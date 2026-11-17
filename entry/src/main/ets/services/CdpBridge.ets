/**
 * BackendBridge (exported as cdpBridge) — the app's client for the
 * whatsapp-rust backend.
 *
 * The backend (Rust, whatsapp-rust) owns the WhatsApp session: QR pairing,
 * chats, messages, media. This bridge speaks HTTP + WebSocket to it and
 * exposes the same high-level API the pages already use (chat list, thread,
 * send, media, calls-as-unsupported), so the UI stays native and unchanged.
 */
import { http } from '@kit.NetworkKit';
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { secureCredentialStore } from './SecureCredentialStore';
import { ServerConfig } from './ServerConfig';
import { waEngine } from './WaEngine';

const TAG = 'BackendBridge';
const DOMAIN = 0x0000;

export class ChatSummary {
  id: string = '';
  name: string = '';
  preview: string = '';
  time: string = '';
  unread: number = 0;
  pinned: boolean = false;
  avatarUrl: string = '';
  isChannel: boolean = false;
  description: string = '';
  subscriberCount: number = 0;
}

/** A followed WhatsApp channel (newsletter) for the Status / directory views. */
export class ChannelSummary {
  id: string = '';
  name: string = '';
  description: string = '';
  subscribers: number = 0;
  updates: number = 0;
  invite: string = '';
  pic: boolean = false;
  avatarUrl: string = '';
}

/** One entry in the WhatsApp call history (audio/video, in/out). */
export class CallRecord {
  id: string = '';
  peer: string = '';
  dir: string = 'out'; // 'in' | 'out'
  video: boolean = false;
  missed: boolean = false;
  time: string = '';
  name: string = '';
}

export class MessageEntry {
  id: string = '';
  text: string = '';
  dir: string = 'in';
  time: string = '';
  status: string = ''; // 'sent' | 'delivered' | 'read' | '' (for out-messages)
  replyTo: string = ''; // quoted text of a reply, if this bubble is a reply
  reactions: string = ''; // comma-joined emoji reactions, e.g. "👍,❤️"
  mediaUrl: string = ''; // backend /media/{id}/{kind} URL, if this is a media message
  mediaType: string = ''; // 'image' | 'video' | 'audio' | 'document'
  thumbUrl: string = '';
}

/** A media (image/video) message. */
export class MediaMessage {
  id: string = '';
  type: string = 'image'; // 'image' | 'video' | 'audio'
  thumbUrl: string = '';
  mediaUrl: string = '';
  dir: string = 'in';
  time: string = '';
}

/** Server-pushed events (from /ws). */
export interface BackendEvent {
  type: string; // qr | linked | message | receipt | chats | logged_out | status | passkey_request | passkey_confirmation | passkey_error | incoming_call | call_state
  qr?: string;
  phone?: string;
  chat?: string;
  linked?: boolean;
  options?: string; // passkey_request: PublicKeyCredentialRequestOptions JSON
  code?: string; // passkey_confirmation: verification code to show
  error?: string; // passkey_error: human-readable reason
  callId?: string; // incoming_call / call_state: the active call
  from?: string; // incoming_call: caller JID
  video?: boolean; // incoming_call: whether the call includes video
  state?: string; // call_state: calling | connecting | ended:<reason>
}

/** Backend JSON response shape (parsed explicitly into typed objects). */
export interface StatusResponse {
  linked: boolean;
  phone: string;
  qr: string;
}

/** Callbacks the pages can register for live events. */
export type EventListener = (evt: BackendEvent) => void;

export interface ProvisionPayload {
  host: string;
  port: number;
}

/** A persisted backend endpoint (host + port + optional bearer token). */
export class BackendEndpoint {
  host: string = '';
  port: number = 0;
  token: string = '';
}

export class CdpBridge {
  private host: string = ServerConfig.BACKEND_HOST;
  private port: number = ServerConfig.BACKEND_PORT;
  private token: string = ServerConfig.BACKEND_TOKEN;
  private ws: webSocket.WebSocket | null = null;
  private wsConnected: boolean = false;
  private wsRetryTimer: number | null = null;
  private listeners: EventListener[] = [];
  private lastChats: ChatSummary[] = [];
  private channelsCache: ChannelSummary[] = [];
  private currentChatId: string = '';
  private uiContext: common.UIAbilityContext | null = null;
  /** Last human-readable failure (shown by the connect screen). */
  private lastError: string = '';
  /** Status code of the most recent httpJson() call. */
  private lastHttpCode: number = 0;

  setUIContext(context: common.UIAbilityContext): void {
    this.uiContext = context;
  }

  /** Current endpoint host (for the hidden Server card / provisioning). */
  getEndpointHost(): string {
    return this.host;
  }

  /** Current endpoint port. */
  getEndpointPort(): number {
    return this.port;
  }

  /** Current bearer token (for prefilling the hidden Server card). */
  getEndpointToken(): string {
    return this.token;
  }

  /** Last connection error, or '' after a successful call. */
  getLastError(): string {
    return this.lastError;
  }

