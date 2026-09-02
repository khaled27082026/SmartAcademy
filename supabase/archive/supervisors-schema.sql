-- ============================================================
-- ============================================================
-- SQL Editor → New query → Run.
-- ============================================================

create extension if not exists "pgcrypto";

create table if not exists public.supervisors (
    id uuid primary key default gen_random_uuid(),
    name text,
    phone text unique not null,
    password text not null,
    created_at timestamptz not null default now()
);

-- -------------------- Row Level Security --------------------
alter table public.supervisors enable row level security;

create or replace function public.verify_supervisor_login(p_phone text, p_password text)
returns table (id uuid, name text)
language sql
security definer
set search_path = public
as $$
    select s.id, s.name
    from public.supervisors s
    where s.phone = p_phone and s.password = p_password
    limit 1;
$$;

revoke all on function public.verify_supervisor_login(text, text) from public;
grant execute on function public.verify_supervisor_login(text, text) to anon;

insert into public.supervisors (name, phone, password)
values ('خالد إبراهيم منصور', '01055555555', '123456')
on conflict (phone) do nothing;
