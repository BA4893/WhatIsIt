/**
 * WaEngine — typed wrapper over the embedded WhatsApp engine
 * (libwa_engine.so, the Rust whatsapp-rust core exposed via NAPI).
 *
 * No HTTP server, no ports, no backend host: the engine runs in-process on a
 * background tokio thread. ArkTS calls go over direct NAPI function calls
 * (memory passing, no sockets); engine events (qr / linked / message /
 * receipt / chats / logged_out / pair_code) arrive via a NAPI callback that
 * this wrapper dispatches to the caller (which should hop to the UI thread).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'WaEngine';
const DOMAIN = 0x0000;

/** Loader for the native NAPI module (same pattern as CallService). */
declare const requireNapi: (name: string) => Object;

/** The native surface exposed by libwa_engine.so (see wa_bridge.cpp). */
interface WaEngineNative {
  start(dataDir: string): number;
  stop(): number;
  status(): string;
  chats(): string;
  messages(chat: string, limit: number): string;
  startPairing(): void;
  pairCode(phone: string): number;
  logout(): number;
  setEventCallback(cb: (type: string, json: string) => void): void;
  sendMessage(chat: string, text: string): string;
  sendReply(chat: string, text: string, replyTo: string): string;
  sendMedia(chat: string, path: string): string;
  react(chat: string, messageId: string, emoji: string): string;
  markRead(chat: string): string;
  callStart(chat: string, video: boolean): string;
  callAccept(callId: string, video: boolean): string;
  callReject(callId: string): string;
  callEnd(callId: string): string;
  callMute(callId: string, muted: boolean): string;
  callCamera(callId: string, on: boolean): string;
  passkeyRequest(): string;
  passkeyAssertion(credentialIdB64Url: string, assertionJsonB64Url: string): string;
  passkeyConfirm(): string;
  passkeyCancel(): string;
  mediaPath(id: string, kind: string): string;
}

/** An engine event forwarded to the app: type + JSON payload. */
export class WaEvent {
  type: string = '';
  json: string = '';
}

export class WaEngine {
  private native: WaEngineNative | null = null;
  private started = false;

