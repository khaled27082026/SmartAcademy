-- ============================================================
-- Smart Academy — functions.sql
-- ============================================================
-- كل الدوال (RPCs) المستخدمة فعليًا في الواجهة الأمامية، مجمّعة حسب
-- الموضوع. يجب تشغيل main-schema.sql قبل الملف ده (الدوال بتشير لجداول
-- لازم تكون موجودة أصلاً). الصلاحيات (GRANT/REVOKE) موجودة في policies.sql
-- اللي بيتشغّل بعد الملف ده.
-- ============================================================

-- ============================================================
-- 1) تسجيل الدخول (Auth)
-- ============================================================

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

-- ترجع بيانات المدير المرتبط بجلسة Supabase Auth الحالية (auth.uid())،
-- بدل الاعتماد على معرّف يرسله العميل. تُستدعى فور تسجيل الدخول عبر
-- Supabase Auth لجلب بروفايل المدير الحقيقي المرتبط بهذا الحساب الموثّق.
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

create or replace function public.verify_supervisor_login(p_phone text, p_password text)
returns table (id uuid, name text)
language sql
security definer
set search_path = public
as $$
    select s.id, s.name
    from public.supervisors s
    where s.phone = p_phone and s.password = p_password
    limit 1;
$$;

-- تسجيل دخول الطالب — يتحقق من رقم الهاتف وكلمة المرور ضد جدول students
-- الحقيقي في Supabase بدل الاعتماد على نسخة localStorage المحلية، عشان
-- الطالب يقدر يدخل من أي جهاز.
create or replace function public.verify_student_login(p_phone text, p_password text)
returns table (
    id uuid,
    full_name text,
    phone text,
    stage text,
    parent_phone text,
    session_price numeric
)
language sql
security definer
set search_path = public
as $$
    select st.id, st.full_name, st.phone, st.stage, st.parent_phone, st.session_price
    from public.students st
    where st.phone = p_phone and st.password = p_password
    limit 1;
$$;

-- تسجيل دخول المعلم — نفس الفكرة بالظبط، ضد جدول teachers الحقيقي.
create or replace function public.verify_teacher_login(p_phone text, p_password text)
returns table (
    id uuid,
    full_name text,
    phone text,
    email text,
    subject text,
    hourly_rate numeric
)
language sql
security definer
set search_path = public
as $$
    select t.id, t.full_name, t.phone, t.email, t.subject, t.hourly_rate
    from public.teachers t
    where t.phone = p_phone and t.password = p_password
    limit 1;
$$;

-- ============================================================
-- 2) إدارة المشرفين (بواسطة المدير)
-- ============================================================

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

create or replace function public.create_teacher(
    p_supervisor_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_subject text,
    p_password text,
    p_hourly_rate numeric default null
)
returns table (id uuid, name text, phone text, email text, subject text, hourly_rate numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.teachers t where t.phone = p_phone) then
        raise exception 'phone_taken';
    end if;

    return query
    insert into public.teachers (full_name, phone, email, subject, password, supervisor_id, hourly_rate)
    values (p_name, p_phone, p_email, p_subject, p_password, p_supervisor_id, p_hourly_rate)
    returning teachers.id, teachers.full_name, teachers.phone, teachers.email, teachers.subject, teachers.hourly_rate, teachers.created_at;
end;
$$;

create or replace function public.update_teacher(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_name text,
    p_phone text,
    p_email text,
    p_subject text,
    p_password text default null,
    p_hourly_rate numeric default null
)
returns table (id uuid, name text, phone text, email text, subject text, hourly_rate numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.teachers t where t.phone = p_phone and t.id <> p_teacher_id) then
        raise exception 'phone_taken';
    end if;

    update public.teachers
    set full_name = p_name,
        phone = p_phone,
        email = p_email,
        subject = p_subject,
        password = coalesce(nullif(p_password, ''), password),
        hourly_rate = p_hourly_rate
    where teachers.id = p_teacher_id;

    return query
    select t.id, t.full_name, t.phone, t.email, t.subject, t.hourly_rate, t.created_at
    from public.teachers t
    where t.id = p_teacher_id;
