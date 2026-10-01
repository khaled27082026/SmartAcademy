-- ============================================================
-- تفريغ كامل لكل بيانات المنصة، مع الإبقاء على جدول managers فقط.
-- ⚠️ عملية غير قابلة للتراجع — كل الطلاب والمعلمين والمشرفين والحصص
-- والتقييمات والحضور والخصومات هيتمسحوا نهائيًا.
-- ============================================================

truncate table
    public.attendance,
    public.ratings,
    public.classes,
    public.teacher_penalties,
    public.students,
    public.teachers,
    public.supervisors
restart identity cascade;

-- تأكيد سريع: الجدول ده المفروض يفضل فيه بياناته زي ما هي بالظبط
select count(*) as managers_count from public.managers;
