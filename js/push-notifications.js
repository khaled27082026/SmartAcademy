// ============================================================
// Smart Academy — نظام التذكير والإشعارات (Push + جرس)
// ============================================================
// يُستخدم في student-dashboard.html و teacher-dashboard.html. يفترض إن
// window.saSupabase و window.SA_NOTIF_USER = { type: 'student'|'teacher', id: '<uuid>' }
// متعرّفين قبل استدعاء saInitNotificationBell().

window.SA_VAPID_PUBLIC_KEY = 'BPZ4t9YlkzQ0sTUUaPWZjU9-y6GNxtH2XKsN2qYh-lpWcArhxIHaAQ7INuxjlRCdfalU2316ZL-xXhdcxE6L1X4';

function saUrlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const rawData = window.atob(base64);
    const outputArray = new Uint8Array(rawData.length);
    for (let i = 0; i < rawData.length; i++) {
        outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
}

async function saSubscribeToPush(userType, userId) {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
        throw new Error('هذا المتصفح لا يدعم إشعارات Push.');
    }

    const permission = await Notification.requestPermission();
    if (permission !== 'granted') {
        throw new Error('تم رفض إذن الإشعارات.');
    }

    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();

    if (!subscription) {
        subscription = await registration.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: saUrlBase64ToUint8Array(window.SA_VAPID_PUBLIC_KEY)
        });
    }

    const raw = subscription.toJSON();
    const sb = window.saSupabase;
    if (!sb) throw new Error('تعذّر الاتصال بقاعدة البيانات.');

    const { error } = await sb.rpc('save_push_subscription', {
        p_user_type: userType,
        p_user_id: userId,
        p_endpoint: raw.endpoint,
        p_p256dh: raw.keys.p256dh,
        p_auth: raw.keys.auth
    });
    if (error) throw error;

    return subscription;
}

async function saIsPushSubscribed() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) return false;
    if (Notification.permission !== 'granted') return false;

    try {
        const registration = await navigator.serviceWorker.ready;
        const subscription = await registration.pushManager.getSubscription();
        return !!subscription;
    } catch (e) {
        return false;
    }
}

