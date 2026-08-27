// PatataTube offline service worker.
// Precache the app shell; serve a cached shell for navigations when offline.
// Media (/stream, /preview) is never cached here — offline video is served
// from IndexedDB Blob URLs by offline.js.
var CACHE = 'ptu-shell-v1';
var SHELL = [
  '/assets/app/videos.css',
  '/assets/app/videos.js',
  '/assets/app/idb.js',
  '/assets/app/offline.js',
  '/assets/vendor/nprogress.js',
  '/assets/vendor/nprogress.css',
  '/manifest.webmanifest',
  '/apple-touch-icon.png'
];

self.addEventListener('install', function(e){
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(function(c){
    // Best-effort: a single 404 must not abort the whole precache.
    return Promise.all(SHELL.map(function(u){
      return c.add(u).catch(function(){});
    }));
  }));
});

self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.map(function(k){
        if(k !== CACHE) return caches.delete(k);
      }));
    }).then(function(){ return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function(e){
  var req = e.request;
  if(req.method !== 'GET') return;
  var url = new URL(req.url);

  // Never intercept media — let the network (or IDB via the page) handle it.
  if(/\/videos\/\d+\/(stream|preview)/.test(url.pathname)) return;

  // Navigations: network-first, fall back to the cached shell HTML offline.
  if(req.mode === 'navigate'){
    e.respondWith(
      fetch(req).then(function(resp){
        var copy = resp.clone();
        caches.open(CACHE).then(function(c){ c.put('/shell', copy); });
        return resp;
      }).catch(function(){
        return caches.match('/shell').then(function(cached){
          return cached || caches.match('/assets/app/videos.js');
        });
      })
    );
    return;
  }

  // Static shell assets: cache-first.
  if(url.pathname.indexOf('/assets/') === 0 || url.pathname === '/manifest.webmanifest'){
    e.respondWith(
      caches.match(req).then(function(hit){
        return hit || fetch(req).then(function(resp){
          var copy = resp.clone();
          caches.open(CACHE).then(function(c){ c.put(req, copy); });
          return resp;
        });
      })
    );
  }
});
