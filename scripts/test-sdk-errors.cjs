const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const sdk = process.env.OHOS_SDK_HOME || path.join(process.env.ProgramFiles || 'C:/Program Files',
  'Huawei/DevEco Studio/sdk/default/openharmony');
const ts = require(process.env.OVPN_TYPESCRIPT || path.join(sdk, 'ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const util = {
  generateRandomUUID: () => 'test-temp',
  TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text)); } },
  TextDecoder: class { decodeToString(bytes) { return Buffer.from(bytes).toString('utf8'); } },
  Base64Helper: class {
    encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
  }
};
function load(relative, mocks, globals = {}) {
  const filename = path.join(root, relative);
  const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const result = { exports: {} };
  vm.runInNewContext(compiled, { module: result, exports: result.exports,
    console: { warn: () => {}, error: () => {} }, ...globals, require: id => {
      if (id in mocks) return mocks[id];
      if (id.startsWith('.')) {
        const base = path.resolve(path.dirname(filename), id);
        return load(path.relative(root, fs.existsSync(base + '.ts') ? base + '.ts' : base + '.ets'), mocks, globals);
      }
      throw new Error(`Unexpected dependency: ${id}`);
    } }, { filename });
  return result.exports;
}

function privateFiles(options = {}) {
  const data = new Map([['/sandbox/ovpn/snapshot.json', 'before']]);
  let opened;
  let closes = 0;
  const io = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: name => data.has(name) || ['/sandbox/ovpn', '/sandbox/ovpn/profiles', '/sandbox/ovpn/commands', '/sandbox/ovpn/replies'].includes(name),
    readTextSync: name => { if (options.readFails) throw Object.assign(new Error('mock private path'), { code: 13900013 }); return data.get(name); },
    mkdirSync: () => {},
    openSync: name => { opened = name; data.set(name, ''); return { fd: 1 }; },
    writeSync: (_fd, bytes) => { if (options.writeFails) throw new Error('mock write error'); data.set(opened, data.get(opened) + Buffer.from(bytes).toString()); return bytes.byteLength; },
    fsyncSync: () => {}, closeSync: () => { closes++; },
    renameSync: (from, to) => { if (options.renameFails) throw new Error('mock rename error'); data.set(to, data.get(from)); data.delete(from); },
    unlinkSync: name => { if (options.removeRace) { data.delete(name); throw Object.assign(new Error('already removed'), { code: 13900002 }); } data.delete(name); },
    listFileSync: () => []
  };
  const { PrivateFiles } = load('storage/PrivateFiles.ets', { '@kit.CoreFileKit': { fileIo: io }, '@kit.ArkTS': { util } });
  return { files: new PrivateFiles({ filesDir: '/sandbox' }), data, closes: () => closes };
}

for (const failure of ['writeFails', 'renameFails']) {
  test(`failed atomic save (${failure}) closes the file, removes its temporary file and preserves the previous value`, () => {
    const { files, data, closes } = privateFiles({ [failure]: true });
    assert.throws(() => files.write('snapshot.json', 'after'));
    assert.equal(data.get('/sandbox/ovpn/snapshot.json'), 'before');
    assert.equal(closes(), 1);
    assert.equal([...data.keys()].some(name => name.endsWith('.tmp')), false);
  });
}
test('a successful atomic save commits the new value and keeps no temporary file', () => {
  const { files, data, closes } = privateFiles();
  files.write('snapshot.json', 'after');
  assert.equal(data.get('/sandbox/ovpn/snapshot.json'), 'after');
  assert.equal(data.size, 1);
  assert.equal(closes(), 1);
});
test('storage read failures produce a local error without exposing SDK path text', () => {
  const { files } = privateFiles({ readFails: true });
  assert.throws(() => files.read('snapshot.json'), /读取本机数据失败/);
});
test('removing a request already consumed by another process succeeds', () => {
  const { files } = privateFiles({ removeRace: true });
  assert.doesNotThrow(() => files.remove('snapshot.json'));
});