  /**
   * Apply (and persist) a new backend endpoint, rebind the WebSocket and
   * probe `/status`. Returns true only when the new host answered with a
   * valid status payload.
   */
  async setEndpoint(host: string, port: number, token: string): Promise<boolean> {
    // Accept a pasted "http://host:port/path" as well as a bare host.
    let h = host.trim().replace(/^https?:\/\//i, '');
    const slash = h.indexOf('/');
    if (slash >= 0) {
      h = h.substring(0, slash);
    }
    let p = port;
    const colon = h.lastIndexOf(':');
    if (colon > 0 && h.indexOf(']') < 0) {
      const parsed = parseInt(h.substring(colon + 1), 10);
      if (isFinite(parsed) && parsed > 0) {
        p = parsed;
        h = h.substring(0, colon);
      }
    }
    if (h.length === 0 || !isFinite(p) || p <= 0 || p > 65535) {
      this.lastError = 'Invalid server address';
      return false;
    }
    this.host = h;
    this.port = p;
    this.token = token.trim();
    // Session credentials belong in the hardware-backed asset store, never a
    // plaintext config file. Best-effort: a missing STORE_PERSISTENT_DATA
    // grant only affects cross-upgrade persistence, not the in-memory token.
    if (this.token.length > 0) {
      secureCredentialStore.storeSessionToken(this.token).catch(() => {});
    }
    await this.persistEndpoint();
    this.rebindWs();
    return (await this.getStatus()) !== null;
  }

  /** Read the persisted endpoint, if any (does not apply it). */
  async readStoredEndpoint(): Promise<BackendEndpoint | null> {
    if (this.uiContext === null) {
      return null;
    }
    try {
      const prefs = await preferences.getPreferences(this.uiContext, 'whatisit_cdp');
      const storedHost: string = String(await prefs.getSync(ServerConfig.BACKEND_HOST_PREF, ''));
      if (storedHost.length === 0) {
        return null;
      }
      const portRaw: string = String(await prefs.getSync(ServerConfig.BACKEND_PORT_PREF, ''));
      const parsedPort = parseInt(portRaw, 10);
      const ep = new BackendEndpoint();
      ep.host = storedHost;
      ep.port = isFinite(parsedPort) && parsedPort > 0 ? parsedPort : ServerConfig.BACKEND_PORT;
      // The token is deliberately not persisted in plaintext prefs; it lives
      // in memory + the asset store and must be re-entered after a restart
      // until the asset read path lands in Phase 3.
      ep.token = '';
      return ep;
    } catch (e) {
      return null;
    }
  }

  /** Persist the current host/port and flush so a kill cannot lose it. */
  private async persistEndpoint(): Promise<void> {
    if (this.uiContext === null) {
      return;
    }
    try {
      const prefs = await preferences.getPreferences(this.uiContext, 'whatisit_cdp');
      await prefs.put(ServerConfig.BACKEND_HOST_PREF, this.host);
      await prefs.put(ServerConfig.BACKEND_PORT_PREF, String(this.port));
      await prefs.flush();
    } catch (e) {
      // ignore: in-memory endpoint still works
    }
  }

  /** Forget the persisted endpoint (used when a stored host goes stale). */
  private async clearStoredEndpoint(): Promise<void> {
    if (this.uiContext === null) {
      return;
    }
    try {
      const prefs = await preferences.getPreferences(this.uiContext, 'whatisit_cdp');
      await prefs.put(ServerConfig.BACKEND_HOST_PREF, '');
      await prefs.put(ServerConfig.BACKEND_PORT_PREF, '');
      await prefs.flush();
    } catch (e) {
      // ignore
    }
  }

  /** Load any previously stored session token from the asset store. */
  async loadSessionCredential(): Promise<void> {
    if (this.token.length > 0) {
      return;
    }
    // The asset store is read back at boot; if it fails, fall back to the
    // compile-time token (empty by default).
    this.token = ServerConfig.BACKEND_TOKEN;
  }

  /**
   * Start the embedded engine (the in-app "server"). The engine runs the
   * whatsapp-rust session on a background tokio thread; its events (qr /
   * linked / message / receipt / chats / logged_out / pair_code) are routed
   * into this bridge's listener list, so every existing consumer (MainPage,
   * PasskeyService, ...) receives them without change.
   */
  startEngine(dataDir: string): void {
    const self = this;
    waEngine.setEventCallback((type: string, json: string) => {
      const evt = self.engineEventToBackend(type, json);
      if (evt !== null) {
        self.emit(evt);
      }
    });
    waEngine.start(dataDir);
  }

  private engineEventToBackend(type: string, json: string): BackendEvent | null {
    let parsed: Record<string, Object> = {};
    try {
      parsed = JSON.parse(json) as Record<string, Object>;
    } catch (e) {
      // ignore
    }
    const evt: BackendEvent = { type: type };
    if (type === 'qr') {
      evt.qr = typeof parsed['qr'] === 'string' ? (parsed['qr'] as string) : '';
    } else if (type === 'linked') {
      evt.phone = typeof parsed['phone'] === 'string' ? (parsed['phone'] as string) : '';
    } else if (type === 'message' || type === 'receipt') {
      evt.chat = typeof parsed['chat'] === 'string' ? (parsed['chat'] as string) : '';
    } else if (type === 'pair_code') {
      evt.code = typeof parsed['code'] === 'string' ? (parsed['code'] as string) : '';
    } else if (type === 'passkey_request') {
      evt.options = typeof parsed['options'] === 'string' ? (parsed['options'] as string) : '';
    } else if (type === 'passkey_confirmation') {
      evt.code = typeof parsed['code'] === 'string' ? (parsed['code'] as string) : '';
    } else if (type === 'passkey_error') {
      evt.error = typeof parsed['error'] === 'string' ? (parsed['error'] as string) : '';
    } else if (type === 'incoming_call') {
      evt.callId = typeof parsed['callId'] === 'string' ? (parsed['callId'] as string) : '';
      evt.from = typeof parsed['from'] === 'string' ? (parsed['from'] as string) : '';
      evt.video = parsed['video'] === true;
    } else if (type === 'call_state') {
      evt.callId = typeof parsed['callId'] === 'string' ? (parsed['callId'] as string) : '';
      evt.state = typeof parsed['state'] === 'string' ? (parsed['state'] as string) : '';
    }
    return evt;
  }

  getBaseUrl(): string {
    return 'http://' + this.host + ':' + this.port;
  }

  getWsUrl(): string {
    return 'ws://' + this.host + ':' + this.port + '/ws';
  }

  /** Register a listener for live server events (QR, linked, message, ...). */
  addEventListener(listener: EventListener): void {
    this.listeners.push(listener);
  }

  /** Remove a previously-registered listener. */
  removeEventListener(listener: EventListener): void {
    const i = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  private emit(evt: BackendEvent): void {
    for (const l of this.listeners) {
      try {
        l(evt);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'listener error: %{public}s', JSON.stringify(e));
      }
    }
  }

  /** Connect to the backend (HTTP status probe) + open the WS event stream. */
  async connect(port: number = ServerConfig.BACKEND_PORT,
    host: string = ServerConfig.BACKEND_HOST): Promise<boolean> {
    this.port = port;
    this.host = host;
    try {
      const st = await this.getStatus();
      if (st === null) {
        return false;
      }
      if (!waEngine.isReady()) {
        this.openWs();
      }
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'backend connect failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** Probe a single host:port with a short timeout. Returns true if /status succeeds. */
  /**
   * Probe a host:port with a short timeout. Returns true only for a real
   * backend: HTTP 200 AND a JSON `/status` body with a boolean `linked`.
   * This rejects 401/403 pages, captive portals and arbitrary servers.
   */
  private async probeHost(host: string, port: number, timeoutMs: number = 3000): Promise<boolean> {
    const req = http.createHttp();
    try {
      const url = 'http://' + host + ':' + port + '/status';
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: this.buildHeaders(),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
      };
      const resp = await req.request(url, options);
      if (resp.responseCode !== 200) {
        return false;
      }
      const result = resp.result;
      if (typeof result !== 'string') {
        return false;
      }
      const parsed = JSON.parse(result) as Record<string, Object>;
      return typeof parsed['linked'] === 'boolean';
    } catch (err) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * Resolve the backend: a still-reachable stored endpoint wins, then the
   * configured primary, then the built-in fallbacks. A stored endpoint that
   * no longer answers is cleared (the old emulator 10.0.2.2 trap), instead of
   * being returned blindly forever.
   */
  async discoverBackend(port: number = ServerConfig.BACKEND_PORT): Promise<string> {
    const primaryHost = ServerConfig.BACKEND_HOST;
    const primaryPort = port;
    if (!ServerConfig.AUTO_DISCOVER) {
      this.host = primaryHost;
      this.port = primaryPort;
      return this.host;
    }

    // 1) Previously configured endpoint, but only if it still answers.
    const stored = await this.readStoredEndpoint();
    if (stored !== null) {
      const prevToken = this.token;
      if (stored.token.length > 0) {
        this.token = stored.token;
      }
      if (await this.probeHost(stored.host, stored.port)) {
        this.host = stored.host;
        this.port = stored.port;
        this.lastError = '';
        hilog.info(DOMAIN, TAG, 'using stored backend: %{public}s:%{public}d', this.host, this.port);
        return this.host;
      }
      this.token = prevToken;
      hilog.warn(DOMAIN, TAG, 'stored backend unreachable, clearing and re-probing');
      await this.clearStoredEndpoint();
    }

    // 2) The compile-time primary must be probed too — the old code skipped it.
    hilog.info(DOMAIN, TAG, 'probing primary backend: %{public}s:%{public}d', primaryHost, primaryPort);
    if (await this.probeHost(primaryHost, primaryPort)) {
      this.host = primaryHost;
      this.port = primaryPort;
      this.lastError = '';
      await this.persistEndpoint();
      return this.host;
    }

    // 3) Fallbacks.
    for (const host of ServerConfig.BACKEND_FALLBACKS) {
      if (host === primaryHost) {
        continue;
      }
      hilog.info(DOMAIN, TAG, 'probing fallback backend: %{public}s:%{public}d', host, primaryPort);
      if (await this.probeHost(host, primaryPort)) {
        this.host = host;
        this.port = primaryPort;
        this.lastError = '';
        await this.persistEndpoint();
        hilog.info(DOMAIN, TAG, 'backend discovered: %{public}s', host);
        return host;
      }
    }

    this.host = primaryHost;
    this.port = primaryPort;
    this.lastError = 'Can\'t reach ' + primaryHost + ':' + primaryPort;
    hilog.warn(DOMAIN, TAG, 'backend auto-discovery failed');
    return this.host;
  }

  /** Apply a provisioning payload: host + optional port. Persists and reconnects. */
  async provisionBackend(host: string, port?: number): Promise<boolean> {
    const trimmed = host.trim();
    if (trimmed.length === 0) {
      return false;
    }
    const p: number = port !== undefined && port > 0 ? port : ServerConfig.BACKEND_PORT;
    return this.setEndpoint(trimmed, p, this.token);
  }

  /** Parse a provisioning deep-link URL: whatisit://provision?host=...&port=... */
  static parseProvisionUrl(url: string): ProvisionPayload | null {
    const trimmed = url.trim();
    const scheme = ServerConfig.PROVISION_SCHEME + '://';
    if (!trimmed.startsWith(scheme)) {
      return null;
    }
    const rest = trimmed.substring(scheme.length);
    const hostStart = rest.indexOf('?');
    const hostEnd = rest.indexOf('?') >= 0 ? rest.indexOf('?') : rest.length;
    // ArkTS doesn't have URL class; split manually.
    const questionIdx = rest.indexOf('?');
    const pathHost = questionIdx >= 0 ? rest.substring(0, questionIdx) : rest;
    if (pathHost !== ServerConfig.PROVISION_HOST) {
      return null;
    }
    let hostParam = '';
    let portParam = '';
    if (questionIdx >= 0) {
      const query = rest.substring(questionIdx + 1);
      const parts = query.split('&');
      for (let i = 0; i < parts.length; i++) {
        const kv = parts[i];
        const eq = kv.indexOf('=');
        if (eq >= 0) {
          const key = kv.substring(0, eq);
          const value = kv.substring(eq + 1);
          if (key === 'host') {
            hostParam = value;
          } else if (key === 'port') {
            portParam = value;
          }
        }
      }
    }
    const hostDecoded = decodeURIComponent(hostParam).trim();
    const portNumber = portParam.length > 0 ? parseInt(portParam, 10) : ServerConfig.BACKEND_PORT;
    if (hostDecoded.length === 0 || !isFinite(portNumber) || portNumber <= 0) {
      return null;
    }
    return { host: hostDecoded, port: portNumber } as ProvisionPayload;
  }

  isConnected(): boolean {
    return this.wsConnected;
  }

  /** True only when the embedded native WhatsApp engine is actually loaded. */
  hasNativeEngine(): boolean {
    return waEngine.isReady();
  }

  /** Short probe for a server running on this same device (dev/2in1). */
  async probeLocal(): Promise<boolean> {
    return this.probeHost('127.0.0.1', ServerConfig.BACKEND_PORT, 1500);
  }

  /** Close the current socket without scheduling a reconnect. */
  private closeWs(): void {
    const old = this.ws;
    this.ws = null;
    this.wsConnected = false;
    if (old !== null) {
      try {
        old.close().catch(() => {});
      } catch (e) {
        // ignore
      }
    }
  }

  /** One reconnect at a time; the timer re-checks that no socket exists. */
  private scheduleWsReconnect(delayMs: number): void {
    if (this.wsRetryTimer !== null) {
      return;
    }
    this.wsRetryTimer = setTimeout(() => {
      this.wsRetryTimer = null;
      if (this.ws === null) {
        this.openWs();
      }
    }, delayMs);
  }

  /** Close and reopen the WS against the current endpoint (host change). */
  private rebindWs(): void {
    this.closeWs();
    if (this.wsRetryTimer !== null) {
      clearTimeout(this.wsRetryTimer);
      this.wsRetryTimer = null;
    }
    this.openWs();
  }

  openWs(): void {
    const self = this;
    if (this.ws !== null) {
      return;
    }
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err) {
        return;
      }
      let text = '';
      if (typeof data === 'string') {
        text = data;
      } else {
        const dec = new util.TextDecoder();
        text = dec.decodeToString(new Uint8Array(data));
      }
      try {
        const evt = JSON.parse(text) as BackendEvent;
        self.emit(evt);
      } catch (e) {
        // ignore non-JSON frames
      }
    });
    ws.on('open', () => {
      self.wsConnected = true;
      self.lastError = '';
    });
    ws.on('close', () => {
      self.wsConnected = false;
      if (self.ws === ws) {
        self.ws = null;
      }
      self.scheduleWsReconnect(5000);
    });
    ws.on('error', () => {
      self.wsConnected = false;
      if (self.ws === ws) {
        self.ws = null;
      }
      self.scheduleWsReconnect(5000);
    });
    // The server's /ws guard accepts ?token= as well as the bearer header.
    const url = this.getWsUrl() +
      (this.token.length > 0 ? '?token=' + encodeURIComponent(this.token) : '');
    ws.connect(url).catch(() => {
      self.wsConnected = false;
      if (self.ws === ws) {
        self.ws = null;
      }
      self.scheduleWsReconnect(5000);
    });
  }