end;
$$;

create or replace function public.list_teachers(p_supervisor_id uuid)
returns table (id uuid, name text, phone text, subject text)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    return query
    select t.id, t.full_name, t.phone, t.subject
    from public.teachers t
    where t.supervisor_id = p_supervisor_id
    order by t.full_name;
end;
$$;

create or replace function public.get_teacher_name(p_teacher_id uuid)
returns text
language sql
security definer
set search_path = public
as $$
    select full_name from public.teachers where id = p_teacher_id;
$$;

-- ============================================================
-- 4) إدارة الطلاب (بواسطة المشرف)
-- ============================================================

create or replace function public.create_student(
    p_supervisor_id uuid,
    p_name text,
    p_phone text,
    p_parent_phone text,
    p_stage text,
    p_password text,
    p_session_price numeric default null
)
returns table (id uuid, name text, phone text, parent_phone text, stage text, session_price numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.students st where st.phone = p_phone) then
        raise exception 'phone_taken';
    end if;

    return query
    insert into public.students (full_name, phone, parent_phone, stage, password, supervisor_id, session_price)
    values (p_name, p_phone, p_parent_phone, p_stage, p_password, p_supervisor_id, p_session_price)
    returning students.id, students.full_name, students.phone, students.parent_phone, students.stage, students.session_price, students.created_at;
end;
$$;

create or replace function public.update_student(
    p_supervisor_id uuid,
    p_student_id uuid,
    p_name text,
    p_phone text,
    p_parent_phone text,
    p_stage text,
    p_password text default null,
    p_session_price numeric default null
)
returns table (id uuid, name text, phone text, parent_phone text, stage text, session_price numeric, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors s where s.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

    if exists (select 1 from public.students st where st.phone = p_phone and st.id <> p_student_id) then
        raise exception 'phone_taken';
    end if;

    update public.students
    set full_name = p_name,
        phone = p_phone,
        parent_phone = p_parent_phone,
        stage = p_stage,
        password = coalesce(nullif(p_password, ''), password),
        session_price = p_session_price
    where students.id = p_student_id;

    return query
    select st.id, st.full_name, st.phone, st.parent_phone, st.stage, st.session_price, st.created_at
    from public.students st
    where st.id = p_student_id;
end;
$$;

-- ============================================================
-- 4.5) الجدول الأسبوعي (المواعيد)
-- ============================================================
-- classes.is_active/updated_at وقابلية teacher_id لل NULL معرَّفين في
-- main-schema.sql مباشرة (كانوا هنا كـALTER TABLE قبل ما يُدمَجوا هناك).

-- تحفظ جدول طالب معيّن بالكامل (استبدال شامل) — بتستدعيها شاشة "تعديل
-- جدول الطالب" في supervisor-students.html بدل ما تكتب في localStorage.
-- p_sessions: [{day, time, subject, duration, link, teacherId}, ...]
create or replace function public.set_student_sessions(
    p_supervisor_id uuid,
    p_student_id uuid,
    p_sessions jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.students st
        where st.id = p_student_id and st.supervisor_id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes, link, is_active, updated_at)
    select s.teacher_id, p_student_id, s.subject, s.day, s.time, s.duration, s.link, true, now()
    from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text, duration integer, link text, teacher_id uuid)
    where s.teacher_id is not null
    on conflict (teacher_id, day, time, subject)
    do update set
        student_id = excluded.student_id,
        duration_minutes = excluded.duration_minutes,
        link = excluded.link,
        is_active = true,
        updated_at = now();

    update public.classes c
    set is_active = false, updated_at = now()
    where c.student_id = p_student_id
      and c.is_active = true
      and not exists (
          select 1
          from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text, teacher_id uuid)
          where s.teacher_id = c.teacher_id and s.day = c.day and s.time = c.time and s.subject = c.subject
      );

    return true;
end;
$$;

