const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { test } = require('node:test');

const sdk = process.env.OHOS_SDK_HOME || path.join(process.env.ProgramFiles || 'C:/Program Files',
  'Huawei/DevEco Studio/sdk/default/openharmony');
const ts = require(process.env.OVPN_TYPESCRIPT || path.join(sdk, 'ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets/model');
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const filename = path.join(root, `${name}.ts`);
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  });
  const result = { exports: {} };
  const run = vm.runInThisContext(`(function(require, module, exports) { ${output.outputText}\n})`, { filename });
  run((id) => load(path.basename(id)), result, result.exports);
  cache.set(name, result.exports);
  return result.exports;
}
const { inspectProfile, embedReference, splitOption } = load('ProfileParser');
const { emptySnapshot, formatBytes, formatDuration, coreError } = load('VpnModels');
const { Traffic } = load('Traffic');
const base = 'client\ndev tun\nremote vpn.example.test 1194\n';

test('normalizes UTF-8 BOM and CRLF without changing inline certificate content', () => {
  const result = inspectProfile(`\uFEFF${base.replaceAll('\n', '\r\n')}<ca>\r\nremote not-a-directive\r\n</ca>\r\n`);
  assert.equal(result.references.length, 0);
  assert.ok(!result.content.includes('\r'));
  assert.ok(result.content.includes('remote not-a-directive'));
});
test('reads quoted external references and retains tls-auth direction', () => {
  const result = inspectProfile(`${base}ca "cert files/ca.pem" # a comment\ntls-auth ta.key 1\n`);
  assert.equal(result.references[0].path, 'cert files/ca.pem');
  let combined = embedReference(result.content, result.references[1], 'TEST KEY');
  combined = embedReference(combined, result.references[0], 'TEST CA');
  assert.ok(combined.includes('key-direction 1'));
  assert.equal(inspectProfile(combined).references.length, 0);
});
test('does not treat comment markers inside quoted paths as comments', () => {
  assert.deepEqual(splitOption('ca "a;#b.pem" ; comment'), ['ca', 'a;#b.pem']);
});
test('rejects missing remote, oversized/binary text, and unclosed blocks', () => {
  for (const text of ['client', '', `${base}\0`, `${base}<key>\nsecret`, `${base}${'x'.repeat(1024 * 1024)}`])
    assert.throws(() => inspectProfile(text));
});
test('rejects scripts, ignored options, unsupported TAP and file credentials', () => {
  for (const directive of ['up script.sh', 'plugin /tmp/x.so', 'dev tap', 'auth-user-pass passwords.txt',
    'ignore-unknown-option route', 'setenv opt block-outside-dns', 'block-ipv6', 'compress lz4', 'comp-lzo yes'])
    assert.throws(() => inspectProfile(`${base}${directive}\n`), directive);
});
test('rejects associated-file block injection', () => {
  const result = inspectProfile(`${base}key client.key\n`);
  assert.throws(() => embedReference(result.content, result.references[0], '</key>\nup script.sh'));
});
test('handles nested connection remotes without parsing inline keys as options', () => {
  const profile = 'client\ndev tun\n<connection>\nremote vpn.example.test 443 tcp\n</connection>\n<key>\nup is-not-a-directive-here\n</key>';
  assert.equal(inspectProfile(profile).references.length, 0);
});

function native(bytesIn, bytesOut, packetsIn = 0, packetsOut = 0) {
  return { state: 'CONNECTED', running: true, bytesIn, bytesOut, packetsIn, packetsOut, error: '' };
}
test('accumulates IP bytes and packets and computes speed from monotonic elapsed time', () => {
  const snapshot = emptySnapshot();
  const traffic = new Traffic();
  traffic.sample(native(1024, 2048, 4, 8), snapshot, 1000);
  assert.equal(snapshot.downloadRate, 0);
  traffic.sample(native(3072, 2560, 9, 12), snapshot, 3000);
  assert.equal(snapshot.downloadBytes, 3072);
  assert.equal(snapshot.uploadBytes, 2560);
  assert.equal(snapshot.downloadRate, 1024);
  assert.equal(snapshot.uploadRate, 256);
  assert.equal(snapshot.downloadPackets, 9);
  assert.equal(snapshot.uploadPackets, 12);
});
test('counts a restarted core counter segment exactly once', () => {
  const snapshot = emptySnapshot();
  const traffic = new Traffic();
  traffic.sample(native(100, 200, 10, 20), snapshot, 1000);
  traffic.sample(native(20, 30, 2, 3), snapshot, 2000);
  traffic.sample(native(20, 30, 2, 3), snapshot, 3000);
  assert.equal(snapshot.downloadBytes, 120);
  assert.equal(snapshot.uploadBytes, 230);
  assert.equal(snapshot.downloadPackets, 12);
});
test('invalid counters and clock intervals cannot introduce NaN, negatives or rate spikes', () => {
  const snapshot = emptySnapshot();
  const traffic = new Traffic();
  traffic.sample(native(100, 100), snapshot, 2000);
  traffic.sample(native(NaN, -1), snapshot, 1000);
  assert.equal(snapshot.downloadBytes, 100);
  assert.equal(snapshot.uploadBytes, 100);
  assert.equal(snapshot.downloadRate, 0);
  traffic.sample(native(300, 300), snapshot, 100000);
  assert.equal(snapshot.downloadRate, 0);
});
test('new sessions start with independent counters', () => {
  const first = emptySnapshot();
  new Traffic().sample(native(1024, 2048), first, 1000);
  const second = emptySnapshot();
  new Traffic().sample(native(10, 20), second, 1000);
  assert.equal(second.downloadBytes, 10);
  assert.equal(first.downloadBytes, 1024);
});
test('formats actual units, long sessions and unknown values', () => {
  assert.equal(formatBytes(0), '0 B');
  assert.equal(formatBytes(1024), '1.0 KiB');
  assert.equal(formatBytes(1024 ** 3), '1.0 GiB');
  assert.equal(formatBytes(NaN), '—');
  assert.equal(formatDuration(360000), '100:00:00');
  assert.equal(formatDuration(NaN), '00:00:00');
});
test('known errors are useful and unknown protocol strings are not echoed to the UI', () => {
  assert.ok(coreError('AUTH_FAILED').includes('认证失败'));
  assert.ok(coreError('EXCLUDE_ROUTE_UNSUPPORTED').includes('排除路由'));
  assert.ok(!coreError('PRIVATE-SECRET-CONTENT').includes('PRIVATE'));
});
