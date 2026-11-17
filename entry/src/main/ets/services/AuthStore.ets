/** Persistent OAuth session for the WhatsApp API. Empty token = signed out. */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'WhatsAppAuth';
const DOMAIN = 0x0000;
const STORE = 'whatisit_auth';

export class AuthStore {
  private token: string = '';
  private userId: string = '';
  private userName: string = '';
  private loaded: boolean = false;

  async load(context: common.Context): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(context, STORE);
      this.token = String(await prefs.get('access_token', ''));
      this.userId = String(await prefs.get('user_id', ''));
      this.userName = String(await prefs.get('user_name', ''));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(e));
    }
    this.loaded = true;
  }

  isLoaded(): boolean {
    return this.loaded;
  }

  isSignedIn(): boolean {
    return this.token.length > 0;
  }

  getToken(): string {
    return this.token;
  }

  getUserId(): string {
    return this.userId;
  }

  getUserName(): string {
    return this.userName;
  }

  async save(context: common.Context, token: string, userId: string, userName: string): Promise<void> {
    this.token = token.trim();
    this.userId = userId;
    this.userName = userName;
    await this.persist(context);
  }

  async signOut(context: common.Context): Promise<void> {
    this.token = '';
    this.userId = '';
    this.userName = '';
    await this.persist(context);
  }

  private async persist(context: common.Context): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(context, STORE);
      await prefs.put('access_token', this.token);
      await prefs.put('user_id', this.userId);
      await prefs.put('user_name', this.userName);
      await prefs.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'persist failed: %{public}s', JSON.stringify(e));
    }
  }
}

export const authStore: AuthStore = new AuthStore();