-- نفس الفكرة لجدول المعلم — من supervisor-teachers.html. لا تتعامل مع
-- student_id لأي صف موجود (يُحدَّد الطالب من شاشة الطالب وليس هنا).
-- p_sessions: [{day, time, subject, duration, link}, ...]
create or replace function public.set_teacher_sessions(
    p_supervisor_id uuid,
    p_teacher_id uuid,
    p_sessions jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.teachers t
        where t.id = p_teacher_id and t.supervisor_id = p_supervisor_id
    ) then
        raise exception 'unauthorized';
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes, link, is_active, updated_at)
    select p_teacher_id, null, s.subject, s.day, s.time, s.duration, s.link, true, now()
    from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text, duration integer, link text)
    on conflict (teacher_id, day, time, subject)
    do update set
        duration_minutes = excluded.duration_minutes,
        link = excluded.link,
        is_active = true,
        updated_at = now();

    update public.classes c
    set is_active = false, updated_at = now()
    where c.teacher_id = p_teacher_id
      and c.is_active = true
      and not exists (
          select 1
          from jsonb_to_recordset(p_sessions) as s(day text, time text, subject text)
          where s.day = c.day and s.time = c.time and s.subject = c.subject
      );

    return true;
end;
$$;

-- تجيب جدول طالب معيّن عشان شاشة "تعديل جدول الطالب" تعرض القيم الحالية.
create or replace function public.get_student_sessions_for_manage(p_supervisor_id uuid, p_student_id uuid)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer, teacher_id uuid)
language sql
security definer
set search_path = public
as $$
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes, c.teacher_id
    from public.classes c
    join public.students st on st.id = c.student_id
    where c.student_id = p_student_id
      and c.is_active = true
      and st.supervisor_id = p_supervisor_id;
$$;

-- نفس الفكرة لجدول المعلم.
create or replace function public.get_teacher_sessions_for_manage(p_supervisor_id uuid, p_teacher_id uuid)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer)
language sql
security definer
set search_path = public
as $$
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    where c.teacher_id = p_teacher_id
      and c.is_active = true
      and t.supervisor_id = p_supervisor_id;
$$;

-- تجيب جدول الطالب نفسه من لوحته (student-dashboard.html) — بدل قراءة
-- localStorage. بترجع اسم المعلم لعرضه في الجدول.
create or replace function public.get_student_sessions(p_student_phone text)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer, teacher_id uuid, teacher_name text)
language sql
security definer
set search_path = public
as $$
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes, c.teacher_id, t.full_name
    from public.classes c
    join public.students st on st.id = c.student_id
    left join public.teachers t on t.id = c.teacher_id
    where st.phone = p_student_phone
      and c.is_active = true;
$$;

-- نفس الفكرة للمعلم من لوحته (teacher-dashboard.html) — بترجع اسم الطالب.
create or replace function public.get_teacher_sessions(p_teacher_phone text)
returns table (id uuid, day text, "time" text, subject text, link text, duration_minutes integer, student_id uuid, student_name text, student_phone text)
language sql
security definer
set search_path = public
as $$
    select c.id, c.day, c.time, c.subject, c.link, c.duration_minutes, c.student_id, s.full_name, s.phone
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    left join public.students s on s.id = c.student_id
    where t.phone = p_teacher_phone
      and c.is_active = true;
$$;

-- ============================================================
-- 5) الحصص والتقييمات
-- ============================================================

create or replace function public.sync_class_rating(
    p_teacher_phone text,
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text,
    p_rating smallint,
    p_duration_minutes integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_teacher_id uuid;
    v_student_id uuid;
    v_class_id uuid;
begin
    select id into v_teacher_id from public.teachers where phone = p_teacher_phone;
    if v_teacher_id is null then
        return false;
    end if;

    if p_student_phone is not null then
        select id into v_student_id from public.students where phone = p_student_phone;
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes)
    values (v_teacher_id, v_student_id, p_subject, p_day, p_time, p_duration_minutes)
    on conflict (teacher_id, day, time, subject)
    do update set
        student_id = excluded.student_id,
        duration_minutes = coalesce(excluded.duration_minutes, public.classes.duration_minutes)
    returning id into v_class_id;

    insert into public.ratings (class_id, teacher_id, student_id, rating_score, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_rating, now())
    on conflict (class_id)
    do update set rating_score = excluded.rating_score, updated_at = now();

    return true;
