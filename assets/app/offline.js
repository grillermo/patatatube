// Offline downloads: chunked ArrayBuffer storage in IndexedDB + sync buttons.
(function(){
  var CHUNK_SIZE = 6 * 1024 * 1024;
  var MAX_CONCURRENT = 2;
  var idb = window.PtIDB;

  var active = {};        // videoId -> {controller, progressCb}
  var queue = [];         // pending videoId starts
  var runningCount = 0;

  function streamUrl(id){ return '/videos/' + id + '/stream'; }

  function loadRow(id){
    return idb.get('videos', id).then(function(row){ return row || null; });
  }

  // How many contiguous bytes we already have on disk for a resume.
  function bytesOnDisk(row){
    return row && typeof row.receivedBytes === 'number' ? row.receivedBytes : 0;
  }

  function setState(id, patch){
    return loadRow(id).then(function(row){
      var next = row || {id: id};
      for(var k in patch){ if(patch.hasOwnProperty(k)) next[k] = patch[k]; }
      return idb.put('videos', next).then(function(){ return next; });
    });
  }

  function runDownload(id, onProgress){
    var controller = new AbortController();
    active[id] = {controller: controller, progressCb: onProgress};

    return loadRow(id).then(function(row){
        // Only whole chunks are durable; resume from the last chunk boundary.
        var rawStart = bytesOnDisk(row);
        var start = Math.floor(rawStart / CHUNK_SIZE) * CHUNK_SIZE;
      var headers = {};
      if(start > 0) headers['Range'] = 'bytes=' + start + '-';
      return fetch(streamUrl(id), {
        signal: controller.signal,
        credentials: 'same-origin',
        headers: headers
      }).then(function(resp){
        // 206 = resumed range; 200 = server ignored/lacked range, restart clean.
        if(resp.status === 200 && start > 0){
          return idb.deleteChunksFor(id).then(function(){
            return startFromResponse(id, resp, 0, 0);
          });
        }
        if(resp.status !== 200 && resp.status !== 206){
          throw new Error('stream http ' + resp.status);
        }
        var total = totalBytesFromResponse(resp, start);
        var seqStart = start > 0 ? seqCountForBytes(start) : 0;
        return startFromResponse(id, resp, start, seqStart, total);
      });
    });

    function startFromResponse(id, resp, received, seq, total){
      var mime = resp.headers.get('Content-Type') || 'video/mp4';
      var reader = resp.body.getReader();
      var carry = new Uint8Array(0);
      var receivedBytes = received;
      var seqIdx = seq;

      function flush(buf){
        return idb.put('chunks', {videoId: id, seq: seqIdx, data: buf.buffer});
      }

      function pump(){
        return reader.read().then(function(step){
          if(active[id] && active[id].controller !== controller) {
            // Superseded (cancel/pause replaced us) — stop silently.
            return;
          }
          if(step.done){
            var tail = carry.length > 0
              ? flush(carry).then(function(){ receivedBytes += carry.length; seqIdx++; })
              : Promise.resolve();
            return tail.then(function(){
              return setState(id, {
                mime: mime,
                receivedBytes: receivedBytes,
                byteLength: receivedBytes,
                chunkCount: seqIdx,
                syncState: 'downloaded'
              });
            });
          }
          var incoming = step.value;
          var merged = new Uint8Array(carry.length + incoming.length);
          merged.set(carry, 0);
          merged.set(incoming, carry.length);
          carry = merged;

          var writes = Promise.resolve();
          while(carry.length >= CHUNK_SIZE){
            (function(){
              var slice = carry.slice(0, CHUNK_SIZE);
              carry = carry.slice(CHUNK_SIZE);
              writes = writes.then(function(){ return flush(slice); }).then(function(){
                receivedBytes += slice.length;
                seqIdx++;
              });
            })();
          }
          return writes.then(function(){
            return setState(id, {mime: mime, receivedBytes: receivedBytes, syncState: 'downloading'})
              .then(function(){
                if(active[id] && active[id].progressCb && total){
                  active[id].progressCb(receivedBytes / total);
                }
                return pump();
              });
          });
        });
      }
      return pump();
    }
  }

  function totalBytesFromResponse(resp, start){
    var cr = resp.headers.get('Content-Range'); // "bytes s-e/total"
    if(cr){
      var m = /\/(\d+)\s*$/.exec(cr);
      if(m) return parseInt(m[1], 10);
    }
    var len = resp.headers.get('Content-Length');
    if(len) return start + parseInt(len, 10);
    return 0;
  }

  // Resume writes new chunks starting after whole chunks already stored.
  function seqCountForBytes(bytes){
    return Math.floor(bytes / CHUNK_SIZE);
  }

  function pumpQueue(){
    while(runningCount < MAX_CONCURRENT && queue.length){
      var job = queue.shift();
      runningCount++;
      runDownload(job.id, job.onProgress)
        .then(function(){ if(job.onDone) job.onDone(null); })
        .catch(function(err){
          if(err && err.name === 'AbortError'){ if(job.onDone) job.onDone('aborted'); return; }
          setState(job.id, {syncState: 'missing'});
          if(job.onDone) job.onDone(err);
        })
        .then(function(){ runningCount--; delete active[job.id]; pumpQueue(); });
    }
  }

  function start(id, onProgress, onDone){
    if(active[id]) return;                    // already downloading
    queue.push({id: id, onProgress: onProgress, onDone: onDone});
    setState(id, {syncState: 'downloading'});
    pumpQueue();
  }

  // Cancel wipes partial state so a re-tap starts clean (mirrors iOS cancel).
  function cancel(id){
    var a = active[id];
    if(a){ try { a.controller.abort(); } catch(_e){} delete active[id]; }
    queue = queue.filter(function(j){ return j.id !== id; });
    return idb.deleteChunksFor(id).then(function(){
      return setState(id, {syncState: 'missing', receivedBytes: 0, chunkCount: 0, byteLength: 0});
    });
  }

  function remove(id){ return cancel(id); }   // evict a completed download

  function stateOf(id){
    return loadRow(id).then(function(row){
      return row && row.syncState ? row.syncState : 'missing';
    });
  }

  // Reassemble stored chunks into one Blob URL for offline playback.
  function blobUrl(id){
    return idb.getChunksFor(id).then(function(rows){
      if(!rows.length) return null;
      return loadRow(id).then(function(row){
        var parts = rows.map(function(r){ return r.data; });
        var blob = new Blob(parts, {type: (row && row.mime) || 'video/mp4'});
        return URL.createObjectURL(blob);
      });
    });
  }

  window.PtOffline = {
    start: start,
    cancel: cancel,
    remove: remove,
    stateOf: stateOf,
    blobUrl: blobUrl,
    _runDownload: runDownload,
    _setState: setState,
    _loadRow: loadRow,
    _active: active
  };
})();

