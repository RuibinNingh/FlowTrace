#include <windows.h>

#include <iostream>
#include <string>

#include "data_directory.h"

// The OS implementation under test is the exact runner source, without Flutter.
int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  DataDirectory directory;
  std::wstring error;
  if (!directory.Acquire(argv[1], &error)) {
    std::cout << (directory.already_running() ? "busy" : "denied") << std::endl;
    ::CoUninitialize();
    return directory.already_running() ? 73 : 1;
  }
  std::cout << "leased" << std::endl;
  std::string line;
  std::getline(std::cin, line);
  ::CoUninitialize();
  return 0;
}
