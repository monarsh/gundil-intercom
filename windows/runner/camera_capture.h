#ifndef RUNNER_CAMERA_CAPTURE_H_
#define RUNNER_CAMERA_CAPTURE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Webcam for video calls (built-in or USB), using Media Foundation.
//
// Dart side: lib/src/video_call.dart.
// * "p2p_intercom/camera" methods: requestPermission, list, start, stop.
// * "p2p_intercom/camera/frames" events:
//   {"jpeg": Uint8List, "rotation": 0, "mirror": bool}.
//
// Pictures are captured on a worker thread, JPEG-encoded with WIC and handed
// to the platform thread with a posted window message (Flutter channels may
// only be used there). Only the newest picture is kept, so a busy UI thread
// drops pictures instead of queueing them.
class CameraCapture {
 public:
  CameraCapture(flutter::BinaryMessenger* messenger, HWND window);
  ~CameraCapture();

  CameraCapture(const CameraCapture&) = delete;
  CameraCapture& operator=(const CameraCapture&) = delete;

  // Call from the window procedure. Returns true when |message| was ours.
  bool HandleMessage(UINT message);

 private:
  struct Settings {
    std::wstring link;  // Device symbolic link.
    int width = 640;
    int height = 480;
    int fps = 15;
    int quality = 70;
    bool mirror = true;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  flutter::EncodableList ListDevices();
  void Start(Settings settings,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result);
  void Stop();
  void CaptureThread(Settings settings);

  // Worker -> platform thread.
  void PostStarted(const std::string& error);
  void PostError(const std::string& error);
  void PostFrame(std::vector<uint8_t> jpeg);

  HWND window_;
  bool mf_started_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  std::thread thread_;
  std::atomic<bool> running_{false};
  bool mirror_ = true;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_start_;

  std::mutex mutex_;  // Guards the fields below.
  std::vector<uint8_t> latest_;
  bool has_latest_ = false;
  bool frame_posted_ = false;
  bool started_ready_ = false;
  std::string started_error_;
  std::string error_;
  bool has_error_ = false;
};

#endif  // RUNNER_CAMERA_CAPTURE_H_
