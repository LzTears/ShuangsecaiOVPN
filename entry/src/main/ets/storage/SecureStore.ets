import asset from '@ohos.security.asset';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
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
    await asset.add(attributes);
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
      await asset.remove(expired);
    }
  }

  async removeSecret(name: string): Promise<void> {
    try { await asset.remove(this.alias(name)); }
    catch (error) {
      if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) throw new Error('删除系统保存的认证信息失败。');
    }
  }

  private async key(create: boolean): Promise<cryptoFramework.SymKey> {
    let stored = await this.getSecret('config-key');
    if (stored.length === 0) {
      if (!create) throw new Error('配置加密密钥不可用，请在设备解锁后重试。');
      const random = await cryptoFramework.createRandom().generateRandom(32);
      stored = this.base64.encodeToStringSync(random.data);
      // Creation is performed by the single UIAbility; extensions only read an existing key.
      await this.putSecret('config-key', stored);
    }
    return cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: this.base64.decodeSync(stored) });
  }

  async writeProfile(id: string, content: string): Promise<void> {
    const key = await this.key(true);
    const iv = await cryptoFramework.createRandom().generateRandom(12);
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec', iv, aad: { data: this.encoder.encodeInto(id) },
      authTag: { data: new Uint8Array(16) }
    };
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const ciphertext = await cipher.doFinal({ data: this.encoder.encodeInto(content) });
    const envelope: Envelope = {
      version: 1, iv: this.base64.encodeToStringSync(iv.data), ciphertext: this.base64.encodeToStringSync(ciphertext.data)
    };
    this.files.write(`profiles/${id}.sec`, JSON.stringify(envelope));
  }

  async readProfile(id: string): Promise<string> {
    const envelope: Envelope = JSON.parse(this.files.read(`profiles/${id}.sec`)) as Envelope;
    const bytes = this.base64.decodeSync(envelope.ciphertext);
    if (envelope.version !== 1 || bytes.length < 16) throw new Error('配置存储格式无效，请重新导入。');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec', iv: { data: this.base64.decodeSync(envelope.iv) },
      aad: { data: this.encoder.encodeInto(id) }, authTag: { data: bytes.slice(bytes.length - 16) }
    };
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, await this.key(false), params);
    const result = await cipher.doFinal({ data: bytes.slice(0, bytes.length - 16) });
    return new util.TextDecoder().decodeToString(result.data);
  }
}
