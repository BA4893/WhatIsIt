/** Window classes shared by the phone, tablet and 2-in-1 layouts. */
export class ResponsiveLayout {
  static readonly BREAKPOINT_SM: string = 'sm';
  static readonly BREAKPOINT_MD: string = 'md';
  static readonly BREAKPOINT_LG: string = 'lg';
  static readonly BREAKPOINT_XL: string = 'xl';

  static breakpointForWidth(widthVp: number): string {
    if (widthVp < 600) {
      return ResponsiveLayout.BREAKPOINT_SM;
    }
    if (widthVp < 840) {
      return ResponsiveLayout.BREAKPOINT_MD;
    }
    if (widthVp < 1200) {
      return ResponsiveLayout.BREAKPOINT_LG;
    }
    return ResponsiveLayout.BREAKPOINT_XL;
  }

  static isWide(breakpoint: string): boolean {
    return breakpoint === ResponsiveLayout.BREAKPOINT_MD ||
      breakpoint === ResponsiveLayout.BREAKPOINT_LG ||
      breakpoint === ResponsiveLayout.BREAKPOINT_XL;
  }

  static isLarge(breakpoint: string): boolean {
    return breakpoint === ResponsiveLayout.BREAKPOINT_LG ||
      breakpoint === ResponsiveLayout.BREAKPOINT_XL;
  }
}