  // ---- HTTP helpers ----

  private async httpJson(method: string, path: string, body?: string): Promise<Record<string, Object> | null> {
    const req = http.createHttp();
    this.lastHttpCode = 0;
    try {
      const url = this.getBaseUrl() + path;
      const options: http.HttpRequestOptions = {
        method: method as http.RequestMethod,
        header: this.buildHeaders(),
        connectTimeout: 10000,
        readTimeout: 15000,
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      const resp = await req.request(url, options);
      this.lastHttpCode = resp.responseCode;
      const result = resp.result;
      if (typeof result === 'string') {
        if (result.length === 0) {
          return null;
        }
        const parsed = JSON.parse(result) as Record<string, Object>;
        if (resp.responseCode < 200 || resp.responseCode >= 300) {
          const err = parsed['error'];
          this.lastError = typeof err === 'string' ? (err as string) :
            ('Server returned HTTP ' + resp.responseCode);
          hilog.warn(DOMAIN, TAG, 'http %{public}s -> %{public}d %{public}s',
            path, resp.responseCode, this.lastError);
        }
        return parsed;
      }
      if (typeof result === 'object' && result !== null) {
        return result as Record<string, Object>;
      }
      return null;
    } catch (err) {
      this.lastError = 'network error';
      hilog.warn(DOMAIN, TAG, 'http %{public}s failed: %{public}s', path, JSON.stringify(err));
      return null;
    } finally {
      req.destroy();
    }
  }

  private buildHeaders(): Record<string, string> {
    const h: Record<string, string> = {
      'Content-Type': 'application/json',
    };
    if (this.token.length > 0) {
      h['Authorization'] = 'Bearer ' + this.token;
    }
    return h;
  }

  /** Public auth headers (media downloads + multipart need the token too). */
  getAuthHeaders(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.token.length > 0) {
      h['Authorization'] = 'Bearer ' + this.token;
    }
    return h;
  }

