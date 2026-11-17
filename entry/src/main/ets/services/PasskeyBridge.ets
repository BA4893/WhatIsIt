/**
 * PasskeyBridge — the no-server credential bridge client.
 *
 * ArkWeb cannot produce a WhatsApp WebAuthn assertion for this account. A small
 * agent on a PC with Chrome (where the passkey works) receives the
 * PublicKeyCredentialRequestOptions over the LAN, asks Chrome to sign the
 * challenge, and returns the assertion. The private key never leaves Chrome.
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'PasskeyBridge';
const DOMAIN = 0x0000;
const STORE = 'whatisit_passkey_bridge';
const HOST_KEY = 'bridge_host';
const PORT_KEY = 'bridge_port';
const TOKEN_KEY = 'bridge_token';

export class PasskeyBridgeConfig {
  host: string = '';
  port: number = 18771;
  token: string = '';
}

export class PasskeyBridgeStore {
  load(context: common.Context): PasskeyBridgeConfig {
    const cfg = new PasskeyBridgeConfig();
    try {
      const options: preferences.Options = { name: STORE };
      const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
      cfg.host = String(store.getSync(HOST_KEY, ''));
      const port = parseInt(String(store.getSync(PORT_KEY, '18771')), 10);
      cfg.port = isFinite(port) && port > 0 ? port : 18771;
      cfg.token = String(store.getSync(TOKEN_KEY, ''));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bridge config load failed: %{public}s', JSON.stringify(e));
    }
    return cfg;
  }

  save(context: common.Context, cfg: PasskeyBridgeConfig): boolean {
    try {
      const options: preferences.Options = { name: STORE };
      const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
      store.putSync(HOST_KEY, cfg.host.trim());
      store.putSync(PORT_KEY, String(cfg.port));
      store.putSync(TOKEN_KEY, cfg.token.trim());
      store.flushSync();
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bridge config save failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }
}

export class PasskeyBridgeClient {
  private cfg: PasskeyBridgeConfig = new PasskeyBridgeConfig();

  configure(cfg: PasskeyBridgeConfig): void {
    this.cfg = cfg;
  }

  getConfig(): PasskeyBridgeConfig {
    return this.cfg;
  }

  isConfigured(): boolean {
    return this.cfg.host.trim().length > 0;
  }

  /** Ask the PC bridge for an assertion. optionsJson is the serialized publicKey options. */
  async assert(optionsJson: string): Promise<string> {
    if (!this.isConfigured()) {
      throw new Error('Passkey bridge is not configured. Open Settings → Passkey bridge.');
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(optionsJson) as Record<string, Object>;
    } catch (e) {
      throw new Error('The passkey request could not be read.');
    }
    const body = JSON.stringify({ options: parsed });
    const req = http.createHttp();
    try {
      const resp = await req.request(this.baseUrl() + '/assert', {
        method: http.RequestMethod.POST,
        header: this.headers(),
        extraData: body,
        connectTimeout: 5000,
        readTimeout: 180000
      } as http.HttpRequestOptions);
      const raw = resp.result;
      if (typeof raw !== 'string') {
        throw new Error('The passkey bridge returned an unreadable response.');
      }
      if (resp.responseCode !== 200) {
        throw new Error(this.errorFromBody(raw));
      }
      const env = JSON.parse(raw) as Record<string, Object>;
      if (env['ok'] !== true) {
        throw new Error(typeof env['error'] === 'string' ? (env['error'] as string) : 'Passkey bridge failed.');
      }
      const assertion = env['assertion'];
      if (assertion === undefined || assertion === null) {
        throw new Error('The passkey bridge returned no assertion.');
      }
      return JSON.stringify(assertion);
    } catch (e) {
      const message = (e as Error)?.message;
      hilog.warn(DOMAIN, TAG, 'assertion failed: %{public}s', message === undefined ? '' : message);
      throw new Error(message !== undefined && message.length > 0 ? message : 'Could not reach the passkey bridge.');
    } finally {
      req.destroy();
    }
  }

  async health(): Promise<boolean> {
    if (!this.isConfigured()) {
      return false;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(this.baseUrl() + '/health', {
        method: http.RequestMethod.GET,
        header: this.headers(),
        connectTimeout: 3000,
        readTimeout: 3000
      } as http.HttpRequestOptions);
      return resp.responseCode === 200;
    } catch (e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  private baseUrl(): string {
    return 'http://' + this.cfg.host.trim() + ':' + this.cfg.port;
  }

  private headers(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.cfg.token.length > 0) {
      h['Authorization'] = 'Bearer ' + this.cfg.token;
    }
    return h;
  }

  private errorFromBody(raw: string): string {
    try {
      const body = JSON.parse(raw) as Record<string, Object>;
      if (typeof body['error'] === 'string') {
        return body['error'] as string;
      }
    } catch (e) {
      // ignore
    }
    return 'The passkey bridge rejected the request.';
  }
}

export const passkeyBridge: PasskeyBridgeClient = new PasskeyBridgeClient();
export const passkeyBridgeStore: PasskeyBridgeStore = new PasskeyBridgeStore();
