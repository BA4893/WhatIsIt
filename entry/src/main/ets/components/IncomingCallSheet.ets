/**
 * IncomingCallSheet — full-screen ringing UI for a WhatsApp-native call.
 *
 * Harbour-whatsapp's call flow is the reference: the caller sees who is
 * calling, can decline or accept, and accepting hands off to the native call
 * surface (CallSurfaceView) with the same call id. This is in-app ringing;
 * background notifications are a later parity item.
 */
import { Avatar } from '../components/Avatar';

@Component
export struct IncomingCallSheet {
  callerName: string = '';
  callerHandle: string = '';
  isVideo: boolean = false;
  onAccept: () => void = () => {
  };
  onReject: () => void = () => {
  };
  @State pulse: number = 1;

  aboutToAppear(): void {
    this.pulse = 1;
    this.startPulse();
  }

  private startPulse(): void {
    animateTo({
      duration: 1600,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.pulse = 1.08;
    });
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#0B141A', 0.0], ['#111B21', 1.0]]
        })

      Column({ space: 10 }) {
        Blank()
        Text(this.isVideo ? 'Incoming video call' : 'Incoming voice call')
          .fontSize(13)
          .fontColor('#8696A0')
          .letterSpacing(0.4)

        Stack() {
          Circle({ width: 148, height: 148 })
            .fill('#1F2C34')
            .scale({ x: this.pulse, y: this.pulse })
            .opacity(0.55)
          Avatar({
            label: this.callerName.length > 0 ? this.callerName : '?',
            seed: this.callerHandle,
            avatarSize: 116,
            online: true
          })
        }
        .width(180)
        .height(180)

        Text(this.callerName.length > 0 ? this.callerName : 'Unknown caller')
          .fontSize(26)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E9EDEF')
          .textAlign(TextAlign.Center)
          .maxLines(2)
        Text(this.callerHandle)
          .fontSize(12)
          .fontColor('#8696A0')
          .textAlign(TextAlign.Center)

        Blank()

        Row({ space: 72 }) {
          Column({ space: 8 }) {
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(28)
                .fontColor(['#FFFFFF'])
            }
            .width(72)
            .height(72)
            .backgroundColor('#F15C5F')
            .borderRadius(36)
            .onClick(() => {
              this.onReject();
            })
            Text('Decline')
              .fontSize(12)
              .fontColor('#E9EDEF')
          }

          Column({ space: 8 }) {
            Button() {
              SymbolGlyph(this.isVideo ? $r('sys.symbol.video') : $r('sys.symbol.phone_fill'))
                .fontSize(30)
                .fontColor(['#0B141A'])
            }
            .width(72)
            .height(72)
            .backgroundColor('#25D366')
            .borderRadius(36)
            .onClick(() => {
              this.onAccept();
            })
            Text('Accept')
              .fontSize(12)
              .fontColor('#E9EDEF')
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 56 })

        Text('WhatIsIt · native WhatsApp call')
          .fontSize(10)
          .fontColor('#667781')
          .margin({ bottom: 18 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 24, right: 24, top: 24 })
    }
    .width('100%')
    .height('100%')
  }
}
