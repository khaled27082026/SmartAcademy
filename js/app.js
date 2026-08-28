// ============================================================
// Smart Academy — app.js
// ============================================================

const SA_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

const SA_TIMEZONE = 'Asia/Dubai';
const SA_TIMEZONE_OFFSET_MINUTES = 4 * 60;

function saFormatDubai(date, options) {
    return new Intl.DateTimeFormat('ar-EG', Object.assign({ timeZone: SA_TIMEZONE }, options)).format(date);
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
    let deferredPrompt = null;

    const isRunningStandalone = () =>
        window.matchMedia('(display-mode: standalone)').matches ||
        window.navigator.standalone === true;

    const hideInstallOption = () => {
        document.querySelectorAll('.pwa-install-btn').forEach((btn) => {
            btn.classList.remove('is-visible');
        });
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
    });

    document.addEventListener('DOMContentLoaded', () => {
        if (isRunningStandalone()) hideInstallOption();

        document.querySelectorAll('.pwa-install-btn').forEach((btn) => {
            btn.addEventListener('click', async () => {
                if (!deferredPrompt || deferredPrompt === 'installed') return;
                deferredPrompt.prompt();
                await deferredPrompt.userChoice;
                deferredPrompt = null;
                hideInstallOption();
            });
        });
    });

    window.addEventListener('appinstalled', () => {
        deferredPrompt = 'installed';
        hideInstallOption();
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
