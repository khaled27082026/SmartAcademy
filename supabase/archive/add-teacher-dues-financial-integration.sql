-- ============================================================
-- بطاقة "مستحقات المعلمين" بلوحة المدير + الربط التلقائي بسجل
-- المعاملات المالية والمصروفات. آمن التكرار بالكامل.
--
-- ملاحظة مهمة عن العملة: مستحقات المعلمين محسوبة بالجنيه المصري (ج.م)
-- — نفس عملة hourly_rate ونظام رواتب المعلمين في كل المنصة — بينما
-- سجل المعاملات المالية وقسم المصروفات في لوحة المدير يستخدموا الدرهم
-- الإماراتي (د.إ). الصفوف التلقائية (source = 'auto_teacher_dues')
-- بتتسجل بالجنيه المصري كما هي بدون أي تحويل عملة، ولذلك تُستبعد من
-- إجماليات "المصروفات" و"صافي الأرباح" بالدرهم لمنع خلط عملتين في رقم
-- واحد — بطاقة "مستحقات المعلمين" نفسها هي المصدر الواضح لهذا الإجمالي.
-- ============================================================

-- 1) عمود التمييز بين المعاملات اليدوية والمولّدة تلقائيًا
alter table public.transactions add column if not exists source text not null default 'manual';

-- 2) list_transactions: إضافة عمود source (لازم drop لتغيّر return type)
drop function if exists public.list_transactions(uuid, integer);

create or replace function public.list_transactions(p_manager_id uuid, p_limit integer default 200)
returns table (
    id uuid,
    "type" text,
    amount numeric,
    student_name text,
    teacher_name text,
    supervisor_name text,
    created_at timestamptz,
    source text
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
           s.full_name, te.full_name, sv.name, t.created_at, t.source
    from public.transactions t
    left join public.students s on s.id = t.student_id
    left join public.teachers te on te.id = t.teacher_id
    left join public.supervisors sv on sv.id = t.supervisor_id
    order by t.created_at desc
    limit p_limit;
end;
$$;

-- 3) get_financial_kpis: استبعاد الصفوف التلقائية من إجمالي المصروفات (د.إ)
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
      and transactions.created_at >= v_month_start
      and transactions.source is distinct from 'auto_teacher_dues';

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

-- 4) get_monthly_financial_trend: نفس الاستبعاد على مدار الأشهر
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
        coalesce(sum(t.amount) filter (where t.type in ('teacher_salary', 'supervisor_salary', 'advertising') and t.source is distinct from 'auto_teacher_dues'), 0),
        coalesce(sum(t.amount) filter (where t.type = 'subscription'), 0)
            - coalesce(sum(t.amount) filter (where t.type in ('teacher_salary', 'supervisor_salary', 'advertising') and t.source is distinct from 'auto_teacher_dues'), 0)
    from bounds
    left join public.transactions t
      on t.created_at >= bounds.m_start_utc and t.created_at < bounds.m_end_utc
    group by bounds.m_start_utc, bounds.m_end_utc
    order by bounds.m_start_utc;
end;
$$;

-- 5) list_teacher_dues_for_manager: بطاقة "مستحقات المعلمين" (كل المعلمين، الشهر الحالي)
create or replace function public.list_teacher_dues_for_manager(p_manager_id uuid)
returns table (
    teacher_id uuid,
    teacher_name text,
    subject text,
    session_count integer,
    total_minutes integer,
    hourly_rate numeric,
    total_amount numeric,
    total_penalties numeric,
    net_amount numeric
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
        t.id,
        t.full_name,
        t.subject,
        coalesce(att.session_count, 0)::integer,
        coalesce(att.total_minutes, 0)::integer,
        t.hourly_rate,
        round(coalesce(att.total_minutes, 0) / 60.0 * coalesce(t.hourly_rate, 0), 2),
        coalesce(pen.total_penalties, 0),
        round(round(coalesce(att.total_minutes, 0) / 60.0 * coalesce(t.hourly_rate, 0), 2) - coalesce(pen.total_penalties, 0), 2)
    from public.teachers t
    left join (
        select a.teacher_id,
               count(*)::integer as session_count,
               coalesce(sum(coalesce(a.actual_duration_minutes, c.duration_minutes, 0)), 0)::integer as total_minutes
        from public.attendance a
        join public.classes c on c.id = a.class_id
        where a.status = 'present' and a.updated_at >= v_month_start
        group by a.teacher_id
    ) att on att.teacher_id = t.id
    left join (
        select tp.teacher_id, sum(tp.amount) as total_penalties
        from public.teacher_penalties tp
        where tp.created_at >= v_month_start
        group by tp.teacher_id
    ) pen on pen.teacher_id = t.id
    order by t.full_name;
end;
$$;

-- 6) sync_teacher_dues_expenses: صف واحد لكل معلم لكل شهر، Upsert تلقائي
create or replace function public.sync_teacher_dues_expenses(p_manager_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_month_start timestamptz;
    v_teacher record;
    v_total_amount numeric;
    v_total_penalties numeric;
    v_net numeric;
    v_existing_id uuid;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    for v_teacher in select id, hourly_rate from public.teachers loop
        select round(coalesce(sum(coalesce(a.actual_duration_minutes, c.duration_minutes, 0)), 0) / 60.0 * coalesce(v_teacher.hourly_rate, 0), 2)
        into v_total_amount
        from public.attendance a
        join public.classes c on c.id = a.class_id
        where a.teacher_id = v_teacher.id
          and a.status = 'present'
          and a.updated_at >= v_month_start;

        select coalesce(sum(tp.amount), 0) into v_total_penalties
        from public.teacher_penalties tp
        where tp.teacher_id = v_teacher.id
          and tp.created_at >= v_month_start;

        v_net := round(coalesce(v_total_amount, 0) - v_total_penalties, 2);

        select id into v_existing_id
        from public.transactions
        where teacher_id = v_teacher.id
          and type = 'teacher_salary'
          and source = 'auto_teacher_dues'
          and created_at >= v_month_start
        limit 1;

        if v_net > 0 then
            if v_existing_id is not null then
                update public.transactions set amount = v_net where id = v_existing_id;
            else
                insert into public.transactions (type, amount, teacher_id, recorded_by, source)
                values ('teacher_salary', v_net, v_teacher.id, p_manager_id, 'auto_teacher_dues');
            end if;
        elsif v_existing_id is not null then
            delete from public.transactions where id = v_existing_id;
        end if;
    end loop;
end;
$$;

revoke all on function public.list_teacher_dues_for_manager(uuid) from public;
grant execute on function public.list_teacher_dues_for_manager(uuid) to anon;

revoke all on function public.sync_teacher_dues_expenses(uuid) from public;
grant execute on function public.sync_teacher_dues_expenses(uuid) to anon;
