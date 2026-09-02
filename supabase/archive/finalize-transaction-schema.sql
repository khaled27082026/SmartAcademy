-- ============================================================
-- تصحيح نهائي وشامل لجدول transactions ودوال المعاملات المالية
-- آمن للتشغيل أكثر من مرة (Idempotent)
-- ============================================================

-- 1) إسقاط أي قيود Check قديمة على عمود type أياً كان اسمها
do $$
declare
    r record;
begin
    for r in
        select conname
        from pg_constraint
        where conrelid = 'public.transactions'::regclass
          and contype = 'c'
          and pg_get_constraintdef(oid) ilike '%type%'
    loop
        execute format('alter table public.transactions drop constraint %I', r.conname);
    end loop;
end $$;

-- 2) تطهير كل الصفوف القديمة لتتوافق مع القيم الجديدة فقط
update public.transactions set type = 'teacher_salary' where type = 'salary';
update public.transactions set type = 'advertising' where type = 'expense';

-- أي قيمة غريبة متبقية غير معروفة (لو وجدت) تتحول لـ advertising كإجراء أمان،
-- وتُعرض في النتيجة التالية عشان تراجعها بعينك
update public.transactions
set type = 'advertising'
where type not in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising');

select id, type, amount, created_at
from public.transactions
where type not in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising');

-- 3) التأكد من وجود عمود supervisor_id (يُستخدم في راتب المشرف)
alter table public.transactions add column if not exists supervisor_id uuid references public.supervisors(id) on delete set null;

-- 4) حذف عمودي payment_method و description تماماً
alter table public.transactions drop column if exists payment_method;
alter table public.transactions drop column if exists description;

-- 5) تطبيق قيد التحقق الجديد على الأنواع الأربعة فقط
alter table public.transactions add constraint transactions_type_check
    check (type in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising'));

-- 6) إعادة إنشاء الدوال المرتبطة بالشكل النهائي المبسّط (بدون payment_method/description)
drop function if exists public.create_transaction(uuid, text, numeric, text, text, uuid, uuid, uuid);
drop function if exists public.create_transaction(uuid, text, numeric, text, text, uuid, uuid);
drop function if exists public.create_transaction(uuid, text, numeric, uuid, uuid, uuid);
drop function if exists public.list_transactions(uuid, integer);

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

-- 7) تحقق نهائي: تعريف القيد الحالي + شكل الجدول
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.transactions'::regclass
  and contype = 'c';

select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'transactions'
order by ordinal_position;
