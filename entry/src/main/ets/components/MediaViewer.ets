/** Full-screen native image viewer for a cached WhatsApp Web image. */
@Component
export struct MediaViewer {
  src: string = '';
  onClose: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')

      if (this.src.length > 0) {
        Image(this.src)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      }

      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 36, height: 36 })
          .fill('#80000000')
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      }
      .width(44)
      .height(44)
      .margin({ top: 12, left: 12 })
      .onClick(() => {
        this.onClose();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
