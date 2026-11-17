/**
 * Short-lived OAuth transaction state. The PKCE verifier and state must survive
 * the trip through the system browser, but never leave the app's private
 * preferences. The callback URI is stashed here by EntryAbility because the
 * app may already be running when the browser redirects back.
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'WhatsAppOAuthFlow';
const DOMAIN = 0x0000;
const STORE = 'whatisit_oauth_flow';

export interface OAuthPendingTransaction {
  verifier: string;
  state: string;
  clientId: string;
}

export class OAuthFlowStore {
  async save(context: common.Context, verifier: string, state: string, clientId: string): Promise<boolean> {
    try {
      const prefs = await preferences.getPreferences(context, STORE);
      await prefs.put('verifier', verifier);
      await prefs.put('state', state);
      await prefs.put('client_id', clientId);
      await prefs.flush();
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  async load(context: common.Context): Promise<OAuthPendingTransaction> {
    try {
      const prefs = await preferences.getPreferences(context, STORE);
      return {
        verifier: String(await prefs.get('verifier', '')),
        state: String(await prefs.get('state', '')),
        clientId: String(await prefs.get('client_id', ''))
      } as OAuthPendingTransaction;
    } catch (e) {
      return { verifier: '', state: '', clientId: '' } as OAuthPendingTransaction;
    }
  }

  async clear(context: common.Context): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(context, STORE);
      await prefs.put('verifier', '');
      await prefs.put('state', '');
      await prefs.put('client_id', '');
      await prefs.flush();
    } catch (e) {
      // ignore
    }
  }

  async saveCallback(context: common.Context, uri: string): Promise<boolean> {
    try {
      const prefs = await preferences.getPreferences(context, STORE);
      await prefs.put('callback_uri', uri);
      await prefs.flush();
      return true;
    } catch (e) {
      return false;
    }
  }

  async takeCallback(context: common.Context): Promise<string> {
    try {
      const prefs = await preferences.getPreferences(context, STORE);
      const uri = String(await prefs.get('callback_uri', ''));
      await prefs.put('callback_uri', '');
      await prefs.flush();
      return uri;
    } catch (e) {
      return '';
    }
  }
}

export const oauthFlowStore: OAuthFlowStore = new OAuthFlowStore();
