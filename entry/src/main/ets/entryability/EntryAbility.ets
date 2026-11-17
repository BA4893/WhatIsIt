import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { AppearanceStore } from '../services/AppearanceStore';
import { ResponsiveLayout } from '../services/ResponsiveLayout';
import { oauthFlowStore } from '../services/OAuthFlowStore';
import { OAUTH_REDIRECT_URI } from '../services/WhatsAppOAuth';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';
const BREAKPOINT_KEY: string = 'whatisit.breakpoint';

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | null = null;
  private callbackUri: string = '';
  private appearance: AppearanceStore = new AppearanceStore();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    const mode = this.appearance.load(this.context);
    try {
      this.context.getApplicationContext().setColorMode(this.appearance.colorMode(mode));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(e));
    }
    try {
      webview.WebviewController.setUserAgentClientHintsEnabled(false);
      webview.WebviewController.initializeWebEngine();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'ArkWeb init failed: %{public}s', JSON.stringify(e));
    }
    AppStorage.setOrCreate<string>(BREAKPOINT_KEY, ResponsiveLayout.BREAKPOINT_SM);
    AppStorage.setOrCreate<boolean>('whatisit.notifications', true);
    AppStorage.setOrCreate<boolean>('whatisit.read_receipts', true);
    this.readCallback(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.callbackUri = '';
    this.readCallback(want);
    if (this.callbackUri.length > 0 && this.windowStage !== null) {
      this.openCallback(this.windowStage, this.callbackUri);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    if (this.callbackUri.length > 0) {
      this.openCallback(windowStage, this.callbackUri);
      return;
    }
    windowStage.loadContent('pages/HybridShell', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'load HybridShell failed: %{public}s', JSON.stringify(err));
        return;
      }
      this.observeWindow(windowStage);
    });
  }

  private async openCallback(windowStage: window.WindowStage, uri: string): Promise<void> {
    const saved = await oauthFlowStore.saveCallback(this.context, uri);
    if (!saved) {
      hilog.error(DOMAIN, TAG, 'could not save OAuth callback');
    }
    windowStage.loadContent('pages/OAuthCallback', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'load OAuthCallback failed: %{public}s', JSON.stringify(err));
        return;
      }
      this.observeWindow(windowStage);
    });
  }

  private readCallback(want: Want): void {
    const uri = want.uri === undefined ? '' : want.uri;
    if (uri.startsWith(OAUTH_REDIRECT_URI)) {
      this.callbackUri = uri;
      hilog.info(DOMAIN, TAG, 'OAuth callback received');
    }
  }

  private observeWindow(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      const uiContext = mainWindow.getUIContext();
      const width = uiContext.px2vp(mainWindow.getWindowProperties().windowRect.width);
      AppStorage.setOrCreate<string>(BREAKPOINT_KEY, ResponsiveLayout.breakpointForWidth(width));
      mainWindow.on('windowSizeChange', (size: window.Size) => {
        const widthVp = uiContext.px2vp(size.width);
        AppStorage.setOrCreate<string>(BREAKPOINT_KEY, ResponsiveLayout.breakpointForWidth(widthVp));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'observeWindow failed: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    this.windowStage = null;
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
