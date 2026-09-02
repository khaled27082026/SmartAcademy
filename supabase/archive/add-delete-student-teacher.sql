-- ============================================================
-- دوال حذف حقيقية للطالب والمعلم (لوحة المشرف)
-- ============================================================
-- كانت أزرار الحذف في supervisor-students.html و supervisor-teachers.html
-- بتمسح الصف من localStorage بس — بدون أي دالة تحذف الصف فعليًا من
-- Supabase، فكان الطالب/المعلم يرجع يظهر تاني عند أي إعادة تحميل.
--
-- ملاحظة عن الحذف المتتالي (Cascade) المرتبط بالفعل في main-schema.sql:
--   - حذف معلم: يحذف كل حصصه (classes.teacher_id cascade)، وبالتبعية كل
--     تقييمات وحضور تلك الحصص (ratings/attendance تشير لكل من
--     teacher_id و class_id بـ cascade)، وكل خصوماته المسجَّلة
--     (teacher_penalties cascade). المعاملات المالية (transactions)
--     تبقى محفوظة (teacher_id يتحول لـ NULL بدل الحذف).
--   - حذف طالب: يحذف تقييماته وسجلات حضوره فقط (ratings/attendance
--     student_id cascade)، أما حصصه في الجدول فتبقى موجودة لكن بدون
--     طالب مرتبط (classes.student_id يتحول لـ NULL). المعاملات المالية
--     تبقى محفوظة أيضًا.
-- هذا سلوك الحذف الفعلي المتحكم فيه Cascade، ولذلك الواجهة تعرض تأكيدًا
-- صريحًا قبل الاستدعاء — الإجراء لا رجعة فيه.
-- ============================================================

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

revoke all on function public.delete_student(uuid, uuid) from public;
grant execute on function public.delete_student(uuid, uuid) to anon;

revoke all on function public.delete_teacher(uuid, uuid) from public;
grant execute on function public.delete_teacher(uuid, uuid) to anon;
