-- ============================================================
-- Smart Academy — main-schema.sql
-- ============================================================
--
--
-- ============================================================

create extension if not exists "pgcrypto";

-- ============================================================
-- ============================================================
drop table if exists public.notifications        cascade;
drop table if exists public.push_subscriptions   cascade;
drop table if exists public.student_reports      cascade;
drop table if exists public.transactions        cascade;
drop table if exists public.teacher_penalties    cascade;
drop table if exists public.attendance           cascade;
drop table if exists public.ratings              cascade;
drop table if exists public.teacher_students     cascade;
drop table if exists public.classes              cascade;
drop table if exists public.teachers             cascade;
drop table if exists public.students             cascade;
drop table if exists public.supervisors          cascade;
drop table if exists public.managers             cascade;

-- ============================================================
-- ============================================================

create table public.managers (
    id uuid primary key default gen_random_uuid(),
    name text,
    phone text unique not null,
    password text not null,
    auth_user_id uuid unique references auth.users(id) on delete set null,
    created_at timestamptz not null default now()
);

create table public.supervisors (
    id uuid primary key default gen_random_uuid(),
    name text,
    phone text unique not null,
    email text,
    password text not null,
    created_at timestamptz not null default now()
);

create table public.students (
    id uuid primary key default gen_random_uuid(),
    phone text unique not null,
    full_name text,
    stage text,
    parent_phone text,
    password text,
    session_price numeric,
    subjects text[] not null default '{}',
    supervisor_id uuid references public.supervisors(id) on delete set null,
    created_at timestamptz not null default now()
);

create table public.teachers (
    id uuid primary key default gen_random_uuid(),
    phone text unique not null,
    full_name text,
    email text,
    subject text,
    subjects text[] not null default '{}',
    password text,
    hourly_rate numeric,
    supervisor_id uuid references public.supervisors(id) on delete set null,
    created_at timestamptz not null default now()
);

create table public.classes (
    id uuid primary key default gen_random_uuid(),
    teacher_id uuid references public.teachers(id) on delete cascade,
    student_id uuid references public.students(id) on delete set null,
    subject text,
    day text not null,
    time text not null,
    link text,
    duration_minutes integer,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (teacher_id, day, time, subject)
);

-- teacher_students: per teacher-student pair session rate. This is the
-- single source of truth for how much a teacher earns per completed
-- session with a given student — replaces the old flat teachers.hourly_rate
-- for all earnings/dues calculations (that column is kept only as legacy
-- metadata and is no longer used in any money math).
create table public.teacher_students (
    id uuid primary key default gen_random_uuid(),
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    student_id uuid not null references public.students(id) on delete cascade,
    session_rate numeric not null default 0 check (session_rate >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (teacher_id, student_id)
);

create table public.ratings (
    id uuid primary key default gen_random_uuid(),
    class_id uuid not null unique references public.classes(id) on delete cascade,
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    student_id uuid references public.students(id) on delete cascade,
    rating_score smallint not null check (rating_score between 1 and 5),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table public.attendance (
    id uuid primary key default gen_random_uuid(),
    class_id uuid not null unique references public.classes(id) on delete cascade,
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    student_id uuid references public.students(id) on delete cascade,
    status text not null check (status in ('present', 'absent')),
    actual_duration_minutes integer,
    -- Snapshot of teacher_students.session_rate at the time this session was
    -- logged/completed. Earnings are always the SUM of this column, never a
    -- rate multiplied on the fly, so a later rate change never reshapes past
    -- months.
    session_rate numeric,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table public.teacher_penalties (
    id uuid primary key default gen_random_uuid(),
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    supervisor_id uuid references public.supervisors(id) on delete set null,
    amount numeric not null check (amount >= 0),
    reason text not null,
    created_at timestamptz not null default now()
);

create table public.transactions (
    id uuid primary key default gen_random_uuid(),
    type text not null check (type in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising')),
    amount numeric not null check (amount >= 0),
    student_id uuid references public.students(id) on delete set null,
    teacher_id uuid references public.teachers(id) on delete set null,
    supervisor_id uuid references public.supervisors(id) on delete set null,
    recorded_by uuid references public.managers(id) on delete set null,
    source text not null default 'manual',
    created_at timestamptz not null default now()
);

create table public.student_reports (
    id uuid primary key default gen_random_uuid(),
    student_id uuid not null references public.students(id) on delete cascade,
    supervisor_id uuid references public.supervisors(id) on delete set null,
    text text not null,
    created_at timestamptz not null default now()
);

create table public.push_subscriptions (
    id uuid primary key default gen_random_uuid(),
    user_type text not null check (user_type in ('student', 'teacher')),
    user_id uuid not null,
    endpoint text not null unique,
    p256dh text not null,
    auth text not null,
    created_at timestamptz not null default now()
);

create table public.notifications (
    id uuid primary key default gen_random_uuid(),
    class_id uuid not null references public.classes(id) on delete cascade,
    recipient_type text not null check (recipient_type in ('student', 'teacher')),
    recipient_id uuid not null,
    occurrence_date date not null,
    type text not null default 'class_reminder_10m',
    title text not null,
    body text not null,
    link text,
    sent_status text not null default 'pending' check (sent_status in ('pending', 'sent', 'failed')),
    read_at timestamptz,
    created_at timestamptz not null default now(),
    unique (class_id, recipient_type, recipient_id, occurrence_date, type)
);

-- ============================================================
-- ============================================================
create index classes_student_id_idx            on public.classes(student_id);
create index classes_teacher_id_idx            on public.classes(teacher_id);
create index classes_day_idx                   on public.classes(day);
create index ratings_student_id_idx            on public.ratings(student_id);
create index ratings_teacher_id_idx            on public.ratings(teacher_id);
create index attendance_student_id_idx         on public.attendance(student_id);
create index attendance_teacher_id_idx         on public.attendance(teacher_id);
create index teacher_penalties_teacher_id_idx  on public.teacher_penalties(teacher_id);
create index teacher_penalties_supervisor_id_idx on public.teacher_penalties(supervisor_id);
create index students_supervisor_id_idx        on public.students(supervisor_id);
create index teachers_supervisor_id_idx        on public.teachers(supervisor_id);
create index teacher_students_teacher_id_idx   on public.teacher_students(teacher_id);
create index teacher_students_student_id_idx   on public.teacher_students(student_id);
create index transactions_created_at_idx       on public.transactions(created_at desc);
create index transactions_type_idx             on public.transactions(type);
create index transactions_source_idx           on public.transactions(source);
create index transactions_student_id_idx       on public.transactions(student_id);
create index transactions_teacher_id_idx       on public.transactions(teacher_id);
create index transactions_supervisor_id_idx    on public.transactions(supervisor_id);
create index student_reports_student_idx       on public.student_reports(student_id, created_at desc);
create index push_subscriptions_user_idx       on public.push_subscriptions(user_type, user_id);
create index notifications_recipient_idx       on public.notifications(recipient_type, recipient_id, created_at desc);

-- ============================================================
-- ============================================================
insert into public.managers (name, phone, password)
values ('Omar', '01012345678', '123456');

insert into public.supervisors (name, phone, password)
values ('خالد إبراهيم منصور', '01055555555', '123456');