function secureStore(options = {}) {
  const stored = new Map();
  const assets = new Map();
  let cryptoCalls = 0;
  const tag = { ALIAS: 'alias', SECRET: 'secret' };
  const asset = {
    Tag: tag, ReturnType: { ALL: 1, ATTRIBUTES: 2 }, Accessibility: { DEVICE_FIRST_UNLOCKED: 1 },
    SyncType: { NEVER: 0 }, ConflictResolution: { OVERWRITE: 1 }, ErrorCode: { NOT_FOUND: 1 },
    query: async query => {
      const secret = assets.get(String(query.get(tag.ALIAS)));
      return secret ? [new Map([[tag.SECRET, secret]])] : [];
    }, remove: async () => {},
    add: attributes => {
      if (options.assetSyncFailure) throw new Error('mock sensitive SDK detail');
      if (options.assetAsyncFailure) return Promise.reject(new Error('mock sensitive SDK detail'));
      assets.set(String(attributes.get(tag.ALIAS)), attributes.get(tag.SECRET));
      return Promise.resolve();
    }
  };
  const cryptoFramework = {
    CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
    createRandom: () => { cryptoCalls++; return { generateRandom: async size => ({ data: new Uint8Array(crypto.randomBytes(size)) }) }; },
    createSymKeyGenerator: () => { cryptoCalls++; return { convertKey: async blob => ({ data: blob.data }) }; },
    createCipher: () => {
      cryptoCalls++;
      let mode, key, params;
      return { init: async (m, k, p) => { mode = m; key = k; params = p; }, doFinal: async blob => {
        const cipher = mode === 0 ? crypto.createCipheriv('aes-256-gcm', key.data, params.iv.data)
          : crypto.createDecipheriv('aes-256-gcm', key.data, params.iv.data);
        cipher.setAAD(params.aad.data);
        if (mode !== 0) cipher.setAuthTag(params.authTag.data);
        const result = Buffer.concat([cipher.update(blob.data), cipher.final()]);
        return { data: new Uint8Array(mode === 0 ? Buffer.concat([result, cipher.getAuthTag()]) : result) };
      } };
    }
  };
  const { SecureStore } = load('storage/SecureStore.ets', {
    '@ohos.security.asset': { default: asset }, '@kit.CryptoArchitectureKit': { cryptoFramework },
    '@ohos.annotation': { SuppressWarnings: () => () => {}, SuppressWarningsType: { SYSCAP: 'syscap' } },
    '@kit.ArkTS': { util }
  }, { canIUse: capability => capability !== options.unsupported });
  return { secure: new SecureStore({ write: (name, value) => stored.set(name, value), read: name => stored.get(name) }), stored, assets, cryptoCalls: () => cryptoCalls };
}
test('supported crypto preserves the version-one AES-GCM round trip and stores no plaintext profile', async () => {
  const { secure, stored } = secureStore();
  await secure.writeProfile('test-profile', 'test-only-profile');
  assert.equal(await secure.readProfile('test-profile'), 'test-only-profile');
  const text = stored.get('profiles/test-profile.sec');
  assert.equal(JSON.parse(text).version, 1);
  assert.equal(text.includes('test-only-profile'), false);
});
test('a profile encrypted for another ID fails authentication without modifying the saved data', async () => {
  const { secure, stored } = secureStore();
  await secure.writeProfile('test-profile', 'test-only-profile');
  const original = stored.get('profiles/test-profile.sec');
  stored.set('profiles/another-profile.sec', original);
  await assert.rejects(secure.readProfile('another-profile'), /配置解密失败/);
  assert.equal(stored.get('profiles/test-profile.sec'), original);
});
for (const capability of ['Cipher', 'Rand', 'Key.SymKey']) {
  test(`missing ${capability} capability rejects profile storage without saving plaintext or credentials`, async () => {
    const { secure, stored, assets, cryptoCalls } = secureStore({ unsupported: `SystemCapability.Security.CryptoFramework.${capability}` });
    await assert.rejects(secure.writeProfile('test-profile', 'test-only-profile'), /不支持/);
    assert.equal(stored.size, 0);
    assert.equal(assets.size, 0);
    assert.equal(cryptoCalls(), 0);
  });
}
for (const failure of ['assetSyncFailure', 'assetAsyncFailure']) {
  test(`secure storage reports ${failure} without exposing SDK details`, async () => {
    const { secure } = secureStore({ [failure]: true });
    await assert.rejects(secure.putSecret('auth:test-profile', 'test-only'), /保存系统认证信息失败/);
  });
}

