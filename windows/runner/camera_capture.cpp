#include "camera_capture.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cwctype>
#include <utility>

#include "utils.h"

using Microsoft::WRL::ComPtr;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

constexpr UINT kStartedMessage = WM_APP + 20;
constexpr UINT kFrameMessage = WM_APP + 21;
constexpr UINT kErrorMessage = WM_APP + 22;

constexpr DWORD kVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), len);
  return out;
}

std::string HrMessage(HRESULT hr, const char* what) {
  if (hr == E_ACCESSDENIED) {
    return "Camera access is blocked. Turn on Windows Settings > Privacy & "
           "security > Camera > Let desktop apps access your camera.";
  }
#ifdef MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED
  if (hr == MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED) {
    return "The camera was unplugged or turned off.";
  }
#endif
#ifdef MF_E_HW_MFT_FAILED_START_STREAMING
  if (hr == MF_E_HW_MFT_FAILED_START_STREAMING) {
    return "The camera is in use by another app.";
  }
#endif
  char buf[128];
  std::snprintf(buf, sizeof(buf), "%s failed (0x%08lX)", what,
                static_cast<unsigned long>(hr));
  return buf;
}

// Guess from the device name: "Surface Camera Front", "... Rear", else a
// normal (built-in or USB) webcam.
std::string FacingFor(const std::wstring& name) {
  std::wstring lower(name);
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  if (lower.find(L"front") != std::wstring::npos) return "front";
  if (lower.find(L"rear") != std::wstring::npos ||
      lower.find(L"back") != std::wstring::npos) {
    return "back";
  }
  return "external";
}

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

int GetInt(const EncodableMap& map, const char* key, int fallback) {
  const EncodableValue* v = Find(map, key);
  if (!v) return fallback;
  if (const auto* i = std::get_if<int32_t>(v)) return *i;
  if (const auto* l = std::get_if<int64_t>(v)) return static_cast<int>(*l);
  return fallback;
}

std::string GetString(const EncodableMap& map, const char* key) {
  const EncodableValue* v = Find(map, key);
  if (!v) return std::string();
  if (const auto* s = std::get_if<std::string>(v)) return *s;
  return std::string();
}

// Size and row stride of the reader's current (RGB32) output.
HRESULT ReadFormat(IMFSourceReader* reader, UINT32* width, UINT32* height,
                   LONG* stride) {
  ComPtr<IMFMediaType> type;
  HRESULT hr = reader->GetCurrentMediaType(kVideoStream, &type);
  if (FAILED(hr)) return hr;
  hr = MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, width, height);
  if (FAILED(hr)) return hr;
  UINT32 raw = 0;
  if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &raw))) {
    *stride = static_cast<LONG>(static_cast<INT32>(raw));
    return S_OK;
  }
  LONG computed = 0;
  hr = MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1, *width,
                                      &computed);
  if (SUCCEEDED(hr)) *stride = computed;
  return hr;
}

// Opens the webcam with symbolic link |link| and sets it up to deliver RGB32
// pictures close to |want_width| x |want_height| at |want_fps| or more.
std::string OpenReader(const std::wstring& link, int want_width,
                       int want_height, int want_fps,
                       ComPtr<IMFSourceReader>* out) {
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 2);
  if (SUCCEEDED(hr)) {
    hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                             MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  }
  if (SUCCEEDED(hr)) {
    hr = attributes->SetString(
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, link.c_str());
  }
  ComPtr<IMFMediaSource> source;
  if (SUCCEEDED(hr)) hr = MFCreateDeviceSource(attributes.Get(), &source);
  if (FAILED(hr)) return HrMessage(hr, "Opening the camera");

  // Video processing converts the camera's YUV/MJPG pictures to RGB32.
  ComPtr<IMFAttributes> reader_attributes;
  hr = MFCreateAttributes(&reader_attributes, 1);
  if (SUCCEEDED(hr)) {
    hr = reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,
                                      TRUE);
  }
  ComPtr<IMFSourceReader> reader;
  if (SUCCEEDED(hr)) {
    hr = MFCreateSourceReaderFromMediaSource(
        source.Get(), reader_attributes.Get(), &reader);
  }
  if (FAILED(hr)) {
    source->Shutdown();
    return HrMessage(hr, "Opening the camera");
  }

  // Pick the camera mode closest to the wanted size that is fast enough.
  // (The reader then owns the source and shuts it down when released.)
  const long long want_area =
      static_cast<long long>(want_width) * static_cast<long long>(want_height);
  ComPtr<IMFMediaType> best;
  long long best_score = LLONG_MAX;
  for (DWORD i = 0;; i++) {
    ComPtr<IMFMediaType> type;
    if (FAILED(reader->GetNativeMediaType(kVideoStream, i, &type))) break;
    UINT32 w = 0, h = 0;
    if (FAILED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h)) ||
        w == 0 || h == 0) {
      continue;
    }
    UINT32 num = 0, den = 0;
    double rate = 30.0;
    if (SUCCEEDED(MFGetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, &num,
                                      &den)) &&
        den != 0) {
      rate = static_cast<double>(num) / static_cast<double>(den);
    }
    GUID subtype = GUID_NULL;
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    const long long area =
        static_cast<long long>(w) * static_cast<long long>(h);
    long long score = std::llabs(area - want_area);
    if (area < want_area) score += 1000000;  // Rather scale down than up.
    if (rate + 0.5 < static_cast<double>(want_fps)) score += 4000000;
    if (subtype.Data1 == MAKEFOURCC('M', 'J', 'P', 'G')) score += 1000;  // Decoded.
    if (score < best_score) {
      best_score = score;
      best = type;
    }
  }
  if (best) reader->SetCurrentMediaType(kVideoStream, nullptr, best.Get());

  ComPtr<IMFMediaType> rgb;
  hr = MFCreateMediaType(&rgb);
  if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (SUCCEEDED(hr)) {
    hr = reader->SetCurrentMediaType(kVideoStream, nullptr, rgb.Get());
  }
  if (FAILED(hr)) return HrMessage(hr, "Setting the camera format");
  reader->SetStreamSelection(kVideoStream, TRUE);
  *out = reader;
  return std::string();
}

