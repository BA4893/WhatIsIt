package server

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"

	// Register the pure-Go sqlite driver as "sqlite3" for the whatsmeow store.
	_ "whatisit/server-go/sqlite3shim"
)

// WAClient wraps the whatsmeow client and adapts its events to the app's
// EventBus + HistoryStore contract.
type WAClient struct {
	cli   *whatsmeow.Client
	state *AppState
	// QR stream (active while pairing).
	qrCh <-chan whatsmeow.QRChannelItem
	cancelQR context.CancelFunc
	// pairMu serializes pairing (re)starts so concurrent /pair calls don't
	// tear down a live QR stream.
	pairMu sync.Mutex
	// Passkey request options currently pending (recoverable via /passkey/request).
	passkeyOpts string
}

// NewWAClient initializes the SQLite device store and whatsmeow client.
func NewWAClient(ctx context.Context, cfg *Config, state *AppState) (*WAClient, error) {
	storeContainer, err := sqlstore.New(ctx, "sqlite3", fmt.Sprintf("file:%s?_foreign_keys=on", cfg.DBPath), waLog.Stdout("Database", "DEBUG", true))
	if err != nil {
		return nil, fmt.Errorf("open sqlite store: %w", err)
	}
	deviceStore, err := storeContainer.GetFirstDevice(ctx)
	if err != nil {
		return nil, fmt.Errorf("get device: %w", err)
	}
	cli := whatsmeow.NewClient(deviceStore, waLog.Stdout("Client", "DEBUG", true))
	wc := &WAClient{cli: cli, state: state}
	cli.AddEventHandler(wc.handleEvent)
	cli.EnableAutoReconnect = true
	return wc, nil
}

// Client exposes the underlying whatsmeow client.
func (wc *WAClient) Client() *whatsmeow.Client { return wc.cli }

// Connect connects to WhatsApp (or starts pairing if no session).
func (wc *WAClient) Connect(ctx context.Context) error {
	if wc.cli.Store.ID == nil {
		// No stored session: start QR pairing.
		wc.startQR(ctx)
		return wc.cli.Connect()
	}
	if err := wc.cli.Connect(); err != nil {
		return err
	}
	// Restore linked state.
	phone := wc.cli.Store.ID.User
	wc.state.SetPhone(phone)
	wc.state.Store.SetPhone(phone)
	return nil
}

// StartPairing (re)starts the QR pairing stream. If a QR stream is already
// active and the client is connected it is a no-op (the existing codes keep
// rotating). If already linked it is a no-op too.
func (wc *WAClient) StartPairing(ctx context.Context) error {
	wc.pairMu.Lock()
	defer wc.pairMu.Unlock()
	if wc.cli.Store.ID != nil {
		return nil
	}
	if wc.qrCh != nil && wc.cli.IsConnected() {
		return nil
	}
	if wc.cancelQR != nil {
		wc.cancelQR()
		wc.cancelQR = nil
	}
	if wc.cli.IsConnected() {
		wc.cli.Disconnect()
	}
	wc.startQR(ctx)
	return wc.cli.Connect()
}

// startQR begins the QR pairing stream and pushes codes via the event bus.
func (wc *WAClient) startQR(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	wc.cancelQR = cancel
	ch, err := wc.cli.GetQRChannel(ctx)
	if err != nil {
		log.Printf("get QR channel: %v", err)
		return
	}
	wc.qrCh = ch
	wc.cancelQR = cancel
	go func() {
		for item := range ch {
			switch item.Event {
			case "code":
				wc.state.SetQR(item.Code)
				wc.state.Bus.Publish(EvQr(item.Code))
			case "timeout":
				wc.state.SetQR("")
				wc.state.Bus.Publish(EvQr(""))
			}
		}
		// Channel closed by whatsmeow (timeout/error). It has called
		// cli.Disconnect(); wait for that teardown to finish so the fresh
		// socket isn't killed by the old one, then restart pairing.
		if wc.cli.Store.ID == nil {
			for i := 0; i < 50 && wc.cli.IsConnected(); i++ {
				time.Sleep(100 * time.Millisecond)
			}
			if err := wc.StartPairing(context.Background()); err != nil {
				log.Printf("restart pairing after QR timeout: %v", err)
			}
		}
	}()
}

