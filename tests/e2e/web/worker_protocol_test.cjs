// Deterministic worker lifecycle races. Real Chrome coverage remains separate.
'use strict';
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');

function worker(stored = new Map()) {
  const scans = [];
  const messages = [];
  const outcomes = [];
  let activations = 0;
  let failActivation = false;
  const context = vm.createContext({
    URL, setTimeout, clearTimeout, Response,
    caches: {open: async () => ({
      match: async (key) => stored.get(key)?.clone(),
      put: async (key, value) => { stored.set(key, value.clone()); },
      delete: async (key) => stored.delete(key),
    })},
    self: {
      registration: {scope: 'https://fixture.invalid/', active: {postMessage: (message) => messages.push(message)}},
      location: new URL('https://fixture.invalid/flutter_service_worker.js'),
      clients: {matchAll: () => new Promise((resolve) => scans.push(resolve))},
      addEventListener: () => {},
      skipWaiting: async () => { activations += 1; if (failActivation) throw new Error('simulated lifecycle failure'); },
    },
    outcomes,
  });
  const source = readFileSync(path.resolve(__dirname, '../../../apps/flowtrace/web/flowtrace_service_worker.js'), 'utf8')
    .replace('__FLOWTRACE_MANIFEST__', JSON.stringify({release_id: 'a'.repeat(64), resources: {}}));
  vm.runInContext(source, context);
  vm.runInContext(`activation = {token: 'round-one', clients: new Set(['one']), pending: new Set(), resolve: result => outcomes.push(result)};`, context);
  return {
    run: (code) => vm.runInContext(code, context),
    scans, messages, outcomes,
    stored,
    clients: [{id: 'one', url: 'https://fixture.invalid/', postMessage: (message) => messages.push(message)}],
    activations: () => activations,
    fail: () => { failActivation = true; },
  };
}

test('peer cancellation during final client scan cannot activate an abandoned round', async () => {
  const current = worker();
  const finishing = current.run('finishActivation()');
  const cancelling = current.run("abortActivation('tab_not_ready')");
  assert.equal(current.scans.length, 2);
  current.scans[1](current.clients);
  await cancelling;
  current.scans[0](current.clients);
  await finishing;
  assert.equal(current.activations(), 0);
  assert.equal(current.outcomes.length, 1);
  assert.equal(current.outcomes[0].reason, 'tab_not_ready');
});

test('concurrent final acknowledgements activate and resolve exactly once', async () => {
  const current = worker();
  const first = current.run('finishActivation()');
  const second = current.run('finishActivation()');
  assert.equal(current.scans.length, 2);
  current.scans[0](current.clients);
  await first;
  current.scans[1](current.clients);
  await second;
  assert.equal(current.activations(), 1);
  assert.equal(current.outcomes.length, 1);
  assert.equal(current.outcomes[0].ok, true);
});

test('failed worker activation releases the lock and resumes each prepared tab', async () => {
  const current = worker();
  current.fail();
  const finishing = current.run('finishActivation()');
  current.scans[0](current.clients);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(current.scans.length, 2);
  current.scans[1](current.clients);
  await finishing;
  assert.equal(current.outcomes[0].reason, 'activation_failed');
  assert.equal(current.messages.filter((message) => message.type === 'FLOWTRACE_UNLOCK').length, 1);
  assert.equal(current.messages.filter((message) => message.type === 'FLOWTRACE_UPDATE_ABORTED').length, 1);
});

test('active worker restart retains the startup lock and only its token can release it', async () => {
  const before = worker();
  assert.equal(await before.run("acquireUpgradeLock('prepare-one')"), true);
  const restarted = worker(before.stored);
  assert.equal(await restarted.run('hasUpgradeLock()'), true);
  assert.equal(await restarted.run("acquireUpgradeLock('prepare-two')"), false);
  await restarted.run("releaseUpgradeLock('wrong-token')");
  assert.equal(await restarted.run('hasUpgradeLock()'), true);
  await restarted.run("releaseUpgradeLock('prepare-one')");
  assert.equal(await restarted.run('hasUpgradeLock()'), false);
});

test('concurrent lock requests have one winner and expired markers release startup', async () => {
  const current = worker();
  const outcomes = await Promise.all([current.run("acquireUpgradeLock('one')"), current.run("acquireUpgradeLock('two')")]);
  assert.deepEqual(outcomes, [true, false]);
  current.stored.set('https://fixture.invalid/__flowtrace_upgrade_lock__', new Response(JSON.stringify({token: 'old', expiresAt: 1})));
  assert.equal(await current.run('hasUpgradeLock()'), false);
  assert.equal(await current.run("acquireUpgradeLock('after-expiry')"), true);
});
