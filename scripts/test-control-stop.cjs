const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { test } = require('node:test');

const sdk = process.env.OHOS_SDK_HOME || path.join(process.env.ProgramFiles || 'C:/Program Files',
  'Huawei/DevEco Studio/sdk/default/openharmony');
const ts = require(process.env.OVPN_TYPESCRIPT || path.join(sdk, 'ets/build-tools/ets-loader/node_modules/typescript'));
const filename = path.join(__dirname, '../entry/src/main/ets/service/ControlClient.ets');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;

function setup(states, rejectStop = false, options = {}) {
  let uptime = 0;
  const stops = [];
  const secrets = new Map();
  const removed = [];
  const stored = new Map([['snapshot.json', JSON.stringify({ state: 'DISCONNECTING', verified: true,
    downloadBytes: 1024, uploadBytes: 512, downloadRate: 100, uploadRate: 50, error: '' })]]);
  const files = { exists: (name) => stored.has(name), read: (name) => stored.get(name),
    write: (name, value) => {
      if (options.commandWriteFails && name.startsWith('commands/')) throw new Error('command write failed');
      stored.set(name, value);
    }, remove: (name) => {
      removed.push(name);
      if (options.commandRemoveFails && name.startsWith('commands/')) throw new Error('command cleanup failed');
      stored.delete(name);
    } };
  const modules = {
    '@kit.AbilityKit': {},
    '@kit.BasicServicesKit': { commonEventManager: { publish: () => {} },
      systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => uptime } },
    '@kit.NetworkKit': { vpnExtension: { stopVpnExtensionAbility: async (want) => {
      stops.push({ bundleName: want.bundleName, abilityName: want.abilityName, at: uptime });
      if (rejectStop) throw new Error('system stop rejected');
    } } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'test-request' } },
    '../model/VpnModels': {},
    '../storage/PrivateFiles': { PrivateFiles: class { constructor() { return files; } } },
    '../storage/SecureStore': { SecureStore: class {
      async putSecret(name, value) { secrets.set(name, value); }
      async removeSecret(name) { secrets.delete(name); }
    } }
  };
  const result = { exports: {} };
  vm.runInNewContext(compiled, { module: result, exports: result.exports, require: (id) => {
    assert.ok(id in modules, `unexpected dependency: ${id}`); return modules[id];
  }, setTimeout: (callback, ms) => { uptime += ms; callback(); return 0; }, clearTimeout: () => {} }, { filename });
  const client = new result.exports.ControlClient({});
  const send = client.send.bind(client);
  let replyIndex = 0;
  client.send = async () => ({ snapshot: { state: states[Math.min(replyIndex++, states.length - 1)], verified: true } });
  return { client, stops, stored, secrets, removed, send };
}

test('waits for confirmed graceful shutdown without stopping the extension', async () => {
  const { client, stops } = setup(['DISCONNECTING', 'DISCONNECTED']);
  assert.equal((await client.disconnect()).state, 'DISCONNECTED');
  assert.equal(stops.length, 0);
});

test('stops only this app extension after graceful shutdown remains stuck for five seconds', async () => {
  const { client, stops, stored } = setup(['DISCONNECTING']);
  const snapshot = await client.disconnect();
  assert.equal(snapshot.state, 'DISCONNECTED');
  assert.equal(snapshot.verified, true);
  assert.equal(stops.length, 1);
  assert.equal(stops[0].bundleName, 'com.shuangsecai.ovpn');
  assert.equal(stops[0].abilityName, 'OvpnAbility');
  assert.ok(stops[0].at >= 5000);
  assert.equal(snapshot.downloadBytes, 1024);
  assert.equal(snapshot.uploadBytes, 512);
  assert.equal(snapshot.downloadRate, 0);
  assert.equal(snapshot.uploadRate, 0);
  assert.equal(JSON.parse(stored.get('snapshot.json')).state, 'DISCONNECTED');
});

test('returns immediately when the extension confirms it is already disconnected', async () => {
  const { client, stops } = setup(['DISCONNECTED']);
  assert.equal((await client.disconnect()).state, 'DISCONNECTED');
  assert.equal(stops.length, 0);
});

test('does not publish a disconnected state if the system stop fails', async () => {
  const { client, stored } = setup(['DISCONNECTING'], true);
  await assert.rejects(client.disconnect(), /system stop rejected/);
  assert.equal(JSON.parse(stored.get('snapshot.json')).state, 'DISCONNECTING');
});

const credentials = { username: 'test-user', password: 'test-only', keyPassword: '' };

test('removes transient credentials when writing the connection command fails', async () => {
  const { send, secrets } = setup([], false, { commandWriteFails: true });
  await assert.rejects(send('connect', 'test-profile', true, credentials), /command write failed/);
  assert.equal(secrets.size, 0);
});

test('still removes the reply and transient credentials when command cleanup fails', async () => {
  const { send, secrets, removed } = setup([], false, { commandRemoveFails: true });
  await assert.rejects(send('connect', 'test-profile', false, credentials), /command cleanup failed/);
  assert.ok(removed.includes('replies/test-request.json'));
  assert.equal(secrets.size, 0);
});

test('removes request files and transient credentials after a connection response timeout', async () => {
  const { send, secrets, stored } = setup([]);
  await assert.rejects(send('connect', 'test-profile', false, credentials), /没有及时响应/);
  assert.equal(secrets.size, 0);
  assert.equal(stored.has('commands/test-request.json'), false);
  assert.equal(stored.has('replies/test-request.json'), false);
});
