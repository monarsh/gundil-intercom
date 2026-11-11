#ifndef RUNNER_CAMERA_CAPTURE_H_
#define RUNNER_CAMERA_CAPTURE_H_

#include <flutter_linux/flutter_linux.h>

// Webcam for video calls on Linux (built-in or USB), using V4L2.
//
// Same channels as Android and Windows (Dart side: lib/src/video_call.dart):
// * "p2p_intercom/camera" methods: requestPermission, list, start, stop.
// * "p2p_intercom/camera/frames" events:
//   {"jpeg": Uint8List, "rotation": 0, "mirror": true}.
//
// Cameras that offer MJPEG send their pictures as they are (no CPU work);
// others (YUYV) are converted and JPEG-encoded with GdkPixbuf. Capture runs
// on a worker thread; only the newest picture is handed to the main thread.
void camera_capture_init(FlView* view);

#endif  // RUNNER_CAMERA_CAPTURE_H_
