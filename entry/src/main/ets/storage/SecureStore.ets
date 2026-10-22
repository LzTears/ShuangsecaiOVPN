import asset from '@ohos.security.asset';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { SuppressWarnings, SuppressWarningsType } from '@ohos.annotation';
import { PrivateFiles } from './PrivateFiles';

interface Envelope {
  version: number;
  iv: string;
  ciphertext: string;
}

export class SecureStore {
  private files: PrivateFiles;
  private encoder: util.TextEncoder = new util.TextEncoder();
  private base64: util.Base64Helper = new util.Base64Helper();

  constructor(files: PrivateFiles) { this.files = files; }

  private alias(name: string): asset.AssetMap {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, this.encoder.encodeInto(`shuangsecai.ovpn.${name}`));
    return attributes;
  }

  async getSecret(name: string): Promise<string> {
    const query = this.alias(name);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const found = await asset.query(query);
      return found.length > 0 ? new util.TextDecoder().decodeToString(found[0].get(asset.Tag.SECRET) as Uint8Array) : '';
    } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) return '';
      throw new Error('系统安全存储不可用，请解锁设备后重试。');
    }
  }

  async putSecret(name: string, secret: string): Promise<void> {
    const attributes = this.alias(name);
    attributes.set(asset.Tag.SECRET, this.encoder.encodeInto(secret));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    if (name.startsWith('once:')) {
      attributes.set(asset.Tag.DATA_LABEL_NORMAL_1, this.encoder.encodeInto('transient-credentials'));
      attributes.set(asset.Tag.DATA_LABEL_NORMAL_2, this.encoder.encodeInto(Date.now().toString()));
    }
    try { await asset.add(attributes); }
    catch (_) { throw new Error('保存系统认证信息失败，请解锁设备后重试。'); }
  }

  async pruneTransientSecrets(): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.DATA_LABEL_NORMAL_1, this.encoder.encodeInto('transient-credentials'));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    let records: asset.AssetMap[];
    try { records = await asset.query(query); }
    catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) return;
      throw new Error('暂存认证信息清理失败，请在设备解锁后重试。');
    }
    for (const record of records) {
      const created = Number(new util.TextDecoder().decodeToString(record.get(asset.Tag.DATA_LABEL_NORMAL_2) as Uint8Array));
      const age = Date.now() - created;
      if (Number.isFinite(created) && age >= -5000 && age < 90000) continue;
      const expired: asset.AssetMap = new Map();
      expired.set(asset.Tag.ALIAS, record.get(asset.Tag.ALIAS) as Uint8Array);
      try { await asset.remove(expired); }
      catch (_) { throw new Error('暂存认证信息清理失败，请解锁设备后重试。'); }
    }
  }

  async removeSecret(name: string): Promise<void> {
    try { await asset.remove(this.alias(name)); }
    catch (error) {
      if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) throw new Error('删除系统保存的认证信息失败。');
    }
  }

  // SDK 26 compares versioned @syscap labels literally. Only suppress that diagnostic after a real capability check.
  @SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
  private async randomBytes(size: number): Promise<Uint8Array> {
    if (canIUse('SystemCapability.Security.CryptoFramework.Rand')) {
      try { return (await cryptoFramework.createRandom().generateRandom(size)).data; }
      catch (_) { throw new Error('安全随机数生成失败，配置未保存，请重试。'); }
    }
    throw new Error('当前设备不支持安全随机数，无法保存加密配置。');
  }

  @SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
  private async key(create: boolean): Promise<cryptoFramework.SymKey> {
    if (canIUse('SystemCapability.Security.CryptoFramework.Key.SymKey')) {
      let stored = await this.getSecret('config-key');
      if (stored.length === 0) {
        if (!create) throw new Error('配置加密密钥不可用，请在设备解锁后重试。');
        stored = this.base64.encodeToStringSync(await this.randomBytes(32));
        // Creation is performed by the single UIAbility; extensions only read an existing key.
        await this.putSecret('config-key', stored);
      }
      try {
        return await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: this.base64.decodeSync(stored) });
      } catch (_) { throw new Error('配置加密密钥无法读取，请解锁设备后重试。'); }
    }
    throw new Error('当前设备不支持 AES 密钥，无法读取或保存加密配置。');
  }

  @SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
  async writeProfile(id: string, content: string): Promise<void> {
    if (canIUse('SystemCapability.Security.CryptoFramework.Cipher')) {
      const key = await this.key(true);
      const iv: cryptoFramework.DataBlob = { data: await this.randomBytes(12) };
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec', iv, aad: { data: this.encoder.encodeInto(id) },
        authTag: { data: new Uint8Array(16) }
      };
      let ciphertext: cryptoFramework.DataBlob;
      try {
        const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
        await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
        ciphertext = await cipher.doFinal({ data: this.encoder.encodeInto(content) });
      } catch (_) { throw new Error('配置加密失败，本次配置未保存，请重试。'); }
      const envelope: Envelope = {
        version: 1, iv: this.base64.encodeToStringSync(iv.data), ciphertext: this.base64.encodeToStringSync(ciphertext.data)
      };
      this.files.write(`profiles/${id}.sec`, JSON.stringify(envelope));
      return;
    }
    throw new Error('当前设备不支持 AES-GCM，无法保存加密配置。');
  }

  @SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
  async readProfile(id: string): Promise<string> {
    if (canIUse('SystemCapability.Security.CryptoFramework.Cipher')) {
      const envelope: Envelope = JSON.parse(this.files.read(`profiles/${id}.sec`)) as Envelope;
      const bytes = this.base64.decodeSync(envelope.ciphertext);
      if (envelope.version !== 1 || bytes.length < 16) throw new Error('配置存储格式无效，请重新导入。');
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec', iv: { data: this.base64.decodeSync(envelope.iv) },
        aad: { data: this.encoder.encodeInto(id) }, authTag: { data: bytes.slice(bytes.length - 16) }
      };
      const key = await this.key(false);
      try {
        const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
        await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
        const result = await cipher.doFinal({ data: bytes.slice(0, bytes.length - 16) });
        return new util.TextDecoder().decodeToString(result.data);
      } catch (_) { throw new Error('配置解密失败，请解锁设备后重试；配置可能已损坏。'); }
    }
    throw new Error('当前设备不支持 AES-GCM，无法读取加密配置。');
  }
}
