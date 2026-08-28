-- ============================================================
-- ============================================================

do $$
declare
    r record;
begin
    for r in
        select p.oid::regprocedure as sig
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where p.proname = 'update_supervisor' and n.nspname = 'public'
    loop
        execute format('drop function %s', r.sig);
    end loop;
end $$;

create or replace function public.update_supervisor(
    p_manager_id uuid,
    p_supervisor_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_password text default null
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

    if exists (select 1 from public.supervisors s where s.phone = p_phone and s.id <> p_supervisor_id) then
        raise exception 'phone_taken';
    end if;

    update public.supervisors
    set name = p_name,
        phone = p_phone,
        email = p_email,
        password = coalesce(nullif(p_password, ''), password)
    where supervisors.id = p_supervisor_id;

    return query
    select s.id, s.name, s.phone, s.email, s.created_at
    from public.supervisors s
    where s.id = p_supervisor_id;
end;
$$;

revoke all on function public.update_supervisor(uuid, uuid, text, text, text, text) from public;
grant execute on function public.update_supervisor(uuid, uuid, text, text, text, text) to anon;