// PairCode starts phone-number linking and returns the 8-char code.
func (wc *WAClient) PairCode(ctx context.Context, phone string) (string, error) {
	wc.pairMu.Lock()
	defer wc.pairMu.Unlock()
	if wc.cli.Store.ID != nil {
		return "", fmt.Errorf("device already linked; log out first")
	}
	if !wc.cli.IsConnected() {
		// The 8-char flow needs a live socket. Make sure the QR pairing
		// stream is running (this also dials WhatsApp), then wait for it.
		if wc.qrCh == nil {
			wc.startQR(ctx)
		}
		if err := wc.cli.Connect(); err != nil {
			return "", fmt.Errorf("connect: %w", err)
		}
		select {
		case <-wc.qrCh:
		case <-time.After(5 * time.Second):
			return "", fmt.Errorf("timed out waiting for connection")
		}
	}
	code, err := wc.cli.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Windows)")
	if err != nil {
		return "", err
	}
	wc.state.SetPairCode(code)
	wc.state.Bus.Publish(EvPairCode(code))
	return code, nil
}

// handleEvent adapts whatsmeow events to the app's event bus + store.
func (wc *WAClient) handleEvent(evt any) {
	switch e := evt.(type) {
	case *events.QR:
		// GetQRChannel handles QR; this is a fallback for the first code.
	case *events.PairSuccess:
		wc.onLinked(e)
	case *events.Connected:
		if wc.cli.Store.ID != nil {
			phone := wc.cli.Store.ID.User
			wc.state.SetPhone(phone)
			wc.state.Store.SetPhone(phone)
			wc.state.Bus.Publish(EvLinked(phone))
		}
		// Announce the session as available so the phone's Linked devices
		// view shows it as "Active now" instead of the last link timestamp.
		wc.sendPresence()
	case *events.LoggedOut:
		wc.onLoggedOut()
	case *events.PairPasskeyRequest:
		wc.onPasskeyRequest(e)
	case *events.PairPasskeyConfirmation:
		wc.state.Bus.Publish(EvPasskeyConf(e.Code))
	case *events.PairPasskeyError:
		wc.state.Bus.Publish(EvPasskeyErr(e.Error.Error()))
	case *events.Message:
		wc.onMessage(e)
	case *events.HistorySync:
		wc.onHistorySync(e)
	case *events.Receipt:
		wc.onReceipt(e)
	case *events.ChatPresence:
		// Presence updates are not part of the app contract; ignore.
	}
}

func (wc *WAClient) onLinked(e *events.PairSuccess) {
	phone := e.ID.User
	wc.state.SetPhone(phone)
	wc.state.Store.SetPhone(phone)
	wc.state.Bus.Publish(EvLinked(phone))
}

// sendPresence announces the session as available so the phone's Linked
// devices view shows it as "Active now" instead of the last link timestamp.
func (wc *WAClient) sendPresence() {
	if wc.cli.Store.ID == nil || !wc.cli.IsConnected() {
		return
	}
	if err := wc.cli.SendPresence(wc.cli.BackgroundEventCtx, types.PresenceAvailable); err != nil {
		log.Printf("send presence: %v", err)
	}
}

func (wc *WAClient) onLoggedOut() {
	wc.state.SetPhone("")
	wc.state.Store.SetPhone("")
	wc.state.SetQR("")
	wc.state.Bus.Publish(EvLoggedOut())
	// The QR goroutine already exited (it closed on pair success), so the
	// client is disconnected with no live QR. Restart pairing so the app gets
	// a fresh QR and a live socket for the 8-char flow too.
	go func() {
		time.Sleep(500 * time.Millisecond)
		if err := wc.StartPairing(context.Background()); err != nil {
			log.Printf("restart pairing after logout: %v", err)
		}
	}()
}

