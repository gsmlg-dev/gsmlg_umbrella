
export const registerSW = () => {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker
      .register("/assets/sw.js", {
        scope: "/",
        updateViaCache: 'imports',
      })
      .then((registration) => {
        console.log('navigator.serviceWorker.register', registration);
        let serviceWorker;
        if (registration.installing) {
          serviceWorker = registration.installing;
          console.log('service worker:', "installing");
        } else if (registration.waiting) {
          serviceWorker = registration.waiting;
          console.log('service worker:', "waiting");
        } else if (registration.active) {
          serviceWorker = registration.active;
          console.log('service worker:', "active");
        }
        if (serviceWorker) {
          console.log('serviceWorker.state', serviceWorker.state);
          serviceWorker.addEventListener("statechange", (e) => {
            console.log('serviceWorker.statechange', e.target.state);
          });
          console.log('serviceWorker', serviceWorker);
        }
      })
      .catch((error) => {
        // Something went wrong during registration. The service-worker.js file
        // might be unavailable or contain a syntax error.
        console.error('service worker error', error)
      });

      navigator.serviceWorker.ready.then(registration => {
        console.log('service worker will get subscription');
        return registration.pushManager.getSubscription()
          .then(subscription => {
            console.log('service worker get subscription', subscription);
            if (subscription) {
              return subscription;
            }

            return fetch('/api/vapid-public-key')
              .then(response => response.json())
              .then(data => {
                console.log('service worker get vapid-public-key', data);
                const publicKey = base64UrlToUint8Array(data.public_key);

                return registration.pushManager.subscribe({
                  userVisibleOnly: true,
                  applicationServerKey: publicKey
                });
              });
          });
        })
        .then(subscription => {
          console.log('service worker new client subscription', subscription);
          return fetch('/api/subscribe', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json'
            },
            body: JSON.stringify({ subscription })
          });
        })
        .catch(err => {
          console.error('Push registration failed:', err);
        });
  } else {
    // The current browser doesn't support service workers.
    // Perhaps it is too old or we are not in a Secure Context.
    console.log(`The current browser doesn't support service workers.`);
  }


  function base64UrlToUint8Array(base64Url) {
    const padding = '='.repeat((4 - (base64Url.length % 4)) % 4);
    const base64 = (base64Url + padding).replace(/-/g, '+').replace(/_/g, '/');
    const rawData = atob(base64);
    return Uint8Array.from([...rawData].map(char => char.charCodeAt(0)));
  }
};
