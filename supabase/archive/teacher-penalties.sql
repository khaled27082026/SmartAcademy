create table if not exists public.teacher_penalties (
    id uuid primary key default gen_random_uuid(),
    teacher_id uuid not null references public.teachers(id) on delete cascade,
    supervisor_id uuid references public.supervisors(id) on delete set null,
    amount numeric not null check (amount >= 0),
    reason text not null,
    created_at timestamptz not null default now()
);

create index if not exists teacher_penalties_teacher_id_idx on public.teacher_penalties(teacher_id);

alter table public.teacher_penalties enable row level security;

-- تسجيل خصم/تنبيه جديد — أي مشرف صالح يقدر يسجّل خصم على أي معلم (مش بس
-- معلميه هو)، عشان يبقى في شفافية كاملة بين كل المشرفين على المنصة.
create or replace function public.create_teacher_penalty(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_amount numeric,
    p_reason text
)
returns table (
    id uuid,
    teacher_id uuid,
    supervisor_id uuid,
    amount numeric,
    reason text,
    created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if not exists (select 1 from public.teachers t where t.id = p_teacher_id) then
        raise exception 'teacher_not_found';
    end if;

    return query
    insert into public.teacher_penalties (teacher_id, supervisor_id, amount, reason)
    values (p_teacher_id, p_supervisor_id, p_amount, p_reason)
    returning teacher_penalties.id, teacher_penalties.teacher_id, teacher_penalties.supervisor_id,
              teacher_penalties.amount, teacher_penalties.reason, teacher_penalties.created_at;
end;
$$;

revoke all on function public.create_teacher_penalty(uuid, uuid, numeric, text) from public;
grant execute on function public.create_teacher_penalty(uuid, uuid, numeric, text) to anon;

-- سجل الخصومات كامل — مرئي لأي مشرف صالح (مش بس اللي سجّله)، عشان الشفافية
-- بين كل المشرفين. لو p_teacher_id اتبعت بيرجع خصومات معلم واحد بس.
create or replace function public.list_teacher_penalties(
    p_supervisor_id uuid,
    p_teacher_id uuid default null
)
returns table (
    id uuid,
    teacher_name text,
    supervisor_name text,
    amount numeric,
    reason text,
    created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select tp.id, t.full_name, s.name, tp.amount, tp.reason, tp.created_at
    from public.teacher_penalties tp
    join public.teachers t on t.id = tp.teacher_id
    left join public.supervisors s on s.id = tp.supervisor_id
    where p_teacher_id is null or tp.teacher_id = p_teacher_id
    order by tp.created_at desc;
end;
$$;

revoke all on function public.list_teacher_penalties(uuid, uuid) from public;
grant execute on function public.list_teacher_penalties(uuid, uuid) to anon;

-- خصومات المعلم بتاعته هو بس، للعرض في لوحته الخاصة — بدون الحاجة لصلاحية
-- مشرف، نفس نمط get_teacher_monthly_earnings اللي بياخد رقم هاتف المعلم مباشرة.
create or replace function public.list_teacher_penalties_for_teacher(p_teacher_phone text)
returns table (
    id uuid,
    amount numeric,
    reason text,
    created_at timestamptz,
    supervisor_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_teacher_id uuid;
begin
    select teachers.id into v_teacher_id from public.teachers where phone = p_teacher_phone;
    if v_teacher_id is null then
        return;
    end if;

    return query
    select tp.id, tp.amount, tp.reason, tp.created_at, s.name
    from public.teacher_penalties tp
    left join public.supervisors s on s.id = tp.supervisor_id
    where tp.teacher_id = v_teacher_id
    order by tp.created_at desc;
end;
$$;

revoke all on function public.list_teacher_penalties_for_teacher(text) from public;
grant execute on function public.list_teacher_penalties_for_teacher(text) to anon;

-- نسخة محدّثة من مستحقات المعلم الشهرية: بتخصم إجمالي خصومات نفس الشهر
-- (بتوقيت دبي، زي باقي الحسابات الشهرية في المنصة) من إجمالي الساعات×السعر،
-- وترجع "الصافي النهائي". لازم drop قبل الإنشاء لأن شكل الإرجاع (الأعمدة)
-- اتغيّر عن النسخة القديمة، وPostgres مابيسمحش بـcreate or replace وحده
-- في الحالة دي.
drop function if exists public.get_teacher_monthly_earnings(text);

create function public.get_teacher_monthly_earnings(p_teacher_phone text)
returns table (
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
    v_teacher_id uuid;
    v_hourly_rate numeric;
    v_month_start timestamptz;
    v_session_count integer;
    v_total_minutes integer;
    v_total_amount numeric;
    v_total_penalties numeric;
begin
    select teachers.id, teachers.hourly_rate into v_teacher_id, v_hourly_rate
    from public.teachers where phone = p_teacher_phone;

    if v_teacher_id is null then
        return;
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    select
        count(*)::integer,
        coalesce(sum(coalesce(a.actual_duration_minutes, c.duration_minutes, 0)), 0)::integer
    into v_session_count, v_total_minutes
    from public.attendance a
    join public.classes c on c.id = a.class_id
    where a.teacher_id = v_teacher_id
      and a.status = 'present'
      and a.updated_at >= v_month_start;

    v_total_amount := round(coalesce(v_total_minutes, 0) / 60.0 * coalesce(v_hourly_rate, 0), 2);

    select coalesce(sum(tp.amount), 0) into v_total_penalties
    from public.teacher_penalties tp
    where tp.teacher_id = v_teacher_id
      and tp.created_at >= v_month_start;

    return query
    select
        v_session_count,
        v_total_minutes,
        v_hourly_rate,
        v_total_amount,
        v_total_penalties,
        round(v_total_amount - v_total_penalties, 2);
end;
$$;

revoke all on function public.get_teacher_monthly_earnings(text) from public;
grant execute on function public.get_teacher_monthly_earnings(text) to anon;
