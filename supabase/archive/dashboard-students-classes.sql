-- دوال بطاقتي "عدد الطلاب المشتركين بالفعل" و"جدول الحصص الفعلية اليومية"
-- في لوحة التحكم الشاملة

create or replace function public.list_students_basic(p_manager_id uuid)
returns table (
    id uuid,
    full_name text,
    phone text,
    stage text,
    created_at timestamptz
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
    select s.id, s.full_name, s.phone, s.stage, s.created_at
    from public.students s
    order by s.full_name;
end;
$$;

revoke all on function public.list_students_basic(uuid) from public;
grant execute on function public.list_students_basic(uuid) to anon;

create or replace function public.list_today_classes(p_manager_id uuid, p_day text)
returns table (
    id uuid,
    "day" text,
    "time" text,
    subject text,
    link text,
    student_name text,
    student_phone text,
    teacher_name text
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
    select c.id, c.day, c.time, c.subject, c.link,
           s.full_name, s.phone, t.full_name
    from public.classes c
    left join public.students s on s.id = c.student_id
    left join public.teachers t on t.id = c.teacher_id
    where c.day = p_day;
end;
$$;

revoke all on function public.list_today_classes(uuid, text) from public;
grant execute on function public.list_today_classes(uuid, text) to anon;
