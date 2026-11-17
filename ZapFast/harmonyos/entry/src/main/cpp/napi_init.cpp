// NAPI surface and XComponent bridge for ZapFast on HarmonyOS.
//
// ArkTS owns the page, the window and the pickers; this file forwards the
// surface, the input events and the lifecycle to the Rust host through the C
// ABI in harmonyos/rust/src/lib.rs, and exposes the few calls ArkTS needs (start,
// stop, text, clipboard polling, soft keyboard) as a NAPI module.
//
// The same shared library is the XComponent's `libraryname`. When ArkUI loads
// it for the component, the exports carry the native XComponent handle, so
// the surface and input callbacks are registered here, on the UI thread,
// rather than polling a surface id from ArkTS.

#include <napi/native_api.h>

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arkui/ui_input_event.h>
#include <hilog/log.h>

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x5A46
#define LOG_TAG "ZapFast"

#define ZF_LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define ZF_LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)
#define ZF_LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

extern "C" {
void zapfast_ohos_start(const char* files_dir, const char* cache_dir,
                        float density, int32_t demo);
void zapfast_ohos_stop();
void zapfast_ohos_surface_created(void* window, int32_t width, int32_t height);
void zapfast_ohos_surface_changed();
void zapfast_ohos_surface_destroyed();
void zapfast_ohos_set_density(float density);
void zapfast_ohos_touch(int32_t action, int32_t id, float x, float y,
                        float force);
void zapfast_ohos_mouse(int32_t action, int32_t button, float x, float y);
void zapfast_ohos_key(int32_t action, int32_t code);
void zapfast_ohos_text(const char* text);
void zapfast_ohos_axis(float horizontal, float vertical, float scroll_step,
                       int32_t mouse);
void zapfast_ohos_focus(int32_t focused);
void zapfast_ohos_pause();
void zapfast_ohos_resume();
void zapfast_ohos_paste(const char* text);
int32_t zapfast_ohos_text_input_wanted();
int32_t zapfast_ohos_take_clipboard(char* out, int32_t capacity);
int32_t zapfast_ohos_take_open_url(char* out, int32_t capacity);
int32_t zapfast_ohos_version(char* out, int32_t capacity);
}

namespace {

OH_NativeXComponent* g_component = nullptr;
std::atomic<bool> g_soft_keyboard{false};

// The component's module is loaded and its callbacks registered before
// ArkTS's onLoad calls `start`, and the first surface can arrive before
// `start` does. Keep it until the Rust host exists, then hand it over.
std::atomic<bool> g_started{false};
void* g_pending_window = nullptr;
int32_t g_pending_width = 0;
int32_t g_pending_height = 0;

std::string GetString(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return "";
  }
  std::vector<char> buffer(length + 1, '\0');
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                 &length) != napi_ok) {
    return "";
  }
  return std::string(buffer.data(), length);
}

double GetDouble(napi_env env, napi_value value, double fallback) {
  double out = fallback;
  if (napi_get_value_double(env, value, &out) != napi_ok) {
    return fallback;
  }
  return out;
}

bool GetBool(napi_env env, napi_value value) {
  bool out = false;
  return napi_get_value_bool(env, value, &out) == napi_ok && out;
}

std::string TakeText(int32_t (*take)(char*, int32_t)) {
  char probe = 0;
  int32_t needed = take(&probe, 0);
  if (needed == 0) {
    return "";
  }
  if (needed < 0) {
    needed = -needed;
  }
  if (needed <= 1 || needed > (1 << 20)) {
    return "";
  }
  std::vector<char> buffer(static_cast<size_t>(needed), '\0');
  int32_t written = take(buffer.data(), needed);
  if (written <= 0) {
    return "";
  }
  return std::string(buffer.data(), static_cast<size_t>(written - 1));
}

// ---------------------------------------------------------------- surface

void OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
  uint64_t width = 0;
  uint64_t height = 0;
  OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
  ZF_LOGI("surface created: %{public}llux%{public}llu",
          static_cast<unsigned long long>(width),
          static_cast<unsigned long long>(height));
  if (!g_started.load()) {
    g_pending_window = window;
    g_pending_width = static_cast<int32_t>(width);
    g_pending_height = static_cast<int32_t>(height);
    return;
  }
  zapfast_ohos_surface_created(window, static_cast<int32_t>(width),
                               static_cast<int32_t>(height));
}

void OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
  uint64_t width = 0;
  uint64_t height = 0;
  OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
  ZF_LOGI("surface changed: %{public}llux%{public}llu",
          static_cast<unsigned long long>(width),
          static_cast<unsigned long long>(height));
  if (!g_started.load()) {
    if (g_pending_window != nullptr) {
      g_pending_width = static_cast<int32_t>(width);
      g_pending_height = static_cast<int32_t>(height);
    }
    return;
  }
  zapfast_ohos_surface_changed();
}

void OnSurfaceDestroyed(OH_NativeXComponent*, void*) {
  ZF_LOGI("surface destroyed");
  if (!g_started.load()) {
    g_pending_window = nullptr;
    return;
  }
  zapfast_ohos_surface_destroyed();
}

void OnTouch(OH_NativeXComponent* component, void* window) {
  OH_NativeXComponent_TouchEvent event;
  if (OH_NativeXComponent_GetTouchEvent(component, window, &event) !=
      OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
    return;
  }
  zapfast_ohos_touch(static_cast<int32_t>(event.type),
                     static_cast<int32_t>(event.id), event.x, event.y,
                     event.force);
}

// ---------------------------------------------------------------- mouse

int32_t MouseAction(int32_t action) {
  switch (action) {
    case UI_MOUSE_EVENT_ACTION_PRESS:
      return 0;
    case UI_MOUSE_EVENT_ACTION_RELEASE:
      return 1;
    case UI_MOUSE_EVENT_ACTION_MOVE:
      return 2;
    case UI_MOUSE_EVENT_ACTION_CANCEL:
      return 4;
    default:
      return -1;
  }
}

int32_t MouseButton(int32_t button) {
  switch (button) {
    case UI_MOUSE_EVENT_BUTTON_RIGHT:
      return 1;
    case UI_MOUSE_EVENT_BUTTON_MIDDLE:
      return 2;
    case UI_MOUSE_EVENT_BUTTON_BACK:
      return 3;
    case UI_MOUSE_EVENT_BUTTON_FORWARD:
      return 4;
    default:
      return 0;
  }
}

// ---------------------------------------------------------------- keyboard

void OnKey(OH_NativeXComponent* component, void*) {
  OH_NativeXComponent_KeyEvent* event = nullptr;
  if (OH_NativeXComponent_GetKeyEvent(component, &event) !=
          OH_NATIVEXCOMPONENT_RESULT_SUCCESS ||
      event == nullptr) {
    return;
  }
  OH_NativeXComponent_KeyAction action = OH_NATIVEXCOMPONENT_KEY_ACTION_UNKNOWN;
  OH_NativeXComponent_KeyCode code = KEY_UNKNOWN;
  OH_NativeXComponent_GetKeyEventAction(event, &action);
  OH_NativeXComponent_GetKeyEventCode(event, &code);
  zapfast_ohos_key(action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN ? 0 : 1,
                   static_cast<int32_t>(code));
}

void OnFocus(OH_NativeXComponent*, void*) { zapfast_ohos_focus(1); }

void OnBlur(OH_NativeXComponent*, void*) { zapfast_ohos_focus(0); }

// ---------------------------------------------------------------- wheel

void OnUIInputEvent(OH_NativeXComponent*, ArkUI_UIInputEvent* event,
                    ArkUI_UIInputEvent_Type type) {
  if (event == nullptr) {
    return;
  }
  if (type == ARKUI_UIINPUTEVENT_TYPE_MOUSE) {
    const int32_t action = MouseAction(OH_ArkUI_MouseEvent_GetMouseAction(event));
    if (action < 0) {
      return;
    }
    zapfast_ohos_mouse(action,
                       MouseButton(OH_ArkUI_MouseEvent_GetMouseButton(event)),
                       OH_ArkUI_PointerEvent_GetX(event),
                       OH_ArkUI_PointerEvent_GetY(event));
    return;
  }
  if (type != ARKUI_UIINPUTEVENT_TYPE_AXIS) {
    return;
  }
  const int32_t action = OH_ArkUI_AxisEvent_GetAxisAction(event);
  if (action != UI_AXIS_EVENT_ACTION_BEGIN && action != UI_AXIS_EVENT_ACTION_UPDATE) {
    return;
  }
  const double vertical = OH_ArkUI_AxisEvent_GetVerticalAxisValue(event);
  const double horizontal = OH_ArkUI_AxisEvent_GetHorizontalAxisValue(event);
  const int32_t step = OH_ArkUI_AxisEvent_GetScrollStep(event);
  const int32_t source = OH_ArkUI_UIInputEvent_GetSourceType(event);
  zapfast_ohos_axis(static_cast<float>(horizontal),
                    static_cast<float>(vertical), static_cast<float>(step),
                    source == UI_INPUT_EVENT_SOURCE_TYPE_MOUSE ? 1 : 0);
}

