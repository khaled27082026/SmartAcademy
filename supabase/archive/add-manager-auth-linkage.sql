-- ============================================================
-- ربط صلاحيات المدير بجلسات Supabase Auth الحقيقية (auth.uid()) بدل
-- الاعتماد على معرّف يرسله العميل فقط. آمن التكرار بالكامل.
--
-- الخطوات المطلوبة بالترتيب:
-- 1) شغّل هذا الملف كاملاً في Supabase SQL Editor.
-- 2) شغّل سكريبت الترحيل (مرة واحدة، من جهازك خارج المتصفح):
--    supabase/migrate-managers-to-auth.mjs — يربط كل حساب مدير حالي
--    بحساب Supabase Auth حقيقي (يحتاج service_role key، لازم يتشغّل
--    محليًا عندك، مش من هنا).
-- 3) بعد الترحيل، تسجيل دخول المدير من admin-login.html يستخدم تلقائيًا
--    Supabase Auth (لا حاجة لأي تعديل إضافي — الكود بالفعل محدّث).
-- ============================================================

-- 1) عمود الربط بحساب Supabase Auth
alter table public.managers add column if not exists auth_user_id uuid unique references auth.users(id) on delete set null;

-- 2) دالة جلب بيانات المدير الحالي عبر auth.uid() (تُستدعى بعد تسجيل الدخول)
create or replace function public.get_current_manager()
returns table (id uuid, name text)
language sql
security definer
set search_path = public
as $$
    select m.id, m.name
    from public.managers m
    where m.auth_user_id = auth.uid()
    limit 1;
$$;

revoke all on function public.get_current_manager() from public;
grant execute on function public.get_current_manager() to authenticated;

-- 3) تحديث كل دوال المدير لتتحقق من auth.uid() بجانب المعرّف المُرسل

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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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

create or replace function public.list_supervisors(p_manager_id uuid)
returns table (id uuid, name text, phone text, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    return query
    select s.id, s.name, s.phone, s.email, s.created_at
    from public.supervisors s
    order by s.created_at desc;
end;
$$;

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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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

create or replace function public.delete_supervisor(p_manager_id uuid, p_supervisor_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    delete from public.supervisors where id = p_supervisor_id;
    return found;
end;
$$;

-- ============================================================
-- 3) إدارة المعلمين (بواسطة المشرف)
-- ============================================================

create or replace function public.list_attendance_overview_for_manager(p_manager_id uuid)
returns table (
    student_name text,
    teacher_name text,
    subject text,
    day text,
    "time" text,
    duration_minutes integer,
    actual_duration_minutes integer,
    status text,
    updated_at timestamptz,
    amount numeric,
    payment_status text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_month_start timestamptz;
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    return query
    select
        s.full_name,
        t.full_name,
        c.subject,
        c.day,
        c.time,
        c.duration_minutes,
        a.actual_duration_minutes,
        a.status,
        a.updated_at,
        case
            when a.status = 'present' and s.session_price is not null then s.session_price
            else null
        end,
        case
            when a.status = 'present' and s.session_price is not null then
                case
                    when exists (
                        select 1 from public.transactions t2
                        where t2.student_id = s.id and t2.type = 'subscription' and t2.created_at >= v_month_start
                    ) then 'paid'
                    else 'overdue'
                end
            else null
        end
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    join public.students s on s.id = c.student_id
    left join public.attendance a on a.class_id = c.id
    order by
        case c.day
            when 'السبت' then 0
            when 'الأحد' then 1
            when 'الاثنين' then 2
            when 'الثلاثاء' then 3
            when 'الأربعاء' then 4
            when 'الخميس' then 5
            when 'الجمعة' then 6
            else 7
        end,
        c.time;
end;
$$;

-- ============================================================
-- 7) المستحقات المالية الفردية (معلم / طالب)
-- ============================================================

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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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

drop function if exists public.get_financial_kpis(uuid);

-- ملاحظة: p_date_from/p_date_to (تاريخ ميلادي بسيط) هي نفس نطاق الفلتر
-- الزمني في "جدول المتابعة الشامل" بلوحة المدير — أصبح هو الفلتر الزمني
-- العام لكل بطاقات ومؤشرات هذا القسم. لو الاثنان null (خيار "الكل")
-- يرجع إجمالي كل التاريخ بدون مقارنة بفترة سابقة (لا توجد فترة سابقة
-- طبيعية لمقارنة "كل الوقت" بها). لو الفترة محددة، تتم المقارنة تلقائيًا
-- بفترة سابقة بنفس طول الفترة المختارة (نفس أسلوب Stripe/المنصات المالية).

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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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

    -- ملاحظة: مستحقات المعلمين المُولّدة تلقائيًا (source = 'auto_teacher_dues')
    -- مسجّلة بالجنيه المصري وليس الدرهم، فبتتستبعد من هذا الإجمالي لمنع خلط
    -- عملتين في رقم واحد. تظهر بطاقتها الخاصة "مستحقات المعلمين" في الواجهة.
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

drop function if exists public.get_monthly_financial_trend(uuid, integer);

-- p_end_month_start (اختياري): إن حُدّد، يصبح هو آخر شهر معروض في
-- الاتجاه (بدل الشهر الحالي دايمًا) — يُستخدم لمزامنة الجراف مع النطاق
-- الزمني العام (فلتر "جدول المتابعة الشامل") لما يكون النطاق المختار
-- منتهيًا في شهر غير الشهر الحالي (مثلاً "الشهر الماضي").

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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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

-- ============================================================
-- 9.1) مستحقات المعلمين (بطاقة "مستحقات المعلمين" بلوحة المدير) —
-- نفس منطق get_teacher_monthly_earnings لكن لكل المعلمين دفعة واحدة،
-- ومزامنة تلقائية لسجل المعاملات المالية (صف واحد لكل معلم لكل شهر،
-- source = 'auto_teacher_dues'، بالجنيه المصري كما هو، بدون تحويل عملة).
-- ============================================================

