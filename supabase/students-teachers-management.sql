-- ============================================================
-- ============================================================
-- → SQL Editor.
--
-- ============================================================

alter table public.students add column if not exists password text;
alter table public.students add column if not exists parent_phone text;
alter table public.students add column if not exists supervisor_id uuid references public.supervisors(id) on delete set null;

alter table public.teachers add column if not exists password text;
alter table public.teachers add column if not exists subject text;
alter table public.teachers add column if not exists supervisor_id uuid references public.supervisors(id) on delete set null;

drop policy if exists "anon full access - students" on public.students;
drop policy if exists "anon full access - teachers" on public.teachers;

-- ============================================================
-- ============================================================

create or replace function public.create_student(
    p_supervisor_id uuid,
    p_name text,
    p_phone text,
    p_parent_phone text,
    p_stage text,
    p_password text
)
returns table (id uuid, name text, phone text, parent_phone text, stage text, created_at timestamptz)
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
    insert into public.students (full_name, phone, parent_phone, stage, password, supervisor_id)
    values (p_name, p_phone, p_parent_phone, p_stage, p_password, p_supervisor_id)
    returning students.id, students.full_name, students.phone, students.parent_phone, students.stage, students.created_at;
end;
$$;

revoke all on function public.create_student(uuid, text, text, text, text, text) from public;
grant execute on function public.create_student(uuid, text, text, text, text, text) to anon;

create or replace function public.update_student(
    p_supervisor_id uuid,
    p_student_id uuid,
    p_name text,
    p_phone text,
    p_parent_phone text,
    p_stage text,
    p_password text default null
)
returns table (id uuid, name text, phone text, parent_phone text, stage text, created_at timestamptz)
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
        password = coalesce(nullif(p_password, ''), password)
    where students.id = p_student_id;

    return query
    select st.id, st.full_name, st.phone, st.parent_phone, st.stage, st.created_at
    from public.students st
    where st.id = p_student_id;
end;
$$;

revoke all on function public.update_student(uuid, uuid, text, text, text, text, text) from public;
grant execute on function public.update_student(uuid, uuid, text, text, text, text, text) to anon;

-- ============================================================
-- ============================================================

create or replace function public.create_teacher(
    p_supervisor_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_subject text,
    p_password text
)
returns table (id uuid, name text, phone text, email text, subject text, created_at timestamptz)
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
    insert into public.teachers (full_name, phone, email, subject, password, supervisor_id)
    values (p_name, p_phone, p_email, p_subject, p_password, p_supervisor_id)
    returning teachers.id, teachers.full_name, teachers.phone, teachers.email, teachers.subject, teachers.created_at;
end;
$$;

revoke all on function public.create_teacher(uuid, text, text, text, text, text) from public;
grant execute on function public.create_teacher(uuid, text, text, text, text, text) to anon;

create or replace function public.update_teacher(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_subject text,
    p_password text default null
)
returns table (id uuid, name text, phone text, email text, subject text, created_at timestamptz)
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
        password = coalesce(nullif(p_password, ''), password)
    where teachers.id = p_teacher_id;

    return query
    select t.id, t.full_name, t.phone, t.email, t.subject, t.created_at
    from public.teachers t
    where t.id = p_teacher_id;
end;
$$;

revoke all on function public.update_teacher(uuid, uuid, text, text, text, text, text) from public;
grant execute on function public.update_teacher(uuid, uuid, text, text, text, text, text) to anon;

-- ============================================================
-- ============================================================

create or replace function public.sync_class_rating(
    p_teacher_phone text,
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text,
    p_rating smallint
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

    insert into public.classes (teacher_id, student_id, subject, day, time)
    values (v_teacher_id, v_student_id, p_subject, p_day, p_time)
    on conflict (teacher_id, day, time, subject)
    do update set student_id = excluded.student_id
    returning id into v_class_id;

    insert into public.ratings (class_id, teacher_id, student_id, rating_score, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_rating, now())
    on conflict (class_id)
    do update set rating_score = excluded.rating_score, updated_at = now();

    return true;
end;
$$;

revoke all on function public.sync_class_rating(text, text, text, text, text, smallint) from public;
grant execute on function public.sync_class_rating(text, text, text, text, text, smallint) to anon;

create or replace function public.get_class_rating(
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text
)
returns smallint
language sql
security definer
set search_path = public
as $$
    select r.rating_score
    from public.ratings r
    join public.classes c on c.id = r.class_id
    join public.students s on s.id = c.student_id
    where s.phone = p_student_phone
      and c.day = p_day
      and c.time = p_time
      and c.subject = p_subject
    limit 1;
$$;

revoke all on function public.get_class_rating(text, text, text, text) from public;
grant execute on function public.get_class_rating(text, text, text, text) to anon;
