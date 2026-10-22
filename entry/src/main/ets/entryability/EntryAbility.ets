import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    try { this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET); }
    catch (_) { console.warn('Automatic theme initialization failed; retaining the system theme.'); }
    this.acceptFile(want);
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void { this.acceptFile(want); }

  private acceptFile(want: Want): void {
    if (want.uri !== undefined && want.uri.length > 0) AppStorage.setOrCreate('importUri', want.uri);
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index', (error) => {
      if (error.code) return;
      this.mainWindow = stage.getMainWindowSync();
      this.updateWindowColors();
    });
  }

  onWindowStageDestroy(): void { this.mainWindow = undefined; }

  onConfigurationUpdate(_configuration: Configuration): void { this.updateWindowColors(); }

  private updateWindowColors(): void {
    if (this.mainWindow === undefined) return;
    try {
      const resources = this.context.resourceManager;
      const background = `#${(resources.getColorSync($r('app.color.page_background').id) >>> 0).toString(16).padStart(8, '0')}`;
      const foreground = `#${(resources.getColorSync($r('app.color.text_primary').id) >>> 0).toString(16).padStart(8, '0')}`;
      // The full-size ArkUI root and launch window already use page_background.
      this.mainWindow.setWindowSystemBarProperties({ statusBarColor: background, navigationBarColor: background,
        statusBarContentColor: foreground, navigationBarContentColor: foreground })
        .catch(() => { console.warn('System bar theme update failed.'); });
    } catch (_) { console.warn('Window theme resources are unavailable.'); }
  }
  onForeground(): void { AppStorage.setOrCreate('appForeground', true); }
  onBackground(): void { AppStorage.setOrCreate('appForeground', false); }
}