// ---------------------------------------------------------------- NAPI

napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    ZF_LOGE("start needs filesDir, cacheDir and density");
    return nullptr;
  }
  const std::string files = GetString(env, args[0]);
  const std::string cache = GetString(env, args[1]);
  const double density = GetDouble(env, args[2], 1.0);
  const bool demo = argc > 3 && GetBool(env, args[3]);
  ZF_LOGI("start: files=%{public}s density=%{public}f demo=%{public}d",
          files.c_str(), density, demo ? 1 : 0);
  zapfast_ohos_start(files.c_str(), cache.c_str(),
                     static_cast<float>(density), demo ? 1 : 0);
  g_started.store(true);
  // A surface that arrived before the host did is handed over now.
  if (g_pending_window != nullptr) {
    void* window = g_pending_window;
    const int32_t width = g_pending_width;
    const int32_t height = g_pending_height;
    g_pending_window = nullptr;
    ZF_LOGI("handing over the early surface");
    zapfast_ohos_surface_created(window, width, height);
  }
  return nullptr;
}

napi_value Stop(napi_env, napi_callback_info) {
  g_started.store(false);
  g_pending_window = nullptr;
  zapfast_ohos_stop();
  return nullptr;
}

napi_value SetDensity(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc >= 1) {
    zapfast_ohos_set_density(
        static_cast<float>(GetDouble(env, args[0], 1.0)));
  }
  return nullptr;
}

napi_value Text(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc >= 1) {
    const std::string text = GetString(env, args[0]);
    if (!text.empty()) {
      zapfast_ohos_text(text.c_str());
    }
  }
  return nullptr;
}

napi_value Paste(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc >= 1) {
    const std::string text = GetString(env, args[0]);
    if (!text.empty()) {
      zapfast_ohos_paste(text.c_str());
    }
  }
  return nullptr;
}

napi_value TakeClipboard(napi_env env, napi_callback_info) {
  const std::string text = TakeText(zapfast_ohos_take_clipboard);
  napi_value result = nullptr;
  napi_get_undefined(env, &result);
  if (text.empty()) {
    return result;
  }
  napi_create_string_utf8(env, text.c_str(), text.size(), &result);
  return result;
}

napi_value TakeOpenUrl(napi_env env, napi_callback_info) {
  const std::string url = TakeText(zapfast_ohos_take_open_url);
  napi_value result = nullptr;
  napi_get_undefined(env, &result);
  if (url.empty()) {
    return result;
  }
  napi_create_string_utf8(env, url.c_str(), url.size(), &result);
  return result;
}

napi_value TextInputWanted(napi_env env, napi_callback_info) {
  napi_value result = nullptr;
  napi_get_boolean(env, zapfast_ohos_text_input_wanted() != 0, &result);
  return result;
}

napi_value ShowSoftKeyboard(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  const bool wanted = argc >= 1 && GetBool(env, args[0]);
  if (g_component == nullptr) {
    ZF_LOGW("no XComponent handle for the soft keyboard");
    return nullptr;
  }
  const bool was = g_soft_keyboard.exchange(wanted);
  if (was != wanted) {
    OH_NativeXComponent_SetNeedSoftKeyboard(g_component, wanted);
    ZF_LOGI("soft keyboard wanted=%{public}d", wanted ? 1 : 0);
  }
  return nullptr;
}

napi_value Version(napi_env env, napi_callback_info) {
  const std::string version = TakeText(zapfast_ohos_version);
  napi_value result = nullptr;
  napi_create_string_utf8(env, version.c_str(), version.size(), &result);
  return result;
}

napi_value Pause(napi_env, napi_callback_info) {
  zapfast_ohos_pause();
  return nullptr;
}