(function(){
  var api = window.PtOffline;
  if(!api) return;

  function mirrorMetadata(){
    if(!navigator.onLine) return Promise.resolve();
    return Promise.all([
      fetch('/api/videos', {credentials: 'same-origin'}).then(function(r){ return r.ok ? r.json() : null; }),
      fetch('/api/groups', {credentials: 'same-origin'}).then(function(r){ return r.ok ? r.json() : null; })
    ]).then(function(res){
      var videos = res[0], groups = res[1];
      var chain = Promise.resolve();
      // /api/groups returns {"groups": [...]}.
      var groupList = groups && Array.isArray(groups.groups) ? groups.groups : null;
      if(groupList){
        groupList.forEach(function(g){ chain = chain.then(function(){ return window.PtIDB.put('groups', g); }); });
      }
      // /api/videos returns a bare list [...].
      if(Array.isArray(videos)){
        videos.forEach(function(v){
          chain = chain.then(function(){
            return api._loadRow(v.id).then(function(row){
              // Merge server metadata without clobbering local sync/chunk fields.
              var next = row || {id: v.id, syncState: 'missing'};
              next.title = v.title; next.group_id = v.group_id;
              next.plex_kind = v.plex_kind; next.status = v.status;
              return window.PtIDB.put('videos', next);
            });
          });
        });
      }
      return chain;
    }).catch(function(){ /* offline: use whatever is already mirrored */ });
  }

  function renderState(btn, state, progress){
    btn.setAttribute('data-sync-state', state);
    btn.setAttribute('aria-pressed', state === 'downloaded' ? 'true' : 'false');
    if(typeof progress === 'number'){ btn.style.setProperty('--sync-progress', progress.toFixed(3)); }
  }

  // Blob URLs handed to a <video>, by video id. Every entry here pins its
  // video's bytes for as long as it lives, so nothing goes in without a
  // matching releaseOffline().
  var objectUrls = {};
  var preparing = {};

  function videoEl(id){ return document.getElementById('v' + id); }
  function networkSrc(id){ return '/videos/' + id + '/stream'; }

  // Build the offline Blob URL, once, on demand.
  //
  // This is deliberately NOT done for every downloaded video at page load:
  // api.blobUrl reads all of a video's chunks out of IndexedDB into
  // ArrayBuffers and copies them into a Blob, so arming the whole library
  // eagerly pulled every synced byte (twice) into memory before the user had
  // touched anything.
  function prepareOffline(id){
    if(objectUrls[id]) return Promise.resolve(objectUrls[id]);
    if(preparing[id]) return preparing[id];
    preparing[id] = api.blobUrl(id).then(function(url){
      delete preparing[id];
      if(url) objectUrls[id] = url;
      return url;
    }, function(err){
      delete preparing[id];
      throw err;
    });
    return preparing[id];
  }

  function swapToOffline(id, url){
    var video = videoEl(id);
    if(!video || !url) return false;
    if(video.getAttribute('data-offline') === '1') return true;
    var source = video.querySelector('source');
    if(source){ source.setAttribute('src', url); }
    video.setAttribute('data-offline', '1');
    try { video.load(); } catch(_e){}
    return true;
  }

  // Give the bytes back: revoke the URL and put the network source back, so a
  // re-tap (or an eviction) doesn't leave the element pointing at a dead blob.
  function releaseOffline(id){
    var url = objectUrls[id];
    if(!url) return;
    delete objectUrls[id];
    var video = videoEl(id);
    if(video){
      var source = video.querySelector('source');
      if(source && source.getAttribute('src') === url){
        source.setAttribute('src', networkSrc(id));
        try { video.load(); } catch(_e){}
      }
      video.removeAttribute('data-offline');
    }
    try { URL.revokeObjectURL(url); } catch(_e){}
  }

  function releaseAll(){
    Object.keys(objectUrls).forEach(releaseOffline);
  }

  // Mark a downloaded video as offline-capable without reading a single byte.
  // The Blob is built on intent (pointerdown), so the swap inside the `play`
  // handler stays synchronous — an async swap there would lose the user
  // gesture and Safari would refuse to resume.
  function armOffline(id){
    var video = videoEl(id);
    if(!video || video.getAttribute('data-offline-armed') === '1') return;
    video.setAttribute('data-offline-armed', '1');

    video.addEventListener('pointerdown', function(){
      prepareOffline(id).catch(function(){});
    });

    video.addEventListener('play', function(){
      if(video.getAttribute('data-offline') === '1') return;
      var url = objectUrls[id];
      if(!url) return;              // not ready yet: keep streaming, don't stall
      video.pause();
      swapToOffline(id, url);
      var p = video.play();
      if(p && typeof p.catch === 'function') p.catch(function(){});
    });

    // Offline, or a stream that failed: nothing warmed the Blob, so build it
    // now. `capture` because a <source> failure targets the <source>, which
    // does not bubble.
    video.addEventListener('error', function(){
      if(video.getAttribute('data-offline') === '1') return;
      prepareOffline(id).then(function(url){
        if(!swapToOffline(id, url)) return;
        var p = video.play();
        if(p && typeof p.catch === 'function') p.catch(function(){});
      }).catch(function(){});
    }, true);
  }

  function beginDownload(btn, id){
    renderState(btn, 'downloading', 0);
    api.start(id, function(p){ renderState(btn, 'downloading', p); }, function(err){
      if(err){ renderState(btn, 'missing'); return; }
      renderState(btn, 'downloaded');
      armOffline(id);
    });
  }

  // A download interrupted by page-close is left as syncState 'downloading'
  // with partial chunks on disk; nothing restarts it. Re-enqueue each such row
  // through the same path a tap uses, so the engine resumes it (206 Range) and
  // the button reflects live progress. api.start's active[id] guard makes a
  // double call for an already-running id a no-op.
  function resumeInterrupted(){
    return window.PtIDB.getAll('videos').then(function(rows){
      if(!rows) return;
      rows.forEach(function(row){
        if(row && row.syncState === 'downloading'){
          var btn = document.querySelector('.sync-btn[data-video-id="' + row.id + '"]');
          if(btn) beginDownload(btn, row.id);
        }
      });
    }).catch(function(){});
  }

  function wireButton(btn){
    var id = parseInt(btn.getAttribute('data-video-id'), 10);

    api.stateOf(id).then(function(state){
      renderState(btn, state);
      if(state === 'downloaded') armOffline(id);
    });

    btn.addEventListener('click', function(){
      var state = btn.getAttribute('data-sync-state');
      if(state === 'missing'){
        beginDownload(btn, id);
      } else if(state === 'downloading'){
        api.cancel(id).then(function(){ releaseOffline(id); renderState(btn, 'missing'); });
      } else if(state === 'downloaded'){
        if(window.confirm('Remove offline copy?')){
          api.remove(id).then(function(){ releaseOffline(id); renderState(btn, 'missing'); });
        }
      }
    });
  }

  function init(){
    if(navigator.storage && navigator.storage.persist){
      navigator.storage.persist().catch(function(){});
    }
    mirrorMetadata();
    document.querySelectorAll('.sync-btn').forEach(wireButton);
    resumeInterrupted();
    window.addEventListener('pagehide', releaseAll);
  }

  if(document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', init);
  } else { init(); }
})();
