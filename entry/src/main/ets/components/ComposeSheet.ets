/** Floating compose menu. Options depend on the active tab. */
@Component
export struct ComposeSheet {
  @Prop tab: number = 0;
  onClose: () => void = () => {
  };
  onAction: (action: string) => void = () => {
  };

  private title(): string {
    if (this.tab === 1) {
      return 'New update';
    }
    if (this.tab === 2) {
      return 'New call';
    }
    if (this.tab === 3) {
      return 'New community';
    }
    if (this.tab === 4) {
      return 'Quick action';
    }
    return 'New chat';
  }

  @Builder
  Option(icon: Resource, title: string, subtitle: string, action: string) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 44, height: 44 })
          .fill($r('app.color.brand_soft'))
        SymbolGlyph(icon)
          .fontSize(21)
          .fontColor([$r('app.color.brand')])
      }
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink'))
      Text(subtitle)
        .fontSize(11)
        .fontColor($r('app.color.ink_subtle'))
        .maxLines(2)
        .textAlign(TextAlign.Center)
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12, left: 8, right: 8 })
    .backgroundColor($r('app.color.surface_subtle'))
    .borderRadius(14)
    .onClick(() => {
      this.onAction(action);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.onClose();
        })

      Column({ space: 12 }) {
        Row() {
          Text(this.title())
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

        if (this.tab === 0) {
          Row({ space: 12 }) {
            this.Option($r('sys.symbol.message'), 'New chat', 'Start a conversation', 'new-chat')
            this.Option($r('sys.symbol.person_2'), 'New group', 'Bring people together', 'new-group')
          }
          .width('100%')
          Row({ space: 12 }) {
            this.Option($r('sys.symbol.rectangle_stack'), 'New channel', 'Broadcast to followers', 'new-channel')
            this.Option($r('sys.symbol.phone'), 'Linked device', 'Scan a QR or use a number', 'link')
          }
          .width('100%')
        } else if (this.tab === 1) {
          Row({ space: 12 }) {
            this.Option($r('sys.symbol.square_and_pencil'), 'Text status', 'Share a text update', 'status-text')
            this.Option($r('sys.symbol.camera'), 'Photo status', 'Share a photo', 'status-photo')
          }
          .width('100%')
          Row({ space: 12 }) {
            this.Option($r('sys.symbol.rectangle_stack'), 'Channel update', 'Post to a channel', 'channel-update')
            this.Option($r('sys.symbol.person_2'), 'Find channels', 'Discover people and brands', 'find-channels')
          }
          .width('100%')
        } else if (this.tab === 2) {
          Row({ space: 12 }) {
            this.Option($r('sys.symbol.phone'), 'Voice call', 'Start a WhatsApp voice call', 'voice-call')
            this.Option($r('sys.symbol.video'), 'Video call', 'Start a WhatsApp video call', 'video-call')
          }
          .width('100%')
        } else if (this.tab === 3) {
          Row({ space: 12 }) {
            this.Option($r('sys.symbol.plus'), 'New community', 'Create a home for your groups', 'new-community')
            this.Option($r('sys.symbol.magnifyingglass'), 'Discover', 'Find communities to join', 'find-communities')
          }
          .width('100%')
        } else {
          Row({ space: 12 }) {
            this.Option($r('sys.symbol.square_and_pencil'), 'Edit profile', 'Name, photo and about', 'edit-profile')
            this.Option($r('sys.symbol.rectangle_stack'), 'Appearance', 'Light, dark or system', 'appearance')
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 28 })
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .onClick(() => {
        // consume taps on the card
      })
    }
    .width('100%')
    .height('100%')
  }
}
