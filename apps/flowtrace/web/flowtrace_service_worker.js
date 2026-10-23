'use strict';

// Filled only by tool/web_release/seal_release.py. Never ship the template.
const RELEASE = __FLOWTRACE_MANIFEST__;
const BASE = self.registration.scope;
const PREFIX = 'flowtrace-shell-v1:' + new URL(BASE).pathname + ':';
const CACHE = PREFIX + RELEASE.release_id;
const COMPLETE = new URL('__flowtrace_complete__', BASE).href;
const UPGRADE_LOCK = new URL('__flowtrace_upgrade_lock__', BASE).href;
const LEGACY_CACHES = ['flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest'];
let lockQueue = Promise.resolve();
let activation = null;

function resourceUrl(name) { return new URL(name, BASE).href; }
function reply(event, data) { event.ports[0]?.postMessage(data); }
async function hash(bytes) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))]
    .map((value) => value.toString(16).padStart(2, '0')).join('');
}
async function verified(response, metadata) {
  if (!response || !response.ok || response.type === 'opaque') return false;
  const bytes = await response.clone().arrayBuffer();
  return bytes.byteLength === metadata.bytes && await hash(bytes) === metadata.sha256;
}
async function validateCache() {
  const cache = await caches.open(CACHE);
  const marker = await cache.match(COMPLETE);
  if (!marker || (await marker.text()) !== RELEASE.release_id) return false;
  for (const [name, metadata] of Object.entries(RELEASE.resources)) {
    if (!await verified(await cache.match(resourceUrl(name)), metadata)) return false;
  }
  return true;
}
function lockOperation(action) {
  const pending = lockQueue.then(async () => action(await caches.open(CACHE)));
  // Serialize a status/read with lock acquisition and removal. A failed cache
  // operation does not prevent a later explicit retry from reaching storage.
  lockQueue = pending.catch(() => {});
  return pending;
}
async function storedUpgradeLock(cache) {
  const response = await cache.match(UPGRADE_LOCK);
  if (!response) return null;
  let lock;
  try { lock = await response.json(); } catch (_) { /* invalid marker expires */ }
  if (typeof lock?.token === 'string' && Number.isSafeInteger(lock.expiresAt)
      && lock.expiresAt > Date.now() && lock.expiresAt <= Date.now() + 30000) return lock;
  await cache.delete(UPGRADE_LOCK);
  return null;
}
function acquireUpgradeLock(token) {
  return lockOperation(async (cache) => {
    if (await storedUpgradeLock(cache)) return false;
    await cache.put(UPGRADE_LOCK, new Response(JSON.stringify({token, expiresAt: Date.now() + 25000}),
      {headers: {'Content-Type': 'application/json'}}));
    return true;
  });
}
function releaseUpgradeLock(token) {
  return lockOperation(async (cache) => {
    if ((await storedUpgradeLock(cache))?.token === token) await cache.delete(UPGRADE_LOCK);
  });
}
function hasUpgradeLock() {
  return lockOperation(async (cache) => Boolean(await storedUpgradeLock(cache)));
}
async function installRelease() {
  if (await validateCache()) return;
  // An incomplete candidate can be discarded. A different complete release is
  // never changed or deleted by installation, including on quota/network error.
  await caches.delete(CACHE);
  const cache = await caches.open(CACHE);
  try {
    let completed = 0;
    for (const [name, metadata] of Object.entries(RELEASE.resources)) {
      // Distinguish in-flight/failed downloads belonging to different releases
      // even when their public filenames are stable. Storage keys remain the
      // canonical filenames inside this release's dedicated verified cache.
      const download = new URL(resourceUrl(name));
      download.searchParams.set('flowtrace_release', RELEASE.release_id);
      const response = await fetch(download.href, {cache: 'no-store', credentials: 'omit', redirect: 'error'});
      if (!await verified(response, metadata)) {
        const bytes = await response.clone().arrayBuffer();
        throw Object.assign(new Error('Release resource integrity failed'), {flowtraceReason: 'integrity', flowtraceResource: name,
          flowtraceObserved: {status: response.status, bytes: bytes.byteLength, sha256: await hash(bytes)}});
      }
      await cache.put(resourceUrl(name), response);
      completed += 1;
      for (const client of await appClients()) client.postMessage({
        type: 'FLOWTRACE_PREPARING', completed, total: Object.keys(RELEASE.resources).length,
        releaseId: RELEASE.release_id,
      });
    }
    await cache.put(COMPLETE, new Response(RELEASE.release_id));
  } catch (error) {
    await caches.delete(CACHE);
    for (const client of await appClients()) client.postMessage({
      type: 'FLOWTRACE_PREPARATION_FAILED', releaseId: RELEASE.release_id,
      reason: error.name === 'QuotaExceededError' ? 'storage_quota' : error.flowtraceReason || 'network_or_storage',
      resource: error.flowtraceResource || null,
      observed: error.flowtraceObserved || null,
    });
    throw error;
  }
}
self.addEventListener('install', (event) => event.waitUntil(installRelease()));

