import { StatusItem } from '../models/WhatsAppModels';
import { Avatar } from './Avatar';

/** Full-screen status viewer with a simple progress treatment. */
@Component
export struct StatusViewer {
  @Prop status: StatusItem = new StatusItem();
  onClose: () => void = () => {
  };

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.status.color)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')

      Column() {
        Row({ space: 4 }) {
          ForEach([0, 1, 2], (index: number) => {
            Row()
              .layoutWeight(1)
              .height(3)
              .backgroundColor(index === 0 ? '#FFFFFF' : '#66FFFFFF')
              .borderRadius(2)
          }, (index: number) => String(index))
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10 })

        Row({ space: 10 }) {
          Avatar({ label: this.status.name, seed: this.status.name, avatarSize: 38 })
          Column({ space: 2 }) {
            Text(this.status.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
            Text(this.status.time + ' ago')
              .fontSize(11)
              .fontColor('#CCFFFFFF')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor(['#FFFFFF'])
            .padding(6)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10 })

        Blank()

        Text(this.status.text)
          .fontSize(26)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 28, right: 28 })

        Blank()

        Text('Text status · 24h')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
          .padding({ bottom: 28 })
      }
      .width('100%')
      .height('100%')
      .onClick(() => {
        this.onClose();
      })
    }
    .width('100%')
    .height('100%')
  }
}
