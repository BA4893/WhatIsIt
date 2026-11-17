#!/usr/bin/env node
/**
 * WhatIsIt passkey bridge (no server).
 *
 * Runs on a PC where Chrome can use the WhatsApp passkey. It receives a
 * WebAuthn PublicKeyCredentialRequestOptions object from the phone over the
 * LAN, asks Chrome to sign it on https://web.whatsapp.com, and returns the
 * assertion. The passkey never leaves Chrome.
 *
 * Usage:
 *   node agent.js --token <pairing-token> [--port 18771] [--chrome-port 9222]
 *                 [--chrome <path>] [--profile <user-data-dir>] [--no-launch]
 *
 * Requirements: Node 22+ (global WebSocket/fetch), Chrome.
 */
'use strict';

const http = require('http');
const os = require('os');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');

const RP_ID = 'web.whatsapp.com';
const MAX_BODY = 1024 * 1024;

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      continue;
    }
    const key = arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[key] = argv[++i];
    } else {
      out[key] = true;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const HOST = typeof args.host === 'string' ? args.host : '0.0.0.0';
const PORT = typeof args.port === 'string' ? parseInt(args.port, 10) : 18771;
const TOKEN = typeof args.token === 'string' && args.token.length > 0
  ? args.token : crypto.randomBytes(16).toString('hex');
const CHROME_PORT = typeof args.chromePort === 'string' ? parseInt(args.chromePort, 10) : 9222;
const CHROME_PATH = typeof args.chrome === 'string' ? args.chrome : findChrome();
const PROFILE = typeof args.profile === 'string' ? args.profile : '';
const NO_LAUNCH = args.noLaunch === true;

let chromeProc = null;
let cdp = null;
let assertionQueue = Promise.resolve();

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function findChrome() {
  const candidates = [];
  if (process.platform === 'win32') {
    candidates.push(
      path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Google\\Chrome\\Application\\chrome.exe'),
      path.join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Google\\Chrome\\Application\\chrome.exe'),
      path.join(process.env.LOCALAPPDATA || '', 'Google\\Chrome\\Application\\chrome.exe')
    );
  } else if (process.platform === 'darwin') {
    candidates.push('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
  } else {
    candidates.push('/usr/bin/google-chrome', '/usr/bin/google-chrome-stable',
      '/usr/bin/chromium', '/usr/bin/chromium-browser', '/snap/bin/chromium');
  }
  for (const candidate of candidates) {
    try {
      if (candidate && fs.existsSync(candidate)) {
        return candidate;
      }
    } catch (e) {
      // ignore
    }
  }
  return process.platform === 'win32' ? 'chrome.exe' : 'google-chrome';
}

function launchChrome() {
  if (chromeProc !== null) {
    return;
  }
  const chromeArgs = [
    `--remote-debugging-port=${CHROME_PORT}`,
    '--remote-allow-origins=*',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-timer-throttling',
    '--disable-backgrounding-occluded-windows',
    '--disable-renderer-backgrounding',
    '--new-window',
    'https://web.whatsapp.com'
  ];
  if (PROFILE.length > 0) {
    chromeArgs.unshift(`--user-data-dir=${PROFILE}`);
  }
  chromeProc = spawn(CHROME_PATH, chromeArgs, { stdio: 'ignore' });
  chromeProc.on('exit', () => {
    chromeProc = null;
  });
  console.log(`[bridge] launched Chrome: ${CHROME_PATH}`);
}

async function waitForCDP(timeoutMs) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const resp = await fetch(`http://127.0.0.1:${CHROME_PORT}/json/version`);
      if (resp.ok) {
        const body = await resp.json();
        if (body && body.webSocketDebuggerUrl) {
          return body.webSocketDebuggerUrl;
        }
      }
    } catch (e) {
      // Chrome not up yet
    }
    await sleep(500);
  }
  throw new Error(`Chrome DevTools endpoint not available on port ${CHROME_PORT}. ` +
    'Close Chrome and run the bridge again, or pass --profile <dir>.');
}

class CDP {
  constructor(url) {
    this.url = url;
    this.nextId = 0;
    this.pending = new Map();
    this.ws = null;
  }

