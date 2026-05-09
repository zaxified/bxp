#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

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
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // 1280x800 matches Linux/macOS runners and the kLogicalMinHeight=768
  // baked into zoom_limits.dart's maxSafeZoom math. The previous 1280x720
  // default forced zoom to clamp to 0.9375 (= 720/768) on first paint,
  // pinned the SizedBox bigger than Stack's biggest constraint, and made
  // the Transform.scale layer paint an ever-larger logical region as the
  // window grew (eg. 2048x1152 logical at maximised 1920x1080 viewport)
  // — the wheel-scroll lag in maximised mode came from that.
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"BXP", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