self.addEventListener('activate', (event) => event.waitUntil((async () => {
  if (!await validateCache()) throw new Error('Incomplete release cannot activate');
  // A ?v= registration migration may install identical release bytes at a new
  // script URL, so old/new workers share this cache. Its completed prepare
  // lease must not block the newly activated page for another 25 seconds.
  await lockOperation((cache) => cache.delete(UPGRADE_LOCK));
  // Keep the prior version cache as an explicit rollback artifact. No cached
  // accounts, tokens, API payloads or databases are stored in these shell caches.
  // Legacy Flutter's mixed cache can be removed only after our full verification.
  if (new URL(BASE).pathname === '/') {
    for (const name of LEGACY_CACHES) await caches.delete(name);
  }
  const prior = (await caches.keys()).filter((name) => name.startsWith(PREFIX) && name !== CACHE);
  // Keep at most one prior complete version. Never touch Drift/other cache
  // namespaces. Cleanup occurs after activation verification, not on install.
  const completePrior = [];
  for (const name of prior) {
    const cached = await caches.open(name);
    if (await cached.match(COMPLETE)) completePrior.push(name);
    else await caches.delete(name);
  }
  for (const name of completePrior.slice(0, -1)) await caches.delete(name);
  await self.clients.claim();
  for (const client of await appClients()) client.postMessage({type: 'FLOWTRACE_ACTIVATED', releaseId: RELEASE.release_id});
})()));

function keyFor(request) {
  const url = new URL(request.url);
  if (!url.href.startsWith(BASE) || url.origin !== self.location.origin) return null;
  let key;
  try { key = decodeURIComponent(url.pathname.substring(new URL(BASE).pathname.length)); }
  catch (_) { return null; }
  if (/^(api|admin|auth)(\/|$)/.test(key)) return null;
  if (request.mode === 'navigate') return 'index.html';
  return Object.hasOwn(RELEASE.resources, key) ? key : null;
}
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const key = keyFor(event.request);
  if (!key) return;
  event.respondWith((async () => {
    const response = await (await caches.open(CACHE)).match(resourceUrl(key));
    if (await verified(response, RELEASE.resources[key])) return response;
    // Never fall back to the currently deployed server bytes for a missing
    // versioned resource: that would splice two releases into one execution.
    return new Response('流迹离线资源不完整，请联网后重新准备。未同步数据仍以浏览器存储状态为准。', {
      status: 503, headers: {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'},
    });
  })());
});