  open() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;
      const timer = setTimeout(() => reject(new Error('CDP connection timed out')), 10000);
      ws.onopen = () => {
        clearTimeout(timer);
        resolve();
      };
      ws.onerror = (err) => {
        clearTimeout(timer);
        reject(new Error('CDP connection failed'));
      };
      ws.onmessage = (event) => {
        let msg;
        try {
          msg = JSON.parse(event.data);
        } catch (e) {
          return;
        }
        if (msg.id === undefined) {
          return;
        }
        const waiter = this.pending.get(msg.id);
        if (waiter === undefined) {
          return;
        }
        this.pending.delete(msg.id);
        if (msg.error) {
          waiter.reject(new Error(msg.error.message || 'CDP error'));
        } else {
          waiter.resolve(msg.result);
        }
      };
      ws.onclose = () => {
        for (const waiter of this.pending.values()) {
          waiter.reject(new Error('CDP connection closed'));
        }
        this.pending.clear();
      };
    });
  }

  send(method, params, sessionId) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      const payload = { id, method, params: params || {} };
      if (sessionId) {
        payload.sessionId = sessionId;
      }
      try {
        this.ws.send(JSON.stringify(payload));
      } catch (e) {
        this.pending.delete(id);
        reject(e);
      }
    });
  }

  close() {
    if (this.ws) {
      try {
        this.ws.close();
      } catch (e) {
        // ignore
      }
      this.ws = null;
    }
  }
}

async function ensureCDP() {
  if (cdp !== null) {
    return cdp;
  }
  let wsUrl;
  try {
    wsUrl = await waitForCDP(1200);
  } catch (e) {
    if (NO_LAUNCH) {
      throw e;
    }
    launchChrome();
    wsUrl = await waitForCDP(15000);
  }
  const client = new CDP(wsUrl);
  await client.open();
  cdp = client;
  return cdp;
}

async function openWhatsAppTarget(client) {
  const targets = await client.send('Target.getTargets');
  const existing = (targets.targetInfos || []).find((t) =>
    t.type === 'page' && typeof t.url === 'string' && t.url.startsWith('https://web.whatsapp.com'));
  let targetId;
  if (existing) {
    targetId = existing.targetId;
  } else {
    const created = await client.send('Target.createTarget', { url: 'https://web.whatsapp.com' });
    targetId = created.targetId;
  }
  await client.send('Target.activateTarget', { targetId });
  const attached = await client.send('Target.attachToTarget', { targetId, flatten: true });
  const sessionId = attached.sessionId;
  await client.send('Page.enable', {}, sessionId);
  try {
    await client.send('Page.bringToFront', {}, sessionId);
  } catch (e) {
    // best effort
  }
  // Give the page a moment to boot; Runtime.evaluate is retried below.
  await sleep(1800);
  return { targetId, sessionId };
}

function pageExpression(options) {
  const optionsJson = JSON.stringify(options);
  return `(async () => {
    const o = ${optionsJson};
    const dec = (s) => {
      s = String(s).replace(/-/g, '+').replace(/_/g, '/');
      s += '='.repeat((4 - (s.length % 4)) % 4);
      const bin = atob(s);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out.buffer;
    };
    const enc = (buf) => {
      const bytes = new Uint8Array(buf);
      let bin = '';
      for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      return btoa(bin).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
    };
    const allow = (o.allowCredentials || []).map((c) => ({
      type: c.type,
      id: dec(c.id),
      transports: c.transports
    }));
    const publicKey = {
      challenge: dec(o.challenge),
      rpId: o.rpId,
      timeout: o.timeout,
      userVerification: o.userVerification,
      allowCredentials: allow
    };
    const cred = await navigator.credentials.get({ publicKey });
    return JSON.stringify({
      id: cred.id,
      rawId: enc(cred.rawId),
      type: cred.type,
      authenticatorAttachment: cred.authenticatorAttachment,
      response: {
        clientDataJSON: enc(cred.response.clientDataJSON),
        authenticatorData: enc(cred.response.authenticatorData),
        signature: enc(cred.response.signature),
        userHandle: cred.response.userHandle ? enc(cred.response.userHandle) : null
      }
    });
  })()`;
}

