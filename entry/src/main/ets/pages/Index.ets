import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Credentials, Profile, VpnSnapshot, emptySnapshot, formatBytes, formatDuration,
  isBusy, stateLabel } from '../model/VpnModels';
import { ProfileStore } from '../storage/ProfileStore';
import { ControlClient } from '../service/ControlClient';
import { FormSync } from '../service/FormSync';

@CustomDialog
struct AuthenticationDialog {
  controller?: CustomDialogController;
  requiresAuth: boolean = false;
  requiresKeyPassword: boolean = false;
  allowSave: boolean = false;
  lockedUsername: string = '';
  @State username: string = '';
  @State password: string = '';
  @State keyPassword: string = '';
  @State save: boolean = false;
  @State error: string = '';
  onSubmit: (credentials: Credentials, save: boolean) => void = () => {};

  build() {
    Column({ space: 16 }) {
      Text('服务器认证').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      Text('认证信息仅用于此 VPN 连接。').fontSize(14).fontColor($r('app.color.text_secondary'))
      if (this.requiresAuth) {
        TextInput({ placeholder: '用户名', text: this.username }).id('authUsername')
          .enabled(this.lockedUsername.length === 0).onChange((value: string) => { this.username = value; })
        TextInput({ placeholder: '密码', text: this.password }).type(InputType.Password).id('authPassword')
          .onChange((value: string) => { this.password = value; })
      }
      if (this.requiresKeyPassword) {
        TextInput({ placeholder: '私钥密码', text: this.keyPassword }).type(InputType.Password).id('keyPassword')
          .onChange((value: string) => { this.keyPassword = value; })
      }
      if (this.allowSave) {
        Row() {
          Checkbox({ name: 'saveCredentials', group: 'authentication' }).select(this.save)
            .selectedColor($r('app.color.accent')).onChange((value: boolean) => { this.save = value; })
          Text('在本机安全存储中保存密码').fontSize(13).fontColor($r('app.color.text_secondary'))
        }.width('100%')
      } else Text('此配置不允许保存认证密码。').fontSize(12).fontColor($r('app.color.text_secondary'))
      if (this.error.length > 0) Text(this.error).fontSize(13).fontColor($r('app.color.error_text'))
      Row({ space: 12 }) {
        Button('取消').onClick(() => { this.password = ''; this.keyPassword = ''; this.controller?.close(); })
          .layoutWeight(1).backgroundColor($r('app.color.page_background')).fontColor($r('app.color.text_primary'))
        Button('连接').id('confirmAuthentication').onClick(() => {
          if (this.requiresAuth && (this.username.trim().length === 0 || this.password.length === 0)) {
            this.error = '请输入用户名和密码。'; return;
          }
          if (this.requiresKeyPassword && this.keyPassword.length === 0) { this.error = '请输入私钥密码。'; return; }
          this.onSubmit({ username: this.username.trim(), password: this.password, keyPassword: this.keyPassword }, this.allowSave && this.save);
          this.password = ''; this.keyPassword = ''; this.controller?.close();
        }).layoutWeight(1).backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
      }
    }.padding(24).backgroundColor($r('app.color.surface')).borderRadius(24).width('92%')
  }
}

@CustomDialog
struct AboutDialog {
  controller?: CustomDialogController;
  onLicenses: () => void = () => {};

  build() {
    Column({ space: 20 }) {
      Text('双色彩OVPN · 0.1.0').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        .width('100%').textAlign(TextAlign.Start)
      Column({ space: 12 }) {
        ForEach([
          '鸿蒙原生 OpenVPN，支持卡片快速开关查询。',
          '无应用账号、广告或行为统计。',
          '配置加密保存在本机，密码是否保存由你选择。',
          '首次连接请在应用内完成系统授权。',
          '卡片展示累计流量及数据更新时间。'
        ], (message: string, index: number) => {
          Row({ space: 8 }) {
            Text(`${index + 1}.`).width(18).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.accent_text')).lineHeight(23).textAlign(TextAlign.Start)
            Text(message).layoutWeight(1).fontSize(15).fontColor($r('app.color.text_primary'))
              .lineHeight(23).textAlign(TextAlign.Start)
          }.width('100%').alignItems(VerticalAlign.Top)
        }, (message: string) => message)
      }.width('100%')
      Row({ space: 8 }) {
        Button('开源许可').id('aboutLicenses').layoutWeight(1).fontSize(15)
          .backgroundColor(Color.Transparent).fontColor($r('app.color.accent_text'))
          .onClick(() => { this.controller?.close(); this.onLicenses(); })
        Divider().vertical(true).height(22).color($r('app.color.divider'))
        Button('知道了').id('closeAbout').layoutWeight(1).fontSize(15)
          .backgroundColor(Color.Transparent).fontColor($r('app.color.text_secondary'))
          .onClick(() => { this.controller?.close(); })
      }.width('100%')
    }.padding(24).backgroundColor($r('app.color.surface')).borderRadius(28).width('92%').constraintSize({ maxWidth: 420 })
  }
}