  // ---- status / pairing ----

  async getStatus(): Promise<StatusResponse | null> {
    // Embedded engine (in-app "server"): read status directly via NAPI. Only
    // trust a real payload; an empty/broken engine must fall through to HTTP.
    if (waEngine.isReady()) {
      const engRaw = waEngine.status();
      if (engRaw.length > 0) {
        try {
          const parsed = JSON.parse(engRaw) as Record<string, Object>;
          if (typeof parsed['linked'] === 'boolean') {
            return {
              linked: parsed['linked'] === true,
              phone: typeof parsed['phone'] === 'string' ? (parsed['phone'] as string) : '',
              qr: typeof parsed['qr'] === 'string' ? (parsed['qr'] as string) : '',
            } as StatusResponse;
          }
        } catch (e) {
          // fall through to HTTP
        }
      }
    }
    const resp = await this.httpJson('GET', '/status');
    if (resp === null || this.lastHttpCode !== 200) {
      return null;
    }
    if (typeof resp['linked'] !== 'boolean') {
      this.lastError = 'Unexpected /status response';
      return null;
    }
    this.lastError = '';
    return {
      linked: resp['linked'] === true,
      phone: typeof resp['phone'] === 'string' ? (resp['phone'] as string) : '',
      qr: typeof resp['qr'] === 'string' ? (resp['qr'] as string) : '',
    } as StatusResponse;
  }

  async isLinked(): Promise<boolean> {
    const st = await this.getStatus();
    if (st === null) {
      return false;
    }
    return st.linked === true;
  }

  async startPair(): Promise<boolean> {
    if (waEngine.isReady()) {
      waEngine.startPairing();
      return true;
    }
    const resp = await this.httpJson('POST', '/pair');
    if (resp === null || this.lastHttpCode < 200 || this.lastHttpCode >= 300) {
      if (this.lastError.length === 0) {
        this.lastError = 'Failed to start pairing';
      }
      return false;
    }
    this.lastError = '';
    return true;
  }

  /** Phone-number linking: request an 8-char code for country+phone. */
  async pairCode(country: string, phone: string): Promise<string> {
    const digits = (s: string): string => {
      let out = '';
      for (const c of s) {
        if (c >= '0' && c <= '9') {
          out += c;
        }
      }
      return out;
    };
    const full = digits(country) + digits(phone);
    if (full.length === 0) {
      return '';
    }
    if (waEngine.isReady()) {
      waEngine.pairCode(full);
      return '';
    }
    const body = JSON.stringify({ country, phone, full });
    const resp = await this.httpJson('POST', '/pair-code', body);
    if (resp === null) {
      throw new Error(this.lastError.length > 0 ? this.lastError : 'pair-code request failed');
    }
    // The backend surfaces the error message (e.g. WhatsApp rate-limit).
    if (resp['error'] !== undefined) {
      const msg = resp['error'];
      throw new Error(typeof msg === 'string' ? (msg as string) : 'pair-code request failed');
    }
    if (this.lastHttpCode < 200 || this.lastHttpCode >= 300) {
      throw new Error('pair-code failed (HTTP ' + this.lastHttpCode + ')');
    }
    // Return the 8-char code from the HTTP response so the UI shows it
    // immediately; the pair_code WS event is a backup path.
    const code = resp['code'];
    return typeof code === 'string' ? (code as string) : '';
  }

  async logout(): Promise<boolean> {
    // Embedded engine first (if one is ever built), then the HTTP backend.
    if (waEngine.isReady()) {
      if (waEngine.logout()) {
        return true;
      }
    }
    const resp = await this.httpJson('POST', '/logout');
    return resp !== null && this.lastHttpCode === 200;
  }

  // ---- passkey (SHORTCAKE) ----

  /** Get the pending passkey request options JSON ("" if none). */
  async passkeyRequest(): Promise<string> {
    if (waEngine.isReady()) {
      return waEngine.passkeyRequest();
    }
    const resp = await this.httpJson('GET', '/passkey/request');
    if (resp === null) {
      return '';
    }
    const options = resp['options'];
    return typeof options === 'string' ? (options as string) : '';
  }

