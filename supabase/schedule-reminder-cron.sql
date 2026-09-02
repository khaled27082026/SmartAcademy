-- ============================================================
-- Smart Academy — schedule-reminder-cron.sql
-- ============================================================
-- يجدول تشغيل Edge Function باسم notify-upcoming-classes كل دقيقة،
-- عن طريق pg_cron (الجدولة) وpg_net (استدعاء HTTP من داخل Postgres).
--
-- ⚠️ يجب تشغيل هذا الملف بعد نشر الـ Edge Function فعليًا.
-- الـ Authorization Bearer أدناه هو مفتاح anon العام الخاص بمشروعك (نفس
-- المفتاح الموجود في js/supabase-config.js) — ليس سرًا، آمن كتابته هنا.
-- ============================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
    'notify-upcoming-classes-every-minute',
    '* * * * *',
    $$
    select net.http_post(
        url := 'https://sxobsikdlgxpwnqazqtj.supabase.co/functions/v1/notify-upcoming-classes',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer sb_publishable_7Q98XUZ5hjMMJKfOW4LBfw_WuBAqk-B'
        ),
        body := '{}'::jsonb
    );
    $$
);

-- للتأكد إن الجدولة اشتغلت:
-- select * from cron.job where jobname = 'notify-upcoming-classes-every-minute';

-- لإيقاف الجدولة (لو محتاج توقفها مؤقتًا):
-- select cron.unschedule('notify-upcoming-classes-every-minute');

-- لمتابعة آخر تشغيلات الجدولة ونتايجها (نجحت/فشلت):
-- select * from cron.job_run_details
-- where jobid = (select jobid from cron.job where jobname = 'notify-upcoming-classes-every-minute')
-- order by start_time desc limit 20;
