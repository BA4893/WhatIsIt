import { StatusItem, ChannelItem } from '../models/WhatsAppModels';
import { Avatar } from './Avatar';

/** Updates — status posts and followed channels. */
@Component
export struct UpdatesPane {
  @Prop statuses: StatusItem[] = [];
  @Prop channels: ChannelItem[] = [];
  @Prop live: boolean = false;
  @State myStatus: boolean = false;
  onComposeStatus: () => void = () => {
  };
  onViewStatus: (status: StatusItem) => void = () => {
  };
  onFindChannels: () => void = () => {
  };
  onOpenChannel: (channel: ChannelItem) => void = () => {
  };

  @Builder
  SectionHeader(title: string, action: string, onAction: () => void) {
    Row() {
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink'))
        .layoutWeight(1)
      Text(action)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.brand'))
        .onClick(() => {
          onAction();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 10 })
  }

  @Builder
  StatusCircle(item: StatusItem) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 62, height: 62 })
          .fill($r('app.color.brand_soft'))
        Avatar({ label: item.name, seed: item.name, avatarSize: 52, ring: !item.viewed })
      }
      Text(item.name.split(' ')[0])
        .fontSize(12)
        .fontColor($r('app.color.ink'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(68)
        .textAlign(TextAlign.Center)
    }
    .width(76)
    .onClick(() => {
      this.onViewStatus(item);
    })
  }

  build() {
    Scroll() {
      Column() {
        this.SectionHeader('Status', this.myStatus ? 'My status' : 'Add', () => {
          this.onComposeStatus();
        })

        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Avatar({ label: 'You', seed: 'me', avatarSize: 52, ring: false })
            Circle({ width: 20, height: 20 })
              .fill($r('app.color.brand'))
              .border({ width: 2, color: $r('app.color.bg_page') })
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(11)
              .fontColor([$r('app.color.brand_text')])
              .position({ x: 34, y: 34 })
          }
          .width(52)
          .height(52)
          .onClick(() => {
            this.onComposeStatus();
          })

          Column({ space: 3 }) {
            Text('My status')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
            Text(this.myStatus ? 'Tap to add another update' : 'Tap to add a status update')
              .fontSize(13)
              .fontColor($r('app.color.ink_subtle'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12 })

        if (this.statuses.length > 0) {
          this.SectionHeader('Recent updates', '', () => {
          })
          Scroll() {
            Row({ space: 10 }) {
              ForEach(this.statuses, (item: StatusItem) => {
                this.StatusCircle(item)
              }, (item: StatusItem) => item.id)
            }
            .padding({ left: 16, right: 16 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }

        this.SectionHeader('Channels', 'Discover', () => {
          this.onFindChannels();
        })

        if (this.channels.length === 0) {
          Column({ space: 6 }) {
            Text('No channels yet')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
            Text('Find channels to follow updates from people and brands.')
              .fontSize(13)
              .fontColor($r('app.color.ink_subtle'))
          }
          .width('100%')
          .padding(16)
        } else {
          Column() {
            ForEach(this.channels, (channel: ChannelItem) => {
              Row({ space: 12 }) {
                Stack({ alignContent: Alignment.Center }) {
                  Circle({ width: 48, height: 48 })
                    .fill($r('app.color.brand_soft'))
                  SymbolGlyph($r('sys.symbol.rectangle_stack'))
                    .fontSize(22)
                    .fontColor([$r('app.color.brand')])
                }
                .width(48)
                .height(48)

                Column({ space: 3 }) {
                  Text(channel.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.ink'))
                    .maxLines(1)
                  Text(channel.description)
                    .fontSize(13)
                    .fontColor($r('app.color.ink_subtle'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.followersText(channel.followers))
                    .fontSize(11)
                    .fontColor($r('app.color.ink_faded'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (channel.unread > 0) {
                  Text(String(channel.unread))
                    .fontSize(11)
                    .fontColor($r('app.color.brand_text'))
                    .width(20)
                    .height(20)
                    .textAlign(TextAlign.Center)
                    .backgroundColor($r('app.color.brand'))
                    .borderRadius(10)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .onClick(() => {
                this.onOpenChannel(channel);
              })
            }, (channel: ChannelItem) => channel.id)
          }
        }

        Blank().height(88)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  private followersText(count: number): string {
    if (count >= 1000000) {
      return (count / 1000000).toFixed(1) + 'M followers';
    }
    if (count >= 1000) {
      return (count / 1000).toFixed(1) + 'K followers';
    }
    return count + ' followers';
  }
}