// Copies the picture in |sample| into |pixels| as top-down BGRX rows.
bool CopyPixels(IMFSample* sample, UINT32 width, UINT32 height, LONG stride,
                std::vector<uint8_t>* pixels) {
  ComPtr<IMFMediaBuffer> buffer;
  if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) return false;
  const size_t row = static_cast<size_t>(width) * 4;
  pixels->resize(row * height);

  ComPtr<IMF2DBuffer> buffer2d;
  if (SUCCEEDED(buffer.As(&buffer2d))) {
    BYTE* scan0 = nullptr;
    LONG pitch = 0;
    if (FAILED(buffer2d->Lock2D(&scan0, &pitch))) return false;
    for (UINT32 y = 0; y < height; y++) {
      const BYTE* src = scan0 + static_cast<ptrdiff_t>(y) * pitch;
      std::copy(src, src + row, pixels->data() + row * y);
    }
    buffer2d->Unlock2D();
    return true;
  }

  BYTE* data = nullptr;
  DWORD length = 0;
  if (FAILED(buffer->Lock(&data, nullptr, &length))) return false;
  const size_t abs_stride = static_cast<size_t>(stride < 0 ? -stride : stride);
  bool ok = abs_stride >= row && static_cast<size_t>(length) >=
                                     abs_stride * (height - 1) + row;
  if (ok) {
    for (UINT32 y = 0; y < height; y++) {
      // A negative stride means the rows are stored bottom-up.
      const UINT32 src_row = stride < 0 ? height - 1 - y : y;
      const BYTE* src = data + abs_stride * src_row;
      std::copy(src, src + row, pixels->data() + row * y);
    }
  }
  buffer->Unlock();
  return ok;
}

