-- ============================================================
--
--
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
