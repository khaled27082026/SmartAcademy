// ============================================================
// Smart Academy — Service Worker
// ============================================================

const CACHE_NAME = 'smart-academy-cache-v46';
const ADMIN_PATH = '/sa-control-x7k9';

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

    if (requestUrl.pathname.startsWith(ADMIN_PATH)) {
        event.respondWith(fetch(event.request));
        return;
    }

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
