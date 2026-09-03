-- تعبئة حضور وتقييم واقعيين لكل حصص هذا الأسبوع (من السبت الماضي لحد
-- النهاردة فقط) لبيانات الاختبار النهائي التي أنشأها seed-final-test-data.sql.
-- بدون أي تواريخ مستقبلية أو تسجيلات قبل معاد الحصة الفعلي.

with parsed as (
    select
        c.id as class_id, c.teacher_id, c.student_id,
        (
            (case c.day
                when 'السبت'   then date '2026-08-29'
                when 'الأحد'   then date '2026-08-30'
                when 'الثلاثاء' then date '2026-09-01'
                when 'الأربعاء' then date '2026-09-02'
            end)::text || ' ' ||
            lpad((case when c.time like '%مساءً' and split_part(c.time, ':', 1)::int <> 12
                       then split_part(c.time, ':', 1)::int + 12 else split_part(c.time, ':', 1)::int end)::text, 2, '0')
            || ':' || split_part(split_part(c.time, ':', 2), ' ', 1) || ':00'
        )::timestamp at time zone 'Asia/Dubai' as occurred_at,
        (c.student_id = (select id from public.students where phone = '01080000004')
            and c.day = 'الأربعاء') as is_absent
    from public.classes c
    where c.day in ('السبت', 'الأحد', 'الثلاثاء', 'الأربعاء')
)
insert into public.attendance (class_id, teacher_id, student_id, status, actual_duration_minutes, created_at, updated_at)
select class_id, teacher_id, student_id,
       case when is_absent then 'absent' else 'present' end,
       case when is_absent then null else 55 + (('x' || substr(md5(class_id::text), 1, 4))::bit(16)::int % 6) end,
       occurred_at, occurred_at
from parsed;

with parsed as (
    select
        c.id as class_id, c.teacher_id, c.student_id,
        (
            (case c.day
                when 'السبت'   then date '2026-08-29'
                when 'الأحد'   then date '2026-08-30'
                when 'الثلاثاء' then date '2026-09-01'
                when 'الأربعاء' then date '2026-09-02'
            end)::text || ' ' ||
            lpad((case when c.time like '%مساءً' and split_part(c.time, ':', 1)::int <> 12
                       then split_part(c.time, ':', 1)::int + 12 else split_part(c.time, ':', 1)::int end)::text, 2, '0')
            || ':' || split_part(split_part(c.time, ':', 2), ' ', 1) || ':00'
        )::timestamp at time zone 'Asia/Dubai' as occurred_at,
        (c.student_id = (select id from public.students where phone = '01080000004')
            and c.day = 'الأربعاء') as is_absent
    from public.classes c
    where c.day in ('السبت', 'الأحد', 'الثلاثاء', 'الأربعاء')
)
insert into public.ratings (class_id, teacher_id, student_id, rating_score, created_at, updated_at)
select class_id, teacher_id, student_id,
       4 + (('x' || substr(md5(class_id::text || 'r'), 1, 4))::bit(16)::int % 2),
       occurred_at, occurred_at
from parsed
where not is_absent;

-- تحقق
select status, count(*) from public.attendance group by status;
select count(*) from public.ratings;
