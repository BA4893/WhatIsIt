/**
 * WebLoginView — WhatsApp Web with a WebAuthn credential bridge.
 *
 * WhatsApp's passkey/SHORTCAKE gate requires a WebAuthn assertion for
 * `web.whatsapp.com`. ArkWeb can show the prompt but cannot complete it on
 * this device. This view injects a small shim at document start that intercepts
 * `navigator.credentials.get` and asks the PC bridge (Chrome, where the passkey
 * works) for the assertion. No server is involved; the bridge runs on the LAN.
 *
 * If the bridge is not configured, the shim falls back to ArkWeb's native
 * WebAuthn behaviour.
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { passkeyBridge, passkeyBridgeStore, PasskeyBridgeConfig } from '../services/PasskeyBridge';

const TAG = 'WebLogin';
const DOMAIN = 0x0000;

/** Desktop Chrome UA: WhatsApp Web does not serve its QR UI to unknown UAs. */
const DESKTOP_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/**
 * Runs before WhatsApp's scripts. It intercepts only public-key get requests;
 * conditionally-mediated and non-WebAuthn calls go to the native implementation.
 */
const PASSKEY_SHIM: string = `
(function () {
  if (window.__waPasskeyShimInstalled) return;
  window.__waPasskeyShimInstalled = true;

  function dec(s) {
    s = String(s).split('-').join('+').split('_').join('/');
    while (s.length % 4 !== 0) s += '=';
    var bin = atob(s);
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  }

  function enc(buf) {
    var bytes = new Uint8Array(buf);
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin).split('+').join('-').split('/').join('_').split('=').join('');
  }

  function serialize(pk) {
    var allow = [];
    var list = pk.allowCredentials || [];
    for (var i = 0; i < list.length; i++) {
      allow.push({ type: list[i].type, id: enc(list[i].id), transports: list[i].transports });
    }
    return {
      challenge: enc(pk.challenge),
      rpId: pk.rpId,
      timeout: pk.timeout,
      userVerification: pk.userVerification,
      allowCredentials: allow
    };
  }

  function makeResponse(a) {
    var r = {
      clientDataJSON: dec(a.response.clientDataJSON),
      authenticatorData: dec(a.response.authenticatorData),
      signature: dec(a.response.signature),
      userHandle: a.response.userHandle ? dec(a.response.userHandle) : null
    };
    r.getTransports = function () { return []; };
    try {
      if (window.AuthenticatorAssertionResponse) {
        Object.setPrototypeOf(r, AuthenticatorAssertionResponse.prototype);
      }
    } catch (e) { }
    return r;
  }

  function makeCredential(a) {
    var c = {
      id: a.id,
      rawId: dec(a.rawId),
      type: a.type || 'public-key',
      authenticatorAttachment: a.authenticatorAttachment || 'platform',
      response: makeResponse(a),
      getClientExtensionResults: function () { return {}; },
      toJSON: function () { return a; }
    };
    try {
      if (window.PublicKeyCredential) {
        Object.setPrototypeOf(c, PublicKeyCredential.prototype);
      }
    } catch (e) { }
    return c;
  }

  var container = navigator.credentials;
  if (!container) return;
  var target = (window.CredentialsContainer && CredentialsContainer.prototype) || container;
  var original = target.get;
  if (!original) {
    return;
  }
  console.log('[passkey-shim] installed');

  function intercept(options) {
    if (!options || !options.publicKey || options.mediation === 'conditional') {
      return original.call(this, options);
    }
    var bridge = window.__waPasskeyBridge;
    if (!bridge) {
      console.warn('[passkey-shim] bridge proxy not available');
      return original.call(this, options);
    }
    try {
      if (bridge.isConfigured && !bridge.isConfigured()) {
        console.warn('[passkey-shim] bridge is not configured');
        return original.call(this, options);
      }
    } catch (e) {
      return original.call(this, options);
    }
    console.log('[passkey-shim] requesting assertion from PC bridge');
    var request;
    try {
      request = serialize(options.publicKey);
    } catch (e) {
      return Promise.reject(new DOMException('Unsupported passkey request', 'NotSupportedError'));
    }
    return Promise.resolve(bridge.getAssertion(JSON.stringify(request)))
      .then(function (json) {
        return makeCredential(JSON.parse(json));
      })
      .catch(function (err) {
        var message = err && err.message ? err.message : String(err);
        throw new DOMException('Passkey bridge failed: ' + message, 'NotAllowedError');
      });
  }

  try {
    Object.defineProperty(target, 'get', {
      value: intercept, configurable: true, writable: true
    });
  } catch (e) {
    try {
      Object.defineProperty(container, 'get', {
        value: intercept, configurable: true, writable: true
      });
    } catch (e2) {
      try {
        container.get = intercept;
      } catch (e3) { }
    }
  }
})();
`;

