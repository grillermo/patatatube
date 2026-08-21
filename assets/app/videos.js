var activePreloadController = null;
var activePreloadVideoId = null;
var completedPreloads = new Set();

function stopAllPreloads(){
  if(!activePreloadController) return;
  try { activePreloadController.abort(); } catch (_err) {}
  activePreloadController = null;
  activePreloadVideoId = null;
}

function resolveVideoSource(video){
  if(video.currentSrc) return video.currentSrc;
  if(video.src) return video.src;
  var source = video.querySelector('source[src]');
  return source ? source.getAttribute('src') : null;
}

function pauseOtherVideos(activeVideo){
  document.querySelectorAll('video[id]').forEach(function(v){
    if(v === activeVideo || v.paused || v.ended) return;
    try { v.pause(); } catch (_err) {}
  });
}

function preloadEntireVideo(video){
  if(typeof fetch !== 'function' || typeof AbortController === 'undefined') return;

  var src = resolveVideoSource(video);
  if(!src) return;
  if(completedPreloads.has(video.id)) return;
  if(activePreloadVideoId === video.id && activePreloadController) return;

  stopAllPreloads();
  var controller = new AbortController();
  activePreloadController = controller;
  activePreloadVideoId = video.id;

  fetch(src, { signal: controller.signal, cache: 'force-cache', credentials: 'same-origin' })
    .then(function(resp){
      if(activePreloadVideoId !== video.id || activePreloadController !== controller) return;
      if(!resp.ok || !resp.body || typeof resp.body.getReader !== 'function') return;

      var reader = resp.body.getReader();
      function pump(){
        return reader.read().then(function(step){
          if(step.done) {
            completedPreloads.add(video.id);
            return;
          }
          if(activePreloadVideoId !== video.id || activePreloadController !== controller) {
            try { reader.cancel(); } catch (_err) {}
            return;
          }
          return pump();
        });
      }
      return pump();
    })
    .catch(function(err){
      if(err && err.name === 'AbortError') return;
    })
    .finally(function(){
      if(activePreloadVideoId === video.id && activePreloadController === controller) {
        activePreloadVideoId = null;
        activePreloadController = null;
      }
    });
}

function exitFullscreen(v){
  try {
    if(v && typeof v.webkitExitFullscreen === 'function' && v.webkitDisplayingFullscreen) {
      v.webkitExitFullscreen();
      return;
    }
    if(document.exitFullscreen && document.fullscreenElement) {
      var p = document.exitFullscreen();
      if(p && typeof p.catch === 'function') p.catch(function(){});
    } else if(document.webkitExitFullscreen && document.webkitFullscreenElement) {
      document.webkitExitFullscreen();
    }
  } catch(e) {}
}

function enterFullscreen(v){
  if(document.fullscreenElement || document.webkitFullscreenElement) return;
  if(v.webkitDisplayingFullscreen) return;
  try {
    if(typeof v.webkitEnterFullscreen === 'function') {
      v.webkitEnterFullscreen();
    } else if(typeof v.requestFullscreen === 'function') {
      var p = v.requestFullscreen();
      if(p && typeof p.catch === 'function') p.catch(function(){});
    } else if(typeof v.webkitRequestFullscreen === 'function') {
      v.webkitRequestFullscreen();
    }
  } catch(e) {}
}

var AUTOPLAY_KEY = 'patatatube:autoplay';

function autoplayEnabled(){
  try { return localStorage.getItem(AUTOPLAY_KEY) === '1'; } catch(_err) { return false; }
}

var autoplayToggle = document.getElementById('autoplay-toggle');
if(autoplayToggle){
  autoplayToggle.setAttribute('aria-pressed', autoplayEnabled() ? 'true' : 'false');
  autoplayToggle.addEventListener('click', function(){
    var next = !autoplayEnabled();
    try { localStorage.setItem(AUTOPLAY_KEY, next ? '1' : '0'); } catch(_err) {}
    autoplayToggle.setAttribute('aria-pressed', next ? 'true' : 'false');
  });
}

