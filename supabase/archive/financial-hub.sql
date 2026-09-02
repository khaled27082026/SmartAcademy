create table if not exists public.transactions (
    id uuid primary key default gen_random_uuid(),
    type text not null check (type in ('subscription', 'salary', 'expense')),
    amount numeric not null check (amount >= 0),
    description text,
    payment_method text,
    student_id uuid references public.students(id) on delete set null,
    teacher_id uuid references public.teachers(id) on delete set null,
    recorded_by uuid references public.managers(id) on delete set null,
    created_at timestamptz not null default now()
);

create index if not exists transactions_created_at_idx on public.transactions(created_at desc);
create index if not exists transactions_type_idx on public.transactions(type);

alter table public.transactions enable row level security;

create or replace function public.create_transaction(
    p_manager_id uuid,
    p_type text,
    p_amount numeric,
    p_description text default null,
    p_payment_method text default null,
    p_student_id uuid default null,
    p_teacher_id uuid default null
)
returns table (
    id uuid,
    "type" text,
    amount numeric,
    description text,
    payment_method text,
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

    if p_type not in ('subscription', 'salary', 'expense') then
        raise exception 'invalid_type';
    end if;

    return query
    insert into public.transactions (type, amount, description, payment_method, student_id, teacher_id, recorded_by)
    values (p_type, p_amount, p_description, p_payment_method, p_student_id, p_teacher_id, p_manager_id)
    returning transactions.id, transactions.type, transactions.amount, transactions.description,
              transactions.payment_method, transactions.created_at;
end;
$$;

revoke all on function public.create_transaction(uuid, text, numeric, text, text, uuid, uuid) from public;
grant execute on function public.create_transaction(uuid, text, numeric, text, text, uuid, uuid) to anon;

create or replace function public.list_transactions(p_manager_id uuid, p_limit integer default 200)
returns table (
    id uuid,
    "type" text,
    amount numeric,
    description text,
    payment_method text,
    student_name text,
    teacher_name text,
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
    select t.id, t.type, t.amount, t.description, t.payment_method,
           s.full_name, te.full_name, t.created_at
    from public.transactions t
    left join public.students s on s.id = t.student_id
    left join public.teachers te on te.id = t.teacher_id
    order by t.created_at desc
    limit p_limit;
end;
$$;

revoke all on function public.list_transactions(uuid, integer) from public;
grant execute on function public.list_transactions(uuid, integer) to anon;

create or replace function public.get_financial_kpis(p_manager_id uuid)
returns table (
    current_month_revenue numeric,
    previous_month_revenue numeric,
    revenue_change_percent numeric,
    current_month_expenses numeric,
    net_profit numeric,
    total_students integer,
    total_teachers integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_month_start timestamptz;
    v_prev_month_start timestamptz;
    v_cur_revenue numeric;
    v_prev_revenue numeric;
    v_cur_expenses numeric;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';
    v_prev_month_start := (date_trunc('month', now() at time zone 'Asia/Dubai') - interval '1 month') at time zone 'Asia/Dubai';

    select coalesce(sum(transactions.amount), 0) into v_cur_revenue
    from public.transactions
    where transactions.type = 'subscription' and transactions.created_at >= v_month_start;

    select coalesce(sum(transactions.amount), 0) into v_prev_revenue
    from public.transactions
    where transactions.type = 'subscription'
      and transactions.created_at >= v_prev_month_start
      and transactions.created_at < v_month_start;

    select coalesce(sum(transactions.amount), 0) into v_cur_expenses
    from public.transactions
    where transactions.type in ('salary', 'expense') and transactions.created_at >= v_month_start;

    return query
    select
        v_cur_revenue,
        v_prev_revenue,
        case when v_prev_revenue > 0 then round((v_cur_revenue - v_prev_revenue) / v_prev_revenue * 100, 1) else null end,
        v_cur_expenses,
        round(v_cur_revenue - v_cur_expenses, 2),
        (select count(*)::integer from public.students),
        (select count(*)::integer from public.teachers);
end;
$$;

revoke all on function public.get_financial_kpis(uuid) from public;
grant execute on function public.get_financial_kpis(uuid) to anon;

create or replace function public.get_monthly_financial_trend(p_manager_id uuid, p_months_back integer default 6)
returns table (
    month_start timestamptz,
    revenue numeric,
    expenses numeric,
    profit numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_current_month_dubai timestamp;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    v_current_month_dubai := date_trunc('month', now() at time zone 'Asia/Dubai');

    return query
    with months as (
        select gs as m_start_dubai
        from generate_series(
            v_current_month_dubai - (interval '1 month' * (p_months_back - 1)),
            v_current_month_dubai,
            interval '1 month'
        ) as gs
    ),
    bounds as (
        select
            (m_start_dubai at time zone 'Asia/Dubai') as m_start_utc,
            ((m_start_dubai + interval '1 month') at time zone 'Asia/Dubai') as m_end_utc
        from months
    )
    select
        bounds.m_start_utc,
        coalesce(sum(t.amount) filter (where t.type = 'subscription'), 0),
        coalesce(sum(t.amount) filter (where t.type in ('salary', 'expense')), 0),
        coalesce(sum(t.amount) filter (where t.type = 'subscription'), 0)
            - coalesce(sum(t.amount) filter (where t.type in ('salary', 'expense')), 0)
    from bounds
    left join public.transactions t
      on t.created_at >= bounds.m_start_utc and t.created_at < bounds.m_end_utc
    group by bounds.m_start_utc, bounds.m_end_utc
    order by bounds.m_start_utc;
end;
$$;

revoke all on function public.get_monthly_financial_trend(uuid, integer) from public;
grant execute on function public.get_monthly_financial_trend(uuid, integer) to anon;

create or replace function public.get_student_subscription_status(p_manager_id uuid)
returns table (
    student_name text,
    phone text,
    last_payment_date timestamptz,
    status text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_month_start timestamptz;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    return query
    select
        s.full_name,
        s.phone,
        (select max(t.created_at) from public.transactions t where t.student_id = s.id and t.type = 'subscription'),
        case
            when exists (
                select 1 from public.transactions t
                where t.student_id = s.id and t.type = 'subscription' and t.created_at >= v_month_start
            ) then 'paid'
            else 'overdue'
        end
    from public.students s
    order by s.full_name;
end;
$$;

revoke all on function public.get_student_subscription_status(uuid) from public;
grant execute on function public.get_student_subscription_status(uuid) to anon;

create or replace function public.list_all_students(p_manager_id uuid)
returns table (id uuid, full_name text, phone text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select s.id, s.full_name, s.phone from public.students s order by s.full_name;
end;
$$;

revoke all on function public.list_all_students(uuid) from public;
grant execute on function public.list_all_students(uuid) to anon;

create or replace function public.list_all_teachers(p_manager_id uuid)
returns table (id uuid, full_name text, phone text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select t.id, t.full_name, t.phone from public.teachers t order by t.full_name;
end;
$$;

revoke all on function public.list_all_teachers(uuid) from public;
grant execute on function public.list_all_teachers(uuid) to anon;
