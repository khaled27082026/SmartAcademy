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

revoke all on function public.get_class_student_name(text, text, text, text) from public;
grant execute on function public.get_class_student_name(text, text, text, text) to anon;
