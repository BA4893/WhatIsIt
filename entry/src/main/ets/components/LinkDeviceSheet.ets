import { cdpBridge, BackendEvent, EventListener } from '../services/CdpBridge';
import { ServerConfig } from '../services/ServerConfig';
import { passkeyBridge, passkeyBridgeStore } from '../services/PasskeyBridge';
import { common } from '@kit.AbilityKit';

/**
 * Link a device. The native QR/phone flow is used when a WhatsApp engine or
 * backend is reachable; otherwise the sheet offers the real WhatsApp Web
 * login, which needs no backend at all.
 */
@Component
export struct LinkDeviceSheet {
  @Prop initialMode: string = 'qr';
  onClose: () => void = () => {
  };
  onWeb: () => void = () => {
  };
  onLinked: () => void = () => {
  };

  @State mode: string = 'qr';
  @State qr: string = '';
  @State code: string = '';
  @State country: string = '1';
  @State phone: string = '';
  @State busy: boolean = false;
  @State errorText: string = '';
  @State linked: boolean = false;
  @State checked: boolean = false;
  @State passkeyStatus: string = '';
  @State passkeyCode: string = '';
  @State passkeyBusy: boolean = false;
  private timer: number | null = null;
  private checking: boolean = false;
  private listener: EventListener = (evt: BackendEvent) => {
    if (evt.type === 'qr' && evt.qr !== undefined) {
      this.qr = evt.qr;
    } else if (evt.type === 'pair_code' && evt.code !== undefined) {
      this.code = evt.code;
      this.busy = false;
    } else if (evt.type === 'linked') {
      this.linked = true;
      this.busy = false;
      this.passkeyStatus = '';
      this.passkeyCode = '';
    } else if (evt.type === 'passkey_request' && evt.options !== undefined) {
      this.handlePasskey(evt.options);
    } else if (evt.type === 'passkey_confirmation' && evt.code !== undefined) {
      this.passkeyCode = evt.code;
      this.passkeyStatus = 'Confirm the code on your phone to finish linking.';
      this.passkeyBusy = false;
    } else if (evt.type === 'passkey_error') {
      this.passkeyStatus = '';
      this.passkeyBusy = false;
      this.errorText = evt.error !== undefined ? evt.error : 'The passkey step failed.';
    }
  };

  aboutToAppear(): void {
    this.mode = this.initialMode;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    passkeyBridge.configure(passkeyBridgeStore.load(ctx));
    cdpBridge.addEventListener(this.listener);
    this.checkStatus();
    this.timer = setInterval(() => {
      if (this.timer !== null) {
        this.checkStatus();
      }
    }, 3000);
  }

