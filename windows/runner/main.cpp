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
  // Client-area size in logical pixels (16:9), so a 16:9 video fills the
  // window without letterboxing. Win32Window::Create expands this to the full
  // window size (title bar and borders included) via AdjustWindowRectEx.
  Win32Window::Size size(1280, 720);
  // Window title: the Chinese app name for PolyFlixPlayer.
  // Kept as \u escapes on purpose: this file is UTF-8 without BOM and CMake
  // does not pass /utf-8 to MSVC, so a literal CJK string would be decoded
  // with the local code page (936) and come out as mojibake. Any non-ASCII
  // byte here also triggers warning C4819, which /WX promotes to an error.
  if (!window.Create(L"\u5f71\u73b0\u64ad\u653e\u5668", origin, size)) {
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
