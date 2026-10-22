import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import ovpn from 'libovpn.so';
import { CoreEvaluation, Credentials, Profile, ProfileIndex } from '../model/VpnModels';
import { embedReference, inspectProfile } from '../model/ProfileParser';
import { PrivateFiles } from './PrivateFiles';
import { SecureStore } from './SecureStore';

export class ProfileStore {
  readonly files: PrivateFiles;
  readonly secure: SecureStore;
  private context: common.UIAbilityContext;
  private uiContext?: UIContext;

  constructor(context: common.UIAbilityContext, uiContext?: UIContext) {
    this.context = context;
    this.uiContext = uiContext;
    this.files = new PrivateFiles(context);
    this.secure = new SecureStore(this.files);
  }

  index(): ProfileIndex {
    if (!this.files.exists('profiles.json')) return { profiles: [], defaultId: '' };
    return JSON.parse(this.files.read('profiles.json')) as ProfileIndex;
  }

  async pickAndImport(): Promise<Profile | undefined> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['OpenVPN 配置|.ovpn'];
    const selected = await new picker.DocumentViewPicker(this.context).select(options);
    if (selected.length === 0) return undefined;
    return this.importUri(selected[0]);
  }

  private readUri(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0 || size > 1024 * 1024) throw new Error('文件应为不超过 1 MiB 的文本。');
      const buffer = new ArrayBuffer(size);
      let offset = 0;
      while (offset < size) {
        const part = new ArrayBuffer(size - offset);
        const length = fs.readSync(file.fd, part, { offset: offset, length: size - offset });
        if (length <= 0) break;
        new Uint8Array(buffer).set(new Uint8Array(part).slice(0, length), offset);
        offset += length;
      }
      if (offset !== size) throw new Error('文件未完整读取，请重新选择。');
      return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(new Uint8Array(buffer));
    } finally { fs.closeSync(file); }
  }

  async importUri(uri: string): Promise<Profile> {
    let inspected = inspectProfile(this.readUri(uri));
    // Resolve in reverse line order so inserted blocks do not shift remaining references.
    for (let i = inspected.references.length - 1; i >= 0; i--) {
      const reference = inspected.references[i];
      if (this.uiContext === undefined) throw new Error('请在应用内选择配置引用的关联文件。');
      await this.uiContext.getPromptAction().showDialog({
        title: '选择关联证书或密钥',
        message: `配置引用 ${reference.directive} 文件：${reference.path}。请在接下来的文件选择器中选择对应文件。`,
        buttons: [{ text: '选择文件', color: '#C65E00' }]
      });
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const files = await new picker.DocumentViewPicker(this.context).select(options);
      if (files.length === 0) throw new Error('未选择关联文件，本次配置未保存。');
      inspected.content = embedReference(inspected.content, reference, this.readUri(files[0]));
    }
    inspected = inspectProfile(inspected.content);
    const evaluation = JSON.parse(ovpn.evaluate(inspected.content)) as CoreEvaluation;
    if (evaluation.error) throw new Error('OpenVPN 核心未通过配置校验，请检查指令、证书和私钥。');
    if (evaluation.externalPki) throw new Error('配置缺少内嵌客户端证书/私钥；当前不支持外部 PKI。');
    if (evaluation.staticChallenge) throw new Error('当前版本暂不支持静态挑战或 MFA 认证。');
    const filename = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1)).replace(/\.ovpn$/i, '');
    const profile: Profile = {
      id: util.generateRandomUUID(true), name: filename.substring(0, 64) || 'VPN 配置',
      protocol: evaluation.protocol.toUpperCase(), requiresAuth: evaluation.requiresAuth,
      requiresKeyPassword: evaluation.requiresKeyPassword, allowPasswordSave: evaluation.allowPasswordSave,
      lockedUsername: evaluation.lockedUsername, createdAt: Date.now()
    };
    await this.secure.writeProfile(profile.id, inspected.content);
    const index = this.index();
    index.profiles.push(profile);
    if (index.defaultId.length === 0) index.defaultId = profile.id;
    try { this.files.write('profiles.json', JSON.stringify(index)); }
    catch (_) { this.files.remove(`profiles/${profile.id}.sec`); throw new Error('配置索引保存失败，请检查存储空间。'); }
    return profile;
  }

  rename(id: string, name: string): void {
    const normalized = name.trim();
    if (normalized.length === 0 || normalized.length > 64) throw new Error('名称应为 1–64 个字符。');
    const index = this.index();
    const profile = index.profiles.find((item: Profile) => item.id === id);
    if (profile === undefined) throw new Error('配置不存在，请刷新后重试。');
    profile.name = normalized;
    this.files.write('profiles.json', JSON.stringify(index));
  }

  setDefault(id: string): void {
    const index = this.index();
    if (!index.profiles.some((item: Profile) => item.id === id)) throw new Error('配置不存在。');
    index.defaultId = id;
    this.files.write('profiles.json', JSON.stringify(index));
  }

  async remove(id: string): Promise<void> {
    const index = this.index();
    index.profiles = index.profiles.filter((item: Profile) => item.id !== id);
    if (index.defaultId === id) index.defaultId = index.profiles.length > 0 ? index.profiles[0].id : '';
    this.files.write('profiles.json', JSON.stringify(index));
    await this.secure.removeSecret(`auth:${id}`);
    this.files.remove(`profiles/${id}.sec`);
  }

  async savedCredentials(id: string): Promise<Credentials> {
    const text = await this.secure.getSecret(`auth:${id}`);
    return text.length > 0 ? JSON.parse(text) as Credentials : { username: '', password: '', keyPassword: '' };
  }
}
