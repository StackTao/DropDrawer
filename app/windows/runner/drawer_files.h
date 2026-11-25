#ifndef RUNNER_DRAWER_FILES_H_
#define RUNNER_DRAWER_FILES_H_

#include <windows.h>
#include <flutter/encodable_value.h>

#include <string>

namespace drawer_files {

flutter::EncodableMap ReadClipboard(HWND window, const std::string& image_path);
bool CopyFiles(HWND window, const flutter::EncodableList& paths);
bool RevealFile(const std::string& path);
bool OpenDirectory(HWND window, const std::string& path);
bool OpenWebUrl(HWND window, const std::string& url);
bool OpenUpdatePackage(HWND window, const std::string& path);

}  // namespace drawer_files

#endif  // RUNNER_DRAWER_FILES_H_
