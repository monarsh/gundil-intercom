#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <cwchar>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Single instance: if Gundil Intercom is already running (maybe hidden in
  // the tray), bring that window up instead of starting a second copy with
  // the same identity. P2P_INTERCOM_PROFILE (developer option) gets its own
  // instance per profile.
  std::wstring mutex_name = L"Local\\GundilIntercom.SingleInstance";
  wchar_t profile[128] = {0};
  if (::GetEnvironmentVariableW(L"P2P_INTERCOM_PROFILE", profile, 128) > 0) {
    mutex_name += L".";
    mutex_name += profile;
  }
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, mutex_name.c_str());
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Gundil Intercom");
    if (existing != nullptr) {
      DWORD pid = 0;
      ::GetWindowThreadProcessId(existing, &pid);
      ::AllowSetForegroundWindow(pid);
      // A second autostart launch must not pop the window up.
      bool minimized_launch = wcsstr(command_line, L"--minimized") != nullptr;
      if (!minimized_launch) {
        ::PostMessageW(existing,
                       ::RegisterWindowMessageW(kShowWindowMessageName), 0, 0);
      }
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // "--minimized" is passed by the autostart entry (sign-in).
  const bool start_minimized =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--minimized") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Gundil Intercom", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  window.SetStartMinimized(start_minimized);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