async function assertWithChrome(options) {
  if (!options || typeof options !== 'object') {
    throw new Error('Missing passkey options.');
  }
  if (options.rpId !== RP_ID) {
    throw new Error('Refusing a passkey request for a different relying party.');
  }
  if (typeof options.challenge !== 'string' || options.challenge.length === 0) {
    throw new Error('Passkey options have no challenge.');
  }
  const client = await ensureCDP();
  const target = await openWhatsAppTarget(client);
  const expression = pageExpression(options);
  let lastError = null;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const result = await client.send('Runtime.evaluate', {
        expression,
        awaitPromise: true,
        userGesture: true,
        returnByValue: true
      }, target.sessionId);
      if (result.exceptionDetails) {
        const detail = result.exceptionDetails.exception &&
          (result.exceptionDetails.exception.description || result.exceptionDetails.exception.value);
        throw new Error(detail || 'The passkey prompt failed.');
      }
      const value = result.result ? result.result.value : undefined;
      if (typeof value !== 'string') {
        throw new Error('Chrome returned no assertion.');
      }
      return JSON.parse(value);
    } catch (e) {
      lastError = e;
      await sleep(1000);
    }
  }
  throw lastError || new Error('Chrome did not return an assertion.');
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error('Request too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store'
  });
  res.end(payload);
}

function authorized(req) {
  const header = req.headers['authorization'] || '';
  return header === `Bearer ${TOKEN}`;
}

function lanAddress() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const entry of interfaces[name] || []) {
      if (entry.family === 'IPv4' && !entry.internal) {
        return entry.address;
      }
    }
  }
  return '127.0.0.1';
}

async function main() {
  if (!NO_LAUNCH && CHROME_PATH) {
    try {
      await waitForCDP(800);
      console.log('[bridge] using an existing Chrome debugging endpoint');
    } catch (e) {
      launchChrome();
      try {
        await waitForCDP(15000);
      } catch (err) {
        console.error('[bridge] Chrome did not expose DevTools. Close Chrome and retry, or use --profile.');
        console.error(err.message);
      }
    }
  }

  const server = http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      json(res, 200, { ok: true, rpId: RP_ID, chromePort: CHROME_PORT });
      return;
    }
    if (req.method !== 'POST' || req.url !== '/assert') {
      json(res, 404, { ok: false, error: 'not found' });
      return;
    }
    if (!authorized(req)) {
      json(res, 401, { ok: false, error: 'unauthorized' });
      return;
    }
    try {
      const raw = await readBody(req);
      const body = JSON.parse(raw);
      const options = body && body.options;
      // Serialize assertions: Chrome shows one passkey prompt at a time.
      const run = assertionQueue.then(() => assertWithChrome(options));
      assertionQueue = run.catch(() => {});
      const assertion = await run;
      json(res, 200, { ok: true, assertion });
    } catch (e) {
      json(res, 500, { ok: false, error: e && e.message ? e.message : 'assertion failed' });
    }
  });

  server.listen(PORT, HOST, () => {
    console.log('');
    console.log('WhatIsIt passkey bridge');
    console.log(`  listening : http://${lanAddress()}:${PORT}`);
    console.log(`  health    : http://${lanAddress()}:${PORT}/health`);
    console.log(`  token     : ${TOKEN}`);
    console.log(`  Chrome    : ${CHROME_PATH}`);
    console.log(`  RP        : ${RP_ID}`);
    console.log('');
    console.log('In WhatIsIt: Settings → Passkey bridge → enter the host, port and token above.');
    console.log('Then open WhatsApp Web in the app and link with phone number.');
    console.log('Complete the passkey prompt that appears in Chrome on this PC.');
    console.log('');
  });

  const shutdown = () => {
    try {
      server.close();
    } catch (e) {
      // ignore
    }
    if (cdp) {
      cdp.close();
    }
    if (chromeProc) {
      try {
        chromeProc.kill();
      } catch (e) {
        // ignore
      }
    }
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((e) => {
  console.error('[bridge] fatal:', e && e.message ? e.message : e);
  process.exit(1);
});
