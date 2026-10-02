// Dawam Attendance - Service Worker
//
// Goal: every device gets the latest deployed files as soon as possible, and still works offline
// from the last good copy.
//
// DO NOT edit the version by hand. Run:  node tools/bump-version.js <N>
// It sets CACHE_VERSION below AND the ?v=N on every script tag of every page. The in-app
// "new version available" check compares these two numbers, so they must always be equal
// (tests/static-checks.js enforces it). Keep the CACHE_VERSION line exactly in this form.
const CACHE_VERSION = 'dawam-attendance-v75';

const OFFLINE_FALLBACK_PAGE = '/punch/index.html';

// Own files needed offline. Every JS file a page loads must be listed (static check enforces it).
const APP_SHELL = [
  '/',
  '/index.html',
  '/dashboard.html',
  '/punch/index.html',
  '/admin/departments.html',
  '/admin/settings.html',
  '/admin/users.html',
  '/attendance/lop.html',
  '/attendance/overtime.html',
  '/attendance/punch-locations.html',
  '/labor/enroll-self.html',
  '/labor/enroll.html',
  '/labor/import.html',
  '/labor/master.html',
  '/reports/3pl-billing.html',
  '/reports/daily.html',
  '/css/main.css',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/icon-maskable-512.png',
  '/icons/ui-update.png',
  '/js/api/department-api.js',
  '/js/api/enrollment-api.js',
  '/js/api/labor-api.js',
  '/js/api/lop-api.js',
  '/js/api/punch-api.js',
  '/js/api/report-api.js',
  '/js/api/terminal-api.js',
  '/js/api/user-api.js',
  '/js/auth/auth.js',
  '/js/config/client.js',
  '/js/config/supabase.js',
  '/js/ui/app-update.js',
  '/js/ui/pwa-install.js',
  '/js/ui/sync-indicator.js',
  '/js/ui/toast.js',
  '/js/utils/csv-handler.js',
  '/js/utils/date-utils.js',
  '/js/utils/offline-storage.js',
  '/js/utils/photo-utils.js',
  '/js/utils/sync-manager.js'
];

// Third-party files the punch terminal needs offline (libraries and face models). Rarely change.
const CDN_FILES = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
  'https://cdn.jsdelivr.net/npm/face-api.js@0.22.2/dist/face-api.min.js',
  'https://justadudewhohacks.github.io/face-api.js/models/tiny_face_detector_model-weights_manifest.json',
  'https://justadudewhohacks.github.io/face-api.js/models/tiny_face_detector_model-shard1',
  'https://justadudewhohacks.github.io/face-api.js/models/face_landmark_68_model-weights_manifest.json',
  'https://justadudewhohacks.github.io/face-api.js/models/face_landmark_68_model-shard1',
  'https://justadudewhohacks.github.io/face-api.js/models/face_recognition_model-weights_manifest.json',
  'https://justadudewhohacks.github.io/face-api.js/models/face_recognition_model-shard1',
  'https://justadudewhohacks.github.io/face-api.js/models/face_recognition_model-shard2'
];

// Install: activate this version immediately and pre-cache. One missing file must not
// cancel the others, so each file is added on its own.
self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_VERSION).then(cache =>
      Promise.allSettled([...APP_SHELL, ...CDN_FILES].map(url => cache.add(url)))
    )
  );
});

// Activate: delete every cache from other versions, then take control of open pages.
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE_VERSION).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return;       // e.g. chrome-extension://
  if (url.searchParams.has('check')) return;                               // the app's "is there a newer version?" request: never cache it
  if (url.hostname.endsWith('supabase.co')) return;                        // database / storage calls: never cache

  // Our own files: network first (so a new deploy is picked up at once), cached copy only when offline.
  if (url.origin === self.location.origin) {
    event.respondWith(
      fetch(request, { cache: 'no-cache' })
        .then(response => {
          if (response.status === 200) {
            const copy = response.clone();
            caches.open(CACHE_VERSION).then(cache => cache.put(request, copy)).catch(() => {});
          }
          return response;
        })
        .catch(() =>
          caches.match(request, { ignoreSearch: true }).then(cached =>
            cached || (request.mode === 'navigate' ? caches.match(OFFLINE_FALLBACK_PAGE) : undefined)
          )
        )
    );
    return;
  }

  // Third-party files (libraries, face models): cached copy first, they do not change.
  event.respondWith(
    caches.match(request).then(cached => {
      if (cached) return cached;
      return fetch(request).then(response => {
        if (response.status === 200) {
          const copy = response.clone();
          caches.open(CACHE_VERSION).then(cache => cache.put(request, copy)).catch(() => {});
        }
        return response;
      });
    })
  );
});

// Background sync event
self.addEventListener('sync', event => {
  if (event.tag === 'sync-punches') {
    event.waitUntil(syncPunches());
  }
});

// Ask open pages to sync their offline punches (the page's sync-manager does the work).
async function syncPunches() {
  const clients = await self.clients.matchAll();
  clients.forEach(client => client.postMessage({ type: 'SYNC_PUNCHES' }));
}

self.addEventListener('message', event => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
