-- تحقق من كل القيم الحالية الموجودة فعلاً في عمود type
select type, count(*) from public.transactions group by type;

-- ترحيل أي قيم قديمة متبقية للقيم الجديدة
update public.transactions set type = 'teacher_salary' where type = 'salary';
update public.transactions set type = 'advertising' where type = 'expense';

-- تحقق تاني بعد الترحيل (لازم تبقى كل القيم من ضمن الأربعة المسموحة فقط)
select type, count(*) from public.transactions group by type;

-- حذف أي قيد CHECK قديم على عمود type أياً كان اسمه
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

alter table public.transactions add constraint transactions_type_check
    check (type in ('subscription', 'teacher_salary', 'supervisor_salary', 'advertising'));

-- تأكيد نهائي إن القيد اتحدث صح
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.transactions'::regclass
  and contype = 'c';