  /**
   * Submit the WebAuthn assertion that resolves the pending passkey ceremony.
   * credentialId / assertionJson are base64url (no padding).
   */
  async passkeyAssertion(credentialIdB64Url: string, assertionJsonB64Url: string): Promise<boolean> {
    if (waEngine.isReady()) {
      return waEngine.passkeyAssertion(credentialIdB64Url, assertionJsonB64Url);
    }
    const body = JSON.stringify({
      credentialId: credentialIdB64Url,
      assertionJson: assertionJsonB64Url,
    });
    const resp = await this.httpJson('POST', '/passkey/assertion', body);
    return resp !== null;
  }

  /** Confirm the verification code shown on the phone (fresh link). */
  async passkeyConfirm(): Promise<boolean> {
    if (waEngine.isReady()) {
      return waEngine.passkeyConfirm();
    }
    const resp = await this.httpJson('POST', '/passkey/confirm');
    return resp !== null;
  }

  /** Cancel the pending passkey ceremony (user backed out). */
  async passkeyCancel(): Promise<boolean> {
    if (waEngine.isReady()) {
      return waEngine.passkeyCancel();
    }
    const resp = await this.httpJson('POST', '/passkey/cancel');
    return resp !== null;
  }

  /** UTF-8 string → base64url (no padding) for binary-safe WebAuthn payloads. */
  b64UrlFromBytes(bytes: Uint8Array): string {
    // Standard base64 first, then map to URL-safe alphabet and strip padding.
    let b64 = this.manualB64(bytes);
    b64 = b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
    return b64;
  }

