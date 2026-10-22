import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { ProfileIndex, VpnSnapshot, formatBytes, isBusy, stateLabel } from '../model/VpnModels';
import { PrivateFiles } from '../storage/PrivateFiles';

export interface CardData {
  dimension?: number;
  formId: string;
  profileName: string;
  statusText: string;
  state: string;
  downloadText: string;
  uploadText: string;
  sessionText: string;
  updatedText: string;
  isBusy: boolean;
  isStale: boolean;
  canConnect: boolean;
  canDisconnect: boolean;
  hint: string;
  hasDefault: boolean;
}

export class FormSync {
  private files: PrivateFiles;

  constructor(context: common.Context) { this.files = new PrivateFiles(context); }

  private ids(): string[] {
    return this.files.exists('forms.json') ? JSON.parse(this.files.read('forms.json')) as string[] : [];
  }

  add(id: string): void {
    const ids = this.ids();
    if (ids.indexOf(id) < 0) ids.push(id);
    this.files.write('forms.json', JSON.stringify(ids));
  }

  remove(id: string): void {
    this.files.write('forms.json', JSON.stringify(this.ids().filter((value: string) => value !== id)));
  }

  data(snapshot: VpnSnapshot, id: string): CardData {
    const index: ProfileIndex = this.files.exists('profiles.json')
      ? JSON.parse(this.files.read('profiles.json')) as ProfileIndex : { profiles: [], defaultId: '' };
    let profileName = '';
    for (const profile of index.profiles) if (profile.id === index.defaultId) profileName = profile.name;
    const active = snapshot.state === 'CONNECTED' || isBusy(snapshot.state);
    if (active && snapshot.profileName.length > 0) {
      profileName = snapshot.profileName;
      for (const profile of index.profiles) if (profile.id === snapshot.profileId) profileName = profile.name;
    }
    const stale = !snapshot.verified;
    const time = snapshot.updatedAt > 0 ? new Date(snapshot.updatedAt) : undefined;
    return {
      formId: id, profileName: profileName || '请先导入配置',
      statusText: stale && active ? '状态待核实' : stateLabel(snapshot.state), state: snapshot.state,
      downloadText: snapshot.sessionId.length > 0 ? formatBytes(snapshot.downloadBytes) : '—',
      uploadText: snapshot.sessionId.length > 0 ? formatBytes(snapshot.uploadBytes) : '—',
      sessionText: snapshot.sessionId.length === 0 ? '累计流量' : (active ? '本次连接' : '上次连接'),
      updatedText: time === undefined ? '等待查询' : `更新 ${time.getHours().toString().padStart(2, '0')}:${time.getMinutes().toString().padStart(2, '0')}`,
      isBusy: snapshot.verified && isBusy(snapshot.state), isStale: stale,
      canConnect: !isBusy(snapshot.state) && snapshot.state !== 'CONNECTED' && index.defaultId.length > 0,
      canDisconnect: snapshot.verified && snapshot.state === 'CONNECTED', hint: snapshot.error,
      hasDefault: index.defaultId.length > 0
    };
  }

  async update(snapshot: VpnSnapshot, id: string): Promise<void> {
    try { await formProvider.updateForm(id, formBindingData.createFormBindingData(this.data(snapshot, id))); }
    catch (_) { throw new Error('卡片数据更新失败，请稍后刷新。'); }
  }

  async updateAll(snapshot: VpnSnapshot): Promise<void> {
    try {
      for (const id of this.ids()) {
        try { await this.update(snapshot, id); }
        catch (_) { /* Host may be temporarily unavailable; retain the prior visible timestamp. */ }
      }
    } catch (_) { console.warn('Card index is unavailable; retaining the previous card data.'); }
  }
}
