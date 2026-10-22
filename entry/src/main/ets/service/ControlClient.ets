import { common, Want } from '@kit.AbilityKit';
import { commonEventManager, systemDateTime } from '@kit.BasicServicesKit';
import { vpnExtension } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ControlCommand, ControlReply, Credentials, VpnSnapshot, emptySnapshot } from '../model/VpnModels';
import { PrivateFiles } from '../storage/PrivateFiles';
import { SecureStore } from '../storage/SecureStore';

export const CONTROL_EVENT = 'com.shuangsecai.ovpn.CONTROL';
export const VPN_WANT: Want = { bundleName: 'com.shuangsecai.ovpn', abilityName: 'OvpnAbility' };

function delay(ms: number): Promise<void> {
  return new Promise((resolve: () => void) => { setTimeout(resolve, ms); });
}

export class ControlClient {
  private files: PrivateFiles;
  private secure: SecureStore;
  private static mutationPending: boolean = false;

  constructor(context: common.Context) {
    this.files = new PrivateFiles(context);
    this.secure = new SecureStore(this.files);
  }

  cached(): VpnSnapshot {
    const result = this.files.exists('snapshot.json')
      ? JSON.parse(this.files.read('snapshot.json')) as VpnSnapshot : emptySnapshot();
    // Disk content is a display cache. Only a nonce-matching query verifies liveness.
    result.verified = false;
    return result;
  }

  async query(): Promise<VpnSnapshot> {
    return (await this.send('query', '', false)).snapshot;
  }

  async connect(profileId: string, credentials: Credentials): Promise<VpnSnapshot> {
    if (ControlClient.mutationPending) throw new Error('正在处理连接操作，请稍候。');
    ControlClient.mutationPending = true;
    try {
      await this.secure.pruneTransientSecrets();
      return (await this.send('connect', profileId, true, credentials)).snapshot;
    }
    finally { ControlClient.mutationPending = false; }
  }

  async disconnect(): Promise<VpnSnapshot> {
    if (ControlClient.mutationPending) throw new Error('正在处理连接操作，请稍候。');
    ControlClient.mutationPending = true;
    try {
      const snapshot = (await this.send('disconnect', '', false)).snapshot;
      if (snapshot.state !== 'DISCONNECTING') return snapshot;
      const deadline = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) + 5000;
      while (systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) < deadline) {
        await delay(200);
        const current = await this.query();
        if (current.verified && current.state === 'DISCONNECTED') return current;
      }
      return await this.stopExtension();
    }
    finally { ControlClient.mutationPending = false; }
  }

  private async stopExtension(): Promise<VpnSnapshot> {
    try { await vpnExtension.stopVpnExtensionAbility(VPN_WANT); }
    catch (_) { throw new Error('系统未能断开 VPN，请在系统设置中核实后重试。'); }
    const snapshot = this.cached();
    snapshot.state = 'DISCONNECTED';
    snapshot.verified = true;
    snapshot.updatedAt = Date.now();
    snapshot.downloadRate = 0;
    snapshot.uploadRate = 0;
    snapshot.error = '';
    this.files.write('snapshot.json', JSON.stringify(snapshot));
    return snapshot;
  }

  private async startExtension(): Promise<void> {
    let timer = -1;
    let timedOut = false;
    try {
      await Promise.race([
        vpnExtension.startVpnExtensionAbility(VPN_WANT),
        new Promise<void>((_resolve: () => void, reject: (reason: Error) => void) => {
          timer = setTimeout(() => {
            timedOut = true;
            reject(new Error('系统 VPN 授权或扩展启动未响应，请检查系统授权后重试。'));
          }, 60000);
        })
      ]);
    } catch (_) {
      throw new Error(timedOut ? '系统 VPN 授权或扩展启动未响应，请检查系统授权后重试。'
        : '系统 VPN 扩展启动失败，请确认系统授权和设备解锁状态后重试。');
    } finally { clearTimeout(timer); }
  }

  private async send(action: string, profileId: string, startExtension: boolean,
    credentials?: Credentials): Promise<ControlReply> {
    const id = util.generateRandomUUID(true);
    const command: ControlCommand = { id, action, profileId, createdAt: Date.now() };
    try {
      if (credentials !== undefined) await this.secure.putSecret(`once:${id}`, JSON.stringify(credentials));
      this.files.write(`commands/${id}.json`, JSON.stringify(command));
      if (startExtension) await this.startExtension();
      commonEventManager.publish(CONTROL_EVENT, { bundleName: 'com.shuangsecai.ovpn' }, () => {});
      // Authorization is handled by the OS before startVpnExtensionAbility resolves.
      const deadline = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) + (startExtension ? 12000 : 1800);
      while (systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) < deadline) {
        if (this.files.exists(`replies/${id}.json`)) {
          const reply = JSON.parse(this.files.read(`replies/${id}.json`)) as ControlReply;
          if (reply.id !== id) throw new Error('VPN 状态应答不匹配。');
          if (reply.error.length > 0) throw new Error(reply.error);
          reply.snapshot.verified = true;
          return reply;
        }
        await delay(80);
      }
      if (action === 'connect') throw new Error('VPN 扩展没有及时响应，请在应用内确认系统授权后重试。');
      const snapshot = this.cached();
      snapshot.verified = false;
      if (action === 'disconnect') {
        return { id, error: '', snapshot: await this.stopExtension() };
      }
      return { id, error: '', snapshot };
    } finally {
      try { this.files.remove(`commands/${id}.json`); }
      finally {
        try { this.files.remove(`replies/${id}.json`); }
        finally {
          if (credentials !== undefined) await this.secure.removeSecret(`once:${id}`);
        }
      }
    }
  }
}
