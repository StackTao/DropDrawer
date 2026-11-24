#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <ole2.h>

#include <algorithm>
#include <filesystem>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT ole = ::OleInitialize(nullptr);
  if (FAILED(ole)) return EXIT_FAILURE;

  const std::filesystem::path exe(GetExecutablePath());
  if (exe.empty()) {
    ::OleUninitialize();
    return EXIT_FAILURE;
  }
  flutter::DartProject project((exe.parent_path() / L"data").wstring());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const bool background =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--background") != command_line_arguments.end();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, background);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"DropDrawer", origin, size)) {
    ::OleUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0) > 0) {
    if (window.HandleKeyboardMessage(msg)) continue;
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