async function appClients() {
  return (await self.clients.matchAll({type: 'window', includeUncontrolled: true}))
    .filter((client) => client.url.startsWith(BASE) && !/\/(api|admin|auth)(\/|$)/.test(new URL(client.url).pathname));
}
function workerRequest(worker, message, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const channel = new MessageChannel();
    const timer = setTimeout(() => { channel.port1.close(); reject(new Error('Worker did not acknowledge upgrade lock')); }, timeout);
    channel.port1.onmessage = (event) => { clearTimeout(timer); channel.port1.close(); resolve(event.data); };
    worker.postMessage(message, [channel.port2]);
  });
}
async function abortActivation(reason) {
  if (!activation) return;
  const pending = activation;
  activation = null;
  clearTimeout(pending.timer);
  self.registration.active?.postMessage({type: 'FLOWTRACE_UNLOCK', token: pending.token});
  for (const client of await appClients()) client.postMessage({type: 'FLOWTRACE_UPDATE_ABORTED', token: pending.token});
  pending.resolve({ok: false, reason});
}
async function finishActivation() {
  const pending = activation;
  if (!pending || pending.pending.size) return;
  const current = await appClients();
  // A peer rejection/timeout can cancel this round while matchAll is pending.
  // Several final acknowledgements can also reach this await together. Only
  // the still-current round may commit, and each round commits at most once.
  if (activation !== pending || pending.pending.size) return;
  if (current.some((client) => !pending.clients.has(client.id))) {
    await abortActivation('new_tab'); return;
  }
  activation = null;
  clearTimeout(pending.timer);
  try {
    await self.skipWaiting();
    pending.resolve({ok: true, releaseId: RELEASE.release_id});
  } catch (_) {
    self.registration.active?.postMessage({type: 'FLOWTRACE_UNLOCK', token: pending.token});
    for (const client of await appClients()) client.postMessage({type: 'FLOWTRACE_UPDATE_ABORTED', token: pending.token});
    pending.resolve({ok: false, reason: 'activation_failed'});
  }
}
async function requestActivation() {
  if (activation) return {ok: false, reason: 'already_preparing'};
  if (!await validateCache()) return {ok: false, reason: 'incomplete_release'};
  const token = crypto.randomUUID();
  const active = self.registration.active;
  if (active) {
    // Flutter's previous registration can have a ?v= query, while this shell
    // uses an unversioned URL. Always negotiate with the actual active worker;
    // a legacy worker that cannot acknowledge safely vetoes hot activation.
    try {
      const result = await workerRequest(active, {type: 'FLOWTRACE_LOCK', token});
      if (!result.ok) return {ok: false, reason: 'active_worker_busy'};
    } catch (_) { return {ok: false, reason: 'legacy_worker'}; }
  }
  const clients = await appClients();
  return new Promise((resolve) => {
    activation = {token, clients: new Set(clients.map((client) => client.id)), pending: new Set(clients.map((client) => client.id)), resolve};
    activation.timer = setTimeout(() => { void abortActivation('timeout'); }, 15000);
    for (const client of clients) client.postMessage({type: 'FLOWTRACE_PREPARE_UPDATE', token, releaseId: RELEASE.release_id});
    void finishActivation();
  });
}
self.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message !== 'object') return;
  if (message.type === 'FLOWTRACE_STATUS') {
    event.waitUntil(validateCache().then(async (complete) => reply(event, {
      releaseId: RELEASE.release_id, complete, resources: Object.keys(RELEASE.resources).length,
      upgradePending: await hasUpgradeLock(),
    })));
  } else if (message.type === 'FLOWTRACE_LOCK') {
    // Only another worker in this registration may acquire the start-up lock.
    const fromWorker = !event.source?.id && self.registration.waiting
      && event.source?.scriptURL === self.registration.waiting.scriptURL;
    if (!fromWorker || typeof message.token !== 'string') { reply(event, {ok: false}); return; }
    // CacheStorage retains this non-sensitive 25s lease when the browser stops
    // and restarts the active worker during another worker's prepare round.
    event.waitUntil(acquireUpgradeLock(message.token).then((ok) => reply(event, {ok}))
      .catch(() => reply(event, {ok: false})));
  } else if (message.type === 'FLOWTRACE_UNLOCK') {
    event.waitUntil(releaseUpgradeLock(message.token));
  } else if (message.type === 'FLOWTRACE_ACTIVATE') {
    event.waitUntil(requestActivation().then((result) => reply(event, result)));
  } else if (message.type === 'FLOWTRACE_PREPARED' && activation?.token === message.token) {
    if (!activation.clients.has(event.source?.id)) return;
    if (message.ok !== true) event.waitUntil(abortActivation('tab_not_ready'));
    else { activation.pending.delete(event.source.id); event.waitUntil(finishActivation()); }
  }
});
