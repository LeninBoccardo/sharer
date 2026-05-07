#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
// Slice 5.x.3.4: single-instance enforcement. Without this, a second
// launch starts another wWinMain → another FlutterWindow → another
// HTTP server racing for port 8080. The second bind silently fails
// and the user gets a half-broken second instance with no visible
// error.
constexpr wchar_t kSingleInstanceMutex[] = L"Sharer_SingleInstance_Mutex";
// Window class used by the Flutter runner template (see Win32Window
// in win32_window.cpp). Used to find the existing window from a
// secondary launch.
constexpr wchar_t kFlutterWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Slice 5.x.3.4: try to acquire the single-instance mutex. If another
  // process already holds it, surface that instance's window (handles
  // the close-to-tray case via SW_RESTORE / SW_SHOW) and exit.
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance_mutex == nullptr ||
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(kFlutterWindowClass, nullptr);
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      } else {
        // Covers both the normal "already in foreground" case and the
        // hidden-to-tray case — SW_SHOW unhides whatever window_manager
        // hid via ShowWindow(SW_HIDE).
        ::ShowWindow(existing, SW_SHOW);
      }
      ::SetForegroundWindow(existing);
    }
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    return EXIT_SUCCESS;
  }

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
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"sharer", origin, size)) {
    ::CloseHandle(single_instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(single_instance_mutex);
  return EXIT_SUCCESS;
}
