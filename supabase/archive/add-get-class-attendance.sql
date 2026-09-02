-- ============================================================
-- إضافة دالة get_class_attendance (لو شغّلت functions.sql / policies.sql
-- قبل تحديثهم بيها). آمن التكرار — نفّذه سواء عندك الدالة دي أو لأ.
-- ============================================================

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

revoke all on function public.get_class_attendance(text, text, text, text) from public;
grant execute on function public.get_class_attendance(text, text, text, text) to anon;
