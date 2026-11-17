/**
 * WhatsAppWebBridge — data/action adapter over the linked WhatsApp Web page.
 *
 * The WebView is the session layer; this class turns its DOM into the app's
 * native ChatItem/MessageItem models. It is intentionally text-first.
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatItem, MessageItem } from '../models/WhatsAppModels';

const TAG = 'WhatsAppWeb';
const DOMAIN = 0x0000;

class WebChatJson {
  id: string = '';
  name: string = '';
  preview: string = '';
  time: string = '';
  unread: number = 0;
  pinned: boolean = false;
  isGroup: boolean = false;
  isChannel: boolean = false;
  avatar: string = '';
}

class WebMessageJson {
  id: string = '';
  text: string = '';
  time: string = '';
  dir: string = 'in';
  status: string = '';
  sender: string = '';
  mediaType: string = '';
  mediaUrl: string = '';
  mediaName: string = '';
}

export class WhatsAppWebBridge {
  private controller: webview.WebviewController | null = null;
  private imageCache: Map<string, string> = new Map<string, string>();

  attach(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  private async js(script: string): Promise<string> {
    if (this.controller === null) {
      return '';
    }
    try {
      const result = await this.controller.runJavaScript(script);
      return result !== undefined && result !== null ? String(result) : '';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'js failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private unwrap(raw: string): string {
    let text = raw.trim();
    if (text.length >= 2 && text.charAt(0) === '"' && text.charAt(text.length - 1) === '"') {
      try {
        text = JSON.parse(text) as string;
      } catch (e) {
        // keep raw
      }
    }
    return text;
  }

  async linked(): Promise<boolean> {
    const raw = this.unwrap(await this.js('window.__waNative ? window.__waNative.linked() : false'));
    return raw.trim() === 'true';
  }

  private parseChats(raw: string): ChatItem[] {
    const text = this.unwrap(raw);
    if (text.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(text) as object[];
      const out: ChatItem[] = [];
      for (const item of arr) {
        const d = item as WebChatJson;
        if (d.id === undefined || d.id.length === 0 || d.name === undefined) {
          continue;
        }
        const c = new ChatItem();
        c.id = d.id;
        c.name = d.name;
        c.preview = d.preview !== undefined ? d.preview : '';
        c.time = d.time !== undefined ? d.time : '';
        c.unread = d.unread !== undefined ? d.unread : 0;
        c.pinned = d.pinned === true;
        c.isGroup = d.isGroup === true || c.id.indexOf('@g.us') >= 0;
        c.isChannel = d.isChannel === true;
        c.avatarUrl = d.avatar !== undefined ? d.avatar : '';
        out.push(c);
      }
      return out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'chat parse failed: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  async chats(): Promise<ChatItem[]> {
    const raw = await this.js('window.__waNative ? window.__waNative.chats() : "[]"');
    return this.parseChats(raw);
  }

  async linkState(): Promise<string> {
    return this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.linkState() : "loading"'
    )).trim();
  }

  async qrImage(): Promise<string> {
    return this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.qrImage() : ""'
    ));
  }

  async choosePhone(): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.choosePhone() : false'
    ));
    return raw.trim() === 'true';
  }

  async submitPhone(country: string, phone: string): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.submitPhone(' +
        JSON.stringify(country) + ', ' + JSON.stringify(phone) + ') : false'
    ));
    return raw.trim() === 'true';
  }

  async pairCode(): Promise<string> {
    return this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.pairCode() : ""'
    ));
  }

  async refreshQr(): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.refreshQr() : false'
    ));
    return raw.trim() === 'true';
  }

  async linkDebug(): Promise<string> {
    return this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.linkDebug() : "{}"'
    ));
  }

  async storeReady(): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.storeReady() : false'
    ));
    return raw.trim() === 'true';
  }

  async storeChats(): Promise<ChatItem[]> {
    const raw = await this.js('window.__waNative ? window.__waNative.storeChats() : "[]"');
    return this.parseChats(raw);
  }

  async openChat(id: string): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.openChat(' + JSON.stringify(id) + ') : false'
    ));
    return raw.trim() === 'true';
  }

  private parseMessages(raw: string): MessageItem[] {
    const text = this.unwrap(raw);
    if (text.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(text) as object[];
      const out: MessageItem[] = [];
      for (const item of arr) {
        const d = item as WebMessageJson;
        if (d.text === undefined || d.text.length === 0) {
          continue;
        }
        const m = new MessageItem();
        m.id = d.id !== undefined ? d.id : '';
        m.text = d.text;
        m.time = d.time !== undefined ? d.time : '';
        m.out = d.dir === 'out';
        m.status = d.status !== undefined ? d.status : '';
        m.sender = d.sender !== undefined ? d.sender : '';
        m.mediaType = d.mediaType !== undefined ? d.mediaType : '';
        m.mediaUrl = d.mediaUrl !== undefined ? d.mediaUrl : '';
        m.mediaName = d.mediaName !== undefined ? d.mediaName : '';
        out.push(m);
      }
      return out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'message parse failed: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  async messages(limit: number = 500): Promise<MessageItem[]> {
    const raw = await this.js(
      'window.__waNative ? window.__waNative.messages(' + limit + ') : "[]"'
    );
    return this.parseMessages(raw);
  }

  async storeMessages(chatId: string, limit: number = 500): Promise<MessageItem[]> {
    const raw = await this.js(
      'window.__waNative ? window.__waNative.storeMessages(' +
        JSON.stringify(chatId) + ', ' + limit + ') : "[]"'
    );
    return this.parseMessages(raw);
  }

  async fullImage(id: string): Promise<string> {
    const cached = this.imageCache.get(id);
    if (cached !== undefined) {
      return cached;
    }
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.fullImage(' + JSON.stringify(id) + ') : ""'
    ));
    if (raw.length > 0) {
      this.imageCache.set(id, raw);
    }
    return raw;
  }

  async search(value: string): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.search(' + JSON.stringify(value) + ') : false'
    ));
    return raw.trim() === 'true';
  }

  async openFirstResult(value: string = ''): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.openFirstResult(' + JSON.stringify(value) + ') : false'
    ));
    return raw.trim() === 'true';
  }

  async scrollOlder(): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.scrollOlder() : false'
    ));
    return raw.trim() === 'true';
  }

  async send(text: string): Promise<boolean> {
    const raw = this.unwrap(await this.js(
      'window.__waNative ? window.__waNative.send(' + JSON.stringify(text) + ') : false'
    ));
    return raw.trim() === 'true';
  }
}

export const whatsappWebBridge: WhatsAppWebBridge = new WhatsAppWebBridge();
