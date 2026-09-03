// ============================================================
// Smart Academy — Service Worker
// ============================================================

const CACHE_NAME = 'smart-academy-cache-v195';

const STATIC_ASSETS = [
    '/',
    '/index.html',
    '/student-login/index.html',
    '/css/style.css',
    '/js/app.js',
    '/manifest.json',
    '/assets/images/SMART ACADEMY.png'
];

const GUARDED_PATHS = [
    '/student-dashboard.html',
    '/teacher-dashboard.html',
    '/supervisor-dashboard.html',
    '/supervisor-students.html',
    '/supervisor-teachers.html',
    '/manager-dashboard.html',
    '/js/route-guard.js'
];

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME)
            .then((cache) => cache.addAll(STATIC_ASSETS))
            .then(() => self.skipWaiting())
    );
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then((keys) =>
            Promise.all(
                keys
                    .filter((key) => key !== CACHE_NAME)
                    .map((key) => caches.delete(key))
            )
        ).then(() => self.clients.claim())
    );
});

// -------------------- Fetch --------------------
self.addEventListener('fetch', (event) => {
    const requestUrl = new URL(event.request.url);

    if (requestUrl.pathname.startsWith('/student/') || requestUrl.pathname.startsWith('/dashboard') ||
        GUARDED_PATHS.includes(requestUrl.pathname)) {
        event.respondWith(
            fetch(event.request).catch(() => caches.match(event.request))
        );
        return;
    }

    event.respondWith(
        caches.match(event.request).then((cachedResponse) => {
            const fetchPromise = fetch(event.request).then((networkResponse) => {
                if (event.request.method === 'GET' && networkResponse && networkResponse.ok) {
                    const responseToCache = networkResponse.clone();
                    caches.open(CACHE_NAME).then((cache) => cache.put(event.request, responseToCache));
                }
                return networkResponse;
            }).catch(() => cachedResponse);

            return cachedResponse || fetchPromise;
        })
    );
});

// -------------------- Push (تذكير قبل الحصة بـ 10 دقائق) --------------------
self.addEventListener('push', (event) => {
    let payload = { title: 'سمارت أكاديمي', body: 'عندك تذكير جديد.', link: null };

    try {
        if (event.data) payload = Object.assign(payload, event.data.json());
    } catch (e) {
        // تجاهل — نستخدم القيم الافتراضية فوق
    }

    event.waitUntil(
        self.registration.showNotification(payload.title, {
            body: payload.body,
            icon: '/assets/images/SMART ACADEMY.png',
            badge: '/assets/images/SMART ACADEMY.png',
            data: { link: payload.link },
            dir: 'rtl',
            lang: 'ar'
        })
    );
});

self.addEventListener('notificationclick', (event) => {
    event.notification.close();
    const link = event.notification.data && event.notification.data.link;
    const targetUrl = link || '/';

    event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
            for (const client of windowClients) {
                if (client.url === targetUrl && 'focus' in client) return client.focus();
            }
            if (clients.openWindow) return clients.openWindow(targetUrl);
        })
    );
});
