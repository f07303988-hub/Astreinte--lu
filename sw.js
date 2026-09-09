// Pasly Astreinte — service worker
// Cache-first strategy pour l'app shell + mise en cache "à l'usage" de la
// bibliothèque cartographique (Leaflet) et des tuiles OpenStreetMap déjà
// consultées, pour que la carte reste utilisable hors connexion sur les
// zones déjà visitées.
const CACHE_NAME = "pasly-astreinte-v2";
const SHELL_FILES = [
  "./index.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png"
];
// Bibliothèque carto : mise en cache "best effort" et individuelle, pour
// qu'un souci réseau sur ces fichiers ne fasse pas échouer l'installation
// de l'app shell elle-même.
const MAP_LIB_FILES = [
  "https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css",
  "https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE_NAME);
      try{ await cache.addAll(SHELL_FILES); }catch(e){}
      await Promise.all(MAP_LIB_FILES.map(async (url) => {
        try{
          const res = await fetch(url, { mode: "cors" });
          if(res && res.ok) await cache.put(url, res);
        }catch(e){}
      }));
    })()
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

function isMapTile(url){
  return /(^|\.)tile\.openstreetmap\.org$/.test(url.hostname);
}
function isMapLib(url){
  return url.hostname === "cdnjs.cloudflare.com" && url.pathname.includes("/leaflet/");
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  const sameOrigin = url.origin === self.location.origin;

  // Ressources externes non liées à la carte (ex: liens "Itinéraire" vers
  // Google Maps) : réseau normal, jamais interceptées ni mises en cache.
  if (!sameOrigin && !isMapTile(url) && !isMapLib(url)) return;

  // Cache-first avec mise à jour en arrière-plan pour l'app shell, la lib
  // carto et les tuiles déjà vues (fonctionne aussi pour les réponses
  // "opaques" des tuiles, chargées sans CORS).
  event.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req)
        .then((res) => {
          if (res && (res.status === 200 || res.type === "opaque")) {
            const clone = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, clone)).catch(() => {});
          }
          return res;
        })
        .catch(() => cached);
      return cached || network;
    })
  );
});
