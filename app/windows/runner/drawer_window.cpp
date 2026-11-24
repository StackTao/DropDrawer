#include "drawer_window.h"

#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <cwchar>

#include "drawer_files.h"
#include "resource.h"
#include "utils.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

constexpr wchar_t kPreferences[] = L"Software\\DropDrawer";
constexpr wchar_t kStartup[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kStartupValue[] = L"DropDrawer";
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kQuitMessage = WM_APP + 2;
constexpr UINT kOutsideClickMessage = WM_APP + 3;
constexpr UINT_PTR kDrawerTimer = 1;
constexpr int kShortcutId = 1;

template <class T>
T Arg(const Map* args, const char* key, T fallback = {}) {
  if (!args) return fallback;
  const auto it = args->find(Value(key));
  if (it == args->end()) return fallback;
  const auto* value = std::get_if<T>(&it->second);
  return value ? *value : fallback;
}

DWORD Preference(const wchar_t* name, DWORD fallback) {
  DWORD result = fallback;
  DWORD size = sizeof(result);
  return RegGetValueW(HKEY_CURRENT_USER, kPreferences, name, RRF_RT_REG_DWORD,
                      nullptr, &result, &size) == ERROR_SUCCESS
             ? result
             : fallback;
}

void SavePreference(const wchar_t* name, DWORD value) {
  RegSetKeyValueW(HKEY_CURRENT_USER, kPreferences, name, REG_DWORD, &value,
                   sizeof(value));
}

bool StartsAtLogin() {
  DWORD size = 0;
  return RegGetValueW(HKEY_CURRENT_USER, kStartup, kStartupValue, RRF_RT_REG_SZ,
                      nullptr, nullptr, &size) == ERROR_SUCCESS;
}

bool SetStartsAtLogin(bool enabled) {
  if (!enabled) {
    const auto status = RegDeleteKeyValueW(HKEY_CURRENT_USER, kStartup, kStartupValue);
    return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
  }
  const auto exe = GetExecutablePath();
  if (exe.empty()) return false;
  const std::wstring command = L"\"" + exe + L"\" --background";
  return RegSetKeyValueW(HKEY_CURRENT_USER, kStartup, kStartupValue, REG_SZ,
                         command.c_str(),
                         static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t))) ==
         ERROR_SUCCESS;
}

RECT WorkArea(HMONITOR monitor) {
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  GetMonitorInfoW(monitor, &info);
  return info.rcWork;
}

UINT KeyboardModifiers() {
  UINT modifiers = 0;
  if (GetKeyState(VK_CONTROL) < 0) modifiers |= MOD_CONTROL;
  if (GetKeyState(VK_MENU) < 0) modifiers |= MOD_ALT;
  if (GetKeyState(VK_SHIFT) < 0) modifiers |= MOD_SHIFT;
  if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) modifiers |= MOD_WIN;
  return modifiers;
}

UINT PresetModifiers(const List& names) {
  UINT modifiers = 0;
  for (const auto& value : names) {
    const auto* name = std::get_if<std::string>(&value);
    if (!name) continue;
    if (*name == "control") modifiers |= MOD_CONTROL;
    if (*name == "option") modifiers |= MOD_ALT;
    if (*name == "shift") modifiers |= MOD_SHIFT;
    if (*name == "command") modifiers |= MOD_WIN;
  }
  return modifiers;
}

bool IsOleDragActive() {
  GUITHREADINFO info{};
  info.cbSize = sizeof(info);
  if (!GetGUIThreadInfo(0, &info) || !info.hwndCapture) return false;

  // OLE owns mouse capture through its hidden clipboard window while dragging.
  wchar_t class_name[32]{};
  return GetClassNameW(info.hwndCapture, class_name,
                       static_cast<int>(ARRAYSIZE(class_name))) &&
         std::wcscmp(class_name, L"CLIPBRDWNDCLASS") == 0;
}

bool IsModifier(UINT key) {
  return key == VK_CONTROL || key == VK_SHIFT || key == VK_MENU ||
         key == VK_LWIN || key == VK_RWIN;
}
}  // namespace