drop function if exists public.list_teacher_dues_for_manager(uuid);

-- p_date_from/p_date_to: نفس نطاق الفلتر الزمني العام. null في الاثنين
-- يعني "كل الوقت" (بدون قيد تاريخ).

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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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

revoke all on function public.list_teacher_dues_for_manager(uuid, date, date) from public;
grant execute on function public.list_teacher_dues_for_manager(uuid, date, date) to anon;

revoke all on function public.sync_teacher_dues_expenses(uuid) from public;
grant execute on function public.sync_teacher_dues_expenses(uuid) to anon;

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
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
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

create or replace function public.list_all_students(p_manager_id uuid)
returns table (id uuid, full_name text, phone text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    return query
    select s.id, s.full_name, s.phone from public.students s order by s.full_name;
end;
$$;

create or replace function public.list_all_teachers(p_manager_id uuid)
returns table (id uuid, full_name text, phone text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    return query
    select t.id, t.full_name, t.phone from public.teachers t order by t.full_name;
end;
$$;

-- ============================================================
-- 10) بطاقات لوحة التحكم الشاملة (الطلاب المشتركون + حصص اليوم)
-- ============================================================

create or replace function public.list_students_basic(p_manager_id uuid)
returns table (
    id uuid,
    full_name text,
    phone text,
    stage text,
    created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    return query
    select s.id, s.full_name, s.phone, s.stage, s.created_at
    from public.students s
    order by s.full_name;
end;
$$;

create or replace function public.list_today_classes(p_manager_id uuid, p_day text)
returns table (
    id uuid,
    "day" text,
    "time" text,
    subject text,
    link text,
    student_name text,
    student_phone text,
    teacher_name text
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

    return query
    select c.id, c.day, c.time, c.subject, c.link,
           s.full_name, s.phone, t.full_name
    from public.classes c
    left join public.students s on s.id = c.student_id
    left join public.teachers t on t.id = c.teacher_id
    where c.day = p_day;
end;
$$;
