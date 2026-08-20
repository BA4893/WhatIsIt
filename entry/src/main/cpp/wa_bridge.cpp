// NAPI bridge for the embedded WhatsApp engine (wa_engine).
//
// Exposes the Rust whatsapp-rust core (compiled as libwa_engine.so) to
// ArkTS as a NAPI module: `import waEngine from 'libwa_engine.so'`.
//
// The Rust side exports a C ABI (engine/src/cabi.rs):
//   wa_engine_start(dataDir), wa_engine_stop(),
//   wa_engine_status(), wa_engine_chats(), wa_engine_messages(chat, limit),
//   wa_engine_start_pairing(), wa_engine_pair_code(phone), wa_engine_logout(),
//   wa_engine_send_message/reply/media(), wa_engine_react(),
//   wa_engine_mark_read(), wa_engine_call_*(), wa_engine_passkey_*(),
//   wa_engine_media_path(), wa_engine_set_event_cb(cb),
//   wa_engine_free_string(s)
//
// Events (qr/linked/message/receipt/chats/logged_out/pair_code/passkey_*/
// incoming_call/call_state) arrive on the engine thread; they are marshaled
// through a napi_threadsafe_function so the ArkTS callback always runs on the
// UI thread (safe for direct @State updates).
#include "napi/native_api.h"
#include "hilog/log.h"
#include <cstdlib>
#include <cstring>
#include <string>

// Declared in engine/src/cabi.rs (cdylib exports).
extern "C" {
void wa_engine_set_event_cb(void (*cb)(const char *type, const char *json));
int wa_engine_start(const char *data_dir);
int wa_engine_stop();
char *wa_engine_status();
char *wa_engine_chats();
char *wa_engine_messages(const char *chat, int limit);
void wa_engine_start_pairing();
int wa_engine_pair_code(const char *phone);
int wa_engine_logout();
char *wa_engine_send_message(const char *chat, const char *text);
char *wa_engine_send_reply(const char *chat, const char *text, const char *reply_to);
char *wa_engine_send_media(const char *chat, const char *path);
char *wa_engine_react(const char *chat, const char *message_id, const char *emoji);
char *wa_engine_mark_read(const char *chat);
char *wa_engine_call_start(const char *chat, int video);
char *wa_engine_call_accept(const char *call_id, int video);
char *wa_engine_call_reject(const char *call_id);
char *wa_engine_call_end(const char *call_id);
char *wa_engine_call_mute(const char *call_id, int muted);
char *wa_engine_call_camera(const char *call_id, int on);
char *wa_engine_passkey_request();
char *wa_engine_passkey_assertion(const char *credential_id, const char *assertion_json);
char *wa_engine_passkey_confirm();
char *wa_engine_passkey_cancel();
char *wa_engine_media_path(const char *id, const char *kind);
void wa_engine_free_string(char *s);
}

#undef LOG_TAG
#define LOG_TAG "WaEngine"
#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))

// ---- event marshaling (engine thread -> UI thread via TSFN) ----

/// Payload queued into the thread-safe function.
struct EventPayload {
    char *type;
    char *json;
};

static napi_threadsafe_function g_tsfn = nullptr;

/// Runs on the UI thread; forwards one queued event to the JS callback.
static void CallJs(napi_env env, napi_value js_cb, void *context, void *data) {
    (void)context;
    auto *payload = static_cast<EventPayload *>(data);
    if (payload == nullptr) return;
    napi_value args[2];
    napi_create_string_utf8(env, payload->type, strlen(payload->type), &args[0]);
    napi_create_string_utf8(env, payload->json, strlen(payload->json), &args[1]);
    napi_value global;
    napi_get_global(env, &global);
    napi_value result;
    napi_call_function(env, global, js_cb, 2, args, &result);
    free(payload->type);
    free(payload->json);
    delete payload;
}

/// Called by the Rust engine on each event (engine thread).
static void OnEngineEvent(const char *type, const char *json) {
    if (g_tsfn == nullptr) return;
    auto *payload = new EventPayload();
    payload->type = strdup(type);
    payload->json = strdup(json);
    // Nonblocking: never stall the engine on a busy UI thread.
    if (napi_call_threadsafe_function(g_tsfn, payload, napi_tsfn_nonblocking) != napi_ok) {
        free(payload->type);
        free(payload->json);
        delete payload;
    }
}