DrawerWindow::DrawerWindow(HWND window, flutter::BinaryMessenger* messenger,
                           bool background)
    : window_(window),
      channel_(messenger, "com.dropdrawer/drawer_window",
               &flutter::StandardMethodCodec::GetInstance()),
      regular_style_(GetWindowLongPtrW(window, GWL_STYLE)),
      regular_ex_style_(GetWindowLongPtrW(window, GWL_EXSTYLE)),
      taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")),
      background_(background),
      dock_left_(Preference(L"DockLeft", 0) != 0),
      show_taskbar_(Preference(L"ShowTaskbar", 0) != 0),
      shortcut_enabled_(Preference(L"ShortcutEnabled", 1) != 0),
      shortcut_key_(Preference(L"ShortcutKey", 'D')),
      shortcut_modifiers_(Preference(L"ShortcutModifiers", MOD_ALT | MOD_SHIFT)),
      anchor_(std::min(Preference(L"DrawerAnchor", 500), 1000UL)) {
  channel_.SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleCall(call, std::move(result)); });
  RegisterShortcut();
  tray_added_ = AddTrayIcon();
}

DrawerWindow::~DrawerWindow() {
  FinishRecording(false, false);
  channel_.SetMethodCallHandler(nullptr);
  KillTimer(window_, kDrawerTimer);
  UnregisterHotKey(window_, kShortcutId);
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window_;
  icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &icon);
}

Map DrawerWindow::State() const {
  return {
      {Value("edgeMode"), Value(edge_)},
      {Value("expanded"), Value(mode_ == Mode::kExpanded)},
      {Value("mode"), Value(mode_ == Mode::kExpanded ? "expanded"
                            : mode_ == Mode::kDragGuide ? "drag_pill" : "collapsed")},
      {Value("pinned"), Value(pinned_)},
      {Value("dockSide"), Value(dock_left_ ? "left" : "right")},
      {Value("hotkeyEnabled"), Value(shortcut_enabled_)},
      {Value("hotkeyLabel"), Value(ShortcutLabel())},
      {Value("hasGlobalHotkeyPermission"), Value(shortcut_registered_)},
      {Value("hotkeyEngine"), Value(shortcut_registered_ ? "register_hotkey" : "local_only")},
      {Value("launchAtLogin"), Value(StartsAtLogin())},
      {Value("showDockIcon"), Value(show_taskbar_)},
  };
}

void DrawerWindow::NotifyState() {
  channel_.InvokeMethod("onDrawerStateChanged", std::make_unique<Value>(State()));
}

