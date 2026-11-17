import { common, continuationManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { curves } from '@kit.ArkUI';
import { cdpBridge, BackendEvent } from '../services/CdpBridge';
import { passkeyService, PasskeyState } from '../services/PasskeyService';
import { e2ee } from '../services/E2eeService';
import { localNotifications } from '../services/LocalNotifications';
import { AppLifecycle } from '../services/AppLifecycle';
import { securityBootBarrier } from '../services/SecurityBootBarrier';
import { ChatListView } from './ChatListView';
import { ChatThreadView } from './ChatThreadView';
import { NewChatView } from './NewChatView';
import { ChannelDirectoryView } from './ChannelDirectoryView';
import { StatusComposerView } from './StatusComposerView';
import { ContactPickerService } from '../services/ContactPickerService';
import { ServerConfig } from '../services/ServerConfig';
import { callService } from '../services/CallService';
import { CallSurfaceView } from './CallSurfaceView';
import { WebLoginView } from './WebLoginView';

const TAG = 'MainPage';
const DOMAIN = 0x0000;

type ShellView = 'connect' | 'chats' | 'thread' | 'newchat' | 'channels' | 'statuscomposer' | 'web';

@Entry
@Component
struct MainPage {
  @State view: ShellView = 'connect';
  @State chatName: string = '';
  @State qr: string = '';
  @State connecting: boolean = false;
  @State errorMsg: string = '';
  @State showPhoneLink: boolean = false;
  @State phoneCountry: string = '1';
  @State phoneNumber: string = '';
  @State pairCodeText: string = '';
  @State pairBusy: boolean = false;
  @State pairError: string = '';
  @State passkeyOptions: string = '';
  @State passkeyPending: boolean = false;
  @State passkeyCode: string = '';
  @State passkeyError: string = '';
  @State assertionInput: string = '';
  @State passkeyBusy: boolean = false;
  @State securityBlocked: boolean = false;
  @State incomingCallId: string = '';
  @State incomingFrom: string = '';
  @State incomingVideo: boolean = false;
  @State activeCallId: string = '';
  @State activeCallName: string = '';
  @State activeCallVideo: boolean = false;
  @State activeCallSurface: boolean = false;
  @State connectionError: string = '';
  private store: preferences.Preferences | null = null;
  private qrTimer: number | null = null;
  private statusFailures: number = 0;
  private booted: boolean = false;

  aboutToAppear(): void {
    // BOOT BARRIER: verify hardware integrity BEFORE any session/UI init.
    // On a rooted / re-signed / emulated device this wipes the local
    // credential store and shows the blocking screen instead of chats.
    this.runSecurityGate();
  }

  private runSecurityGate(): void {
    securityBootBarrier.runGate().then((ok: boolean) => {
      if (!ok) {
        this.securityBlocked = true;
        hilog.warn(DOMAIN, TAG, 'security gate failed — app blocked');
        return;
      }
      this.initApp();
    });
  }

  private initApp(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    e2ee.init(ctx);
    localNotifications.init(ctx);
    localNotifications.requestPermission();
    localNotifications.clearBadge();
    cdpBridge.setUIContext(ctx);
    // Mark booted before the async prefs read so onPageShow() cannot race in
    // and start a second discovery/pairing pass against an uninitialised store.
    this.booted = true;
    preferences.getPreferences(ctx, 'whatisit_cdp').then((store) => {
      this.store = store;
      // App Continuation resume: if we were handed off into a chat, open it.
      const resumeChat = store.getSync('current_chat', '') as string;
      const resumeView = store.getSync('current_view', '') as string;
      if (resumeView === 'thread' && resumeChat.length > 0) {
        this.chatName = resumeChat;
        this.view = 'thread';
        this.autoReconnect();
        return;
      }
      // Provisioning deep-link: if the app was opened via a provisioning QR,
      // auto-apply the backend URL and connect.
      const pending = store.getSync('provision_pending', '') as string;
      if (pending === 'true') {
        const provHost = store.getSync('provision_host', '') as string;
        const provPortRaw = store.getSync('provision_port', '') as string;
        const provPort = parseInt(provPortRaw, 10);
        store.put('provision_pending', 'false').catch(() => {});
        if (provHost.length > 0 && isFinite(provPort) && provPort > 0) {
          this.applyProvisioning(provHost, provPort);
          return;
        }
      }
      // Silently re-attach on return: resume chats instead of forcing a step.
      this.autoReconnect();
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'load prefs failed: %{public}s', JSON.stringify(err));
      this.autoReconnect();
    });
    // Live events: QR updates + linked + pair code.
    cdpBridge.addEventListener((evt: BackendEvent) => {
      if (evt.type === 'qr' && evt.qr !== undefined) {
        this.qr = evt.qr;
        this.connectionError = '';
      } else if (evt.type === 'status') {
        // Sent by the server on every WS (re)connect. A server that reports
        // not-linked means the session is gone (server reset/logout/relink),
        // so drop back to the connect screen and follow the fresh QR.
        if (evt.linked === true) {
          this.qr = '';
          this.view = 'chats';
          this.connectionError = '';
          this.stopQrPoll();
        } else if (evt.qr !== undefined && evt.qr.length > 0) {
          this.qr = evt.qr;
          this.view = 'connect';
          this.connectionError = '';
          this.startQrPoll();
        } else {
          // Unlinked with no QR yet: make sure a pairing stream is running.
          this.qr = '';
          this.view = 'connect';
          this.startQrPoll();
          this.restartPairing();
        }
      } else if (evt.type === 'linked') {
        this.qr = '';
        this.view = 'chats';
        this.connectionError = '';
        this.stopQrPoll();
        localNotifications.start();
        if (this.store !== null) {
          this.store.put('was_linked', true).catch(() => {});
        }
      } else if (evt.type === 'logged_out') {
        this.qr = '';
        this.view = 'connect';
        this.connectionError = '';
        this.stopQrPoll();
        this.restartPairing();
      } else if (evt.type === 'pair_code' && evt.code !== undefined) {
        this.pairCodeText = evt.code;
        this.pairBusy = false;
      } else if (evt.type === 'incoming_call') {
        this.onIncomingCall(evt);
      } else if (evt.type === 'call_state') {
        this.onCallState(evt);
      }
    });
    // Passkey (SHORTCAKE) verification during linking.
    passkeyService.bind();
    passkeyService.addListener((s: PasskeyState) => {
      this.passkeyOptions = s.requestOptionsJson;
      this.passkeyPending = s.pending;
      this.passkeyCode = s.verificationCode;
      this.passkeyError = s.error;
    });
    // Start the embedded engine last, after every listener is registered, so
    // an immediate qr/linked event cannot be dropped. Without libwa_engine.so
    // this is a harmless no-op and the HTTP backend is used.
    cdpBridge.startEngine(`${ctx.filesDir}/wa`);
  }

  aboutToDisappear(): void {
    this.stopQrPoll();
  }

  /** App came to foreground — resume polling. */
  onPageShow(): void {
    AppLifecycle.setForeground(true);
    if (!this.booted) {
      return;
    }
    this.autoReconnect();
  }

  /** App went to background — pause polling. */
  onPageHide(): void {
    AppLifecycle.setForeground(false);
    localNotifications.stop();
  }

  private stopQrPoll(): void {
    if (this.qrTimer !== null) {
      clearInterval(this.qrTimer);
      this.qrTimer = null;
    }
  }

  private startQrPoll(): void {
    this.stopQrPoll();
    // Poll /status every 3s while on the connect screen: the server's QR
    // rotates (first 60s, then 20s) and WS may not be connected yet.
    this.qrTimer = setInterval(() => {
      if (AppLifecycle.isForeground()) {
        this.pollStatus();
      }
    }, 3000);
  }

  private async pollStatus(): Promise<void> {
    const st = await cdpBridge.getStatus();
    if (st === null) {
      this.statusFailures++;
      if (this.statusFailures >= 2) {
        this.connectionError = this.connectionErrorText();
      }
      return;
    }
    this.statusFailures = 0;
    this.connectionError = '';
    if (st.linked) {
      this.qr = '';
      this.view = 'chats';
      this.stopQrPoll();
    } else if (st.qr.length > 0) {
      this.qr = st.qr;
    }
  }

  /** Try to silently re-attach to the backend; resume chats if linked. */
  private async autoReconnect(): Promise<void> {
    if (this.view !== 'connect') {
      return;
    }
    // No native engine and no configured server: go straight to the real
    // WhatsApp Web login (QR / phone-number linking) instead of showing an
    // unreachable 127.0.0.1 backend. A local server on a 2in1 dev box is still
    // detected by the short loopback probe.
    if (!cdpBridge.hasNativeEngine()) {
      const stored = await cdpBridge.readStoredEndpoint();
      const configured = stored !== null ? stored.host : ServerConfig.BACKEND_HOST;
      const loopback = configured === '127.0.0.1' || configured === 'localhost';
      if (loopback && !(await cdpBridge.probeLocal())) {
        this.enterWebMode();
        return;
      }
    }
    await cdpBridge.discoverBackend();
    cdpBridge.openWs();
    const linked = await cdpBridge.isLinked();
    if (linked) {
      this.view = 'chats';
      this.connectionError = '';
      if (this.store !== null) {
        this.store.put('was_linked', true).catch(() => {});
      }
      return;
    }
    // Not linked — start QR pairing and watch for the code.
    const ok = await cdpBridge.startPair();
    if (!ok) {
      // No native backend available: use the real WhatsApp Web login.
      this.enterWebMode();
      return;
    }
    this.startQrPoll();
    this.pollStatus();
  }

  /** WhatsApp Web fallback: no backend host/port/token is needed. */
  private enterWebMode(): void {
    this.stopQrPoll();
    this.connectionError = '';
    this.pairError = '';
    this.view = 'web';
  }

  private async connect(): Promise<void> {
    this.connecting = true;
    this.errorMsg = '';
    this.connectionError = '';
    this.statusFailures = 0;
    await cdpBridge.discoverBackend();
    cdpBridge.openWs();
    const linked = await cdpBridge.isLinked();
    this.connecting = false;
    if (linked) {
      this.view = 'chats';
      localNotifications.start();
    } else {
      const ok = await cdpBridge.startPair();
      if (!ok) {
        this.enterWebMode();
        return;
      }
      this.startQrPoll();
      this.pollStatus();
    }
  }

  /** Apply provisioning data from a scanned QR or deep link. */
  private async applyProvisioning(host: string, port: number): Promise<void> {
    this.errorMsg = '';
    const ok = await cdpBridge.provisionBackend(host, port);
    if (ok) {
        await this.startPairAfterEndpoint();
    } else {
      this.errorMsg = 'Provisioning failed. Check the backend URL and try again.';
    }
  }

  /** Start pairing after an endpoint change and keep the UI honest. */
  private async startPairAfterEndpoint(): Promise<void> {
    const ok = await cdpBridge.startPair();
    if (!ok) {
      this.connectionError = this.connectionErrorText();
    } else {
      this.connectionError = '';
    }
    this.startQrPoll();
    this.pollStatus();
  }

  /** Best-effort pairing restart after a logged_out / WS status event. */
  private async restartPairing(): Promise<void> {
    const ok = await cdpBridge.startPair();
    if (!ok) {
      this.enterWebMode();
      return;
    }
    this.connectionError = '';
    this.startQrPoll();
    this.pollStatus();
  }

  /** Human-readable reachability error (no IP/server details in the UI). */
  private connectionErrorText(): string {
    return 'Native WhatsApp backend unavailable. Tap Retry, or continue with WhatsApp Web.';
  }

  /** Real logout: clear the server session, then present a fresh QR. */
  private async logoutAndReset(): Promise<void> {
    await cdpBridge.logout();
    this.qr = '';
    this.pairCodeText = '';
    this.view = 'connect';
    this.stopQrPoll();
    await this.restartPairing();
  }

  private openThread(name: string): void {
    this.chatName = name;
    if (this.store !== null) {
      this.store.put('current_chat', name).catch(() => {});
      this.store.put('current_view', 'thread').catch(() => {});
    }
    this.animatedSetView('thread');
  }

  /** Request an 8-char code for the phone-number linking flow. */
  private async startPhonePair(): Promise<void> {
    if (this.pairBusy) {
      return;
    }
    this.pairBusy = true;
    this.pairError = '';
    this.pairCodeText = '';
    const country = this.phoneCountry.replace(/[^0-9]/g, '').replace(/^0+/, '');
    let national = this.phoneNumber.replace(/[^0-9]/g, '');
    // whatsmeow rejects numbers starting with 0 (national trunk prefix) and
    // the server concatenates country+phone, so normalise here:
    //  - drop a leading 0 ("07700…" -> "7700…")
    //  - if the user pasted the country code into the number box, remove it
    national = national.replace(/^0+/, '');
    if (country.length > 0 && national.startsWith(country) && national.length > country.length + 6) {
      national = national.substring(country.length);
    }
    if (country.length === 0 || national.length < 7) {
      this.pairError = 'Enter a country code and a national number (no leading 0).';
      this.pairBusy = false;
      return;
    }
    let code = '';
    try {
      code = await cdpBridge.pairCode(country, national);
    } catch (err) {
      const msg = (err as Error)?.message;
      if (msg === 'network error') {
        this.pairError = 'Couldn\'t reach WhatsApp. Check your connection and try again.';
      } else {
        this.pairError = msg !== undefined && msg.length > 0
          ? msg
          : 'Failed to request code. Check your connection and try again.';
      }
      this.pairBusy = false;
      return;
    }
    if (code.length > 0) {
      // The 8-char code came straight back from the HTTP response.
      this.pairCodeText = code;
      this.pairBusy = false;
      return;
    }
    // Safety timeout: if no pair_code event arrives within 30s, unstick the UI.
    setTimeout(() => {
      if (this.pairBusy && this.pairCodeText.length === 0) {
        this.pairError = 'No code received — check your connection and try again.';
        this.pairBusy = false;
      }
    }, 30000);
  }

  /**
   * Submit a pasted WebAuthn assertion JSON. The user obtains this from a real
   * authenticator (this SDK has no native WebAuthn API yet); on-device
   * passkeys will replace this once @kit ships Credential Manager.
   */
  private async submitPasskeyAssertion(): Promise<void> {
    const raw = this.assertionInput.trim();
    if (raw.length === 0) {
      this.passkeyError = 'Paste the WebAuthn assertion JSON first.';
      return;
    }
    this.passkeyBusy = true;
    this.passkeyError = '';
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (e) {
      this.passkeyBusy = false;
      this.passkeyError = 'The pasted text is not valid JSON.';
      return;
    }
    // Build the base64url payloads from the WebAuthn PublicKeyCredential shape.
    const rawId = parsed['rawId'];
    const credentialId = typeof rawId === 'string' ? (rawId as string) : this.extractCredentialId(parsed);
    const ok = await passkeyService.submitAssertion(cdpBridge.b64UrlFromBytes(this.strToBytes(raw)),
      credentialId.length > 0 ? credentialId : '');
    this.passkeyBusy = false;
    if (!ok) {
      this.passkeyError = this.passkeyError.length > 0 ? this.passkeyError : 'Server rejected the assertion.';
    }
  }

  /** rawId may already be base64url in the JSON; normalize if present. */
  private extractCredentialId(parsed: Record<string, Object>): string {
    const id = parsed['id'];
    if (typeof id === 'string') {
      return id as string;
    }
    return '';
  }

  private async confirmPasskey(): Promise<void> {
    this.passkeyBusy = true;
    const ok = await passkeyService.confirm();
    this.passkeyBusy = false;
    if (!ok) {
      this.passkeyError = 'Could not confirm. Check the server, then retry.';
    }
  }

  private async cancelPasskey(): Promise<void> {
    await passkeyService.cancel();
    this.assertionInput = '';
  }

  private async refreshPasskey(): Promise<void> {
    await passkeyService.refresh();
  }

  /** ASCII/UTF-8 string → bytes (ArkTS has no TextEncoder). */
  private strToBytes(s: string): Uint8Array {
    const buf = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      buf[i] = s.charCodeAt(i) & 0xFF;
    }
    return buf;
  }

  private backToChats(): void {
    if (this.store !== null) {
      this.store.put('current_view', 'chats').catch(() => {});
    }
    this.animatedSetView('chats');
  }

  /** WhatsApp-native call arrives (from the server's incoming_call event). */
  private onIncomingCall(evt: BackendEvent): void {
    // Already in a call — ignore further incoming calls.
    if (this.activeCallSurface) {
      return;
    }
    const callId = evt.callId !== undefined ? evt.callId : '';
    if (callId.length === 0) {
      return;
    }
    this.incomingCallId = callId;
    this.incomingFrom = evt.from !== undefined ? evt.from : '';
    this.incomingVideo = evt.video === true;
    hilog.info(DOMAIN, TAG, 'incoming call %{public}s from %{public}s video=%{public}s',
      callId, this.incomingFrom, this.incomingVideo);
  }

  /** Call lifecycle pushes: dismiss the prompt / close the surface on end. */
  private onCallState(evt: BackendEvent): void {
    const callId = evt.callId !== undefined ? evt.callId : '';
    const state = evt.state !== undefined ? evt.state : '';
    if (callId.length === 0) {
      return;
    }
    if (state.startsWith('ended') || state === 'rejected' || state === 'missed') {
      if (this.incomingCallId === callId) {
        this.incomingCallId = '';
        this.incomingFrom = '';
      }
      if (this.activeCallId === callId) {
        this.activeCallId = '';
        this.activeCallSurface = false;
      }
    }
  }

  /** Answer the ringing call: open the native call surface. */
  private async acceptIncomingCall(): Promise<void> {
    const callId = this.incomingCallId;
    const from = this.incomingFrom;
    const video = this.incomingVideo;
    if (callId.length === 0) {
      return;
    }
    const ok = await callService.acceptCall(callId, video);
    this.incomingCallId = '';
    this.incomingFrom = '';
    if (!ok) {
      hilog.warn(DOMAIN, TAG, 'accept call %{public}s failed', callId);
      return;
    }
    this.activeCallId = callId;
    this.activeCallName = from;
    this.activeCallVideo = video;
    this.activeCallSurface = true;
  }

  /** Decline the ringing call (the caller hears the busy tone). */
  private async declineIncomingCall(): Promise<void> {
    const callId = this.incomingCallId;
    this.incomingCallId = '';
    this.incomingFrom = '';
    if (callId.length > 0) {
      await callService.rejectCall(callId);
    }
  }

  /** The active call surface's end button → tear down everything. */
  private closeActiveCallSurface(): void {
    callService.endCall();
    this.activeCallId = '';
    this.activeCallSurface = false;
  }

  /** Animate view switches with an elegant spring curve. */
  private animatedSetView(v: ShellView): void {
    this.getUIContext().animateTo({
      duration: 260,
      curve: curves.springMotion(0.35, 0.85),
    }, () => {
      this.view = v;
    });
  }

  /** Connect screen: simple fade. */
  private connectTransition(): TransitionEffect {
    return TransitionEffect.OPACITY;
  }

  /** Chats list: light rise + fade (tab-like). */
  private chatsTransition(): TransitionEffect {
    return TransitionEffect.translate({ y: 24 }).combine(TransitionEffect.OPACITY);
  }

  /** Thread: iOS-style push-in from the right. */
  private threadTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: '30%' }).combine(TransitionEffect.OPACITY),
      TransitionEffect.translate({ x: '100%' }).combine(TransitionEffect.OPACITY)
    );
  }

  /** New Chat sheet: full slide-in from the right. */
  private newchatTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: '100%' }).combine(TransitionEffect.OPACITY),
      TransitionEffect.translate({ x: '100%' }).combine(TransitionEffect.OPACITY)
    );
  }

  /** Channel directory: iOS-style push-in from the right. */
  private channelsTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: '30%' }).combine(TransitionEffect.OPACITY),
      TransitionEffect.translate({ x: '100%' }).combine(TransitionEffect.OPACITY)
    );
  }

  /** Status composer: bottom-sheet-style rise. */
  private composerTransition(): TransitionEffect {
    return TransitionEffect.translate({ y: '40%' }).combine(TransitionEffect.OPACITY);
  }

  /** Hand off the current chat to another HarmonyOS device (App Continuation). */
  private async handOff(): Promise<void> {
    try {
      const params: continuationManager.ContinuationExtraParams = {};
      const token = await continuationManager.register(params);
      hilog.info(DOMAIN, TAG, 'continuation registered, token=%{public}d', token);
      await continuationManager.startContinuationDeviceManager(token, params);
      setTimeout(() => {
        continuationManager.unregister(token).catch(() => {});
      }, 10000);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'handOff failed: %{public}s', JSON.stringify(err));
    }
  }

  build() {
    Stack() {
      // SECURITY BARRIER FAILURE: device not trusted — block all content.
      if (this.securityBlocked) {
        Column({ space: 12 }) {
          Text('Device not trusted')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.danger'))
          Text('This device failed the hardware integrity check. Chats are locked and local credentials have been wiped.')
            .fontSize(14)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_page'))
      } else if (this.view === 'connect') {
        Scroll() {
          Column({ space: 16 }) {
          Blank()
          Text('Link your WhatsApp')
            .fontSize(24)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Text('Open WhatsApp on your phone, tap Linked Devices > Link a Device, and scan this QR code.')
            .fontSize(14)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })

          // QR code card.
          Stack() {
            if (this.qr.length > 0) {
              QRCode(this.qr)
                .width(240)
                .height(240)
                .backgroundColor('#FFFFFF')
                .borderRadius(12)
            } else {
              Column({ space: 12 }) {
                LoadingProgress()
                  .width(40)
                  .height(40)
                  .color($r('app.color.brand'))
                Text('Waiting for a QR code…')
                  .fontSize(13)
                  .fontColor($r('app.color.ink_subtle'))
              }
              .width(240)
              .height(240)
              .justifyContent(FlexAlign.Center)
            }
          }
          .width(260)
          .height(260)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .shadow({ radius: 12, color: '#11000000', offsetY: 4 })

          Text('The code refreshes automatically. No browser or PC needed after linking.')
            .fontSize(12)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })

          // ---- Link with phone number instead ----
          Button(this.showPhoneLink ? 'Hide phone-number link' : 'Link with phone number instead')
            .width('70%')
            .height(44)
            .backgroundColor('#FFFFFF')
            .fontColor($r('app.color.brand'))
            .border({ width: 1, color: $r('app.color.brand') })
            .borderRadius(22)
            .onClick(() => {
              this.showPhoneLink = !this.showPhoneLink;
            })

          if (this.showPhoneLink) {
            Column({ space: 12 }) {
              Text('Enter your phone number to get an 8-character code, then tap Link a Device > Link with phone number instead in WhatsApp.')
                .fontSize(12)
                .fontColor($r('app.color.ink_subtle'))
                .textAlign(TextAlign.Center)
              Text('Country code separately; national number without the leading 0. After typing the code in WhatsApp, approve the "Link a device" notification on the phone.')
                .fontSize(10)
                .fontColor($r('app.color.ink_faded'))
                .textAlign(TextAlign.Center)

              Row({ space: 8 }) {
                // Country code.
                TextInput({ text: this.phoneCountry, placeholder: '1' })
                  .width(72)
                  .height(46)
                  .type(InputType.Number)
                  .fontColor($r('app.color.ink'))
                  .placeholderColor($r('app.color.ink_faded'))
                  .backgroundColor($r('app.color.surface_subtle'))
                  .onChange((v: string) => {
                    this.phoneCountry = v.replace(/[^0-9+]/g, '');
                  })
                // Phone number.
                TextInput({ text: this.phoneNumber, placeholder: 'Phone number' })
                  .layoutWeight(1)
                  .height(46)
                  .type(InputType.PhoneNumber)
                  .fontColor($r('app.color.ink'))
                  .placeholderColor($r('app.color.ink_faded'))
                  .backgroundColor($r('app.color.surface_subtle'))
                  .onChange((v: string) => {
                    this.phoneNumber = v;
                  })
              }

              Button(this.pairBusy ? 'Requesting…' : 'Get code')
                .width('100%')
                .height(44)
                .backgroundColor($r('app.color.brand'))
                .fontColor('#FFFFFF')
                .enabled(!this.pairBusy)
                .onClick(() => {
                  this.startPhonePair();
                })

              if (this.pairError.length > 0) {
                Text(this.pairError)
                  .fontSize(12)
                  .fontColor($r('app.color.danger'))
                  .textAlign(TextAlign.Center)
              }

              if (this.pairCodeText.length > 0) {
                Column({ space: 6 }) {
                  Text('Enter this 8-character code in WhatsApp (Link with phone number instead), then approve the link on the phone:')
                    .fontSize(11)
                    .fontColor($r('app.color.ink_subtle'))
                    .textAlign(TextAlign.Center)
                  Row({ space: 2 }) {
                    ForEach(this.pairCodeText.split(''), (ch: string) => {
                      Text(ch)
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor($r('app.color.ink'))
                        .height(34)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .backgroundColor($r('app.color.bg_page'))
                        .borderRadius(5)
                        .border({ width: 1, color: '#DDDDDD' })
                    }, (ch: string, idx: number) => idx + ch)
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                }
              }
            }
            .width('85%')
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .shadow({ radius: 8, color: '#11000000', offsetY: 2 })
          }

          // ---- Passkey (SHORTCAKE) verification card ----
          if (this.passkeyPending || this.passkeyCode.length > 0) {
            Column({ space: 12 }) {
              Text('WhatsApp security check')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.ink'))
              Text('WhatsApp wants to verify this device with a passkey. Complete the check to finish linking.')
                .fontSize(12)
                .fontColor($r('app.color.ink_subtle'))
                .textAlign(TextAlign.Center)

              if (this.passkeyCode.length > 0) {
                Text('Verification code — enter it in WhatsApp if asked:')
                  .fontSize(12)
                  .fontColor($r('app.color.ink_subtle'))
                  .textAlign(TextAlign.Center)
                 Text(this.passkeyCode)
                   .fontSize(24)
                   .fontWeight(FontWeight.Bold)
                   .fontColor($r('app.color.ink'))
                   .letterSpacing(4)
                   .textAlign(TextAlign.Center)
                Button(this.passkeyBusy ? 'Confirming…' : 'I entered the code — Confirm')
                  .width('100%')
                  .height(42)
                  .backgroundColor($r('app.color.brand'))
                  .fontColor('#FFFFFF')
                  .enabled(!this.passkeyBusy)
                  .onClick(() => {
                    this.confirmPasskey();
                  })
              } else if (this.passkeyPending) {
                Text('No native WebAuthn API on this SDK yet — paste the assertion JSON from a real authenticator to continue.')
                  .fontSize(11)
                  .fontColor($r('app.color.ink_subtle'))
                  .textAlign(TextAlign.Center)
                TextInput({ text: this.assertionInput, placeholder: 'Paste WebAuthn assertion JSON' })
                  .width('100%')
                  .height(90)
                  .type(InputType.Normal)
                  .onChange((v: string) => {
                    this.assertionInput = v;
                  })
                Button(this.passkeyBusy ? 'Submitting…' : 'Submit assertion')
                  .width('100%')
                  .height(42)
                  .backgroundColor($r('app.color.brand'))
                  .fontColor('#FFFFFF')
                  .enabled(!this.passkeyBusy && this.assertionInput.length > 0)
                  .onClick(() => {
                    this.submitPasskeyAssertion();
                  })
                Button('Use the QR code instead')
                  .width('100%')
                  .height(38)
                  .backgroundColor('#FFFFFF')
                  .fontColor($r('app.color.ink_subtle'))
                  .border({ width: 1, color: '#DDDDDD' })
                  .borderRadius(19)
                  .onClick(() => {
                    this.cancelPasskey();
                  })
              }

              if (this.passkeyError.length > 0) {
                Text(this.passkeyError)
                  .fontSize(12)
                  .fontColor($r('app.color.danger'))
                  .textAlign(TextAlign.Center)
                Button('Retry security check')
                  .width('100%')
                  .height(36)
                  .backgroundColor('#FFFFFF')
                  .fontColor($r('app.color.brand'))
                  .border({ width: 1, color: $r('app.color.brand') })
                  .borderRadius(18)
                  .onClick(() => {
                    this.refreshPasskey();
                  })
              }
            }
            .width('85%')
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .shadow({ radius: 8, color: '#11000000', offsetY: 2 })
          }

          Button(this.connecting ? 'Connecting…' : (this.connectionError.length > 0 ? 'Retry' : 'Refresh QR'))
            .width('70%')
            .height(48)
            .backgroundColor($r('app.color.brand'))
            .fontColor('#FFFFFF')
            .enabled(!this.connecting)
            .onClick(() => {
              this.connect();
            })
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(13)
              .fontColor($r('app.color.danger'))
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
          }

          Blank()
          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
          .padding(24)
          .backgroundColor($r('app.color.bg_page'))
        }
        .scrollBar(BarState.Auto)
        .width('100%')
        .height('100%')
        .transition(this.connectTransition())
      } else if (this.view === 'web') {
        WebLoginView()
          .width('100%')
          .height('100%')
          .transition(this.connectTransition())
      } else if (this.view === 'chats') {
        ChatListView({ onOpenChat: (name: string) => {
          this.openThread(name);
        }, onLoggedOut: () => {
          this.logoutAndReset();
        }, onHandOff: () => {
          this.handOff();
        }, onNewChat: () => {
          this.view = 'newchat';
        }, onComposeStatus: () => {
          this.view = 'statuscomposer';
        }, onFindChannels: () => {
          this.view = 'channels';
        } })
          .width('100%')
          .height('100%')
          .transition(this.chatsTransition())
      } else if (this.view === 'newchat') {
        NewChatView({ onBack: () => {
          this.view = 'chats';
        }, onPick: (digits: string) => {
          this.openThread(ContactPickerService.toWhatsAppJid(digits));
        } })
          .width('100%')
          .height('100%')
          .transition(this.newchatTransition())
      } else if (this.view === 'channels') {
        ChannelDirectoryView({ onBack: () => {
          this.view = 'chats';
        }, onOpenChannel: (id: string) => {
          this.openThread(id);
        } })
          .width('100%')
          .height('100%')
          .transition(this.channelsTransition())
      } else if (this.view === 'statuscomposer') {
        StatusComposerView({ onBack: () => {
          this.view = 'chats';
        }, onPosted: () => {
          this.view = 'chats';
        } })
          .width('100%')
          .height('100%')
          .transition(this.composerTransition())
      } else if (this.view === 'thread') {
        ChatThreadView({ chatName: this.chatName, onBack: () => {
          this.backToChats();
        } })
          .width('100%')
          .height('100%')
          .transition(this.threadTransition())
      }

      // Ringing call → full-screen accept/decline prompt.
      if (this.incomingCallId.length > 0) {
        Column({ space: 20 }) {
          Stack() {
            Circle({ width: 84, height: 84 })
              .fill($r('app.color.brand'))
            Text(cdpBridge.displayName(this.incomingFrom).charAt(0).toUpperCase())
              .fontSize(36)
              .fontColor('#FFFFFF')
          }
          Text(cdpBridge.displayName(this.incomingFrom))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
          Text(this.incomingVideo ? 'Video call from this contact' : 'Voice call from this contact')
            .fontSize(14)
            .fontColor('#E4E6EB')
          Row({ space: 48 }) {
            Column({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.phone'))
                .fontSize(26)
                .fontColor(['#FFFFFF'])
                .backgroundColor('#EA4335')
                .borderRadius(28)
                .padding(14)
              Text('Decline')
                .fontSize(12)
                .fontColor('#E4E6EB')
            }
            .onClick(() => {
              this.declineIncomingCall();
            })
            Column({ space: 6 }) {
              SymbolGlyph(this.incomingVideo ? $r('sys.symbol.video') : $r('sys.symbol.phone'))
                .fontSize(26)
                .fontColor(['#FFFFFF'])
                .backgroundColor('#007DFF')
                .borderRadius(28)
                .padding(14)
              Text('Accept')
                .fontSize(12)
                .fontColor('#E4E6EB')
            }
            .onClick(() => {
              this.acceptIncomingCall();
            })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#111B21')
      }

      // Active call (accepted from the prompt): the native call surface.
      if (this.activeCallSurface) {
        CallSurfaceView({
          chatName: this.activeCallName,
          callId: this.activeCallId,
          isVideo: this.activeCallVideo,
          onClose: () => {
            this.closeActiveCallSurface();
          }
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