function entryAbility(context) {
  const storage = new Map();
  const { default: EntryAbility } = load('entryability/EntryAbility.ets', {
    '@kit.AbilityKit': { UIAbility: class {}, ConfigurationConstant: { ColorMode: { COLOR_MODE_NOT_SET: -1 } } }
  }, { AppStorage: { setOrCreate: (key, value) => storage.set(key, value) }, $r: () => ({ id: 1 }) });
  const ability = new EntryAbility();
  ability.context = context;
  return { ability, storage };
}
test('theme initialization failure does not abort an incoming import intent', () => {
  const { ability, storage } = entryAbility({ getApplicationContext: () => ({ setColorMode: () => { throw new Error('mock theme failure'); } }) });
  assert.doesNotThrow(() => ability.onCreate({ uri: 'file://test-only.ovpn' }, {}));
  assert.equal(storage.get('importUri'), 'file://test-only.ovpn');
});
test('theme resource failure does not escape a configuration lifecycle callback', () => {
  const { ability } = entryAbility({ resourceManager: { getColorSync: () => { throw new Error('mock resource failure'); } } });
  ability.mainWindow = {};
  assert.doesNotThrow(() => ability.onConfigurationUpdate({}));
});

function cardAbility() {
  const callbacks = new Map();
  const { default: CardControlAbility } = load('service/CardControlAbility.ets', {
    '@kit.AbilityKit': { UIAbility: class {} },
    './ControlClient': { ControlClient: class { async query() { return { state: 'DISCONNECTED', verified: true }; } } },
    './FormSync': { FormSync: class { async updateAll() {} } },
    '../storage/ProfileStore': {}
  });
  const ability = new CardControlAbility();
  ability.callee = { on: (name, callback) => callbacks.set(name, callback), off: () => {} };
  return { ability, callbacks };
}
test('partial RPC registration failure cleans up callbacks without escaping onCreate', () => {
  const { ability } = cardAbility();
  const removed = [];
  ability.callee.on = name => { if (name === 'vpnDisconnect') throw new Error('mock registration failure'); };
  ability.callee.off = name => removed.push(name);
  assert.doesNotThrow(() => ability.onCreate());
  assert.deepEqual(removed, ['vpnConnect', 'vpnDisconnect', 'vpnRefresh']);
});
test('card storage initialization failure does not become an unhandled call rejection', async () => {
  const { default: FaultyCardAbility } = load('service/CardControlAbility.ets', {
    '@kit.AbilityKit': { UIAbility: class {} },
    './ControlClient': { ControlClient: class { constructor() { throw new Error('mock storage failure'); } } },
    './FormSync': { FormSync: class { async updateAll() {} } }, '../storage/ProfileStore': {}
  });
  await assert.doesNotReject(new FaultyCardAbility().handle('query'));
});
test('RPC acknowledgement returns failure when serialization throws', () => {
  const { ability, callbacks } = cardAbility();
  ability.onCreate();
  const reply = callbacks.get('vpnRefresh')({});
  assert.equal(reply.marshalling({ writeString: () => { throw new Error('mock RPC failure'); } }), false);
});
test('RPC teardown attempts every callback even if the first unregistration fails', () => {
  const { ability } = cardAbility();
  const removed = [];
  ability.callee.off = name => { removed.push(name); if (removed.length === 1) throw new Error('mock unregistration failure'); };
  assert.doesNotThrow(() => ability.onDestroy());
  assert.deepEqual(removed, ['vpnConnect', 'vpnDisconnect', 'vpnRefresh']);
});

for (const operation of ['open', 'read']) {
  test(`selected file ${operation} failure is reported safely and closes only an opened descriptor`, () => {
    let closes = 0;
    const io = { OpenMode: { READ_ONLY: 0 },
      openSync: () => { if (operation === 'open') throw Object.assign(new Error('mock private URI'), { code: 13900013 }); return { fd: 1 }; },
      statSync: () => ({ size: 8 }),
      readSync: () => { throw Object.assign(new Error('mock private URI'), { code: 13900005 }); },
      closeSync: () => { closes++; }
    };
    const { ProfileStore } = load('storage/ProfileStore.ets', {
      '@kit.CoreFileKit': { fileIo: io }, '@kit.ArkTS': { util }, 'libovpn.so': {},
      './PrivateFiles': {}, './SecureStore': {}
    });
    const store = Object.create(ProfileStore.prototype);
    assert.throws(() => store.readUri('file://test-only.ovpn'), /读取所选文件失败/);
    assert.equal(closes, operation === 'open' ? 0 : 1);
  });
}