void DrawerWindow::HandleCall(const flutter::MethodCall<Value>& call,
                              std::unique_ptr<Result> result) {
  const auto& method = call.method_name();
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (method == "setEdgeDrawerMode") {
    SetEdgeMode(Arg<bool>(args, "enabled"));
  } else if (method == "expandDrawer") {
    SetMode(Mode::kExpanded, true);
  } else if (method == "collapseDrawer") {
    SetMode(Mode::kCollapsed);
  } else if (method == "showDragGuide") {
    if (edge_ && mode_ == Mode::kCollapsed) SetMode(Mode::kDragGuide);
  } else if (method == "moveDrawerHandle") {
    MoveHandle(Arg<bool>(args, "save"));
  } else if (method == "setPinned") {
    pinned_ = Arg<bool>(args, "pinned");
    NotifyState();
  } else if (method == "setDockSide") {
    SetDockLeft(Arg<std::string>(args, "side") == "left");
  } else if (method == "setModalOpen") {
    modal_open_ = Arg<bool>(args, "open");
  } else if (method == "setMainDrawerActive") {
    main_drawer_active_ = Arg<bool>(args, "active");
  } else if (method == "getSystemSettings") {
    return result->Success(Value(State()));
  } else if (method == "setShowDockIcon") {
    show_taskbar_ = Arg<bool>(args, "shown");
    SavePreference(L"ShowTaskbar", show_taskbar_);
    UpdateTaskbar();
    NotifyState();
  } else if (method == "quitApp") {
    PostMessageW(window_, kQuitMessage, 0, 0);
  } else if (method == "setHotkeyEnabled") {
    shortcut_enabled_ = Arg<bool>(args, "enabled");
    SavePreference(L"ShortcutEnabled", shortcut_enabled_);
    RegisterShortcut();
    NotifyState();
  } else if (method == "setHotkeyPreset") {
    const auto key = Arg<int32_t>(args, "keyCode");
    const bool ok = SetShortcut(static_cast<UINT>(key),
                                PresetModifiers(Arg<List>(args, "modifiers")));
    return result->Success(Value(Map{{Value("ok"), Value(ok)},
                                     {Value("label"), Value(ShortcutLabel())}}));
  } else if (method == "startHotkeyRecording") {
    FinishRecording(false, false);
    UnregisterHotKey(window_, kShortcutId);
    shortcut_registered_ = false;
    recording_ = std::move(result);
    return;
  } else if (method == "cancelHotkeyRecording") {
    FinishRecording(false, false);
  } else if (method == "setLaunchAtLogin") {
    const bool ok = SetStartsAtLogin(Arg<bool>(args, "enabled"));
    NotifyState();
    return result->Success(Value(ok));
  } else if (method == "readClipboard") {
    return result->Success(Value(drawer_files::ReadClipboard(
        window_, Arg<std::string>(args, "imagePath"))));
  } else if (method == "copyFileToClipboard") {
    return result->Success(Value(drawer_files::CopyFiles(
        window_, {Value(Arg<std::string>(args, "path"))})));
  } else if (method == "copyFilesToClipboard") {
    return result->Success(Value(drawer_files::CopyFiles(window_, Arg<List>(args, "paths"))));
  } else if (method == "revealInFinder") {
    return result->Success(Value(drawer_files::RevealFile(Arg<std::string>(args, "path"))));
  } else if (method == "openDirectory") {
    return result->Success(Value(drawer_files::OpenDirectory(window_, Arg<std::string>(args, "path"))));
  } else if (method == "openExternalUrl") {
    return result->Success(Value(drawer_files::OpenWebUrl(window_, Arg<std::string>(args, "url"))));
  } else {
    return result->NotImplemented();
  }
  result->Success();
}