function playNextVideo(current){
  var vids = Array.prototype.slice.call(document.querySelectorAll('video[id]'));
  var idx = vids.indexOf(current);
  if(idx === -1 || idx + 1 >= vids.length) return;
  var next = vids[idx + 1];
  try { next.scrollIntoView({behavior: 'smooth', block: 'center'}); } catch(_err) { next.scrollIntoView(); }
  var p = next.play();
  if(p && typeof p.catch === 'function') p.catch(function(){});
}

var PREVIEW_CACHE_PREFIX = 'patatatube:preview:';

function previewCacheKey(url){
  return PREVIEW_CACHE_PREFIX + url;
}

function readPreviewCache(url){
  try {
    var raw = localStorage.getItem(previewCacheKey(url));
    if(!raw) return null;
    var parsed = JSON.parse(raw);
    return parsed && parsed.data ? parsed.data : null;
  } catch(_err) {
    return null;
  }
}

function evictOldestPreview(){
  var oldestKey = null;
  var oldestTs = Infinity;
  for(var i = 0; i < localStorage.length; i++){
    var key = localStorage.key(i);
    if(!key || key.indexOf(PREVIEW_CACHE_PREFIX) !== 0) continue;
    try {
      var parsed = JSON.parse(localStorage.getItem(key));
      if(parsed && typeof parsed.ts === 'number' && parsed.ts < oldestTs){
        oldestTs = parsed.ts;
        oldestKey = key;
      }
    } catch(_err) {}
  }
  if(!oldestKey) return false;
  localStorage.removeItem(oldestKey);
  return true;
}

function writePreviewCache(url, dataUrl){
  var payload = JSON.stringify({data: dataUrl, ts: Date.now()});
  while(true){
    try {
      localStorage.setItem(previewCacheKey(url), payload);
      return;
    } catch(_err) {
      if(!evictOldestPreview()) return;
    }
  }
}

function applyPreview(video, url){
  if(!url) return;
  var cached = readPreviewCache(url);
  if(cached){
    video.poster = cached;
    return;
  }

  fetch(url, {credentials: 'same-origin'})
    .then(function(resp){
      if(!resp.ok) throw new Error('preview fetch failed');
      return resp.blob();
    })
    .then(function(blob){
      return new Promise(function(resolve, reject){
        var reader = new FileReader();
        reader.onload = function(){ resolve(reader.result); };
        reader.onerror = reject;
        reader.readAsDataURL(blob);
      });
    })
    .then(function(dataUrl){
      video.poster = dataUrl;
      writePreviewCache(url, dataUrl);
    })
    .catch(function(_err){});
}

// Replay forever: a per-video loop toggle that outlives a reload. Setting
// `loop` is the primary mechanism; it also suppresses `ended`, so a looping
// video never hands off to autoplay. The `ended` handler below restarts the
// video anyway, for players that fire `ended` despite `loop` (iOS's native
// fullscreen player is the one that does).
var LOOP_KEY = 'patatatube:loop';

function loopedIds(){
  try {
    var raw = localStorage.getItem(LOOP_KEY);
    var ids = raw ? JSON.parse(raw) : [];
    return Array.isArray(ids) ? ids.map(String) : [];
  } catch(_err) { return []; }
}

function isLooping(video){
  if(!video) return false;
  return video.loop || loopedIds().indexOf(String(video.id).slice(1)) !== -1;
}

function setLooped(id, on){
  var ids = loopedIds().filter(function(x){ return x !== id; });
  if(on) ids.push(id);
  try { localStorage.setItem(LOOP_KEY, JSON.stringify(ids)); } catch(_err) {}
}

function restartVideo(video){
  try { video.currentTime = 0; } catch(_err) {}
  var p = video.play();
  if(p && typeof p.catch === 'function') p.catch(function(){});
}

document.querySelectorAll('.loop-btn').forEach(function(btn){
  var id = btn.getAttribute('data-video-id');
  var video = document.getElementById('v' + id);

  function apply(on){
    if(video) video.loop = on;
    btn.setAttribute('aria-pressed', on ? 'true' : 'false');
  }

  apply(loopedIds().indexOf(id) !== -1);

  btn.addEventListener('click', function(){
    var on = btn.getAttribute('aria-pressed') !== 'true';
    setLooped(id, on);
    apply(on);
    // Toggling it on at the very end of a finished video should replay now,
    // not on some future end that already happened.
    if(on && video && video.ended) restartVideo(video);
  });
});

