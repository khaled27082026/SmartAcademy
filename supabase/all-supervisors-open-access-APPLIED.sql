-- ============================================================
-- Smart Academy — all-supervisors-open-access-DRAFT.sql
-- ============================================================
-- DRAFT FOR REVIEW ONLY. NOT EXECUTED BY THE ASSISTANT.
--
-- Supersedes the "owner + shared viewers" model from
-- multi-supervisor-shared-access-DRAFT.sql. Per your decision: every
-- valid supervisor should see and edit ALL students/teachers, with zero
-- manual granting.
--
-- Zero-data-loss guarantee for this script:
--   - No DROP TABLE / DROP COLUMN / TRUNCATE / ALTER TABLE anywhere.
--   - Every "create or replace function" keeps the EXACT SAME name and
--     argument signature as the current version, so no frontend call
--     site needs to change.
--   - students.supervisor_id / teachers.supervisor_id are left as-is
--     (still recorded as "who created this record", just no longer used
--     to gate access). Existing data is untouched.
--
-- Note on the previous migration: student_supervisors, teacher_supervisors,
-- audit_log, and the grant_*/revoke_*/list_*_supervisors functions from
-- multi-supervisor-shared-access-DRAFT.sql are NOT removed by this
-- script — they simply stop being read by the functions below. They are
-- harmless to leave in place (unused tables/functions, no data loss risk).
-- Say the word separately if you'd like a follow-up script to drop them
-- for cleanliness — that would be a DROP and needs its own explicit
-- approval per the zero-data-loss policy.
--
-- Security note: this intentionally removes ALL per-supervisor
-- restrictions. Any of the phone+password accounts in public.supervisors
-- can now read and write every student and teacher record on the
-- platform. Audit logging (from the previous migration) is kept and
-- extended here so actions remain traceable even though they're no
-- longer restricted.
-- ============================================================


-- ============================================================
-- READ functions — drop the ownership filter, keep "caller must be a
-- valid supervisor" check
-- ============================================================

create or replace function public.list_students(p_supervisor_id uuid)
returns table (
    id uuid, full_name text, phone text, parent_phone text, stage text,
    session_price numeric, subjects text[], created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select st.id, st.full_name, st.phone, st.parent_phone, st.stage,
           st.session_price, st.subjects, st.created_at
    from public.students st
    order by st.created_at desc;
end;
$$;

create or replace function public.list_teachers_full(p_supervisor_id uuid)
returns table (
    id uuid, full_name text, phone text, email text, hourly_rate numeric,
    subjects text[], created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select t.id, t.full_name, t.phone, t.email, t.hourly_rate, t.subjects, t.created_at
    from public.teachers t
    order by t.created_at desc;
end;
$$;

create or replace function public.list_teachers(p_supervisor_id uuid)
returns table (id uuid, name text, phone text, subject text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select t.id, t.full_name, t.phone, t.subject
    from public.teachers t
    order by t.full_name;
end;
$$;

create or replace function public.list_student_reports(p_supervisor_id uuid, p_student_id uuid)
returns table (id uuid, text text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.students st where st.id = p_student_id) then
        raise exception 'student_not_found';
    end if;

    return query
    select r.id, r.text, r.created_at
    from public.student_reports r
    where r.student_id = p_student_id
    order by r.created_at desc;
end;
$$;

create or replace function public.get_student_sessions_for_manage(p_supervisor_id uuid, p_student_id uuid)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer, teacher_id uuid)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes, c.teacher_id
    from public.classes c
    where c.student_id = p_student_id
      and c.is_active = true;
end;
$$;

create or replace function public.get_teacher_sessions_for_manage(p_supervisor_id uuid, p_teacher_id uuid)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes
    from public.classes c
    where c.teacher_id = p_teacher_id
      and c.is_active = true;
end;
$$;

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


-- ============================================================
-- WRITE functions — drop the ownership filter, keep "caller must be a
-- valid supervisor" check, keep audit logging
-- ============================================================

create or replace function public.set_student_subjects(p_supervisor_id uuid, p_student_id uuid, p_subjects text[])
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.students st where st.id = p_student_id) then
        raise exception 'student_not_found';
    end if;

    update public.students set subjects = coalesce(p_subjects, '{}') where id = p_student_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'set_student_subjects', 'student', p_student_id, jsonb_build_object('subjects', p_subjects));

    return true;
end;
$$;

create or replace function public.set_teacher_subjects(p_supervisor_id uuid, p_teacher_id uuid, p_subjects text[])
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.teachers t where t.id = p_teacher_id) then
        raise exception 'teacher_not_found';
    end if;

    update public.teachers set subjects = coalesce(p_subjects, '{}') where id = p_teacher_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'set_teacher_subjects', 'teacher', p_teacher_id, jsonb_build_object('subjects', p_subjects));

    return true;