// Encodes BGRX |pixels| as a JPEG, scaled down to about |max_width| wide.
bool EncodeJpeg(IWICImagingFactory* wic, std::vector<uint8_t>& pixels,
                UINT32 width, UINT32 height, int max_width, int quality,
                std::vector<uint8_t>* out) {
  ComPtr<IWICBitmap> bitmap;
  HRESULT hr = wic->CreateBitmapFromMemory(
      width, height, GUID_WICPixelFormat32bppBGR, width * 4,
      static_cast<UINT>(pixels.size()), pixels.data(), &bitmap);
  if (FAILED(hr)) return false;
  ComPtr<IWICBitmapSource> source = bitmap;

  UINT32 out_width = width, out_height = height;
  const UINT32 limit = static_cast<UINT32>(std::max(160, max_width));
  if (width > limit + limit / 4) {
    out_width = limit;
    out_height = std::max<UINT32>(1, height * limit / width);
    ComPtr<IWICBitmapScaler> scaler;
    hr = wic->CreateBitmapScaler(&scaler);
    if (SUCCEEDED(hr)) {
      hr = scaler->Initialize(source.Get(), out_width, out_height,
                              WICBitmapInterpolationModeFant);
    }
    if (FAILED(hr)) return false;
    source = scaler;
  }

  ComPtr<IWICFormatConverter> converter;
  hr = wic->CreateFormatConverter(&converter);
  if (SUCCEEDED(hr)) {
    hr = converter->Initialize(source.Get(), GUID_WICPixelFormat24bppBGR,
                               WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeCustom);
  }
  ComPtr<IStream> stream;
  if (SUCCEEDED(hr)) hr = ::CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  ComPtr<IWICBitmapEncoder> encoder;
  if (SUCCEEDED(hr)) {
    hr = wic->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder);
  }
  if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &properties);
  if (SUCCEEDED(hr)) {
    PROPBAG2 option = {};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value = {};
    value.vt = VT_R4;
    value.fltVal = static_cast<FLOAT>(quality) / 100.0f;
    properties->Write(1, &option, &value);  // Best effort.
    hr = frame->Initialize(properties.Get());
  }
  if (SUCCEEDED(hr)) hr = frame->SetSize(out_width, out_height);
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
  if (SUCCEEDED(hr)) hr = frame->WriteSource(converter.Get(), nullptr);
  if (SUCCEEDED(hr)) hr = frame->Commit();
  if (SUCCEEDED(hr)) hr = encoder->Commit();
  HGLOBAL global = nullptr;
  if (SUCCEEDED(hr)) hr = ::GetHGlobalFromStream(stream.Get(), &global);
  STATSTG stat = {};
  if (SUCCEEDED(hr)) hr = stream->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr)) return false;
  const size_t size = static_cast<size_t>(stat.cbSize.QuadPart);
  const void* data = ::GlobalLock(global);
  if (!data) return false;
  const uint8_t* bytes = static_cast<const uint8_t*>(data);
  out->assign(bytes, bytes + size);
  ::GlobalUnlock(global);
  return true;
}

}  // namespace

CameraCapture::CameraCapture(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  mf_started_ = SUCCEEDED(::MFStartup(MF_VERSION));

  methods_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "p2p_intercom/camera",
      &flutter::StandardMethodCodec::GetInstance());
  methods_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "p2p_intercom/camera/frames",
      &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_ = std::move(events);
            return nullptr;
          },
          [this](const EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_.reset();
            return nullptr;
          }));
}

CameraCapture::~CameraCapture() {
  Stop();
  sink_.reset();
  if (events_) events_->SetStreamHandler(nullptr);
  if (methods_) methods_->SetMethodCallHandler(nullptr);
  if (mf_started_) ::MFShutdown();
}

void CameraCapture::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& name = call.method_name();
  if (name == "requestPermission") {
    // Windows has no prompt for desktop apps; a blocked camera (Privacy
    // settings) is reported when it's opened.
    result->Success(EncodableValue(true));
  } else if (name == "list") {
    result->Success(EncodableValue(ListDevices()));
  } else if (name == "start") {
    Settings settings;
    if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
      settings.link = Utf16FromUtf8(GetString(*args, "id"));
      settings.width = GetInt(*args, "width", settings.width);
      settings.height = GetInt(*args, "height", settings.height);
      settings.fps = std::clamp(GetInt(*args, "fps", settings.fps), 1, 30);
      settings.quality =
          std::clamp(GetInt(*args, "quality", settings.quality), 30, 95);
    }
    Start(std::move(settings), std::move(result));
  } else if (name == "stop") {
    Stop();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

EncodableList CameraCapture::ListDevices() {
  EncodableList out;
  if (!mf_started_) return out;
  ComPtr<IMFAttributes> attributes;
  if (FAILED(MFCreateAttributes(&attributes, 1))) return out;
  attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                      MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  if (FAILED(MFEnumDeviceSources(attributes.Get(), &devices, &count))) {
    return out;
  }
  for (UINT32 i = 0; i < count; i++) {
    WCHAR* name = nullptr;
    WCHAR* link = nullptr;
    UINT32 length = 0;
    if (SUCCEEDED(devices[i]->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length)) &&
        SUCCEEDED(devices[i]->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link,
            &length))) {
      out.push_back(EncodableValue(EncodableMap{
          {EncodableValue("id"), EncodableValue(Utf8FromUtf16(link))},
          {EncodableValue("name"), EncodableValue(Utf8FromUtf16(name))},
          {EncodableValue("facing"), EncodableValue(FacingFor(name))},
      }));
    }
    ::CoTaskMemFree(name);
    ::CoTaskMemFree(link);
    devices[i]->Release();
  }
  ::CoTaskMemFree(devices);
  return out;
}

void CameraCapture::Start(
    Settings settings,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  Stop();
  if (!mf_started_) {
    result->Error("camera", "Media Foundation is not available");
    return;
  }
  if (settings.link.empty()) {
    result->Error("camera", "No camera chosen");
    return;
  }
  // Webcam self-views are shown like a mirror, except a tablet's rear one.
  mirror_ = FacingFor(settings.link) != "back";
  settings.mirror = mirror_;
  pending_start_ = std::move(result);
  running_ = true;
  thread_ = std::thread(&CameraCapture::CaptureThread, this,
                        std::move(settings));
}