void DrawerWindow::SetEdgeMode(bool enabled) {
  if (edge_ == enabled) {
    NotifyState();
    return;
  }
  if (enabled) {
    if (IsZoomed(window_) || IsIconic(window_)) ShowWindow(window_, SW_RESTORE);
    GetWindowRect(window_, &regular_bounds_);
  }
  const bool start_collapsed = background_ && enabled;
  if (enabled) background_ = false;
  edge_ = enabled;
  pinned_ = false;
  guide_from_ole_drag_ = false;
  opened_by_drag_ = false;
  mode_ = start_collapsed ? Mode::kCollapsed : Mode::kExpanded;
  if (edge_) {
    const LONG_PTR visible = GetWindowLongPtrW(window_, GWL_STYLE) & WS_VISIBLE;
    SetWindowLongPtrW(window_, GWL_STYLE, WS_POPUP | WS_CLIPCHILDREN | visible);
    PlaceDrawer();
    SetTimer(window_, kDrawerTimer, 80, nullptr);
    if (start_collapsed) ShowWindow(window_, SW_SHOWNOACTIVATE);
  } else {
    KillTimer(window_, kDrawerTimer);
    SetWindowRgn(window_, nullptr, TRUE);
    const LONG_PTR visible = GetWindowLongPtrW(window_, GWL_STYLE) & WS_VISIBLE;
    SetWindowLongPtrW(window_, GWL_STYLE, (regular_style_ & ~WS_VISIBLE) | visible);
    LONG_PTR ex_style =
        regular_ex_style_ & ~(WS_EX_APPWINDOW | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
    ex_style |= show_taskbar_ || !tray_added_ ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW;
    SetWindowLongPtrW(window_, GWL_EXSTYLE, ex_style);
    SetWindowPos(window_, HWND_NOTOPMOST, regular_bounds_.left, regular_bounds_.top,
                 regular_bounds_.right - regular_bounds_.left,
                 regular_bounds_.bottom - regular_bounds_.top,
                 SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }
  NotifyState();
}

void DrawerWindow::SetMode(Mode mode, bool activate) {
  if (!edge_) {
    if (activate) Activate();
    return;
  }
  if (mode_ != mode) {
    mode_ = mode;
    drag_guide_timeout_ = 0;
    if (mode != Mode::kDragGuide) guide_from_ole_drag_ = false;
    if (mode != Mode::kExpanded) {
      pinned_ = false;
      opened_by_drag_ = false;
    }
    if (mode == Mode::kDragGuide) drag_guide_open_at_ = GetTickCount64() + 180;
    PlaceDrawer();
    NotifyState();
  }
  if (activate) {
    Activate();
  } else if (mode == Mode::kCollapsed && GetForegroundWindow() == window_ &&
             IsWindow(previous_window_)) {
    SetForegroundWindow(previous_window_);
  }
}

void DrawerWindow::SetDockLeft(bool left) {
  dock_left_ = left;
  SavePreference(L"DockLeft", dock_left_);
  if (edge_) PlaceDrawer();
  NotifyState();
}

void DrawerWindow::PlaceDrawer() {
  const RECT area = WorkArea(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST));
  const auto dpi = static_cast<int>(GetDpiForWindow(window_));
  const int logical_width = mode_ == Mode::kExpanded ? 410 : mode_ == Mode::kDragGuide ? 200 : 14;
  const int logical_height = mode_ == Mode::kExpanded ? 645 : mode_ == Mode::kDragGuide ? 62 : 64;
  const LONG width = std::min<LONG>(MulDiv(logical_width, dpi, 96), area.right - area.left);
  const LONG height = std::min<LONG>(MulDiv(logical_height, dpi, 96), area.bottom - area.top);
  const LONG center = area.top + MulDiv(area.bottom - area.top, static_cast<int>(anchor_), 1000);
  const LONG top = std::clamp(center - height / 2, area.top, area.bottom - height);
  const LONG left = dock_left_ ? area.left : area.right - width;

  LONG_PTR style = regular_ex_style_ & ~(WS_EX_APPWINDOW | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
  style |= show_taskbar_ || !tray_added_ ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW;
  if (mode_ != Mode::kExpanded) style |= WS_EX_NOACTIVATE;
  SetWindowLongPtrW(window_, GWL_EXSTYLE, style);
  SetWindowPos(window_, HWND_TOPMOST, left, top, width, height,
               SWP_NOACTIVATE | SWP_FRAMECHANGED);
  // CreateRoundRectRgn takes ellipse width/height (2 * corner radius).
  const int diameter = MulDiv(
      mode_ == Mode::kExpanded ? 32 : mode_ == Mode::kDragGuide ? 26 : 12,
      dpi, 96);
  HRGN region = CreateRoundRectRgn(0, 0, width + 1, height + 1, diameter, diameter);
  if (region && !SetWindowRgn(window_, region, TRUE)) DeleteObject(region);
}

void DrawerWindow::MoveHandle(bool save) {
  if (!edge_ || mode_ != Mode::kCollapsed) return;
  POINT cursor{};
  if (!GetCursorPos(&cursor)) return;
  const HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  const RECT area = WorkArea(monitor);
  if (area.bottom <= area.top || area.right <= area.left) return;
  const int ratio = MulDiv(cursor.y - area.top, 1000, area.bottom - area.top);
  anchor_ = static_cast<DWORD>(std::clamp(ratio, 0, 1000));

  const LONG span = area.right - area.left;
  bool dock_changed = false;
  if (!dock_left_ && cursor.x < area.left + span / 4) {
    dock_left_ = true;
    dock_changed = true;
  } else if (dock_left_ && cursor.x > area.right - span / 4) {
    dock_left_ = false;
    dock_changed = true;
  }

  // Move to the cursor's monitor if dragged across displays.
  if (MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST) != monitor) {
    SetWindowPos(window_, HWND_TOPMOST,
                 dock_left_ ? area.left : area.right - 14, area.top, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE);
  }
  PlaceDrawer();
  if (dock_changed) {
    SavePreference(L"DockLeft", dock_left_);
    NotifyState();
  }
  if (save) {
    SavePreference(L"DrawerAnchor", anchor_);
    SavePreference(L"DockLeft", dock_left_);
  }
}

void DrawerWindow::Activate() {
  background_ = false;
  HWND foreground = GetForegroundWindow();
  if (foreground && foreground != window_) previous_window_ = foreground;
  if (IsIconic(window_)) ShowWindow(window_, SW_RESTORE);
  if (!IsWindowVisible(window_)) ShowWindow(window_, SW_SHOW);
  SetForegroundWindow(window_);
}

void DrawerWindow::Hide() {
  if (edge_) SetMode(Mode::kCollapsed);
  else if (tray_added_) ShowWindow(window_, SW_HIDE);
  else ShowWindow(window_, SW_MINIMIZE);
}

void DrawerWindow::Toggle() {
  if (edge_) {
    if (mode_ == Mode::kExpanded) SetMode(Mode::kCollapsed);
    else SetMode(Mode::kExpanded, true);
  } else if (GetForegroundWindow() == window_ && !IsIconic(window_)) {
    Hide();
  } else {
    Activate();
  }
}

void DrawerWindow::OnTimer() {
  if (modal_open_) return;
  POINT cursor{};
  RECT bounds{};
  if (!GetCursorPos(&cursor) || !GetWindowRect(window_, &bounds)) return;

  const bool mouse_down =
      GetAsyncKeyState(VK_LBUTTON) < 0 || GetAsyncKeyState(VK_RBUTTON) < 0;
  if (mode_ == Mode::kCollapsed) {
    if (mouse_down && IsOleDragActive()) {
      guide_from_ole_drag_ = true;
      SetMode(Mode::kDragGuide);
    }
    return;
  }
  if (mode_ == Mode::kDragGuide) {
    InflateRect(&bounds, 24, 24);
    const bool near_guide = PtInRect(&bounds, cursor) != FALSE;
    const bool dragging =
        mouse_down && (guide_from_ole_drag_ ? IsOleDragActive() : near_guide);
    const ULONGLONG now = GetTickCount64();
    if (dragging) {
      drag_guide_timeout_ = 0;
      if (near_guide && now >= drag_guide_open_at_) {
        opened_by_drag_ = true;
        SetMode(Mode::kExpanded);
      }
    } else if (!drag_guide_timeout_) {
      drag_guide_timeout_ = now + 450;
    } else if (now >= drag_guide_timeout_) {
      SetMode(Mode::kCollapsed);
    }
  } else if (opened_by_drag_) {
    if (mouse_down) return;
    opened_by_drag_ = false;
    if (!pinned_ && !PtInRect(&bounds, cursor)) SetMode(Mode::kCollapsed);
  } else if (mode_ == Mode::kExpanded && !pinned_ && mouse_down &&
             !IsOleDragActive() && !PtInRect(&bounds, cursor) &&
             GetForegroundWindow() != window_) {
    SetMode(Mode::kCollapsed);
  }
}

void DrawerWindow::UpdateTaskbar() {
  const bool visible = IsWindowVisible(window_) != FALSE;
  if (visible) ShowWindow(window_, SW_HIDE);
  if (edge_) {
    PlaceDrawer();
  } else {
    LONG_PTR ex_style =
        regular_ex_style_ & ~(WS_EX_APPWINDOW | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
    ex_style |= show_taskbar_ || !tray_added_ ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW;
    SetWindowLongPtrW(window_, GWL_EXSTYLE, ex_style);
    SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
  }
  if (visible) ShowWindow(window_, SW_SHOWNOACTIVATE);
  if (visible && (!edge_ || mode_ == Mode::kExpanded)) Activate();
}

bool DrawerWindow::AddTrayIcon() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window_;
  icon.uID = 1;
  icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"DropDrawer");
  return Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
}

