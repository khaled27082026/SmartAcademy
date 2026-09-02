-- ============================================================
-- إضافة فهارس (Indexes) ناقصة على أعمدة مفاتيح خارجية (Foreign Keys)
-- بيتم الفلترة/الربط بيها بكثرة في دوال RPC، لتحسين أداء الاستعلامات
-- مع نمو البيانات. لا تغيّر أي سلوك أو صلاحيات — تحسين أداء بحت وآمن
-- تمامًا للتشغيل على قاعدة بيانات فيها بيانات حية بالفعل.
-- ============================================================

create index if not exists classes_teacher_id_idx             on public.classes(teacher_id);
create index if not exists classes_day_idx                    on public.classes(day);
create index if not exists ratings_teacher_id_idx              on public.ratings(teacher_id);
create index if not exists teacher_penalties_supervisor_id_idx on public.teacher_penalties(supervisor_id);
create index if not exists students_supervisor_id_idx          on public.students(supervisor_id);
create index if not exists teachers_supervisor_id_idx          on public.teachers(supervisor_id);
create index if not exists transactions_source_idx             on public.transactions(source);
create index if not exists transactions_student_id_idx         on public.transactions(student_id);
create index if not exists transactions_teacher_id_idx         on public.transactions(teacher_id);
create index if not exists transactions_supervisor_id_idx      on public.transactions(supervisor_id);
