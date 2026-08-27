// IndexedDB primitives for offline video storage. No app logic here.
(function(){
  var DB_NAME = 'patatatube';
  var DB_VERSION = 1;
  var dbPromise = null;

  function openDB(){
    if(dbPromise) return dbPromise;
    dbPromise = new Promise(function(resolve, reject){
      var req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = function(){
        var db = req.result;
        if(!db.objectStoreNames.contains('videos')){
          db.createObjectStore('videos', {keyPath: 'id'});
        }
        if(!db.objectStoreNames.contains('chunks')){
          var chunks = db.createObjectStore('chunks', {keyPath: ['videoId', 'seq']});
          chunks.createIndex('byVideo', 'videoId', {unique: false});
        }
        if(!db.objectStoreNames.contains('groups')){
          db.createObjectStore('groups', {keyPath: 'id'});
        }
        if(!db.objectStoreNames.contains('meta')){
          db.createObjectStore('meta', {keyPath: 'key'});
        }
      };
      req.onsuccess = function(){ resolve(req.result); };
      req.onerror = function(){ reject(req.error); };
    });
    return dbPromise;
  }

  function tx(storeNames, mode){
    return openDB().then(function(db){
      return db.transaction(storeNames, mode);
    });
  }

  function reqToPromise(request){
    return new Promise(function(resolve, reject){
      request.onsuccess = function(){ resolve(request.result); };
      request.onerror = function(){ reject(request.error); };
    });
  }

  function put(store, value){
    return tx([store], 'readwrite').then(function(t){
      var r = reqToPromise(t.objectStore(store).put(value));
      return r;
    });
  }

  function get(store, key){
    return tx([store], 'readonly').then(function(t){
      return reqToPromise(t.objectStore(store).get(key));
    });
  }

  function getAll(store){
    return tx([store], 'readonly').then(function(t){
      return reqToPromise(t.objectStore(store).getAll());
    });
  }

  function del(store, key){
    return tx([store], 'readwrite').then(function(t){
      return reqToPromise(t.objectStore(store).delete(key));
    });
  }

  // All chunk records for one video, ordered by seq.
  function getChunksFor(videoId){
    return tx(['chunks'], 'readonly').then(function(t){
      var idx = t.objectStore('chunks').index('byVideo');
      return reqToPromise(idx.getAll(IDBKeyRange.only(videoId)));
    }).then(function(rows){
      rows.sort(function(a, b){ return a.seq - b.seq; });
      return rows;
    });
  }

  function deleteChunksFor(videoId){
    return tx(['chunks'], 'readwrite').then(function(t){
      var idx = t.objectStore('chunks').index('byVideo');
      return new Promise(function(resolve, reject){
        var cur = idx.openKeyCursor(IDBKeyRange.only(videoId));
        cur.onsuccess = function(){
          var c = cur.result;
          if(!c){ resolve(); return; }
          t.objectStore('chunks').delete(c.primaryKey);
          c.continue();
        };
        cur.onerror = function(){ reject(cur.error); };
      });
    });
  }

  window.PtIDB = {
    put: put, get: get, getAll: getAll, del: del,
    getChunksFor: getChunksFor, deleteChunksFor: deleteChunksFor,
    open: openDB
  };
})();
