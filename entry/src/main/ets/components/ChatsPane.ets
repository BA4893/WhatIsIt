import { ChatItem } from '../models/WhatsAppModels';
import { ChatRow } from './ChatRow';

/** Chats — the default root tab. */
@Component
export struct ChatsPane {
  @Prop chats: ChatItem[] = [];
  @Prop live: boolean = false;
  @State query: string = '';
  @State filter: string = 'All';
  onOpen: (chat: ChatItem) => void = () => {
  };
  onLink: () => void = () => {
  };

  private filtered(): ChatItem[] {
    const q = this.query.trim().toLowerCase();
    return this.chats.filter((c: ChatItem) => {
      if (this.filter === 'Unread' && c.unread === 0) {
        return false;
      }
      if (this.filter === 'Groups' && !c.isGroup) {
        return false;
      }
      if (q.length === 0) {
        return true;
      }
      return c.name.toLowerCase().includes(q) || c.preview.toLowerCase().includes(q);
    });
  }

  @Builder
  FilterChip(label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.filter === label ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.filter === label ? $r('app.color.brand_text') : $r('app.color.ink_subtle'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.filter === label ? $r('app.color.brand') : $r('app.color.surface'))
      .borderRadius(18)
      .onClick(() => {
        this.filter = label;
      })
  }

  @Builder
  Empty() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 72, height: 72 })
          .fill($r('app.color.brand_soft'))
        SymbolGlyph($r('sys.symbol.message'))
          .fontSize(30)
          .fontColor([$r('app.color.brand')])
      }
      Text(this.query.length > 0 ? 'No chats found' : 'No chats yet')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink'))
      Text(this.query.length > 0 ? 'Try a different name or message.' : 'Your conversations will appear here.')
        .fontSize(13)
        .fontColor($r('app.color.ink_subtle'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 72, left: 32, right: 32 })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(17)
          .fontColor([$r('app.color.ink_faded')])
        TextInput({ text: this.query, placeholder: 'Search' })
          .layoutWeight(1)
          .height(38)
          .fontSize(15)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.query = value;
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
      .backgroundColor($r('app.color.surface_subtle'))
      .borderRadius(19)
      .margin({ left: 16, right: 16, top: 8, bottom: 10 })

      Scroll() {
        Row({ space: 8 }) {
          this.FilterChip('All')
          this.FilterChip('Unread')
          this.FilterChip('Groups')
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ bottom: 6 })

      if (!this.live) {
        Row({ space: 8 }) {
          Circle({ width: 6, height: 6 })
            .fill($r('app.color.warning'))
          Text('Preview chats — link a device to go live')
            .fontSize(11)
            .fontColor($r('app.color.ink_subtle'))
            .layoutWeight(1)
          Text('Link')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              this.onLink();
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
        .margin({ left: 16, right: 16, bottom: 6 })
      }

      if (this.filtered().length === 0) {
        this.Empty()
      } else {
        List() {
          ForEach(this.filtered(), (chat: ChatItem) => {
            ListItem() {
              ChatRow({ chat: chat, onOpen: (c: ChatItem) => {
                this.onOpen(c);
              } })
            }
          }, (chat: ChatItem) => chat.id)
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
