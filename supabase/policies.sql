-- ============================================================
-- Smart Academy — policies.sql
-- ============================================================
-- الأمان: تفعيل RLS على كل الجداول (بدون أي سياسة مباشرة تسمح لمفتاح anon
-- بقراءة/كتابة أي جدول مباشرة)، بالإضافة لصلاحيات تنفيذ الدوال (RPCs)
-- فقط. يعني الوصول الوحيد لأي بيانات هو عبر الدوال في functions.sql،
-- واللي كل واحدة فيها بتتحقق من صلاحية المستخدم (manager_id / supervisor_id)
-- قبل ما ترجع أو تعدّل أي حاجة.
--
-- لازم يتشغّل بعد main-schema.sql و functions.sql (بالترتيب ده بالظبط).
-- ============================================================

-- ============================================================
-- 1) تفعيل RLS على كل الجداول — من غير أي CREATE POLICY
-- ============================================================
-- الافتراضي في Postgres لما تفعّل RLS على جدول من غير ما تضيفله أي policy
-- هو رفض كل شيء (Deny All) لأي حد غير مالك الجدول. الدوال في functions.sql
-- كلها SECURITY DEFINER، يعني بتشتغل بصلاحيات مالك قاعدة البيانات وبتتجاوز
-- RLS تلقائيًا — فهي الطريقة الوحيدة المتاحة للوصول للبيانات.
alter table public.managers          enable row level security;
alter table public.supervisors       enable row level security;
alter table public.students          enable row level security;
alter table public.teachers          enable row level security;
alter table public.classes           enable row level security;
alter table public.ratings           enable row level security;
alter table public.attendance        enable row level security;
alter table public.teacher_penalties enable row level security;
alter table public.transactions      enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.notifications      enable row level security;

-- ============================================================
-- 2) صلاحيات تنفيذ الدوال (Grants)
-- ============================================================
-- نمط ثابت لكل دالة: نمنع التنفيذ عن الجميع أولاً، وبعدين نسمح بس لمفتاح
-- anon (المفتاح العام المستخدم في الواجهة الأمامية) — وده أمان إضافي فوق
-- فحص الصلاحية اللي جوا كل دالة نفسها.

-- -------------------- تسجيل الدخول --------------------
revoke all on function public.verify_manager_login(text, text) from public;
grant execute on function public.verify_manager_login(text, text) to anon;

revoke all on function public.get_current_manager() from public;
grant execute on function public.get_current_manager() to authenticated;

revoke all on function public.verify_supervisor_login(text, text) from public;
grant execute on function public.verify_supervisor_login(text, text) to anon;

revoke all on function public.verify_student_login(text, text) from public;
grant execute on function public.verify_student_login(text, text) to anon;

revoke all on function public.verify_teacher_login(text, text) from public;
grant execute on function public.verify_teacher_login(text, text) to anon;

-- -------------------- إدارة المشرفين --------------------
revoke all on function public.create_supervisor(uuid, text, text, text, text) from public;
grant execute on function public.create_supervisor(uuid, text, text, text, text) to anon;

revoke all on function public.list_supervisors(uuid) from public;
grant execute on function public.list_supervisors(uuid) to anon;

revoke all on function public.update_supervisor(uuid, uuid, text, text, text, text) from public;
grant execute on function public.update_supervisor(uuid, uuid, text, text, text, text) to anon;

revoke all on function public.delete_supervisor(uuid, uuid) from public;
grant execute on function public.delete_supervisor(uuid, uuid) to anon;

