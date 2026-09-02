// ============================================================
// Smart Academy — app.js
// ============================================================

const SA_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

const SA_TIMEZONE = 'Asia/Dubai';
const SA_TIMEZONE_OFFSET_MINUTES = 4 * 60;

function saFormatDubai(date, options) {
    return new Intl.DateTimeFormat('ar-EG', Object.assign({ timeZone: SA_TIMEZONE }, options, { numberingSystem: 'latn' })).format(date);
}

function saDubaiNow() {
    const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: SA_TIMEZONE,
        hour12: false,
        year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit',
        weekday: 'short'
    }).formatToParts(new Date()).reduce(function (acc, p) {
        acc[p.type] = p.value;
        return acc;
    }, {});

    const weekdayIndex = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 }[parts.weekday];
    let hours = parseInt(parts.hour, 10);
    if (hours === 24) hours = 0;

    return {
        year: parseInt(parts.year, 10),
        month: parseInt(parts.month, 10) - 1,
        date: parseInt(parts.day, 10),
        day: weekdayIndex,
        hours: hours,
        minutes: parseInt(parts.minute, 10)
    };
}

function saDubaiTimestamp(year, month, date, hours, minutes) {
    return Date.UTC(year, month, date, hours, minutes, 0, 0) - SA_TIMEZONE_OFFSET_MINUTES * 60000;
}

// Supabase Auth يحتاج بريدًا إلكترونيًا كمعرّف دخول، والمنصة مبنية على
// تسجيل الدخول برقم الهاتف — فبنولّد بريدًا مُصنَّعًا وثابتًا من رقم هاتف
// المدير (أرقام فقط) لربطه بحساب Supabase Auth حقيقي دون تغيير تجربة
// إدخال رقم الهاتف في واجهة تسجيل الدخول. يُستخدم في admin-login.html
// وفي سكريبت الترحيل migrate-managers-to-auth.mjs — يجب أن يبقى نفس
// المنطق في المكانين.
function saManagerAuthEmail(phone) {
    const digits = String(phone || '').replace(/[^0-9]/g, '');
    return 'manager+' + digits + '@smartacademy.internal';
}

function saSetSession(key, data) {
    localStorage.setItem(key, JSON.stringify({
        data: data,
        expiresAt: Date.now() + SA_SESSION_TTL_MS
    }));
}

function saGetSession(key) {
    let raw;
    try {
        raw = JSON.parse(localStorage.getItem(key));
    } catch (e) {
        raw = null;
    }

    if (!raw || typeof raw !== 'object' || !raw.data || !raw.expiresAt) {
        return null;
    }

    if (Date.now() > raw.expiresAt) {
        localStorage.removeItem(key);
        return null;
    }

    return raw.data;
}

function saClearSession(key) {
    localStorage.removeItem(key);
}

if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
        navigator.serviceWorker.register('/service-worker.js')
            .catch((err) => console.error('Service Worker registration failed:', err));
    });
}

(function initInstallPrompt() {
    const PWA_MODAL_SEEN_KEY = 'sa_pwa_modal_seen';
    const PWA_MODAL_SHOW_DELAY_MS = 1500;

    let deferredPrompt = null;

    const isRunningStandalone = () =>
        window.matchMedia('(display-mode: standalone)').matches ||
        window.navigator.standalone === true;

    const hideInstallOption = () => {
        document.querySelectorAll('.pwa-install-btn').forEach((btn) => {
            btn.classList.remove('is-visible');
        });
    };

    const runInstallFlow = async () => {
        if (!deferredPrompt || deferredPrompt === 'installed') return;
        deferredPrompt.prompt();
        await deferredPrompt.userChoice;
        deferredPrompt = null;
        hideInstallOption();
    };

    // -------------------- نافذة تثبيت PWA التلقائية (أول زيارة فقط) --------------------
    const modalOverlay = document.getElementById('pwa-install-overlay');

    const dismissInstallModal = () => {
        if (!modalOverlay) return;
        modalOverlay.classList.remove('is-visible');
        localStorage.setItem(PWA_MODAL_SEEN_KEY, '1');
    };

    const maybeShowInstallModal = () => {
        if (!modalOverlay) return;
        if (localStorage.getItem(PWA_MODAL_SEEN_KEY)) return;
        if (isRunningStandalone()) return;
        if (!deferredPrompt || deferredPrompt === 'installed') return;

        setTimeout(() => {
            if (!deferredPrompt || deferredPrompt === 'installed') return;
            modalOverlay.classList.add('is-visible');
        }, PWA_MODAL_SHOW_DELAY_MS);
    };

    if (isRunningStandalone()) {
        deferredPrompt = 'installed';
    }

    window.addEventListener('beforeinstallprompt', (event) => {
        event.preventDefault();
        if (deferredPrompt === 'installed') return;
        deferredPrompt = event;
        document.querySelectorAll('.pwa-install-btn').forEach((btn) => {
            btn.classList.add('is-visible');
        });
        maybeShowInstallModal();
    });

    document.addEventListener('DOMContentLoaded', () => {
        if (isRunningStandalone()) hideInstallOption();

        document.querySelectorAll('.pwa-install-btn').forEach((btn) => {
            btn.addEventListener('click', runInstallFlow);
        });

        const modalInstallBtn = document.getElementById('pwa-modal-install-btn');
        const modalLaterBtn = document.getElementById('pwa-modal-later-btn');
        const modalCloseBtn = document.getElementById('pwa-modal-close');

        if (modalInstallBtn) {
            modalInstallBtn.addEventListener('click', async () => {
                await runInstallFlow();
                dismissInstallModal();
            });
        }

        if (modalLaterBtn) modalLaterBtn.addEventListener('click', dismissInstallModal);
        if (modalCloseBtn) modalCloseBtn.addEventListener('click', dismissInstallModal);

        if (modalOverlay) {
            modalOverlay.addEventListener('click', (event) => {
                if (event.target === modalOverlay) dismissInstallModal();
            });
        }
    });

    window.addEventListener('appinstalled', () => {
        deferredPrompt = 'installed';
        hideInstallOption();
        dismissInstallModal();
    });
})();