// ---- helpers ----

static char *dup_str(const std::string &s) {
    char *out = (char *)malloc(s.size() + 1);
    if (out) {
        memcpy(out, s.c_str(), s.size() + 1);
    }
    return out;
}

static std::string read_string(napi_env env, napi_value arg) {
    if (arg == nullptr) return "";
    size_t len = 0;
    napi_get_value_string_utf8(env, arg, nullptr, 0, &len);
    if (len == 0) return "";
    char *buf = (char *)malloc(len + 1);
    napi_get_value_string_utf8(env, arg, buf, len + 1, &len);
    std::string out(buf, len);
    free(buf);
    return out;
}

static bool read_bool(napi_env env, napi_value arg) {
    if (arg == nullptr) return false;
    bool out = false;
    napi_get_value_bool(env, arg, &out);
    return out;
}

/// Build a JS string from a Rust-allocated C string (freed via free_string).
static napi_value js_from_rust_string(napi_env env, char *s, const char *fallback) {
    napi_value result;
    if (s != nullptr) {
        napi_create_string_utf8(env, s, strlen(s), &result);
        wa_engine_free_string(s);
    } else {
        napi_create_string_utf8(env, fallback, strlen(fallback), &result);
    }
    return result;
}

// ---- NAPI entry points ----

static napi_value NapiStart(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string dir = read_string(env, argc >= 1 ? args[0] : nullptr);
    int rc = wa_engine_start(dir.c_str());
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiStop(napi_env env, napi_callback_info info) {
    int rc = wa_engine_stop();
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiStatus(napi_env env, napi_callback_info info) {
    return js_from_rust_string(env, wa_engine_status(), "{}");
}

static napi_value NapiChats(napi_env env, napi_callback_info info) {
    return js_from_rust_string(env, wa_engine_chats(), "[]");
}

static napi_value NapiMessages(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string chat = read_string(env, argc >= 1 ? args[0] : nullptr);
    int32_t limit = 200;
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &limit);
    }
    return js_from_rust_string(env, wa_engine_messages(chat.c_str(), limit), "[]");
}

static napi_value NapiStartPairing(napi_env env, napi_callback_info info) {
    wa_engine_start_pairing();
    return nullptr;
}

static napi_value NapiPairCode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string phone = read_string(env, argc >= 1 ? args[0] : nullptr);
    int rc = wa_engine_pair_code(phone.c_str());
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiLogout(napi_env env, napi_callback_info info) {
    int rc = wa_engine_logout();
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiSetEventCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1 && args[0] != nullptr) {
        if (g_tsfn != nullptr) {
            napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
            g_tsfn = nullptr;
        }
        napi_value resource_name;
        napi_create_string_utf8(env, "waEngineEvents", NAPI_AUTO_LENGTH, &resource_name);
        napi_create_threadsafe_function(env, args[0], nullptr, resource_name, 0, 1,
            nullptr, nullptr, nullptr, CallJs, &g_tsfn);
        wa_engine_set_event_cb(OnEngineEvent);
    }
    return nullptr;
}

// ---- generic wrapper for (chat, ...) string-returning C calls ----

using WaFn3 = char *(*)(const char *, const char *, const char *);
using WaFn2 = char *(*)(const char *, const char *);
using WaFn1 = char *(*)(const char *);
using WaFn1Bool = char *(*)(const char *, int);
using WaFn0 = char *(*)();

static napi_value Wrap3(napi_env env, napi_callback_info info, WaFn3 fn) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string a = read_string(env, argc >= 1 ? args[0] : nullptr);
    std::string b = read_string(env, argc >= 2 ? args[1] : nullptr);
    std::string c = read_string(env, argc >= 3 ? args[2] : nullptr);
    return js_from_rust_string(env, fn(a.c_str(), b.c_str(), c.c_str()), "{}");
}

static napi_value Wrap2(napi_env env, napi_callback_info info, WaFn2 fn) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string a = read_string(env, argc >= 1 ? args[0] : nullptr);
    std::string b = read_string(env, argc >= 2 ? args[1] : nullptr);
    return js_from_rust_string(env, fn(a.c_str(), b.c_str()), "{}");
}

