-- ============================================================
-- Smart Academy — Supabase Schema
-- ============================================================

create extension if not exists "pgcrypto";

create table if not exists public.students (
    id uuid primary key default gen_random_uuid(),
    phone text unique not null,
    full_name text,
    stage text,
    created_at timestamptz not null default now()
);

create table if not exists public.teachers (
    id uuid primary key default gen_random_uuid(),
    phone text unique not null,
    full_name text,
    email text,
    created_at timestamptz not null default now()
);

create table if not exists public.classes (
    id uuid primary key default gen_random_uuid(),
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    student_id uuid references public.students(id) on delete set null,
    subject text,
    day text not null,
    time text not null,
    link text,
    created_at timestamptz not null default now(),
    unique (teacher_id, day, time, subject)
);

create table if not exists public.ratings (
    id uuid primary key default gen_random_uuid(),
    class_id uuid not null unique references public.classes(id) on delete cascade,
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    student_id uuid references public.students(id) on delete cascade,
    rating_score smallint not null check (rating_score between 1 and 5),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists ratings_student_id_idx on public.ratings(student_id);
create index if not exists classes_student_id_idx on public.classes(student_id);

-- ============================================================
-- Row Level Security (RLS)
-- ============================================================
alter table public.students enable row level security;
alter table public.teachers enable row level security;
alter table public.classes  enable row level security;
alter table public.ratings  enable row level security;

create policy "anon full access - students" on public.students
    for all using (true) with check (true);

create policy "anon full access - teachers" on public.teachers
    for all using (true) with check (true);

create policy "anon full access - classes" on public.classes
    for all using (true) with check (true);

create policy "anon full access - ratings" on public.ratings
    for all using (true) with check (true);
