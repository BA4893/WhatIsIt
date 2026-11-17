/**
 * NativeLinkView — native onboarding for the hidden WhatsApp Web session.
 *
 * It mirrors WhatsApp Web's unlinked state: QR, phone-number entry, 8-character
 * code and linked. The WebView performs the actual pairing; the user sees only
 * native ArkUI. Passkey/unsupported flows can fall back to the Web view.
 */
import { whatsappWebBridge } from '../services/WhatsAppWebBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'NativeLink';
const DOMAIN = 0x0000;

@Component
export struct NativeLinkView {
  @State phase: string = 'loading'; // loading | qr | phone | code | linked
  @State qrUrl: string = '';
  @State country: string = '44';
  @State phone: string = '';
  @State code: string = '';
  @State countdown: number = 0;
  @State busy: boolean = false;
  @State errorText: string = '';
  onLinked: () => void = () => {
  };
  onWeb: () => void = () => {
  };
  onSkip: () => void = () => {
  };
  private pollTimer: number | null = null;
  private tickTimer: number | null = null;
  private pollCount: number = 0;
  private debugLogged: boolean = false;

  aboutToAppear(): void {
    this.poll();
    this.pollTimer = setInterval(() => {
      this.poll();
    }, 1200);
    this.tickTimer = setInterval(() => {
      if (this.countdown > 0) {
        this.countdown -= 1;
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    if (this.tickTimer !== null) {
      clearInterval(this.tickTimer);
      this.tickTimer = null;
    }
  }

  private async poll(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.pollCount += 1;
    const state = await whatsappWebBridge.linkState();
    if (state === 'linked') {
      this.phase = 'linked';
      hilog.info(DOMAIN, TAG, 'WhatsApp linked');
      this.onLinked();
      return;
    }
    if (state === 'code') {
      const value = await whatsappWebBridge.pairCode();
      if (value.length > 0 && value !== this.code) {
        this.code = value;
        this.phase = 'code';
        this.countdown = 60;
        hilog.info(DOMAIN, TAG, 'pair code received');
      }
      return;
    }
    if (state === 'qr') {
      const image = await whatsappWebBridge.qrImage();
      if (image.length > 0 && image !== this.qrUrl) {
        this.qrUrl = image;
      }
      if (this.phase !== 'qr') {
        this.phase = 'qr';
        this.errorText = '';
      }
      return;
    }
    if (state === 'phone-entry') {
      this.phase = 'phone';
      return;
    }
    if (this.phase !== 'phone' && this.phase !== 'code') {
      this.phase = 'loading';
    }
    if (this.pollCount === 8 && !this.debugLogged) {
      this.debugLogged = true;
      const debug = await whatsappWebBridge.linkDebug();
      hilog.info(DOMAIN, TAG, 'link debug: %{public}s', debug);
      this.errorText = 'Still reading WhatsApp Web. You can use WhatsApp Web instead.';
    }
  }

  private async usePhone(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    const ok = await whatsappWebBridge.choosePhone();
    this.busy = false;
    if (!ok) {
      this.errorText = 'Could not open the phone-number form. Use WhatsApp Web instead.';
      return;
    }
    this.phase = 'phone';
  }

  private async requestCode(): Promise<void> {
    if (this.busy) {
      return;
    }
    const cc = this.country.replace(/[^0-9]/g, '');
    const national = this.phone.replace(/[^0-9]/g, '').replace(/^0+/, '');
    if (cc.length === 0 || national.length < 7) {
      this.errorText = 'Enter a country code and national number.';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const ok = await whatsappWebBridge.submitPhone(cc, national);
      if (!ok) {
        this.errorText = 'Could not submit the phone number.';
        return;
      }
      await this.delay(900);
      const value = await whatsappWebBridge.pairCode();
      if (value.length > 0) {
        this.code = value;
        this.phase = 'code';
        this.countdown = 60;
      } else {
        this.errorText = 'Waiting for WhatsApp to show the code…';
      }
    } finally {
      this.busy = false;
    }
  }

  private async newCode(): Promise<void> {
    this.code = '';
    this.countdown = 0;
    this.phase = 'phone';
    await this.requestCode();
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  private formattedCode(): string {
    if (this.code.length === 8) {
      return this.code.substring(0, 4) + '-' + this.code.substring(4);
    }
    return this.code;
  }

  build() {
    Column({ space: 12 }) {
      Blank()
      Row({ space: 8 }) {
        Circle({ width: 34, height: 34 })
          .fill($r('app.color.brand'))
        Text('W')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand_text'))
          .position({ x: 0, y: 0 })
      }
      .width(34)
      .height(34)

      Text('Link your WhatsApp')
        .fontSize(25)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink'))
      Text('Use this phone as a linked device. Messages stay end-to-end encrypted.')
        .fontSize(12)
        .fontColor($r('app.color.ink_subtle'))
        .textAlign(TextAlign.Center)
        .padding({ left: 28, right: 28 })

      if (this.phase === 'loading') {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(34)
            .height(34)
            .color($r('app.color.brand'))
          Text('Preparing WhatsApp Web…')
            .fontSize(12)
            .fontColor($r('app.color.ink_subtle'))
        }
        .height(250)
        .justifyContent(FlexAlign.Center)
      } else if (this.phase === 'qr') {
        Column({ space: 10 }) {
          if (this.qrUrl.length > 0) {
            Image(this.qrUrl)
              .width(220)
              .height(220)
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
          } else {
            LoadingProgress()
              .width(32)
              .height(32)
              .color($r('app.color.brand'))
          }
          Text('WhatsApp → Settings → Linked devices → Link a device')
            .fontSize(12)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
          Button('Link with phone number instead')
            .height(36)
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .backgroundColor($r('app.color.brand_soft'))
            .borderRadius(18)
            .enabled(!this.busy)
            .onClick(() => {
              this.usePhone();
            })
        }
      } else if (this.phase === 'phone') {
        Column({ space: 10 }) {
          Text('Enter the WhatsApp phone number')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Row({ space: 8 }) {
            TextInput({ text: this.country, placeholder: '44' })
              .width(68)
              .height(42)
              .type(InputType.Number)
              .fontSize(14)
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(10)
              .onChange((value: string) => {
                this.country = value.replace(/[^0-9]/g, '');
              })
            TextInput({ text: this.phone, placeholder: 'National number' })
              .layoutWeight(1)
              .height(42)
              .type(InputType.Number)
              .fontSize(14)
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(10)
              .onChange((value: string) => {
                this.phone = value.replace(/[^0-9]/g, '');
              })
          }
          .width('100%')
          Text('You will get an 8-character code to enter in WhatsApp → Linked devices.')
            .fontSize(11)
            .fontColor($r('app.color.ink_faded'))
            .textAlign(TextAlign.Center)
          Button(this.busy ? 'Requesting…' : 'Get code')
            .width('100%')
            .height(42)
            .fontSize(13)
            .fontColor($r('app.color.brand_text'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius(21)
            .enabled(!this.busy)
            .onClick(() => {
              this.requestCode();
            })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 20, right: 20 })
      } else if (this.phase === 'code') {
        Column({ space: 10 }) {
          Text('Enter this code on your phone')
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
          Text(this.formattedCode())
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink'))
            .letterSpacing(3)
          Text(this.countdown > 0 ? 'Expires in ' + this.countdown + 's' : 'Code expired')
            .fontSize(11)
            .fontColor(this.countdown > 0 ? $r('app.color.ink_faded') : $r('app.color.danger'))
          Text('WhatsApp → Settings → Linked devices → Link with phone number')
            .fontSize(11)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
          if (this.countdown === 0) {
            Button('Request a new code')
              .height(38)
              .fontSize(12)
              .fontColor($r('app.color.brand_text'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(19)
              .onClick(() => {
                this.newCode();
              })
          }
        }
        .width('100%')
        .padding(18)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 20, right: 20 })
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(11)
          .fontColor($r('app.color.danger'))
          .textAlign(TextAlign.Center)
          .padding({ left: 20, right: 20 })
      }

      Blank()

      Row({ space: 8 }) {
        Button('Open WhatsApp Web')
          .height(34)
          .fontSize(11)
          .fontColor($r('app.color.brand'))
          .backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.brand') })
          .borderRadius(17)
          .onClick(() => {
            this.onWeb();
          })
        Button('Continue to native shell')
          .height(34)
          .fontSize(11)
          .fontColor($r('app.color.ink_subtle'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(17)
          .onClick(() => {
            this.onSkip();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