@CustomDialog
struct RenameDialog {
  controller?: CustomDialogController;
  @State name: string = '';
  onSave: (name: string) => void = () => {};

  build() {
    Column({ space: 20 }) {
      Text('重命名配置').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      TextInput({ text: this.name, placeholder: '配置名称' }).maxLength(64).id('renameInput')
        .onChange((value: string) => { this.name = value; })
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).backgroundColor($r('app.color.page_background')).fontColor($r('app.color.text_primary'))
          .onClick(() => { this.controller?.close(); })
        Button('保存').id('saveProfileName').layoutWeight(1).backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
          .enabled(this.name.trim().length > 0).onClick(() => { this.onSave(this.name); this.controller?.close(); })
      }
    }.padding(24).backgroundColor($r('app.color.surface')).borderRadius(24).width('92%')
  }
}

@Entry
@Component
struct Index {
  @StorageLink('appForeground') @Watch('onForegroundChanged') foreground: boolean = true;
  @StorageLink('importUri') @Watch('onImportUri') importUri: string = '';
  @State tab: number = 0;
  @State profiles: Profile[] = [];
  @State defaultId: string = '';
  @State selectedId: string = '';
  @State snapshot: VpnSnapshot = emptySnapshot();
  @State working: boolean = false;
  @State phaseLabel: string = '';
  @State error: string = '';
  private store?: ProfileStore;
  private control?: ControlClient;
  private forms?: FormSync;
  private timer: number = -1;
  private refreshing: boolean = false;
  private controlRevision: number = 0;
  private dialog?: CustomDialogController;

