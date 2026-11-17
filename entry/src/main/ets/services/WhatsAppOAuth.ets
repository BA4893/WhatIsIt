/**
 * OAuth 2.0 Authorization Code + PKCE client for the WhatsApp developer app.
 *
 * Only the public Client ID is stored on-device. The authorization page is
 * opened in the system browser; the app receives `whatisit://callback` and
 * exchanges the code with the PKCE verifier. The provider endpoints are Meta's
 * public OAuth endpoints; a compatible provider can be substituted by editing
 * the constants below.
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'WhatsAppOAuth';
const DOMAIN = 0x0000;

export const OAUTH_REDIRECT_URI: string = 'whatisit://callback';
const AUTH_ENDPOINT: string = 'https://www.facebook.com/v21.0/dialog/oauth';
const TOKEN_ENDPOINT: string = 'https://graph.facebook.com/v21.0/oauth/access_token';
const PROFILE_ENDPOINT: string = 'https://graph.facebook.com/v21.0/me';
const SCOPES: string = 'whatsapp_business_messaging,whatsapp_business_management';

export class OAuthResult {
  ok: boolean = false;
  accessToken: string = '';
  errorText: string = '';
}

export class OAuthProfile {
  id: string = '';
  name: string = '';
}

export class WhatsAppOAuth {
  static buildAuthorizeUrl(clientId: string, challenge: string, state: string): string {
    return AUTH_ENDPOINT +
      '?client_id=' + encodeURIComponent(clientId) +
      '&redirect_uri=' + encodeURIComponent(OAUTH_REDIRECT_URI) +
      '&response_type=code' +
      '&scope=' + encodeURIComponent(SCOPES) +
      '&code_challenge=' + encodeURIComponent(challenge) +
      '&code_challenge_method=S256' +
      '&state=' + encodeURIComponent(state);
  }

  async exchangeCode(clientId: string, code: string, verifier: string): Promise<OAuthResult> {
    const result = new OAuthResult();
    const url = TOKEN_ENDPOINT +
      '?client_id=' + encodeURIComponent(clientId) +
      '&redirect_uri=' + encodeURIComponent(OAUTH_REDIRECT_URI) +
      '&code=' + encodeURIComponent(code) +
      '&code_verifier=' + encodeURIComponent(verifier);
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 12000,
        readTimeout: 15000,
        header: { 'Accept': 'application/json' }
      } as http.HttpRequestOptions);
      const raw = resp.result;
      if (typeof raw !== 'string') {
        result.errorText = 'The sign-in server returned an unreadable response.';
        return result;
      }
      const body = JSON.parse(raw) as Record<string, Object>;
      const token = body['access_token'];
      if (typeof token === 'string' && (token as string).length > 0) {
        result.ok = true;
        result.accessToken = token as string;
        return result;
      }
      result.errorText = this.readError(body);
      return result;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'exchange failed: %{public}s', JSON.stringify(e));
      result.errorText = 'Could not reach the sign-in server. Check your connection.';
      return result;
    } finally {
      req.destroy();
    }
  }

  async profile(token: string): Promise<OAuthProfile | null> {
    const req = http.createHttp();
    try {
      const url = PROFILE_ENDPOINT + '?fields=id,name&access_token=' + encodeURIComponent(token);
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 12000,
        header: { 'Accept': 'application/json' }
      } as http.HttpRequestOptions);
      const raw = resp.result;
      if (typeof raw !== 'string') {
        return null;
      }
      const body = JSON.parse(raw) as Record<string, Object>;
      const p = new OAuthProfile();
      p.id = typeof body['id'] === 'string' ? (body['id'] as string) : '';
      p.name = typeof body['name'] === 'string' ? (body['name'] as string) : '';
      return p;
    } catch (e) {
      return null;
    } finally {
      req.destroy();
    }
  }

  private readError(body: Record<string, Object>): string {
    const err = body['error'];
    if (err !== undefined && err !== null) {
      const detail = err as Record<string, Object>;
      if (typeof detail['message'] === 'string') {
        return detail['message'] as string;
      }
    }
    return 'Sign-in was not completed. Check the Client ID and the callback URI.';
  }
}

/** Parse one query parameter from a callback URL. */
export function queryParam(url: string, key: string): string {
  const q = url.indexOf('?');
  if (q < 0) {
    return '';
  }
  const parts = url.substring(q + 1).split('&');
  for (let i = 0; i < parts.length; i++) {
    const eq = parts[i].indexOf('=');
    if (eq > 0 && parts[i].substring(0, eq) === key) {
      return decodeURIComponent(parts[i].substring(eq + 1));
    }
  }
  return '';
}