func (wc *WAClient) onPasskeyRequest(e *events.PairPasskeyRequest) {
	if e.PublicKey == nil {
		wc.state.Bus.Publish(EvPasskeyErr("passkey request had no public key"))
		return
	}
	opts := mustJSON(e.PublicKey)
	// Install the answer channel before publishing the request. Without this,
	// /passkey/assertion finds no pending ceremony and returns 409, leaving the
	// companion link stalled.
	answer := wc.state.InstallPasskeyAnswer()
	go wc.awaitPasskeyAnswer(answer)
	wc.state.SetPasskeyPending(opts)
	wc.state.Bus.Publish(EvPasskeyReq(opts))
}

// awaitPasskeyAnswer turns the app's WebAuthn assertion into a whatsmeow
// SendPasskeyResponse. WhatsApp then sends PairPasskeyConfirmation, which the
// event handler publishes as passkey_confirmation.
func (wc *WAClient) awaitPasskeyAnswer(answer chan PasskeyAnswer) {
	timer := time.NewTimer(5 * time.Minute)
	defer timer.Stop()
	select {
	case ans := <-answer:
		if ans.Cancelled || ans.Assertion == nil {
			return
		}
		var resp types.WebAuthnResponse
		if err := json.Unmarshal(ans.Assertion.AssertionJSON, &resp); err != nil {
			log.Printf("passkey assertion JSON: %v", err)
			wc.state.Bus.Publish(EvPasskeyErr("invalid passkey assertion: " + err.Error()))
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		if err := wc.PasskeyResponse(ctx, &resp); err != nil {
			log.Printf("send passkey response: %v", err)
			wc.state.Bus.Publish(EvPasskeyErr(err.Error()))
		}
	case <-timer.C:
		wc.state.Bus.Publish(EvPasskeyErr("passkey request timed out"))
		wc.state.TakePasskeyPending()
	}
}

// PasskeyResponse sends the app's WebAuthn assertion to complete the ceremony.
func (wc *WAClient) PasskeyResponse(ctx context.Context, resp *types.WebAuthnResponse) error {
	return wc.cli.SendPasskeyResponse(ctx, resp)
}

// PasskeyConfirm finishes the pairing after the code match.
func (wc *WAClient) PasskeyConfirm(ctx context.Context) error {
	return wc.cli.SendPasskeyConfirmation(ctx)
}

func (wc *WAClient) onMessage(e *events.Message) {
	chat := e.Info.Chat.String()
	msg := Message{
		ID:     e.Info.ID,
		Chat:   chat,
		Dir:    "in",
		Time:   e.Info.Timestamp.UnixMilli(),
		Status: "received",
		FromMe: e.Info.IsFromMe,
	}
	if e.Info.IsFromMe {
		msg.Dir = "out"
	}
	// Extract text / media / reply.
	extractMessage(e, &msg)
	// Cache incoming media (mirror media.rs::maybe_cache_media).
	if msg.Media != nil && !msg.FromMe {
		if dl, ok := mediaDownloadable(e.Message); ok {
			wc.cacheIncomingMedia(wc.cli.BackgroundEventCtx, e, msg.Media.Kind, dl)
		}
	}
	if e.Info.IsFromMe {
		msg.Status = "sent"
	}
	// Upsert + broadcast.
	wc.state.Store.UpsertMessage(msg)
	// Status posts live in the status@broadcast chat: record the latest update
	// per contact for the Status tab. They must never appear as a normal chat
	// (Chats() filters @broadcast) or take the sender's number as a name.
	if e.Info.Chat.Server == types.BroadcastServer && !e.Info.IsFromMe && e.Info.Sender.User != "" {
		wc.state.Store.AddStatus(StatusEntry{
			Sender: e.Info.Sender.String(),
			Name:   wc.contactName(e.Info.Sender),
			Text:   msg.Text,
			Kind:   statusKind(msg),
			Time:   msg.Time,
			Media:  msg.Media,
		})
	}
	// Update the chat preview name — 1:1 chats only. Group subjects come from
	// history sync (never overwrite them with a member's number), and a
	// numeric-only name never beats a name history sync already stored.
	if !e.Info.IsFromMe && e.Info.Chat.Server == types.DefaultUserServer && e.Info.Chat.User == e.Info.Sender.User {
		if name := wc.contactName(e.Info.Sender); name != "" && name != e.Info.Sender.User {
			wc.state.Store.SetName(chat, name)
		}
	}
	wc.state.Bus.Publish(EvMessage(chat))
}

func (wc *WAClient) onReceipt(e *events.Receipt) {
	if len(e.MessageIDs) == 0 {
		return
	}
	chat := e.Chat.String()
	status := "delivered"
	if e.Type == events.ReceiptTypeRead || e.Type == events.ReceiptTypeReadSelf {
		status = "read"
	}
	for _, id := range e.MessageIDs {
		wc.state.Store.SetStatus(chat, id, status)
	}
	wc.state.Bus.Publish(EvReceipt(chat))
}

// SendText sends a text message, returns the message ID.
func (wc *WAClient) SendText(ctx context.Context, jid types.JID, text, replyTo string) (string, error) {
	msg := &waE2E.Message{Conversation: &text}
	if replyTo != "" {
		ext := &waE2E.ExtendedTextMessage{
			Text:        &text,
			ContextInfo: &waE2E.ContextInfo{StanzaID: &replyTo},
		}
		msg = &waE2E.Message{ExtendedTextMessage: ext}
	}
	resp, err := wc.cli.SendMessage(ctx, jid, msg)
	if err != nil {
		return "", err
	}
	return resp.ID, nil
}

// RequestHistoryBackfill asks the phone's primary device for up to `count`
// messages older than the oldest message we hold for `chat` (whatsmeow's
// on-demand history sync — the same mechanism WhatsApp Web uses when you scroll
// up). The result arrives later as an events.HistorySync (type ON_DEMAND) which
// onHistorySync ingests into the store.
func (wc *WAClient) RequestHistoryBackfill(ctx context.Context, chat types.JID, count int) error {
	oldest := wc.state.Store.OldestMessage(chat.String())
	if oldest == nil {
		return fmt.Errorf("no messages stored for %s; nothing to backfill before", chat)
	}
	if count <= 0 {
		count = 50
	}
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:     chat,
			IsFromMe: oldest.FromMe,
		},
		ID:        types.MessageID(oldest.ID),
		Timestamp: time.UnixMilli(oldest.Time),
	}
	req := wc.cli.BuildHistorySyncRequest(info, count)
	_, err := wc.cli.SendPeerMessage(ctx, req)
	if err != nil {
		return fmt.Errorf("request backfill: %w", err)
	}
	log.Printf("history backfill requested for %s: %d messages before %s", chat, count, oldest.ID)
	return nil
}

