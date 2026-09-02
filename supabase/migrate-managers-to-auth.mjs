// ============================================================
// ترحيل حسابات المديرين الحالية إلى Supabase Auth (خطوة تُشغَّل مرة واحدة)
// ============================================================
//
// ليه محتاجين السكريبت ده؟
// دوال RPC الخاصة بالمدير بقت تتحقق من auth.uid() الحقيقي بدل الاكتفاء
// بوجود معرّف يرسله العميل — وده يتطلب إن كل مدير له حساب Supabase Auth
// حقيقي (auth.users) مرتبط بصف managers.auth_user_id الخاص بيه. إنشاء
// حسابات Auth بباسورد لازم يمر عبر Admin API (service_role key)، وده
// مينفعش يتعمل من SQL Editor العادي ولا من كود الواجهة الأمامية —
// عشان كده السكريبت ده لازم يتشغّل مرة واحدة من جهازك انت مباشرة.
//
// ⚠️ لازم تشغّل add-manager-auth-linkage.sql على Supabase الأول (بيضيف
// عمود auth_user_id لجدول managers) قبل ما تشغّل السكريبت ده.
//
// طريقة التشغيل:
//   1) npm install @supabase/supabase-js
//   2) صدّر متغيّرين بيئة (من إعدادات مشروعك في Supabase Dashboard →
//      Project Settings → API — استخدم service_role key، مش anon key،
//      ومتحطهوش أبدًا في أي كود واجهة أمامية أو تشاركه مع أي حد):
//        export SUPABASE_URL="https://xxxx.supabase.co"
//        export SUPABASE_SERVICE_ROLE_KEY="ey..."
//   3) node supabase/migrate-managers-to-auth.mjs
//
// السكريبت بيعدّي على كل صف في managers مفيهوش auth_user_id لسه، وبيعمل:
//   - إنشاء مستخدم Supabase Auth جديد بنفس كلمة المرور الحالية (المخزّنة
//     نص عادي في عمود managers.password حاليًا) وبريد مُصنَّع من رقم
//     الهاتف (manager+<phone>@smartacademy.internal — نفس منطق
//     saManagerAuthEmail في js/app.js، لازم يفضلوا متطابقين).
//   - تحديث managers.auth_user_id بمعرّف المستخدم الجديد.
// آمن التكرار: أي مدير عنده auth_user_id بالفعل يتجاوزه السكريبت.
// ============================================================

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    console.error('لازم تصدّر SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY كمتغيّرات بيئة أولاً.');
    process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false }
});

function managerAuthEmail(phone) {
    const digits = String(phone || '').replace(/[^0-9]/g, '');
    return 'manager+' + digits + '@smartacademy.internal';
}

async function main() {
    const { data: managers, error } = await supabase
        .from('managers')
        .select('id, phone, password, auth_user_id')
        .is('auth_user_id', null);

    if (error) {
        console.error('تعذّر جلب قائمة المديرين:', error);
        process.exit(1);
    }

    if (!managers || managers.length === 0) {
        console.log('كل المديرين مرتبطين بحساب Supabase Auth بالفعل — لا يوجد شيء لترحيله.');
        return;
    }

    console.log('عدد المديرين المطلوب ترحيلهم:', managers.length);

    for (const manager of managers) {
        const email = managerAuthEmail(manager.phone);

        const { data: created, error: createErr } = await supabase.auth.admin.createUser({
            email,
            password: manager.password,
            email_confirm: true
        });

        if (createErr) {
            console.error('فشل إنشاء حساب Auth للمدير (هاتف: ' + manager.phone + '):', createErr.message);
            continue;
        }

        const { error: updateErr } = await supabase
            .from('managers')
            .update({ auth_user_id: created.user.id })
            .eq('id', manager.id);

        if (updateErr) {
            console.error('فشل ربط المدير (هاتف: ' + manager.phone + ') بحساب Auth الجديد:', updateErr.message);
            continue;
        }

        console.log('تم ترحيل المدير بنجاح — هاتف:', manager.phone, '| auth_user_id:', created.user.id);
    }

    console.log('انتهى الترحيل.');
}

main();