/** Native object exposed to the page as window.__waPasskeyBridge. */
class PasskeyProxy {
  onBusy: (busy: boolean) => void = () => {
  };
  onError: (message: string) => void = () => {
  };

  isConfigured(): boolean {
    return passkeyBridge.isConfigured();
  }

  async getAssertion(optionsJson: string): Promise<string> {
    this.onBusy(true);
    try {
      const assertion = await passkeyBridge.assert(optionsJson);
      return assertion;
    } catch (e) {
      const message = (e as Error)?.message;
      const text = message !== undefined && message.length > 0
        ? message : 'Could not reach the passkey bridge.';
      this.onError(text);
      throw new Error(text);
    } finally {
      this.onBusy(false);
    }
  }
}

@Component
export struct WebLoginView {
  private controller: webview.WebviewController = new webview.WebviewController();
  private proxy: PasskeyProxy = new PasskeyProxy();
  @State passkeyBusy: boolean = false;
  @State passkeyError: string = '';
  @State bridgeConfigured: boolean = false;
  onClose: () => void = () => {
  };

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const cfg: PasskeyBridgeConfig = passkeyBridgeStore.load(ctx);
    passkeyBridge.configure(cfg);
    this.bridgeConfigured = cfg.host.trim().length > 0;
    this.proxy.onBusy = (busy: boolean) => {
      this.passkeyBusy = busy;
    };
    this.proxy.onError = (message: string) => {
      this.passkeyError = message;
    };
  }

  @Builder
  BridgeBanner() {
    if (this.passkeyBusy) {
      Row({ space: 8 }) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color($r('app.color.brand'))
        Text('Passkey verification on your computer…')
          .fontSize(12)
          .fontColor($r('app.color.ink'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.brand_soft'))
    } else if (this.passkeyError.length > 0) {
      Row({ space: 8 }) {
        Text(this.passkeyError)
          .fontSize(11)
          .fontColor($r('app.color.danger'))
          .layoutWeight(1)
        Text('Retry')
          .fontSize(11)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            this.passkeyError = '';
            this.controller.refresh();
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor('#FFF4F4')
    } else if (!this.bridgeConfigured) {
      Row({ space: 6 }) {
        Text('Passkey bridge not configured. Settings → Passkey bridge.')
          .fontSize(10)
          .fontColor($r('app.color.ink_subtle'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.surface_subtle'))
    }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([$r('app.color.ink')])
          .onClick(() => {
            this.onClose();
          })
        Text('WhatsApp Web')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
        Blank()
        Circle({ width: 6, height: 6 })
          .fill(this.bridgeConfigured ? $r('app.color.connected') : $r('app.color.ink_faded'))
        Text('Refresh')
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            try {
              this.controller.refresh();
            } catch (e) {
              hilog.warn(DOMAIN, TAG, 'refresh failed: %{public}s', JSON.stringify(e));
            }
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.surface'))

      this.BridgeBanner()

      Web({ src: 'https://web.whatsapp.com', controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .userAgent(DESKTOP_UA)
        .javaScriptProxy({
          object: this.proxy,
          name: '__waPasskeyBridge',
          methodList: ['isConfigured'],
          asyncMethodList: ['getAssertion'],
          controller: this.controller
        })
        .javaScriptOnDocumentStart([
          {
            script: PASSKEY_SHIM,
            scriptRules: ['https://web.whatsapp.com', 'https://web.whatsapp.com/*']
          }
        ])
        .onConsole((event) => {
          hilog.info(DOMAIN, TAG, 'console: %{public}s', event.message.getMessage());
          return false;
        })
        .onPageEnd((event) => {
          hilog.info(DOMAIN, TAG, 'page end: %{public}s', event.url);
        })
        .onErrorReceive((event) => {
          hilog.warn(DOMAIN, TAG, 'web error: %{public}s', JSON.stringify(event.error));
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
