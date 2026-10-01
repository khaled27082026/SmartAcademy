-- ============================================================
-- SQL Editor.
-- ============================================================

alter table public.supervisors add column if not exists email text;


create or replace function public.create_supervisor(
    p_manager_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_password text
)
returns table (id uuid, name text, phone text, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.supervisors s where s.phone = p_phone) then
        raise exception 'phone_taken';
    end if;

    return query
    insert into public.supervisors (name, phone, email, password)
    values (p_name, p_phone, p_email, p_password)
    returning supervisors.id, supervisors.name, supervisors.phone, supervisors.email, supervisors.created_at;
end;
$$;

revoke all on function public.create_supervisor(uuid, text, text, text, text) from public;
grant execute on function public.create_supervisor(uuid, text, text, text, text) to anon;

create or replace function public.list_supervisors(p_manager_id uuid)
returns table (id uuid, name text, phone text, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select s.id, s.name, s.phone, s.email, s.created_at
    from public.supervisors s
    order by s.created_at desc;
end;
$$;

revoke all on function public.list_supervisors(uuid) from public;
grant execute on function public.list_supervisors(uuid) to anon;

create or replace function public.delete_supervisor(p_manager_id uuid, p_supervisor_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    delete from public.supervisors where id = p_supervisor_id;
    return found;
end;
$$;

revoke all on function public.delete_supervisor(uuid, uuid) from public;
grant execute on function public.delete_supervisor(uuid, uuid) to anon;
