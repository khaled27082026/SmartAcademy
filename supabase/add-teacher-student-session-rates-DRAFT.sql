-- ============================================================
-- Smart Academy — add-teacher-student-session-rates-DRAFT.sql
-- ============================================================
-- DRAFT FOR REVIEW ONLY. NOT EXECUTED BY THE ASSISTANT.
--
-- What this does:
--   1. Adds public.teacher_students (teacher_id, student_id, session_rate)
--      — the per-pair rate that replaces the flat teachers.hourly_rate for
--      all money math.
--   2. Adds public.attendance.session_rate — a snapshot of that rate taken
--      whenever a session is logged/completed, so past months never
--      reshape themselves if a rate changes later.
--   3. Backfills teacher_students for every existing teacher-student pair
--      (derived from public.classes) using that teacher's CURRENT
--      hourly_rate as the starting session_rate, so nobody's earnings drop
--      to zero the moment this runs. Supervisors should review/adjust
--      these per pair afterwards.
--   4. Rewrites sync_class_attendance, get_teacher_monthly_earnings,
--      list_teacher_dues_for_manager and sync_teacher_dues_expenses to
--      compute earnings/dues as SUM(attendance.session_rate) instead of
--      (minutes / 60 * hourly_rate).
--   5. Adds two new RPCs so supervisor-teachers.html can manage the
--      per-student rate: list_teacher_student_rates, set_teacher_student_rate.
--
-- Data-loss / breakage notes (read before running):
--   - No DROP TABLE / DROP COLUMN / TRUNCATE anywhere below. teachers.hourly_rate
--     is kept as-is (untouched column, untouched supervisor add/edit-teacher
--     form) — it simply stops being read by any earnings/dues calculation.
--   - get_teacher_monthly_earnings(text) and list_teacher_dues_for_manager(uuid,date,date)
--     CHANGE RETURN SHAPE (total_minutes and hourly_rate columns are dropped
--     from their output, since pay is no longer minutes-based). This is a
--     real breaking change to those two RPCs' signatures — intentional, and
--     only safe because teacher-dashboard.html and manager-dashboard.html
--     are updated in this same patch to match the new columns. If you have
--     any other caller of these two RPCs outside this repo, update it too.
--   - Every other function here keeps its exact existing name + signature.
--
-- Run order: once, after your current schema/functions/policies are already
-- applied. Safe to re-run (idempotent: IF NOT EXISTS / ON CONFLICT DO NOTHING
-- / CREATE OR REPLACE everywhere, backfill only inserts missing rows).
-- ============================================================


-- ============================================================
-- STEP 1 — New table + column (additive only)
-- ============================================================

