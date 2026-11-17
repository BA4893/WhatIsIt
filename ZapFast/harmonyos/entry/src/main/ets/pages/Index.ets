import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x5A46;
const TAG = 'ZapFastArk';

/** The native host's functions, mounted on the XComponent's onLoad context. */
interface ZapFastNative {
  start(filesDir: string, cacheDir: string, density: number, demo?: boolean): void;
  stop(): void;
  setDensity(density: number): void;
  text(text: string): void;
  paste(text: string): void;
  takeClipboard(): string | undefined;
  takeOpenUrl(): string | undefined;
  textInputWanted(): boolean;
  showSoftKeyboard(wanted: boolean): void;
  version(): string;
  pause(): void;
  resume(): void;
  focus(focused: boolean): void;
  mouse(action: number, button: number, x: number, y: number): void;
  axis(horizontal: number, vertical: number, scrollStep: number,
       mouse: boolean): void;
}

/**
 * ZapFast's window: one XComponent the Rust host draws into.
 *
 * The native library is the XComponent's `libraryname`, so it is loaded for
 * the component and its module init receives the native XComponent handle.
 * That is where it registers the surface and input callbacks. ArkTS reaches
 * the same module through the `onLoad` context the component hands over
 * (a separate `import` would load the module before the component exists and
 * leave the callbacks unattached). It forwards only what the native side
 * cannot see: the text a keyboard or input method commits, pasted clipboard
 * text, and the lifecycle and clipboard polls. The interface itself is
 * egui's, the same one the desktop draws.
 */
