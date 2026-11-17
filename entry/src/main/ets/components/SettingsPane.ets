import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AuthStore, authStore } from '../services/AuthStore';
import { OAuthConfigStore } from '../services/OAuthConfigStore';
import { OAuthFlowStore, oauthFlowStore } from '../services/OAuthFlowStore';
import { OAUTH_REDIRECT_URI, WhatsAppOAuth } from '../services/WhatsAppOAuth';
import { Pkce } from '../services/Pkce';
import { passkeyBridge, passkeyBridgeStore, PasskeyBridgeConfig } from '../services/PasskeyBridge';
import { cdpBridge } from '../services/CdpBridge';
import { ServerConfig } from '../services/ServerConfig';
import { Avatar } from './Avatar';

/**
 * Settings — account, WhatsApp API (Client ID + OAuth 2.0 PKCE), linked
 * device, appearance, preferences and about.
 */
@Component
export struct SettingsPane {
  @Prop linked: boolean = false;
  @Prop phone: string = '';
  @Prop oauthConnected: boolean = false;
  @Prop accountName: string = '';
  @Prop appearanceMode: string = 'system';
  @Prop live: boolean = false;
  onLink: () => void = () => {
  };
  onWebLink: () => void = () => {
  };
  onLogout: () => void = () => {
  };
  onAppearance: (mode: string) => void = () => {
  };
  onSignedOut: () => void = () => {
  };

  @State clientId: string = '';
  @State saved: boolean = false;
  @State busy: boolean = false;
  @State errorText: string = '';
  @State engineHost: string = ServerConfig.BACKEND_HOST;
  @State enginePort: string = String(ServerConfig.BACKEND_PORT);
  @State engineToken: string = '';
  @State engineBusy: boolean = false;
  @State engineStatus: string = '';
  @State engineError: string = '';
  @State bridgeHost: string = '';
  @State bridgePort: string = '18771';
  @State bridgeToken: string = '';
  @State bridgeSaved: boolean = false;
  @State bridgeBusy: boolean = false;
  @State bridgeError: string = '';
  @StorageLink('whatisit.notifications') notifications: boolean = true;
  @StorageLink('whatisit.read_receipts') readReceipts: boolean = true;