create table if not exists public.teacher_students (
    id uuid primary key default gen_random_uuid(),
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    student_id uuid not null references public.students(id) on delete cascade,
    session_rate numeric not null default 0 check (session_rate >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (teacher_id, student_id)
);

create index if not exists teacher_students_teacher_id_idx on public.teacher_students(teacher_id);
create index if not exists teacher_students_student_id_idx on public.teacher_students(student_id);

alter table public.teacher_students enable row level security;

alter table public.attendance add column if not exists session_rate numeric;

-- ============================================================
-- STEP 2 — One-time backfill
-- ============================================================
-- Seed a teacher_students row for every (teacher, student) pair that
-- currently exists via classes, using that teacher's existing hourly_rate
-- as the starting per-session rate. Only inserts rows that don't already
-- exist, so this is safe to re-run.

insert into public.teacher_students (teacher_id, student_id, session_rate)
select distinct c.teacher_id, c.student_id, coalesce(t.hourly_rate, 0)
from public.classes c
join public.teachers t on t.id = c.teacher_id
where c.student_id is not null
on conflict (teacher_id, student_id) do nothing;

-- Backfill attendance.session_rate for existing rows so historical dues
-- reports don't suddenly show 0 for sessions already on the books.
update public.attendance a
set session_rate = ts.session_rate
from public.teacher_students ts
where a.teacher_id = ts.teacher_id
  and a.student_id = ts.student_id
  and a.session_rate is null;

-- ============================================================
-- STEP 3 — Rate management RPCs (new, same pattern as other supervisor RPCs)
-- ============================================================

create or replace function public.list_teacher_student_rates(p_supervisor_id uuid, p_teacher_id uuid)
returns table (student_id uuid, student_name text, session_rate numeric)
language sql
security definer
set search_path = public
as $$
    select distinct on (s.id)
        s.id,
        s.full_name,
        coalesce(ts.session_rate, 0)
    from public.classes c
    join public.students s on s.id = c.student_id
    join public.teachers t on t.id = c.teacher_id
    left join public.teacher_students ts
        on ts.teacher_id = c.teacher_id and ts.student_id = c.student_id
    where c.teacher_id = p_teacher_id
      and c.is_active = true
      and t.supervisor_id = p_supervisor_id
    order by s.id, s.full_name;
$$;

create or replace function public.set_teacher_student_rate(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_student_id uuid,
    p_session_rate numeric
)
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
    end if;

    if p_session_rate is null or p_session_rate < 0 then
        raise exception 'invalid_rate';
    end if;

    insert into public.teacher_students (teacher_id, student_id, session_rate, updated_at)
    values (p_teacher_id, p_student_id, p_session_rate, now())
    on conflict (teacher_id, student_id)
    do update set session_rate = excluded.session_rate, updated_at = now();

    return true;
end;
$$;

revoke all on function public.list_teacher_student_rates(uuid, uuid) from public;
grant execute on function public.list_teacher_student_rates(uuid, uuid) to anon;

revoke all on function public.set_teacher_student_rate(uuid, uuid, uuid, numeric) from public;
grant execute on function public.set_teacher_student_rate(uuid, uuid, uuid, numeric) to anon;

-- ============================================================
-- STEP 4 — sync_class_attendance now stamps the inherited rate
-- ============================================================

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
    v_session_rate numeric;
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

    if v_student_id is not null then
        select session_rate into v_session_rate
        from public.teacher_students
        where teacher_id = v_teacher_id and student_id = v_student_id;
    else
        v_session_rate := null;
    end if;

    insert into public.attendance (class_id, teacher_id, student_id, status, actual_duration_minutes, session_rate, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_status, p_actual_duration_minutes, v_session_rate, now())
    on conflict (class_id)
    do update set
        status = excluded.status,
        actual_duration_minutes = excluded.actual_duration_minutes,
        session_rate = excluded.session_rate,
        updated_at = now();

    return true;
end;
$$;

-- ============================================================
-- STEP 5 — Earnings/dues become dynamic SUM(session_rate) aggregates
-- ============================================================

drop function if exists public.get_teacher_monthly_earnings(text);

create or replace function public.get_teacher_monthly_earnings(p_teacher_phone text)
returns table (
    session_count integer,
    total_amount numeric,
    total_penalties numeric,
    net_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_teacher_id uuid;
    v_month_start timestamptz;
    v_session_count integer;
    v_total_amount numeric;
    v_total_penalties numeric;
begin
    select id into v_teacher_id from public.teachers where phone = p_teacher_phone;

    if v_teacher_id is null then
        return;
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    select
        count(*)::integer,
        coalesce(sum(coalesce(a.session_rate, 0)), 0)
    into v_session_count, v_total_amount
    from public.attendance a
    where a.teacher_id = v_teacher_id
      and a.status = 'present'
      and a.updated_at >= v_month_start;

    select coalesce(sum(tp.amount), 0) into v_total_penalties
    from public.teacher_penalties tp
    where tp.teacher_id = v_teacher_id
      and tp.created_at >= v_month_start;

    return query
    select
        v_session_count,
        round(v_total_amount, 2),
        v_total_penalties,
        round(v_total_amount - v_total_penalties, 2);
end;
$$;

revoke all on function public.get_teacher_monthly_earnings(text) from public;
grant execute on function public.get_teacher_monthly_earnings(text) to anon;

drop function if exists public.list_teacher_dues_for_manager(uuid, date, date);

create or replace function public.list_teacher_dues_for_manager(p_manager_id uuid, p_date_from date default null, p_date_to date default null)
returns table (
    teacher_id uuid,
    teacher_name text,
    subject text,
    session_count integer,
    total_amount numeric,
    total_penalties numeric,
    net_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_from timestamptz;
    v_to timestamptz;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    if p_date_from is not null then
        v_from := (p_date_from::timestamp) at time zone 'Asia/Dubai';
    end if;
    if p_date_to is not null then
        v_to := ((p_date_to + 1)::timestamp) at time zone 'Asia/Dubai';
    end if;

    return query
    select
        t.id,
        t.full_name,
        t.subject,
        coalesce(att.session_count, 0)::integer,
        round(coalesce(att.total_amount, 0), 2),
        coalesce(pen.total_penalties, 0),
        round(round(coalesce(att.total_amount, 0), 2) - coalesce(pen.total_penalties, 0), 2)
    from public.teachers t
    left join (
        select a.teacher_id,
               count(*)::integer as session_count,
               coalesce(sum(coalesce(a.session_rate, 0)), 0) as total_amount
        from public.attendance a
        where a.status = 'present'
          and (v_from is null or a.updated_at >= v_from)
          and (v_to is null or a.updated_at < v_to)
        group by a.teacher_id
    ) att on att.teacher_id = t.id
    left join (
        select tp.teacher_id, sum(tp.amount) as total_penalties
        from public.teacher_penalties tp
        where (v_from is null or tp.created_at >= v_from)
          and (v_to is null or tp.created_at < v_to)
        group by tp.teacher_id
    ) pen on pen.teacher_id = t.id
    order by t.full_name;
end;
$$;

revoke all on function public.list_teacher_dues_for_manager(uuid, date, date) from public;
grant execute on function public.list_teacher_dues_for_manager(uuid, date, date) to anon;

create or replace function public.sync_teacher_dues_expenses(p_manager_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_month_start timestamptz;
    v_teacher record;
    v_total_amount numeric;
    v_total_penalties numeric;
    v_net numeric;
    v_existing_id uuid;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    for v_teacher in select id from public.teachers loop
        select round(coalesce(sum(coalesce(a.session_rate, 0)), 0), 2)
        into v_total_amount
        from public.attendance a
        where a.teacher_id = v_teacher.id
          and a.status = 'present'
          and a.updated_at >= v_month_start;

        select coalesce(sum(tp.amount), 0) into v_total_penalties
        from public.teacher_penalties tp
        where tp.teacher_id = v_teacher.id
          and tp.created_at >= v_month_start;

        v_net := round(coalesce(v_total_amount, 0) - v_total_penalties, 2);

        select id into v_existing_id
        from public.transactions
        where teacher_id = v_teacher.id
          and type = 'teacher_salary'
          and source = 'auto_teacher_dues'
          and created_at >= v_month_start
        limit 1;

        if v_net > 0 then
            if v_existing_id is not null then
                update public.transactions set amount = v_net where id = v_existing_id;
            else
                insert into public.transactions (type, amount, teacher_id, recorded_by, source)
                values ('teacher_salary', v_net, v_teacher.id, p_manager_id, 'auto_teacher_dues');
            end if;
        elsif v_existing_id is not null then
            delete from public.transactions where id = v_existing_id;
        end if;
    end loop;
end;
$$;

revoke all on function public.sync_teacher_dues_expenses(uuid) from public;
grant execute on function public.sync_teacher_dues_expenses(uuid) to anon;
