/** Floating WhatsApp compose action. Sits above the tab bar / safe area. */
@Component
export struct FloatingCompose {
  @Prop bottomInset: number = 76;
  @Prop icon: Resource = $r('sys.symbol.square_and_pencil');
  onTap: () => void = () => {
  };

  @State pressed: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: 56, height: 56 })
        .fill($r('app.color.brand'))
        .shadow({ radius: 14, color: '#3325D366', offsetY: 6 })
      SymbolGlyph(this.icon)
        .fontSize(23)
        .fontColor([$r('app.color.brand_text')])
    }
    .width(56)
    .height(56)
    .scale({ x: this.pressed ? 0.92 : 1, y: this.pressed ? 0.92 : 1 })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onTap();
    })
    .margin({ right: 18, bottom: this.bottomInset })
  }
}
