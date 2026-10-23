#ifndef RUNNER_DATA_DIRECTORY_H_
#define RUNNER_DATA_DIRECTORY_H_

#include <windows.h>

#include <string>

// One OS-held writer lease per canonical user data directory. This lease is
// acquired before starting Flutter and is released by the OS after termination.
class DataDirectory {
 public:
  DataDirectory() = default;
  ~DataDirectory();
  DataDirectory(const DataDirectory&) = delete;
  DataDirectory& operator=(const DataDirectory&) = delete;

  bool Acquire(const std::wstring& explicit_path, std::wstring* error);
  const std::wstring& path() const { return path_; }
  bool isolated() const { return isolated_; }
  bool already_running() const { return already_running_; }
  DWORD owner_pid() const { return owner_pid_; }

 private:
  HANDLE lock_ = INVALID_HANDLE_VALUE;
  std::wstring path_;
  bool isolated_ = false;
  bool already_running_ = false;
  DWORD owner_pid_ = 0;
};

#endif  // RUNNER_DATA_DIRECTORY_H_