  aboutToAppear(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.store = new ProfileStore(context, this.getUIContext());
      this.store.secure.pruneTransientSecrets().catch((reason: Error) => { this.error = reason.message; });
      this.control = new ControlClient(context);
      this.forms = new FormSync(context);
      this.reloadProfiles();
      this.snapshot = this.control.cached();
      this.refresh();
      this.startPolling();
      this.onImportUri();
    } catch (reason) { this.error = (reason as Error).message || '应用存储初始化失败，请重新打开应用。'; }
  }

  aboutToDisappear(): void { clearInterval(this.timer); this.dialog?.close(); }

  private onForegroundChanged(): void {
    if (this.foreground) { this.refresh(); this.startPolling(); }
    else { clearInterval(this.timer); this.timer = -1; }
  }

  private startPolling(): void {
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = setInterval(() => { if (this.foreground) this.refresh(); }, 1000);
  }

  private reloadProfiles(): void {
    if (this.store === undefined) return;
    const index = this.store.index();
    this.profiles = [...index.profiles.filter((profile: Profile) => profile.id === index.defaultId),
      ...index.profiles.filter((profile: Profile) => profile.id !== index.defaultId)];
    this.defaultId = index.defaultId;
    if (!this.profiles.some((item: Profile) => item.id === this.selectedId)) this.selectedId = this.defaultId;
  }

  private async refresh(): Promise<void> {
    if (this.refreshing || this.working || this.control === undefined) return;
    this.refreshing = true;
    const revision = this.controlRevision;
    try {
      const next = await this.control.query();
      if (revision === this.controlRevision) this.snapshot = next;
    }
    catch (_) { if (revision === this.controlRevision) this.snapshot = this.control.cached(); }
    finally { this.refreshing = false; }
  }

  private async onImportUri(): Promise<void> {
    if (this.importUri.length === 0 || this.store === undefined || this.working) return;
    const uri = this.importUri;
    this.importUri = '';
    await this.importFile(uri);
  }

  private async importFile(uri: string = ''): Promise<void> {
    if (this.working || this.store === undefined) return;
    this.working = true;
    this.error = '';
    try {
      const profile = uri.length > 0 ? await this.store.importUri(uri) : await this.store.pickAndImport();
      if (profile !== undefined) {
        this.reloadProfiles();
        if (this.snapshot.state !== 'CONNECTED' && !isBusy(this.snapshot.state)) this.selectedId = profile.id;
        this.tab = 1;
      }
      await this.forms?.updateAll(this.snapshot);
    } catch (reason) { this.error = (reason as Error).message || '导入未完成，请重新选择配置。'; }
    finally { this.working = false; if (this.importUri.length > 0) this.onImportUri(); }
  }

  private selectedProfile(): Profile | undefined {
    return this.profiles.find((item: Profile) => item.id === this.selectedId);
  }

  private async primaryAction(): Promise<void> {
    if (this.working || isBusy(this.snapshot.state)) return;
    if (this.snapshot.state === 'CONNECTED') {
      if (!this.snapshot.verified) { await this.refresh(); return; }
      await this.disconnect(); return;
    }
    const profile = this.selectedProfile();
    if (profile === undefined) { this.tab = 1; await this.importFile(); return; }
    this.error = '';
    const credentials = await this.store!.savedCredentials(profile.id);
    if (profile.lockedUsername.length > 0) credentials.username = profile.lockedUsername;
    if (profile.requiresAuth || profile.requiresKeyPassword) {
      this.dialog = new CustomDialogController({
        builder: AuthenticationDialog({
          requiresAuth: profile.requiresAuth, requiresKeyPassword: profile.requiresKeyPassword,
          allowSave: profile.requiresAuth ? profile.allowPasswordSave : true, lockedUsername: profile.lockedUsername,
          username: credentials.username, password: credentials.password, keyPassword: credentials.keyPassword,
          save: credentials.password.length > 0 || credentials.keyPassword.length > 0,
          onSubmit: (values: Credentials, save: boolean) => { this.connect(profile, values, save); }
        }), autoCancel: false, customStyle: true
      });
      this.dialog.open();
    } else await this.connect(profile, credentials, false);
  }

  private async connect(profile: Profile, credentials: Credentials, save: boolean): Promise<void> {
    if (this.working || this.control === undefined || this.store === undefined) return;
    this.controlRevision++;
    this.working = true;
    this.error = '';
    this.phaseLabel = '等待系统 VPN 授权';
    try {
      if (save) await this.store.secure.putSecret(`auth:${profile.id}`, JSON.stringify(credentials));
      else await this.store.secure.removeSecret(`auth:${profile.id}`);
      this.snapshot = await this.control.connect(profile.id, credentials);
      this.tab = 0;
    } catch (reason) {
      this.error = (reason as Error).message || '连接未启动，请检查系统授权。';
      await this.refresh();
    } finally { credentials.password = ''; credentials.keyPassword = ''; this.phaseLabel = ''; this.working = false; }
  }

  private async disconnect(): Promise<void> {
    if (this.working || this.control === undefined) return;
    this.controlRevision++;
    this.working = true;
    this.error = '';
    this.snapshot.state = 'DISCONNECTING';
    try { this.snapshot = await this.control.disconnect(); }
    catch (reason) { this.error = (reason as Error).message; }
    finally { this.working = false; }
  }

  private async selectProfile(profile: Profile): Promise<void> {
    if (this.working || isBusy(this.snapshot.state)) return;
    const reconnect = this.snapshot.state === 'CONNECTED' && this.snapshot.profileId !== profile.id;
    if (reconnect && this.control !== undefined) {
      this.controlRevision++;
      this.working = true;
      this.error = '';
      try {
        this.snapshot = await this.control.disconnect();
        const deadline = Date.now() + 15000;
        while (this.snapshot.state === 'CONNECTED' || isBusy(this.snapshot.state)) {
          if (Date.now() >= deadline) throw new Error('旧连接尚未释放，请核实状态后重试。');
          await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 200); });
          this.snapshot = await this.control.query();
          if (!this.snapshot.verified) throw new Error('无法核实旧连接是否结束，请先请求系统断开。');
        }
      } catch (reason) {
        this.error = (reason as Error).message; this.tab = 0; this.working = false; return;
      }
      this.working = false;
    }
    this.selectedId = profile.id;
    this.tab = 0;
    if (reconnect) await this.primaryAction();
  }

  private rename(profile: Profile): void {
    this.dialog = new CustomDialogController({
      builder: RenameDialog({ name: profile.name, onSave: (name: string) => {
        try { this.store?.rename(profile.id, name); this.reloadProfiles(); this.forms?.updateAll(this.snapshot); }
        catch (reason) { this.error = (reason as Error).message; }
      } }), customStyle: true
    });
    this.dialog.open();
  }

  private async remove(profile: Profile): Promise<void> {
    if (this.snapshot.profileId === profile.id && (this.snapshot.state === 'CONNECTED' || isBusy(this.snapshot.state))) {
      this.error = '请先断开此配置的连接，再删除。'; return;
    }
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({ title: '删除配置',
        message: `删除“${profile.name}”及其本机保存的认证信息？`,
        buttons: [{ text: '取消', color: $r('app.color.text_secondary') }, { text: '删除', color: $r('app.color.error_text') }] });
      if (result.index !== 1) return;
      await this.store?.remove(profile.id); this.reloadProfiles(); await this.forms?.updateAll(this.snapshot);
    }
    catch (reason) { this.error = (reason as Error).message; }
  }

  private titleStatus(): string {
    if (this.phaseLabel.length > 0) return this.phaseLabel;
    if (!this.snapshot.verified && (this.snapshot.state === 'CONNECTED' || isBusy(this.snapshot.state))) return '状态待核实';
    return stateLabel(this.snapshot.state);
  }

  private about(): void {
    this.dialog = new CustomDialogController({ builder: AboutDialog({
      onLicenses: () => { this.showLicenses(); }
    }), customStyle: true });
    this.dialog.open();
  }

  private async showLicenses(): Promise<void> {
    try {
      const prompt = this.getUIContext().getPromptAction();
      const choice = await prompt.showActionMenu({ title: '开源组件许可', buttons: [
        { text: 'OpenVPN 3 · MPL 2.0', color: $r('app.color.text_primary') },
        { text: 'Mbed TLS · Apache 2.0 / GPL', color: $r('app.color.text_primary') },
        { text: 'Asio · Boost 1.0', color: $r('app.color.text_primary') }
      ] });
      const filenames = ['OpenVPN-MPL-2.0.txt', 'MbedTLS-LICENSE.txt', 'Asio-LICENSE.txt'];
      const manager = this.getUIContext().getHostContext()!.resourceManager;
      const data = await manager.getRawFileContent(`licenses/${filenames[choice.index]}`);
      await prompt.showDialog({ title: '开源许可', message: new util.TextDecoder().decodeToString(data),
        buttons: [{ text: '关闭', color: $r('app.color.accent_text') }] });
    } catch (_) { console.warn('License dialog was cancelled or unavailable; retaining the application page.'); }
  }

  @Builder
  private connectionPage() {
    Column({ space: 20 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Image($r('app.media.server')).width(28).height(28)
          Column({ space: 4 }) {
            Text(this.selectedProfile()?.name ?? '选择一个 VPN 配置').fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.selectedId === this.defaultId && this.defaultId.length > 0 ? '默认配置 · 卡片快速连接' : '点击管理配置')
              .fontSize(12).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Image($r('app.media.chevron_right')).width(20).height(20)
        }.width('100%')
      }.id('openProfiles').width('100%').padding(18).borderRadius(20).backgroundColor($r('app.color.surface'))
        .onClick(() => { this.tab = 1; }).accessibilityText('选择或管理 VPN 配置')
      Column({ space: 12 }) {
        Stack() {
          Circle().width(164).height(164).fill($r('app.color.accent_surface'))
          Button({ type: ButtonType.Circle }) {
            if (this.working || isBusy(this.snapshot.state)) LoadingProgress().width(48).height(48).color(Color.White)
            else if (this.snapshot.verified && this.snapshot.state === 'CONNECTED') {
              Stack() {
                LoadingProgress().id('vpnConnectedMotion').width(112).height(112).color(Color.White).opacity(0.45)
                Image($r('app.media.shield_connected')).width(56).height(56)
              }
            }
            else Image($r('app.media.power_on_accent')).width(56).height(56)
          }.id('vpnPowerButton').width(126).height(126)
            .backgroundColor(this.snapshot.verified && this.snapshot.state === 'CONNECTED' ?
              $r('app.color.accent') : $r('app.color.power_off'))
            .enabled(!this.working && !isBusy(this.snapshot.state)).onClick(() => {
              this.primaryAction().catch((reason: Error) => { this.error = reason.message; });
            }).accessibilityText(this.snapshot.state === 'CONNECTED' && this.snapshot.verified ? '断开 VPN' : '连接 VPN')
        }.height(184)
        Text(this.titleStatus()).id('connectionStatus').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(this.snapshot.state === 'CONNECTED' ? (this.snapshot.verified ? '点击上方开关断开连接' : '点击查询以核实真实状态') : '点击上方开关连接 VPN')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
        Text(this.snapshot.sessionId.length > 0 ? formatDuration(this.snapshot.durationSeconds) : '00:00:00')
          .fontSize(16).fontColor($r('app.color.text_secondary')).fontFamily('monospace')
        if (!this.snapshot.verified && (this.snapshot.state === 'CONNECTED' || isBusy(this.snapshot.state))) {
          Button('请求系统断开').backgroundColor($r('app.color.accent_surface')).fontColor($r('app.color.accent_text')).onClick(() => { this.disconnect(); })
        }
      }.width('100%').padding({ top: 4, bottom: 12 })
      Column({ space: 18 }) {
        Row() {
          Text(this.snapshot.sessionId.length === 0 ? '连接统计' :
            (this.snapshot.state === 'CONNECTED' || isBusy(this.snapshot.state) ? '本次连接' : '上次连接'))
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text('隧道内 IP 数据').fontSize(11).fontColor($r('app.color.text_secondary'))
        }.width('100%')
        Row({ space: 16 }) {
          this.trafficColumn('下载', true)
          Divider().vertical(true).height(90).color($r('app.color.divider'))
          this.trafficColumn('上传', false)
        }.width('100%')
        Text(this.snapshot.updatedAt > 0 ? `数据更新于 ${new Date(this.snapshot.updatedAt).toLocaleTimeString()}` : '连接后展示实际统计')
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
      }.width('100%').padding(20).backgroundColor($r('app.color.surface')).borderRadius(20)
      if (this.snapshot.error.length > 0) this.notice(this.snapshot.error)
      Text('原生连接 · 本机保存 · 无账号与广告').fontSize(12).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
    }.width('100%')
  }

  @Builder
  private trafficColumn(label: string, download: boolean) {
    Column({ space: 7 }) {
      Row({ space: 5 }) {
        Image(download ? $r('app.media.download') : $r('app.media.upload')).width(18).height(18)
        Text(label).fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      // Read state directly: primitive @Builder arguments retain their initial values.
      Text(this.snapshot.sessionId.length > 0 ? formatBytes(download ? this.snapshot.downloadBytes : this.snapshot.uploadBytes) : '—')
        .id(download ? 'downloadBytes' : 'uploadBytes').fontSize(21).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.snapshot.verified && this.snapshot.state === 'CONNECTED' ?
        `${formatBytes(download ? this.snapshot.downloadRate : this.snapshot.uploadRate)}/s` : '— /s')
        .id(download ? 'downloadRate' : 'uploadRate')
        .fontSize(13).fontColor($r('app.color.text_secondary'))
      Text(this.snapshot.sessionId.length > 0 ? `${Math.floor(download ? this.snapshot.downloadPackets : this.snapshot.uploadPackets)} 包` : '— 包')
        .id(download ? 'downloadPackets' : 'uploadPackets').fontSize(11).fontColor($r('app.color.text_secondary'))
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
  }

  @Builder
  private profilesPage() {
    Column({ space: 16 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 14 }) {
          Image($r('app.media.import_file')).width(32).height(32)
          Column({ space: 5 }) {
            Text('导入 .ovpn 配置').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent_text'))
            Text('从系统文件中选择已有配置').fontSize(12).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
      }.id('importProfile').width('100%').padding(22).backgroundColor($r('app.color.accent_surface')).borderRadius(20)
        .enabled(!this.working).onClick(() => { this.importFile(); })
      if (this.profiles.length === 0) {
        Column({ space: 12 }) {
          Image($r('app.media.server')).width(48).height(48).opacity(0.55)
          Text('尚未导入配置').fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text('准备好你已在其他客户端使用的 .ovpn，导入后即可连接。')
            .fontSize(14).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
        }.width('100%').padding({ top: 64, bottom: 64, left: 20, right: 20 })
      } else {
        ForEach(this.profiles, (profile: Profile) => {
          Row({ space: 12 }) {
            Image($r('app.media.server')).width(26).height(26)
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text(profile.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                if (profile.id === this.defaultId) {
                  Text('默认配置').id('defaultProfileBadge').fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.accent_text')).backgroundColor($r('app.color.accent_surface'))
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(8).flexShrink(0)
                }
              }.width('100%')
              Text(`${profile.protocol}${profile.id === this.snapshot.profileId && this.snapshot.state === 'CONNECTED' && this.snapshot.verified ? ' · 已连接' : ''}`)
                .fontSize(12).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick(() => { this.selectProfile(profile); })
            Button({ type: ButtonType.Circle }) {
              Image($r('app.media.more')).width(22).height(22)
            }.width(48).height(48).backgroundColor($r('app.color.page_background')).accessibilityText(`管理配置 ${profile.name}`)
              .bindMenu([
                { value: '设为默认配置', action: () => {
                  this.store?.setDefault(profile.id); this.reloadProfiles(); this.forms?.updateAll(this.snapshot);
                } },
                { value: '重命名', action: () => { this.rename(profile); } },
                { value: '删除', action: () => { this.remove(profile); } }
              ])
          }.width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(20)
            .border({ width: profile.id === this.selectedId ? 1.5 : 0, color: $r('app.color.accent') })
        }, (profile: Profile) => `${profile.id}:${profile.name}:${profile.id === this.defaultId}`)
      }
      Row({ space: 7 }) {
        Image($r('app.media.shield')).width(17).height(17)
        Text('配置加密保存在本机，密码由系统安全存储保护。').fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      }.width('100%').padding({ top: 12 })
    }.width('100%')
  }

  @Builder
  private notice(message: string) {
    Text(message).fontSize(13).fontColor($r('app.color.error_text')).padding(14).width('100%').backgroundColor($r('app.color.error_surface')).borderRadius(12)
  }

  build() {
    Column() {
      Row() {
        Text(this.tab === 0 ? '双色彩OVPN' : '配置').fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button('关于').fontSize(13).fontColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent)
          .onClick(() => { this.about(); })
      }.width('100%').padding({ left: 20, right: 12, top: 12, bottom: 16 })
      Scroll() {
        Column({ space: 16 }) {
          if (this.error.length > 0) this.notice(this.error)
          if (this.tab === 0) this.connectionPage()
          else this.profilesPage()
        }.width('100%').padding({ left: 20, right: 20, bottom: 24 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
      Row() {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 4 }) {
            Image($r('app.media.power')).width(24).height(24)
            Text('连接').fontSize(12).fontColor(this.tab === 0 ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
          }.width('100%').padding(10)
        }.id('connectionTab').layoutWeight(1).backgroundColor(this.tab === 0 ? $r('app.color.accent_surface') : $r('app.color.surface')).onClick(() => { this.tab = 0; })
        Button({ type: ButtonType.Normal }) {
          Column({ space: 4 }) {
            Image($r('app.media.server')).width(24).height(24)
            Text('配置').fontSize(12).fontColor(this.tab === 1 ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
          }.width('100%').padding(10)
        }.id('profilesTab').layoutWeight(1).backgroundColor(this.tab === 1 ? $r('app.color.accent_surface') : $r('app.color.surface')).onClick(() => { this.tab = 1; })
      }.width('100%').backgroundColor($r('app.color.surface'))
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
