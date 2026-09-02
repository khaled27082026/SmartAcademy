-- ============================================================
-- تحويل فلتر التاريخ في "جدول المتابعة الشامل" إلى الفلتر الزمني العام
-- لبوابة البيانات والشؤون المالية بلوحة المدير: مؤشرات الإيرادات
-- والمصروفات وصافي الأرباح، جراف "تطور الأرباح والإيرادات"، وبطاقة
-- "مستحقات المعلمين" — الثلاثة بقوا يقبلوا نطاق تاريخ (p_date_from/
-- p_date_to) بدل قيم ثابتة (الشهر الحالي / آخر N شهر من الآن).
--
-- ملاحظة: "حالة اشتراكات الطلاب" (مدفوع هذا الشهر / متأخر) و"مزامنة
-- مستحقات المعلمين مع سجل المصروفات" (sync_teacher_dues_expenses)
-- عمدًا لم يتغيّرا — الأول مفهوم شهري ثابت بطبيعته (مش تقرير)، والثاني
-- عملية محاسبية حقيقية (تسجيل راتب الشهر الحالي) يخطر تكرارها بمجرد
-- تصفّح فلتر تاريخ مختلف. آمن التكرار بالكامل.
-- ============================================================

-- 1) get_financial_kpis: نطاق تاريخ بدل "الشهر الحالي/السابق" الثابتين،
--    مع مقارنة تلقائية بفترة سابقة بنفس طول الفترة المختارة.
drop function if exists public.get_financial_kpis(uuid);

create or replace function public.get_financial_kpis(p_manager_id uuid, p_date_from date default null, p_date_to date default null)
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
    v_from timestamptz;
    v_to timestamptz;
    v_prev_from timestamptz;
    v_prev_to timestamptz;
    v_period_len interval;
    v_cur_revenue numeric;
    v_prev_revenue numeric;
    v_cur_expenses numeric;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    if p_date_from is not null then
        v_from := (p_date_from::timestamp) at time zone 'Asia/Dubai';
    end if;
    if p_date_to is not null then
        v_to := ((p_date_to + 1)::timestamp) at time zone 'Asia/Dubai';
    end if;

    select coalesce(sum(transactions.amount), 0) into v_cur_revenue
    from public.transactions
    where transactions.type = 'subscription'
      and (v_from is null or transactions.created_at >= v_from)
      and (v_to is null or transactions.created_at < v_to);

    select coalesce(sum(transactions.amount), 0) into v_cur_expenses
    from public.transactions
    where transactions.type in ('teacher_salary', 'supervisor_salary', 'advertising')
      and transactions.source is distinct from 'auto_teacher_dues'
      and (v_from is null or transactions.created_at >= v_from)
      and (v_to is null or transactions.created_at < v_to);

    if v_from is not null and v_to is not null then
        v_period_len := v_to - v_from;
        v_prev_to := v_from;
        v_prev_from := v_from - v_period_len;

        select coalesce(sum(transactions.amount), 0) into v_prev_revenue
        from public.transactions
        where transactions.type = 'subscription'
          and transactions.created_at >= v_prev_from
          and transactions.created_at < v_prev_to;
    else
        v_prev_revenue := null;
    end if;

    return query
    select
        v_cur_revenue,
        v_prev_revenue,
        case when v_prev_revenue is not null and v_prev_revenue > 0
            then round((v_cur_revenue - v_prev_revenue) / v_prev_revenue * 100, 1)
            else null
        end,
        v_cur_expenses,
        round(v_cur_revenue - v_cur_expenses, 2),
        (select count(*)::integer from public.students),
        (select count(*)::integer from public.teachers);
end;
$$;

revoke all on function public.get_financial_kpis(uuid, date, date) from public;
grant execute on function public.get_financial_kpis(uuid, date, date) to anon;

-- 2) get_monthly_financial_trend: إمكانية تثبيت آخر شهر معروض
--    (p_end_month_start) بدل الشهر الحالي دايمًا.
drop function if exists public.get_monthly_financial_trend(uuid, integer);

create or replace function public.get_monthly_financial_trend(p_manager_id uuid, p_months_back integer default 6, p_end_month_start date default null)
returns table (
    month_start timestamptz,
    revenue numeric,
    expenses numeric,
    profit numeric,
    teacher_dues_egp numeric
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

    if p_end_month_start is not null then
        v_current_month_dubai := date_trunc('month', p_end_month_start::timestamp);
    else
        v_current_month_dubai := date_trunc('month', now() at time zone 'Asia/Dubai');
    end if;

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
            - coalesce(sum(t.amount) filter (where t.type in ('teacher_salary', 'supervisor_salary', 'advertising') and t.source is distinct from 'auto_teacher_dues'), 0),
        coalesce(sum(t.amount) filter (where t.source = 'auto_teacher_dues'), 0)
    from bounds
    left join public.transactions t
      on t.created_at >= bounds.m_start_utc and t.created_at < bounds.m_end_utc
    group by bounds.m_start_utc, bounds.m_end_utc
    order by bounds.m_start_utc;
end;
$$;

revoke all on function public.get_monthly_financial_trend(uuid, integer, date) from public;
grant execute on function public.get_monthly_financial_trend(uuid, integer, date) to anon;

-- 3) list_teacher_dues_for_manager: نطاق تاريخ بدل "الشهر الحالي" الثابت.
drop function if exists public.list_teacher_dues_for_manager(uuid);

create or replace function public.list_teacher_dues_for_manager(p_manager_id uuid, p_date_from date default null, p_date_to date default null)
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
    v_from timestamptz;
    v_to timestamptz;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id) then
        raise exception 'unauthorized';
    end if;

    if p_date_from is not null then
        v_from := (p_date_from::timestamp) at time zone 'Asia/Dubai';
    end if;
    if p_date_to is not null then
        v_to := ((p_date_to + 1)::timestamp) at time zone 'Asia/Dubai';
    end if;

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
        where a.status = 'present'
          and (v_from is null or a.updated_at >= v_from)
          and (v_to is null or a.updated_at < v_to)
        group by a.teacher_id
    ) att on att.teacher_id = t.id
    left join (
        select tp.teacher_id, sum(tp.amount) as total_penalties
        from public.teacher_penalties tp
        where (v_from is null or tp.created_at >= v_from)
          and (v_to is null or tp.created_at < v_to)
        group by tp.teacher_id
    ) pen on pen.teacher_id = t.id
    order by t.full_name;
end;
$$;

revoke all on function public.list_teacher_dues_for_manager(uuid, date, date) from public;
grant execute on function public.list_teacher_dues_for_manager(uuid, date, date) to anon;