  aboutToDisappear(): void {
    cdpBridge.removeEventListener(this.listener);
    if (this.passkeyCode.length > 0 || this.passkeyStatus.length > 0) {
      cdpBridge.passkeyCancel();
    }
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  private async checkStatus(): Promise<void> {
    if (this.checking || this.linked) {
      return;
    }
    this.checking = true;
    try {
      if (!cdpBridge.hasNativeEngine()) {
        const stored = await cdpBridge.readStoredEndpoint();
        const configured = stored !== null ? stored.host : ServerConfig.BACKEND_HOST;
        const loopback = configured === '127.0.0.1' || configured === 'localhost';
        if (loopback && !(await cdpBridge.probeLocal())) {
          this.errorText = 'No native WhatsApp engine is reachable. Use WhatsApp Web below.';
          this.checked = true;
          if (this.timer !== null) {
            clearInterval(this.timer);
            this.timer = null;
          }
          return;
        }
      }
      const st = await cdpBridge.getStatus();
      if (st === null) {
        this.errorText = 'No native WhatsApp engine is reachable. Use WhatsApp Web below.';
        return;
      }
      this.errorText = '';
      if (st.linked) {
        this.linked = true;
        this.busy = false;
        if (this.timer !== null) {
          clearInterval(this.timer);
          this.timer = null;
        }
        return;
      }
      if (st.qr.length > 0) {
        this.qr = st.qr;
      }
      if (!this.checked) {
        this.checked = true;
        this.startQr();
      }
    } finally {
      this.checking = false;
    }
  }

  private async startQr(): Promise<void> {
    const ok = await cdpBridge.startPair();
    if (!ok) {
      this.errorText = 'No native WhatsApp engine is reachable. Use WhatsApp Web below.';
    }
  }

  /** A passkey-gated companion link: ask the PC bridge for the assertion. */
  private async handlePasskey(optionsJson: string): Promise<void> {
    if (this.passkeyBusy) {
      return;
    }
    this.passkeyBusy = true;
    this.passkeyCode = '';
    this.errorText = '';
    this.passkeyStatus = 'Complete the passkey prompt on your computer…';
    try {
      if (!passkeyBridge.isConfigured()) {
        this.errorText = 'Configure Settings → Passkey bridge so this account can use its passkey.';
        this.passkeyStatus = '';
        return;
      }
      const assertionJson = await passkeyBridge.assert(optionsJson);
      const parsed = JSON.parse(assertionJson) as Record<string, Object>;
      const rawId = String(parsed['rawId'] ?? '');
      if (rawId.length === 0) {
        throw new Error('The bridge returned no credential id.');
      }
      const bytes = new Uint8Array(assertionJson.length);
      for (let i = 0; i < assertionJson.length; i++) {
        bytes[i] = assertionJson.charCodeAt(i) & 0xFF;
      }
      const assertionB64 = cdpBridge.b64UrlFromBytes(bytes);
      const ok = await cdpBridge.passkeyAssertion(rawId, assertionB64);
      if (!ok) {
        throw new Error('The engine rejected the passkey assertion.');
      }
      this.passkeyStatus = 'Waiting for WhatsApp confirmation…';
    } catch (e) {
      const message = (e as Error)?.message;
      this.errorText = message !== undefined && message.length > 0
        ? message : 'The passkey step failed.';
      this.passkeyStatus = '';
      this.passkeyBusy = false;
      await cdpBridge.passkeyCancel();
      return;
    }
    this.passkeyBusy = false;
  }

  private async confirmPasskey(): Promise<void> {
    if (this.passkeyBusy) {
      return;
    }
    this.passkeyBusy = true;
    try {
      const ok = await cdpBridge.passkeyConfirm();
      if (!ok) {
        throw new Error('WhatsApp did not accept the confirmation.');
      }
      this.passkeyCode = '';
      this.passkeyStatus = 'Confirmed. Waiting for the engine to finish linking…';
    } catch (e) {
      const message = (e as Error)?.message;
      this.errorText = message !== undefined && message.length > 0
        ? message : 'Could not confirm the passkey link.';
    } finally {
      this.passkeyBusy = false;
    }
  }

  private async startPhone(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.code = '';
    let cc = this.country.replace(/[^0-9]/g, '').replace(/^0+/, '');
    let national = this.phone.replace(/[^0-9]/g, '').replace(/^0+/, '');
    if (cc.length > 0 && national.startsWith(cc) && national.length > cc.length + 6) {
      national = national.substring(cc.length);
    }
    if (cc.length === 0 || national.length < 7) {
      this.errorText = 'Enter a country code and a national number without the leading 0.';
      this.busy = false;
      return;
    }
    try {
      const value = await cdpBridge.pairCode(cc, national);
      if (value.length > 0) {
        this.code = value;
        this.busy = false;
        return;
      }
      this.errorText = 'No code received yet. Keep this sheet open and try again.';
    } catch (e) {
      const message = (e as Error)?.message;
      this.errorText = message !== undefined && message.length > 0
        ? message : 'Could not request a code. Use WhatsApp Web below.';
    }
    this.busy = false;
  }

  @Builder
  Segment(label: string, key: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.mode === key ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.mode === key ? $r('app.color.brand') : $r('app.color.ink_subtle'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: 8, bottom: 8 })
      .backgroundColor(this.mode === key ? $r('app.color.brand_soft') : Color.Transparent)
      .borderRadius(15)
      .onClick(() => {
        this.mode = key;
        this.errorText = '';
        if (key === 'qr' && this.qr.length === 0) {
          this.startQr();
        }
      })
  }

