const SHELL_CACHE = "kincare-shell-v1";

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const scope = self.registration.scope;
    const cache = await caches.open(SHELL_CACHE);
    const response = await fetch(scope, { cache: "reload" });
    if (response.ok) {
      await cache.put(scope, response.clone());
      const html = await response.clone().text();
      const references = [...html.matchAll(/(?:src|href)=["']([^"']+)["']/g)].map((match) => match[1]);
      for (const reference of references) {
        const url = new URL(reference, scope);
        if (url.origin !== self.location.origin || !url.pathname.includes("/assets/")) continue;
        try {
          const asset = await fetch(url.href, { cache: "reload" });
          if (asset.ok) await cache.put(url.href, asset);
        } catch {
          // A failed optional asset does not prevent app-shell installation.
        }
      }
    }
    for (const file of ["manifest.webmanifest", "kincare-icon.svg"]) {
      try {
        const asset = await fetch(new URL(file, scope));
        if (asset.ok) await cache.put(new URL(file, scope), asset);
      } catch { /* Online launch can fill this cache later. */ }
    }
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((key) => key.startsWith("kincare-shell-") && key !== SHELL_CACHE).map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin || !url.href.startsWith(self.registration.scope)) return;
  if (request.mode === "navigate") {
    event.respondWith((async () => {
      try {
        const response = await fetch(request);
        if (response.ok) (await caches.open(SHELL_CACHE)).put(self.registration.scope, response.clone());
        return response;
      } catch {
        return (await caches.match(self.registration.scope)) ?? new Response("KinCare could not load offline because the app shell has not been cached yet.", { status: 503, headers: { "content-type": "text/plain; charset=utf-8" } });
      }
    })());
    return;
  }
  if (!(request.destination === "script" || request.destination === "style" || request.destination === "image" || request.destination === "font" || url.pathname.endsWith(".webmanifest"))) return;
  event.respondWith((async () => {
    const cache = await caches.open(SHELL_CACHE);
    const cached = await cache.match(request);
    if (cached) return cached;
    const response = await fetch(request);
    if (response.ok) await cache.put(request, response.clone());
    return response;
  })());
});