  /** Load the native module once. */
  private loadNative(): WaEngineNative | null {
    if (this.native !== null) {
      return this.native;
    }
    try {
      this.native = requireNapi('wa_engine') as WaEngineNative;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'wa_engine native not loaded: %{public}s', JSON.stringify(err));
      this.native = null;
    }
    return this.native;
  }

  /** Start the engine with the app's private sandbox dir. */
  start(dataDir: string): void {
    const native = this.loadNative();
    if (native === null) {
      hilog.warn(DOMAIN, TAG, 'engine unavailable (libwa_engine not built)');
      return;
    }
    try {
      native.start(dataDir);
      this.started = true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'engine start failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Stop the engine (disconnect + flush session). */
  stop(): void {
    if (!this.started) {
      return;
    }
    const native = this.loadNative();
    if (native !== null) {
      try {
        native.stop();
      } catch (err) {
        // ignore
      }
    }
    this.started = false;
  }

  /** Register the event callback (replaces any prior). */
  setEventCallback(cb: (type: string, json: string) => void): void {
    const native = this.loadNative();
    if (native === null) {
      return;
    }
    try {
      native.setEventCallback(cb);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setEventCallback failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Current status JSON: { linked, phone, qr }. */
  status(): string {
    const native = this.loadNative();
    if (native === null) {
      return '{"linked":false,"phone":"","qr":""}';
    }
    try {
      return native.status();
    } catch (err) {
      return '{"linked":false,"phone":"","qr":""}';
    }
  }

  /** Chat list JSON. */
  chats(): string {
    const native = this.loadNative();
    if (native === null) {
      return '[]';
    }
    try {
      return native.chats();
    } catch (err) {
      return '[]';
    }
  }

  /** Messages for a chat as JSON. */
  messages(chat: string, limit: number): string {
    const native = this.loadNative();
    if (native === null) {
      return '[]';
    }
    try {
      return native.messages(chat, limit);
    } catch (err) {
      return '[]';
    }
  }

  /** Begin QR pairing (no-op when linked). */
  startPairing(): void {
    const native = this.loadNative();
    if (native === null) {
      return;
    }
    try {
      native.startPairing();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startPairing failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Request an 8-char pair code for the given full E.164 phone number. */
  pairCode(phone: string): boolean {
    const native = this.loadNative();
    if (native === null) {
      return false;
    }
    try {
      return native.pairCode(phone) === 0;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'pairCode failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** Log out (clears the session). */
  logout(): boolean {
    const native = this.loadNative();
    if (native === null) {
      return false;
    }
    try {
      return native.logout() === 0;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'logout failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** Whether the engine is loaded and running. */
  isReady(): boolean {
    return this.native !== null && this.started;
  }

  private callJson(native: WaEngineNative | null, fn: () => string): Record<string, Object> | null {
    if (native === null) {
      return null;
    }
    try {
      const raw = fn();
      if (raw.length === 0) {
        return null;
      }
      return JSON.parse(raw) as Record<string, Object>;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'waEngine call failed: %{public}s', JSON.stringify(err));
      return null;
    }
  }

  /** Send a text message to a chat. */
  sendMessage(chat: string, text: string): Promise<Record<string, Object> | null> {
    return Promise.resolve(this.callJson(this.loadNative(), () => this.native!.sendMessage(chat, text)));
  }

  /** Reply to a message. */
  sendReply(chat: string, text: string, replyTo: string): Promise<Record<string, Object> | null> {
    return Promise.resolve(this.callJson(this.loadNative(), () => this.native!.sendReply(chat, text, replyTo)));
  }

  /** Send a media file to a chat. */
  sendMedia(chat: string, path: string): Promise<Record<string, Object> | null> {
    return Promise.resolve(this.callJson(this.loadNative(), () => this.native!.sendMedia(chat, path)));
  }

  /** React to a message. */
  react(chat: string, messageId: string, emoji: string): Promise<Record<string, Object> | null> {
    return Promise.resolve(this.callJson(this.loadNative(), () => this.native!.react(chat, messageId, emoji)));
  }

  /** Mark a chat as read. */
  markRead(chat: string): Promise<Record<string, Object> | null> {
    return Promise.resolve(this.callJson(this.loadNative(), () => this.native!.markRead(chat)));
  }

  /** Start an outgoing call. */
  callStart(chat: string, video: boolean): Promise<Record<string, Object> | null> {
    return Promise.resolve(this.callJson(this.loadNative(), () => this.native!.callStart(chat, video)));
  }

  /** Accept an incoming call. */
  callAccept(callId: string, video: boolean): Promise<Record<string, Object> | null> {
    return Promise.resolve(this.callJson(this.loadNative(), () => this.native!.callAccept(callId, video)));
  }

  /** Reject an incoming call. */
  callReject(callId: string): Promise<boolean> {
    const native = this.loadNative();
    if (native === null) {
      return Promise.resolve(false);
    }
    try {
      const raw = native.callReject(callId);
      return Promise.resolve(raw === 'true' || raw === '{"ok":true}');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'callReject failed: %{public}s', JSON.stringify(err));
      return Promise.resolve(false);
    }
  }

  /** End an active call. */
  callEnd(callId: string): Promise<boolean> {
    const native = this.loadNative();
    if (native === null) {
      return Promise.resolve(false);
    }
    try {
      const raw = native.callEnd(callId);
      return Promise.resolve(raw === 'true' || raw === '{"ok":true}');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'callEnd failed: %{public}s', JSON.stringify(err));
      return Promise.resolve(false);
    }
  }

  /** Mute/unmute. */
  callMute(callId: string, muted: boolean): Promise<boolean> {
    const native = this.loadNative();
    if (native === null) {
      return Promise.resolve(false);
    }
    try {
      const raw = native.callMute(callId, muted);
      return Promise.resolve(raw === 'true' || raw === '{"ok":true}');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'callMute failed: %{public}s', JSON.stringify(err));
      return Promise.resolve(false);
    }
  }

  /** Toggle camera. */
  callCamera(callId: string, on: boolean): Promise<boolean> {
    const native = this.loadNative();
    if (native === null) {
      return Promise.resolve(false);
    }
    try {
      const raw = native.callCamera(callId, on);
      return Promise.resolve(raw === 'true' || raw === '{"ok":true}');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'callCamera failed: %{public}s', JSON.stringify(err));
      return Promise.resolve(false);
    }
  }

  /** Pending passkey request options JSON ('' when none). */
  passkeyRequest(): string {
    const native = this.loadNative();
    if (native === null) {
      return '';
    }
    try {
      const raw = native.passkeyRequest();
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        const options = parsed['options'];
        return typeof options === 'string' ? (options as string) : '';
      } catch (e) {
        return '';
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'passkeyRequest failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  /** Resolve the pending passkey ceremony with a WebAuthn assertion. */
  passkeyAssertion(credentialIdB64Url: string, assertionJsonB64Url: string): Promise<boolean> {
    const native = this.loadNative();
    if (native === null) {
      return Promise.resolve(false);
    }
    try {
      const raw = native.passkeyAssertion(credentialIdB64Url, assertionJsonB64Url);
      let ok = false;
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        ok = parsed['ok'] === true;
      } catch (e) {
        ok = raw === 'true';
      }
      return Promise.resolve(ok);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'passkeyAssertion failed: %{public}s', JSON.stringify(err));
      return Promise.resolve(false);
    }
  }

  /** Confirm the verification code on a fresh link. */
  passkeyConfirm(): Promise<boolean> {
    const native = this.loadNative();
    if (native === null) {
      return Promise.resolve(false);
    }
    try {
      const raw = native.passkeyConfirm();
      let ok = false;
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        ok = parsed['ok'] === true;
      } catch (e) {
        ok = raw === 'true';
      }
      return Promise.resolve(ok);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'passkeyConfirm failed: %{public}s', JSON.stringify(err));
      return Promise.resolve(false);
    }
  }

  /** Cancel the pending passkey ceremony. */
  passkeyCancel(): Promise<boolean> {
    const native = this.loadNative();
    if (native === null) {
      return Promise.resolve(false);
    }
    try {
      const raw = native.passkeyCancel();
      let ok = false;
      try {
        const parsed = JSON.parse(raw) as Record<string, Object>;
        ok = parsed['ok'] === true;
      } catch (e) {
        ok = raw === 'true';
      }
      return Promise.resolve(ok);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'passkeyCancel failed: %{public}s', JSON.stringify(err));
      return Promise.resolve(false);
    }
  }

  /** Absolute path of a cached media file ('' when not cached yet). */
  mediaPath(id: string, kind: string): string {
    const native = this.loadNative();
    if (native === null) {
      return '';
    }
    try {
      return native.mediaPath(id, kind);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'mediaPath failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }
}

/** Singleton. */
export const waEngine = new WaEngine();
