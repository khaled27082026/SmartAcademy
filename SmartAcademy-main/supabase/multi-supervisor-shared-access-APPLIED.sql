-- ============================================================
-- Smart Academy — multi-supervisor-shared-access-DRAFT.sql
-- ============================================================
-- DRAFT FOR REVIEW ONLY. NOT EXECUTED BY THE ASSISTANT.
--
-- Zero-data-loss guarantee for this script:
--   - No DROP TABLE / DROP COLUMN / TRUNCATE anywhere below.
--   - No ALTER TABLE that removes or renames anything.
--   - Every "create or replace function" keeps the EXACT SAME name and
--     argument signature as the current version in functions.sql, so no
--     frontend call site (js/*.js, *.html) needs to change.
--   - New tables/columns only. Existing columns (students.supervisor_id,
--     teachers.supervisor_id) are kept and now mean "owner" — nothing
--     currently reading them breaks.
--
-- Run order: this file, once, after your current schema/functions/policies
-- are already applied. Safe to re-run (idempotent: IF NOT EXISTS / ON
-- CONFLICT DO NOTHING / CREATE OR REPLACE everywhere).
--
-- Design decision (per your answer): "owner + shared viewers" model.
--   - The existing supervisor_id column on students/teachers = the OWNER.
--   - New junction tables add extra supervisors with equal read/write
--     access to that student/teacher, but who CANNOT grant/revoke anyone
--     else's access (only the owner or a manager can).
--
-- Pre-existing observation (not fixed here, flagging for your awareness):
--   update_student / update_teacher currently only check that the calling
--   supervisor_id exists at all — not that it owns the record. So today,
--   any valid supervisor can already edit any student/teacher. This script
--   does not change that behavior (out of scope for "shared access"); it
--   only adds audit logging so such edits are now traceable. Say the word
--   if you also want update_* restricted to owner+shared supervisors only.
-- ============================================================


-- ============================================================
-- STEP 1 — Junction tables (new, empty until backfilled)
-- ============================================================

create table if not exists public.student_supervisors (
    student_id    uuid not null references public.students(id) on delete cascade,
    supervisor_id uuid not null references public.supervisors(id) on delete cascade,
    granted_by    uuid references public.managers(id) on delete set null,
    created_at    timestamptz not null default now(),
    primary key (student_id, supervisor_id)
);

create table if not exists public.teacher_supervisors (
    teacher_id    uuid not null references public.teachers(id) on delete cascade,
    supervisor_id uuid not null references public.supervisors(id) on delete cascade,
    granted_by    uuid references public.managers(id) on delete set null,
    created_at    timestamptz not null default now(),
    primary key (teacher_id, supervisor_id)
);

create index if not exists student_supervisors_supervisor_idx on public.student_supervisors(supervisor_id);
create index if not exists teacher_supervisors_supervisor_idx on public.teacher_supervisors(supervisor_id);

alter table public.student_supervisors enable row level security;
alter table public.teacher_supervisors enable row level security;
-- No policies added (same deny-all-by-default pattern as every other table).
-- All access goes through the SECURITY DEFINER functions below.


-- ============================================================
-- STEP 2 — Backfill (pure INSERT, reads existing data, writes nothing to
-- the original supervisor_id columns)
-- ============================================================

insert into public.student_supervisors (student_id, supervisor_id)
select id, supervisor_id from public.students where supervisor_id is not null
on conflict do nothing;

insert into public.teacher_supervisors (teacher_id, supervisor_id)
select id, supervisor_id from public.teachers where supervisor_id is not null
on conflict do nothing;


-- ============================================================
-- STEP 3 — Audit log (new, append-only)
-- ============================================================

create table if not exists public.audit_log (
    id          uuid primary key default gen_random_uuid(),
    actor_type  text not null check (actor_type in ('manager', 'supervisor')),
    actor_id    uuid not null,
    action      text not null,
    entity_type text not null,
    entity_id   uuid,
    details     jsonb,
    created_at  timestamptz not null default now()
);

create index if not exists audit_log_entity_idx on public.audit_log(entity_type, entity_id, created_at desc);
create index if not exists audit_log_actor_idx  on public.audit_log(actor_id, created_at desc);

alter table public.audit_log enable row level security;
-- No policies: written/read only via SECURITY DEFINER functions.

create or replace function public.list_audit_log(
    p_manager_id uuid,
    p_entity_type text default null,
    p_entity_id uuid default null,
    p_limit integer default 200
)
returns table (
    id uuid, actor_type text, actor_id uuid, action text,
    entity_type text, entity_id uuid, details jsonb, created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    return query
    select a.id, a.actor_type, a.actor_id, a.action, a.entity_type, a.entity_id, a.details, a.created_at
    from public.audit_log a
    where (p_entity_type is null or a.entity_type = p_entity_type)
      and (p_entity_id is null or a.entity_id = p_entity_id)
    order by a.created_at desc
    limit coalesce(p_limit, 200);
end;
$$;

revoke all on function public.list_audit_log(uuid, text, uuid, integer) from public;
grant execute on function public.list_audit_log(uuid, text, uuid, integer) to anon;


-- ============================================================
-- STEP 4 — Grant/revoke shared-access RPCs
-- ============================================================
-- Authorized caller = a valid manager (p_manager_id) OR the owning
-- supervisor of the record (p_supervisor_id, must match supervisor_id on
-- the students/teachers row). Exactly one of the two should be passed by
-- the frontend depending on which dashboard is calling.

create or replace function public.grant_student_access(
    p_student_id uuid,
    p_target_supervisor_id uuid,
    p_manager_id uuid default null,
    p_supervisor_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_actor_type text;
    v_actor_id uuid;
begin
    if p_manager_id is not null then
        if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'manager';
        v_actor_id := p_manager_id;
    elsif p_supervisor_id is not null then
        if not exists (select 1 from public.students st where st.id = p_student_id and st.supervisor_id = p_supervisor_id) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'supervisor';
        v_actor_id := p_supervisor_id;
    else
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.supervisors s where s.id = p_target_supervisor_id) then
        raise exception 'supervisor_not_found';
    end if;

    insert into public.student_supervisors (student_id, supervisor_id, granted_by)
    values (p_student_id, p_target_supervisor_id, p_manager_id)
    on conflict do nothing;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values (v_actor_type, v_actor_id, 'grant_student_access', 'student', p_student_id,
            jsonb_build_object('target_supervisor_id', p_target_supervisor_id));

    return true;
end;
$$;

create or replace function public.revoke_student_access(
    p_student_id uuid,
    p_target_supervisor_id uuid,
    p_manager_id uuid default null,
    p_supervisor_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_actor_type text;
    v_actor_id uuid;
begin
    if p_manager_id is not null then
        if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'manager';
        v_actor_id := p_manager_id;
    elsif p_supervisor_id is not null then
        if not exists (select 1 from public.students st where st.id = p_student_id and st.supervisor_id = p_supervisor_id) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'supervisor';
        v_actor_id := p_supervisor_id;
    else
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.students st where st.id = p_student_id and st.supervisor_id = p_target_supervisor_id) then
        raise exception 'cannot_revoke_owner';
    end if;

    delete from public.student_supervisors
    where student_id = p_student_id and supervisor_id = p_target_supervisor_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values (v_actor_type, v_actor_id, 'revoke_student_access', 'student', p_student_id,
            jsonb_build_object('target_supervisor_id', p_target_supervisor_id));

    return found;
end;
$$;

create or replace function public.grant_teacher_access(
    p_teacher_id uuid,
    p_target_supervisor_id uuid,
    p_manager_id uuid default null,
    p_supervisor_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_actor_type text;
    v_actor_id uuid;
begin
    if p_manager_id is not null then
        if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'manager';
        v_actor_id := p_manager_id;
    elsif p_supervisor_id is not null then
        if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.supervisor_id = p_supervisor_id) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'supervisor';
        v_actor_id := p_supervisor_id;
    else
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.supervisors s where s.id = p_target_supervisor_id) then
        raise exception 'supervisor_not_found';
    end if;

    insert into public.teacher_supervisors (teacher_id, supervisor_id, granted_by)
    values (p_teacher_id, p_target_supervisor_id, p_manager_id)
    on conflict do nothing;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values (v_actor_type, v_actor_id, 'grant_teacher_access', 'teacher', p_teacher_id,
            jsonb_build_object('target_supervisor_id', p_target_supervisor_id));

    return true;
end;
$$;

create or replace function public.revoke_teacher_access(
    p_teacher_id uuid,
    p_target_supervisor_id uuid,
    p_manager_id uuid default null,
    p_supervisor_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_actor_type text;
    v_actor_id uuid;
begin
    if p_manager_id is not null then
        if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'manager';
        v_actor_id := p_manager_id;
    elsif p_supervisor_id is not null then
        if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.supervisor_id = p_supervisor_id) then
            raise exception 'unauthorized';
        end if;
        v_actor_type := 'supervisor';
        v_actor_id := p_supervisor_id;
    else
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.teachers t where t.id = p_teacher_id and t.supervisor_id = p_target_supervisor_id) then
        raise exception 'cannot_revoke_owner';
    end if;

    delete from public.teacher_supervisors
    where teacher_id = p_teacher_id and supervisor_id = p_target_supervisor_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values (v_actor_type, v_actor_id, 'revoke_teacher_access', 'teacher', p_teacher_id,
            jsonb_build_object('target_supervisor_id', p_target_supervisor_id));

    return found;
end;
$$;

create or replace function public.list_student_supervisors(p_student_id uuid)
returns table (supervisor_id uuid, name text, phone text, is_owner boolean)
language sql
security definer
set search_path = public
as $$
    select s.id, s.name, s.phone, (s.id = st.supervisor_id) as is_owner
    from public.students st
    join public.supervisors s
      on s.id = st.supervisor_id
      or s.id in (select ss.supervisor_id from public.student_supervisors ss where ss.student_id = st.id)
    where st.id = p_student_id;
$$;

create or replace function public.list_teacher_supervisors(p_teacher_id uuid)
returns table (supervisor_id uuid, name text, phone text, is_owner boolean)
language sql
security definer
set search_path = public
as $$
    select s.id, s.name, s.phone, (s.id = t.supervisor_id) as is_owner
    from public.teachers t
    join public.supervisors s
      on s.id = t.supervisor_id
      or s.id in (select ts.supervisor_id from public.teacher_supervisors ts where ts.teacher_id = t.id)
    where t.id = p_teacher_id;
$$;

revoke all on function public.grant_student_access(uuid, uuid, uuid, uuid) from public;
grant execute on function public.grant_student_access(uuid, uuid, uuid, uuid) to anon;
revoke all on function public.revoke_student_access(uuid, uuid, uuid, uuid) from public;
grant execute on function public.revoke_student_access(uuid, uuid, uuid, uuid) to anon;
revoke all on function public.grant_teacher_access(uuid, uuid, uuid, uuid) from public;
grant execute on function public.grant_teacher_access(uuid, uuid, uuid, uuid) to anon;
revoke all on function public.revoke_teacher_access(uuid, uuid, uuid, uuid) from public;
grant execute on function public.revoke_teacher_access(uuid, uuid, uuid, uuid) to anon;
revoke all on function public.list_student_supervisors(uuid) from public;
grant execute on function public.list_student_supervisors(uuid) to anon;
revoke all on function public.list_teacher_supervisors(uuid) from public;
grant execute on function public.list_teacher_supervisors(uuid) to anon;


-- ============================================================
-- STEP 5 — Update existing ownership checks to accept shared access
-- ============================================================
-- Every function below keeps its exact name + signature. The only change
-- is the authorization/filter condition: it now passes for the OWNER
-- (existing supervisor_id column) OR any supervisor granted shared access
-- via the junction tables.

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
    where st.supervisor_id = p_supervisor_id
       or exists (select 1 from public.student_supervisors ss where ss.student_id = st.id and ss.supervisor_id = p_supervisor_id)
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
    where t.supervisor_id = p_supervisor_id
       or exists (select 1 from public.teacher_supervisors ts where ts.teacher_id = t.id and ts.supervisor_id = p_supervisor_id)
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
    where t.supervisor_id = p_supervisor_id
       or exists (select 1 from public.teacher_supervisors ts where ts.teacher_id = t.id and ts.supervisor_id = p_supervisor_id)
    order by t.full_name;
end;
$$;

create or replace function public.set_student_subjects(p_supervisor_id uuid, p_student_id uuid, p_subjects text[])
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.students st
        where st.id = p_student_id
          and (st.supervisor_id = p_supervisor_id
               or exists (select 1 from public.student_supervisors ss where ss.student_id = st.id and ss.supervisor_id = p_supervisor_id))
    ) then
        raise exception 'unauthorized';
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
    if not exists (
        select 1 from public.teachers t
        where t.id = p_teacher_id
          and (t.supervisor_id = p_supervisor_id
               or exists (select 1 from public.teacher_supervisors ts where ts.teacher_id = t.id and ts.supervisor_id = p_supervisor_id))
    ) then
        raise exception 'unauthorized';
    end if;

    update public.teachers set subjects = coalesce(p_subjects, '{}') where id = p_teacher_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'set_teacher_subjects', 'teacher', p_teacher_id, jsonb_build_object('subjects', p_subjects));

    return true;
end;
$$;

create or replace function public.list_student_reports(p_supervisor_id uuid, p_student_id uuid)
returns table (id uuid, text text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.students st
        where st.id = p_student_id
          and (st.supervisor_id = p_supervisor_id
               or exists (select 1 from public.student_supervisors ss where ss.student_id = st.id and ss.supervisor_id = p_supervisor_id))
    ) then
        raise exception 'unauthorized';
    end if;

    return query
    select r.id, r.text, r.created_at
    from public.student_reports r
    where r.student_id = p_student_id
    order by r.created_at desc;
end;
$$;

create or replace function public.add_student_report(p_supervisor_id uuid, p_student_id uuid, p_text text)
returns table (id uuid, text text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.students st
        where st.id = p_student_id
          and (st.supervisor_id = p_supervisor_id
               or exists (select 1 from public.student_supervisors ss where ss.student_id = st.id and ss.supervisor_id = p_supervisor_id))
    ) then
        raise exception 'unauthorized';
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
    select r.student_id into v_student_id
    from public.student_reports r
    join public.students st on st.id = r.student_id
    where r.id = p_report_id
      and (st.supervisor_id = p_supervisor_id
           or exists (select 1 from public.student_supervisors ss where ss.student_id = st.id and ss.supervisor_id = p_supervisor_id));

    if v_student_id is null then
        return false;
    end if;

    delete from public.student_reports where id = p_report_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'delete_student_report', 'student', v_student_id, jsonb_build_object('report_id', p_report_id));

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
    if not exists (
        select 1 from public.students st
        where st.id = p_student_id and st.supervisor_id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
        -- NOTE: deletion stays owner-only on purpose (shared viewers can
        -- read/edit day-to-day data but should not be able to delete the
        -- student outright). Say the word if you'd rather allow any
        -- shared supervisor to delete too.
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
    if not exists (
        select 1 from public.teachers t
        where t.id = p_teacher_id and t.supervisor_id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
        -- Same owner-only-delete note as delete_student above.
    end if;

    delete from public.teachers where id = p_teacher_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'delete_teacher', 'teacher', p_teacher_id, null);

    return found;
end;
$$;

create or replace function public.get_student_sessions_for_manage(p_supervisor_id uuid, p_student_id uuid)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer, teacher_id uuid)
language sql
security definer
set search_path = public
as $$
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes, c.teacher_id
    from public.classes c
    join public.students st on st.id = c.student_id
    where c.student_id = p_student_id
      and c.is_active = true
      and (st.supervisor_id = p_supervisor_id
           or exists (select 1 from public.student_supervisors ss where ss.student_id = st.id and ss.supervisor_id = p_supervisor_id));
$$;

create or replace function public.get_teacher_sessions_for_manage(p_supervisor_id uuid, p_teacher_id uuid)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer)
language sql
security definer
set search_path = public
as $$
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    where c.teacher_id = p_teacher_id
      and c.is_active = true
      and (t.supervisor_id = p_supervisor_id
           or exists (select 1 from public.teacher_supervisors ts where ts.teacher_id = t.id and ts.supervisor_id = p_supervisor_id));
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
    if not exists (
        select 1 from public.students st
        where st.id = p_student_id
          and (st.supervisor_id = p_supervisor_id
               or exists (select 1 from public.student_supervisors ss where ss.student_id = st.id and ss.supervisor_id = p_supervisor_id))
    ) then
        raise exception 'unauthorized';
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
    if not exists (
        select 1 from public.teachers t
        where t.id = p_teacher_id
          and (t.supervisor_id = p_supervisor_id
               or exists (select 1 from public.teacher_supervisors ts where ts.teacher_id = t.id and ts.supervisor_id = p_supervisor_id))
    ) then
        raise exception 'unauthorized';
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
       or exists (select 1 from public.teacher_supervisors ts where ts.teacher_id = t.id and ts.supervisor_id = p_supervisor_id)
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
-- STEP 6 — Audit logging added to remaining write-path RPCs
-- (ownership/authorization logic in these is UNCHANGED — only the audit
-- insert is new)
-- ============================================================

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
declare
    v_id uuid;
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.students st where st.phone = p_phone) then
        raise exception 'phone_taken';
    end if;

    insert into public.students (full_name, phone, parent_phone, stage, password, supervisor_id, session_price)
    values (p_name, p_phone, p_parent_phone, p_stage, p_password, p_supervisor_id, p_session_price)
    returning students.id into v_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'create_student', 'student', v_id, jsonb_build_object('name', p_name, 'phone', p_phone));

    return query
    select st.id, st.full_name, st.phone, st.parent_phone, st.stage, st.session_price, st.created_at
    from public.students st where st.id = v_id;
end;
$$;

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

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'update_student', 'student', p_student_id, jsonb_build_object('name', p_name, 'phone', p_phone));

    return query
    select st.id, st.full_name, st.phone, st.parent_phone, st.stage, st.session_price, st.created_at
    from public.students st
    where st.id = p_student_id;
end;
$$;

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
declare
    v_id uuid;
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.teachers t where t.phone = p_phone) then
        raise exception 'phone_taken';
    end if;

    insert into public.teachers (full_name, phone, email, subject, password, supervisor_id, hourly_rate)
    values (p_name, p_phone, p_email, p_subject, p_password, p_supervisor_id, p_hourly_rate)
    returning teachers.id into v_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'create_teacher', 'teacher', v_id, jsonb_build_object('name', p_name, 'phone', p_phone));

    return query
    select t.id, t.full_name, t.phone, t.email, t.subject, t.hourly_rate, t.created_at
    from public.teachers t where t.id = v_id;
end;
$$;

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

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'update_teacher', 'teacher', p_teacher_id, jsonb_build_object('name', p_name, 'phone', p_phone));

    return query
    select t.id, t.full_name, t.phone, t.email, t.subject, t.hourly_rate, t.created_at
    from public.teachers t
    where t.id = p_teacher_id;
end;
$$;

create or replace function public.create_teacher_penalty(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_amount numeric,
    p_reason text
)
returns table (
    id uuid,
    teacher_id uuid,
    supervisor_id uuid,
    amount numeric,
    reason text,
    created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.teachers t where t.id = p_teacher_id) then
        raise exception 'teacher_not_found';
    end if;

    insert into public.teacher_penalties (teacher_id, supervisor_id, amount, reason)
    values (p_teacher_id, p_supervisor_id, p_amount, p_reason)
    returning teacher_penalties.id into v_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('supervisor', p_supervisor_id, 'create_teacher_penalty', 'teacher', p_teacher_id, jsonb_build_object('amount', p_amount, 'reason', p_reason));

    return query
    select tp.id, tp.teacher_id, tp.supervisor_id, tp.amount, tp.reason, tp.created_at
    from public.teacher_penalties tp where tp.id = v_id;
end;
$$;

create or replace function public.create_transaction(
    p_manager_id uuid,
    p_type text,
    p_amount numeric,
    p_student_id uuid default null,
    p_teacher_id uuid default null,
    p_supervisor_id uuid default null
)
returns table (
    id uuid,
    "type" text,
    amount numeric,
    created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    if p_type not in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising') then
        raise exception 'invalid_type';
    end if;

    insert into public.transactions (type, amount, student_id, teacher_id, supervisor_id, recorded_by)
    values (p_type, p_amount, p_student_id, p_teacher_id, p_supervisor_id, p_manager_id)
    returning transactions.id into v_id;

    insert into public.audit_log (actor_type, actor_id, action, entity_type, entity_id, details)
    values ('manager', p_manager_id, 'create_transaction', 'transaction', v_id,
            jsonb_build_object('type', p_type, 'amount', p_amount, 'student_id', p_student_id, 'teacher_id', p_teacher_id, 'supervisor_id', p_supervisor_id));

    return query
    select t.id, t.type, t.amount, t.created_at
    from public.transactions t where t.id = v_id;
end;
$$;


-- ============================================================
-- STEP 7 — Grants for functions replaced above
-- (signatures unchanged, so existing grants from policies.sql already
-- cover them — this is a defensive re-assert, harmless to re-run)
-- ============================================================

grant execute on function public.list_students(uuid) to anon;
grant execute on function public.list_teachers_full(uuid) to anon;
grant execute on function public.list_teachers(uuid) to anon;
grant execute on function public.set_student_subjects(uuid, uuid, text[]) to anon;
grant execute on function public.set_teacher_subjects(uuid, uuid, text[]) to anon;
grant execute on function public.list_student_reports(uuid, uuid) to anon;
grant execute on function public.add_student_report(uuid, uuid, text) to anon;
grant execute on function public.delete_student_report(uuid, uuid) to anon;
grant execute on function public.delete_student(uuid, uuid) to anon;
grant execute on function public.delete_teacher(uuid, uuid) to anon;
grant execute on function public.get_student_sessions_for_manage(uuid, uuid) to anon;
grant execute on function public.get_teacher_sessions_for_manage(uuid, uuid) to anon;
grant execute on function public.set_student_sessions(uuid, uuid, jsonb) to anon;
grant execute on function public.set_teacher_sessions(uuid, uuid, jsonb) to anon;
grant execute on function public.list_attendance_overview(uuid) to anon;
grant execute on function public.create_student(uuid, text, text, text, text, text, numeric) to anon;
grant execute on function public.update_student(uuid, uuid, text, text, text, text, text, numeric) to anon;
grant execute on function public.create_teacher(uuid, text, text, text, text, text, numeric) to anon;
grant execute on function public.update_teacher(uuid, uuid, text, text, text, text, text, numeric) to anon;
grant execute on function public.create_teacher_penalty(uuid, uuid, numeric, text) to anon;
grant execute on function public.create_transaction(uuid, text, numeric, uuid, uuid, uuid) to anon;

-- ============================================================
-- END OF DRAFT
-- ============================================================