function cinemaActiveCard(){
  return document.querySelector('.card.cinema-active');
}

function setCinema(card, on){
  var btn = card.querySelector('.cinema-btn');
  card.classList.toggle('cinema-active', on);
  document.body.classList.toggle('cinema-mode', on);
  if(btn) btn.setAttribute('aria-pressed', on ? 'true' : 'false');
  var video = card.querySelector('video');
  if(on){
    // The native fullscreen a play() would trigger fights with cinema mode, so
    // step out of it and let the fixed card be the expanded view. The body class
    // is already set above, so the play handler below won't re-enter it either.
    exitFullscreen(video);
    if(video && video.paused){
      var p = video.play();
      if(p && typeof p.catch === 'function') p.catch(function(){});
    }
  } else {
    try { card.scrollIntoView({block: 'center'}); } catch(_err) {}
  }
}

document.querySelectorAll('.cinema-btn').forEach(function(btn){
  btn.addEventListener('click', function(){
    var card = btn.closest('.card');
    if(!card) return;
    var on = !card.classList.contains('cinema-active');
    var current = cinemaActiveCard();
    if(current && current !== card) setCinema(current, false);
    setCinema(card, on);
  });
});

document.addEventListener('keydown', function(e){
  if(e.key !== 'Escape') return;
  var card = cinemaActiveCard();
  if(card) setCinema(card, false);
});

document.querySelectorAll('video[id]').forEach(function(v){
  var wrap = v.closest('.video-wrap');
  var previewSrc = v.getAttribute('data-preview-src');
  if(previewSrc) applyPreview(v, previewSrc);

  var overlay = wrap ? wrap.querySelector('.name-overlay') : null;
  if(overlay){
    overlay.addEventListener('click', function(){
      var p = v.play();
      if(p && typeof p.catch === 'function') p.catch(function(){});
    });
  }

  v.addEventListener('play', function(){
    if(wrap) wrap.classList.add('is-playing');
    pauseOtherVideos(v);
    preloadEntireVideo(v);
    if(!document.body.classList.contains('cinema-mode')) enterFullscreen(v);
  });
  v.addEventListener('pause', function(){
    if(wrap) wrap.classList.remove('is-playing');
    if(activePreloadVideoId === v.id) {
      stopAllPreloads();
    }
  });
  v.addEventListener('ended', function(){
    if(wrap) wrap.classList.remove('is-playing');
    if(activePreloadVideoId === v.id) {
      stopAllPreloads();
    }
    // Replay forever outranks both leaving fullscreen and autoplay-next.
    if(isLooping(v)){
      restartVideo(v);
      return;
    }
    exitFullscreen(v);
    if(autoplayEnabled()) playNextVideo(v);
  });
});

window.addEventListener('pagehide', stopAllPreloads);
document.addEventListener('visibilitychange', function(){
  if(document.hidden) stopAllPreloads();
});
var UPLOAD_TOKEN = window.UPLOAD_TOKEN || "";
document.getElementById('upload-form').addEventListener('submit', function(e){
  e.preventDefault();
  var fileInput = document.getElementById('upload-file-input');
  var groupSelect = document.getElementById('upload-group');
  var errorEl = document.getElementById('upload-error');
  var file = fileInput.files[0];
  if(!file) return;

  errorEl.style.display = 'none';
  var formData = new FormData();
  formData.append('file', file);
  formData.append('group_id', groupSelect.value);

  var xhr = new XMLHttpRequest();
  xhr.open('POST', '/upload/file');
  xhr.setRequestHeader('Authorization', 'Bearer ' + UPLOAD_TOKEN);
  NProgress.start();
  xhr.upload.onprogress = function(evt){
    if(evt.lengthComputable){
      NProgress.set(evt.loaded / evt.total);
    }
  };
  xhr.onload = function(){
    NProgress.done();
    if(xhr.status === 202){
      document.getElementById('upload-dialog').close();
      window.location.reload();
    } else {
      errorEl.textContent = 'Upload failed (' + xhr.status + ')';
      errorEl.style.display = 'block';
    }
  };
  xhr.onerror = function(){
    NProgress.done();
    errorEl.textContent = 'Upload failed - network error';
    errorEl.style.display = 'block';
  };
  xhr.send(formData);
});