-- -------------------- إدارة المعلمين --------------------
revoke all on function public.create_teacher(uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.create_teacher(uuid, text, text, text, text, text, numeric) to anon;

revoke all on function public.update_teacher(uuid, uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.update_teacher(uuid, uuid, text, text, text, text, text, numeric) to anon;

revoke all on function public.list_teachers(uuid) from public;
grant execute on function public.list_teachers(uuid) to anon;

revoke all on function public.get_teacher_name(uuid) from public;
grant execute on function public.get_teacher_name(uuid) to anon;

-- -------------------- إدارة الطلاب --------------------
revoke all on function public.create_student(uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.create_student(uuid, text, text, text, text, text, numeric) to anon;

revoke all on function public.update_student(uuid, uuid, text, text, text, text, text, numeric) from public;
grant execute on function public.update_student(uuid, uuid, text, text, text, text, text, numeric) to anon;

-- -------------------- الجدول الأسبوعي (المواعيد) --------------------
revoke all on function public.set_student_sessions(uuid, uuid, jsonb) from public;
grant execute on function public.set_student_sessions(uuid, uuid, jsonb) to anon;

revoke all on function public.set_teacher_sessions(uuid, uuid, jsonb) from public;
grant execute on function public.set_teacher_sessions(uuid, uuid, jsonb) to anon;

revoke all on function public.get_student_sessions_for_manage(uuid, uuid) from public;
grant execute on function public.get_student_sessions_for_manage(uuid, uuid) to anon;

revoke all on function public.get_teacher_sessions_for_manage(uuid, uuid) from public;
grant execute on function public.get_teacher_sessions_for_manage(uuid, uuid) to anon;

revoke all on function public.get_student_sessions(text) from public;
grant execute on function public.get_student_sessions(text) to anon;

revoke all on function public.get_teacher_sessions(text) from public;
grant execute on function public.get_teacher_sessions(text) to anon;

-- -------------------- الحصص والتقييمات --------------------
revoke all on function public.sync_class_rating(text, text, text, text, text, smallint, integer) from public;
grant execute on function public.sync_class_rating(text, text, text, text, text, smallint, integer) to anon;

revoke all on function public.get_class_rating(text, text, text, text) from public;
grant execute on function public.get_class_rating(text, text, text, text) to anon;

revoke all on function public.get_class_rating_with_date(text, text, text, text) from public;
grant execute on function public.get_class_rating_with_date(text, text, text, text) to anon;

revoke all on function public.get_class_student_name(text, text, text, text) from public;
grant execute on function public.get_class_student_name(text, text, text, text) to anon;

-- -------------------- الحضور --------------------
revoke all on function public.sync_class_attendance(text, text, text, text, text, text, integer, integer) from public;
grant execute on function public.sync_class_attendance(text, text, text, text, text, text, integer, integer) to anon;

revoke all on function public.get_class_attendance(text, text, text, text) from public;
grant execute on function public.get_class_attendance(text, text, text, text) to anon;

revoke all on function public.list_attendance_overview(uuid) from public;
grant execute on function public.list_attendance_overview(uuid) to anon;

revoke all on function public.list_attendance_overview_for_manager(uuid) from public;
grant execute on function public.list_attendance_overview_for_manager(uuid) to anon;

-- -------------------- المستحقات المالية الفردية --------------------
revoke all on function public.get_teacher_monthly_earnings(text) from public;
grant execute on function public.get_teacher_monthly_earnings(text) to anon;

revoke all on function public.get_student_monthly_cost(text) from public;
grant execute on function public.get_student_monthly_cost(text) to anon;

-- -------------------- خصومات وتنبيهات المعلمين --------------------
revoke all on function public.create_teacher_penalty(uuid, uuid, numeric, text) from public;
grant execute on function public.create_teacher_penalty(uuid, uuid, numeric, text) to anon;

revoke all on function public.list_teacher_penalties(uuid, uuid) from public;
grant execute on function public.list_teacher_penalties(uuid, uuid) to anon;

revoke all on function public.list_teacher_penalties_for_teacher(text) from public;
grant execute on function public.list_teacher_penalties_for_teacher(text) to anon;

-- -------------------- البوابة المالية الشاملة --------------------
revoke all on function public.create_transaction(uuid, text, numeric, uuid, uuid, uuid) from public;
grant execute on function public.create_transaction(uuid, text, numeric, uuid, uuid, uuid) to anon;

revoke all on function public.list_transactions(uuid, integer) from public;
grant execute on function public.list_transactions(uuid, integer) to anon;

revoke all on function public.get_financial_kpis(uuid, date, date) from public;
grant execute on function public.get_financial_kpis(uuid, date, date) to anon;

revoke all on function public.get_monthly_financial_trend(uuid, integer, date) from public;
grant execute on function public.get_monthly_financial_trend(uuid, integer, date) to anon;

revoke all on function public.get_student_subscription_status(uuid) from public;
grant execute on function public.get_student_subscription_status(uuid) to anon;

revoke all on function public.list_teacher_dues_for_manager(uuid, date, date) from public;
grant execute on function public.list_teacher_dues_for_manager(uuid, date, date) to anon;

revoke all on function public.sync_teacher_dues_expenses(uuid) from public;
grant execute on function public.sync_teacher_dues_expenses(uuid) to anon;

revoke all on function public.list_all_students(uuid) from public;
grant execute on function public.list_all_students(uuid) to anon;

revoke all on function public.list_all_teachers(uuid) from public;
grant execute on function public.list_all_teachers(uuid) to anon;

-- -------------------- بطاقات لوحة التحكم الشاملة --------------------
revoke all on function public.list_students_basic(uuid) from public;
grant execute on function public.list_students_basic(uuid) to anon;

revoke all on function public.list_today_classes(uuid, text) from public;
grant execute on function public.list_today_classes(uuid, text) to anon;

-- -------------------- نظام التذكير والإشعارات --------------------
revoke all on function public.save_push_subscription(text, uuid, text, text, text) from public;
grant execute on function public.save_push_subscription(text, uuid, text, text, text) to anon;

revoke all on function public.delete_push_subscription(text) from public;
grant execute on function public.delete_push_subscription(text) to anon;

revoke all on function public.list_my_notifications(text, uuid, integer) from public;
grant execute on function public.list_my_notifications(text, uuid, integer) to anon;

revoke all on function public.get_unread_notification_count(text, uuid) from public;
grant execute on function public.get_unread_notification_count(text, uuid) to anon;

revoke all on function public.mark_notifications_read(text, uuid) from public;
grant execute on function public.mark_notifications_read(text, uuid) to anon;
