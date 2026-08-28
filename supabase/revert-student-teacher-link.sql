-- ============================================================
-- ============================================================
--
-- SQL Editor.
-- ============================================================

alter table public.students drop column if exists teacher_id;

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
    order by t.full_name;
end;
$$;

revoke all on function public.list_teachers(uuid) from public;
grant execute on function public.list_teachers(uuid) to anon;

create or replace function public.get_teacher_name(p_teacher_id uuid)
returns text
language sql
security definer
set search_path = public
as $$
    select full_name from public.teachers where id = p_teacher_id;
$$;

revoke all on function public.get_teacher_name(uuid) from public;
grant execute on function public.get_teacher_name(uuid) to anon;