void DrawerWindow::ShowTrayMenu() {
  POINT cursor{};
  if (!GetCursorPos(&cursor)) return;
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, 1, L"展开 / 收起");
  AppendMenuW(menu, MF_STRING, 2, edge_ ? L"常规窗口" : L"边缘抽屉");
  AppendMenuW(menu, MF_STRING, 3, dock_left_ ? L"停靠右侧" : L"停靠左侧");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 4, L"退出应用");
  const bool was_modal = modal_open_;
  modal_open_ = true;
  SetForegroundWindow(window_);
  const BOOL selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                       cursor.x, cursor.y, 0, window_, nullptr);
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  switch (selected) {
    case 1:
      if (edge_) Toggle();
      else if (IsWindowVisible(window_) && !IsIconic(window_)) Hide();
      else Activate();
      break;
    case 2: SetEdgeMode(!edge_); Activate(); break;
    case 3: SetDockLeft(!dock_left_); break;
    case 4: PostMessageW(window_, kQuitMessage, 0, 0); break;
  }
  modal_open_ = was_modal;
}

bool DrawerWindow::RegisterShortcut() {
  if (shortcut_registered_) UnregisterHotKey(window_, kShortcutId);
  shortcut_registered_ = shortcut_enabled_ &&
      RegisterHotKey(window_, kShortcutId, shortcut_modifiers_ | MOD_NOREPEAT,
                     shortcut_key_) != FALSE;
  return shortcut_registered_;
}

