/** Per-install WhatsApp developer configuration. Only the public Client ID is stored. */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class WhatsAppOAuthConfig {
  clientId: string = '';

  constructor(clientId: string) {
    this.clientId = clientId;
  }
}

export class OAuthConfigStore {
  private static readonly STORE_NAME: string = 'whatisit_oauth_config';
  private static readonly CLIENT_ID_KEY: string = 'whatsapp_client_id';

  load(context: common.Context): WhatsAppOAuthConfig {
    try {
      const options: preferences.Options = { name: OAuthConfigStore.STORE_NAME };
      const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
      const id: string = store.getSync(OAuthConfigStore.CLIENT_ID_KEY, '') as string;
      return new WhatsAppOAuthConfig(id.trim());
    } catch (error) {
      return new WhatsAppOAuthConfig('');
    }
  }

  save(context: common.Context, clientId: string): boolean {
    try {
      const options: preferences.Options = { name: OAuthConfigStore.STORE_NAME };
      const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
      store.putSync(OAuthConfigStore.CLIENT_ID_KEY, clientId.trim());
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
