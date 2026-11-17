import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import {
  cdpBridge, BackendEvent, EventListener, ChatSummary, ChannelSummary, CallRecord, MessageEntry
} from '../services/CdpBridge';
import { callService } from '../services/CallService';
import { authStore } from '../services/AuthStore';
import { AppearanceStore, DISPLAY_MODE_SYSTEM } from '../services/AppearanceStore';
import { ResponsiveLayout } from '../services/ResponsiveLayout';
import { WhatsAppStore } from '../services/WhatsAppStore';
import { Theme } from '../styles/Theme';
import {
  ChatItem, MessageItem, StatusItem, ChannelItem, CallItem, CommunityItem
} from '../models/WhatsAppModels';
import { Avatar } from '../components/Avatar';
import { ChatsPane } from '../components/ChatsPane';
import { UpdatesPane } from '../components/UpdatesPane';
import { CallsPane } from '../components/CallsPane';
import { CommunitiesPane } from '../components/CommunitiesPane';
import { SettingsPane } from '../components/SettingsPane';
import { ConversationView } from '../components/ConversationView';
import { FloatingCompose } from '../components/FloatingCompose';
import { ComposeSheet } from '../components/ComposeSheet';
import { LinkDeviceSheet } from '../components/LinkDeviceSheet';
import { StatusComposerSheet } from '../components/StatusComposerSheet';
import { NewChatSheet } from '../components/NewChatSheet';
import { CallPickerSheet } from '../components/CallPickerSheet';
import { StatusViewer } from '../components/StatusViewer';
import { IncomingCallSheet } from '../components/IncomingCallSheet';
import { MediaViewer } from '../components/MediaViewer';
import { NativeLinkView } from '../components/NativeLinkView';
import { whatsappWebBridge } from '../services/WhatsAppWebBridge';
import { mediaDownloader } from '../services/MediaDownloader';
import { WA_NATIVE_SHIM } from '../services/WhatsAppWebShim';
import { webview } from '@kit.ArkWeb';
import { CallSurfaceView } from './CallSurfaceView';

const TAG = 'Index';
const DOMAIN = 0x0000;

const WEB_DESKTOP_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

class NavItem {
  key: number = 0;
  label: string = '';
  icon: Resource;
  activeIcon: Resource;

