#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuOpen = 1001;
constexpr UINT kMenuExit = 1002;

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), len);
  return out;
}

// Copies |src| into a fixed-size WCHAR buffer, truncating safely.
template <size_t N>
void CopyToBuffer(WCHAR (&dst)[N], const std::wstring& src) {
  wcsncpy_s(dst, N, src.c_str(), _TRUNCATE);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterWindowChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  show_window_message_ = ::RegisterWindowMessageW(kShowWindowMessageName);
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Started by autostart ("--minimized"): stay hidden in the tray.
    if (StartMinimized() && tray_added_) {
      ConsumeStartMinimized();
      return;
    }
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

// ------------------------------------------------------------- Dart channel

void FlutterWindow::RegisterWindowChannel() {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "gundil/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const flutter::EncodableValue* args = call.arguments();
        if (call.method_name() == "setTrayEnabled") {
          if (args) {
            if (const bool* enabled = std::get_if<bool>(args)) {
              tray_enabled_ = *enabled;
            }
          }
          result->Success();
        } else if (call.method_name() == "setTooltip") {
          if (args) {
            if (const std::string* text = std::get_if<std::string>(args)) {
              tooltip_ = Utf16FromUtf8(*text);
              UpdateTrayTooltip();
            }
          }
          result->Success();
        } else if (call.method_name() == "show") {
          RestoreFromTray();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

// ---------------------------------------------------------------- tray icon

void FlutterWindow::AddTrayIcon() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = hwnd;
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  if (!tray_icon_.hIcon) {
    tray_icon_.hIcon = ::LoadIconW(nullptr, IDI_APPLICATION);
  }
  CopyToBuffer(tray_icon_.szTip, tooltip_);
  tray_added_ = ::Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
  if (tray_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    ::Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) return;
  ::Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_added_ = false;
  if (tray_icon_.hIcon) {
    ::DestroyIcon(tray_icon_.hIcon);
    tray_icon_.hIcon = nullptr;
  }
}

void FlutterWindow::UpdateTrayTooltip() {
  if (!tray_added_) return;
  tray_icon_.uFlags = NIF_TIP | NIF_SHOWTIP;
  CopyToBuffer(tray_icon_.szTip, tooltip_);
  ::Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
}

void FlutterWindow::ShowBalloon(const std::wstring& title,
                                const std::wstring& text) {
  if (!tray_added_) return;
  tray_icon_.uFlags = NIF_INFO;
  tray_icon_.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
  CopyToBuffer(tray_icon_.szInfoTitle, title);
  CopyToBuffer(tray_icon_.szInfo, text);
  ::Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  HMENU menu = ::CreatePopupMenu();
  if (!menu) return;
  ::AppendMenuW(menu, MF_STRING, kMenuOpen, L"&Open Gundil Intercom");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuExit, L"E&xit");
  ::SetMenuDefaultItem(menu, kMenuOpen, FALSE);

  POINT pt;
  ::GetCursorPos(&pt);
  // Required so the menu closes when the user clicks elsewhere.
  ::SetForegroundWindow(hwnd);
  UINT cmd = ::TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
      pt.x, pt.y, 0, hwnd, nullptr);
  ::PostMessageW(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  if (cmd == kMenuOpen) {
    RestoreFromTray();
  } else if (cmd == kMenuExit) {
    quitting_ = true;
    ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
  }
}

void FlutterWindow::HideToTray() {
  HWND hwnd = GetHandle();
  ::ShowWindow(hwnd, SW_HIDE);
  if (!balloon_shown_) {
    balloon_shown_ = true;
    ShowBalloon(L"Gundil Intercom is still running",
                L"It keeps receiving in the background. Click the tray icon "
                L"to open it, or right-click > Exit to quit.");
  }
}

void FlutterWindow::RestoreFromTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ConsumeStartMinimized();
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
}

// ------------------------------------------------------------------ messages

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Explorer restarted: the tray icon must be added again.
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }
  // Another instance was launched: show this one instead.
  if (show_window_message_ != 0 && message == show_window_message_) {
    RestoreFromTray();
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case kTrayCallbackMessage:
      // NOTIFYICON_VERSION_4: the event is in LOWORD(lparam).
      switch (LOWORD(lparam)) {
        // A left click sends NIN_SELECT (WM_LBUTTONUP too, ignored to avoid
        // handling it twice); a right click ends with WM_CONTEXTMENU.
        case NIN_SELECT:
        case NIN_KEYSELECT:
        case WM_LBUTTONDBLCLK:
          RestoreFromTray();
          return 0;
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          return 0;
      }
      return 0;

    case WM_SYSCOMMAND:
      if ((wparam & 0xFFF0) == SC_MINIMIZE && tray_enabled_ && tray_added_) {
        HideToTray();
        return 0;
      }
      break;

    // Windows is logging off / shutting down, or an installer (Restart
    // Manager) asks us to close: quit for real instead of hiding.
    case WM_QUERYENDSESSION:
      quitting_ = true;
      return TRUE;
    case WM_ENDSESSION:
      if (wparam) {
        quitting_ = true;
        ::DestroyWindow(hwnd);
      } else {
        quitting_ = false;  // Shutdown was cancelled.
      }
      return 0;

    case WM_CLOSE:
      if (tray_enabled_ && tray_added_ && !quitting_) {
        HideToTray();
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