// Logout disconnects and clears the stored session.
func (wc *WAClient) Logout(ctx context.Context) error {
	return wc.cli.Logout(ctx)
}

// React sends (or removes, with "") a reaction on a message.
func (wc *WAClient) React(ctx context.Context, chat types.JID, messageID, emoji string) error {
	msg := wc.cli.BuildReaction(chat, chat, types.MessageID(messageID), emoji)
	_, err := wc.cli.SendMessage(ctx, chat, msg)
	return err
}

// SendMedia uploads a file and sends it as a media message (image/video/audio
// by extension, document otherwise), mirroring media.rs::handle_send_media.
func (wc *WAClient) SendMedia(ctx context.Context, chat types.JID, data []byte, filename, mime string) (string, error) {
	mediaType := wc.mediaTypeForFilename(filename)
	resp, err := wc.cli.Upload(ctx, data, mediaType)
	if err != nil {
		return "", err
	}
	msg := wc.buildMediaMessage(mediaType, resp, filename)
	sent, err := wc.cli.SendMessage(ctx, chat, msg)
	if err != nil {
		return "", err
	}
	return sent.ID, nil
}

func (wc *WAClient) mediaTypeForFilename(filename string) whatsmeow.MediaType {
	switch ext := strings.ToLower(filename[strings.LastIndexByte(filename, '.')+1:]); ext {
	case "jpg", "jpeg", "png", "gif", "webp":
		return whatsmeow.MediaImage
	case "mp4", "mov", "mkv", "3gp":
		return whatsmeow.MediaVideo
	case "mp3", "m4a", "ogg", "opus", "wav":
		return whatsmeow.MediaAudio
	}
	return whatsmeow.MediaDocument
}