bool DrawerWindow::SetShortcut(UINT key, UINT modifiers) {
  if (!key || key > 0xFE || IsModifier(key)) return false;
  const UINT old_key = shortcut_key_;
  const UINT old_modifiers = shortcut_modifiers_;
  shortcut_key_ = key;
  shortcut_modifiers_ = modifiers;
  if (shortcut_enabled_ && !RegisterShortcut()) {
    shortcut_key_ = old_key;
    shortcut_modifiers_ = old_modifiers;
    RegisterShortcut();
    NotifyState();
    return false;
  }
  SavePreference(L"ShortcutKey", shortcut_key_);
  SavePreference(L"ShortcutModifiers", shortcut_modifiers_);
  NotifyState();
  return true;
}

std::string DrawerWindow::ShortcutLabel() const {
  std::string label;
  if (shortcut_modifiers_ & MOD_CONTROL) label += "Ctrl+";
  if (shortcut_modifiers_ & MOD_ALT) label += "Alt+";
  if (shortcut_modifiers_ & MOD_SHIFT) label += "Shift+";
  if (shortcut_modifiers_ & MOD_WIN) label += "Win+";
  if (shortcut_key_ >= VK_F1 && shortcut_key_ <= VK_F24) {
    return label + "F" + std::to_string(shortcut_key_ - VK_F1 + 1);
  }
  if (shortcut_key_ >= 'A' && shortcut_key_ <= 'Z') {
    return label + static_cast<char>(shortcut_key_);
  }
  if (shortcut_key_ >= '0' && shortcut_key_ <= '9') {
    return label + static_cast<char>(shortcut_key_);
  }
  const UINT scan = MapVirtualKeyW(shortcut_key_, MAPVK_VK_TO_VSC_EX);
  wchar_t name[64]{};
  const LONG key_info = static_cast<LONG>(((scan & 0xFF) << 16) |
                                         ((scan & 0xFF00) ? (1 << 24) : 0));
  if (GetKeyNameTextW(key_info, name, static_cast<int>(ARRAYSIZE(name)))) {
    return label + Utf8FromUtf16(name);
  }
  return label + std::to_string(shortcut_key_);
}

void DrawerWindow::FinishRecording(bool recorded, bool ok) {
  if (!recording_) return;
  if (!recorded) RegisterShortcut();
  recording_->Success(Value(Map{{Value("recorded"), Value(recorded)},
                                {Value("ok"), Value(ok)},
                                {Value("label"), Value(ShortcutLabel())}}));
  recording_.reset();
  NotifyState();
}

