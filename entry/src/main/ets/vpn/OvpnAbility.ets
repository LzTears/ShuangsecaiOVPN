import { Want } from '@kit.AbilityKit';
import { VpnExtensionAbility, connection, vpnExtension } from '@kit.NetworkKit';
import { commonEventManager, systemDateTime } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import ovpn from 'libovpn.so';
import { ControlCommand, ControlReply, CoreMessage, Credentials, NativeSnapshot, ProfileIndex,
  VpnSnapshot, coreError, emptySnapshot, isBusy } from '../model/VpnModels';
import { Traffic } from '../model/Traffic';
import { PrivateFiles } from '../storage/PrivateFiles';
import { SecureStore } from '../storage/SecureStore';
import { CONTROL_EVENT } from '../service/ControlClient';
import { FormSync } from '../service/FormSync';

export default class OvpnAbility extends VpnExtensionAbility {
  private files?: PrivateFiles;
  private secure?: SecureStore;
  private forms?: FormSync;
  private vpn?: vpnExtension.VpnConnection;
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private current: VpnSnapshot = emptySnapshot();
  private traffic: Traffic = new Traffic();
  private timer: number = -1;
  private startMonotonic: number = 0;
  private draining: boolean = false;
  private shuttingDown: boolean = false;
  private tunExists: boolean = false;
  private sessionOpen: boolean = false;
  private systemError: string = '';

  onCreate(_want: Want): void {
    this.files = new PrivateFiles(this.context);
    this.secure = new SecureStore(this.files);
    this.forms = new FormSync(this.context);
    this.vpn = vpnExtension.createVpnConnection(this.context);
    if (this.files.exists('snapshot.json')) {
      this.current = JSON.parse(this.files.read('snapshot.json')) as VpnSnapshot;
      // A fresh extension cannot inherit a previous process's tunnel.
      this.current.state = 'DISCONNECTED';
      this.current.downloadRate = 0;
      this.current.uploadRate = 0;
      this.current.error = '';
    }
    this.publish(true);
    commonEventManager.createSubscriber({ events: [CONTROL_EVENT], publisherBundleName: 'com.shuangsecai.ovpn' })
      .then((subscriber: commonEventManager.CommonEventSubscriber) => {
        if (this.shuttingDown) return;
        this.subscriber = subscriber;
        commonEventManager.subscribe(subscriber, () => { this.drain(); });
        this.drain();
      }).catch(() => { this.drain(); });
    this.timer = setInterval(() => {
      this.sample();
      this.drain();
    }, 1000);
  }

  private publish(updateCards: boolean): void {
    if (this.shuttingDown) return;
    this.current.updatedAt = Date.now();
    this.current.verified = true;
    this.files?.write('snapshot.json', JSON.stringify(this.current));
    if (updateCards) this.forms?.updateAll(this.current);
  }