end;
$$;

create or replace function public.add_student_report(p_supervisor_id uuid, p_student_id uuid, p_text text)
returns table (id uuid, text text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.students st where st.id = p_student_id) then
        raise exception 'student_not_found';
    end if;

    if coalesce(trim(p_text), '') = '' then
        raise exception 'empty_text';
    end if;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'add_student_report', 'student', p_student_id, jsonb_build_object('text', p_text));

    return query
    insert into public.student_reports (student_id, supervisor_id, text)
    values (p_student_id, p_supervisor_id, p_text)
    returning student_reports.id, student_reports.text, student_reports.created_at;
end;
$$;

create or replace function public.delete_student_report(p_supervisor_id uuid, p_report_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    select student_id into v_student_id from public.student_reports where id = p_report_id;
    if v_student_id is null then
        return false;
    end if;

    delete from public.student_reports where id = p_report_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'delete_student_report', 'student', v_student_id, jsonb_build_object('report_id', p_report_id));

    return true;
end;
$$;

create or replace function public.set_student_sessions(
    p_supervisor_id uuid,
    p_student_id uuid,
    p_sessions jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.students st where st.id = p_student_id) then
        raise exception 'student_not_found';
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes, link, is_active, updated_at)
    select s.teacher_id, p_student_id, s.subject, s.day, s.time, s.duration, s.link, true, now()
    from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text, duration integer, link text, teacher_id uuid)
    where s.teacher_id is not null
    on conflict (teacher_id, day, time, subject)
    do update set
        student_id = excluded.student_id,
        duration_minutes = excluded.duration_minutes,
        link = excluded.link,
        is_active = true,
        updated_at = now();

    update public.classes c
    set is_active = false, updated_at = now()
    where c.student_id = p_student_id
      and c.is_active = true
      and not exists (
          select 1
          from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text, teacher_id uuid)
          where s.teacher_id = c.teacher_id and s.day = c.day and s.time = c.time and s.subject = c.subject
      );

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'set_student_sessions', 'student', p_student_id, p_sessions);

    return true;
end;
$$;

create or replace function public.set_teacher_sessions(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_sessions jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.teachers t where t.id = p_teacher_id) then
        raise exception 'teacher_not_found';
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes, link, is_active, updated_at)
    select p_teacher_id, null, s.subject, s.day, s.time, s.duration, s.link, true, now()
    from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text, duration integer, link text)
    on conflict (teacher_id, day, time, subject)
    do update set
        duration_minutes = excluded.duration_minutes,
        link = excluded.link,
        is_active = true,
        updated_at = now();

    update public.classes c
    set is_active = false, updated_at = now()
    where c.teacher_id = p_teacher_id
      and c.is_active = true
      and not exists (
          select 1
          from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text)
          where s.day = c.day and s.time = c.time and s.subject = c.subject
      );

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'set_teacher_sessions', 'teacher', p_teacher_id, p_sessions);

    return true;
end;
$$;

create or replace function public.delete_student(p_supervisor_id uuid, p_student_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    delete from public.students where id = p_student_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'delete_student', 'student', p_student_id, null);

    return found;
end;
$$;

create or replace function public.delete_teacher(p_supervisor_id uuid, p_teacher_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    delete from public.teachers where id = p_teacher_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'delete_teacher', 'teacher', p_teacher_id, null);

    return found;
end;
$$;

-- update_student / update_teacher / create_teacher_penalty already had no
-- ownership restriction before this migration (any valid supervisor could
-- already call them) — no change needed, they already match the new model.


-- ============================================================
-- Grants (signatures unchanged — defensive re-assert, harmless to re-run)
-- ============================================================

grant execute on function public.list_students(uuid) to anon;
grant execute on function public.list_teachers_full(uuid) to anon;
grant execute on function public.list_teachers(uuid) to anon;
grant execute on function public.list_student_reports(uuid, uuid) to anon;
grant execute on function public.get_student_sessions_for_manage(uuid, uuid) to anon;
grant execute on function public.get_teacher_sessions_for_manage(uuid, uuid) to anon;
grant execute on function public.list_attendance_overview(uuid) to anon;
grant execute on function public.set_student_subjects(uuid, uuid, text[]) to anon;
grant execute on function public.set_teacher_subjects(uuid, uuid, text[]) to anon;
grant execute on function public.add_student_report(uuid, uuid, text) to anon;
grant execute on function public.delete_student_report(uuid, uuid) to anon;
grant execute on function public.set_student_sessions(uuid, uuid, jsonb) to anon;
grant execute on function public.set_teacher_sessions(uuid, uuid, jsonb) to anon;
grant execute on function public.delete_student(uuid, uuid) to anon;
grant execute on function public.delete_teacher(uuid, uuid) to anon;

-- ============================================================
-- END OF DRAFT
-- ============================================================