napi_value Resume(napi_env, napi_callback_info) {
  zapfast_ohos_resume();
  return nullptr;
}

napi_value Focus(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  zapfast_ohos_focus(argc >= 1 && GetBool(env, args[0]) ? 1 : 0);
  return nullptr;
}

napi_value Mouse(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t action = 4;
  int32_t button = 0;
  double x = 0;
  double y = 0;
  if (argc >= 1) napi_get_value_int32(env, args[0], &action);
  if (argc >= 2) napi_get_value_int32(env, args[1], &button);
  if (argc >= 3) napi_get_value_double(env, args[2], &x);
  if (argc >= 4) napi_get_value_double(env, args[3], &y);
  zapfast_ohos_mouse(action, button, static_cast<float>(x), static_cast<float>(y));
  return nullptr;
}

napi_value Axis(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  double horizontal = 0;
  double vertical = 0;
  double step = 0;
  bool mouse = false;
  if (argc >= 1) napi_get_value_double(env, args[0], &horizontal);
  if (argc >= 2) napi_get_value_double(env, args[1], &vertical);
  if (argc >= 3) napi_get_value_double(env, args[2], &step);
  if (argc >= 4) mouse = GetBool(env, args[3]);
  zapfast_ohos_axis(static_cast<float>(horizontal),
                    static_cast<float>(vertical),
                    static_cast<float>(step), mouse ? 1 : 0);
  return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
      {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setDensity", nullptr, SetDensity, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"text", nullptr, Text, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"paste", nullptr, Paste, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"takeClipboard", nullptr, TakeClipboard, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"takeOpenUrl", nullptr, TakeOpenUrl, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"textInputWanted", nullptr, TextInputWanted, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"showSoftKeyboard", nullptr, ShowSoftKeyboard, nullptr, nullptr,
       nullptr, napi_default, nullptr},
      {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"resume", nullptr, Resume, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"focus", nullptr, Focus, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"mouse", nullptr, Mouse, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"axis", nullptr, Axis, nullptr, nullptr, nullptr, napi_default,
       nullptr},
  };
  napi_define_properties(env, exports,
                         sizeof(descriptors) / sizeof(descriptors[0]),
                         descriptors);

  // The XComponent hands its native handle over in the exports it passes to
  // this module. Without it (an ordinary `import` of the library), the module
  // still works: only the surface and input callbacks have nothing to attach
  // to, which is exactly when there is no XComponent to attach them to.
  napi_value instance = nullptr;
  if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ,
                              &instance) != napi_ok ||
      instance == nullptr) {
    ZF_LOGW("loaded without an XComponent; no surface callbacks registered");
    return exports;
  }
  OH_NativeXComponent* component = nullptr;
  if (napi_unwrap(env, instance, reinterpret_cast<void**>(&component)) !=
          napi_ok ||
      component == nullptr) {
    ZF_LOGE("the exports did not carry a native XComponent");
    return exports;
  }
  g_component = component;

  static OH_NativeXComponent_Callback callbacks = {
      .OnSurfaceCreated = OnSurfaceCreated,
      .OnSurfaceChanged = OnSurfaceChanged,
      .OnSurfaceDestroyed = OnSurfaceDestroyed,
      .DispatchTouchEvent = OnTouch,
  };
  int32_t surface_result =
      OH_NativeXComponent_RegisterCallback(component, &callbacks);
  int32_t axis_events = OH_NativeXComponent_RegisterUIInputEventCallback(
      component, OnUIInputEvent, ARKUI_UIINPUTEVENT_TYPE_AXIS);
  int32_t mouse_events = OH_NativeXComponent_RegisterUIInputEventCallback(
      component, OnUIInputEvent, ARKUI_UIINPUTEVENT_TYPE_MOUSE);
  ZF_LOGI("XComponent callbacks: surface=%{public}d axis=%{public}d mouse=%{public}d",
          surface_result, axis_events, mouse_events);
  OH_NativeXComponent_RegisterKeyEventCallback(component, OnKey);
  OH_NativeXComponent_RegisterFocusEventCallback(component, OnFocus);
  OH_NativeXComponent_RegisterBlurEventCallback(component, OnBlur);
  ZF_LOGI("XComponent callbacks registered");
  return exports;
}

}  // namespace

static napi_module zapfastModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "zapfastohos",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterZapfastModule() {
  napi_module_register(&zapfastModule);
}