bool DrawerWindow::HandleKeyboard(const MSG& message) {
  if ((message.message != WM_KEYDOWN && message.message != WM_SYSKEYDOWN) ||
      (message.hwnd != window_ && !IsChild(window_, message.hwnd))) {
    return false;
  }
  const auto key = static_cast<UINT>(message.wParam);
  const UINT modifiers = KeyboardModifiers();
  const bool repeat = (message.lParam & (static_cast<LPARAM>(1) << 30)) != 0;
  if (recording_) {
    if (repeat || IsModifier(key)) return true;
    if (key == VK_ESCAPE) {
      FinishRecording(false, false);
    } else if ((modifiers & (MOD_CONTROL | MOD_ALT | MOD_WIN)) ||
               (key >= VK_F1 && key <= VK_F24)) {
      FinishRecording(true, SetShortcut(key, modifiers));
    }
    return true;
  }
  if (modal_open_) return false;
  if (shortcut_enabled_ && !shortcut_registered_ && key == shortcut_key_ &&
      modifiers == shortcut_modifiers_) {
    if (!repeat) Toggle();
    return true;
  }
  if (edge_ && mode_ == Mode::kExpanded && key == VK_ESCAPE && !modifiers) {
    if (!repeat) SetMode(Mode::kCollapsed);
    return true;
  }
  if (main_drawer_active_ && key == 'V' && modifiers == MOD_CONTROL) {
    if (!repeat) channel_.InvokeMethod("onPasteShortcut", nullptr);
    return true;
  }
  return false;
}

std::optional<LRESULT> DrawerWindow::HandleMessage(UINT message, WPARAM wparam,
                                                   LPARAM lparam) {
  if (message == taskbar_created_ && taskbar_created_) {
    tray_added_ = AddTrayIcon();
    UpdateTaskbar();
    return 0;
  }
  switch (message) {
    case WM_TIMER:
      if (wparam == kDrawerTimer) {
        OnTimer();
        return 0;
      }
      break;
    case WM_HOTKEY:
      if (wparam == kShortcutId && shortcut_registered_ && !modal_open_) {
        Toggle();
        return 0;
      }
      break;
    case WM_CLOSE:
      if (tray_added_) {
        Hide();
        return 0;
      }
      break;
    case WM_QUERYENDSESSION:
      // Allow OS shutdown and installer Restart Manager to close cleanly.
      return TRUE;
    case WM_ENDSESSION:
      if (wparam != FALSE) {
        DestroyWindow(window_);
      }
      return 0;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE && recording_) {
        FinishRecording(false, false);
      }
      if (LOWORD(wparam) == WA_INACTIVE && edge_ &&
          mode_ == Mode::kExpanded && !pinned_ && !opened_by_drag_ && !modal_open_) {
        POINT cursor{};
        RECT bounds{};
        if (GetCursorPos(&cursor) && GetWindowRect(window_, &bounds) &&
            !PtInRect(&bounds, cursor) &&
            (GetAsyncKeyState(VK_LBUTTON) < 0 || GetAsyncKeyState(VK_RBUTTON) < 0)) {
          PostMessageW(window_, kOutsideClickMessage, 0, 0);
        }
      }
      break;
    case kOutsideClickMessage:
      if (!pinned_ && !modal_open_ && GetForegroundWindow() != window_) {
        SetMode(Mode::kCollapsed);
      }
      return 0;
    case WM_DPICHANGED:
      if (edge_) {
        PlaceDrawer();
        return 0;
      }
      break;
    case WM_DISPLAYCHANGE:
      if (edge_) PlaceDrawer();
      break;
    case kActivateDrawerMessage:
      SetMode(Mode::kExpanded, true);
      return 0;
    case kQuitMessage:
      DestroyWindow(window_);
      return 0;
    case kTrayMessage:
      if (lparam == WM_RBUTTONUP) ShowTrayMenu();
      if (lparam == WM_LBUTTONUP) {
        if (edge_) Toggle();
        else Activate();
      }
      return 0;
  }
  return std::nullopt;
}