// نصوص عنوان/محتوى الإشعار جايه في الأساس من حقول حرة بيدخلها المشرف
// (اسم الطالب/المعلم، المادة، رابط الحصة) — لازم تتهرّب قبل الحقن في
// innerHTML عشان نمنع أي HTML/Script يتنفّذ لو حد كتب اسم فيه وسوم بالغلط
// أو قصدًا.
function saEscapeHtml(str) {
    return String(str == null ? '' : str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function saFormatNotifTime(iso) {
    try {
        return saFormatDubai(new Date(iso), { hour: '2-digit', minute: '2-digit', day: 'numeric', month: 'short' });
    } catch (e) {
        return '';
    }
}

function saShowNotifToast(title, body, link) {
    const toast = document.createElement('div');
    toast.className = 'sa-notif-toast';
    toast.innerHTML =
        '<div class="sa-notif-toast-icon"><i class="fa-solid fa-bell"></i></div>' +
        '<div class="sa-notif-toast-text">' +
        '<strong>' + saEscapeHtml(title) + '</strong>' +
        '<span>' + saEscapeHtml(body) + '</span>' +
        '</div>';

    if (link) {
        toast.style.cursor = 'pointer';
        toast.addEventListener('click', function () {
            window.open(link, '_blank', 'noopener');
        });
    }

    document.body.appendChild(toast);
    requestAnimationFrame(function () {
        toast.classList.add('is-visible');
    });

    setTimeout(function () {
        toast.classList.remove('is-visible');
        setTimeout(function () {
            toast.remove();
        }, 400);
    }, 7000);
}

async function saInitNotificationBell(userType, userId) {
    const sb = window.saSupabase;
    const bellBtn = document.getElementById('notif-bell-btn');
    const badge = document.getElementById('notif-bell-badge');
    const panel = document.getElementById('notif-bell-panel');
    const list = document.getElementById('notif-bell-list');
    const enableBtn = document.getElementById('notif-enable-btn');

    if (!sb || !bellBtn || !userId) return;

    async function refreshBadge() {
        try {
            const { data, error } = await sb.rpc('get_unread_notification_count', {
                p_recipient_type: userType,
                p_recipient_id: userId
            });
            if (error) throw error;

            const count = data || 0;
            if (count > 0) {
                badge.textContent = count > 9 ? '9+' : String(count);
                badge.style.display = 'flex';
            } else {
                badge.style.display = 'none';
            }
        } catch (e) {
            console.error('تعذّر جلب عدد الإشعارات غير المقروءة:', e);
        }
    }

    async function renderList() {
        try {
            const { data, error } = await sb.rpc('list_my_notifications', {
                p_recipient_type: userType,
                p_recipient_id: userId,
                p_limit: 20
            });
            if (error) throw error;

            const rows = data || [];
            if (rows.length === 0) {
                list.innerHTML = '<p class="notif-bell-empty">لا توجد إشعارات بعد.</p>';
                return;
            }

            list.innerHTML = rows.map(function (n) {
                const tag = n.link ? 'a' : 'div';
                const hrefAttr = n.link ? ' href="' + saEscapeHtml(n.link) + '" target="_blank" rel="noopener"' : '';
                return '<' + tag + ' class="notif-bell-item' + (!n.read_at ? ' is-unread' : '') + '"' + hrefAttr + '>' +
                    '<span class="notif-bell-item-title">' + saEscapeHtml(n.title) + '</span>' +
                    '<span class="notif-bell-item-body">' + saEscapeHtml(n.body) + '</span>' +
                    '<span class="notif-bell-item-time">' + saEscapeHtml(saFormatNotifTime(n.created_at)) + '</span>' +
                    '</' + tag + '>';
            }).join('');
        } catch (e) {
            console.error('تعذّر جلب الإشعارات:', e);
            list.innerHTML = '<p class="notif-bell-empty">تعذّر تحميل الإشعارات.</p>';
        }
    }

    async function updateEnableBtnState() {
        if (!enableBtn) return;
        const subscribed = await saIsPushSubscribed();
        enableBtn.classList.toggle('is-active', subscribed);
        enableBtn.innerHTML = subscribed
            ? '<i class="fa-solid fa-bell"></i> التنبيهات مفعّلة'
            : '<i class="fa-solid fa-bell-slash"></i> تفعيل تنبيهات الحصص';
    }

    bellBtn.addEventListener('click', async function (e) {
        e.stopPropagation();
        const isOpen = panel.classList.toggle('is-open');
        if (isOpen) {
            await renderList();
            await sb.rpc('mark_notifications_read', { p_recipient_type: userType, p_recipient_id: userId });
            await refreshBadge();
        }
    });

    document.addEventListener('click', function (e) {
        if (!panel.contains(e.target) && e.target !== bellBtn) {
            panel.classList.remove('is-open');
        }
    });

    if (enableBtn) {
        enableBtn.addEventListener('click', async function (e) {
            e.stopPropagation();
            try {
                await saSubscribeToPush(userType, userId);
            } catch (err) {
                console.error('تعذّر تفعيل الإشعارات:', err);
                alert(err.message || 'تعذّر تفعيل الإشعارات، حاول مرة أخرى.');
            }
            updateEnableBtnState();
        });
    }

    refreshBadge();
    updateEnableBtnState();

    // لا تتوفر للطالب أو المعلم جلسة Supabase Auth حقيقية (يتم التحقق من
    // تسجيل الدخول برقم الهاتف وكلمة المرور عبر RPC، وليس عبر auth.uid())،
    // لذا لا توجد طريقة آمنة لفتح قناة Realtime (postgres_changes) تقتصر
    // على بيانات المستخدم نفسه باستخدام مفتاح anon العام. الحل الآمن
    // المكافئ: فحص دوري (Polling) كل 20 ثانية عبر نفس الدوال المحمية (RPC
    // بمعرّف المستخدم) — يصل خلال ثوانٍ قليلة بدلاً من اللحظية، لكن دون
    // أي كشف لبيانات مستخدمين آخرين.
    let lastSeenCreatedAt = null;

    async function pollForNewNotifications() {
        try {
            const { data, error } = await sb.rpc('list_my_notifications', {
                p_recipient_type: userType,
                p_recipient_id: userId,
                p_limit: 5
            });
            if (error) throw error;

            const rows = data || [];
            if (rows.length === 0) return;

            if (lastSeenCreatedAt === null) {
                lastSeenCreatedAt = rows[0].created_at;
                return;
            }

            const freshRows = rows.filter(function (n) { return n.created_at > lastSeenCreatedAt; });
            if (freshRows.length === 0) return;

            lastSeenCreatedAt = rows[0].created_at;

            freshRows.slice().reverse().forEach(function (n) {
                saShowNotifToast(n.title, n.body, n.link);
            });

            refreshBadge();
            if (panel.classList.contains('is-open')) renderList();
        } catch (e) {
            console.error('تعذّر فحص الإشعارات الجديدة:', e);
        }
    }

    pollForNewNotifications();
    setInterval(pollForNewNotifications, 20000);
}