void CameraCapture::Stop() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    latest_.clear();
    has_latest_ = false;
    started_ready_ = false;
    has_error_ = false;
  }
  if (pending_start_) {
    pending_start_->Error("camera", "Stopped");
    pending_start_.reset();
  }
}

void CameraCapture::CaptureThread(Settings settings) {
  const bool com = SUCCEEDED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  {
    ComPtr<IMFSourceReader> reader;
    std::string error = OpenReader(settings.link, settings.width,
                                   settings.height, settings.fps, &reader);
    UINT32 width = 0, height = 0;
    LONG stride = 0;
    if (error.empty()) {
      HRESULT hr = ReadFormat(reader.Get(), &width, &height, &stride);
      if (FAILED(hr)) error = HrMessage(hr, "Reading the camera format");
    }
    ComPtr<IWICImagingFactory> wic;
    if (error.empty()) {
      HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
      if (FAILED(hr)) error = HrMessage(hr, "Creating the JPEG encoder");
    }
    PostStarted(error);

    if (error.empty()) {
      const auto interval = std::chrono::milliseconds(1000 / settings.fps);
      auto last = std::chrono::steady_clock::now() - interval;
      std::vector<uint8_t> pixels;
      while (running_) {
        DWORD stream = 0, flags = 0;
        LONGLONG timestamp = 0;
        ComPtr<IMFSample> sample;
        HRESULT hr = reader->ReadSample(kVideoStream, 0, &stream, &flags,
                                        &timestamp, &sample);
        if (FAILED(hr)) {
          error = HrMessage(hr, "Reading the camera");
          break;
        }
        if (flags & (MF_SOURCE_READERF_ENDOFSTREAM | MF_SOURCE_READERF_ERROR)) {
          error = "The camera stopped (unplugged or in use by another app).";
          break;
        }
        if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
          ReadFormat(reader.Get(), &width, &height, &stride);
        }
        if (!sample || !running_ || width == 0 || height == 0) continue;
        const auto now = std::chrono::steady_clock::now();
        if (now - last < interval) continue;
        last = now;
        std::vector<uint8_t> jpeg;
        if (CopyPixels(sample.Get(), width, height, stride, &pixels) &&
            EncodeJpeg(wic.Get(), pixels, width, height, settings.width,
                       settings.quality, &jpeg)) {
          PostFrame(std::move(jpeg));
        }
      }
      if (running_ && !error.empty()) PostError(error);
    }
  }
  if (com) ::CoUninitialize();
}

void CameraCapture::PostStarted(const std::string& error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    started_error_ = error;
    started_ready_ = true;
  }
  ::PostMessage(window_, kStartedMessage, 0, 0);
}

void CameraCapture::PostError(const std::string& error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    error_ = error;
    has_error_ = true;
  }
  ::PostMessage(window_, kErrorMessage, 0, 0);
}

void CameraCapture::PostFrame(std::vector<uint8_t> jpeg) {
  bool post = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    latest_ = std::move(jpeg);
    has_latest_ = true;
    post = !frame_posted_;
    frame_posted_ = true;
  }
  if (post) ::PostMessage(window_, kFrameMessage, 0, 0);
}

bool CameraCapture::HandleMessage(UINT message) {
  switch (message) {
    case kStartedMessage: {
      std::string error;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!started_ready_) return true;
        started_ready_ = false;
        error = started_error_;
      }
      if (!error.empty()) {
        running_ = false;
        if (thread_.joinable()) thread_.join();
      }
      if (pending_start_) {
        if (error.empty()) {
          pending_start_->Success();
        } else {
          pending_start_->Error("camera", error);
        }
        pending_start_.reset();
      }
      return true;
    }
    case kFrameMessage: {
      std::vector<uint8_t> jpeg;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        frame_posted_ = false;
        if (!has_latest_) return true;
        jpeg.swap(latest_);
        has_latest_ = false;
      }
      if (sink_ && running_) {
        sink_->Success(EncodableValue(EncodableMap{
            {EncodableValue("jpeg"), EncodableValue(std::move(jpeg))},
            {EncodableValue("rotation"), EncodableValue(0)},
            {EncodableValue("mirror"), EncodableValue(mirror_)},
        }));
      }
      return true;
    }
    case kErrorMessage: {
      std::string error;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!has_error_) return true;
        has_error_ = false;
        error = error_;
      }
      running_ = false;
      if (thread_.joinable()) thread_.join();
      if (sink_) sink_->Error("camera", error);
      return true;
    }
  }
  return false;
}
