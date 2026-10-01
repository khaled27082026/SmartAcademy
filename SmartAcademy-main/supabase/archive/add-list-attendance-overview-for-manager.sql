-- ============================================================
-- إضافة دالة list_attendance_overview_for_manager (نسخة موسّعة النطاق من
-- list_attendance_overview تخص المدير، بتغطي كل المشرفين والمعلمين في
-- المنصة). آمن التكرار.
-- ============================================================

create or replace function public.list_attendance_overview_for_manager(p_manager_id uuid)
returns table (
    student_name text,
    teacher_name text,
    subject text,
    day text,
    "time" text,
    duration_minutes integer,
    actual_duration_minutes integer,
    status text,
    updated_at timestamptz,
    amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select
        s.full_name,
        t.full_name,
        c.subject,
        c.day,
        c.time,
        c.duration_minutes,
        a.actual_duration_minutes,
        a.status,
        a.updated_at,
        case
            when a.status = 'present' and s.session_price is not null then s.session_price
            else null
        end
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    join public.students s on s.id = c.student_id
    left join public.attendance a on a.class_id = c.id
    order by
        case c.day
            when 'السبت' then 0
            when 'الأحد' then 1
            when 'الاثنين' then 2
            when 'الثلاثاء' then 3
            when 'الأربعاء' then 4
            when 'الخميس' then 5
            when 'الجمعة' then 6
            else 7
        end,
        c.time;
end;
$$;

revoke all on function public.list_attendance_overview_for_manager(uuid) from public;
grant execute on function public.list_attendance_overview_for_manager(uuid) to anon;