  @Builder
  QrContent() {
    Column({ space: 12 }) {
      if (this.qr.length > 0) {
        QRCode(this.qr)
          .width(220)
          .height(220)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
      } else {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(34)
            .height(34)
            .color($r('app.color.brand'))
          Text(this.errorText.length > 0 ? 'Native pairing unavailable' : 'Preparing your QR code…')
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
        }
        .width(220)
        .height(220)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.surface_subtle'))
        .borderRadius(12)
      }
      Text('WhatsApp → Settings → Linked devices → Link a device')
        .fontSize(12)
        .fontColor($r('app.color.ink_subtle'))
        .textAlign(TextAlign.Center)
      Text('The code refreshes automatically.')
        .fontSize(11)
        .fontColor($r('app.color.ink_faded'))
    }
    .width('100%')
  }

  @Builder
  PhoneContent() {
    Column({ space: 10 }) {
      Text('Enter your phone number to get an 8-character code.')
        .fontSize(12)
        .fontColor($r('app.color.ink_subtle'))
        .textAlign(TextAlign.Center)
      Row({ space: 8 }) {
        TextInput({ text: this.country, placeholder: '1' })
          .width(66)
          .height(42)
          .type(InputType.Number)
          .fontSize(14)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(10)
          .onChange((value: string) => {
            this.country = value.replace(/[^0-9]/g, '');
          })
        TextInput({ text: this.phone, placeholder: 'National number' })
          .layoutWeight(1)
          .height(42)
          .type(InputType.PhoneNumber)
          .fontSize(14)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(10)
          .onChange((value: string) => {
            this.phone = value;
          })
      }
      .width('100%')
      Button(this.busy ? 'Requesting…' : 'Get code')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor($r('app.color.brand_text'))
        .backgroundColor($r('app.color.brand'))
        .borderRadius(20)
        .enabled(!this.busy)
        .onClick(() => {
          this.startPhone();
        })
      if (this.code.length > 0) {
        Text(this.code)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .letterSpacing(2)
          .textAlign(TextAlign.Center)
        Text('Enter this code in WhatsApp → Linked devices → Link with phone number instead, then approve the notification on the phone.')
          .fontSize(11)
          .fontColor($r('app.color.ink_subtle'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.onClose();
        })

      Column({ space: 12 }) {
        Row() {
          Text('Link a device')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink'))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor([$r('app.color.ink_subtle')])
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')

        if (this.linked) {
          Column({ space: 10 }) {
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: 64, height: 64 })
                .fill($r('app.color.brand_soft'))
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(30)
                .fontColor([$r('app.color.brand')])
            }
            Text('This device is linked')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
            Text('Your chats are now available in the app.')
              .fontSize(12)
              .fontColor($r('app.color.ink_subtle'))
          }
          .width('100%')
          .padding({ top: 24, bottom: 24 })
        } else {
          Row({ space: 4 }) {
            this.Segment('QR code', 'qr')
            this.Segment('Phone number', 'phone')
          }
          .width('100%')
          .padding(3)
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(18)

          Scroll() {
            Column({ space: 10 }) {
              if (this.mode === 'qr') {
                this.QrContent()
              } else {
                this.PhoneContent()
              }
              if (this.errorText.length > 0) {
                Text(this.errorText)
                  .fontSize(11)
                  .fontColor($r('app.color.danger'))
                  .textAlign(TextAlign.Center)
              }
              if (this.passkeyStatus.length > 0 || this.passkeyCode.length > 0) {
                Column({ space: 8 }) {
                  Text(this.passkeyStatus)
                    .fontSize(12)
                    .fontColor($r('app.color.ink'))
                    .textAlign(TextAlign.Center)
                  if (this.passkeyCode.length > 0) {
                    Text(this.passkeyCode)
                      .fontSize(26)
                      .fontWeight(FontWeight.Bold)
                      .fontColor($r('app.color.ink'))
                      .letterSpacing(2)
                      .textAlign(TextAlign.Center)
                    Button(this.passkeyBusy ? 'Confirming…' : 'Confirm link')
                      .width('100%')
                      .height(38)
                      .fontSize(13)
                      .fontColor($r('app.color.brand_text'))
                      .backgroundColor($r('app.color.brand'))
                      .borderRadius(19)
                      .enabled(!this.passkeyBusy)
                      .onClick(() => {
                        this.confirmPasskey();
                      })
                  }
                }
                .width('100%')
                .padding(12)
                .backgroundColor($r('app.color.brand_soft'))
                .borderRadius(12)
              }
              Button('Use WhatsApp Web instead')
                .width('100%')
                .height(40)
                .fontSize(13)
                .fontColor($r('app.color.brand'))
                .backgroundColor($r('app.color.surface'))
                .border({ width: 1, color: $r('app.color.brand') })
                .borderRadius(20)
                .onClick(() => {
                  this.onWeb();
                })
              Text('WhatsApp Web runs the official QR / phone-number flow in the app and needs no backend.')
                .fontSize(10)
                .fontColor($r('app.color.ink_faded'))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
          }
          .scrollBar(BarState.Off)
          .constraintSize({ maxHeight: 520 })
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 28 })
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .onClick(() => {
        // consume taps on the card
      })
    }
    .width('100%')
    .height('100%')
  }
}
