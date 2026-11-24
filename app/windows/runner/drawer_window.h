#ifndef RUNNER_DRAWER_WINDOW_H_
#define RUNNER_DRAWER_WINDOW_H_

#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>

inline constexpr UINT kActivateDrawerMessage = WM_APP + 4;
inline constexpr wchar_t kDropDrawerTitle[] = L"DropDrawer";

class DrawerWindow {
 public:
  DrawerWindow(HWND window, flutter::BinaryMessenger* messenger, bool background);
  ~DrawerWindow();

  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);
  bool HandleKeyboard(const MSG& message);

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;
  enum class Mode { kCollapsed, kDragGuide, kExpanded };

  void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<Result> result);
  flutter::EncodableMap State() const;
  void NotifyState();
  void SetEdgeMode(bool enabled);
  void SetMode(Mode mode, bool activate = false);
  void SetDockLeft(bool left);
  void PlaceDrawer();
  void MoveHandle(bool save);
  void Toggle();
  void Hide();
  void Activate();
  void OnTimer();
  void UpdateTaskbar();
  bool AddTrayIcon();
  void ShowTrayMenu();
  std::string ShowMoreMenu(double x, double y, const std::string& username);
  bool RegisterShortcut();
  bool SetShortcut(UINT key, UINT modifiers);
  std::string ShortcutLabel() const;
  void FinishRecording(bool recorded, bool ok);

  HWND window_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  std::unique_ptr<Result> recording_;
  RECT regular_bounds_{};
  LONG_PTR regular_style_;
  LONG_PTR regular_ex_style_;
  HWND previous_window_ = nullptr;
  ULONGLONG drag_guide_timeout_ = 0;
  ULONGLONG drag_guide_open_at_ = 0;
  UINT taskbar_created_;
  Mode mode_ = Mode::kExpanded;
  bool background_;
  bool edge_ = false;
  bool pinned_ = false;
  bool opened_by_drag_ = false;
  bool modal_open_ = false;
  bool main_drawer_active_ = false;
  bool dock_left_ = false;
  bool show_taskbar_ = false;
  bool tray_added_ = false;
  bool shortcut_enabled_ = true;
  bool shortcut_registered_ = false;
  UINT shortcut_key_ = 'D';
  UINT shortcut_modifiers_ = MOD_ALT | MOD_SHIFT;
  DWORD anchor_ = 500;
};

#endif  // RUNNER_DRAWER_WINDOW_H_