@Entry
@Component
struct Index {
  private controller: XComponentController = new XComponentController();
  private native?: ZapFastNative = undefined;
  private context?: common.UIAbilityContext = undefined;
  private poll: number = -1;
  private softKeyboardWanted: boolean = false;
  private clipboardBusy: boolean = false;
  @State private focused: boolean = true;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // Polls the small bridge: copied text, links to open, and whether a text
    // field wants the soft keyboard. The frame loop itself is native.
    this.poll = setInterval(() => this.tick(), 250);
  }

  aboutToDisappear(): void {
    if (this.poll >= 0) {
      clearInterval(this.poll);
      this.poll = -1;
    }
    try {
      this.native?.stop();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'native stop failed: %{public}s', JSON.stringify(error));
    }
    this.native = undefined;
  }

  onPageShow(): void {
    try {
      this.native?.resume();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'resume failed: %{public}s', JSON.stringify(error));
    }
  }

  onPageHide(): void {
    try {
      this.native?.pause();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'pause failed: %{public}s', JSON.stringify(error));
    }
  }

  private density(): number {
    try {
      const density = display.getDefaultDisplaySync().densityPixels;
      return density > 0 ? density : 1.0;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'display density unavailable: %{public}s', JSON.stringify(error));
      return 1.0;
    }
  }

  /** The surface is ready: the module is loaded and its callbacks are up. */
  private attach(context: object): void {
    const native = context as ZapFastNative;
    this.native = native;
    const density = this.density();
    try {
      native.start(this.context!.filesDir, this.context!.cacheDir, density, false);
      hilog.info(DOMAIN, TAG, 'ZapFast host starting at %{public}f density', density);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'native start failed: %{public}s', JSON.stringify(error));
    }
  }

  private tick(): void {
    const native = this.native;
    if (native === undefined) {
      return;
    }
    try {
      native.setDensity(this.density());
      this.pollClipboard(native);
      this.pollOpenUrl(native);
      const wanted = native.textInputWanted();
      if (wanted !== this.softKeyboardWanted) {
        this.softKeyboardWanted = wanted;
        native.showSoftKeyboard(wanted);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'bridge poll failed: %{public}s', JSON.stringify(error));
    }
  }

  private pollClipboard(native: ZapFastNative): void {
    const text = native.takeClipboard();
    if (text === undefined || text.length === 0 || this.clipboardBusy) {
      return;
    }
    this.clipboardBusy = true;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.clipboardBusy = false;
      }).catch((error: BusinessError) => {
        this.clipboardBusy = false;
        hilog.warn(DOMAIN, TAG, 'pasteboard write failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      this.clipboardBusy = false;
      hilog.warn(DOMAIN, TAG, 'pasteboard write threw: %{public}s', JSON.stringify(error));
    }
  }

  private pollOpenUrl(native: ZapFastNative): void {
    const url = native.takeOpenUrl();
    if (url === undefined || url.length === 0 || this.context === undefined) {
      return;
    }
    try {
      this.context.openLink(url).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'openLink failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'openLink threw: %{public}s', JSON.stringify(error));
    }
  }

  /** Reads the pasteboard for a paste gesture and hands it to egui. */
  private readClipboard(native: ZapFastNative): void {
    try {
      pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
        const text = data.getPrimaryText();
        if (text !== undefined && text.length > 0) {
          native.paste(text);
        }
      }).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'pasteboard read failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'pasteboard read threw: %{public}s', JSON.stringify(error));
    }
  }

  build() {
    Stack() {
      XComponent({
        id: 'zapfast-surface',
        type: XComponentType.SURFACE,
        libraryname: 'zapfastohos',
        controller: this.controller
      })
        .width('100%')
        .height('100%')
        .backgroundColor('#0B141A')
        .focusable(true)
        .focusOnTouch(true)
        .defaultFocus(true)
        .hitTestBehavior(HitTestMode.Block)
        .onLoad((context: object) => {
          this.attach(context);
        })
        .onFocus(() => {
          this.focused = true;
          this.native?.focus(true);
        })
        .onBlur(() => {
          this.focused = false;
          this.native?.focus(false);
        })
        .onKeyEvent((event: KeyEvent) => {
          const native = this.native;
          if (native === undefined || event.type !== KeyType.Down) {
            return false;
          }
          const ctrl = event.getModifierKeyState !== undefined
            ? event.getModifierKeyState(['Ctrl'])
            : false;
          // Ctrl+V is the integration's job on the desktop; here the
          // pasteboard belongs to ArkTS, so the text is read and handed over.
          if (ctrl && event.keyCode === 2038) {
            this.readClipboard(native);
            return false;
          }
          // The native key callback already reports the key press and the
          // shortcuts; this adds the character the keyboard committed. IME
          // composition arrives as `unicode` where the platform provides it.
          if (event.unicode !== undefined && event.unicode > 0) {
            if (event.unicode <= 0xFFFF) {
              native.text(String.fromCharCode(event.unicode));
            } else {
              native.text(String.fromCodePoint(event.unicode));
            }
          } else if (event.keyText !== undefined && event.keyText.length > 0 &&
                     event.keyText !== '\n' && event.keyText !== '\r' &&
                     event.keyText !== '\t') {
            native.text(event.keyText);
          }
          return false;
        })
        .onAreaChange(() => {
          this.native?.setDensity(this.density());
        })
      // The native XComponent does not receive mouse events on this PC, but a
      // plain ArkUI node above it does. It is transparent and forwards every
      // mouse action in vp to the same egui input path.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Block)
        .focusable(false)
        .onMouse((event: MouseEvent) => {
          const action = event.action === MouseAction.Press ? 0
            : event.action === MouseAction.Release ? 1
            : event.action === MouseAction.Move ? 2
            : event.action === MouseAction.Hover ? 3
            : 4;
          if (action === 4) {
            return;
          }
          const button = event.button === MouseButton.Right ? 1
            : event.button === MouseButton.Middle ? 2
            : event.button === MouseButton.Back ? 3
            : event.button === MouseButton.Forward ? 4
            : 0;
          this.native?.mouse(action, button, event.x, event.y);
        })
        .onAxisEvent((event: AxisEvent) => {
          // Two-finger touchpad swipes and the mouse wheel both arrive here.
          if (event.action !== AxisAction.BEGIN &&
              event.action !== AxisAction.UPDATE) {
            return;
          }
          this.native?.axis(
            event.getHorizontalAxisValue(),
            event.getVerticalAxisValue(),
            event.scrollStep ?? 0,
            event.sourceTool === SourceTool.MOUSE);
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B141A')
  }
}