func (wc *WAClient) buildMediaMessage(mediaType whatsmeow.MediaType, up whatsmeow.UploadResponse, filename string) *waE2E.Message {
	length := &up.FileLength
	switch mediaType {
	case whatsmeow.MediaImage:
		return &waE2E.Message{
			ImageMessage: &waE2E.ImageMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("image/jpeg"),
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	case whatsmeow.MediaVideo:
		return &waE2E.Message{
			VideoMessage: &waE2E.VideoMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("video/mp4"),
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	case whatsmeow.MediaAudio:
		return &waE2E.Message{
			AudioMessage: &waE2E.AudioMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("audio/ogg"),
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	default:
		return &waE2E.Message{
			DocumentMessage: &waE2E.DocumentMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("application/octet-stream"),
				FileName:   &filename,
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	}
}

// cacheIncomingMedia downloads a media message to the cache (mirrors
// media.rs::maybe_cache_media). Non-blocking best-effort.
func (wc *WAClient) cacheIncomingMedia(ctx context.Context, e *events.Message, kind string, downloadable whatsmeow.DownloadableMessage) {
	go func() {
		data, err := wc.cli.Download(ctx, downloadable)
		if err != nil {
			log.Printf("media download %s: %v", kind, err)
			return
		}
		if err := wc.state.Media.Put(e.Info.ID, kind, data); err != nil {
			log.Printf("media cache %s: %v", kind, err)
		}
	}()
}

// IsConnected reports the connection state.
func (wc *WAClient) IsConnected() bool { return wc.cli.IsConnected() }

// ---- helpers ----

// contactName resolves the display name for a user JID: the user's saved
// contact name (FullName), then their WhatsApp push name, then the bare
// number. Non-user JIDs (groups, broadcasts) fall back to the local part.
func (wc *WAClient) contactName(jid types.JID) string {
	if jid.Server != types.DefaultUserServer {
		return jid.User
	}
	if wc.cli != nil && wc.cli.Store != nil && wc.cli.Store.Contacts != nil {
		if c, err := wc.cli.Store.Contacts.GetContact(context.Background(), jid); err == nil {
			for _, n := range []string{c.FullName, c.PushName, c.FirstName, c.BusinessName} {
				if n != "" {
					return n
				}
			}
		}
	}
	return jid.User
}

// statusKind labels a status update for the Status tab (media kind or text).
func statusKind(msg Message) string {
	if msg.Media != nil {
		return msg.Media.Kind
	}
	return "text"
}

func mustJSON(v any) string {
	b, _ := jsonMarshal(v)
	return string(b)
}

func jsonMarshal(v any) ([]byte, error) {
	return jsonMarshalImpl(v)
}

// trimJID normalizes a chat arg to a bare JID string.
func trimJID(s string) string {
	if i := strings.IndexByte(s, '@'); i >= 0 {
		return s
	}
	return s
}
