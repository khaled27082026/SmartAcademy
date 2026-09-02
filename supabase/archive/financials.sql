alter table public.teachers add column if not exists hourly_rate numeric;
alter table public.students add column if not exists session_price numeric;
alter table public.attendance add column if not exists actual_duration_minutes integer;

create or replace function public.create_student(
    p_supervisor_id uuid,
    p_name text,
    p_phone text,
    p_parent_phone text,
    p_stage text,
    p_password text,
    p_session_price numeric default null
)
returns table (id uuid, name text, phone text, parent_phone text, stage text, session_price numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.students st where st.phone = p_phone) then
        raise exception 'phone_taken';
    end if;

    return query
    insert into public.students (full_name, phone, parent_phone, stage, password, supervisor_id, session_price)
    values (p_name, p_phone, p_parent_phone, p_stage, p_password, p_supervisor_id, p_session_price)
    returning students.id, students.full_name, students.phone, students.parent_phone, students.stage, students.session_price, students.created_at;
end;
$$;

revoke all on function public.create_student(uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.create_student(uuid, text, text, text, text, text, numeric) to anon;

create or replace function public.update_student(
    p_supervisor_id uuid,
    p_student_id uuid,
    p_name text,
    p_phone text,
    p_parent_phone text,
    p_stage text,
    p_password text default null,
    p_session_price numeric default null
)
returns table (id uuid, name text, phone text, parent_phone text, stage text, session_price numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.students st where st.phone = p_phone and st.id <> p_student_id) then
        raise exception 'phone_taken';
    end if;

    update public.students
    set full_name = p_name,
        phone = p_phone,
        parent_phone = p_parent_phone,
        stage = p_stage,
        password = coalesce(nullif(p_password, ''), password),
        session_price = p_session_price
    where students.id = p_student_id;

    return query
    select st.id, st.full_name, st.phone, st.parent_phone, st.stage, st.session_price, st.created_at
    from public.students st
    where st.id = p_student_id;
end;
$$;

revoke all on function public.update_student(uuid, uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.update_student(uuid, uuid, text, text, text, text, text, numeric) to anon;

create or replace function public.create_teacher(
    p_supervisor_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_subject text,
    p_password text,
    p_hourly_rate numeric default null
)
returns table (id uuid, name text, phone text, email text, subject text, hourly_rate numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.teachers t where t.phone = p_phone) then
        raise exception 'phone_taken';
    end if;

    return query
    insert into public.teachers (full_name, phone, email, subject, password, supervisor_id, hourly_rate)
    values (p_name, p_phone, p_email, p_subject, p_password, p_supervisor_id, p_hourly_rate)
    returning teachers.id, teachers.full_name, teachers.phone, teachers.email, teachers.subject, teachers.hourly_rate, teachers.created_at;
end;
$$;

revoke all on function public.create_teacher(uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.create_teacher(uuid, text, text, text, text, text, numeric) to anon;

create or replace function public.update_teacher(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_subject text,
    p_password text default null,
    p_hourly_rate numeric default null
)
returns table (id uuid, name text, phone text, email text, subject text, hourly_rate numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.teachers t where t.phone = p_phone and t.id <> p_teacher_id) then
        raise exception 'phone_taken';
    end if;

    update public.teachers
    set full_name = p_name,
        phone = p_phone,
        email = p_email,
        subject = p_subject,
        password = coalesce(nullif(p_password, ''), password),
        hourly_rate = p_hourly_rate
    where teachers.id = p_teacher_id;

    return query
    select t.id, t.full_name, t.phone, t.email, t.subject, t.hourly_rate, t.created_at
    from public.teachers t
    where t.id = p_teacher_id;
end;
$$;

revoke all on function public.update_teacher(uuid, uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.update_teacher(uuid, uuid, text, text, text, text, text, numeric) to anon;

create or replace function public.sync_class_attendance(
    p_teacher_phone text,
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text,
    p_status text,
    p_duration_minutes integer default null,
    p_actual_duration_minutes integer default null
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

    insert into public.attendance (class_id, teacher_id, student_id, status, actual_duration_minutes, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_status, p_actual_duration_minutes, now())
    on conflict (class_id)
    do update set
        status = excluded.status,
        actual_duration_minutes = excluded.actual_duration_minutes,
        updated_at = now();

    return true;
end;
$$;

revoke all on function public.sync_class_attendance(text, text, text, text, text, text, integer, integer) from public;
grant execute on function public.sync_class_attendance(text, text, text, text, text, text, integer, integer) to anon;

create or replace function public.list_attendance_overview(p_supervisor_id uuid)
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
    if not exists (select 1 from public.supervisors sv where sv.id = p_supervisor_id) then
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

create or replace function public.get_teacher_monthly_earnings(p_teacher_phone text)
returns table (
    session_count integer,
    total_minutes integer,
    hourly_rate numeric,
    total_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_teacher_id uuid;
    v_hourly_rate numeric;
    v_month_start timestamptz;
begin
    select teachers.id, teachers.hourly_rate into v_teacher_id, v_hourly_rate
    from public.teachers where phone = p_teacher_phone;

    if v_teacher_id is null then
        return;
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    return query
    select
        count(*)::integer,
        coalesce(sum(coalesce(a.actual_duration_minutes, c.duration_minutes, 0)), 0)::integer,
        v_hourly_rate,
        round(coalesce(sum(coalesce(a.actual_duration_minutes, c.duration_minutes, 0)), 0) / 60.0 * coalesce(v_hourly_rate, 0), 2)
    from public.attendance a
    join public.classes c on c.id = a.class_id
    where a.teacher_id = v_teacher_id
      and a.status = 'present'
      and a.updated_at >= v_month_start;
end;
$$;

revoke all on function public.get_teacher_monthly_earnings(text) from public;
grant execute on function public.get_teacher_monthly_earnings(text) to anon;

create or replace function public.get_student_monthly_cost(p_student_phone text)
returns table (
    session_count integer,
    session_price numeric,
    total_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
    v_session_price numeric;
    v_month_start timestamptz;
begin
    select students.id, students.session_price into v_student_id, v_session_price
    from public.students where phone = p_student_phone;

    if v_student_id is null then
        return;
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    return query
    select
        count(*)::integer,
        v_session_price,
        round(count(*) * coalesce(v_session_price, 0), 2)
    from public.attendance a
    where a.student_id = v_student_id
      and a.status = 'present'
      and a.updated_at >= v_month_start;
end;
$$;

revoke all on function public.get_student_monthly_cost(text) from public;
grant execute on function public.get_student_monthly_cost(text) to anon;