  private manualB64(bytes: Uint8Array): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i];
      const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += chars.charAt(b0 >> 2);
      out += chars.charAt(((b0 & 3) << 4) | (b1 >> 4));
      if (i + 1 < bytes.length) {
        out += chars.charAt(((b1 & 15) << 2) | (b2 >> 6));
      }
      if (i + 2 < bytes.length) {
        out += chars.charAt(b2 & 63);
      }
    }
    return out;
  }

  // ---- chats / messages ----

  /** Fill chat-list rows with avatar URLs + channel metadata. */
  private decorateChat(c: ChatSummary): ChatSummary {
    c.isChannel = c.id.indexOf('@newsletter') >= 0;
    if (c.isChannel) {
      for (const ch of this.channelsCache) {
        if (ch.id === c.id) {
          if (c.name.length === 0) {
            c.name = ch.name;
          }
          c.description = ch.description;
          c.subscriberCount = ch.subscribers;
          break;
        }
      }
    }
    c.avatarUrl = this.avatarUrlFor(c.id);
    return c;
  }

  /** The /avatar endpoint URL for a chat JID (404 when it has no picture). */
  avatarUrlFor(chatId: string): string {
    if (chatId.length === 0) {
      return '';
    }
    return this.getBaseUrl() + '/avatar?chat=' + encodeURIComponent(chatId);
  }

  /** Resolve a chat's display name from the chat list / channel cache. */
  displayName(chatId: string): string {
    for (const c of this.lastChats) {
      if (c.id === chatId && c.name.length > 0) {
        return c.name;
      }
    }
    for (const ch of this.channelsCache) {
      if (ch.id === chatId && ch.name.length > 0) {
        return ch.name;
      }
    }
    return chatId;
  }

  /** Fetch the chat list (returns ChatSummary[], id = JID). */
  async scrapeChats(): Promise<ChatSummary[]> {
    // Embedded engine: parse the engine's JSON directly (no HTTP). Only
    // trust it when it is actually loaded and started; otherwise fall
    // through to the backend HTTP API.
    const engRaw = waEngine.isReady() ? waEngine.chats() : '';
    if (engRaw.length > 0) {
      const out: ChatSummary[] = [];
      try {
        const arr = JSON.parse(engRaw) as object[];
        for (const item of arr) {
          const d = item as Record<string, Object>;
          const c = new ChatSummary();
          c.id = typeof d['id'] === 'string' ? (d['id'] as string) : '';
          c.name = typeof d['name'] === 'string' ? (d['name'] as string) : '';
          c.preview = typeof d['preview'] === 'string' ? (d['preview'] as string) : '';
          const t = d['time'];
          c.time = typeof t === 'number' ? this.formatTime(t as number) : '';
          c.unread = typeof d['unread'] === 'number' ? (d['unread'] as number) : 0;
          c.pinned = typeof d['pinned'] === 'boolean' ? (d['pinned'] as boolean) : false;
          c.avatarUrl = '';
          out.push(c);
        }
      } catch (e) {
        // fall through to HTTP
      }
      if (out.length > 0 || engRaw === '[]') {
        for (const c of out) {
          this.decorateChat(c);
        }
        this.lastChats = out;
        return out;
      }
    }
    const resp = await this.httpJson('GET', '/chats');
    const out: ChatSummary[] = [];
    if (resp === null) {
      return out;
    }
    const chats = resp['chats'];
    if (chats === undefined || chats === null) {
      return out;
    }
    const arr = chats as object[];
    for (const item of arr) {
      const d = item as Record<string, Object>;
      const c = new ChatSummary();
      c.id = typeof d['id'] === 'string' ? (d['id'] as string) : '';
      c.name = typeof d['name'] === 'string' ? (d['name'] as string) : '';
      c.preview = typeof d['preview'] === 'string' ? (d['preview'] as string) : '';
      const t = d['time'];
      c.time = typeof t === 'number' ? this.formatTime(t as number) : '';
      c.unread = typeof d['unread'] === 'number' ? (d['unread'] as number) : 0;
      c.pinned = typeof d['pinned'] === 'boolean' ? (d['pinned'] as boolean) : false;
      c.avatarUrl = '';
      out.push(c);
    }
    for (const c of out) {
      this.decorateChat(c);
    }
    this.lastChats = out;
    return out;
  }

  /** Open a chat: resolve its JID (by name or id) as the current chat. */
  async openChat(name: string): Promise<boolean> {
    this.currentChatId = this.resolveJid(name);
    return this.currentChatId.length > 0;
  }

  /** Search the chat list locally (no DOM search over the protocol). */
  async searchChats(query: string): Promise<ChatSummary[]> {
    if (query.length === 0) {
      return this.scrapeChats();
    }
    const q = query.toLowerCase();
    const filtered = this.lastChats.filter((c: ChatSummary) =>
      c.name.toLowerCase().includes(q) || c.preview.toLowerCase().includes(q));
    return filtered;
  }

  /** Fetch messages for a chat by JID (id or name). */
  async scrapeMessages(chat?: string): Promise<MessageEntry[]> {
    const jid = this.resolveJid(chat);
    if (jid.length === 0) {
      return [];
    }
    // Embedded engine: read directly via NAPI. Only trust it when the
    // engine is actually loaded and started.
    const engRaw = waEngine.isReady() ? waEngine.messages(jid, 200) : '';
    if (engRaw.length > 0) {
      const out: MessageEntry[] = [];
      try {
        const arr = JSON.parse(engRaw) as object[];
        for (const item of arr) {
          const d = item as Record<string, Object>;
          const m = new MessageEntry();
          m.id = typeof d['id'] === 'string' ? (d['id'] as string) : '';
          m.text = typeof d['text'] === 'string' ? (d['text'] as string) : '';
          m.dir = typeof d['dir'] === 'string' ? (d['dir'] as string) : 'in';
          const t = d['time'];
          m.time = typeof t === 'number' ? this.formatTime(t as number) : '';
          m.status = typeof d['status'] === 'string' ? (d['status'] as string) : '';
          m.replyTo = typeof d['replyTo'] === 'string' ? (d['replyTo'] as string) : '';
          const reactionsRaw = d['reactions'];
          if (reactionsRaw !== undefined && reactionsRaw !== null) {
            const reactions = reactionsRaw as string[];
            if (reactions.length > 0) {
              m.reactions = reactions.join(',');
            }
          }
          const mediaRaw = d['media'];
          if (mediaRaw !== undefined && mediaRaw !== null) {
            const media = mediaRaw as Record<string, Object>;
            m.mediaUrl = typeof media['url'] === 'string' ? (media['url'] as string) : '';
            m.mediaType = typeof media['kind'] === 'string' ? (media['kind'] as string) : '';
            m.thumbUrl = typeof media['thumbUrl'] === 'string' ? (media['thumbUrl'] as string) : '';
          }
          out.push(m);
        }
      } catch (e) {
        // fall through to HTTP
      }
      if (out.length > 0 || engRaw === '[]') {
        return out;
      }
    }
    const resp = await this.httpJson('GET', '/messages?chat=' + encodeURIComponent(jid));
    const out: MessageEntry[] = [];
    if (resp === null) {
      return out;
    }
    const messages = resp['messages'];
    if (messages === undefined || messages === null) {
      return out;
    }
    const arr = messages as object[];
    for (const item of arr) {
      const d = item as Record<string, Object>;
      const m = new MessageEntry();
      m.id = typeof d['id'] === 'string' ? (d['id'] as string) : '';
      m.text = typeof d['text'] === 'string' ? (d['text'] as string) : '';
      m.dir = typeof d['dir'] === 'string' ? (d['dir'] as string) : 'in';
      const t = d['time'];
      m.time = typeof t === 'number' ? this.formatTime(t as number) : '';
      m.status = typeof d['status'] === 'string' ? (d['status'] as string) : '';
      m.replyTo = typeof d['replyTo'] === 'string' ? (d['replyTo'] as string) : '';
      const reactionsRaw = d['reactions'];
      if (reactionsRaw !== undefined && reactionsRaw !== null) {
        const reactions = reactionsRaw as string[];
        if (reactions.length > 0) {
          m.reactions = reactions.join(',');
        }
      }
      const mediaRaw = d['media'];
      if (mediaRaw !== undefined && mediaRaw !== null) {
        const media = mediaRaw as Record<string, Object>;
        m.mediaUrl = typeof media['url'] === 'string' ? (media['url'] as string) : '';
        m.mediaType = typeof media['kind'] === 'string' ? (media['kind'] as string) : '';
        m.thumbUrl = typeof media['thumbUrl'] === 'string' ? (media['thumbUrl'] as string) : '';
      }
      out.push(m);
    }
    return out;
  }

  /** Extract media entries from the last-fetched messages (media rides on messages). */
  async scrapeMediaMessages(): Promise<MediaMessage[]> {
    const jid = this.resolveJid(undefined);
    if (jid.length === 0) {
      return [];
    }
    const msgs = await this.scrapeMessages(jid);
    const out: MediaMessage[] = [];
    for (const m of msgs) {
      if (m.mediaUrl.length === 0) {
        continue;
      }
      const mm = new MediaMessage();
      mm.id = m.id;
      mm.type = m.mediaType.length > 0 ? m.mediaType : 'image';
      mm.mediaUrl = m.mediaUrl;
      mm.thumbUrl = m.thumbUrl;
      mm.dir = m.dir;
      mm.time = m.time;
      out.push(mm);
    }
    return out;
  }

  private resolveJid(chat?: string): string {
    if (chat !== undefined && chat.length > 0) {
      // The page passes names; find the JID in the last fetched chat list.
      for (const c of this.lastChats) {
        if (c.id === chat || c.name === chat) {
          return c.id;
        }
      }
      // Fall back to treating the arg as a JID.
      return chat;
    }
    return this.currentChatId;
  }

  // ---- send / react ----

  /** Send a text message to the current/open chat (page API compat). */
  async sendMessage(text: string): Promise<boolean> {
    const jid = this.resolveJid(undefined);
    if (jid.length === 0) {
      return false;
    }
    const resp = await waEngine.sendMessage(jid, text);
    if (resp !== null && resp['ok'] === true) {
      return true;
    }
    const body = JSON.stringify({ chat: jid, text: text });
    const httpResp = await this.httpJson('POST', '/send', body);
    return httpResp !== null;
  }

  /** Send a text message to a specific chat by JID/name. */
  async sendMessageToChat(chat: string, text: string): Promise<boolean> {
    const jid = this.resolveJid(chat);
    if (jid.length === 0) {
      return false;
    }
    const resp = await waEngine.sendMessage(jid, text);
    if (resp !== null && resp['ok'] === true) {
      return true;
    }
    const body = JSON.stringify({ chat: jid, text: text });
    const httpResp = await this.httpJson('POST', '/send', body);
    return httpResp !== null;
  }

  /** Reply to a specific message (targetId = message id, text = reply body). */
  async sendReply(targetId: string, text: string): Promise<boolean> {
    const jid = this.resolveJid(undefined);
    if (jid.length === 0) {
      return false;
    }
    const resp = await waEngine.sendReply(jid, text, targetId);
    if (resp !== null && resp['ok'] === true) {
      return true;
    }
    const body = JSON.stringify({ chat: jid, text: text, replyTo: targetId });
    const httpResp = await this.httpJson('POST', '/send', body);
    return httpResp !== null;
  }

  /** React to a message with an emoji (empty emoji removes). */
  async addReaction(targetId: string, emoji: string): Promise<boolean> {
    const jid = this.resolveJid(undefined);
    if (jid.length === 0) {
      return false;
    }
    const resp = await waEngine.react(jid, targetId, emoji);
    if (resp !== null && resp['ok'] === true) {
      return true;
    }
    const body = JSON.stringify({ chat: jid, messageId: targetId, emoji: emoji });
    const httpResp = await this.httpJson('POST', '/react', body);
    return httpResp !== null;
  }

  /** Mark a chat as read. */
  async markRead(chat?: string): Promise<boolean> {
    const jid = this.resolveJid(chat);
    if (jid.length === 0) {
      return false;
    }
    const resp = await waEngine.markRead(jid);
    if (resp !== null && resp['ok'] === true) {
      return true;
    }
    const body = JSON.stringify({ chat: jid });
    const httpResp = await this.httpJson('POST', '/read', body);
    return httpResp !== null;
  }

  /**
   * Send media files to the open chat. Over the protocol this is a multipart
   * upload to /send-media (the backend uploads to WhatsApp).
   */
  async sendMediaFiles(paths: string[]): Promise<boolean> {
    if (paths.length === 0) {
      return false;
    }
    const jid = this.resolveJid(undefined);
    if (jid.length === 0) {
      return false;
    }
    const nativeResp = await waEngine.sendMedia(jid, paths[0]);
    if (nativeResp !== null && nativeResp['ok'] === true) {
      return true;
    }
    try {
      const req = http.createHttp();
      try {
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.POST,
          header: this.buildHeaders(),
          connectTimeout: 15000,
          readTimeout: 120000,
        };
        const boundary = '----WhatIsIt' + Date.now();
        const parts: string[] = [];
        parts.push('--' + boundary + '\r\n' +
          'Content-Disposition: form-data; name="chat"\r\n\r\n' + jid + '\r\n');
        parts.push('--' + boundary + '\r\n' +
          'Content-Disposition: form-data; name="file"; filename="media.bin"\r\n' +
          'Content-Type: application/octet-stream\r\n\r\n');
        const fileData = await this.readFileAsArrayBuffer(paths[0]);
        const headStr = parts[0] + parts[1];
        const tailStr = '\r\n--' + boundary + '--\r\n';
        const headBytes = this.strToBytes(headStr);
        const tailBytes = this.strToBytes(tailStr);
        const total = headBytes.byteLength + fileData.byteLength + tailBytes.byteLength;
        const full = new Uint8Array(total);
        full.set(new Uint8Array(headBytes), 0);
        full.set(new Uint8Array(fileData), headBytes.byteLength);
        full.set(new Uint8Array(tailBytes), headBytes.byteLength + fileData.byteLength);
        (options.header as Record<string, string>)['Content-Type'] = 'multipart/form-data; boundary=' + boundary;
        options.extraData = full.buffer;
        const resp = await req.request(this.getBaseUrl() + '/send-media', options);
        const result = resp.result;
        let resultStr = '';
        if (typeof result === 'string') {
          resultStr = result;
        }
        if (resultStr.length > 0) {
          const j = JSON.parse(resultStr) as Record<string, Object>;
          return j['ok'] === true;
        }
        return false;
      } finally {
        req.destroy();
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'sendMediaFiles failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  private async readFileAsArrayBuffer(path: string): Promise<ArrayBuffer> {
    try {
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
      return buf;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'readFileAsArrayBuffer failed: %{public}s', JSON.stringify(err));
      return new ArrayBuffer(0);
    }
  }

  /** ASCII/UTF-8 string → bytes (ArkTS has no TextEncoder). */
  private strToBytes(s: string): ArrayBuffer {
    const buf = new ArrayBuffer(s.length);
    const view = new Uint8Array(buf);
    for (let i = 0; i < s.length; i++) {
      view[i] = s.charCodeAt(i) & 0xFF;
    }
    return buf;
  }

  // ---- unread helpers ----

  async getUnreadTotal(): Promise<number> {
    const chats = await this.scrapeChats();
    let total = 0;
    for (const c of chats) {
      total += c.unread;
    }
    return total;
  }

  async getLatestUnreadChat(): Promise<ChatSummary | null> {
    const chats = await this.scrapeChats();
    let best: ChatSummary | null = null;
    for (const c of chats) {
      if (c.unread > 0 && (best === null || c.unread > best.unread)) {
        best = c;
      }
    }
    return best;
  }

  // ---- calls (not supported over the protocol — honest limit) ----

  async getCallState(): Promise<string> {
    return 'none';
  }

  async startCall(): Promise<boolean> {
    return false;
  }

  async startVideoCall(): Promise<boolean> {
    return false;
  }

  async acceptCall(): Promise<boolean> {
    return false;
  }

  async endCall(): Promise<boolean> {
    return false;
  }

  async toggleMute(): Promise<boolean> {
    return false;
  }

  async toggleCamera(): Promise<boolean> {
    return false;
  }

  // ---- calls (signaling) ----

  /** Start an outgoing call; returns {callId}. */
  async callStart(chat: string, video: boolean): Promise<Record<string, Object> | null> {
    const nativeResp = await waEngine.callStart(chat, video);
    if (nativeResp !== null) {
      return nativeResp;
    }
    const body = JSON.stringify({ chat: chat, video: video });
    return this.httpJson('POST', '/call', body);
  }

  /** Accept an incoming call; returns {callId}. */
  async callAccept(callId: string, video: boolean): Promise<Record<string, Object> | null> {
    const nativeResp = await waEngine.callAccept(callId, video);
    if (nativeResp !== null) {
      return nativeResp;
    }
    const body = JSON.stringify({ callId: callId, video: video });
    return this.httpJson('POST', '/call/accept', body);
  }

  /** Reject an incoming call. */
  async callReject(callId: string): Promise<boolean> {
    const nativeOk = await waEngine.callReject(callId);
    if (nativeOk) {
      return true;
    }
    const body = JSON.stringify({ callId: callId });
    const resp = await this.httpJson('POST', '/call/reject', body);
    return resp !== null;
  }

  /** End the active call. */
  async callEnd(callId: string): Promise<boolean> {
    const nativeOk = await waEngine.callEnd(callId);
    if (nativeOk) {
      return true;
    }
    const body = JSON.stringify({ callId: callId });
    const resp = await this.httpJson('POST', '/call/end', body);
    return resp !== null;
  }

  /** Mute/unmute the active call. */
  async callMute(callId: string, muted: boolean): Promise<boolean> {
    const nativeOk = await waEngine.callMute(callId, muted);
    if (nativeOk) {
      return true;
    }
    const body = JSON.stringify({ callId: callId, muted: muted });
    const resp = await this.httpJson('POST', '/call/mute', body);
    return resp !== null;
  }

  /** Toggle the camera on the active call. */
  async callCamera(callId: string, on: boolean): Promise<boolean> {
    const nativeOk = await waEngine.callCamera(callId, on);
    if (nativeOk) {
      return true;
    }
    const body = JSON.stringify({ callId: callId, on: on });
    const resp = await this.httpJson('POST', '/call/camera', body);
    return resp !== null;
  }

  // ---- misc page API kept for compat ----

  async getSessionCookies(): Promise<string> {
    return '';
  }

  async getDisappearingTimer(): Promise<string> {
    return 'off';
  }

  async setDisappearingTimer(_value: string): Promise<boolean> {
    return false;
  }

  async getGroupInfo(): Promise<string> {
    return '';
  }

  /** Contacts with a recent status update (from the backend /status-list). */
  async scrapeStatus(): Promise<ChatSummary[]> {
    const resp = await this.httpJson('GET', '/status-list');
    const out: ChatSummary[] = [];
    if (resp !== null) {
      const arr = resp['statuses'];
      if (arr !== undefined && arr !== null) {
        const items = arr as object[];
        for (const item of items) {
          const d = item as Record<string, Object>;
          const c = new ChatSummary();
          c.id = typeof d['sender'] === 'string' ? (d['sender'] as string) : '';
          c.name = typeof d['name'] === 'string' ? (d['name'] as string) : '';
          if (c.name.length === 0) {
            c.name = c.id;
          }
          const kind = typeof d['kind'] === 'string' ? (d['kind'] as string) : 'text';
          const text = typeof d['text'] === 'string' ? (d['text'] as string) : '';
          c.preview = text.length > 0 ? text : (kind === 'text' ? 'Status update' : '📎 ' + kind);
          const t = d['time'];
          c.time = typeof t === 'number' ? this.formatTime(t as number) : '';
          c.avatarUrl = this.avatarUrlFor(c.id);
          out.push(c);
        }
      }
    }
    return out;
  }

  async openStatusTab(): Promise<ChatSummary[]> {
    return this.scrapeStatus();
  }

  /** Fetch the followed channels list from the backend (with cache). */
  async scrapeChannels(): Promise<ChannelSummary[]> {
    if (this.channelsCache.length > 0) {
      return this.channelsCache;
    }
    const resp = await this.httpJson('GET', '/channels');
    const out: ChannelSummary[] = [];
    if (resp !== null) {
      const arr = resp['channels'];
      if (arr !== undefined && arr !== null) {
        const items = arr as object[];
        for (const item of items) {
          const d = item as Record<string, Object>;
          const ch = new ChannelSummary();
          ch.id = typeof d['id'] === 'string' ? (d['id'] as string) : '';
          ch.name = typeof d['name'] === 'string' ? (d['name'] as string) : '';
          ch.description = typeof d['description'] === 'string' ? (d['description'] as string) : '';
          ch.subscribers = typeof d['subscribers'] === 'number' ? (d['subscribers'] as number) : 0;
          ch.updates = typeof d['updates'] === 'number' ? (d['updates'] as number) : 0;
          ch.invite = typeof d['invite'] === 'string' ? (d['invite'] as string) : '';
          ch.pic = d['pic'] === true;
          ch.avatarUrl = this.avatarUrlFor(ch.id);
          out.push(ch);
        }
      }
    }
    this.channelsCache = out;
    return out;
  }

  /** Expire the channel cache so the next call refetches. */
  invalidateChannels(): void {
    this.channelsCache = [];
  }

  /** Follow/unfollow a WhatsApp channel. */
  async followChannel(id: string): Promise<boolean> {
    const body = JSON.stringify({ chat: id });
    const resp = await this.httpJson('POST', '/channel/follow', body);
    if (resp !== null) {
      this.invalidateChannels();
      return true;
    }
    return false;
  }

  async unfollowChannel(id: string): Promise<boolean> {
    const body = JSON.stringify({ chat: id });
    const resp = await this.httpJson('POST', '/channel/unfollow', body);
    if (resp !== null) {
      this.invalidateChannels();
      return true;
    }
    return false;
  }

  /** Post a text status update to the backend (published to your status). */
  async sendStatus(text: string): Promise<boolean> {
    const body = JSON.stringify({ text: text });
    const resp = await this.httpJson('POST', '/status-update', body);
    return resp !== null;
  }

  /** Fetch the WhatsApp call history (audio + video, incoming + outgoing). */
  async scrapeCalls(): Promise<CallRecord[]> {
    const resp = await this.httpJson('GET', '/calls');
    const out: CallRecord[] = [];
    if (resp !== null) {
      const arr = resp['calls'];
      if (arr !== undefined && arr !== null) {
        const items = arr as object[];
        for (const item of items) {
          const d = item as Record<string, Object>;
          const c = new CallRecord();
          c.id = typeof d['id'] === 'string' ? (d['id'] as string) : '';
          c.peer = typeof d['peer'] === 'string' ? (d['peer'] as string) : '';
          c.dir = typeof d['dir'] === 'string' ? (d['dir'] as string) : 'out';
          c.video = d['video'] === true;
          c.missed = d['missed'] === true;
          const t = d['time'];
          c.time = typeof t === 'number' ? this.formatTime(t as number) : '';
          c.name = this.displayName(c.peer);
          out.push(c);
        }
      }
    }
    return out;
  }

  /** Communities are the @g.us groups this account belongs to. */
  async scrapeCommunities(): Promise<ChatSummary[]> {
    const out: ChatSummary[] = [];
    for (const c of this.lastChats) {
      if (c.id.indexOf('@g.us') >= 0) {
        out.push(c);
      }
    }
    return out;
  }

  async openCommunitiesTab(): Promise<ChatSummary[]> {
    return this.scrapeCommunities();
  }

  async openChannelsTab(): Promise<ChatSummary[]> {
    const out: ChatSummary[] = [];
    for (const c of this.lastChats) {
      if (c.isChannel) {
        out.push(c);
      }
    }
    return out;
  }

  async openArchived(): Promise<ChatSummary[]> {
    return [];
  }

  async openStarred(): Promise<ChatSummary[]> {
    return [];
  }

  private formatTime(unixMillis: number): string {
    if (unixMillis <= 0) {
      return '';
    }
    const d = new Date(unixMillis);
    const now = new Date();
    const sameDay = d.toDateString() === now.toDateString();
    if (sameDay) {
      return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }
    return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  }
}

/** Singleton (name kept as cdpBridge for page-API compatibility). */
export const cdpBridge = new CdpBridge();
