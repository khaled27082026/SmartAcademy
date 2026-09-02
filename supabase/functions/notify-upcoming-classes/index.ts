// ============================================================
// Smart Academy — Edge Function: notify-upcoming-classes
// ============================================================
// يعمل كل دقيقة (عبر pg_cron وpg_net، راجع
// supabase/schedule-reminder-cron.sql). يحسب "بعد 10 دقائق بالضبط من
// الآن" بتوقيت دبي، ويبحث في الحصص النشطة (classes.is_active = true)
// التي تبدأ في اللحظة نفسها، ثم يرسل إشعار Web Push حقيقيًا للطالب والمعلم.
//
// منع التكرار: عملية upsert في جدول notifications بمفتاح فريد
// (class_id, recipient_type, recipient_id, occurrence_date, type) —
// إذا كان الصف موجودًا مسبقًا (تشغيل آخر لأي سبب)، يُرفض الإدراج بهدوء
// (ignoreDuplicates) ولا يُرسل إشعار مكرر.

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY')!;
const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY')!;
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@smartacademy.app';

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

const REMINDER_MINUTES_AHEAD = 10;
const DUBAI_TZ = 'Asia/Dubai';

// نفس ترتيب الأيام المستخدم في كل الواجهة الأمامية (السبت أول يوم).
const DAY_MAP: Record<string, string> = {
    Sat: 'السبت',
    Sun: 'الأحد',
    Mon: 'الاثنين',
    Tue: 'الثلاثاء',
    Wed: 'الأربعاء',
    Thu: 'الخميس',
    Fri: 'الجمعة'
};

function getDubaiTargetParts(targetDate: Date) {
    const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: DUBAI_TZ,
        hour12: false,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        weekday: 'short'
    }).formatToParts(targetDate).reduce((acc: Record<string, string>, p) => {
        acc[p.type] = p.value;
        return acc;
    }, {});

    let hour = parseInt(parts.hour, 10);
    if (hour === 24) hour = 0;

    return {
        dayArabic: DAY_MAP[parts.weekday] || null,
        hour,
        minute: parseInt(parts.minute, 10),
        occurrenceDate: `${parts.year}-${parts.month}-${parts.day}`
    };
}

// نفس منطق parseSessionTime في الواجهة الأمامية بالظبط — "5:00 مساءً" أو
// "11:30 صباحاً".
function parseClassTime(str: string | null): { hour: number; minute: number } | null {
    if (!str) return null;
    const match = str.match(/^(\d{1,2}):(\d{2})\s*(صباحاً|مساءً)?$/);
    if (!match) return null;

    let hour = parseInt(match[1], 10);
    const minute = parseInt(match[2], 10);
    const period = match[3];

    if (period === 'مساءً' && hour !== 12) hour += 12;
    if (period === 'صباحاً' && hour === 12) hour = 0;

    return { hour, minute };
}

