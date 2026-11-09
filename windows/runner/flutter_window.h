#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include "win32_window.h"

// Registered window message another instance posts to bring this one up
// (single-instance support, see main.cpp).
inline constexpr wchar_t kShowWindowMessageName[] = L"GundilIntercom.ShowWindow";

// Hosts the Flutter view and adds a system tray (notification area) icon:
// * minimize / close hide the window to the tray (configurable from Dart),
// * left-click the icon to open, right-click for Open / Exit,
// * the tooltip shows the intercom status (set from Dart).
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void AddTrayIcon();
  void RemoveTrayIcon();
  void UpdateTrayTooltip();
  void ShowTrayMenu();
  void HideToTray();
  void RestoreFromTray();
  void ShowBalloon(const std::wstring& title, const std::wstring& text);
  void RegisterWindowChannel();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "gundil/window" channel used by Dart to configure the tray.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  NOTIFYICONDATAW tray_icon_{};
  bool tray_added_ = false;
  // Minimize and close go to the tray instead of the taskbar / quitting.
  bool tray_enabled_ = true;
  // Set by "Exit" in the tray menu: the next close really quits.
  bool quitting_ = false;
  bool balloon_shown_ = false;
  std::wstring tooltip_ = L"Gundil Intercom";

  UINT taskbar_created_message_ = 0;
  UINT show_window_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
