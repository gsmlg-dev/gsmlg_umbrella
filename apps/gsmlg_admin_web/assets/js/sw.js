const CACHE_VERSION = 1;
const CURRENT_CACHES = {
  gsmlg: `gsmlg-admin-web-cache-v${CACHE_VERSION}`,
};

console.log('serviceWorker', 'running');

self.addEventListener('install', (event) => {
  console.log('serviceWorker', 'install', event);
  event.waitUntil(caches.open(CURRENT_CACHES.gsmlg));
});

self.addEventListener("activate", (event) => {
  const expectedCacheNamesSet = new Set(Object.values(CURRENT_CACHES));
  event.waitUntil(
    caches.keys().then((cacheNames) =>
      Promise.all(
        cacheNames.map((cacheName) => {
          if (!expectedCacheNamesSet.has(cacheName)) {
            return caches.delete(cacheName);
          }
        }),
      ),
    ),
  );
});

self.addEventListener("fetch", (event) => {
  const method = event.request.method;

  event.respondWith(
    caches.open(CURRENT_CACHES.gsmlg).then((cache) => {
      return cache
        .match(event.request)
        .then((response) => {
          if (method === "GET" && response) {
            return response;
          }

          // We call .clone() on the request since we might use it
          // in a call to cache.put() later on.
          // Both fetch() and cache.put() "consume" the request,
          // so we need to make a copy.
          // (see https://developer.mozilla.org/en-US/docs/Web/API/Request/clone)
          return fetch(event.request.clone()).then((response) => {
            if (
              method === "GET" && 
              response.status < 400 &&
              response.headers.has("content-type") &&
              response.headers.get("content-type").match(/(^font\/)|(^text\/)|(^image\/)/i)
            ) {
              console.log("  Caching the response to", event.request.url);

              cache.put(event.request, response.clone());
            }

            return response;
          });
        })
        .catch((error) => {
          // This catch() will handle exceptions that arise from the match()
          // or fetch() operations.
          // Note that a HTTP error response (e.g. 404) will NOT trigger
          // an exception.
          // It will return a normal response object that has the appropriate
          // error code set.
          console.error("  Error in fetch handler:", error);

          throw error;
        });
    }),
  );
});

self.addEventListener('message', (event) => {
  console.log("Handling message event for", event.data, event);
  const data = event.data;
  if (data == 'delete cache') {
    caches.keys().then((cacheNames) =>
      Promise.all(
        cacheNames.map((cacheName) => {
          console.log("Deleting out of date cache:", cacheName);
          caches.delete(cacheName);
        }),
      ),
    );
  }
});

self.addEventListener('push', event => {
  console.log('Handling push event for', event.data, event);
  const data = event.data.json();

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.content,
      icon: '/images/logo.svg'
    })
  );
});

self.addEventListener('notificationclick', event => {
  console.log('Handling notificationclick event for', event);
  event.notification.close();
});
