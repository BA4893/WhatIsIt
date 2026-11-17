import { ChatItem } from '../models/WhatsAppModels';
import { Avatar } from './Avatar';

/** One conversation row in the Chats tab. */
@Component
export struct ChatRow {
  @Prop chat: ChatItem = new ChatItem();
  onOpen: (chat: ChatItem) => void = () => {
  };

  build() {
    Column() {
      Row({ space: 12 }) {
        Avatar({
          label: this.chat.name,
          seed: this.chat.id,
          avatarSize: 52,
          online: this.chat.online,
          imageUrl: this.chat.avatarUrl
        })
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(this.chat.name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.chat.isGroup) {
              SymbolGlyph($r('sys.symbol.person_2'))
                .fontSize(13)
                .fontColor([$r('app.color.ink_faded')])
            }
          }
          .width('100%')

          Row({ space: 6 }) {
            if (this.chat.typing) {
              Text('typing…')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .layoutWeight(1)
                .maxLines(1)
            } else {
              Text(this.chat.preview)
                .fontSize(14)
                .fontColor($r('app.color.ink_subtle'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 6 }) {
          Text(this.chat.time)
            .fontSize(12)
            .fontColor(this.chat.unread > 0 ? $r('app.color.brand') : $r('app.color.ink_faded'))
          if (this.chat.unread > 0) {
            Text(this.chat.unread > 99 ? '99+' : String(this.chat.unread))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.brand_text'))
              .constraintSize({ minWidth: 20 })
              .height(20)
              .textAlign(TextAlign.Center)
              .padding({ left: 5, right: 5 })
              .backgroundColor($r('app.color.brand'))
              .borderRadius(10)
          } else if (this.chat.pinned) {
            Circle({ width: 6, height: 6 })
              .fill($r('app.color.ink_faded'))
          }
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.divider'))
        .margin({ left: 80 })
    }
    .width('100%')
    .onClick(() => {
      this.onOpen(this.chat);
    })
  }
}
