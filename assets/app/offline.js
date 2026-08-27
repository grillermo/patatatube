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

  window.PtOffline = window.PtOffline || {};
  window.PtOffline._runDownload = runDownload;
  window.PtOffline._setState = setState;
  window.PtOffline._loadRow = loadRow;
  window.PtOffline._active = active;
})();
