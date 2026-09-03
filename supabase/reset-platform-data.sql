-- ============================================================
-- تصفير بيانات المنصة بالكامل (بداية نظيفة) — بدون المساس بحسابات
-- المدير (جدول managers لا يُلمس إطلاقًا، فتفضل تقدر تسجّل دخول عادي).
--
-- ⚠️⚠️⚠️ تحذير: الملف ده حذف نهائي ولا رجعة فيه. بمجرد تشغيله هيتمسح:
--   - كل المشرفين (supervisors)
--   - كل المعلمين (teachers)
--   - كل الطلاب (students)
--   - كل الحصص الأسبوعية (classes)
--   - كل التقييمات (ratings)
--   - كل سجلات الحضور (attendance)
--   - كل خصومات/تنبيهات المعلمين (teacher_penalties)
--   - كل المعاملات المالية (transactions)
--   - كل اشتراكات Push والإشعارات (push_subscriptions, notifications)
--   - كل تقارير متابعة الطلاب (student_reports)
--
-- لن يتأثر: جدول managers (حسابات المديرين وربطها بـ Supabase Auth).
-- ============================================================

truncate table
    public.notifications,
    public.push_subscriptions,
    public.student_reports,
    public.transactions,
    public.teacher_penalties,
    public.attendance,
    public.ratings,
    public.classes,
    public.teachers,
    public.students,
    public.supervisors
cascade;
