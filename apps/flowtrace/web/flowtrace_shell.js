'use strict';
(() => {
  const releaseId = '__FLOWTRACE_RELEASE__';
  const sealed = /^[0-9a-f]{64}$/.test(releaseId);
  const base = new URL('.', document.baseURI);
  let registration;
  let barrier;
  let preparedToken;
  let booted = false;
  let offlinePrepared = false;
  let reloading = false;
  let readyResolve;
  let preparationFailure = null;
  const ready = new Promise((resolve) => { readyResolve = resolve; });
  const panel = document.createElement('aside');
  panel.setAttribute('aria-live', 'polite');
  panel.setAttribute('role', 'status');
  Object.assign(panel.style, {position: 'fixed', inset: '12px 12px auto auto', maxWidth: 'min(360px, calc(100vw - 24px))', boxSizing: 'border-box', zIndex: '10000', padding: '12px 16px', borderRadius: '12px', background: '#f4f2ee', color: '#26342f', font: '14px/1.5 sans-serif', boxShadow: '0 2px 12px #0002'});
  const label = document.createElement('span');
  const button = document.createElement('button');
  Object.assign(button.style, {marginLeft: '12px', padding: '5px 12px', cursor: 'pointer'});
  button.hidden = true;
  const dismiss = document.createElement('button');
  dismiss.textContent = '收起提示';
  Object.assign(dismiss.style, {marginLeft: '12px', padding: '5px 12px', cursor: 'pointer'});
  dismiss.hidden = true;
  dismiss.onclick = () => { panel.hidden = true; };
  panel.append(label, button, dismiss);
  document.body.append(panel);
  function show(text, action, callback) {
    panel.hidden = false;
    label.textContent = text;
    button.hidden = !action;
    // Startup checks remain visible until an editor can safely start. Once
    // running, feedback must be dismissible so it cannot cover navigation.
    dismiss.hidden = !booted;
    if (action) { button.textContent = action; button.onclick = callback; }
  }
  function request(worker, type, timeout = 30000) {
    return new Promise((resolve, reject) => {
      if (!worker) { reject(new Error('worker_unavailable')); return; }
      const channel = new MessageChannel();
      const timer = setTimeout(() => { channel.port1.close(); reject(new Error('worker_timeout')); }, timeout);
      channel.port1.onmessage = (event) => { clearTimeout(timer); channel.port1.close(); resolve(event.data); };
      worker.postMessage({type}, [channel.port2]);
    });
  }
  async function status() {
    if (!navigator.serviceWorker?.controller) return {releaseId, complete: false, onlineOnly: true, failureReason: preparationFailure};
    return request(navigator.serviceWorker.controller, 'FLOWTRACE_STATUS');
  }
  async function activateUpdate() {
    if (!registration?.waiting) return {ok: false, reason: 'no_waiting_release'};
    show('正在保存各个窗口中的更改…');
    const result = await request(registration.waiting, 'FLOWTRACE_ACTIVATE', 25000);
    if (!result.ok) show('其他窗口尚未准备好更新。请保存更改后重试，或关闭所有流迹窗口。', '重试', () => { void activateUpdate(); });
    return result;
  }
  function updateAvailable() {
    show('新版已完整准备，保存当前工作后即可更新。', '更新', () => { void activateUpdate(); });
    window.dispatchEvent(new CustomEvent('flowtrace-update-ready'));
  }
  window.FlowTraceShell = Object.freeze({
    releaseId, ready, status, activateUpdate,
    checkForUpdate: async () => { await registration?.update(); return Boolean(registration?.waiting); },
    registerUpdateBarrier(value) {
      if (!value || typeof value.prepare !== 'function' || typeof value.resume !== 'function') throw new TypeError('An update barrier requires prepare and resume');
      if (barrier) throw new Error('An update barrier is already registered');
      barrier = value;
      return () => { if (barrier === value) barrier = null; };
    },
  });
  async function releaseBarrier(token) {
    if (preparedToken !== token) return;
    preparedToken = null;
    try { await barrier?.resume(); } catch (_) { show('无法恢复写入，请关闭并重新打开流迹。'); }
  }
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', async (event) => {
      const message = event.data;
      if (message?.type === 'FLOWTRACE_PREPARING') {
        show(`${booted ? '正在准备新版' : '正在准备离线使用'} ${message.completed}/${message.total}…`);
      } else if (message?.type === 'FLOWTRACE_PREPARATION_FAILED') {
        preparationFailure = ['storage_quota', 'integrity', 'network_or_storage'].includes(message.reason) ? message.reason : 'network_or_storage';
        if (booted && offlinePrepared) show('新版尚未准备完成，当前版本仍可继续使用。', '重新准备', () => { void registration?.update(); });
        else if (booted) show('离线准备未完成，当前仅可联网使用。请保留未同步数据的备份。', '重新准备', () => location.reload());
      } else if (message?.type === 'FLOWTRACE_PREPARE_UPDATE') {
        let ok = false;
        if (barrier && !preparedToken) {
          preparedToken = message.token;
          const preparingBarrier = barrier;
          try { ok = await preparingBarrier.prepare() === true; } catch (_) { ok = false; }
          // A timeout/peer rejection may arrive while an asynchronous database
          // flush is still running. Resume again after that late flush completes
          // so it cannot leave the surviving old app permanently paused.
          if (preparedToken !== message.token) {
            ok = false;
            try { await preparingBarrier.resume(); } catch (_) { /* already shown by abort */ }
          }
        }
        if (!ok) await releaseBarrier(message.token);
        event.source?.postMessage({type: 'FLOWTRACE_PREPARED', token: message.token, ok});
      } else if (message?.type === 'FLOWTRACE_UPDATE_ABORTED') {
        await releaseBarrier(message.token);
      }
    });
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      // First install claims before boot and needs no reload. During an update,
      // every running old app has completed its persistence barrier beforehand.
      if (booted && preparedToken && !reloading) { reloading = true; location.reload(); }
      else if (booted) {
        // A slow first installation may finish after the online-only UI has
        // started. Claiming that same version must not reload an editor whose
        // draft/outbox barrier has never run.
        void status().then((current) => {
          if (current.complete && current.releaseId === releaseId) {
            offlinePrepared = true; panel.hidden = true;
            window.dispatchEvent(new CustomEvent('flowtrace-offline-prepared'));
          }
        }).catch(() => { /* keep the explicit online-only feedback */ });
      }
    });
  }
  function startFlutter(offlineReady, failureReason = null) {
    if (booted) return;
    booted = true;
    dismiss.hidden = false;
    offlinePrepared = offlineReady;
    readyResolve({releaseId, offlineReady, failureReason});
    window.dispatchEvent(new CustomEvent('flowtrace-shell-ready', {detail: {releaseId, offlineReady}}));
    const script = document.createElement('script');
    script.src = new URL('flutter_bootstrap.js', base).href;
    script.async = true;
    script.onerror = () => show('应用资源加载失败，请检查网络后重试。', '重试', () => location.reload());
    document.body.append(script);
    if (offlineReady) panel.hidden = true;
  }
  function onlineOnly(reason = 'unsupported_or_unsealed') {
    show('离线准备未完成，当前仅可联网使用。请保留未同步数据的备份。', '重新准备', () => location.reload());
    startFlutter(false, preparationFailure || reason);
  }
  function watchInstall(worker) {
    if (!worker) return;
    worker.addEventListener('statechange', () => {
      if (worker.state === 'installed' && registration.waiting) updateAvailable();
    });
  }
  async function boot() {
    if (!sealed || !('serviceWorker' in navigator) || !window.isSecureContext) { onlineOnly(); return; }
    show('正在准备离线使用…');
    try {
      registration = await navigator.serviceWorker.register(new URL('flutter_service_worker.js', base), {scope: base.href, updateViaCache: 'none'});
      registration.addEventListener('updatefound', () => watchInstall(registration.installing));
      watchInstall(registration.installing);
      // ready never rejects on failed installation; race it against the actual
      // installing worker's redundant state and a bounded networking deadline.
      await Promise.race([
        navigator.serviceWorker.ready,
        new Promise((_, reject) => {
          const worker = registration.installing;
          if (worker) worker.addEventListener('statechange', () => { if (worker.state === 'redundant') reject(new Error('install_failed')); });
          setTimeout(() => reject(new Error('install_timeout')), 45000);
        }),
      ]);
      // The first install's ready can precede claim/controllerchange by a tick.
      if (!navigator.serviceWorker.controller) await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('controller_timeout')), 5000);
        navigator.serviceWorker.addEventListener('controllerchange', () => { clearTimeout(timer); resolve(); }, {once: true});
      });
      const current = await status();
      if (!current.complete) throw new Error('cache_incomplete');
      if (current.upgradePending) { show('另一个窗口正在更新，请稍候。', '重新打开', () => location.reload()); return; }
      if (current.releaseId !== releaseId) {
        // A legacy/old controller returned live HTML. Reload through its pinned
        // index rather than run new HTML with an older worker's resource map.
        if (!sessionStorage.getItem('flowtrace-shell-version-reload')) {
          sessionStorage.setItem('flowtrace-shell-version-reload', '1'); location.reload(); return;
        }
        throw new Error('controller_release_mismatch');
      }
      sessionStorage.removeItem('flowtrace-shell-version-reload');
      startFlutter(true);
      if (registration.waiting) updateAvailable();
    } catch (_) {
      // A controlled page must confirm both its complete package and the
      // durable upgrade lock before starting an editor. A failed status check
      // cannot safely fall through to the first-install online-only path.
      if (navigator.serviceWorker.controller) {
        show('应用资源检查未完成，请联网后重新打开。未同步数据仍保留在浏览器存储中。', '重试', () => location.reload());
      } else onlineOnly();
    }
  }
  void boot();
})();
