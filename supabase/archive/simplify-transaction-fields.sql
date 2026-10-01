-- إزالة حقلي "طريقة الدفع" و"الوصف" نهائياً من نظام المعاملات المالية

drop function if exists public.create_transaction(uuid, text, numeric, text, text, uuid, uuid, uuid);
drop function if exists public.create_transaction(uuid, text, numeric, text, text, uuid, uuid);
drop function if exists public.list_transactions(uuid, integer);

alter table public.transactions drop column if exists payment_method;
alter table public.transactions drop column if exists description;

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
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    if p_type not in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising') then
        raise exception 'invalid_type';
    end if;

    return query
    insert into public.transactions (type, amount, student_id, teacher_id, supervisor_id, recorded_by)
    values (p_type, p_amount, p_student_id, p_teacher_id, p_supervisor_id, p_manager_id)
    returning transactions.id, transactions.type, transactions.amount, transactions.created_at;
end;
$$;

revoke all on function public.create_transaction(uuid, text, numeric, uuid, uuid, uuid) from public;
grant execute on function public.create_transaction(uuid, text, numeric, uuid, uuid, uuid) to anon;

create or replace function public.list_transactions(p_manager_id uuid, p_limit integer default 200)
returns table (
    id uuid,
    "type" text,
    amount numeric,
    student_name text,
    teacher_name text,
    supervisor_name text,
    created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select t.id, t.type, t.amount,
           s.full_name, te.full_name, sv.name, t.created_at
    from public.transactions t
    left join public.students s on s.id = t.student_id
    left join public.teachers te on te.id = t.teacher_id
    left join public.supervisors sv on sv.id = t.supervisor_id
    order by t.created_at desc
    limit p_limit;
end;
$$;

revoke all on function public.list_transactions(uuid, integer) from public;
grant execute on function public.list_transactions(uuid, integer) to anon;
