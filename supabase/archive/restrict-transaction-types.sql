-- ربط المعاملات المالية بالمشرفين (لبند "رواتب المشرفين" الجديد)
alter table public.transactions add column if not exists supervisor_id uuid references public.supervisors(id) on delete set null;

-- ترحيل أي بيانات قديمة لأنواع المعاملات الجديدة (أفضل تخمين ممكن للبيانات
-- الموجودة، قبل ما نطبّق القيد الجديد الأضيق)
update public.transactions set type = 'teacher_salary' where type = 'salary';
update public.transactions set type = 'advertising' where type = 'expense';

-- استبدال قيد النوع القديم بالقيد الجديد المحصور في 4 بنود فقط:
-- اشتراك الطالب (إيراد)، رواتب المعلمين، رواتب المشرفين، مصروفات الإعلانات (مصروفات)
alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions add constraint transactions_type_check
    check (type in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising'));

create or replace function public.create_transaction(
    p_manager_id uuid,
    p_type text,
    p_amount numeric,
    p_description text default null,
    p_payment_method text default null,
    p_student_id uuid default null,
    p_teacher_id uuid default null,
    p_supervisor_id uuid default null
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

    if p_type not in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising') then
        raise exception 'invalid_type';
    end if;

    return query
    insert into public.transactions (type, amount, description, payment_method, student_id, teacher_id, supervisor_id, recorded_by)
    values (p_type, p_amount, p_description, p_payment_method, p_student_id, p_teacher_id, p_supervisor_id, p_manager_id)
    returning transactions.id, transactions.type, transactions.amount, transactions.description,
              transactions.payment_method, transactions.created_at;
end;
$$;

revoke all on function public.create_transaction(uuid, text, numeric, text, text, uuid, uuid, uuid) from public;
grant execute on function public.create_transaction(uuid, text, numeric, text, text, uuid, uuid, uuid) to anon;

-- الدالة القديمة (بدون p_supervisor_id) لم تعد مستخدمة من الواجهة، لازم نشيلها
-- عشان مايفضلش فيه نسختين متضاربتين بنفس الاسم
drop function if exists public.create_transaction(uuid, text, numeric, text, text, uuid, uuid);

create or replace function public.list_transactions(p_manager_id uuid, p_limit integer default 200)
returns table (
    id uuid,
    "type" text,
    amount numeric,
    description text,
    payment_method text,
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
    select t.id, t.type, t.amount, t.description, t.payment_method,
           s.full_name, te.full_name, sv.name, t.created_at
    from public.transactions t
    left join public.students s on s.id = t.student_id
    left join public.teachers te on te.id = t.teacher_id
    left join public.supervisors sv on sv.id = t.supervisor_id
    order by t.created_at desc
    limit p_limit;
end;
$$;

revoke all on function public.get_financial_kpis(uuid) from public;

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
    where transactions.type in ('teacher_salary', 'supervisor_salary', 'advertising')
      and transactions.created_at >= v_month_start;

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

grant execute on function public.get_financial_kpis(uuid) to anon;

revoke all on function public.get_monthly_financial_trend(uuid, integer) from public;

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
        coalesce(sum(t.amount) filter (where t.type in ('teacher_salary', 'supervisor_salary', 'advertising')), 0),
        coalesce(sum(t.amount) filter (where t.type = 'subscription'), 0)
            - coalesce(sum(t.amount) filter (where t.type in ('teacher_salary', 'supervisor_salary', 'advertising')), 0)
    from bounds
    left join public.transactions t
      on t.created_at >= bounds.m_start_utc and t.created_at < bounds.m_end_utc
    group by bounds.m_start_utc, bounds.m_end_utc
    order by bounds.m_start_utc;
end;
$$;

grant execute on function public.get_monthly_financial_trend(uuid, integer) to anon;

revoke all on function public.list_transactions(uuid, integer) from public;
grant execute on function public.list_transactions(uuid, integer) to anon;
