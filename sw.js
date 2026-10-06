// Eenvoudige service worker: app-bestanden cachen zodat de app snel opent.
// Data (Supabase) wordt nooit gecachet.
const CACHE = "bonusbuddy-v21";
const ASSETS = ["./", "index.html", "styles.css", "app.js", "config.js", "icon.svg", "icon-192.png", "icon-512.png", "apple-touch-icon.png", "manifest.webmanifest"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
  );
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  // Netwerk eerst, cache als terugval
  e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
});