  private configStore: OAuthConfigStore = new OAuthConfigStore();
  private flowStore: OAuthFlowStore = oauthFlowStore;
  private auth: AuthStore = authStore;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.clientId = this.configStore.load(ctx).clientId;
    this.saved = this.clientId.length > 0;
    const bridge: PasskeyBridgeConfig = passkeyBridgeStore.load(ctx);
    this.bridgeHost = bridge.host;
    this.bridgePort = String(bridge.port);
    this.bridgeToken = bridge.token;
    this.bridgeSaved = bridge.host.length > 0;
    passkeyBridge.configure(bridge);
    this.engineToken = cdpBridge.getEndpointToken();
    this.loadEngine();
    this.auth.load(ctx).then(() => {
      // The parent owns the connected state; this is only a best-effort prefill.
    });
  }

  private async loadEngine(): Promise<void> {
    const ep = await cdpBridge.readStoredEndpoint();
    if (ep !== null) {
      this.engineHost = ep.host;
      this.enginePort = String(ep.port);
      this.engineStatus = 'Stored engine address';
    }
  }

  private async saveEngine(): Promise<void> {
    const port = parseInt(this.enginePort, 10);
    if (this.engineHost.trim().length === 0) {
      this.engineError = 'Enter the host running server-go.';
      return;
    }
    if (!isFinite(port) || port <= 0 || port > 65535) {
      this.engineError = 'Enter a valid engine port (default 18770).';
      return;
    }
    this.engineBusy = true;
    this.engineError = '';
    this.engineStatus = 'Connecting…';
    try {
      const ok = await cdpBridge.setEndpoint(this.engineHost.trim(), port, this.engineToken.trim());
      this.engineStatus = ok ? 'Engine reachable' : 'Engine did not answer';
      if (!ok) {
        this.engineError = 'No /status response. Is server-go running and reachable from this phone?';
      } else {
        promptAction.showToast({ message: 'Live engine connected', duration: 1800 });
      }
    } catch (e) {
      this.engineStatus = 'Engine did not answer';
      this.engineError = 'Could not reach server-go.';
    } finally {
      this.engineBusy = false;
    }
  }

  private saveBridge(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const port = parseInt(this.bridgePort, 10);
    if (this.bridgeHost.trim().length === 0) {
      this.bridgeError = 'Enter the LAN address of the PC running the bridge.';
      return;
    }
    if (!isFinite(port) || port <= 0 || port > 65535) {
      this.bridgeError = 'Enter a valid port (default 18771).';
      return;
    }
    const cfg = new PasskeyBridgeConfig();
    cfg.host = this.bridgeHost.trim();
    cfg.port = port;
    cfg.token = this.bridgeToken.trim();
    const ok = passkeyBridgeStore.save(ctx, cfg);
    passkeyBridge.configure(cfg);
    this.bridgeSaved = ok;
    this.bridgeError = ok ? '' : 'Could not save the bridge settings.';
    promptAction.showToast({ message: ok ? 'Passkey bridge saved' : 'Could not save the bridge', duration: 1800 });
  }

  private async testBridge(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const port = parseInt(this.bridgePort, 10);
    if (this.bridgeHost.trim().length === 0 || !isFinite(port) || port <= 0) {
      this.bridgeError = 'Enter the bridge host and port first.';
      return;
    }
    const cfg = new PasskeyBridgeConfig();
    cfg.host = this.bridgeHost.trim();
    cfg.port = port;
    cfg.token = this.bridgeToken.trim();
    this.bridgeSaved = passkeyBridgeStore.save(ctx, cfg);
    passkeyBridge.configure(cfg);
    this.bridgeBusy = true;
    this.bridgeError = '';
    try {
      const ok = await passkeyBridge.health();
      this.bridgeError = ok ? '' : 'Bridge did not answer. Start bridge/agent.js on the PC.';
      if (ok) {
        promptAction.showToast({ message: 'Passkey bridge is reachable', duration: 1800 });
      }
    } catch (e) {
      this.bridgeError = 'Bridge did not answer. Start bridge/agent.js on the PC.';
    } finally {
      this.bridgeBusy = false;
    }
  }

  private saveClientId(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ok = this.configStore.save(ctx, this.clientId);
    this.saved = ok;
    promptAction.showToast({ message: ok ? 'Client ID saved' : 'Could not save the Client ID', duration: 1800 });
  }

  private async startOAuth(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.clientId = this.clientId.trim();
    if (this.clientId.length === 0) {
      this.errorText = 'Enter your WhatsApp app Client ID first.';
      return;
    }
    if (!this.configStore.save(ctx, this.clientId)) {
      this.errorText = 'Could not save the Client ID.';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const verifier = Pkce.newVerifier();
      const challenge = Pkce.challengeS256(verifier);
      const state = Pkce.newState();
      const url = WhatsAppOAuth.buildAuthorizeUrl(this.clientId, challenge, state);
      const saved = await this.flowStore.save(ctx, verifier, state, this.clientId);
      if (!saved) {
        this.errorText = 'Could not prepare the sign-in session.';
        this.busy = false;
        return;
      }
      await ctx.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      });
      promptAction.showToast({ message: 'Continue in your browser to authorize WhatsApp.', duration: 2200 });
      this.saved = true;
    } catch (e) {
      this.errorText = 'Could not open the system browser.';
    } finally {
      this.busy = false;
    }
  }

  private async signOut(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.auth.signOut(ctx);
    this.onSignedOut();
    promptAction.showToast({ message: 'Signed out of the WhatsApp API', duration: 1800 });
  }

  @Builder
  SectionLabel(text: string) {
    Text(text)
      .width('100%')
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.ink_faded'))
      .letterSpacing(0.7)
      .padding({ left: 20, right: 16, top: 14, bottom: 8 })
  }

  @Builder
  SettingRow(icon: Resource, title: string, subtitle: string, value: string, onTap: () => void) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 36, height: 36 })
          .fill($r('app.color.brand_soft'))
        SymbolGlyph(icon)
          .fontSize(18)
          .fontColor([$r('app.color.brand')])
      }
      .width(36)
      .height(36)

      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(12)
            .fontColor($r('app.color.ink_subtle'))
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (value.length > 0) {
        Text(value)
          .fontSize(12)
          .fontColor($r('app.color.ink_subtle'))
          .maxLines(1)
      }
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(15)
        .fontColor([$r('app.color.ink_faded')])
        .rotate({ angle: 180 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  ToggleRow(icon: Resource, title: string, subtitle: string, isOn: boolean, onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 36, height: 36 })
          .fill($r('app.color.brand_soft'))
        SymbolGlyph(icon)
          .fontSize(18)
          .fontColor([$r('app.color.brand')])
      }
      .width(36)
      .height(36)

      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.ink_subtle'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor($r('app.color.brand'))
        .onChange((on: boolean) => {
          onChange(on);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  @Builder
  AppearanceOption(label: string, key: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.appearanceMode === key ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.appearanceMode === key ? $r('app.color.brand') : $r('app.color.ink_subtle'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: 9, bottom: 9 })
      .backgroundColor(this.appearanceMode === key ? $r('app.color.brand_soft') : Color.Transparent)
      .borderRadius(16)
      .onClick(() => {
        this.onAppearance(key);
      })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // Profile card
        Row({ space: 14 }) {
          Avatar({ label: this.accountName.length > 0 ? this.accountName : 'You', seed: 'me', avatarSize: 58, online: this.linked })
          Column({ space: 3 }) {
            Text(this.accountName.length > 0 ? this.accountName : 'Your name')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
            Text(this.phone.length > 0 ? this.phone : 'No phone number linked')
              .fontSize(13)
              .fontColor($r('app.color.ink_subtle'))
            Text(this.linked ? 'Live account' : (this.live ? 'Web session' : 'Preview mode'))
              .fontSize(11)
              .fontColor(this.linked ? $r('app.color.connected') : $r('app.color.ink_faded'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(19)
            .fontColor([$r('app.color.ink_subtle')])
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16, top: 8 })

        this.SectionLabel('WHATSAPP API')
        Column({ space: 10 }) {
          Text('Client ID')
            .width('100%')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          TextInput({ text: this.clientId, placeholder: 'Your WhatsApp app Client ID' })
            .width('100%')
            .height(42)
            .fontSize(14)
            .fontColor($r('app.color.ink'))
            .placeholderColor($r('app.color.ink_faded'))
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(10)
            .onChange((value: string) => {
              this.clientId = value;
              this.errorText = '';
            })
          Text('OAuth 2.0 with PKCE · no client secret is stored on this device')
            .width('100%')
            .fontSize(11)
            .fontColor($r('app.color.ink_faded'))

          Row({ space: 8 }) {
            Button(this.saved ? 'Saved' : 'Save')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.surface'))
              .border({ width: 1, color: $r('app.color.brand') })
              .borderRadius(19)
              .onClick(() => {
                this.saveClientId();
              })
            Button(this.busy ? 'Opening…' : 'Connect WhatsApp')
              .layoutWeight(2)
              .height(38)
              .fontSize(13)
              .fontColor($r('app.color.brand_text'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(19)
              .enabled(!this.busy)
              .onClick(() => {
                this.startOAuth();
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Circle({ width: 7, height: 7 })
              .fill(this.oauthConnected ? $r('app.color.connected') : $r('app.color.ink_faded'))
            Text(this.oauthConnected ? 'API connected' : 'API not connected')
              .fontSize(12)
              .fontColor($r('app.color.ink_subtle'))
            Blank()
            Button('Authorize in browser')
              .height(28)
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.brand_soft'))
              .borderRadius(14)
              .onClick(() => {
                this.startOAuth();
              })
          }
          .width('100%')

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .width('100%')
              .fontSize(11)
              .fontColor($r('app.color.danger'))
          }
          Text('Callback URI: ' + OAUTH_REDIRECT_URI)
            .width('100%')
            .fontSize(10)
            .fontColor($r('app.color.ink_faded'))
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16 })

        this.SectionLabel('LINKED DEVICE')
        Column() {
          this.SettingRow($r('sys.symbol.phone'), 'Link a device',
            this.linked ? 'This device is linked' : 'Scan a QR code or use a phone number',
            this.linked ? 'Linked' : 'Preview', () => {
              this.onLink();
            })
          this.SettingRow($r('sys.symbol.rectangle_stack'), 'WhatsApp Web',
            'Open the real WhatsApp Web login without a backend', '', () => {
              this.onWebLink();
            })
          if (this.linked) {
            this.SettingRow($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'), 'Log out of this device',
              'End the linked session', '', () => {
                this.onLogout();
              })
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16 })

        this.SectionLabel('LIVE ENGINE')
        Column({ space: 10 }) {
          Text('Native Chats, Updates, Calls and Communities are driven by server-go. Run it on a PC or VPS, then enter its address here. Without it the app stays in Preview mode; WhatsApp Web is a separate browser session.')
            .width('100%')
            .fontSize(11)
            .fontColor($r('app.color.ink_subtle'))
          TextInput({ text: this.engineHost, placeholder: 'PC/VPS host, e.g. 192.168.1.20' })
            .width('100%')
            .height(40)
            .fontSize(13)
            .fontColor($r('app.color.ink'))
            .placeholderColor($r('app.color.ink_faded'))
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(10)
            .onChange((value: string) => {
              this.engineHost = value;
              this.engineError = '';
            })
          Row({ space: 8 }) {
            TextInput({ text: this.enginePort, placeholder: '18770' })
              .width(100)
              .height(40)
              .fontSize(13)
              .type(InputType.Number)
              .fontColor($r('app.color.ink'))
              .placeholderColor($r('app.color.ink_faded'))
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(10)
              .onChange((value: string) => {
                this.enginePort = value;
              })
            TextInput({ text: this.engineToken, placeholder: 'Bearer token (optional)' })
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .fontColor($r('app.color.ink'))
              .placeholderColor($r('app.color.ink_faded'))
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(10)
              .onChange((value: string) => {
                this.engineToken = value;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Button(this.engineBusy ? 'Connecting…' : 'Save & connect')
              .layoutWeight(2)
              .height(36)
              .fontSize(12)
              .fontColor($r('app.color.brand_text'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(18)
              .enabled(!this.engineBusy)
              .onClick(() => {
                this.saveEngine();
              })
            Button('Test')
              .layoutWeight(1)
              .height(36)
              .fontSize(12)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.surface'))
              .border({ width: 1, color: $r('app.color.brand') })
              .borderRadius(18)
              .enabled(!this.engineBusy)
              .onClick(() => {
                this.saveEngine();
              })
          }
          .width('100%')

          if (this.engineStatus.length > 0 || this.engineError.length > 0) {
            Row({ space: 6 }) {
              Circle({ width: 6, height: 6 })
                .fill(this.engineError.length === 0 ? $r('app.color.connected') : $r('app.color.danger'))
              Text(this.engineError.length > 0 ? this.engineError : this.engineStatus)
                .fontSize(11)
                .fontColor(this.engineError.length > 0 ? $r('app.color.danger') : $r('app.color.ink_subtle'))
                .layoutWeight(1)
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16 })

        this.SectionLabel('PASSKEY BRIDGE')
        Column({ space: 10 }) {
          Text('For WhatsApp accounts with a passkey. Run bridge/agent.js on the PC where Chrome can complete the passkey, then enter its LAN address here. The passkey stays in Chrome; the app only receives the assertion.')
            .width('100%')
            .fontSize(11)
            .fontColor($r('app.color.ink_subtle'))
          TextInput({ text: this.bridgeHost, placeholder: 'PC LAN address, e.g. 192.168.1.20' })
            .width('100%')
            .height(40)
            .fontSize(13)
            .fontColor($r('app.color.ink'))
            .placeholderColor($r('app.color.ink_faded'))
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(10)
            .onChange((value: string) => {
              this.bridgeHost = value;
              this.bridgeSaved = false;
              this.bridgeError = '';
            })
          Row({ space: 8 }) {
            TextInput({ text: this.bridgePort, placeholder: '18771' })
              .width(100)
              .height(40)
              .fontSize(13)
              .type(InputType.Number)
              .fontColor($r('app.color.ink'))
              .placeholderColor($r('app.color.ink_faded'))
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(10)
              .onChange((value: string) => {
                this.bridgePort = value;
                this.bridgeSaved = false;
              })
            TextInput({ text: this.bridgeToken, placeholder: 'Pairing token (from agent.js)' })
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .fontColor($r('app.color.ink'))
              .placeholderColor($r('app.color.ink_faded'))
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(10)
              .onChange((value: string) => {
                this.bridgeToken = value;
                this.bridgeSaved = false;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Button(this.bridgeSaved ? 'Saved' : 'Save')
              .layoutWeight(1)
              .height(36)
              .fontSize(12)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.surface'))
              .border({ width: 1, color: $r('app.color.brand') })
              .borderRadius(18)
              .onClick(() => {
                this.saveBridge();
              })
            Button(this.bridgeBusy ? 'Checking…' : 'Test bridge')
              .layoutWeight(1)
              .height(36)
              .fontSize(12)
              .fontColor($r('app.color.brand_text'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(18)
              .enabled(!this.bridgeBusy)
              .onClick(() => {
                this.testBridge();
              })
          }
          .width('100%')

          if (this.bridgeError.length > 0) {
            Text(this.bridgeError)
              .width('100%')
              .fontSize(11)
              .fontColor($r('app.color.danger'))
          }
          Text('Then open WhatsApp Web → Link with phone number. Complete the passkey prompt in Chrome on the PC.')
            .width('100%')
            .fontSize(10)
            .fontColor($r('app.color.ink_faded'))
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16 })

        this.SectionLabel('APPEARANCE')
        Column({ space: 8 }) {
          Row({ space: 4 }) {
            this.AppearanceOption('System', 'system')
            this.AppearanceOption('Light', 'light')
            this.AppearanceOption('Dark', 'dark')
          }
          .width('100%')
          .padding(3)
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(19)
          Text('Follows the system when set to System.')
            .fontSize(11)
            .fontColor($r('app.color.ink_faded'))
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16 })

        this.SectionLabel('PREFERENCES')
        Column() {
          this.ToggleRow($r('sys.symbol.circle'), 'Notifications', 'Message and call alerts', this.notifications,
            (on: boolean) => {
              this.notifications = on;
            })
          this.ToggleRow($r('sys.symbol.checkmark'), 'Read receipts', 'Let contacts know when you read', this.readReceipts,
            (on: boolean) => {
              this.readReceipts = on;
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16 })

        this.SectionLabel('ABOUT')
        Column() {
          this.SettingRow($r('sys.symbol.message'), 'WhatIsIt', 'Native WhatsApp client for HarmonyOS', '2.0.0', () => {
            promptAction.showToast({ message: 'WhatIsIt 2.0.0', duration: 1500 });
          })
          this.SettingRow($r('sys.symbol.person_2'), 'Communities', 'Groups, announcements and discoverability', '', () => {
            promptAction.showToast({ message: 'Sample communities are shown in the Communities tab.', duration: 1800 });
          })
          this.SettingRow($r('sys.symbol.checkmark'), 'Privacy', 'PKCE · no client secret stored on-device', '', () => {
            promptAction.showToast({ message: 'The Client ID is public; PKCE protects the exchange.', duration: 2200 });
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16 })

        if (this.oauthConnected) {
          Button('Sign out of WhatsApp API')
            .width('100%')
            .height(42)
            .fontSize(13)
            .fontColor($r('app.color.danger'))
            .backgroundColor($r('app.color.surface'))
            .border({ width: 1, color: $r('app.color.divider') })
            .borderRadius(21)
            .margin({ left: 16, right: 16, top: 4 })
            .onClick(() => {
              this.signOut();
            })
        }

        Blank().height(96)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}
