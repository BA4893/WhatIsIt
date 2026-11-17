import { CommunityItem } from '../models/WhatsAppModels';

/** Communities — a design-complete shell with sample communities. */
@Component
export struct CommunitiesPane {
  @Prop communities: CommunityItem[] = [];
  onToggleJoin: (id: string) => void = () => {
  };
  onDiscover: () => void = () => {
  };

  build() {
    Scroll() {
      Column() {
        Column({ space: 14 }) {
          Row() {
            Column({ space: 4 }) {
              Text('Communities')
                .fontSize(26)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.ink'))
              Text('Bring your groups together')
                .fontSize(13)
                .fontColor($r('app.color.ink_subtle'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.person_2'))
              .fontSize(26)
              .fontColor([$r('app.color.brand')])
          }
          .width('100%')

          Text('A community connects related groups and gives announcements a home. Create one for your neighbourhood, team or club.')
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
            .lineHeight(19)

          Row({ space: 10 }) {
            Button('Create community')
              .layoutWeight(1)
              .height(40)
              .fontSize(14)
              .fontColor($r('app.color.brand_text'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(20)
              .onClick(() => {
                this.onDiscover();
              })
            Button('Discover')
              .layoutWeight(1)
              .height(40)
              .fontSize(14)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.surface'))
              .border({ width: 1, color: $r('app.color.brand') })
              .borderRadius(20)
              .onClick(() => {
                this.onDiscover();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 16 })
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .margin({ left: 16, right: 16, top: 12 })

        Text('YOUR COMMUNITIES')
          .width('100%')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink_faded'))
          .letterSpacing(0.6)
          .padding({ left: 20, right: 16, top: 18, bottom: 8 })

        if (this.communities.length === 0) {
          Column({ space: 6 }) {
            Text('No communities yet')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
            Text('Communities you join will appear here.')
              .fontSize(13)
              .fontColor($r('app.color.ink_subtle'))
          }
          .width('100%')
          .padding(20)
        } else {
          ForEach(this.communities, (community: CommunityItem) => {
            Row({ space: 12 }) {
              Stack({ alignContent: Alignment.Center }) {
                Circle({ width: 52, height: 52 })
                  .fill($r('app.color.brand_soft'))
                SymbolGlyph($r('sys.symbol.person_2_fill'))
                  .fontSize(23)
                  .fontColor([$r('app.color.brand')])
              }
              .width(52)
              .height(52)

              Column({ space: 3 }) {
                Row({ space: 6 }) {
                  Text(community.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.ink'))
                    .maxLines(1)
                  if (community.unread > 0) {
                    Text(String(community.unread))
                      .fontSize(10)
                      .fontColor($r('app.color.brand_text'))
                      .padding({ left: 5, right: 5 })
                      .backgroundColor($r('app.color.brand'))
                      .borderRadius(8)
                  }
                }
                Text(community.description)
                  .fontSize(12)
                  .fontColor($r('app.color.ink_subtle'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.membersText(community.members) + ' members')
                  .fontSize(11)
                  .fontColor($r('app.color.ink_faded'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(community.joined ? 'Open' : 'Join')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(community.joined ? $r('app.color.ink_subtle') : $r('app.color.brand'))
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(community.joined ? $r('app.color.surface_subtle') : $r('app.color.brand_soft'))
                .borderRadius(16)
                .onClick(() => {
                  this.onToggleJoin(community.id);
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          }, (community: CommunityItem) => community.id)
        }
        Blank().height(88)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  private membersText(count: number): string {
    if (count >= 1000) {
      return (count / 1000).toFixed(1) + 'K';
    }
    return String(count);
  }
}
