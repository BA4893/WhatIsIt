import { CallItem } from '../models/WhatsAppModels';
import { Avatar } from './Avatar';

/** Calls — recent call history and the entry points for voice/video calls. */
@Component
export struct CallsPane {
  @Prop calls: CallItem[] = [];
  @Prop live: boolean = false;
  onNewCall: () => void = () => {
  };
  onCallBack: (name: string, video: boolean) => void = () => {
  };

  @Builder
  CallIcon(item: CallItem) {
    Row({ space: 4 }) {
      SymbolGlyph(item.incoming ? $r('sys.symbol.arrow_down_left') : $r('sys.symbol.arrow_up_right'))
        .fontSize(13)
        .fontColor([item.missed ? $r('app.color.danger') : $r('app.color.connected')])
      SymbolGlyph(item.video ? $r('sys.symbol.video') : $r('sys.symbol.phone'))
        .fontSize(12)
        .fontColor([$r('app.color.ink_faded')])
    }
  }

  build() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text('Recent calls')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink'))
          Text('Voice and video calls')
            .fontSize(12)
            .fontColor($r('app.color.ink_subtle'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('New call')
          .height(34)
          .fontSize(13)
          .fontColor($r('app.color.brand_text'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(17)
          .onClick(() => {
            this.onNewCall();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (this.calls.length === 0) {
        Column({ space: 10 }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle({ width: 72, height: 72 })
              .fill($r('app.color.brand_soft'))
            SymbolGlyph($r('sys.symbol.phone'))
              .fontSize(30)
              .fontColor([$r('app.color.brand')])
          }
          Text('No calls yet')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Text('Start a voice or video call from any conversation.')
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 72, left: 32, right: 32 })
      } else {
        List() {
          ForEach(this.calls, (item: CallItem) => {
            ListItem() {
              Row({ space: 12 }) {
                Avatar({ label: item.name, seed: item.name, avatarSize: 48 })
                Column({ space: 4 }) {
                  Text(item.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(item.missed ? $r('app.color.danger') : $r('app.color.ink'))
                    .maxLines(1)
                  Row({ space: 6 }) {
                    this.CallIcon(item)
                    Text(item.time)
                      .fontSize(12)
                      .fontColor($r('app.color.ink_subtle'))
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                SymbolGlyph(item.video ? $r('sys.symbol.video') : $r('sys.symbol.phone'))
                  .fontSize(21)
                  .fontColor([$r('app.color.brand')])
                  .padding(10)
                  .onClick(() => {
                    this.onCallBack(item.name, item.video);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }
          }, (item: CallItem) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
  }
}
