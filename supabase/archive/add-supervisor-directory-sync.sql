-- ============================================================
-- مزامنة حقيقية لقوائم الطلاب/المعلمين وموادهم وتقارير المتابعة
-- ============================================================
-- المشكلة: صفحتَي إدارة الطلاب والمعلمين (لوحة المشرف) كانتا تعرضان
-- القائمة من localStorage فقط، بدون أي دالة تجيبها من Supabase — فلو
-- المشرف بدّل جهاز أو مسح بيانات المتصفح، كانت القائمة تختفي بالكامل
-- رغم وجود البيانات فعليًا في القاعدة. المواد الدراسية لكل طالب/معلم
-- وتقارير متابعة الطالب لم تكن مخزَّنة في Supabase أصلاً (محلية بحتة).
-- ============================================================

alter table public.students add column if not exists subjects text[] not null default '{}';
alter table public.teachers add column if not exists subjects text[] not null default '{}';

create table if not exists public.student_reports (
    id uuid primary key default gen_random_uuid(),
    student_id uuid not null references public.students(id) on delete cascade,
    supervisor_id uuid references public.supervisors(id) on delete set null,
    text text not null,
    created_at timestamptz not null default now()
);

create index if not exists student_reports_student_idx on public.student_reports(student_id, created_at desc);

alter table public.student_reports enable row level security;

-- -------------------- قوائم كاملة لصفحات المشرف --------------------

create or replace function public.list_students(p_supervisor_id uuid)
returns table (
    id uuid, full_name text, phone text, parent_phone text, stage text,
    session_price numeric, subjects text[], created_at timestamptz
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
    select st.id, st.full_name, st.phone, st.parent_phone, st.stage,
           st.session_price, st.subjects, st.created_at
    from public.students st
    where st.supervisor_id = p_supervisor_id
    order by st.created_at desc;
end;
$$;

create or replace function public.list_teachers_full(p_supervisor_id uuid)
returns table (
    id uuid, full_name text, phone text, email text, hourly_rate numeric,
    subjects text[], created_at timestamptz
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
    select t.id, t.full_name, t.phone, t.email, t.hourly_rate, t.subjects, t.created_at
    from public.teachers t
    where t.supervisor_id = p_supervisor_id
    order by t.created_at desc;
end;
$$;

-- -------------------- المواد الدراسية --------------------

create or replace function public.set_student_subjects(p_supervisor_id uuid, p_student_id uuid, p_subjects text[])
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.students st
        join public.supervisors s on s.id = st.supervisor_id
        where st.id = p_student_id and s.id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
    end if;

    update public.students set subjects = coalesce(p_subjects, '{}') where id = p_student_id;
    return true;
end;
$$;

create or replace function public.set_teacher_subjects(p_supervisor_id uuid, p_teacher_id uuid, p_subjects text[])
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.teachers t
        join public.supervisors s on s.id = t.supervisor_id
        where t.id = p_teacher_id and s.id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
    end if;

    update public.teachers set subjects = coalesce(p_subjects, '{}') where id = p_teacher_id;
    return true;
end;
$$;

-- -------------------- تقارير متابعة الطالب --------------------

create or replace function public.list_student_reports(p_supervisor_id uuid, p_student_id uuid)
returns table (id uuid, text text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.students st
        join public.supervisors s on s.id = st.supervisor_id
        where st.id = p_student_id and s.id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
    end if;

    return query
    select r.id, r.text, r.created_at
    from public.student_reports r
    where r.student_id = p_student_id
    order by r.created_at desc;
end;
$$;

create or replace function public.add_student_report(p_supervisor_id uuid, p_student_id uuid, p_text text)
returns table (id uuid, text text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.students st
        join public.supervisors s on s.id = st.supervisor_id
        where st.id = p_student_id and s.id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
    end if;

    if coalesce(trim(p_text), '') = '' then
        raise exception 'empty_text';
    end if;

    return query
    insert into public.student_reports (student_id, supervisor_id, text)
    values (p_student_id, p_supervisor_id, p_text)
    returning student_reports.id, student_reports.text, student_reports.created_at;
end;
$$;

create or replace function public.delete_student_report(p_supervisor_id uuid, p_report_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from public.student_reports r
    using public.students st
    where r.id = p_report_id
      and r.student_id = st.id
      and st.supervisor_id = p_supervisor_id;

    return found;
end;
$$;

-- -------------------- الصلاحيات --------------------

revoke all on function public.list_students(uuid) from public;
grant execute on function public.list_students(uuid) to anon;

revoke all on function public.list_teachers_full(uuid) from public;
grant execute on function public.list_teachers_full(uuid) to anon;

revoke all on function public.set_student_subjects(uuid, uuid, text[]) from public;
grant execute on function public.set_student_subjects(uuid, uuid, text[]) to anon;

revoke all on function public.set_teacher_subjects(uuid, uuid, text[]) from public;
grant execute on function public.set_teacher_subjects(uuid, uuid, text[]) to anon;

revoke all on function public.list_student_reports(uuid, uuid) from public;
grant execute on function public.list_student_reports(uuid, uuid) to anon;

revoke all on function public.add_student_report(uuid, uuid, text) from public;
grant execute on function public.add_student_report(uuid, uuid, text) to anon;

revoke all on function public.delete_student_report(uuid, uuid) from public;
grant execute on function public.delete_student_report(uuid, uuid) to anon;