(function initTheme() {
    const root = document.documentElement;

    document.addEventListener('DOMContentLoaded', () => {
        const toggleBtn = document.querySelector('.theme-toggle');
        if (!toggleBtn) return;

        toggleBtn.addEventListener('click', () => {
            const isLight = root.getAttribute('data-theme') === 'light';
            if (isLight) {
                root.removeAttribute('data-theme');
                localStorage.removeItem('theme');
            } else {
                root.setAttribute('data-theme', 'light');
                localStorage.setItem('theme', 'light');
            }
        });
    });
})();

document.addEventListener('DOMContentLoaded', () => {
    const navToggle = document.querySelector('.nav-toggle');
    const mobileMenu = document.querySelector('.mobile-menu');
    const mobileMenuClose = document.querySelector('.mobile-menu-close');
    const overlay = document.querySelector('.mobile-menu-overlay');

    if (!navToggle || !mobileMenu || !overlay) return;

    const openMenu = () => {
        mobileMenu.classList.add('is-open');
        overlay.classList.add('is-open');
    };

    const closeMenu = () => {
        mobileMenu.classList.remove('is-open');
        overlay.classList.remove('is-open');
    };

    navToggle.addEventListener('click', openMenu);
    mobileMenuClose?.addEventListener('click', closeMenu);
    overlay.addEventListener('click', closeMenu);
    mobileMenu.querySelectorAll('a, .pwa-install-btn').forEach((link) => link.addEventListener('click', closeMenu));
});

document.addEventListener('DOMContentLoaded', () => {
    const faqItems = document.querySelectorAll('.faq-item');

    faqItems.forEach((item) => {
        const question = item.querySelector('.faq-question');
        if (!question) return;

        question.addEventListener('click', () => {
            const isOpen = item.classList.contains('is-open');

            faqItems.forEach((otherItem) => {
                otherItem.classList.remove('is-open');
                otherItem.querySelector('.faq-question')?.setAttribute('aria-expanded', 'false');
            });

            if (!isOpen) {
                item.classList.add('is-open');
                question.setAttribute('aria-expanded', 'true');
            }
        });
    });
});

document.addEventListener('DOMContentLoaded', () => {
    const countdownEl = document.getElementById('pricing-countdown');
    if (!countdownEl) return;

    const hEl = countdownEl.querySelector('[data-countdown-h]');
    const mEl = countdownEl.querySelector('[data-countdown-m]');
    const sEl = countdownEl.querySelector('[data-countdown-s]');

    function tick() {
        const now = new Date();
        const deadline = new Date(now);
        deadline.setHours(23, 59, 59, 999);

        const diff = Math.max(0, deadline - now);
        const totalSeconds = Math.floor(diff / 1000);
        const hours = Math.floor(totalSeconds / 3600);
        const minutes = Math.floor((totalSeconds % 3600) / 60);
        const seconds = totalSeconds % 60;

        hEl.textContent = String(hours).padStart(2, '0');
        mEl.textContent = String(minutes).padStart(2, '0');
        sEl.textContent = String(seconds).padStart(2, '0');
    }

    tick();
    setInterval(tick, 1000);
});

