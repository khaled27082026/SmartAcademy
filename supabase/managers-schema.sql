-- ============================================================
-- SQL Editor → New query → Run.
-- ============================================================

create extension if not exists "pgcrypto";

create table if not exists public.managers (
    id uuid primary key default gen_random_uuid(),
    name text,
    phone text unique not null,
    password text not null,
    created_at timestamptz not null default now()
);

-- -------------------- Row Level Security --------------------
alter table public.managers enable row level security;

create or replace function public.verify_manager_login(p_phone text, p_password text)
returns table (id uuid, name text)
language sql
security definer
set search_path = public
as $$
    select m.id, m.name
    from public.managers m
    where m.phone = p_phone and m.password = p_password
    limit 1;
$$;

revoke all on function public.verify_manager_login(text, text) from public;
grant execute on function public.verify_manager_login(text, text) to anon;

insert into public.managers (name, phone, password)
values ('مدير سمارت أكاديمي', '01012345678', '123456')
on conflict (phone) do nothing;