static napi_value Wrap1(napi_env env, napi_callback_info info, WaFn1 fn) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string a = read_string(env, argc >= 1 ? args[0] : nullptr);
    return js_from_rust_string(env, fn(a.c_str()), "{}");
}

static napi_value Wrap1Bool(napi_env env, napi_callback_info info, WaFn1Bool fn) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string a = read_string(env, argc >= 1 ? args[0] : nullptr);
    bool b = read_bool(env, argc >= 2 ? args[1] : nullptr);
    return js_from_rust_string(env, fn(a.c_str(), b ? 1 : 0), "{}");
}

static napi_value Wrap0(napi_env env, napi_callback_info info, WaFn0 fn) {
    return js_from_rust_string(env, fn(), "{}");
}

static napi_value NapiSendMessage(napi_env env, napi_callback_info info) {
    return Wrap2(env, info, wa_engine_send_message);
}

static napi_value NapiSendReply(napi_env env, napi_callback_info info) {
    return Wrap3(env, info, wa_engine_send_reply);
}

static napi_value NapiSendMedia(napi_env env, napi_callback_info info) {
    return Wrap2(env, info, wa_engine_send_media);
}

static napi_value NapiReact(napi_env env, napi_callback_info info) {
    return Wrap3(env, info, wa_engine_react);
}

static napi_value NapiMarkRead(napi_env env, napi_callback_info info) {
    return Wrap1(env, info, wa_engine_mark_read);
}

static napi_value NapiCallStart(napi_env env, napi_callback_info info) {
    return Wrap1Bool(env, info, wa_engine_call_start);
}

static napi_value NapiCallAccept(napi_env env, napi_callback_info info) {
    return Wrap1Bool(env, info, wa_engine_call_accept);
}

static napi_value NapiCallReject(napi_env env, napi_callback_info info) {
    return Wrap1(env, info, wa_engine_call_reject);
}

static napi_value NapiCallEnd(napi_env env, napi_callback_info info) {
    return Wrap1(env, info, wa_engine_call_end);
}

static napi_value NapiCallMute(napi_env env, napi_callback_info info) {
    return Wrap1Bool(env, info, wa_engine_call_mute);
}

static napi_value NapiCallCamera(napi_env env, napi_callback_info info) {
    return Wrap1Bool(env, info, wa_engine_call_camera);
}

static napi_value NapiPasskeyRequest(napi_env env, napi_callback_info info) {
    return Wrap0(env, info, wa_engine_passkey_request);
}

static napi_value NapiPasskeyAssertion(napi_env env, napi_callback_info info) {
    return Wrap2(env, info, wa_engine_passkey_assertion);
}

static napi_value NapiPasskeyConfirm(napi_env env, napi_callback_info info) {
    return Wrap0(env, info, wa_engine_passkey_confirm);
}

static napi_value NapiPasskeyCancel(napi_env env, napi_callback_info info) {
    return Wrap0(env, info, wa_engine_passkey_cancel);
}

static napi_value NapiMediaPath(napi_env env, napi_callback_info info) {
    return Wrap2(env, info, wa_engine_media_path);
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, NapiStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, NapiStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, NapiStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"chats", nullptr, NapiChats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"messages", nullptr, NapiMessages, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startPairing", nullptr, NapiStartPairing, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pairCode", nullptr, NapiPairCode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"logout", nullptr, NapiLogout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEventCallback", nullptr, NapiSetEventCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMessage", nullptr, NapiSendMessage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendReply", nullptr, NapiSendReply, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMedia", nullptr, NapiSendMedia, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"react", nullptr, NapiReact, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"markRead", nullptr, NapiMarkRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"callStart", nullptr, NapiCallStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"callAccept", nullptr, NapiCallAccept, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"callReject", nullptr, NapiCallReject, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"callEnd", nullptr, NapiCallEnd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"callMute", nullptr, NapiCallMute, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"callCamera", nullptr, NapiCallCamera, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"passkeyRequest", nullptr, NapiPasskeyRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"passkeyAssertion", nullptr, NapiPasskeyAssertion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"passkeyConfirm", nullptr, NapiPasskeyConfirm, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"passkeyCancel", nullptr, NapiPasskeyCancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mediaPath", nullptr, NapiMediaPath, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module waEngineModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "wa_engine",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterWaEngineModule(void) {
    napi_module_register(&waEngineModule);
}