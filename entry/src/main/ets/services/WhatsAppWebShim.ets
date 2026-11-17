/**
 * WA_NATIVE_SHIM — injected at document start into the linked WhatsApp Web
 * page. It exposes a small JSON API on window.__waNative for the ArkUI shell.
 *
 * This is deliberately DOM-based and isolated: if WhatsApp Web changes its
 * selectors, only this file needs updating.
 */
export const WA_NATIVE_SHIM: string = `
(function () {
  if (window.__waNative) return;

  function q(sel, root) {
    try { return (root || document).querySelector(sel); } catch (e) { return null; }
  }
  function qa(sel, root) {
    try { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
    catch (e) { return []; }
  }
  function txt(el) {
    if (!el) return '';
    return String(el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
  }
  function attr(el, name) {
    return el && el.getAttribute ? (el.getAttribute(name) || '') : '';
  }
  function chatRows() {
    var pane = q('#pane-side');
    if (!pane) return [];
    return qa('[role="listitem"]', pane);
  }
  function rowId(row, index) {
    return attr(row, 'data-id') || ('row-' + index);
  }

  function phoneInput() {
    return q('input[type="tel"]') ||
      q('[data-testid="phone-number-input"]') ||
      q('input[placeholder*="phone" i]') ||
      q('input[aria-label*="phone" i]') ||
      q('input[data-testid*="phone" i]');
  }

  function qrNode() {
    var boxes = [q('[data-testid="qrcode"]'), q('[data-testid="link-device-qr"]'), q('[data-ref]')];
    for (var i = 0; i < boxes.length; i++) {
      if (!boxes[i]) continue;
      var c = q('canvas', boxes[i]) || q('img', boxes[i]);
      if (c) return c;
    }
    var canvases = qa('canvas');
    var best = null;
    for (var j = 0; j < canvases.length; j++) {
      var cv = canvases[j];
      if ((cv.width || 0) >= 120 && (cv.height || 0) >= 120) {
        if (!best || cv.width * cv.height > best.width * best.height) best = cv;
      }
    }
    if (best) return best;
    var imgs = qa('img');
    for (var k = 0; k < imgs.length; k++) {
      if ((imgs[k].width || 0) >= 120 && (imgs[k].src || '').length > 0) return imgs[k];
    }
    return null;
  }

  function findCode() {
    var direct = q('[data-testid="pairing-code"]') || q('[data-testid="link-code"]') ||
      q('[data-testid="link-device-code"]') || q('[data-testid="code"]') ||
      q('[aria-label*="code" i]');
    if (direct) {
      var t = txt(direct);
      var m0 = t.match(/([A-Z0-9]{4})[^A-Z0-9]?([A-Z0-9]{4})/);
      if (m0) return m0[1] + m0[2];
    }
    var body = document.body ? (document.body.innerText || '') : '';
    var lower = body.toLowerCase();
    var marks = ['enter this code', 'pairing code', 'link with phone number', 'code:'];
    for (var m = 0; m < marks.length; m++) {
      var idx = lower.indexOf(marks[m]);
      if (idx < 0) continue;
      var snippet = body.substring(idx, idx + 240);
      var found = snippet.match(/\b([A-Z0-9]{4})[^A-Z0-9]?([A-Z0-9]{4})\b/g) || [];
      for (var i = 0; i < found.length; i++) {
        var compact = found[i].replace(/[^A-Z0-9]/g, '');
        if (compact.length !== 8) continue;
        if (!/[0-9]/.test(compact)) continue;
        if (compact === 'LINKCODE' || compact === 'WHATSAPP') continue;
        return compact;
      }
    }
    return '';
  }

  function linkState() {
    if (linked()) return 'linked';
    if (findCode()) return 'code';
    if (qrNode()) return 'qr';
    if (phoneInput()) return 'phone-entry';
    return 'loading';
  }

  function qrImage() {
    var node = qrNode();
    if (!node) return '';
    if (node.tagName && node.tagName.toLowerCase() === 'canvas') {
      try { return node.toDataURL('image/png'); } catch (e) { return ''; }
    }
    return dataUrl(node, 420, '');
  }

  function choosePhone() {
    var direct = q('[data-testid="link-with-phone-number"]') ||
      q('[data-testid="link-phone-number"]');
    if (direct) { direct.click(); return true; }
    var nodes = qa('button, a, div[role="button"]');
    for (var i = 0; i < nodes.length; i++) {
      var t = txt(nodes[i]);
      if (t.indexOf('phone number') >= 0 && (t.indexOf('Link') >= 0 || t.indexOf('Use') >= 0)) {
        nodes[i].click();
        return true;
      }
    }
    return false;
  }

  function submitPhone(country, phone) {
    var input = phoneInput();
    if (!input) return false;
    var full = String(country || '').replace(/[^0-9]/g, '') + String(phone || '').replace(/[^0-9]/g, '');
    if (full.length < 7) return false;
    input.focus();
    try {
      var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(input, full);
    } catch (e) {
      input.value = full;
    }
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    var next = q('[data-testid="link-phone-next"]') || q('[data-testid="phone-next"]');
    if (next) { next.click(); return true; }
    var buttons = qa('button, div[role="button"]');
    for (var i = 0; i < buttons.length; i++) {
      var t = txt(buttons[i]);
      if (t === 'Next' || t === 'Continue' || t.indexOf('Next') === 0 || t.indexOf('Continue') === 0) {
        buttons[i].click();
        return true;
      }
    }
    return true;
  }

  function refreshQr() {
    var direct = q('[data-testid="refresh-qr"]') || q('[data-testid="link-device-refresh"]');
    if (direct) { direct.click(); return true; }
    var nodes = qa('button, div[role="button"]');
    for (var i = 0; i < nodes.length; i++) {
      if (txt(nodes[i]).indexOf('Refresh') >= 0) {
        nodes[i].click();
        return true;
      }
    }
    return false;
  }

  function linkDebug() {
    var inputs = [];
    var allInputs = qa('input');
    for (var i = 0; i < allInputs.length && i < 8; i++) {
      inputs.push((allInputs[i].type || '') + ':' + (allInputs[i].placeholder || '') + ':' + (allInputs[i].getAttribute('data-testid') || ''));
    }
    var buttons = [];
    var allButtons = qa('button, div[role="button"], a');
    for (var j = 0; j < allButtons.length && buttons.length < 15; j++) {
      var t = txt(allButtons[j]);
      if (t.length > 0 && t.length < 80) buttons.push(t);
    }
    var node = qrNode();
    return JSON.stringify({
      href: location.href,
      title: document.title,
      canvases: qa('canvas').length,
      qr: node ? (node.tagName + ' ' + (node.width || 0) + 'x' + (node.height || 0)) : '',
      code: findCode(),
      inputs: inputs,
      buttons: buttons,
      body: (document.body ? document.body.innerText : '').substring(0, 500)
    });
  }

  function dataUrl(img, maxSize, cacheKey) {
    if (!img) return '';
    var cache = window.__waMediaCache || (window.__waMediaCache = {});
    if (cacheKey && cache[cacheKey]) return cache[cacheKey];
    var src = img.currentSrc || img.src || '';
    if (!src) return '';
    if (src.indexOf('data:') === 0) {
      if (cacheKey) cache[cacheKey] = src;
      return src;
    }
    try {
      var w = img.naturalWidth || maxSize;
      var h = img.naturalHeight || maxSize;
      var scale = Math.min(1, maxSize / Math.max(w, h));
      var c = document.createElement('canvas');
      c.width = Math.max(1, Math.round(w * scale));
      c.height = Math.max(1, Math.round(h * scale));
      var ctx = c.getContext('2d');
      ctx.drawImage(img, 0, 0, c.width, c.height);
      var out = c.toDataURL('image/jpeg', 0.6);
      if (cacheKey) cache[cacheKey] = out;
      return out;
    } catch (e) {
      return src;
    }
  }

  window.__waMediaEls = window.__waMediaEls || {};

  function mediaInfo(row, id) {
    var doc = q('[data-testid="document-thumb"]', row) || q('[data-testid="document"]', row);
    if (doc) {
      var title = q('[data-testid="document-title"]', row) || q('span[title]', row);
      return { type: 'document', url: '', name: txt(title) || 'Document' };
    }
    var video = q('[data-testid="video-thumb"]', row) || q('video', row);
    if (video) {
      var vimg = q('img', video) || q('img', row);
      return { type: 'video', url: dataUrl(vimg, 160, id + ':v'), name: '' };
    }
    var image = q('[data-testid="image-thumb"]', row) || q('[data-testid="media-thumb"]', row);
    if (image) {
      var img = q('img', image) || q('img', row);
      return { type: 'image', url: dataUrl(img, 240, id + ':i'), name: '', el: img };
    }
    if (q('[data-testid="audio-play"]', row) || q('[data-testid="audio-download"]', row)) {
      return { type: 'audio', url: '', name: 'Voice message' };
    }
    return null;
  }

  function store() {
    if (window.__waStore) return window.__waStore;
    try {
      if (typeof window.require !== 'function') return null;
      var c = window.require('WAWebCollections');
      if (!c || !c.Chat || !c.Msg) return null;
      window.__waStore = { Chat: c.Chat, Msg: c.Msg, Contact: c.Contact };
      return window.__waStore;
    } catch (e) {
      return null;
    }
  }

  function fmtTime(t) {
    if (!t) return '';
    try {
      return new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } catch (e) {
      return '';
    }
  }

  function storeReady() {
    return store() !== null;
  }

  function storeChats() {
    var s = store();
    if (!s) return '[]';
    var models = s.Chat.getModelsArray();
    var out = [];
    for (var i = 0; i < models.length; i++) {
      var chat = models[i];
      if (!chat || !chat.id) continue;
      var id = chat.id._serialized || String(chat.id);
      var name = chat.formattedTitle || chat.name ||
        (chat.contact && (chat.contact.name || chat.contact.pushname)) ||
        (chat.id.user || '');
      if (!name) continue;
      var last = chat.lastMessage;
      var preview = last ? (last.body || last.caption || '') : '';
      var unread = typeof chat.unreadCount === 'number' ? chat.unreadCount : 0;
      var isGroup = chat.isGroup === true || (chat.id.server === 'g.us');
      var isChannel = chat.id.server === 'newsletter';
      out.push({
        id: id,
        name: name,
        preview: preview,
        time: fmtTime(chat.t),
        unread: unread,
        pinned: !!chat.pin,
        isGroup: isGroup,
        isChannel: isChannel,
        avatar: ''
      });
    }
    return JSON.stringify(out);
  }

  function storeMessages(chatId, limit) {
    var s = store();
    if (!s) return '[]';
    var models = s.Chat.getModelsArray();
    var chat = null;
    for (var i = 0; i < models.length; i++) {
      var id = models[i].id && models[i].id._serialized;
      if (id === chatId) { chat = models[i]; break; }
    }
    if (!chat && chatId) return '[]';
    if (!chat) {
      for (var a = 0; a < models.length; a++) {
        if (models[a].active) { chat = models[a]; break; }
      }
    }
    if (!chat || !chat.msgs) return '[]';
    var rows = chat.msgs.getModelsArray();
    var max = limit && limit > 0 ? limit : 500;
    var start = Math.max(0, rows.length - max);
    var out = [];
    for (var j = start; j < rows.length; j++) {
      var m = rows[j];
      if (!m) continue;
      var text = m.body || m.caption || '';
      if (!text) continue;
      var ack = typeof m.ack === 'number' ? m.ack : -1;
      var status = ack >= 3 ? 'read' : (ack === 2 ? 'delivered' : (ack === 1 ? 'sent' : ''));
      var sender = '';
      if (!m.fromMe && m.sender) sender = m.sender.pushname || m.sender.name || '';
      out.push({
        id: (m.id && (m.id._serialized || String(m.id))) || ('store-' + j),
        text: text,
        time: fmtTime(m.t),
        dir: m.fromMe ? 'out' : 'in',
        status: status,
        sender: sender
      });
    }
    return JSON.stringify(out);
  }

  function chats() {
    var rows = chatRows();
    var out = [];
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var title = q('[data-testid="cell-frame-title"] span[title]', row) ||
        q('[data-testid="cell-frame-title"]', row) ||
        q('span[title]', row);
      var name = attr(title, 'title') || txt(title);
      if (!name) continue;
      var id = rowId(row, i);
      var timeEl = q('[data-testid="cell-frame-primary-detail"]', row) || q('time', row);
      var timeText = txt(timeEl);
      var secondary = q('[data-testid="cell-frame-secondary"]', row) ||
        q('[data-testid="last-msg-status"]', row);
      var preview = txt(secondary);
      if (!preview) {
        var spans = qa('span', row);
        for (var s = 0; s < spans.length; s++) {
          var t = txt(spans[s]);
          if (!t || t === name || t === timeText) continue;
          if (/^[0-9]{1,2}:[0-9]{2}$/.test(t)) continue;
          if (t.length > preview.length) preview = t;
        }
      }
      var unreadEl = q('[data-testid="icon-unread-count"]', row);
      var unread = 0;
      if (unreadEl) {
        var n = parseInt(txt(unreadEl).replace(/[^0-9]/g, ''), 10);
        unread = isNaN(n) ? 0 : n;
      }
      var img = q('img', row);
      var avatar = dataUrl(img, 64, id + ':a');
      out.push({
        id: id,
        name: name,
        preview: preview,
        time: timeText,
        unread: unread,
        pinned: !!(q('[data-testid="cell-frame-pin"]', row) || q('[data-icon="pinned"]', row)),
        isGroup: id.indexOf('@g.us') >= 0,
        isChannel: id.indexOf('@newsletter') >= 0,
        avatar: avatar
      });
    }
    return JSON.stringify(out);
  }

  function messages(limit) {
    var main = q('#main');
    if (!main) return '[]';
    var rows = qa('[data-testid="msg-container"]', main);
    var max = limit && limit > 0 ? limit : 500;
    var start = Math.max(0, rows.length - max);
    var out = [];
    for (var i = start; i < rows.length; i++) {
      var row = rows[i];
      var textEl = q('.selectable-text span', row) ||
        q('[data-testid="msg-text"]', row) ||
        q('.copyable-text span', row);
      var text = txt(textEl);
      var id = attr(row, 'data-id') || ('msg-' + i);
      var media = mediaInfo(row, id);
      if (!text && !media) continue;
      if (media && media.el && media.type === 'image') {
        window.__waMediaEls[id] = media.el;
      }
      var outMsg = row.className.indexOf('message-out') >= 0 || id.indexOf('true_') === 0;
      var meta = q('[data-testid="msg-meta"]', row) || q('time', row);
      var timeText = txt(meta);
      var icon = meta ? q('[data-icon]', meta) : null;
      var iconName = attr(icon, 'data-icon');
      var status = '';
      if (iconName === 'msg-dblcheck-ack') status = 'read';
      else if (iconName === 'msg-dblcheck') status = 'delivered';
      else if (iconName === 'msg-check') status = 'sent';
      var sender = '';
      var pre = attr(row, 'data-pre-plain-text');
      if (!pre) pre = attr(q('.copyable-text', row), 'data-pre-plain-text');
      if (pre) {
        var m = pre.match(/\]\s*([^:]+):/);
        if (m && m[1]) sender = m[1].trim();
      }
      out.push({
        id: id,
        text: text,
        time: timeText,
        dir: outMsg ? 'out' : 'in',
        status: status,
        sender: sender,
        mediaType: media ? media.type : '',
        mediaUrl: media ? media.url : '',
        mediaName: media ? media.name : ''
      });
    }
    return JSON.stringify(out);
  }

  function fullImage(id) {
    var img = window.__waMediaEls[id];
    if (!img) return '';
    return dataUrl(img, 1600, id + ':full');
  }

  function search(value) {
    var box = q('#side [contenteditable="true"]') ||
      q('[data-testid="chat-list-search"]') ||
      q('[data-testid="chat-list-search-input"]') ||
      q('[aria-label*="Search"]') ||
      q('div[contenteditable="true"]');
    if (!box) return false;
    box.focus();
    try {
      box.textContent = '';
      document.execCommand('insertText', false, value);
    } catch (e) {
      box.textContent = value;
    }
    try {
      box.dispatchEvent(new InputEvent('input', {
        bubbles: true, cancelable: true, inputType: 'insertText', data: value
      }));
    } catch (e2) {
      box.dispatchEvent(new Event('input', { bubbles: true }));
    }
    return true;
  }

  function openFirstResult(value) {
    var rows = chatRows();
    var needle = value ? String(value).toLowerCase() : '';
    var fallback = -1;
    for (var i = 0; i < rows.length; i++) {
      var title = q('[data-testid="cell-frame-title"] span[title]', rows[i]) ||
        q('span[title]', rows[i]);
      var name = txt(title);
      if (!name) continue;
      if (fallback < 0) fallback = i;
      if (!needle || name.toLowerCase().indexOf(needle) >= 0) {
        rows[i].click();
        return true;
      }
    }
    if (fallback >= 0) {
      rows[fallback].click();
      return true;
    }
    return false;
  }

  function scrollOlder() {
    var node = q('#main [data-testid="conversation-panel-messages"]') ||
      q('#main [data-testid="conversation-panel-body"]') ||
      q('#main');
    var scroller = node;
    while (scroller && scroller.scrollHeight <= scroller.clientHeight + 4) {
      scroller = scroller.parentElement;
    }
    if (!scroller) return false;
    scroller.scrollTop = Math.max(0, scroller.scrollTop - 900);
    try {
      scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
    } catch (e) { }
    return true;
  }

  function openChat(id) {
    var rows = chatRows();
    for (var i = 0; i < rows.length; i++) {
      if (rowId(rows[i], i) === id) {
        rows[i].click();
        return true;
      }
    }
    return false;
  }

  function send(text) {
    var box = q('#main footer [contenteditable="true"]') ||
      q('footer [contenteditable="true"]');
    if (!box) return false;
    box.focus();
    try {
      box.textContent = '';
      document.execCommand('insertText', false, text);
    } catch (e) {
      box.textContent = text;
    }
    try {
      box.dispatchEvent(new InputEvent('input', {
        bubbles: true, cancelable: true, inputType: 'insertText', data: text
      }));
    } catch (e2) {
      box.dispatchEvent(new Event('input', { bubbles: true }));
    }
    var sendBtn = q('[data-testid="send"]') || q('span[data-icon="send"]') ||
      q('button[aria-label="Send"]');
    if (sendBtn) {
      sendBtn.click();
      return true;
    }
    try {
      box.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
      }));
      return true;
    } catch (e3) {
      return false;
    }
  }

  function linked() {
    return chatRows().length > 0;
  }

  window.__waNative = {
    linkState: linkState,
    qrImage: qrImage,
    linkDebug: linkDebug,
    choosePhone: choosePhone,
    submitPhone: submitPhone,
    pairCode: findCode,
    refreshQr: refreshQr,
    storeReady: storeReady,
    storeChats: storeChats,
    storeMessages: storeMessages,
    chats: chats,
    messages: messages,
    openChat: openChat,
    send: send,
    fullImage: fullImage,
    search: search,
    openFirstResult: openFirstResult,
    scrollOlder: scrollOlder,
    linked: linked
  };
})();
`;
