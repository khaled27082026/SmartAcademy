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

revoke all on function public.get_class_rating_with_date(text, text, text, text) from public;
grant execute on function public.get_class_rating_with_date(text, text, text, text) to anon;
