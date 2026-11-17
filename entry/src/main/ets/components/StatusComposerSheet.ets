/** Text status composer. */
@Component
export struct StatusComposerSheet {
  onClose: () => void = () => {
  };
  onPost: (text: string) => void = () => {
  };
  @State draft: string = '';
  @State posting: boolean = false;

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
          Text('New status')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink'))
            .layoutWeight(1)
          Text('Post')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.draft.trim().length > 0 ? $r('app.color.brand') : $r('app.color.ink_faded'))
            .onClick(() => {
              const text = this.draft.trim();
              if (text.length === 0 || this.posting) {
                return;
              }
              this.posting = true;
              this.onPost(text);
              this.posting = false;
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          Circle({ width: 42, height: 42 })
            .fill($r('app.color.brand'))
          Text('My status')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.person_2'))
            .fontSize(18)
            .fontColor([$r('app.color.ink_subtle')])
        }
        .width('100%')

        TextArea({ placeholder: 'Type a status update…', text: this.draft })
          .width('100%')
          .height(160)
          .fontSize(18)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(14)
          .onChange((value: string) => {
            this.draft = value;
          })

        Text('Visible to your contacts for 24 hours.')
          .fontSize(11)
          .fontColor($r('app.color.ink_faded'))
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
