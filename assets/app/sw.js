// PatataTube offline service worker. Fully implemented in offline-downloads plan Task 6.
self.addEventListener('install', function(){ self.skipWaiting(); });
self.addEventListener('activate', function(e){ e.waitUntil(self.clients.claim()); });
