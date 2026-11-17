/**
 * HybridShell — Path A native chrome around a visible WhatsApp Web session.
 *
 * No hidden WebView, no DOM shim, no Store bridge. The native shell owns the
 * header, tabs and settings; WhatsApp Web owns the Chats content. Native panes
 * can take over individual tabs incrementally.
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { waEngine } from '../services/WaEngine';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ResponsiveLayout } from '../services/ResponsiveLayout';
import { CallsPane } from '../components/CallsPane';
import { UpdatesPane } from '../components/UpdatesPane';
import { CommunitiesPane } from '../components/CommunitiesPane';
import { SettingsPane } from '../components/SettingsPane';
import { ChatsPane } from '../components/ChatsPane';
import { ConversationView } from '../components/ConversationView';
import { WhatsAppStore } from '../services/WhatsAppStore';
import { ChatItem, MessageItem } from '../models/WhatsAppModels';

const TAG = 'HybridShell';
const DOMAIN = 0x0000;
const FIT_VIEWPORT_SCRIPT: string =
  '(function(){function set(){var m=document.querySelector(\'meta[name="viewport"]\');' +
  'if(!m){m=document.createElement(\'meta\');m.name=\'viewport\';' +
  '(document.head||document.documentElement).appendChild(m);}' +
  'if(m){m.setAttribute(\'content\',\'width=820, initial-scale=0.44, minimum-scale=0.25, maximum-scale=1, user-scalable=no\');}}' +
  'set();setTimeout(set,300);setTimeout(set,1500);})();';

const NATURAL_VIEWPORT_SCRIPT: string =
  '(function(){var m=document.querySelector(\'meta[name="viewport"]\');' +
  'if(!m){m=document.createElement(\'meta\');m.name=\'viewport\';' +
  '(document.head||document.documentElement).appendChild(m);}' +
  'if(m){m.setAttribute(\'content\',\'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no\');}})();';

const PHONE_LAYOUT_JS: string = `
(function () {
  if (window.__waPhonePane) return;
  window.__waPhonePane = true;
  var style = document.createElement('style');
  style.id = 'wa-phone-pane';
  style.textContent =
    'html, body, #app { overflow: hidden !important; width: 100vw !important; height: 100% !important; }' +
    'body.wa-phone-list #side, body.wa-phone-chat #side {' +
    ' position: fixed !important; left: 0 !important; top: 0 !important; bottom: 0 !important;' +
    ' width: 100vw !important; max-width: 100vw !important; height: 100% !important;' +
    ' z-index: 2 !important; transform: translateX(0);' +
    ' transition: transform 220ms cubic-bezier(.2,.8,.2,1); will-change: transform; }' +
    'body.wa-phone-list #main, body.wa-phone-chat #main {' +
    ' position: fixed !important; left: 0 !important; top: 0 !important; bottom: 0 !important;' +
    ' width: 100vw !important; max-width: 100vw !important; height: 100% !important;' +
    ' z-index: 3 !important; transform: translateX(100%);' +
    ' transition: transform 220ms cubic-bezier(.2,.8,.2,1); will-change: transform; }' +
    'body.wa-phone-chat #side { transform: translateX(-100%) !important; }' +
    'body.wa-phone-chat #main { transform: translateX(0) !important; }' +
    '#side [data-testid="navbar"], #side nav, .wa-phone-rail { display: none !important; }' +
    'html { touch-action: manipulation; }';
  (document.head || document.documentElement).appendChild(style);

  function mainOpen() {
    var main = document.querySelector('#main');
    return !!(main && (main.querySelector('[data-testid="conversation-panel-messages"]') ||
      main.querySelector('.copyable-area')));
  }
  function linked() {
    return !!document.querySelector('#pane-side [role="listitem"]');
  }
  function hideRail() {
    var side = document.querySelector('#side');
    if (!side) return;
    var node = side;
    for (var depth = 0; depth < 3 && node; depth++) {
      var parent = node.parentElement;
      if (!parent) break;
      for (var i = 0; i < parent.children.length; i++) {
        var el = parent.children[i];
        if (el === node) continue;
        var r = el.getBoundingClientRect();
        if (r.width > 0 && r.width < 130 && r.height > 280) {
          el.classList.add('wa-phone-rail');
        }
      }
      node = parent;
    }
    var nodes = document.querySelectorAll('div, nav');
    for (var j = 0; j < nodes.length; j++) {
      var rr = nodes[j].getBoundingClientRect();
      if (rr.left <= 2 && rr.width >= 40 && rr.width <= 130 && rr.height > window.innerHeight * 0.5) {
        nodes[j].classList.add('wa-phone-rail');
      }
    }
  }
  function showChat() {
    document.body.classList.remove('wa-phone-list');
    document.body.classList.add('wa-phone-chat');
  }
  function sync() {
    hideRail();
    if (!linked()) {
      document.body.classList.remove('wa-phone-list');
      document.body.classList.remove('wa-phone-chat');
      return;
    }
    if (document.body.classList.contains('wa-phone-list')) {
      document.body.classList.remove('wa-phone-chat');
      return;
    }
    if (mainOpen()) {
      showChat();
    } else {
      document.body.classList.add('wa-phone-list');
      document.body.classList.remove('wa-phone-chat');
    }
  }
  document.addEventListener('click', function (e) {
    var row = e.target && e.target.closest ? e.target.closest('#pane-side [role="listitem"]') : null;
    if (row) {
      document.body.classList.remove('wa-phone-list');
      setTimeout(showChat, 40);
      setTimeout(sync, 180);
    }
  }, true);

  var startX = 0;
  var startY = 0;
  var tracking = false;
  document.addEventListener('touchstart', function (e) {
    if (!document.body.classList.contains('wa-phone-chat')) return;
    if (!e.touches || e.touches.length !== 1) return;
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
    tracking = startX < 32;
  }, { passive: true, capture: true });
  document.addEventListener('touchmove', function (e) {
    if (!tracking || !e.touches || e.touches.length !== 1) return;
    var dx = e.touches[0].clientX - startX;
    var dy = Math.abs(e.touches[0].clientY - startY);
    if (dx > 10 && dx > dy) {
      e.preventDefault();
    }
  }, { passive: false, capture: true });
  document.addEventListener('touchend', function (e) {
    if (!tracking) return;
    tracking = false;
    if (!e.changedTouches || e.changedTouches.length === 0) return;
    var dx = e.changedTouches[0].clientX - startX;
    if (dx > 60) {
      document.body.classList.remove('wa-phone-chat');
      document.body.classList.add('wa-phone-list');
    }
  }, { passive: true, capture: true });

  var obs = new MutationObserver(sync);
  obs.observe(document.body, { childList: true, subtree: true });
  sync();
})();
`;

const WEB_DESKTOP_UA: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

class NavItem {
  index: number = 0;
  label: string = '';
  icon: Resource = $r('sys.symbol.message');
  constructor(index: number, label: string, icon: Resource) {
    this.index = index;
    this.label = label;
    this.icon = icon;
  }
}

@Entry
@Component
struct HybridShell {
  @StorageProp('whatisit.breakpoint') breakpoint: string = ResponsiveLayout.BREAKPOINT_SM;
  @State tab: number = 0;
  @State webLoading: boolean = true;
  @State webReady: boolean = false;
  @State webError: string = '';
  @State appearanceMode: string = 'system';
  @State chatMode: string = 'web';
  @State nativeChats: ChatItem[] = WhatsAppStore.sampleChats();
  @State nativeThread: ChatItem = new ChatItem();
  @State nativeMessages: MessageItem[] = [];
  @State nativeThreadOpen: boolean = false;
  @State phoneFit: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private navItems: NavItem[] = [
    new NavItem(0, 'Chats', $r('sys.symbol.message')),
    new NavItem(1, 'Updates', $r('sys.symbol.circle')),
    new NavItem(2, 'Calls', $r('sys.symbol.phone')),
    new NavItem(3, 'Communities', $r('sys.symbol.person_2')),
    new NavItem(4, 'Settings', $r('sys.symbol.gearshape'))
  ];

  aboutToAppear(): void {
    // Phase 0 engine probe: verifies libwa_engine.so / QR events without
    // depending on the WebView. Harmless when the .so is absent.
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      waEngine.setEventCallback((type: string, json: string) => {
        hilog.info(DOMAIN, TAG, 'engine event: %{public}s', type);
      });
      waEngine.start(`${ctx.filesDir}/wa`);
      hilog.info(DOMAIN, TAG, 'engine ready=%{public}s status=%{public}s',
        String(waEngine.isReady()), waEngine.status());
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'engine probe failed: %{public}s', JSON.stringify(e));
    }
  }

  private isWide(): boolean {
    return ResponsiveLayout.isWide(this.breakpoint);
  }

  private applyPhoneLayout(): void {
    if (this.isWide()) {
      return;
    }
    try {
      this.controller.runJavaScript(PHONE_LAYOUT_JS);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'phone layout failed: %{public}s', JSON.stringify(e));
    }
  }

  private showPhoneList(): void {
    try {
      this.controller.runJavaScript(
        "document.body.classList.add('wa-phone-list');document.body.classList.remove('wa-phone-chat');"
      );
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'phone list failed: %{public}s', JSON.stringify(e));
    }
  }

  private reload(): void {
    this.webLoading = true;
    this.webError = '';
    try {
      this.controller.refresh();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh failed: %{public}s', JSON.stringify(e));
      try {
        this.controller.loadUrl('https://web.whatsapp.com');
      } catch (e2) {
        this.webError = 'Could not reload WhatsApp Web';
      }
    }
  }

  @Builder
  Header() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 30, height: 30 })
          .fill($r('app.color.brand'))
        Text('W')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand_text'))
      }
      .width(30)
      .height(30)
      Column({ space: 1 }) {
        Text('WhatIsIt')
          .fontSize(this.isWide() ? 17 : 15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.isWide()) {
          Text('WhatsApp Web')
            .fontSize(10)
            .fontColor($r('app.color.ink_subtle'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!this.isWide() && this.tab === 0) {
        Text('List')
          .fontSize(10)
          .fontColor($r('app.color.brand'))
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .onClick(() => {
            this.showPhoneList();
          })
      }

      if (this.tab === 0) {
        Row({ space: 2 }) {
          Text('Web')
            .fontSize(10)
            .fontColor(this.chatMode === 'web' ? $r('app.color.brand_text') : $r('app.color.ink_subtle'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.chatMode === 'web' ? $r('app.color.brand') : Color.Transparent)
            .borderRadius(10)
            .onClick(() => {
              this.chatMode = 'web';
            })
          Text('Native')
            .fontSize(10)
            .fontColor(this.chatMode === 'native' ? $r('app.color.brand_text') : $r('app.color.ink_subtle'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.chatMode === 'native' ? $r('app.color.brand') : Color.Transparent)
            .borderRadius(10)
            .onClick(() => {
              this.chatMode = 'native';
            })
        }
        .padding(2)
        .backgroundColor($r('app.color.surface_subtle'))
        .borderRadius(12)
      }

      if (this.isWide()) {
        Row({ space: 6 }) {
          Circle({ width: 6, height: 6 })
            .fill(this.webReady ? $r('app.color.connected') : $r('app.color.warning'))
          Text(this.webLoading ? 'Loading' : (this.webReady ? 'Connected' : 'Offline'))
            .fontSize(10)
            .fontColor($r('app.color.ink_subtle'))
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor($r('app.color.surface_subtle'))
        .borderRadius(12)
      }

      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(20)
        .fontColor([$r('app.color.ink_subtle')])
        .padding(6)
        .onClick(() => {
          this.reload();
        })
    }
    .width('100%')
    .height(54)
    .padding({ left: 12, right: 10 })
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  NavButton(item: NavItem) {
    Column({ space: 3 }) {
      SymbolGlyph(item.icon)
        .fontSize(this.tab === item.index ? 22 : 20)
        .fontColor([this.tab === item.index ? $r('app.color.brand') : $r('app.color.ink_subtle')])
      Text(item.label)
        .fontSize(9)
        .fontColor(this.tab === item.index ? $r('app.color.brand') : $r('app.color.ink_subtle'))
    }
    .width(60)
    .padding({ top: 6, bottom: 6 })
    .onClick(() => {
      this.tab = item.index;
    })
  }

  @Builder
  SideRail() {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 40, height: 40 })
          .fill($r('app.color.brand'))
        Text('W')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand_text'))
      }
      .width(40)
      .height(40)
      .margin({ top: 14, bottom: 14 })

      ForEach(this.navItems, (item: NavItem) => {
        Column({ space: 2 }) {
          SymbolGlyph(item.icon)
            .fontSize(this.tab === item.index ? 23 : 21)
            .fontColor([this.tab === item.index ? $r('app.color.brand') : $r('app.color.ink_subtle')])
          Text(item.label)
            .fontSize(9)
            .fontColor(this.tab === item.index ? $r('app.color.brand') : $r('app.color.ink_subtle'))
        }
        .width(64)
        .padding({ top: 8, bottom: 8 })
        .backgroundColor(this.tab === item.index ? $r('app.color.brand_soft') : Color.Transparent)
        .borderRadius(12)
        .onClick(() => {
          this.tab = item.index;
        })
      }, (item: NavItem) => String(item.index))
      Blank()
    }
    .width(78)
    .height('100%')
    .padding({ left: 6, right: 6 })
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  TabBar() {
    Row() {
      ForEach(this.navItems, (item: NavItem) => {
        this.NavButton(item)
      }, (item: NavItem) => String(item.index))
    }
    .width('100%')
    .height(60)
    .justifyContent(FlexAlign.SpaceAround)
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  WebContent() {
    Stack({ alignContent: Alignment.Center }) {
      Web({ src: 'https://web.whatsapp.com', controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .userAgent(WEB_DESKTOP_UA)
        .zoomAccess(false)
        .javaScriptOnDocumentStart([
          {
            script: this.phoneFit ? FIT_VIEWPORT_SCRIPT : NATURAL_VIEWPORT_SCRIPT,
            scriptRules: ['https://web.whatsapp.com', 'https://web.whatsapp.com/*']
          }
        ])
        .onPageBegin((event) => {
          this.webLoading = true;
          this.webError = '';
          hilog.info(DOMAIN, TAG, 'web begin: %{public}s', event.url);
        })
        .onPageEnd((event) => {
          this.webLoading = false;
          this.webReady = true;
          this.applyPhoneLayout();
          hilog.info(DOMAIN, TAG, 'web ready: %{public}s', event.url);
        })
        .onErrorReceive((event) => {
          this.webLoading = false;
          this.webReady = false;
          this.webError = 'WhatsApp Web failed to load';
          hilog.warn(DOMAIN, TAG, 'web error: %{public}s', JSON.stringify(event.error));
        })

      if (this.webLoading) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color($r('app.color.brand'))
          Text('Loading WhatsApp Web…')
            .fontSize(11)
            .fontColor($r('app.color.ink_subtle'))
        }
        .padding(14)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(14)
      }

      if (this.webError.length > 0) {
        Column({ space: 10 }) {
          Text(this.webError)
            .fontSize(13)
            .fontColor($r('app.color.ink'))
            .textAlign(TextAlign.Center)
          Button('Retry')
            .height(36)
            .fontSize(12)
            .fontColor($r('app.color.brand_text'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius(18)
            .onClick(() => {
              this.reload();
            })
        }
        .padding(18)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(16)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  NativeChats() {
    if (this.nativeThreadOpen) {
      ConversationView({
        chat: this.nativeThread,
        messages: this.nativeMessages,
        live: false,
        loadingOlder: false,
        onBack: () => {
          this.nativeThreadOpen = false;
        },
        onSend: (text: string) => {
          const m = new MessageItem();
          m.id = 'local-' + Date.now();
          m.chatId = this.nativeThread.id;
          m.text = text;
          m.time = 'now';
          m.out = true;
          m.status = 'sent';
          this.nativeMessages = this.nativeMessages.concat([m]);
        },
        onCall: () => {
        },
        onLoadOlder: () => {
        },
        onAttachTap: () => {
        },
        onOpenMedia: () => {
        }
      })
        .width('100%')
        .height('100%')
    } else {
      ChatsPane({
        chats: this.nativeChats,
        live: false,
        onOpen: (chat: ChatItem) => {
          this.nativeThread = chat;
          this.nativeMessages = WhatsAppStore.sampleMessages(chat.id, chat.name);
          this.nativeThreadOpen = true;
        }
      })
        .width('100%')
        .height('100%')
    }
  }

  @Builder
  NativeTab() {
    Column() {
      if (this.tab === 1) {
        UpdatesPane()
          .layoutWeight(1)
      } else if (this.tab === 2) {
        CallsPane()
          .layoutWeight(1)
      } else if (this.tab === 3) {
        CommunitiesPane()
          .layoutWeight(1)
      } else if (this.tab === 4) {
        SettingsPane({
          linked: false,
          phone: '',
          oauthConnected: false,
          accountName: 'WhatsApp Web',
          appearanceMode: this.appearanceMode,
          live: true,
          onLink: () => {
            this.tab = 0;
          },
          onWebLink: () => {
            this.tab = 0;
          },
          onLogout: () => {
          },
          onAppearance: (mode: string) => {
            this.appearanceMode = mode;
          },
          onSignedOut: () => {
          }
        })
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  build() {
    Row() {
      if (this.isWide()) {
        this.SideRail()
      }
      Column() {
        this.Header()
        Stack({ alignContent: Alignment.Center }) {
          // Keep the WebView mounted across tab switches.
          this.WebContent()
          if (this.tab === 0 && this.chatMode === 'native') {
            this.NativeChats()
          } else if (this.tab !== 0) {
            this.NativeTab()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.bg_page'))
        if (!this.isWide()) {
          this.TabBar()
        }
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