Deno.serve(async () => {
    try {
        const target = new Date(Date.now() + REMINDER_MINUTES_AHEAD * 60000);
        const { dayArabic, hour: targetHour, minute: targetMinute, occurrenceDate } = getDubaiTargetParts(target);

        if (!dayArabic) {
            return new Response(JSON.stringify({ ok: false, error: 'day_mapping_failed' }), { status: 500 });
        }

        const { data: classes, error: classesError } = await supabase
            .from('classes')
            .select('id, day, time, subject, link, teacher_id, student_id')
            .eq('is_active', true)
            .eq('day', dayArabic);

        if (classesError) throw classesError;

        const matches = (classes || []).filter((c) => {
            const parsed = parseClassTime(c.time);
            return parsed && parsed.hour === targetHour && parsed.minute === targetMinute;
        });

        if (matches.length === 0) {
            return new Response(JSON.stringify({ ok: true, matched: 0 }), { status: 200 });
        }

        const teacherIds = [...new Set(matches.map((c) => c.teacher_id).filter(Boolean))];
        const studentIds = [...new Set(matches.map((c) => c.student_id).filter(Boolean))];

        const [{ data: teachers }, { data: students }] = await Promise.all([
            teacherIds.length
                ? supabase.from('teachers').select('id, full_name').in('id', teacherIds)
                : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
            studentIds.length
                ? supabase.from('students').select('id, full_name').in('id', studentIds)
                : Promise.resolve({ data: [] as { id: string; full_name: string }[] })
        ]);

        const teacherNameMap = new Map((teachers || []).map((t) => [t.id, t.full_name]));
        const studentNameMap = new Map((students || []).map((s) => [s.id, s.full_name]));

        let sentCount = 0;
        let skippedDuplicates = 0;

        for (const cls of matches) {
            const teacherName = cls.teacher_id ? teacherNameMap.get(cls.teacher_id) || 'المعلم' : null;
            const studentName = cls.student_id ? studentNameMap.get(cls.student_id) || 'الطالب' : null;

            const recipients: { type: 'student' | 'teacher'; id: string; title: string; body: string }[] = [];

            if (cls.student_id) {
                recipients.push({
                    type: 'student',
                    id: cls.student_id,
                    title: 'تذكير: حصتك تبدأ بعد 10 دقائق',
                    body: `${cls.subject || 'حصتك'} مع ${teacherName || 'معلمك'} — الساعة ${cls.time}`
                });
            }

            if (cls.teacher_id) {
                recipients.push({
                    type: 'teacher',
                    id: cls.teacher_id,
                    title: 'تذكير: حصتك تبدأ بعد 10 دقائق',
                    body: `${cls.subject || 'حصة'} مع الطالب ${studentName || 'غير محدد'} — الساعة ${cls.time}`
                });
            }

            for (const recipient of recipients) {
                const { data: inserted, error: insertError } = await supabase
                    .from('notifications')
                    .upsert(
                        {
                            class_id: cls.id,
                            recipient_type: recipient.type,
                            recipient_id: recipient.id,
                            occurrence_date: occurrenceDate,
                            type: 'class_reminder_10m',
                            title: recipient.title,
                            body: recipient.body,
                            link: cls.link || null,
                            sent_status: 'pending'
                        },
                        {
                            onConflict: 'class_id,recipient_type,recipient_id,occurrence_date,type',
                            ignoreDuplicates: true
                        }
                    )
                    .select('id')
                    .maybeSingle();

                if (insertError) {
                    console.error('notification insert failed:', insertError);
                    continue;
                }

                if (!inserted) {
                    skippedDuplicates++;
                    continue;
                }

                const { data: subs } = await supabase
                    .from('push_subscriptions')
                    .select('id, endpoint, p256dh, auth')
                    .eq('user_type', recipient.type)
                    .eq('user_id', recipient.id);

                let anySent = false;

                for (const sub of subs || []) {
                    try {
                        await webpush.sendNotification(
                            {
                                endpoint: sub.endpoint,
                                keys: { p256dh: sub.p256dh, auth: sub.auth }
                            },
                            JSON.stringify({ title: recipient.title, body: recipient.body, link: cls.link || null })
                        );
                        anySent = true;
                    } catch (err) {
                        const statusCode = (err as { statusCode?: number })?.statusCode;
                        console.error('push send failed:', statusCode, (err as Error)?.message);
                        if (statusCode === 404 || statusCode === 410) {
                            await supabase.from('push_subscriptions').delete().eq('id', sub.id);
                        }
                    }
                }

                await supabase
                    .from('notifications')
                    .update({ sent_status: anySent ? 'sent' : 'failed' })
                    .eq('id', inserted.id);

                if (anySent) sentCount++;
            }
        }

        return new Response(
            JSON.stringify({ ok: true, matched: matches.length, sent: sentCount, skippedDuplicates }),
            { status: 200 }
        );
    } catch (err) {
        console.error('notify-upcoming-classes failed:', err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), { status: 500 });
    }
});
