var CACHE='kylogram-v73';
var FILES=['./','index.html','manifest.json','icon-192.png','icon-512.png','apple-touch-icon.png'];
self.addEventListener('install',function(e){e.waitUntil(caches.open(CACHE).then(function(c){return c.addAll(FILES)}));self.skipWaiting()});
self.addEventListener('activate',function(e){e.waitUntil(caches.keys().then(function(k){return Promise.all(k.filter(function(n){return n!==CACHE}).map(function(n){return caches.delete(n)}))}));self.clients.claim().then(function(){return self.clients.matchAll({type:'window'})}).then(function(cs){cs.forEach(function(c){try{c.navigate(c.url)}catch(e){}})})});
self.addEventListener('fetch',function(e){
  if(e.request.method!=='GET')return;
  e.respondWith(fetch(e.request,{cache:'no-store'}).then(function(r){var c=r.clone();caches.open(CACHE).then(function(x){x.put(e.request,c)});return r}).catch(function(){return caches.match(e.request).then(function(m){return m||caches.match('index.html')})}));
});