  private sample(persist: boolean = false): void {
    if (this.shuttingDown) return;
    const native = JSON.parse(ovpn.snapshot()) as NativeSnapshot;
    if (this.current.sessionId.length > 0 && native.running && native.state === 'CONNECTED') {
      const now = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
      this.traffic.sample(native, this.current, now);
    }
    if (native.running) this.current.durationSeconds = Math.max(0,
      (systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) - this.startMonotonic) / 1000);
    if (native.running) this.current.state = this.current.state === 'DISCONNECTING' ? 'DISCONNECTING' : native.state;
    this.current.updatedAt = Date.now();
    this.current.verified = true;
    if (persist) this.files?.write('snapshot.json', JSON.stringify(this.current));
  }

  private async drain(): Promise<void> {
    if (this.draining || this.shuttingDown || this.files === undefined) return;
    this.draining = true;
    try {
      const names = this.files.list('commands').filter((name: string) => name.endsWith('.json'));
      const commands: ControlCommand[] = [];
      for (const name of names) {
        const id = name.substring(0, name.length - 5);
        if (!this.files.claimCommand(id)) continue;
        const command = JSON.parse(this.files.read(`commands/${id}.processing`)) as ControlCommand;
        if (name === `${command.id}.json`) commands.push(command);
      }
      commands.sort((a: ControlCommand, b: ControlCommand) => a.createdAt - b.createdAt);
      for (const command of commands) {
        const age = Date.now() - command.createdAt;
        if (age > 60000 || age < -5000) {
          this.files.remove(`commands/${command.id}.processing`);
          await this.secure?.removeSecret(`once:${command.id}`);
          continue;
        }
        if (this.files.exists(`replies/${command.id}.json`)) continue;
        let error = '';
        try {
          if (command.action === 'connect') await this.connect(command);
          else if (command.action === 'disconnect') this.disconnect();
          else if (command.action !== 'query') throw new Error('未知 VPN 操作。');
          this.sample(true);
        } catch (reason) { error = (reason as Error).message; }
        const reply: ControlReply = { id: command.id, error, snapshot: this.current };
        this.files.write(`replies/${command.id}.json`, JSON.stringify(reply));
        this.files.remove(`commands/${command.id}.processing`);
      }
      // An interrupted UI process may leave replies behind. They contain no credentials.
      for (const name of this.files.list('replies')) {
        if (!name.endsWith('.json')) continue;
        const reply = JSON.parse(this.files.read(`replies/${name}`)) as ControlReply;
        if (Date.now() - reply.snapshot.updatedAt > 60000) this.files.remove(`replies/${name}`);
      }
    } finally { this.draining = false; }
  }

  private async connect(command: ControlCommand): Promise<void> {
    if (this.files === undefined || this.secure === undefined) return;
    const native = JSON.parse(ovpn.snapshot()) as NativeSnapshot;
    if (native.running || this.sessionOpen || isBusy(this.current.state))
      throw new Error('已有 VPN 会话或正在清理连接，请稍候再试。');
    const index = JSON.parse(this.files.read('profiles.json')) as ProfileIndex;
    const profile = index.profiles.find((item) => item.id === command.profileId);
    if (profile === undefined) throw new Error('配置不存在，请回到应用重新选择。');
    const secret = await this.secure.getSecret(`once:${command.id}`);
    await this.secure.removeSecret(`once:${command.id}`);
    const credentials: Credentials = secret.length > 0 ? JSON.parse(secret) as Credentials
      : { username: '', password: '', keyPassword: '' };
    if (profile.requiresAuth && (credentials.username.length === 0 || credentials.password.length === 0))
      throw new Error('需要服务器用户名和密码，请在应用内连接。');
    if (profile.requiresKeyPassword && credentials.keyPassword.length === 0)
      throw new Error('需要私钥密码，请在应用内连接。');
    const content = await this.secure.readProfile(profile.id);
    this.current = emptySnapshot();
    this.current.profileId = profile.id;
    this.current.profileName = profile.name;
    this.current.sessionId = util.generateRandomUUID(true);
    this.current.startedAt = Date.now();
    this.current.state = 'CONNECTING';
    this.startMonotonic = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
    this.traffic = new Traffic();
    this.systemError = '';
    this.sessionOpen = true;
    this.publish(true);
    const sessionId = this.current.sessionId;
    const started = ovpn.start(content, credentials.username, credentials.password, credentials.keyPassword,
      (message: string) => { if (this.current.sessionId === sessionId) this.onCoreMessage(message); });
    credentials.password = '';
    credentials.keyPassword = '';
    if (!started) {
      this.sessionOpen = false;
      this.current.state = 'FAILED';
      this.current.error = 'OpenVPN 核心未能启动，请稍后重试。';
      this.publish(true);
      throw new Error(this.current.error);
    }
  }

  private disconnect(): void {
    const native = JSON.parse(ovpn.snapshot()) as NativeSnapshot;
    if (!native.running) return;
    if (this.current.state === 'DISCONNECTING') return;
    this.sample();
    this.current.state = 'DISCONNECTING';
    this.publish(true);
    ovpn.stop();
  }

  private async destroyTun(): Promise<void> {
    if (this.tunExists) {
      await this.vpn?.destroy();
      this.tunExists = false;
    }
  }

  private async onCoreMessage(text: string): Promise<void> {
    const message = JSON.parse(text) as CoreMessage;
    if (this.shuttingDown) return;
    try {
      if (message.type === 'protect') {
        await this.vpn?.protect(message.fd);
        if (!this.shuttingDown) ovpn.respond(message.requestId, 1);
      } else if (message.type === 'tun') {
        await this.destroyTun();
        const addresses: connection.LinkAddress[] = message.addresses.map((item) => {
          const address: connection.LinkAddress = {
            address: { address: item.address, family: item.ipv6 ? 2 : 1 }, prefixLength: item.prefix
          };
          return address;
        });
        const routes: connection.RouteInfo[] = message.routes.map((item) => {
          const route: connection.RouteInfo = {
            interface: '', destination: {
              address: { address: item.address, family: item.ipv6 ? 2 : 1 }, prefixLength: item.prefix
            }, gateway: { address: '', family: item.ipv6 ? 2 : 1 }, hasGateway: false,
            isDefaultRoute: item.prefix === 0
          };
          return route;
        });
        const config: vpnExtension.VpnConfig = {
          addresses, routes, dnsAddresses: message.dns, searchDomains: message.domains, mtu: message.mtu,
          isIPv4Accepted: message.addresses.some((item) => !item.ipv6),
          isIPv6Accepted: message.addresses.some((item) => item.ipv6), isBlocking: false
        };
        const fd = await this.vpn!.create(config);
        this.tunExists = true;
        const accepted = !this.shuttingDown && ovpn.respond(message.requestId, fd);
        ovpn.closeFd(fd);
        if (!accepted) await this.destroyTun();
      } else if (message.type === 'destroyTun') {
        await this.destroyTun();
        ovpn.respond(message.requestId, 1);
      } else if (message.type === 'state') {
        if (this.current.state !== 'DISCONNECTING' || message.state === 'DISCONNECTED' || message.state === 'FAILED')
          this.current.state = message.state;
        if (message.error.length > 0) this.current.error = coreError(message.error);
        if (message.state === 'CONNECTED') {
          this.current.error = '';
          this.files?.write('authorized.json', '{"completed":true}');
        }
        this.sample();
        this.publish(true);
      } else if (message.type === 'stopped') {
        await this.destroyTun();
        const native = JSON.parse(ovpn.snapshot()) as NativeSnapshot;
        this.traffic.sample(native, this.current, systemDateTime.getUptime(systemDateTime.TimeType.STARTUP));
        this.current.durationSeconds = Math.max(0,
          (systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) - this.startMonotonic) / 1000);
        this.current.state = native.state === 'DISCONNECTED' ? 'DISCONNECTED' : 'FAILED';
        if (this.systemError.length > 0) this.current.error = this.systemError;
        else if (this.current.state === 'FAILED' && this.current.error.length === 0) this.current.error = coreError(native.error);
        this.current.downloadRate = 0;
        this.current.uploadRate = 0;
        this.sessionOpen = false;
        this.publish(true);
      }
    } catch (_) {
      this.systemError = coreError('SYSTEM_VPN_ERROR');
      this.current.error = this.systemError;
      ovpn.respond(message.requestId, -1);
      ovpn.stop();
      this.publish(true);
    }
  }

  async onDestroy(): Promise<void> {
    this.sample();
    this.shuttingDown = true;
    clearInterval(this.timer);
    ovpn.stop();
    if (this.subscriber !== undefined) commonEventManager.unsubscribe(this.subscriber, () => {});
    await this.destroyTun();
    this.current.state = 'DISCONNECTED';
    this.current.downloadRate = 0;
    this.current.uploadRate = 0;
    this.current.verified = false;
    this.current.updatedAt = Date.now();
    this.files?.write('snapshot.json', JSON.stringify(this.current));
    await this.forms?.updateAll(this.current);
  }
}
