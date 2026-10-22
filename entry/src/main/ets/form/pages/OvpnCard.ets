const cardStorage = new LocalStorage();

@Entry(cardStorage)
@Component
struct OvpnCard {
  // FormDimension: 2 = 2*2, 3 = 2*4. Form UI cannot import FormKit APIs.
  @LocalStorageProp('dimension') dimension: number = 2;
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('profileName') profileName: string = '请先导入配置';
  @LocalStorageProp('statusText') statusText: string = '未连接';
  @LocalStorageProp('state') state: string = 'DISCONNECTED';
  @LocalStorageProp('downloadText') downloadText: string = '—';
  @LocalStorageProp('uploadText') uploadText: string = '—';
  @LocalStorageProp('sessionText') sessionText: string = '上次连接';
  @LocalStorageProp('updatedText') updatedText: string = '等待查询';
  @LocalStorageProp('isBusy') isBusy: boolean = false;
  @LocalStorageProp('isStale') isStale: boolean = true;
  @LocalStorageProp('canConnect') canConnect: boolean = false;
  @LocalStorageProp('canDisconnect') canDisconnect: boolean = false;
  @LocalStorageProp('hint') hint: string = '';
  @LocalStorageProp('hasDefault') hasDefault: boolean = false;

  private openApp(): void {
    postCardAction(this, { action: 'router', abilityName: 'EntryAbility' });
  }

  private call(method: string): void {
    postCardAction(this, { action: 'call', abilityName: 'CardControlAbility', params: { method, formId: this.formId } });
  }

  @Builder
  private heading(wide: boolean) {
    Column({ space: 3 }) {
      Text('双色彩OVPN').fontSize(wide ? 16 : 12).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.profileName).fontSize(wide ? 12 : 10).fontColor($r('app.color.text_secondary')).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.alignItems(HorizontalAlign.Start).width('100%').onClick(() => { this.openApp(); })
  }

  @Builder
  private status(wide: boolean) {
    Column({ space: 3 }) {
      Text(this.statusText).fontSize(wide ? 14 : 12).fontWeight(FontWeight.Medium).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.state === 'CONNECTED' && !this.isStale ? $r('app.color.success_text') : $r('app.color.text_secondary'))
      Text(this.sessionText).fontSize(wide ? 11 : 10).fontColor($r('app.color.text_secondary'))
    }.alignItems(HorizontalAlign.Start).onClick(() => { this.openApp(); })
  }

  @Builder
  private powerButton(wide: boolean) {
    Button({ type: ButtonType.Circle }) {
      if (this.isBusy) LoadingProgress().width(wide ? 28 : 24).height(wide ? 28 : 24).color(Color.White)
      else Image(this.canDisconnect ? $r('app.media.shield_connected') : $r('app.media.power_on_accent'))
        .width(wide ? 28 : 24).height(wide ? 28 : 24)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.7, y: 0.7 }))
          .animation({ duration: 800, curve: Curve.EaseOut }))
    }.id('cardPower').width(wide ? 52 : 44).height(wide ? 52 : 44)
      .backgroundColor(this.canDisconnect ? $r('app.color.accent') : $r('app.color.power_off'))
      .animation({ duration: 800, curve: Curve.EaseOut })
      .enabled(!this.isBusy).onClick(() => {
        if (!this.hasDefault) this.openApp();
        else this.call(this.canDisconnect ? 'vpnDisconnect' : (this.canConnect ? 'vpnConnect' : 'vpnRefresh'));
      }).accessibilityText(!this.hasDefault ? '打开应用导入配置' :
        (this.canDisconnect ? '断开 VPN' : (this.canConnect ? '连接默认 VPN' : '查询 VPN 状态')))
  }

  @Builder
  private traffic(wide: boolean) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text('下载').fontSize(wide ? 11 : 10).fontColor($r('app.color.text_secondary'))
        Text(this.downloadText).fontSize(wide ? 18 : 12).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 3 }) {
        Text('上传').fontSize(wide ? 11 : 10).fontColor($r('app.color.text_secondary'))
        Text(this.uploadText).fontSize(wide ? 18 : 12).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').onClick(() => { this.openApp(); })
  }

  @Builder
  private footer(wide: boolean) {
    Row({ space: 4 }) {
      Text(this.hint.length > 0 ? this.hint : (this.isStale ? this.updatedText + ' · 待核实' : this.updatedText))
        .fontSize(wide ? 10 : 9).fontColor($r('app.color.text_secondary')).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.refresh')).width(14).height(14)
      }.id('cardRefresh').width(24).height(24).backgroundColor(Color.Transparent).accessibilityText('刷新流量统计')
        .onClick(() => { this.call('vpnRefresh'); })
    }.width('100%').height(24)
  }

  build() {
    if (this.dimension === 3) {
      Column({ space: 8 }) {
        Row({ space: 12 }) {
          Column() { this.heading(true) }.layoutWeight(1)
          Column() { this.status(true) }.width(84)
          this.powerButton(true)
        }.width('100%')
        this.traffic(true)
        this.footer(true)
      }.id('vpnCard4x2').width('100%').height('100%').padding(12)
        .backgroundColor($r('app.color.surface')).justifyContent(FlexAlign.SpaceBetween)
    } else {
      Column({ space: 3 }) {
        this.heading(false)
        Row({ space: 2 }) {
          Column() { this.status(false) }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          this.powerButton(false)
        }.width('100%').height(44)
        this.traffic(false)
        this.footer(false)
      }.id('vpnCard2x2').width('100%').height('100%').padding(12)
        .backgroundColor($r('app.color.surface')).justifyContent(FlexAlign.SpaceBetween)
    }
  }
}
