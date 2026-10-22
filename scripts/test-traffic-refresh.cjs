const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const sdk = process.env.OHOS_SDK_HOME || path.join(process.env.ProgramFiles || 'C:/Program Files',
  'Huawei/DevEco Studio/sdk/default/openharmony');
const ts = require(process.env.OVPN_TYPESCRIPT || path.join(sdk, 'ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');

async function setup() {
  let uptime = 10000;
  let timer;
  const cards = [];
  const stored = new Map([
    ['forms.json', JSON.stringify(['card-2x2', 'card-4x2'])],
    ['profiles.json', JSON.stringify({ defaultId: 'test-profile', profiles: [{ id: 'test-profile', name: 'Test VPN' }] })]
  ]);
  const files = {
    exists: name => stored.has(name), read: name => stored.get(name),
    write: (name, content) => stored.set(name, content), remove: name => stored.delete(name),
    list: directory => [...stored.keys()].filter(name => name.startsWith(directory + '/')).map(name => name.slice(directory.length + 1)),
    claimCommand: id => {
      const name = `commands/${id}.json`;
      if (!stored.has(name)) return false;
      stored.set(`commands/${id}.processing`, stored.get(name));
      stored.delete(name);
      return true;
    }
  };
  const native = { running: true, state: 'CONNECTED', bytesIn: 0, bytesOut: 0, packetsIn: 0, packetsOut: 0, error: '' };
  const modules = {
    '@kit.AbilityKit': {},
    '@kit.NetworkKit': { VpnExtensionAbility: class { context = {}; }, vpnExtension: { createVpnConnection: () => ({}) } },
    '@kit.BasicServicesKit': { systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => uptime },
      commonEventManager: { createSubscriber: async () => ({}), subscribe: () => {}, unsubscribe: () => {} } },
    '@kit.ArkTS': {},
    '@kit.FormKit': { formBindingData: { createFormBindingData: data => data }, formProvider: {
      updateForm: async (id, data) => { cards.push({ id, data: structuredClone(data), at: uptime }); }
    } },
    'libovpn.so': { default: { snapshot: () => JSON.stringify(native), stop: () => {} } }
  };
  const cache = new Map();
  function load(filename) {
    if (cache.has(filename)) return cache.get(filename);
    if (path.basename(filename) === 'PrivateFiles.ets') return { PrivateFiles: class { constructor() { return files; } } };
    if (path.basename(filename) === 'SecureStore.ets') return { SecureStore: class {} };
    if (path.basename(filename) === 'ControlClient.ets') return { CONTROL_EVENT: 'test.CONTROL' };
    const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const result = { exports: {} };
    vm.runInNewContext(compiled, { module: result, exports: result.exports, Date: class extends Date {
      static now() { return 1800000000000 + uptime; }
    }, setInterval: callback => { timer = callback; return 1; }, clearInterval: () => { timer = undefined; },
    require: id => {
      if (id in modules) return modules[id];
      assert.ok(id.startsWith('.'), `unexpected dependency: ${id}`);
      const base = path.resolve(path.dirname(filename), id);
      return load(fs.existsSync(base + '.ts') ? base + '.ts' : base + '.ets');
    } }, { filename });
    cache.set(filename, result.exports);
    return result.exports;
  }
  const { default: OvpnAbility } = load(path.join(root, 'vpn/OvpnAbility.ets'));
  const { emptySnapshot } = load(path.join(root, 'model/VpnModels.ts'));
  const ability = new OvpnAbility();
  ability.onCreate({});
  await new Promise(setImmediate);
  ability.current = { ...emptySnapshot(), state: 'CONNECTED', sessionId: 'test-session',
    profileId: 'test-profile', profileName: 'Test VPN', verified: true };
  ability.startMonotonic = uptime;
  ability.publish(true);
  await new Promise(setImmediate);
  cards.length = 0;
  return { ability, native, cards, stored, now: () => uptime,
    tick: async (milliseconds = 1000) => { uptime += milliseconds; timer(); await new Promise(setImmediate); },
    query: async () => {
      uptime += 80;
      stored.set('commands/test-query.json', JSON.stringify({ id: 'test-query', action: 'query', profileId: '', createdAt: 1800000000000 + uptime }));
      await ability.drain();
      return JSON.parse(stored.get('replies/test-query.json')).snapshot;
    } };
}

test('persists fresh traffic every second without any UI or card refresh request', async () => {
  const { native, stored, tick } = await setup();
  Object.assign(native, { bytesIn: 4096, bytesOut: 2048, packetsIn: 8, packetsOut: 4 });
  await tick();
  const snapshot = JSON.parse(stored.get('snapshot.json'));
  assert.equal(snapshot.state, 'CONNECTED');
  assert.equal(snapshot.downloadBytes, 4096);
  assert.equal(snapshot.uploadBytes, 2048);
  assert.equal(snapshot.downloadPackets, 8);
  assert.equal(snapshot.uploadPackets, 4);
});

test('automatically updates both card dimensions once per minute with current totals', async () => {
  const { native, cards, tick } = await setup();
  Object.assign(native, { bytesIn: 4096, bytesOut: 2048 });
  for (let second = 1; second < 60; second++) await tick();
  assert.equal(cards.length, 0, 'do not refresh third-party cards every second');
  await tick();
  assert.equal(cards.length, 2);
  assert.deepEqual(cards.map(card => card.id).sort(), ['card-2x2', 'card-4x2']);
  for (const card of cards) {
    assert.equal(card.data.downloadText, '4.0 KiB');
    assert.equal(card.data.uploadText, '2.0 KiB');
    assert.equal(card.data.isStale, false);
  }
  Object.assign(native, { bytesIn: 8192, bytesOut: 4096 });
  for (let second = 0; second < 60; second++) await tick();
  assert.equal(cards.length, 4);
  assert.equal(cards[2].data.downloadText, '8.0 KiB');
  assert.equal(cards[2].data.uploadText, '4.0 KiB');
});

test('querying the latest snapshot does not reset the sampled traffic rate to zero', async () => {
  const { native, tick, query } = await setup();
  Object.assign(native, { bytesIn: 1024, bytesOut: 512 });
  await tick();
  Object.assign(native, { bytesIn: 2048, bytesOut: 1024 });
  await tick();
  const snapshot = await query();
  assert.equal(snapshot.downloadBytes, 2048);
  assert.equal(snapshot.uploadBytes, 1024);
  assert.equal(snapshot.downloadRate, 1024);
  assert.equal(snapshot.uploadRate, 512);
});

test('disconnect state still reaches every card immediately between periodic updates', async () => {
  const { ability, cards, tick } = await setup();
  await tick();
  ability.current.state = 'DISCONNECTED';
  ability.publish(true);
  await new Promise(setImmediate);
  assert.equal(cards.length, 2);
  assert.equal(cards[0].data.statusText, '未连接');
  assert.equal(cards[1].data.canDisconnect, false);
});

test('a failed system TUN release is reported without persisting a confirmed disconnection', async () => {
  const { ability, stored, cards } = await setup();
  ability.tunExists = true;
  ability.vpn = { destroy: async () => { throw new Error('mock system release failure'); } };
  await assert.doesNotReject(ability.onDestroy());
  const snapshot = JSON.parse(stored.get('snapshot.json'));
  assert.equal(snapshot.state, 'FAILED');
  assert.equal(snapshot.verified, false);
  assert.match(snapshot.error, /系统 VPN 资源释放失败/);
  assert.equal(ability.tunExists, true);
  assert.equal(cards.at(-1).data.canDisconnect, false);
});