end;
$$;

create or replace function public.get_class_rating(
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text
)
returns smallint
language sql
security definer
set search_path = public
as $$
    select r.rating_score
    from public.ratings r
    join public.classes c on c.id = r.class_id
    join public.students s on s.id = c.student_id
    where s.phone = p_student_phone
      and c.day = p_day
      and c.time = p_time
      and c.subject = p_subject
    limit 1;
$$;

create or replace function public.get_class_rating_with_date(
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text
)
returns table (rating_score smallint, updated_at timestamptz)
language sql
security definer
set search_path = public
as $$
    select r.rating_score, r.updated_at
    from public.ratings r
    join public.classes c on c.id = r.class_id
    join public.students s on s.id = c.student_id
    where s.phone = p_student_phone
      and c.day = p_day
      and c.time = p_time
      and c.subject = p_subject
    limit 1;
$$;

create or replace function public.get_class_attendance_with_date(
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text
)
returns table (status text, updated_at timestamptz)
language sql
security definer
set search_path = public
as $$
    select a.status, a.updated_at
    from public.attendance a
    join public.classes c on c.id = a.class_id
    join public.students s on s.id = c.student_id
    where s.phone = p_student_phone
      and c.day = p_day
      and c.time = p_time
      and c.subject = p_subject
    limit 1;
$$;

create or replace function public.get_class_student_name(
    p_teacher_phone text,
    p_day text,
    p_time text,
    p_subject text
)
returns text
language sql
security definer
set search_path = public
as $$
    select s.full_name
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    join public.students s on s.id = c.student_id
    where t.phone = p_teacher_phone
      and c.day = p_day
      and c.time = p_time
      and c.subject = p_subject
    limit 1;
$$;

-- ============================================================
-- 6) الحضور
-- ============================================================

