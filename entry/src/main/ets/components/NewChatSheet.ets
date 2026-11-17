/** Start a new 1:1 conversation by name or phone number. */
@Component
export struct NewChatSheet {
  onClose: () => void = () => {
  };
  onStart: (value: string) => void = () => {
  };
  @State value: string = '';

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
          Text('New chat')
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

        Text('Enter a name or a phone number. In preview mode the conversation is created locally; with a linked device it opens the real chat.')
          .fontSize(12)
          .fontColor($r('app.color.ink_subtle'))
          .lineHeight(18)

        TextInput({ text: this.value, placeholder: 'Name or +44 7700 900123' })
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(12)
          .onChange((value: string) => {
            this.value = value;
          })

        Button('Start chat')
          .width('100%')
          .height(42)
          .fontSize(14)
          .fontColor($r('app.color.brand_text'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(21)
          .enabled(this.value.trim().length > 0)
          .onClick(() => {
            const text = this.value.trim();
            if (text.length > 0) {
              this.onStart(text);
            }
          })
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
