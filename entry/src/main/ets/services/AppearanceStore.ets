/**
 * AppearanceStore — system / light / dark preference. The color mode is applied
 * through ApplicationContext so resource-qualified dark colors update.
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export const DISPLAY_MODE_SYSTEM: string = 'system';
export const DISPLAY_MODE_LIGHT: string = 'light';
export const DISPLAY_MODE_DARK: string = 'dark';

export class AppearanceStore {
  private static readonly STORE_NAME: string = 'whatisit_appearance';
  private static readonly MODE_KEY: string = 'display_mode';

  load(context: common.Context): string {
    try {
      const options: preferences.Options = { name: AppearanceStore.STORE_NAME };
      const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
      const mode: string = store.getSync(AppearanceStore.MODE_KEY, DISPLAY_MODE_SYSTEM) as string;
      return this.isValid(mode) ? mode : DISPLAY_MODE_SYSTEM;
    } catch (error) {
      return DISPLAY_MODE_SYSTEM;
    }
  }

  save(context: common.Context, mode: string): void {
    try {
      const options: preferences.Options = { name: AppearanceStore.STORE_NAME };
      const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
      store.putSync(AppearanceStore.MODE_KEY, mode);
      store.flushSync();
    } catch (error) {
      // preference write is best-effort
    }
  }

  colorMode(mode: string): ConfigurationConstant.ColorMode {
    if (mode === DISPLAY_MODE_LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    if (mode === DISPLAY_MODE_DARK) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  private isValid(mode: string): boolean {
    return mode === DISPLAY_MODE_SYSTEM || mode === DISPLAY_MODE_LIGHT || mode === DISPLAY_MODE_DARK;
  }
}
