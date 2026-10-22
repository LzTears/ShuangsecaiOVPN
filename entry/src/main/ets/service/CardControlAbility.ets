import { UIAbility } from '@kit.AbilityKit';
import { rpc } from '@kit.IPCKit';
import { ControlClient } from './ControlClient';
import { FormSync } from './FormSync';
import { ProfileStore } from '../storage/ProfileStore';
import { VpnSnapshot, emptySnapshot, isBusy } from '../model/VpnModels';

class Acknowledgement implements rpc.Parcelable {
  marshalling(sequence: rpc.MessageSequence): boolean { sequence.writeString('accepted'); return true; }
  unmarshalling(_sequence: rpc.MessageSequence): boolean { return true; }
}

// Private, single-instance UIAbility is the documented Form call target.
// It has no window and sends intents to the VPN extension through the private mailbox.
export default class CardControlAbility extends UIAbility {
  onCreate(): void {
    this.callee.on('vpnConnect', (_data: rpc.MessageSequence) => {
      this.handle('connect'); return new Acknowledgement();
    });
    this.callee.on('vpnDisconnect', (_data: rpc.MessageSequence) => {
      this.handle('disconnect'); return new Acknowledgement();
    });
    this.callee.on('vpnRefresh', (_data: rpc.MessageSequence) => {
      this.handle('query'); return new Acknowledgement();
    });
  }

  private async handle(action: string): Promise<void> {
    const control = new ControlClient(this.context);
    const forms = new FormSync(this.context);
    let snapshot: VpnSnapshot = emptySnapshot();
    try {
      snapshot = await control.query();
      if (action === 'connect') {
        if (snapshot.verified && (snapshot.state === 'CONNECTED' || isBusy(snapshot.state))) {
          await forms.updateAll(snapshot); return;
        }
        if (!snapshot.verified && (snapshot.state === 'CONNECTED' || isBusy(snapshot.state)))
          throw new Error('状态待核实，请打开应用确认连接状态。');
        const store = new ProfileStore(this.context);
        if (!store.files.exists('authorized.json')) throw new Error('首次连接请先打开应用完成配置与系统授权。');
        const index = store.index();
        const profile = index.profiles.find((item) => item.id === index.defaultId);
        if (profile === undefined) throw new Error('请先打开应用导入默认配置。');
        const credentials = await store.savedCredentials(profile.id);
        if ((profile.requiresAuth && (credentials.username.length === 0 || credentials.password.length === 0))
          || (profile.requiresKeyPassword && credentials.keyPassword.length === 0))
          throw new Error('需要认证信息，请打开应用连接。');
        snapshot = await control.connect(profile.id, credentials);
      } else if (action === 'disconnect') {
        if (snapshot.verified && (snapshot.state === 'CONNECTED' || snapshot.state === 'CONNECTING'))
          snapshot = await control.disconnect();
      }
    } catch (error) {
      snapshot.error = (error as Error).message;
    }
    await forms.updateAll(snapshot);
  }

  onDestroy(): void {
    this.callee.off('vpnConnect');
    this.callee.off('vpnDisconnect');
    this.callee.off('vpnRefresh');
  }
}
