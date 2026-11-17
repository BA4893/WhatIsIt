import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { authStore } from '../services/AuthStore';
import { oauthFlowStore } from '../services/OAuthFlowStore';
import { queryParam, WhatsAppOAuth } from '../services/WhatsAppOAuth';

/** Completes the OAuth 2.0 PKCE exchange after the system browser redirects. */
@Entry
@Component
struct OAuthCallback {
  @State status: string = 'Completing sign-in…';
  @State finished: boolean = false;
  @State succeeded: boolean = false;
  private api: WhatsAppOAuth = new WhatsAppOAuth();
  private started: boolean = false;

  aboutToAppear(): void {
    if (!this.started) {
      this.started = true;
      this.finish();
    }
  }

  private async finish(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uri = await oauthFlowStore.takeCallback(ctx);
    const code = queryParam(uri, 'code');
    const state = queryParam(uri, 'state');
    const error = queryParam(uri, 'error_description');
    const pending = await oauthFlowStore.load(ctx);

    if (error.length > 0) {
      await oauthFlowStore.clear(ctx);
      this.fail('Sign-in was cancelled: ' + error);
      return;
    }
    if (code.length === 0) {
      this.fail('No authorization code was returned.');
      return;
    }
    if (pending.verifier.length === 0 || pending.clientId.length === 0) {
      this.fail('The sign-in session expired. Start again from Settings.');
      return;
    }
    if (state !== pending.state) {
      await oauthFlowStore.clear(ctx);
      this.fail('The sign-in state did not match. Start again from Settings.');
      return;
    }

    await oauthFlowStore.clear(ctx);
    const result = await this.api.exchangeCode(pending.clientId, code, pending.verifier);
    if (!result.ok) {
      this.fail(result.errorText);
      return;
    }
    const profile = await this.api.profile(result.accessToken);
    await authStore.save(ctx, result.accessToken, profile === null ? '' : profile.id,
      profile === null ? '' : profile.name);
    this.succeeded = true;
    this.finished = true;
    this.status = 'Signed in. Opening WhatIsIt…';
    promptAction.showToast({ message: 'WhatsApp API connected', duration: 1400 });
    setTimeout(() => {
      router.replaceUrl({ url: 'pages/Index' });
    }, 500);
  }

  private fail(message: string): void {
    this.finished = true;
    this.succeeded = false;
    this.status = message;
  }

  build() {
    Column({ space: 16 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 78, height: 78 })
          .fill($r('app.color.brand_soft'))
        SymbolGlyph(this.succeeded ? $r('sys.symbol.checkmark') : $r('sys.symbol.message'))
          .fontSize(34)
          .fontColor([$r('app.color.brand')])
      }

      Text(this.succeeded ? 'Connected' : (this.finished ? 'Sign-in failed' : 'Finishing sign-in'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.ink'))

      Text(this.status)
        .fontSize(14)
        .fontColor($r('app.color.ink_subtle'))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })

      if (!this.finished) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color($r('app.color.brand'))
      }

      if (this.finished && !this.succeeded) {
        Button('Back to settings')
          .width(200)
          .height(42)
          .fontSize(14)
          .fontColor($r('app.color.brand_text'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(21)
          .onClick(() => {
            router.replaceUrl({ url: 'pages/Index' });
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
    .backgroundColor($r('app.color.bg_page'))
  }
}