  constructor(key: number, label: string, icon: Resource, activeIcon: Resource) {
    this.key = key;
    this.label = label;
    this.icon = icon;
    this.activeIcon = activeIcon;
  }
}

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State chats: ChatItem[] = WhatsAppStore.sampleChats();
  @State statuses: StatusItem[] = WhatsAppStore.sampleStatuses();
  @State channels: ChannelItem[] = WhatsAppStore.sampleChannels();
  @State calls: CallItem[] = WhatsAppStore.sampleCalls();
  @State communities: CommunityItem[] = WhatsAppStore.sampleCommunities();
  @State thread: ChatItem = new ChatItem();
  @State threadOpen: boolean = false;
  @State messages: MessageItem[] = [];
  @State live: boolean = false;
  @State linked: boolean = false;
  @State phone: string = '';
  @State oauthConnected: boolean = false;
  @State accountName: string = '';
  @State appearanceMode: string = DISPLAY_MODE_SYSTEM;
  @State unreadTotal: number = 0;
  @State showCompose: boolean = false;
  @State showLink: boolean = false;
  @State showStatusComposer: boolean = false;
  @State showNewChat: boolean = false;
  @State showCallPicker: boolean = false;
  @State showStatusViewer: boolean = false;
  @State viewingStatus: StatusItem = new StatusItem();
  @State webMode: boolean = false;
  @State webReady: boolean = false;
  @State webLive: boolean = false;
  @State storeReady: boolean = false;
  @State loadingOlder: boolean = false;
  @State mediaViewerOpen: boolean = false;
  @State mediaViewerSrc: string = '';
  @State showLinkScreen: boolean = false;
  @State webError: string = '';
  @State callOpen: boolean = false;
  @State activeCall: ChatItem = new ChatItem();
  @State activeCallVideo: boolean = false;
  @State activeCallId: string = '';
  @State incomingCallOpen: boolean = false;
  @State incomingCallId: string = '';
  @State incomingCallFrom: string = '';
  @State incomingCallName: string = '';
  @State incomingCallVideo: boolean = false;
  @StorageProp('whatisit.breakpoint') breakpoint: string = ResponsiveLayout.BREAKPOINT_SM;
  private timer: number | null = null;
  private webTimer: number | null = null;
  private webController: webview.WebviewController = new webview.WebviewController();
  private webChatsSignature: string = '';
  private storeLogged: boolean = false;
  private threadSignature: string = '';
  private webAutoReturn: boolean = true;
  private refreshing: boolean = false;
  private appearance: AppearanceStore = new AppearanceStore();
  private navItems: NavItem[] = [
    new NavItem(0, 'Chats', $r('sys.symbol.message'), $r('sys.symbol.message_fill')),
    new NavItem(1, 'Updates', $r('sys.symbol.circle'), $r('sys.symbol.circle_fill')),
    new NavItem(2, 'Calls', $r('sys.symbol.phone'), $r('sys.symbol.phone_fill')),
    new NavItem(3, 'Communities', $r('sys.symbol.person_2'), $r('sys.symbol.person_2_fill')),
    new NavItem(4, 'Settings', $r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill'))
  ];
  private listener: EventListener = (evt: BackendEvent) => {
    if (evt.type === 'incoming_call' && evt.callId !== undefined) {
      this.handleIncomingCall(evt.callId, evt.from !== undefined ? evt.from : '', evt.video === true);
      return;
    }
    if (evt.type === 'call_state' && this.incomingCallOpen && evt.callId === this.incomingCallId) {
      const state = evt.state !== undefined ? evt.state : '';
      if (state.startsWith('ended') || state === 'rejected' || state === 'missed') {
        this.incomingCallOpen = false;
        this.refresh();
      }
      return;
    }
    if (evt.type === 'linked' || evt.type === 'logged_out' || evt.type === 'message' ||
      evt.type === 'receipt' || evt.type === 'chats' ||
      (evt.type === 'call_state' && !this.callOpen && !this.incomingCallOpen)) {
      this.refresh();
    }
  };

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.appearanceMode = this.appearance.load(ctx);
    authStore.load(ctx).then(() => {
      this.oauthConnected = authStore.isSignedIn();
      this.accountName = authStore.getUserName();
    });
    cdpBridge.setUIContext(ctx);
    cdpBridge.addEventListener(this.listener);
    whatsappWebBridge.attach(this.webController);
    mediaDownloader.init(ctx);
    cdpBridge.startEngine(`${ctx.filesDir}/wa`);
    this.boot();
    this.timer = setInterval(() => {
      this.refresh();
    }, 8000);
    this.webTimer = setInterval(() => {
      this.pollWeb();
    }, 1500);
  }

  /** Poll the hidden WhatsApp Web page and mirror its chat list. */
  private async pollWeb(): Promise<void> {
    if (!this.webReady || this.linked) {
      return;
    }
    const wasLive = this.webLive;
    const isLinked = await whatsappWebBridge.linked();
    this.webLive = isLinked;
    if (!isLinked) {
      this.live = false;
      this.storeReady = false;
      return;
    }
    this.live = true;
    if (this.webMode && !wasLive && this.webAutoReturn) {
      promptAction.showToast({ message: 'WhatsApp linked — returning to the native shell', duration: 1800 });
      setTimeout(() => {
        this.closeWeb();
      }, 1200);
      return;
    }
    if (this.webMode) {
      return;
    }
    this.showLinkScreen = false;
    this.storeReady = await whatsappWebBridge.storeReady();
    hilog.info(DOMAIN, TAG, 'web linked (store=%{public}s)', this.storeReady ? 'yes' : 'no');
    if (this.storeReady && !this.storeLogged) {
      this.storeLogged = true;
      hilog.info(DOMAIN, TAG, 'WhatsApp Web Store is available');
    }
    let webChats = this.storeReady
      ? await whatsappWebBridge.storeChats()
      : await whatsappWebBridge.chats();
    if (webChats.length === 0) {
      webChats = await whatsappWebBridge.chats();
    }
    if (this.storeReady && webChats.length > 0) {
      const domChats = await whatsappWebBridge.chats();
      for (const c of webChats) {
        if (c.avatarUrl.length === 0) {
          for (const d of domChats) {
            if (d.id === c.id) {
              c.avatarUrl = d.avatarUrl;
              break;
            }
          }
        }
      }
    }
    if (webChats.length > 0) {
      let signature = '';
      for (const c of webChats) {
        signature += c.id + '|' + c.name + '|' + c.preview + '|' + c.time + '|' + c.unread + '|' + (c.avatarUrl.length > 0 ? '1' : '0') + ';';
      }
      if (signature !== this.webChatsSignature) {
        this.webChatsSignature = signature;
        this.chats = webChats;
        this.recount();
      }
      this.live = true;
      if (this.threadOpen && !this.webMode) {
        await this.refreshWebThread();
      }
    }
  }

  private async webMessagesFor(chatId: string): Promise<MessageItem[]> {
    const dom = await whatsappWebBridge.messages();
    let hasMedia = false;
    for (const m of dom) {
      if (m.mediaType.length > 0) {
        hasMedia = true;
        break;
      }
    }
    if (hasMedia) {
      for (const m of dom) {
        m.chatId = chatId;
      }
      return dom;
    }
    if (this.storeReady) {
      const stored = await whatsappWebBridge.storeMessages(chatId);
      if (stored.length > 0) {
        for (const m of stored) {
          m.chatId = chatId;
        }
        return stored;
      }
    }
    for (const m of dom) {
      m.chatId = chatId;
    }
    return dom;
  }

  private async refreshWebThread(): Promise<void> {
    if (!this.webLive || !this.threadOpen || this.webMode) {
      return;
    }
    const msgs = await this.webMessagesFor(this.thread.id);
    if (msgs.length === 0) {
      return;
    }
    const lastId = msgs[msgs.length - 1].id;
    const signature = String(msgs.length) + '|' + lastId;
    if (signature === this.threadSignature) {
      return;
    }
    for (const m of msgs) {
      m.chatId = this.thread.id;
    }
    this.threadSignature = signature;
    this.messages = msgs;
  }

  /** Probe the configured native backend once, then attach the WS. */
  private async boot(): Promise<void> {
    await cdpBridge.discoverBackend();
    cdpBridge.openWs();
    await this.refresh();
  }

  aboutToDisappear(): void {
    cdpBridge.removeEventListener(this.listener);
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
    if (this.webTimer !== null) {
      clearInterval(this.webTimer);
      this.webTimer = null;
    }
  }

  onBackPress(): boolean {
    if (this.mediaViewerOpen) {
      this.mediaViewerOpen = false;
      return true;
    }
    if (this.showStatusViewer) {
      this.showStatusViewer = false;
      return true;
    }
    if (this.showCallPicker) {
      this.showCallPicker = false;
      return true;
    }
    if (this.showNewChat) {
      this.showNewChat = false;
      return true;
    }
    if (this.showStatusComposer) {
      this.showStatusComposer = false;
      return true;
    }
    if (this.showLink) {
      this.showLink = false;
      return true;
    }
    if (this.showCompose) {
      this.showCompose = false;
      return true;
    }
    if (this.callOpen) {
      this.closeCall();
      return true;
    }
    if (this.webMode) {
      this.closeWeb();
      return true;
    }
    if (this.threadOpen) {
      this.closeChat();
      return true;
    }
    if (this.tab !== 0) {
      this.tab = 0;
      return true;
    }
    return false;
  }

  private isWide(): boolean {
    return ResponsiveLayout.isWide(this.breakpoint);
  }

  private headerTitle(): string {
    if (this.tab === 1) {
      return 'Updates';
    }
    if (this.tab === 2) {
      return 'Calls';
    }
    if (this.tab === 3) {
      return 'Communities';
    }
    if (this.tab === 4) {
      return 'Settings';
    }
    return 'Chats';
  }

  private headerSubtitle(): string {
    if (this.tab === 1) {
      return 'Status and channels';
    }
    if (this.tab === 2) {
      return 'Voice and video calls';
    }
    if (this.tab === 3) {
      return 'Groups and announcements';
    }
    if (this.tab === 4) {
      return 'Account and preferences';
    }
    return this.unreadTotal > 0 ? String(this.unreadTotal) + ' unread' : 'WhatsApp';
  }

  private async refresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    if (!this.linked && this.webLive) {
      this.live = true;
      this.recount();
      return;
    }
    this.refreshing = true;
    try {
      const st = await cdpBridge.getStatus();
      this.linked = st !== null && st.linked;
      this.phone = st !== null ? st.phone : '';
      if (this.linked) {
        this.showLinkScreen = false;
      }
      if (this.linked) {
        const liveChats = await cdpBridge.scrapeChats();
        if (liveChats.length > 0) {
          this.chats = this.mapChats(liveChats);
        }
        const liveStatuses = await cdpBridge.scrapeStatus();
        if (liveStatuses.length > 0) {
          this.statuses = this.mapStatuses(liveStatuses);
        }
        const liveChannels = await cdpBridge.scrapeChannels();
        if (liveChannels.length > 0) {
          this.channels = this.mapChannels(liveChannels);
        }
        const liveCalls = await cdpBridge.scrapeCalls();
        if (liveCalls.length > 0) {
          this.calls = this.mapCalls(liveCalls);
        }
      }
      this.live = this.linked || this.webLive;
      this.recount();
    } catch (e) {
      // keep the sample content
    } finally {
      this.refreshing = false;
    }
  }

  private recount(): void {
    let total = 0;
    for (const chat of this.chats) {
      total += chat.unread;
    }
    this.unreadTotal = total;
  }

  private mapChats(list: ChatSummary[]): ChatItem[] {
    const out: ChatItem[] = [];
    for (const item of list) {
      const c = new ChatItem();
      c.id = item.id;
      c.name = item.name;
      c.preview = item.preview;
      c.time = item.time;
      c.unread = item.unread;
      c.pinned = item.pinned;
      c.isChannel = item.isChannel;
      c.isGroup = item.id.indexOf('@g.us') >= 0;
      out.push(c);
    }
    return out;
  }

  private mapStatuses(list: ChatSummary[]): StatusItem[] {
    const out: StatusItem[] = [];
    for (const item of list) {
      const s = new StatusItem();
      s.id = item.id;
      s.name = item.name;
      s.time = item.time;
      s.text = item.preview;
      s.color = Theme.avatarColor(item.id);
      out.push(s);
    }
    return out;
  }

  private mapChannels(list: ChannelSummary[]): ChannelItem[] {
    const out: ChannelItem[] = [];
    for (const item of list) {
      const c = new ChannelItem();
      c.id = item.id;
      c.name = item.name;
      c.description = item.description;
      c.followers = item.subscribers;
      c.unread = item.updates;
      out.push(c);
    }
    return out;
  }

  private mapCalls(list: CallRecord[]): CallItem[] {
    const out: CallItem[] = [];
    for (const item of list) {
      const c = new CallItem();
      c.id = item.id;
      c.name = item.name.length > 0 ? item.name : item.peer;
      c.video = item.video;
      c.incoming = item.dir === 'in';
      c.missed = item.missed;
      c.time = item.time;
      out.push(c);
    }
    return out;
  }

  private mapMessages(list: MessageEntry[], chatId: string): MessageItem[] {
    const out: MessageItem[] = [];
    for (const item of list) {
      const m = new MessageItem();
      m.id = item.id;
      m.chatId = chatId;
      m.text = item.text;
      m.time = item.time;
      m.out = item.dir === 'out';
      m.status = item.status;
      out.push(m);
    }
    return out;
  }

  private async openChat(chat: ChatItem): Promise<void> {
    this.thread = chat;
    this.threadOpen = true;
    this.messages = WhatsAppStore.sampleMessages(chat.id, chat.name);
    for (const c of this.chats) {
      if (c.id === chat.id) {
        c.unread = 0;
      }
    }
    this.chats = this.chats.slice();
    this.recount();
    if (this.linked) {
      const liveMessages = await cdpBridge.scrapeMessages(chat.id);
      if (liveMessages.length > 0) {
        this.messages = this.mapMessages(liveMessages, chat.id);
      }
      cdpBridge.markRead(chat.id);
    } else if (this.webLive) {
      const opened = await whatsappWebBridge.openChat(chat.id);
      if (opened) {
        await this.delay(450);
        const webMessages = await this.webMessagesFor(chat.id);
        if (webMessages.length > 0) {
          for (const wm of webMessages) {
            wm.chatId = chat.id;
          }
          this.messages = webMessages;
        } else {
          this.messages = [];
        }
      }
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  private async openMedia(message: MessageItem): Promise<void> {
    if (this.webLive && !this.linked && message.mediaType === 'image') {
      const full = await whatsappWebBridge.fullImage(message.id);
      const src = full.length > 0 ? full : message.mediaUrl;
      if (src.length > 0) {
        const saved = await mediaDownloader.saveDataUrl(src, 'jpg');
        this.mediaViewerSrc = saved.length > 0 ? saved : src;
        this.mediaViewerOpen = true;
        return;
      }
    }
    if (this.webLive && !this.linked) {
      this.webAutoReturn = false;
      this.webMode = true;
      promptAction.showToast({ message: 'Opening media in WhatsApp Web', duration: 1600 });
      return;
    }
    promptAction.showToast({ message: 'Media is available in Web or live mode', duration: 1600 });
  }

  private attach(): void {
    if (this.webLive && !this.linked) {
      this.webAutoReturn = false;
      this.webMode = true;
      promptAction.showToast({ message: 'Use WhatsApp Web to attach a file', duration: 1800 });
      return;
    }
    promptAction.showToast({ message: 'Attachments are available in live or Web mode', duration: 1800 });
  }

  private async loadOlder(): Promise<void> {
    if (this.linked || !this.webLive || this.loadingOlder) {
      return;
    }
    this.loadingOlder = true;
    try {
      if (this.storeReady) {
        const stored = await whatsappWebBridge.storeMessages(this.thread.id);
        if (stored.length > this.messages.length) {
          for (const wm of stored) {
            wm.chatId = this.thread.id;
          }
          this.messages = stored;
        }
        return;
      }
      await whatsappWebBridge.scrollOlder();
      await this.delay(900);
      const webMessages = await whatsappWebBridge.messages();
      if (webMessages.length > 0) {
        for (const wm of webMessages) {
          wm.chatId = this.thread.id;
        }
        this.messages = webMessages;
      }
    } finally {
      this.loadingOlder = false;
    }
  }

  private closeChat(): void {
    this.threadOpen = false;
    this.refresh();
  }

  private async sendMessage(text: string): Promise<void> {
    const m = new MessageItem();
    m.id = 'local-' + Date.now();
    m.chatId = this.thread.id;
    m.text = text;
    m.time = this.nowTime();
    m.out = true;
    m.status = (this.linked || this.webLive) ? 'sent' : '';
    this.messages = this.messages.concat([m]);
    this.thread.preview = text;
    this.thread.time = m.time;
    this.chats = this.chats.slice();
    if (this.linked) {
      const ok = await cdpBridge.sendMessageToChat(this.thread.id, text);
      if (!ok) {
        m.status = 'failed';
        this.messages = this.messages.slice();
        promptAction.showToast({ message: 'Message not sent — check the linked device', duration: 1800 });
      }
    } else if (this.webLive) {
      const ok = await whatsappWebBridge.send(text);
      if (!ok) {
        m.status = 'failed';
        this.messages = this.messages.slice();
        promptAction.showToast({ message: 'Message not sent — WhatsApp Web is not ready', duration: 1800 });
      } else {
        await this.delay(500);
        const webMessages = await this.webMessagesFor(this.thread.id);
        if (webMessages.length > 0) {
          for (const wm of webMessages) {
            wm.chatId = this.thread.id;
          }
          this.messages = webMessages;
        }
      }
    } else {
      promptAction.showToast({ message: 'Preview message added. Link a device to send.', duration: 1800 });
    }
  }

  private nowTime(): string {
    const d = new Date();
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return hh + ':' + mm;
  }

  private async startCall(chat: ChatItem, video: boolean): Promise<void> {
    if (!this.linked && !this.webLive) {
      promptAction.showToast({ message: 'Link a device to start a call', duration: 1800 });
      return;
    }
    if (this.webLive && !this.linked) {
      this.webAutoReturn = false;
      this.webMode = true;
      promptAction.showToast({ message: 'Use the WhatsApp Web call screen', duration: 1800 });
      return;
    }
    const ok = await callService.startCall(chat.id, video);
    if (!ok) {
      promptAction.showToast({ message: 'Could not start the call', duration: 1800 });
      return;
    }
    const callId = callService.getActiveCallId();
    if (callId.length === 0) {
      promptAction.showToast({ message: 'The call could not be established', duration: 1800 });
      return;
    }
    this.activeCall = chat;
    this.activeCallVideo = video;
    this.activeCallId = callId;
    this.callOpen = true;
  }

  private async closeCall(): Promise<void> {
    await callService.endCall();
    this.callOpen = false;
  }

  private handleIncomingCall(callId: string, from: string, video: boolean): void {
    if (this.callOpen || this.incomingCallOpen) {
      return;
    }
    this.incomingCallId = callId;
    this.incomingCallFrom = from;
    this.incomingCallVideo = video;
    let name = '';
    for (const chat of this.chats) {
      if (chat.id === from) {
        name = chat.name;
        break;
      }
    }
    if (name.length === 0) {
      const at = from.indexOf('@');
      name = at > 0 ? from.substring(0, at) : from;
    }
    this.incomingCallName = name;
    this.incomingCallOpen = true;
    this.refresh();
  }

  private async acceptIncomingCall(): Promise<void> {
    if (!this.incomingCallOpen) {
      return;
    }
    const callId = this.incomingCallId;
    const from = this.incomingCallFrom;
    const video = this.incomingCallVideo;
    const name = this.incomingCallName;
    this.incomingCallOpen = false;
    const ok = await callService.acceptCall(callId, video);
    if (!ok) {
      promptAction.showToast({ message: 'Could not accept the call', duration: 1800 });
      this.refresh();
      return;
    }
    let chat: ChatItem | null = null;
    for (const item of this.chats) {
      if (item.id === from) {
        chat = item;
        break;
      }
    }
    if (chat === null) {
      chat = new ChatItem();
      chat.id = from;
      chat.name = name;
    }
    this.activeCall = chat;
    this.activeCallVideo = video;
    this.activeCallId = callId;
    this.callOpen = true;
  }

  private async rejectIncomingCall(): Promise<void> {
    if (!this.incomingCallOpen) {
      return;
    }
    const callId = this.incomingCallId;
    this.incomingCallOpen = false;
    await callService.rejectCall(callId);
    promptAction.showToast({ message: 'Call declined', duration: 1200 });
    this.refresh();
  }

  private async postStatus(text: string): Promise<void> {
    this.showStatusComposer = false;
    if (this.linked) {
      const ok = await cdpBridge.sendStatus(text);
      if (!ok) {
        promptAction.showToast({ message: 'Could not post the status', duration: 1800 });
        return;
      }
    }
    const s = new StatusItem();
    s.id = 'my-status-' + Date.now();
    s.name = 'My status';
    s.time = 'now';
    s.text = text;
    s.viewed = true;
    s.color = Theme.avatarColor('me');
    this.statuses = [s].concat(this.statuses);
    promptAction.showToast({ message: this.linked ? 'Status posted' : 'Status added in preview', duration: 1600 });
  }

  private async newChat(value: string): Promise<void> {
    this.showNewChat = false;
    const existing = this.chats.find((c: ChatItem) => c.name.toLowerCase() === value.toLowerCase());
    if (existing !== undefined) {
      this.openChat(existing);
      return;
    }
    if (this.webLive && !this.linked) {
      const searched = await whatsappWebBridge.search(value);
      if (!searched) {
        promptAction.showToast({ message: 'Could not search WhatsApp Web', duration: 1800 });
        return;
      }
      await this.delay(1200);
      const opened = await whatsappWebBridge.openFirstResult(value);
      if (!opened) {
        promptAction.showToast({ message: 'No matching WhatsApp chat found', duration: 1800 });
        return;
      }
      await this.delay(600);
      const webChats = this.storeReady
        ? await whatsappWebBridge.storeChats()
        : await whatsappWebBridge.chats();
      if (webChats.length > 0) {
        this.chats = webChats;
        this.recount();
      }
      const match = this.chats.find((c: ChatItem) => c.name.toLowerCase().indexOf(value.toLowerCase()) >= 0);
      if (match !== undefined) {
        this.openChat(match);
      }
      return;
    }
    const digits = value.replace(/[^0-9]/g, '');
    const c = new ChatItem();
    c.id = digits.length >= 7 ? digits + '@s.whatsapp.net' : value.toLowerCase().replace(/[^a-z0-9]/g, '') + '@s.whatsapp.net';
    c.name = value;
    c.preview = 'New conversation';
    c.time = this.nowTime();
    this.chats = [c].concat(this.chats);
    this.openChat(c);
  }

  private toggleCommunity(id: string): void {
    for (const c of this.communities) {
      if (c.id === id) {
        c.joined = !c.joined;
      }
    }
    this.communities = this.communities.slice();
  }

  private setAppearance(mode: string): void {
    this.appearanceMode = mode;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.appearance.save(ctx, mode);
    try {
      ctx.getApplicationContext().setColorMode(this.appearance.colorMode(mode));
    } catch (e) {
      // best effort
    }
  }

  private async logout(): Promise<void> {
    await cdpBridge.logout();
    this.linked = false;
    this.live = false;
    this.threadOpen = false;
    this.refresh();
    promptAction.showToast({ message: 'Logged out of the linked device', duration: 1800 });
  }

  private reloadWeb(): void {
    this.webReady = false;
    this.webError = '';
    try {
      this.webController.loadUrl('https://web.whatsapp.com');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'web reload failed: %{public}s', JSON.stringify(e));
    }
  }

  private openWeb(): void {
    hilog.info(DOMAIN, TAG, 'open WhatsApp Web mode');
    this.showLink = false;
    this.webAutoReturn = true;
    this.webMode = true;
    promptAction.showToast({ message: 'Web view open — tap Native UI to return', duration: 2000 });
  }

  private async closeWeb(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'close WhatsApp Web mode');
    this.webMode = false;
    await this.pollWeb();
    await this.refresh();
  }

  private onComposeAction(action: string): void {
    this.showCompose = false;
    if (action === 'new-chat') {
      this.showNewChat = true;
    } else if (action === 'link') {
      this.showLink = true;
    } else if (action === 'status-text') {
      this.showStatusComposer = true;
    } else if (action === 'voice-call' || action === 'video-call') {
      this.showCallPicker = true;
    } else if (action === 'find-channels' || action === 'channel-update') {
      this.tab = 1;
    } else if (action === 'new-community' || action === 'find-communities') {
      this.tab = 3;
    } else if (action === 'appearance' || action === 'edit-profile') {
      this.tab = 4;
    } else {
      promptAction.showToast({ message: 'This action is available after linking a device.', duration: 1800 });
    }
  }

  @Builder
  Header() {
    Row({ space: 10 }) {
      Column({ space: 1 }) {
        Text(this.headerTitle())
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
        Text(this.headerSubtitle())
          .fontSize(12)
          .fontColor($r('app.color.ink_subtle'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 5 }) {
        Circle({ width: 6, height: 6 })
          .fill(this.live ? $r('app.color.connected') : $r('app.color.ink_faded'))
        Text(this.linked ? 'Live' : (this.webLive ? 'Web' : 'Preview'))
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.live ? $r('app.color.connected') : $r('app.color.ink_subtle'))
      }
      .padding({ left: 8, right: 8, top: 5, bottom: 5 })
      .backgroundColor(this.live ? $r('app.color.brand_soft') : $r('app.color.surface_subtle'))
      .borderRadius(12)

      Row() {
        Avatar({ label: 'You', seed: 'me', avatarSize: 34, online: this.linked })
      }
      .onClick(() => {
        this.tab = 4;
      })
    }
    .width('100%')
    .height(62)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  TabBar() {
    Row() {
      ForEach(this.navItems, (item: NavItem) => {
        Column({ space: 3 }) {
          Stack({ alignContent: Alignment.TopEnd }) {
            SymbolGlyph(this.tab === item.key ? item.activeIcon : item.icon)
              .fontSize(22)
              .fontColor([this.tab === item.key ? $r('app.color.brand') : $r('app.color.tab_inactive')])
            if (item.key === 0 && this.unreadTotal > 0) {
              Text(this.unreadTotal > 99 ? '99+' : String(this.unreadTotal))
                .fontSize(9)
                .fontColor($r('app.color.brand_text'))
                .padding({ left: 4, right: 4 })
                .height(15)
                .backgroundColor($r('app.color.brand'))
                .borderRadius(8)
                .position({ x: 18, y: -4 })
            }
          }
          .width(30)
          .height(24)

          Text(item.label)
            .fontSize(9)
            .fontWeight(this.tab === item.key ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.tab === item.key ? $r('app.color.brand') : $r('app.color.tab_inactive'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .height(58)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.tab = item.key;
          this.threadOpen = false;
        })
      }, (item: NavItem) => String(item.key))
    }
    .width('100%')
    .height(60)
    .backgroundColor($r('app.color.surface'))
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  @Builder
  SideRail() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 38, height: 38 })
          .fill($r('app.color.brand'))
        SymbolGlyph($r('sys.symbol.message_fill'))
          .fontSize(20)
          .fontColor([$r('app.color.brand_text')])
      }
      .margin({ top: 16, bottom: 18 })

      ForEach(this.navItems, (item: NavItem) => {
        Column({ space: 3 }) {
          SymbolGlyph(this.tab === item.key ? item.activeIcon : item.icon)
            .fontSize(22)
            .fontColor([this.tab === item.key ? $r('app.color.brand') : $r('app.color.tab_inactive')])
          Text(item.label)
            .fontSize(9)
            .fontColor(this.tab === item.key ? $r('app.color.brand') : $r('app.color.tab_inactive'))
            .maxLines(1)
          if (item.key === 0 && this.unreadTotal > 0) {
            Text(String(this.unreadTotal))
              .fontSize(9)
              .fontColor($r('app.color.brand_text'))
              .padding({ left: 4, right: 4 })
              .backgroundColor($r('app.color.brand'))
              .borderRadius(7)
          }
        }
        .width(64)
        .padding({ top: 8, bottom: 8 })
        .margin({ bottom: 4 })
        .backgroundColor(this.tab === item.key ? $r('app.color.brand_soft') : Color.Transparent)
        .borderRadius(12)
        .onClick(() => {
          this.tab = item.key;
          this.threadOpen = false;
        })
      }, (item: NavItem) => 'rail-' + String(item.key))

      Blank()

      Row() {
        Avatar({ label: 'You', seed: 'me', avatarSize: 34, online: this.linked })
      }
      .margin({ bottom: 18 })
      .onClick(() => {
        this.tab = 4;
      })
    }
    .width(80)
    .height('100%')
    .padding({ top: 4 })
    .backgroundColor($r('app.color.surface'))
    .border({ width: { right: 0.5 }, color: $r('app.color.divider') })
  }

  @Builder
  Content() {
    if (this.tab === 0) {
      ChatsPane({
        chats: this.chats,
        live: this.live,
        onOpen: (chat: ChatItem) => {
          this.openChat(chat);
        },
        onLink: () => {
          this.showLink = true;
        }
      })
    } else if (this.tab === 1) {
      UpdatesPane({
        statuses: this.statuses,
        channels: this.channels,
        live: this.live,
        onComposeStatus: () => {
          this.showStatusComposer = true;
        },
        onViewStatus: (status: StatusItem) => {
          this.viewingStatus = status;
          this.showStatusViewer = true;
        },
        onFindChannels: () => {
          promptAction.showToast({ message: 'Channel discovery is available after linking a device.', duration: 1600 });
        },
        onOpenChannel: (channel: ChannelItem) => {
          promptAction.showToast({ message: channel.name, duration: 1200 });
        }
      })
    } else if (this.tab === 2) {
      CallsPane({
        calls: this.calls,
        live: this.live,
        onNewCall: () => {
          this.showCallPicker = true;
        },
        onCallBack: (name: string, video: boolean) => {
          const chat = this.chats.find((c: ChatItem) => c.name === name);
          if (chat !== undefined) {
            this.startCall(chat, video);
          } else {
            const fallback = new ChatItem();
            fallback.id = name;
            fallback.name = name;
            this.startCall(fallback, video);
          }
        }
      })
    } else if (this.tab === 3) {
      CommunitiesPane({
        communities: this.communities,
        onToggleJoin: (id: string) => {
          this.toggleCommunity(id);
        },
        onDiscover: () => {
          promptAction.showToast({ message: 'Community discovery is a preview in this build.', duration: 1600 });
        }
      })
    } else {
      SettingsPane({
        linked: this.linked,
        phone: this.phone,
        oauthConnected: this.oauthConnected,
        accountName: this.accountName,
        appearanceMode: this.appearanceMode,
        live: this.live,
        onLink: () => {
          this.showLink = true;
        },
        onWebLink: () => {
          this.openWeb();
        },
        onLogout: () => {
          this.logout();
        },
        onAppearance: (mode: string) => {
          this.setAppearance(mode);
        },
        onSignedOut: () => {
          this.oauthConnected = false;
          this.accountName = '';
        }
      })
    }
  }

  @Builder
  WebStatusBanner() {
    if (!this.linked && !this.webLive) {
      Row({ space: 8 }) {
        Circle({ width: 6, height: 6 })
          .fill(this.webError.length > 0 ? $r('app.color.danger') : $r('app.color.warning'))
        Text(!this.webReady ? (this.webError.length > 0 ? this.webError : 'Loading WhatsApp Web…') : 'WhatsApp Web not connected')
          .fontSize(11)
          .fontColor($r('app.color.ink_subtle'))
          .layoutWeight(1)
        Button(this.webReady ? 'Open Web' : 'Retry')
          .height(28)
          .fontSize(11)
          .fontColor($r('app.color.brand'))
          .backgroundColor($r('app.color.brand_soft'))
          .borderRadius(14)
          .onClick(() => {
            if (this.webReady) {
              this.openWeb();
            } else {
              this.reloadWeb();
            }
          })
        Button('Link')
          .height(28)
          .fontSize(11)
          .fontColor($r('app.color.ink_subtle'))
          .backgroundColor($r('app.color.surface'))
          .borderRadius(14)
          .onClick(() => {
            this.showLinkScreen = true;
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor($r('app.color.surface_subtle'))
    }
  }

  build() {
    Stack() {
      Web({ src: 'https://web.whatsapp.com', controller: this.webController })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .userAgent(WEB_DESKTOP_UA)
        .javaScriptOnDocumentStart([
          {
            script: WA_NATIVE_SHIM,
            scriptRules: ['https://web.whatsapp.com', 'https://web.whatsapp.com/*']
          }
        ])
        .onPageBegin((event) => {
          this.webReady = false;
          this.webError = '';
          hilog.info(DOMAIN, TAG, 'web session begin: %{public}s', event.url);
        })
        .onPageEnd((event) => {
          hilog.info(DOMAIN, TAG, 'web session ready: %{public}s', event.url);
          this.webReady = true;
          this.pollWeb();
        })
        .onErrorReceive((event) => {
          this.webError = 'WhatsApp Web failed to load';
          hilog.warn(DOMAIN, TAG, 'web session error: %{public}s', JSON.stringify(event.error));
        })

      if (!this.webMode && this.showLinkScreen && !this.linked) {
        NativeLinkView({
          onLinked: () => {
            this.showLinkScreen = false;
            this.webLive = true;
            this.live = true;
            this.pollWeb();
            this.refresh();
          },
          onWeb: () => {
            this.openWeb();
          },
          onSkip: () => {
            this.showLinkScreen = false;
            promptAction.showToast({ message: 'Native shell opened — use Settings → WhatsApp Web to load chats', duration: 2400 });
          }
        })
          .width('100%')
          .height('100%')
      } else if (!this.webMode) {
        Row() {
          if (this.isWide()) {
            this.SideRail()
          }
          Column() {
            if (!this.threadOpen) {
              this.Header()
            }
            this.WebStatusBanner()
            Stack({ alignContent: Alignment.BottomEnd }) {
              if (this.threadOpen) {
                ConversationView({
                  chat: this.thread,
                  messages: this.messages,
                  live: this.live,
                  loadingOlder: this.loadingOlder,
                  onBack: () => {
                    this.closeChat();
                  },
                  onSend: (text: string) => {
                    this.sendMessage(text);
                  },
                  onCall: (video: boolean) => {
                    this.startCall(this.thread, video);
                  },
                  onLoadOlder: () => {
                    this.loadOlder();
                  },
                  onAttachTap: () => {
                    this.attach();
                  },
                  onOpenMedia: (message: MessageItem) => {
                    this.openMedia(message);
                  }
                })
              } else {
                this.Content()
              }
              if (!this.threadOpen && this.tab !== 4) {
                FloatingCompose({
                  bottomInset: this.isWide() ? 20 : 82,
                  icon: this.tab === 1 ? $r('sys.symbol.square_and_pencil') :
                    (this.tab === 2 ? $r('sys.symbol.phone') : $r('sys.symbol.square_and_pencil')),
                  onTap: () => {
                    this.showCompose = true;
                  }
                })
              }
            }
            .width('100%')
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_page'))

            if (!this.isWide() && !this.threadOpen) {
              this.TabBar()
            }
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor($r('app.color.bg_page'))
        }
        .width('100%')
        .height('100%')
      }

      if (this.webMode) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor(['#FFFFFF'])
            .onClick(() => {
              this.closeWeb();
            })
          Text('WhatsApp Web')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
          Blank()
          Text('Native UI')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#25D366')
            .padding({ left: 8, right: 12 })
            .onClick(() => {
              this.closeWeb();
            })
          Text('Close')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.closeWeb();
            })
        }
        .width('100%')
        .height(44)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#111B21')
        .position({ x: 0, y: 0 })
      }

      if (this.showCompose) {
        ComposeSheet({
          tab: this.tab,
          onClose: () => {
            this.showCompose = false;
          },
          onAction: (action: string) => {
            this.onComposeAction(action);
          }
        })
      }

      if (this.showLink) {
        LinkDeviceSheet({
          initialMode: 'qr',
          onClose: () => {
            this.showLink = false;
            this.refresh();
          },
          onWeb: () => {
            this.openWeb();
          },
          onLinked: () => {
            this.showLink = false;
            this.refresh();
          }
        })
      }

      if (this.showStatusComposer) {
        StatusComposerSheet({
          onClose: () => {
            this.showStatusComposer = false;
          },
          onPost: (text: string) => {
            this.postStatus(text);
          }
        })
      }

      if (this.showNewChat) {
        NewChatSheet({
          onClose: () => {
            this.showNewChat = false;
          },
          onStart: (value: string) => {
            this.newChat(value);
          }
        })
      }

      if (this.showCallPicker) {
        CallPickerSheet({
          chats: this.chats,
          onClose: () => {
            this.showCallPicker = false;
          },
          onCall: (chat: ChatItem, video: boolean) => {
            this.showCallPicker = false;
            this.startCall(chat, video);
          }
        })
      }

      if (this.showStatusViewer) {
        StatusViewer({
          status: this.viewingStatus,
          onClose: () => {
            this.showStatusViewer = false;
          }
        })
      }

      if (this.mediaViewerOpen) {
        MediaViewer({
          src: this.mediaViewerSrc,
          onClose: () => {
            this.mediaViewerOpen = false;
          }
        })
          .width('100%')
          .height('100%')
      }

      if (this.incomingCallOpen) {
        IncomingCallSheet({
          callerName: this.incomingCallName,
          callerHandle: this.incomingCallFrom,
          isVideo: this.incomingCallVideo,
          onAccept: () => {
            this.acceptIncomingCall();
          },
          onReject: () => {
            this.rejectIncomingCall();
          }
        })
          .width('100%')
          .height('100%')
      }

      if (this.callOpen) {
        CallSurfaceView({
          chatName: this.activeCall.name,
          callId: this.activeCallId,
          isVideo: this.activeCallVideo,
          onClose: () => {
            this.closeCall();
          }
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