create or replace function public.sync_class_attendance(
    p_teacher_phone text,
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text,
    p_status text,
    p_duration_minutes integer default null,
    p_actual_duration_minutes integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_teacher_id uuid;
    v_student_id uuid;
    v_class_id uuid;
begin
    if p_status not in ('present', 'absent') then
        raise exception 'invalid_status';
    end if;

    select id into v_teacher_id from public.teachers where phone = p_teacher_phone;
    if v_teacher_id is null then
        return false;
    end if;

    if p_student_phone is not null then
        select id into v_student_id from public.students where phone = p_student_phone;
    end if;

    insert into public.classes (teacher_id, student_id, subject, day, time, duration_minutes)
    values (v_teacher_id, v_student_id, p_subject, p_day, p_time, p_duration_minutes)
    on conflict (teacher_id, day, time, subject)
    do update set
        student_id = excluded.student_id,
        duration_minutes = coalesce(excluded.duration_minutes, public.classes.duration_minutes)
    returning id into v_class_id;

    insert into public.attendance (class_id, teacher_id, student_id, status, actual_duration_minutes, updated_at)
    values (v_class_id, v_teacher_id, v_student_id, p_status, p_actual_duration_minutes, now())
    on conflict (class_id)
    do update set
        status = excluded.status,
        actual_duration_minutes = excluded.actual_duration_minutes,
        updated_at = now();

    return true;
end;
$$;

-- تستخدمها لوحة الطالب للتحقق من حالة حضوره لحصة معيّنة (لعرض شارة "غائب"
-- ومنع احتساب الحصة ضمن إنجازه)، مستقلة عن مزامنة التقييم.
create or replace function public.get_class_attendance(
    p_student_phone text,
    p_day text,
    p_time text,
    p_subject text
)
returns text
language sql
security definer
set search_path = public
as $$
    select a.status
    from public.attendance a
    join public.classes c on c.id = a.class_id
    join public.students s on s.id = c.student_id
    where s.phone = p_student_phone
      and c.day = p_day
      and c.time = p_time
      and c.subject = p_subject
    limit 1;
$$;

create or replace function public.list_attendance_overview(p_supervisor_id uuid)
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
    amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (select 1 from public.supervisors sv where sv.id = p_supervisor_id) then
        raise exception 'unauthorized';
    end if;

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
        end
    from public.classes c
    join public.teachers t on t.id = c.teacher_id
    join public.students s on s.id = c.student_id
    left join public.attendance a on a.class_id = c.id
    where t.supervisor_id = p_supervisor_id
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

-- نسخة موسّعة النطاق للمدير: نفس جدول المتابعة الشامل لكن عبر كل المشرفين
-- والمعلمين في المنصة (مش مقتصرة على مشرف واحد)، مستخدمة في البطاقة
-- الأخيرة بلوحة تحكم المدير.
drop function if exists public.list_attendance_overview_for_manager(uuid);

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
begin
    if not exists (select 1 from public.managers m where m.id = p_manager_id and m.auth_user_id = auth.uid()) then
        raise exception 'unauthorized';
    end if;

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
        -- حالة السداد محسوبة بالنسبة لشهر وقوع الحصة نفسها (شهر a.updated_at)،
        -- مش الشهر الحالي الفعلي — عشان بطاقة "نسبة تحصيل المستحقات" لما
        -- المدير يفلتر بالنطاق الزمني على شهر سابق (مثلاً "الشهر الماضي")
        -- تعرض تحصيل ذلك الشهر فعليًا مش تحصيل الشهر الحالي بالخطأ.
        case
            when a.status = 'present' and s.session_price is not null then
                case
                    when exists (
                        select 1 from public.transactions t2
                        where t2.student_id = s.id and t2.type = 'subscription'
                          and t2.created_at >= date_trunc('month', a.updated_at at time zone 'Asia/Dubai') at time zone 'Asia/Dubai'
                          and t2.created_at < (date_trunc('month', a.updated_at at time zone 'Asia/Dubai') + interval '1 month') at time zone 'Asia/Dubai'
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

create or replace function public.get_teacher_monthly_earnings(p_teacher_phone text)
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

create or replace function public.get_student_monthly_cost(p_student_phone text)
returns table (
    session_count integer,
    session_price numeric,
    total_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
    v_session_price numeric;
    v_month_start timestamptz;
begin
    select students.id, students.session_price into v_student_id, v_session_price
    from public.students where phone = p_student_phone;

    if v_student_id is null then
        return;
    end if;

    v_month_start := date_trunc('month', now() at time zone 'Asia/Dubai') at time zone 'Asia/Dubai';

    return query
    select
        count(*)::integer,
        v_session_price,
        round(count(*) * coalesce(v_session_price, 0), 2)
    from public.attendance a
    where a.student_id = v_student_id
      and a.status = 'present'
      and a.updated_at >= v_month_start;
end;
$$;

-- ============================================================
-- 8) خصومات وتنبيهات المعلمين
-- ============================================================

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

-- ============================================================
-- 9) البوابة المالية الشاملة (لوحة المدير)
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

-- ============================================================
-- 10) نظام التذكير والإشعارات (Push قبل الحصة بـ 10 دقائق)
-- ============================================================
-- جداول push_subscriptions وnotifications معرَّفة في main-schema.sql.

