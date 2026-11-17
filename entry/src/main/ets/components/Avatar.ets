import { Theme } from '../styles/Theme';

/** Round initial avatar used across chats, updates, calls and settings. */
@Component
export struct Avatar {
  @Prop label: string = '';
  @Prop seed: string = '';
  @Prop avatarSize: number = 48;
  @Prop online: boolean = false;
  @Prop ring: boolean = false;
  @Prop imageUrl: string = '';

  private initials(): string {
    const source = this.label.trim();
    if (source.length === 0) {
      return '?';
    }
    const parts = source.split(' ');
    if (parts.length === 1) {
      return source.charAt(0).toUpperCase();
    }
    return (parts[0].charAt(0) + parts[1].charAt(0)).toUpperCase();
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: this.avatarSize, height: this.avatarSize })
          .fill(Theme.avatarColor(this.seed.length > 0 ? this.seed : this.label))
        Text(this.initials())
          .fontSize(this.avatarSize * 0.36)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        if (this.imageUrl.length > 0) {
          Image(this.imageUrl)
            .width(this.avatarSize)
            .height(this.avatarSize)
            .borderRadius(this.avatarSize / 2)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(this.avatarSize)
      .height(this.avatarSize)
      .borderRadius(this.avatarSize / 2)
      .border({
        width: this.ring ? 2.5 : 0,
        color: this.ring ? $r('app.color.brand') : '#00000000'
      })

      if (this.online) {
        Circle({ width: this.avatarSize * 0.26, height: this.avatarSize * 0.26 })
          .fill($r('app.color.connected'))
          .border({ width: 2, color: $r('app.color.surface') })
      }
    }
    .width(this.avatarSize)
    .height(this.avatarSize)
  }
}
