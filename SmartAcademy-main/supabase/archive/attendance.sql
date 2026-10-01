create table if not exists public.attendance (
    id uuid primary key default gen_random_uuid(),
    class_id uuid not null unique references public.classes(id) on delete cascade,
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    student_id uuid references public.students(id) on delete cascade,
    status text not null check (status in ('present', 'absent')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists attendance_student_id_idx on public.attendance(student_id);
create index if not exists attendance_teacher_id_idx on public.attendance(teacher_id);

alter table public.attendance enable row level security;

create or replace function public.sync_class_attendance(
    p_teacher_phone text,
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text,
    p_status text
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

    insert into public.classes (teacher_id, student_id, subject, day, time)
    values (v_teacher_id, v_student_id, p_subject, p_day, p_time)
    on conflict (teacher_id, day, time, subject)
    do update set student_id = excluded.student_id
    returning id into v_class_id;

    insert into public.attendance (class_id, teacher_id, student_id, status, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_status, now())
    on conflict (class_id)
    do update set status = excluded.status, updated_at = now();

    return true;
end;
$$;

revoke all on function public.sync_class_attendance(text, text, text, text, text, text) from public;
grant execute on function public.sync_class_attendance(text, text, text, text, text, text) to anon;

create or replace function public.get_class_attendance(
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text
)
returns text
language sql
security definer
set search_path = public
as $$
    select a.status
    from public.attendance a
    join public.classes c on c.id = a.class_id
    join public.students s on s.id = c.student_id
    where s.phone = p_student_phone
      and c.day = p_day
      and c.time = p_time
      and c.subject = p_subject
    limit 1;
$$;

revoke all on function public.get_class_attendance(text, text, text, text) from public;
grant execute on function public.get_class_attendance(text, text, text, text) to anon;

create or replace function public.list_attendance_overview(p_supervisor_id uuid)
returns table (
    student_name text,
    teacher_name text,
    subject text,
    day text,
    "time" text,
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
    select s.full_name, t.full_name, c.subject, c.day, c.time, a.status, a.updated_at
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
