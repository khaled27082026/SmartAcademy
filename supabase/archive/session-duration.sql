alter table public.classes add column if not exists duration_minutes integer;

create or replace function public.sync_class_rating(
    p_teacher_phone text,
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text,
    p_rating smallint,
    p_duration_minutes integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_teacher_id uuid;
    v_student_id uuid;
    v_class_id uuid;
begin
    select id into v_teacher_id from public.teachers where phone = p_teacher_phone;
    if v_teacher_id is null then
        return false;
    end if;

    if p_student_phone is not null then
        select id into v_student_id from public.students where phone = p_student_phone;
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes)
    values (v_teacher_id, v_student_id, p_subject, p_day, p_time, p_duration_minutes)
    on conflict (teacher_id, day, time, subject)
    do update set
        student_id = excluded.student_id,
        duration_minutes = coalesce(excluded.duration_minutes, public.classes.duration_minutes)
    returning id into v_class_id;

    insert into public.ratings (class_id, teacher_id, student_id, rating_score, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_rating, now())
    on conflict (class_id)
    do update set rating_score = excluded.rating_score, updated_at = now();

    return true;
end;
$$;

revoke all on function public.sync_class_rating(text, text, text, text, text, smallint, integer) from public;
grant execute on function public.sync_class_rating(text, text, text, text, text, smallint, integer) to anon;

create or replace function public.sync_class_attendance(
    p_teacher_phone text,
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text,
    p_status text,
    p_duration_minutes integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_teacher_id uuid;
    v_student_id uuid;
    v_class_id uuid;
begin
    if p_status not in ('present', 'absent') then
        raise exception 'invalid_status';
    end if;

    select id into v_teacher_id from public.teachers where phone = p_teacher_phone;
    if v_teacher_id is null then
        return false;
    end if;

    if p_student_phone is not null then
        select id into v_student_id from public.students where phone = p_student_phone;
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes)
    values (v_teacher_id, v_student_id, p_subject, p_day, p_time, p_duration_minutes)
    on conflict (teacher_id, day, time, subject)
    do update set
        student_id = excluded.student_id,
        duration_minutes = coalesce(excluded.duration_minutes, public.classes.duration_minutes)
    returning id into v_class_id;

    insert into public.attendance (class_id, teacher_id, student_id, status, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_status, now())
    on conflict (class_id)
    do update set status = excluded.status, updated_at = now();

    return true;
end;
$$;

revoke all on function public.sync_class_attendance(text, text, text, text, text, text, integer) from public;
grant execute on function public.sync_class_attendance(text, text, text, text, text, text, integer) to anon;

create or replace function public.list_attendance_overview(p_supervisor_id uuid)
returns table (
    student_name text,
    teacher_name text,
    subject text,
    day text,
    "time" text,
    duration_minutes integer,
    status text,
    updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors sv where sv.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select s.full_name, t.full_name, c.subject, c.day, c.time, c.duration_minutes, a.status, a.updated_at
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    join public.students s on s.id = c.student_id
    left join public.attendance a on a.class_id = c.id
    where t.supervisor_id = p_supervisor_id
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

revoke all on function public.list_attendance_overview(uuid) from public;
grant execute on function public.list_attendance_overview(uuid) to anon;
