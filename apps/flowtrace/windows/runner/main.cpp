#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include "flutter_window.h"
#include "data_directory.h"
#include "utils.h"

namespace {
BOOL CALLBACK ActivateOwnedWindow(HWND window, LPARAM owner) {
  DWORD process = 0;
  ::GetWindowThreadProcessId(window, &process);
  if (process == static_cast<DWORD>(owner) && ::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_RESTORE);
    ::SetForegroundWindow(window);
    return FALSE;
  }
  return TRUE;
}
}  // namespace

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

  std::wstring explicit_data;
  int argument_count = 0;
  wchar_t** arguments = ::CommandLineToArgvW(::GetCommandLineW(), &argument_count);
  const std::wstring prefix = L"--flowtrace-data-dir=";
  for (int index = 1; arguments != nullptr && index < argument_count; ++index) {
    std::wstring argument(arguments[index]);
    if (argument.rfind(prefix, 0) == 0) {
      if (!explicit_data.empty()) {
        ::LocalFree(arguments);
        ::CoUninitialize();
        return EXIT_FAILURE;
      }
      explicit_data = argument.substr(prefix.size());
      if (explicit_data.empty()) {
        ::LocalFree(arguments);
        ::CoUninitialize();
        return EXIT_FAILURE;
      }
    }
  }
  if (arguments != nullptr) ::LocalFree(arguments);
  DataDirectory data_directory;
  std::wstring directory_error;
  if (!data_directory.Acquire(explicit_data, &directory_error)) {
    if (data_directory.already_running()) {
      if (data_directory.owner_pid() != 0) {
        ::EnumWindows(ActivateOwnedWindow, data_directory.owner_pid());
      }
    } else {
      ::MessageBoxW(nullptr, directory_error.c_str(), L"流迹 FlowTrace",
                    MB_OK | MB_ICONERROR);
    }
    ::CoUninitialize();
    return data_directory.already_running() ? 73 : EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, data_directory.path(), data_directory.isolated());
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"流迹 FlowTrace", origin, size)) {
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
