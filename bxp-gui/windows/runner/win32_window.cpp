#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <fcntl.h>
#include <io.h>

#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <mutex>
#include <string>
#include <thread>

#include "resource.h"

namespace {

// Diagnostic native-side log. Activated by `BXP_DIAGNOSTIC=1` env var
// or marker file `%APPDATA%\bxp-gui\.bxp-diagnostic`. Writes one
// timestamped line per Win32 message of interest to
// `%APPDATA%\bxp-gui\diagnostic-native-YYYYMMDD-HHMMSS.log`.
//
// Also captures the Flutter engine + ANGLE + EGL stderr stream into a
// sibling `diagnostic-engine-YYYYMMDD-HHMMSS.log` — that's where the
// `D3D11 device was removed` → `EGL Context Lost` cascade lives, the
// load-bearing signal for freeze diagnosis. Capture is via Win32
// pipe + `SetStdHandle(STD_ERROR_HANDLE)` + best-effort CRT `stderr`
// rebind, NOT `freopen_s` — the latter breaks the engine boot in
// `/SUBSYSTEM:WINDOWS` release builds where CRT `stderr` starts with
// an invalid handle. A detached reader thread copies pipe bytes to
// the log file with `FILE_FLAG_WRITE_THROUGH` so a hard kill loses
// at most one buffer's worth of writes.
//
// All capture is gated on the activator check — nothing is opened or
// hooked when neither env var nor marker is set, so a default build
// is byte-identical to a non-diagnostic build at runtime.
static std::FILE* g_diag_log = nullptr;
static std::once_flag g_diag_init_once;
static std::mutex g_diag_mutex;

// Pipe + thread for the engine stderr capture. Held in static storage
// only so we don't leak a file handle if `DiagInit` is somehow called
// twice (shouldn't happen — `std::call_once` guards it, but defensive).
static HANDLE g_diag_engine_log = INVALID_HANDLE_VALUE;
static HANDLE g_diag_engine_pipe_r = INVALID_HANDLE_VALUE;

static void DiagInit() {
  // Resolve %APPDATA%\bxp-gui — same path the Dart side uses.
  char appdata[MAX_PATH];
  size_t adlen = 0;
  if (getenv_s(&adlen, appdata, sizeof(appdata), "APPDATA") != 0) return;
  if (adlen == 0) return;

  std::string dir = std::string(appdata) + "\\bxp-gui";

  // Activation: env var BXP_DIAGNOSTIC=1 OR marker file
  // `<dir>\.bxp-diagnostic` exists. The marker is what the Dart-side
  // SettingsInspector toggle writes, so the two activation paths must
  // agree exactly — otherwise the user toggles the switch and gets
  // only the NDJSON, missing the native + engine logs that need to
  // hook in this early.
  bool activated = false;
  char buf[8];
  size_t needed = 0;
  if (getenv_s(&needed, buf, sizeof(buf), "BXP_DIAGNOSTIC") == 0 &&
      needed != 0 && std::strncmp(buf, "1", 1) == 0) {
    activated = true;
  }
  if (!activated) {
    std::string marker = dir + "\\.bxp-diagnostic";
    DWORD attrs = GetFileAttributesA(marker.c_str());
    if (attrs != INVALID_FILE_ATTRIBUTES &&
        !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
      activated = true;
    }
  }
  if (!activated) return;

  CreateDirectoryA(dir.c_str(), nullptr);  // ignore EXISTS

  std::time_t now = std::time(nullptr);
  std::tm tm{};
  localtime_s(&tm, &now);
  char ts[32];
  std::snprintf(ts, sizeof(ts), "%04d%02d%02d-%02d%02d%02d",
                tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                tm.tm_hour, tm.tm_min, tm.tm_sec);

  std::string path = dir + "\\diagnostic-native-" + ts + ".log";
  std::FILE* f = nullptr;
  if (fopen_s(&f, path.c_str(), "ab") == 0 && f != nullptr) {
    g_diag_log = f;
    std::fprintf(g_diag_log, "[native] log opened: %s\n", path.c_str());
    std::fflush(g_diag_log);
  }

  // Engine / ANGLE / EGL stderr capture.
  //
  // The freeze cascade we care about lives entirely on stderr:
  //   ERR: SwapChain11.cpp:951: Present failed: D3D11 device was removed,
  //       HRESULT: 0x887A0007
  //   [ERROR] EGL Error: Context Lost (12302) in surface.cc:61
  //   [ERROR] Could not make the context current to acquire the frame.
  //   ← repeats every frame, forever
  //
  // In a `/SUBSYSTEM:WINDOWS` release binary launched without an attached
  // console, `stderr` writes vanish — `INVALID_HANDLE_VALUE` swallows them.
  // We need to redirect both the Win32 STD_ERROR_HANDLE *and* the CRT
  // `stderr` FILE* to the same destination so:
  //   - direct `WriteFile(GetStdHandle(STD_ERROR_HANDLE), ...)` calls
  //     (used by ANGLE / D3D11 layer) land in the log,
  //   - `fprintf(stderr, ...)` / `std::cerr` calls (used by Flutter
  //     engine's logging) also land in the log.
  //
  // Implementation: an anonymous pipe whose write end is plumbed to both
  // entrypoints. A background thread drains the read end into the log
  // file. We do NOT use `freopen_s(stderr, ...)` — in `/SUBSYSTEM:WINDOWS`
  // builds where CRT `stderr` starts with no valid OS handle, that call
  // can leave the CRT in a half-initialised state and crash the engine
  // boot path. The pipe + `SetStdHandle` + `_dup2` route is robust to
  // any starting state of the CRT streams: even if the CRT-side rebind
  // fails, the Win32-side capture still works on its own.
  std::string engine_path = dir + "\\diagnostic-engine-" + ts + ".log";

  // Open the destination first so a creation failure doesn't leave us
  // with a dangling pipe nobody is reading from. WRITE_THROUGH so each
  // `WriteFile` is committed to disk before returning — survives a
  // hard kill / power loss with at most one in-flight buffer lost.
  HANDLE log = CreateFileA(
      engine_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
      CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (log == INVALID_HANDLE_VALUE) return;

  // Pipe with a 64 KB internal buffer — big enough to absorb a typical
  // engine log burst without making the writer block on the reader.
  // SECURITY_ATTRIBUTES with bInheritHandle = TRUE so any child process
  // we ever spawn inherits the same stderr (we don't currently spawn
  // any, but it costs nothing and matches `STARTUPINFO.hStdError`
  // expectations if we ever do).
  HANDLE r = INVALID_HANDLE_VALUE;
  HANDLE w = INVALID_HANDLE_VALUE;
  SECURITY_ATTRIBUTES sa = {sizeof(sa), nullptr, TRUE};
  if (!CreatePipe(&r, &w, &sa, 64 * 1024)) {
    CloseHandle(log);
    return;
  }
  g_diag_engine_log = log;
  g_diag_engine_pipe_r = r;

  // Replace the Win32 standard error handle. Anything calling
  // `GetStdHandle(STD_ERROR_HANDLE)` (ANGLE's `WriteFile` path) now
  // hits our pipe write end. We deliberately keep `w` open for the
  // process lifetime — closing it would EOF the pipe and the reader
  // thread would exit even though the engine is still running.
  SetStdHandle(STD_ERROR_HANDLE, w);

  // Best-effort: rebind the CRT `stderr` file descriptor onto a
  // duplicate of the same pipe write end. After this, `fprintf(stderr,
  // ...)` / `std::cerr <<` flow through the pipe too. We duplicate
  // because `_open_osfhandle` takes ownership of the OS handle it
  // wraps, and we already gave the original `w` to `SetStdHandle`.
  // If anything in this chain fails (no valid stderr fd, fd table
  // exhausted, …) we silently fall through — the Win32 capture
  // already covers the most important path.
  HANDLE w_dup = INVALID_HANDLE_VALUE;
  if (DuplicateHandle(GetCurrentProcess(), w, GetCurrentProcess(),
                      &w_dup, 0, TRUE, DUPLICATE_SAME_ACCESS)) {
    int fd = _open_osfhandle(reinterpret_cast<intptr_t>(w_dup),
                             _O_WRONLY | _O_BINARY);
    if (fd >= 0) {
      const int stderr_fd = _fileno(stderr);
      if (stderr_fd >= 0) {
        // _dup2 dups `fd` over `stderr_fd`. The original `stderr` fd
        // (whatever it pointed at before, possibly invalid) is closed.
        _dup2(fd, stderr_fd);
      }
      // Close our side regardless — _dup2 made stderr_fd a copy.
      _close(fd);
      // Unbuffered so writes propagate to the pipe immediately. The
      // pipe / reader thread / file handle do their own buffering.
      std::setvbuf(stderr, nullptr, _IONBF, 0);
    } else {
      CloseHandle(w_dup);
    }
  }

  // Header line so the file is non-empty even if the engine never
  // logs anything — confirms capture wiring is alive. Direct WriteFile
  // (not stderr) so we don't depend on the CRT rebind succeeding.
  {
    const std::string hdr =
        std::string("[engine] stderr captured to ") + engine_path + "\n";
    DWORD wn = 0;
    WriteFile(log, hdr.data(), static_cast<DWORD>(hdr.size()), &wn, nullptr);
  }

  // Reader thread: ReadFile(pipe) → WriteFile(log). Pure byte copy,
  // no parsing, so this thread cannot crash on malformed input. Lives
  // for the process lifetime — when the process exits, all pipe write
  // ends are closed by the kernel, ReadFile returns 0 / fails, the
  // loop exits and the thread terminates. Detached because we have no
  // shutdown handshake (and don't need one — there's nothing for the
  // main thread to wait on).
  //
  // `std::thread` constructor can throw `std::system_error` on resource
  // exhaustion. Catching here is critical — `DiagInit` runs from the
  // WM_NCCREATE Win32 handler and an uncaught exception there would
  // corrupt window creation and prevent the engine from starting. If
  // we can't spawn a reader, the pipe still has stderr pointed at it;
  // we must redirect stderr at the log file directly so the engine
  // doesn't block on a pipe with no drainer once the 64 KB buffer
  // fills. Falling back to the file is safe — Win32 doesn't care
  // whether the handle is a pipe or a file.
  try {
    std::thread reader([r, log]() {
      char buf[4096];
      DWORD n = 0;
      while (ReadFile(r, buf, sizeof(buf), &n, nullptr)) {
        if (n == 0) break;  // EOF
        DWORD wn = 0;
        WriteFile(log, buf, n, &wn, nullptr);
      }
    });
    reader.detach();
  } catch (...) {
    // Bypass the pipe — point stderr straight at the file. Closing
    // the pipe handles AFTER reassigning stderr keeps the engine's
    // writes flowing.
    SetStdHandle(STD_ERROR_HANDLE, log);
    CloseHandle(r);
    g_diag_engine_pipe_r = INVALID_HANDLE_VALUE;
    const char err[] = "[engine] reader thread failed; "
                       "stderr piped directly to log\n";
    DWORD wn = 0;
    WriteFile(log, err, sizeof(err) - 1, &wn, nullptr);
  }
}

static void DiagLog(const char* fmt, ...) {
  std::call_once(g_diag_init_once, DiagInit);
  if (g_diag_log == nullptr) return;
  std::lock_guard<std::mutex> lock(g_diag_mutex);
  // Sub-second precision via GetSystemTimeAsFileTime → millis.
  SYSTEMTIME st;
  GetLocalTime(&st);
  std::fprintf(g_diag_log, "[%02d:%02d:%02d.%03d] ",
               st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
  std::va_list ap;
  va_start(ap, fmt);
  std::vfprintf(g_diag_log, fmt, ap);
  va_end(ap);
  std::fputc('\n', g_diag_log);
  std::fflush(g_diag_log);
}

static const char* WmSizeKind(WPARAM wp) {
  switch (wp) {
    case SIZE_RESTORED: return "RESTORED";
    case SIZE_MINIMIZED: return "MINIMIZED";
    case SIZE_MAXIMIZED: return "MAXIMIZED";
    case SIZE_MAXSHOW: return "MAXSHOW";
    case SIZE_MAXHIDE: return "MAXHIDE";
    default: return "?";
  }
}

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // Treat `size` as the desired CLIENT (inner) area in logical pixels —
  // that is the rectangle Flutter renders into, and the dimension our
  // UI layout was tuned against (1280×800 logical, matching the Linux
  // runner). The default-template `CreateWindow(..., Scale(size.width),
  // Scale(size.height))` passed those numbers as the OUTER window size,
  // so on Windows the title bar + frame ate ~30 logical pixels off the
  // height — Flutter ended up with ~770 logical px and the
  // `maxSafeZoom` post-frame autoclamp (kLogicalMinHeight=768) fired
  // immediately, persisting `0.9908…` to prefs even though the user
  // had not touched the zoom. Using `AdjustWindowRectExForDpi` to
  // back-compute the outer rect needed for the requested inner area
  // makes the Flutter canvas match Linux exactly: 1280×800 logical, no
  // autoclamp, no FP residue in prefs.
  RECT inner = {0, 0, Scale(size.width, scale_factor),
                Scale(size.height, scale_factor)};
  AdjustWindowRectExForDpi(&inner, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
  const int outer_w = inner.right - inner.left;
  const int outer_h = inner.bottom - inner.top;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      outer_w, outer_h,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    DiagLog("WM_NCCREATE hwnd=%p w=%d h=%d", window, window_struct->cx,
            window_struct->cy);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      DiagLog("WM_DESTROY hwnd=%p", hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;
      DiagLog("WM_DPICHANGED dpi=%u w=%ld h=%ld", LOWORD(wparam), newWidth,
              newHeight);

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      DiagLog("WM_SIZE %s w=%ld h=%ld child=%p",
              WmSizeKind(wparam),
              rect.right - rect.left, rect.bottom - rect.top,
              child_content_);
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      DiagLog("WM_ACTIVATE wparam=%u (%s)", LOWORD(wparam),
              LOWORD(wparam) == WA_INACTIVE
                  ? "INACTIVE"
                  : (LOWORD(wparam) == WA_ACTIVE ? "ACTIVE" : "CLICKACTIVE"));
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_WINDOWPOSCHANGED: {
      auto* wp = reinterpret_cast<WINDOWPOS*>(lparam);
      DiagLog("WM_WINDOWPOSCHANGED x=%d y=%d w=%d h=%d flags=0x%x",
              wp->x, wp->y, wp->cx, wp->cy, wp->flags);
      break;  // fall through to DefWindowProc
    }

    case WM_SHOWWINDOW:
      DiagLog("WM_SHOWWINDOW shown=%d reason=%lld",
              static_cast<int>(wparam), static_cast<long long>(lparam));
      break;

    case WM_DISPLAYCHANGE:
      DiagLog("WM_DISPLAYCHANGE bpp=%u w=%d h=%d",
              static_cast<unsigned>(wparam),
              LOWORD(lparam), HIWORD(lparam));
      break;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_GETMINMAXINFO: {
      // Enforce a minimum window size of 1024x768. Mirrors the GTK
      // GdkGeometry hint in linux/runner/my_application.cc and the
      // contentMinSize set in macos/Runner/MainFlutterWindow.swift;
      // every panel split in the UI assumes at least this much room.
      // Values are in physical pixels; scale by current DPI so the
      // minimum stays consistent across high-DPI displays.
      auto* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      const double scale = dpi / 96.0;
      mmi->ptMinTrackSize.x = static_cast<LONG>(1024 * scale);
      mmi->ptMinTrackSize.y = static_cast<LONG>(768 * scale);
      return 0;
    }
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
