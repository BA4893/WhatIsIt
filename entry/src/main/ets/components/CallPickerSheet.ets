import { ChatItem } from '../models/WhatsAppModels';
import { Avatar } from './Avatar';

/** Pick a contact and start a voice or video call. */
@Component
export struct CallPickerSheet {
  @Prop chats: ChatItem[] = [];
  onClose: () => void = () => {
  };
  onCall: (chat: ChatItem, video: boolean) => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.onClose();
        })

      Column({ space: 8 }) {
        Row() {
          Text('New call')
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
        .padding({ bottom: 6 })

        List() {
          ForEach(this.chats, (chat: ChatItem) => {
            ListItem() {
              Row({ space: 12 }) {
                Avatar({ label: chat.name, seed: chat.id, avatarSize: 44 })
                Text(chat.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.ink'))
                  .layoutWeight(1)
                  .maxLines(1)
                SymbolGlyph($r('sys.symbol.phone'))
                  .fontSize(19)
                  .fontColor([$r('app.color.brand')])
                  .padding(8)
                  .onClick(() => {
                    this.onCall(chat, false);
                  })
                SymbolGlyph($r('sys.symbol.video'))
                  .fontSize(19)
                  .fontColor([$r('app.color.brand')])
                  .padding(8)
                  .onClick(() => {
                    this.onCall(chat, true);
                  })
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
            }
          }, (chat: ChatItem) => chat.id)
        }
        .width('100%')
        .height(360)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 28 })
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .onClick(() => {
        // consume
      })
    }
    .width('100%')
    .height('100%')
  }
}
