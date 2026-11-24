#include "drawer_files.h"

#include <shellapi.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <system_error>
#include <vector>

#include "utils.h"

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                          text.c_str(), -1, nullptr, 0);
  if (!length) return {};
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.c_str(), -1,
                      wide.data(), length);
  wide.pop_back();
  return wide;
}

class Clipboard {
 public:
  explicit Clipboard(HWND window) : opened_(OpenClipboard(window) != FALSE) {}
  ~Clipboard() {
    if (opened_) CloseClipboard();
  }
  bool opened() const { return opened_; }

 private:
  bool opened_;
};

EncodableMap Kind(const char* kind) {
  return {{EncodableValue("kind"), EncodableValue(kind)}};
}

EncodableMap Paths(const char* kind, EncodableList paths) {
  auto value = Kind(kind);
  value.emplace(EncodableValue("paths"), EncodableValue(std::move(paths)));
  return value;
}

bool SaveClipboardImage(const std::wstring& path) {
  if (path.empty()) return false;
  const auto png = GetClipboardData(RegisterClipboardFormatW(L"PNG"));
  const auto bitmap = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
  if (!png && !bitmap) return false;

  std::error_code error;
  std::filesystem::create_directories(std::filesystem::path(path).parent_path(),
                                      error);
  if (error) return false;
  if (png) {
    const auto* data = static_cast<const char*>(GlobalLock(png));
    if (data) {
      std::ofstream out{std::filesystem::path(path), std::ios::binary};
      out.write(data, static_cast<std::streamsize>(GlobalSize(png)));
      out.close();
      GlobalUnlock(png);
      if (out) return true;
    }
  }
  if (!bitmap) return false;

  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmap> source;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) ||
      FAILED(factory->CreateBitmapFromHBITMAP(bitmap, nullptr,
                                              WICBitmapIgnoreAlpha, &source)) ||
      FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&frame, &properties)) ||
      FAILED(frame->Initialize(properties.Get()))) {
    return false;
  }
  UINT width = 0;
  UINT height = 0;
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  return SUCCEEDED(source->GetSize(&width, &height)) &&
         SUCCEEDED(frame->SetSize(width, height)) &&
         SUCCEEDED(frame->SetPixelFormat(&format)) &&
         SUCCEEDED(frame->WriteSource(source.Get(), nullptr)) &&
         SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
}

bool Open(HWND window, const std::wstring& target) {
  return !target.empty() &&
         reinterpret_cast<INT_PTR>(ShellExecuteW(
             window, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32;
}
}  // namespace

namespace drawer_files {

EncodableMap ReadClipboard(HWND window, const std::string& image_path) {
  Clipboard clipboard(window);
  if (!clipboard.opened()) return Kind("empty");
  if (const auto files = static_cast<HDROP>(GetClipboardData(CF_HDROP))) {
    EncodableList paths;
    const UINT count = DragQueryFileW(files, 0xFFFFFFFF, nullptr, 0);
    for (UINT index = 0; index < count; ++index) {
      const UINT length = DragQueryFileW(files, index, nullptr, 0);
      std::wstring path(length + 1, L'\0');
      if (!DragQueryFileW(files, index, path.data(), length + 1)) continue;
      const DWORD attributes = GetFileAttributesW(path.c_str());
      if (attributes != INVALID_FILE_ATTRIBUTES) {
        paths.emplace_back(Utf8FromUtf16(path.c_str()));
      }
    }
    if (!paths.empty()) return Paths("files", std::move(paths));
  }

  const auto image = Wide(image_path);
  if (SaveClipboardImage(image)) {
    return Paths("image", {EncodableValue(image_path)});
  }
  if (const auto data = GetClipboardData(CF_UNICODETEXT)) {
    const auto* buffer = static_cast<const wchar_t*>(GlobalLock(data));
    if (buffer) {
      const auto text = Utf8FromUtf16(buffer);
      GlobalUnlock(data);
      return {{EncodableValue("kind"), EncodableValue("text")},
              {EncodableValue("text"), EncodableValue(text)}};
    }
  }
  return Kind("empty");
}

bool CopyFiles(HWND window, const EncodableList& paths) {
  std::vector<std::wstring> files;
  size_t characters = 1;
  for (const auto& value : paths) {
    const auto* path = std::get_if<std::string>(&value);
    if (!path) return false;
    std::wstring file = Wide(*path);
    const DWORD attributes = GetFileAttributesW(file.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      return false;
    }
    characters += file.size() + 1;
    files.push_back(std::move(file));
  }
  if (files.empty()) return false;

  Clipboard clipboard(window);
  if (!clipboard.opened()) return false;
  HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,
                            sizeof(DROPFILES) + characters * sizeof(wchar_t));
  if (!data) return false;
  auto* header = static_cast<DROPFILES*>(GlobalLock(data));
  if (!header) {
    GlobalFree(data);
    return false;
  }
  header->pFiles = static_cast<DWORD>(sizeof(DROPFILES));
  header->fWide = TRUE;
  auto* buffer = reinterpret_cast<wchar_t*>(header + 1);
  for (const auto& file : files) {
    std::memcpy(buffer, file.c_str(), (file.size() + 1) * sizeof(wchar_t));
    buffer += file.size() + 1;
  }
  GlobalUnlock(data);
  if (!EmptyClipboard() || !SetClipboardData(CF_HDROP, data)) {
    GlobalFree(data);
    return false;
  }
  return true;
}

bool RevealFile(const std::string& path) {
  const auto wide = Wide(path);
  PIDLIST_ABSOLUTE item = nullptr;
  if (FAILED(SHParseDisplayName(wide.c_str(), nullptr, &item, 0, nullptr))) {
    return false;
  }
  const HRESULT result = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
  CoTaskMemFree(item);
  return SUCCEEDED(result);
}

bool OpenDirectory(HWND window, const std::string& path) {
  const auto wide = Wide(path);
  const DWORD attributes = GetFileAttributesW(wide.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) && Open(window, wide);
}

bool OpenWebUrl(HWND window, const std::string& url) {
  return (url.rfind("https://", 0) == 0 || url.rfind("http://", 0) == 0) &&
         Open(window, Wide(url));
}

}  // namespace drawer_files
