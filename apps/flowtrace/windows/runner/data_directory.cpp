#include "data_directory.h"

#include <shlobj.h>

#include <algorithm>
#include <cwctype>
#include <cstdlib>
#include <vector>

namespace {
std::wstring CanonicalDirectory(const std::wstring& path) {
  HANDLE directory = ::CreateFileW(
      path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (directory == INVALID_HANDLE_VALUE) return L"";
  DWORD length = ::GetFinalPathNameByHandleW(directory, nullptr, 0, 0);
  std::vector<wchar_t> buffer(static_cast<size_t>(length) + 1);
  DWORD written = ::GetFinalPathNameByHandleW(
      directory, buffer.data(), static_cast<DWORD>(buffer.size()), 0);
  ::CloseHandle(directory);
  if (written == 0 || written >= buffer.size()) return L"";
  std::wstring result(buffer.data(), written);
  // Use ordinary local paths for Dart, SQLite and the native plugins.
  if (result.rfind(L"\\\\?\\", 0) == 0) result.erase(0, 4);
  while (result.size() > 3 && result.back() == L'\\') result.pop_back();
  return result;
}

std::wstring Fold(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return value;
}

bool Within(const std::wstring& child, const std::wstring& parent) {
  const auto left = Fold(child);
  const auto right = Fold(parent);
  return left == right || left.rfind(right + L"\\", 0) == 0;
}

bool SafeAncestors(const std::wstring& requested,
                   const std::wstring& installation) {
  // Resolve every existing component before creating children. In particular,
  // an alias/junction into the installation must not create an empty child
  // there before being rejected by final canonical validation.
  size_t end = 3;
  while (end <= requested.size()) {
    const std::wstring component = requested.substr(0, end);
    const DWORD attributes = ::GetFileAttributesW(component.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
      const DWORD error = ::GetLastError();
      if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) return false;
    } else {
      if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) return false;
      const std::wstring canonical = CanonicalDirectory(component);
      if (canonical.size() < 3 || canonical[1] != L':' ||
          Within(canonical, installation)) return false;
    }
    if (end == requested.size()) break;
    const auto separator = requested.find_first_of(L"\\/", end + 1);
    end = separator == std::wstring::npos ? requested.size() : separator;
  }
  return true;
}
}  // namespace

DataDirectory::~DataDirectory() {
  if (lock_ != INVALID_HANDLE_VALUE) ::CloseHandle(lock_);
}

bool DataDirectory::Acquire(const std::wstring& explicit_path,
                            std::wstring* error) {
  if (lock_ != INVALID_HANDLE_VALUE) {
    *error = L"The data directory lease has already been acquired.";
    return false;
  }
  std::wstring requested = explicit_path;
  isolated_ = !requested.empty();
  if (requested.empty()) {
    PWSTR roaming = nullptr;
    if (FAILED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                     &roaming))) {
      *error = L"Cannot locate the Windows user data directory.";
      return false;
    }
    // Keep the exact path_provider company/product/flowtrace location. Product
    // names must stay stable across upgrades and secure-storage operations.
    requested = std::wstring(roaming) + L"\\com.flowtrace\\flowtrace\\flowtrace";
    ::CoTaskMemFree(roaming);
  }
  if (requested.size() <= 3 || !std::iswalpha(requested[0]) ||
      requested[1] != L':' || (requested[2] != L'\\' && requested[2] != L'/')) {
    *error = L"The data directory must be an absolute local Windows path.";
    return false;
  }
  std::vector<wchar_t> full(32768);
  DWORD count = ::GetFullPathNameW(requested.c_str(),
                                  static_cast<DWORD>(full.size()), full.data(),
                                  nullptr);
  if (count == 0 || count >= full.size()) {
    *error = L"Cannot resolve the data directory.";
    return false;
  }
  requested.assign(full.data(), count);
  std::vector<wchar_t> executable(32768);
  count = ::GetModuleFileNameW(nullptr, executable.data(),
                             static_cast<DWORD>(executable.size()));
  if (count == 0 || count >= executable.size()) {
    *error = L"Cannot resolve the installation directory.";
    return false;
  }
  std::wstring installation(executable.data(), count);
  installation = installation.substr(0, installation.find_last_of(L"\\/"));
  installation = CanonicalDirectory(installation);
  // Reject the lexical install path before creating any directory there.
  if (installation.empty() || Within(requested, installation) ||
      !SafeAncestors(requested, installation)) {
    *error = L"Business data cannot be stored in the installation directory.";
    return false;
  }
  const int created = ::SHCreateDirectoryExW(nullptr, requested.c_str(), nullptr);
  if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS &&
      created != ERROR_FILE_EXISTS) {
    *error = L"Cannot create the user data directory. Check disk space and permissions.";
    return false;
  }
  path_ = CanonicalDirectory(requested);
  if (path_.size() < 3 || path_[1] != L':' || Within(path_, installation)) {
    *error = L"The data directory resolves to an invalid installation location.";
    return false;
  }
  const std::wstring file = path_ + L"\\flowtrace.instance.lock";
  const DWORD attributes = ::GetFileAttributesW(file.c_str());
  if (attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    *error = L"The instance lock must be an ordinary local file.";
    return false;
  }
  lock_ = ::CreateFileW(file.c_str(), GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                        nullptr);
  if (lock_ == INVALID_HANDLE_VALUE) {
    already_running_ = ::GetLastError() == ERROR_SHARING_VIOLATION;
    if (already_running_) {
      HANDLE reader = ::CreateFileW(file.c_str(), GENERIC_READ,
          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
      if (reader != INVALID_HANDLE_VALUE) {
        char contents[32] = {};
        DWORD read = 0;
        if (::ReadFile(reader, contents, sizeof(contents) - 1, &read, nullptr)) {
          owner_pid_ = static_cast<DWORD>(std::strtoul(contents, nullptr, 10));
        }
        ::CloseHandle(reader);
      }
    }
    *error = already_running_
                 ? L"FlowTrace is already using this data directory. Return to the open window."
                 : L"Cannot lock the data directory. Check permissions and disk space.";
    return false;
  }
  FILE_ATTRIBUTE_TAG_INFO tag = {};
  if (!::GetFileInformationByHandleEx(lock_, FileAttributeTagInfo, &tag,
                                       sizeof(tag)) ||
      (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    *error = L"The instance lock must be an ordinary local file.";
    ::CloseHandle(lock_);
    lock_ = INVALID_HANDLE_VALUE;
    return false;
  }
  // Contents are diagnostic metadata only; the live HANDLE is the authority.
  const std::string owner = std::to_string(::GetCurrentProcessId()) + "\r\n";
  DWORD written = 0;
  if (!::SetFilePointerEx(lock_, LARGE_INTEGER{}, nullptr, FILE_BEGIN) ||
      !::SetEndOfFile(lock_) ||
      !::WriteFile(lock_, owner.data(), static_cast<DWORD>(owner.size()),
                   &written, nullptr) ||
      written != owner.size() || !::FlushFileBuffers(lock_)) {
    *error = L"Cannot persist the instance lease. Check disk space and permissions.";
    ::CloseHandle(lock_);
    lock_ = INVALID_HANDLE_VALUE;
    return false;
  }
  return true;
}