-- تحفظ (أو تحدّث) اشتراك Push لجهاز طالب/معلم — بتتنادى بعد ما المتصفح
-- يوافق على إذن الإشعارات ويرجع endpoint/keys حقيقية من الـ PushManager.
create or replace function public.save_push_subscription(
    p_user_type text,
    p_user_id uuid,
    p_endpoint text,
    p_p256dh text,
    p_auth text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_user_type not in ('student', 'teacher') then
        raise exception 'invalid_user_type';
    end if;

    -- كل إعادة تسجيل لـService Worker (بعد كل نشر جديد للموقع مثلًا) بتولّد
    -- endpoint مختلف تمامًا من نفس الجهاز. من غير هذا الحذف، الاشتراك القديم
    -- كان بيفضل معلّق في الجدول ويستقبل تذكيرات مكررة لحد ما يفشل الإرسال
    -- ليه فعليًا — نفترض جهاز واحد فعّال لكل مستخدم حاليًا.
    delete from public.push_subscriptions
    where user_type = p_user_type
      and user_id = p_user_id
      and endpoint <> p_endpoint;

    insert into public.push_subscriptions (user_type, user_id, endpoint, p256dh, auth)
    values (p_user_type, p_user_id, p_endpoint, p_p256dh, p_auth)
    on conflict (endpoint)
    do update set
        user_type = excluded.user_type,
        user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth;

    return true;
end;
$$;

-- تشيل اشتراك Push (مثلًا لما المستخدم يلغي إذن الإشعارات أو يسجّل خروج).
create or replace function public.delete_push_subscription(p_endpoint text)
returns boolean
language sql
security definer
set search_path = public
as $$
    delete from public.push_subscriptions where endpoint = p_endpoint;
    select true;
$$;

-- آخر إشعارات المستخدم — لقائمة الجرس المنسدلة.
create or replace function public.list_my_notifications(
    p_recipient_type text,
    p_recipient_id uuid,
    p_limit integer default 20
)
returns table (id uuid, title text, body text, link text, read_at timestamptz, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
    select n.id, n.title, n.body, n.link, n.read_at, n.created_at
    from public.notifications n
    where n.recipient_type = p_recipient_type
      and n.recipient_id = p_recipient_id
    order by n.created_at desc
    limit greatest(p_limit, 1);
$$;

-- عدد الإشعارات غير المقروءة — لبادج الجرس.
create or replace function public.get_unread_notification_count(p_recipient_type text, p_recipient_id uuid)
returns integer
language sql
security definer
set search_path = public
as $$
    select count(*)::integer
    from public.notifications n
    where n.recipient_type = p_recipient_type
      and n.recipient_id = p_recipient_id
      and n.read_at is null;
$$;

-- تعليم كل إشعارات المستخدم كمقروءة — بتتنادى لما يفتح قائمة الجرس.
create or replace function public.mark_notifications_read(p_recipient_type text, p_recipient_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
    update public.notifications
    set read_at = now()
    where recipient_type = p_recipient_type
      and recipient_id = p_recipient_id
      and read_at is null;
    select true;
$$;

-- ============================================================
-- 11) قوائم الطلاب/المعلمين الكاملة، موادهم، وتقارير متابعة الطالب
-- ============================================================
-- تُستخدم في supervisor-students.html و supervisor-teachers.html لجلب
-- القائمة الحقيقية من Supabase عند تحميل الصفحة، بدل الاعتماد على نسخة
-- localStorage القديمة (كانت القائمة تختفي بالكامل لو المشرف بدّل جهاز
-- أو مسح بيانات المتصفح رغم وجود البيانات فعليًا في القاعدة). عمود
-- students.subjects/teachers.subjects وجدول student_reports معرَّفين في
-- main-schema.sql.

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

-- حذف حقيقي لطالب/معلم (بدل الاعتماد على إخفاء محلي في localStorage).
-- الحذف المتتالي (Cascade) لتقييمات/حضور/خصومات المعلم أو تقييمات/حضور
-- الطالب متحكَّم فيه من قيود الجداول نفسها في main-schema.sql — راجع
-- التعليق التفصيلي في supabase/add-delete-student-teacher.sql.
create or replace function public.delete_student(p_supervisor_id uuid, p_student_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from public.students
    where id = p_student_id and supervisor_id = p_supervisor_id;
    return found;
end;
$$;

create or replace function public.delete_teacher(p_supervisor_id uuid, p_teacher_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from public.teachers
    where id = p_teacher_id and supervisor_id = p_supervisor_id;
    return found;
end;
$$;
