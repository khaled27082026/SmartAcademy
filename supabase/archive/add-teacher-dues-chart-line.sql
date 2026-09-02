-- ============================================================
-- إضافة خط "مستحقات المعلمين (ج.م)" كخط منفصل في رسم "تطور الأرباح
-- والإيرادات" بلوحة المدير — بدون دمجه في إجمالي المصروفات أو صافي
-- الأرباح (تلك الأرقام بالدرهم فقط، ودمج عملتين في رقم واحد بيدي رقم
-- خاطئ ماليًا). آمن التكرار.
-- ============================================================

drop function if exists public.get_monthly_financial_trend(uuid, integer);

create or replace function public.get_monthly_financial_trend(p_manager_id uuid, p_months_back integer default 6)
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
            - coalesce(sum(t.amount) filter (where t.type in ('teacher_salary', 'supervisor_salary', 'advertising') and t.source is distinct from 'auto_teacher_dues'), 0),
        coalesce(sum(t.amount) filter (where t.source = 'auto_teacher_dues'), 0)
    from bounds
    left join public.transactions t
      on t.created_at >= bounds.m_start_utc and t.created_at < bounds.m_end_utc
    group by bounds.m_start_utc, bounds.m_end_utc
    order by bounds.m_start_utc;
end;
$$;

revoke all on function public.get_monthly_financial_trend(uuid, integer) from public;
grant execute on function public.get_monthly_financial_trend(uuid, integer) to anon;
