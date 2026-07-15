const CACHE_NAME = 'study-room-app-db-2';
self.addEventListener('install', event => self.skipWaiting());
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.map(key => caches.delete(key)))));
  self.clients.claim();
});
self.addEventListener('fetch', event => {
  return;
});
