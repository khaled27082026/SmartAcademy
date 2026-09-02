-- ============================================================
-- Smart Academy — جدول المديرين (Managers) + دالة التحقق من الدخول
-- ملف مستقل تمامًا عن supabase/schema.sql — ما يلمسش ولا يعدّل أي جدول
-- موجود (students / teachers / classes / ratings) ولا أي سياسة RLS
-- بتاعتهم خالص. شغّله زي ما هو مرة واحدة في: Supabase Dashboard →
-- SQL Editor → New query → Run.
-- ============================================================

create extension if not exists "pgcrypto";

-- -------------------- جدول المديرين --------------------
create table if not exists public.managers (
    id uuid primary key default gen_random_uuid(),
    name text,
    phone text unique not null,
    password text not null,
    created_at timestamptz not null default now()
);

-- -------------------- Row Level Security --------------------
-- ⚠️ مهم: بعكس باقي الجداول، الجدول ده مالوش ولا سياسة RLS واحدة تسمح
-- بالقراءة أو الكتابة المباشرة عبر الـ anon key — يعني حتى لو حد معاه
-- الـ anon/publishable key (وهو مفتاح عام مكشوف في كود الواجهة أصلاً)،
-- مش هيقدر يعمل SELECT ولا INSERT ولا UPDATE على جدول المديرين مباشرة
-- خالص. الوصول الوحيد المسموح هو عبر دالة verify_manager_login تحت،
-- اللي بترجع الـ id والاسم بس لو رقم الهاتف وكلمة المرور مطابقين تمامًا
-- (مش بترجع كلمة المرور نفسها، ومفيش طريقة تسرد بيها كل المديرين). ده
-- أعلى مستوى حماية ممكن نوصله من غير Supabase Authentication حقيقي.
alter table public.managers enable row level security;
-- (تعمّدنا عدم إضافة أي CREATE POLICY هنا — الافتراضي هو رفض كل شيء)

-- -------------------- دالة التحقق من دخول المدير --------------------
-- SECURITY DEFINER يخليها تشتغل بصلاحيات مالك الدالة (بتتجاوز RLS داخليًا
-- بس هي نفسها)، وبتترجع بس id + name عند التطابق، من غير ما تكشف عمود
-- password أبدًا ولا تسمح بجلب أي صف تاني.
create or replace function public.verify_manager_login(p_phone text, p_password text)
returns table (id uuid, name text)
language sql
security definer
set search_path = public
as $$
    select m.id, m.name
    from public.managers m
    where m.phone = p_phone and m.password = p_password
    limit 1;
$$;

revoke all on function public.verify_manager_login(text, text) from public;
grant execute on function public.verify_manager_login(text, text) to anon;

-- -------------------- الحساب الافتراضي الأولي --------------------
-- نفس بيانات الدخول الافتراضية اللي كانت مكتوبة (Hardcoded) قبل كده في
-- admin-login.html، عشان الاستمرارية ومفيش حد يتفاجئ بحساب جديد. غيّرها
-- من نفس الجدول (UPDATE) بعد أول دخول لو حابب.
insert into public.managers (name, phone, password)
values ('Omar', '01012345678', '123456')
on conflict (phone) do nothing;