import { ChatItem, MessageItem } from '../models/WhatsAppModels';
import { Avatar } from './Avatar';

/** A conversation thread with a WhatsApp-style bubble list and composer. */
@Component
export struct ConversationView {
  @Prop chat: ChatItem = new ChatItem();
  @Prop @Watch('onMessagesChanged') messages: MessageItem[] = [];
  @Prop live: boolean = false;
  @Prop loadingOlder: boolean = false;
  private listScroller: Scroller = new Scroller();
  @State draft: string = '';
  onBack: () => void = () => {
  };
  onSend: (text: string) => void = () => {
  };
  onCall: (video: boolean) => void = () => {
  };
  onLoadOlder: () => void = () => {
  };
  onAttachTap: () => void = () => {
  };
  onOpenMedia: (message: MessageItem) => void = () => {
  };

  private onMessagesChanged(): void {
    setTimeout(() => {
      if (this.messages.length > 0) {
        try {
          this.listScroller.scrollToIndex(this.messages.length - 1, false, ScrollAlign.END);
        } catch (e) {
          // list not laid out yet
        }
      }
    }, 30);
  }

  @Builder
  Tick(message: MessageItem) {
    if (message.out) {
      Row({ space: 1 }) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(11)
          .fontColor([message.status === 'read' ? $r('app.color.read_tick') : $r('app.color.delivered_tick')])
        if (message.status === 'delivered' || message.status === 'read') {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(11)
            .fontColor([message.status === 'read' ? $r('app.color.read_tick') : $r('app.color.delivered_tick')])
        }
      }
    }
  }

  @Builder
  Bubble(message: MessageItem) {
    Row() {
      if (message.out) {
        Blank()
      }
      Column({ space: 3 }) {
        if (message.sender.length > 0 && !message.out) {
          Text(message.sender)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand'))
        }
        if (message.mediaType === 'image' && message.mediaUrl.length > 0) {
          Image(message.mediaUrl)
            .width(210)
            .height(150)
            .borderRadius(8)
            .objectFit(ImageFit.Cover)
            .onClick(() => {
              this.onOpenMedia(message);
            })
        } else if (message.mediaType === 'video') {
          Stack({ alignContent: Alignment.Center }) {
            if (message.mediaUrl.length > 0) {
              Image(message.mediaUrl)
                .width(210)
                .height(150)
                .borderRadius(8)
                .objectFit(ImageFit.Cover)
                .opacity(0.85)
            } else {
              Row()
                .width(210)
                .height(150)
                .borderRadius(8)
                .backgroundColor('#263238')
            }
            Circle({ width: 44, height: 44 })
              .fill('#CC000000')
            SymbolGlyph($r('sys.symbol.play'))
              .fontSize(22)
              .fontColor(['#FFFFFF'])
          }
          .width(210)
          .height(150)
          .onClick(() => {
            this.onOpenMedia(message);
          })
        } else if (message.mediaType === 'document') {
          Row({ space: 8 }) {
            Row() {
              Text('DOC')
                .fontSize(9)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.brand'))
            }
            .width(34)
            .height(42)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.brand_soft'))
            .borderRadius(4)
            Text(message.mediaName.length > 0 ? message.mediaName : 'Document')
              .fontSize(13)
              .fontColor(message.out ? $r('app.color.bubble_out_text') : $r('app.color.bubble_in_text'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width(210)
          .onClick(() => {
            this.onOpenMedia(message);
          })
        } else if (message.mediaType === 'audio') {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.play'))
              .fontSize(16)
              .fontColor([$r('app.color.brand')])
            Text('Voice message')
              .fontSize(13)
              .fontColor(message.out ? $r('app.color.bubble_out_text') : $r('app.color.bubble_in_text'))
          }
          .onClick(() => {
            this.onOpenMedia(message);
          })
        }
        if (message.text.length > 0) {
          Text(message.text)
            .fontSize(15)
            .fontColor(message.out ? $r('app.color.bubble_out_text') : $r('app.color.bubble_in_text'))
            .lineHeight(20)
        }
        Row({ space: 4 }) {
          Text(message.time)
            .fontSize(10)
            .fontColor($r('app.color.ink_faded'))
          this.Tick(message)
        }
        .justifyContent(FlexAlign.End)
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ maxWidth: '78%' })
      .padding({ left: 10, right: 10, top: 7, bottom: 5 })
      .backgroundColor(message.out ? $r('app.color.bubble_out') : $r('app.color.bubble_in'))
      .borderRadius(10)
      if (!message.out) {
        Blank()
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 2, bottom: 2 })
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(23)
          .fontColor([$r('app.color.brand')])
          .width(28)
          .onClick(() => {
            this.onBack();
          })
        Avatar({ label: this.chat.name, seed: this.chat.id, avatarSize: 38, online: this.chat.online, imageUrl: this.chat.avatarUrl })
        Column({ space: 1 }) {
          Text(this.chat.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.chat.typing ? 'typing…' : (this.chat.online ? 'online' : 'tap for contact info'))
            .fontSize(11)
            .fontColor(this.chat.typing ? $r('app.color.brand') : $r('app.color.ink_subtle'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.video'))
          .fontSize(21)
          .fontColor([$r('app.color.brand')])
          .padding(6)
          .onClick(() => {
            this.onCall(true);
          })
        SymbolGlyph($r('sys.symbol.phone'))
          .fontSize(20)
          .fontColor([$r('app.color.brand')])
          .padding(6)
          .onClick(() => {
            this.onCall(false);
          })
      }
      .width('100%')
      .padding({ left: 6, right: 12, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.surface'))

      if (!this.live) {
        Row({ space: 6 }) {
          Circle({ width: 6, height: 6 })
            .fill($r('app.color.warning'))
          Text('Preview conversation — link a device to send messages')
            .fontSize(11)
            .fontColor($r('app.color.ink_subtle'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.surface_subtle'))
      }

      List({ space: 0, scroller: this.listScroller }) {
        if (this.loadingOlder) {
          ListItem() {
            Text('Loading older messages…')
              .fontSize(11)
              .fontColor($r('app.color.ink_subtle'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(8)
          }
        }
        ForEach(this.messages, (message: MessageItem, index: number) => {
          ListItem() {
            Column() {
              if (index === 0) {
                Text(this.chat.time.length > 0 ? this.chat.time : 'Today')
                  .fontSize(10)
                  .fontColor($r('app.color.ink_subtle'))
                  .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                  .backgroundColor($r('app.color.surface'))
                  .borderRadius(7)
                  .margin({ top: 10, bottom: 6 })
              }
              this.Bubble(message)
            }
            .width('100%')
          }
        }, (message: MessageItem) => message.id)
        ListItem() {
          Row().width('100%').height(10)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor($r('app.color.bg_chat'))
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachStart(() => {
        if (this.messages.length > 0) {
          this.onLoadOlder();
        }
      })

      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.paperclip'))
          .fontSize(21)
          .fontColor([$r('app.color.ink_subtle')])
          .padding(4)
          .onClick(() => {
            this.onAttachTap();
          })
        Row({ space: 6 }) {
          TextInput({ text: this.draft, placeholder: 'Message' })
            .layoutWeight(1)
            .height(40)
            .fontSize(15)
            .fontColor($r('app.color.ink'))
            .placeholderColor($r('app.color.ink_faded'))
            .backgroundColor(Color.Transparent)
            .onChange((value: string) => {
              this.draft = value;
            })
          if (this.draft.trim().length === 0) {
            SymbolGlyph($r('sys.symbol.camera'))
              .fontSize(19)
              .fontColor([$r('app.color.ink_subtle')])
          } else {
            SymbolGlyph($r('sys.symbol.mic'))
              .fontSize(19)
              .fontColor([$r('app.color.ink_subtle')])
          }
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 8 })
        .backgroundColor($r('app.color.surface_subtle'))
        .borderRadius(20)

        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 40, height: 40 })
            .fill(this.draft.trim().length > 0 ? $r('app.color.brand') : $r('app.color.surface_subtle'))
          SymbolGlyph(this.draft.trim().length > 0 ? $r('sys.symbol.arrow_up') : $r('sys.symbol.plus'))
            .fontSize(19)
            .fontColor([this.draft.trim().length > 0 ? $r('app.color.brand_text') : $r('app.color.ink_subtle')])
        }
        .onClick(() => {
          const text = this.draft.trim();
          if (text.length === 0) {
            return;
          }
          this.draft = '';
          this.onSend(text);
        })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.surface'))
    }
    .width('100%')
    .height('100%')
  }
}
