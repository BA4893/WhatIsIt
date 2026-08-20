/**
 * MediaDownloader — the native-render half of the media bridge.
 *
 * The backend serves cached WhatsApp media at /media/{id}/{kind}. This
 * service downloads those bytes into the app's private sandbox cache and
 * returns a local file:// path so native ArkUI Image/Video components can
 * render them — no webview involved.
 */
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { cdpBridge } from './CdpBridge';
import { waEngine } from './WaEngine';

const TAG = 'MediaDownloader';
const DOMAIN = 0x0000;
const MAX_BYTES = 50 * 1024 * 1024; // 50 MB cap

export class MediaDownloader {
  private cacheDir: string = '';

  /** Must be called once with a UI context before download(). */
  init(context: common.UIAbilityContext): void {
    if (this.cacheDir.length === 0) {
      this.cacheDir = context.cacheDir;
    }
  }

  /**
   * Download a media URL into the sandbox cache and return a local
   * file:// path suitable for native Image/Video. Returns '' on failure.
   * `cookies` is ignored (the backend serves media with the same auth as
   * the API; no page-session cookies needed).
   */
  async download(url: string, ext: string, _cookies: string = ''): Promise<string> {
    if (url.length === 0) {
      return '';
    }
    if (this.cacheDir.length === 0) {
      hilog.warn(DOMAIN, TAG, 'download: cacheDir not initialized');
      return '';
    }
    // Embedded engine: media was cached locally when the message arrived;
    // resolve /media/{id}/{kind} straight from the engine's sandbox store.
    if (waEngine.isReady() && !url.startsWith('http')) {
      const parts = url.split('/');
      if (parts.length >= 3 && parts[1] === 'media') {
        const engPath = waEngine.mediaPath(parts[2], parts[3]);
        if (engPath.length > 0 && fileIo.accessSync(engPath)) {
          return 'file://' + engPath;
        }
      }
    }
    // Backend media URLs are relative (/media/{id}/{kind}); resolve them
    // against the backend base URL.
    const fullUrl = url.startsWith('http') ? url : cdpBridge.getBaseUrl() + url;
    const name = util.generateRandomUUID() + (ext.length > 0 ? '.' + ext : '');
    const dest = this.cacheDir + '/' + name;
    const req = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: cdpBridge.getAuthHeaders(),
      };
      const resp = await req.request(fullUrl, options);
      const buf = resp.result as ArrayBuffer;
      if (buf.byteLength === 0 || buf.byteLength > MAX_BYTES) {
        hilog.warn(DOMAIN, TAG, 'download: bad size %{public}d', buf.byteLength);
        return '';
      }
      const file = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        fileIo.writeSync(file.fd, buf);
      } finally {
        fileIo.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'downloaded %{public}d bytes to cache', buf.byteLength);
      return 'file://' + dest;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'download failed: %{public}s', JSON.stringify(err));
      return '';
    } finally {
      req.destroy();
    }
  }
}

/** Singleton export. */
export const mediaDownloader = new MediaDownloader();
