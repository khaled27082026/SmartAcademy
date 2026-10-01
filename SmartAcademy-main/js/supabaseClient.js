// ============================================================
// ============================================================
window.saSupabase = (function () {
    const notConfigured =
        !window.supabase ||
        !window.SUPABASE_URL ||
        !window.SUPABASE_ANON_KEY ||
        window.SUPABASE_URL.indexOf('YOUR_PROJECT_REF') !== -1 ||
        window.SUPABASE_ANON_KEY.indexOf('YOUR_ANON_PUBLIC_KEY') !== -1;

    if (notConfigured) {
        return null;
    }

    try {
        return window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);
    } catch (e) {
        console.error('تعذّر إنشاء عميل Supabase:', e);
        return null;
    }
})();
