#include "camera_capture.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <linux/videodev2.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

// Largest picture the intercom protocol carries (protocol.dart).
constexpr size_t kMaxJpeg = 250 * 1024;

struct Settings {
  std::string path;
  int width = 640;
  int height = 480;
  int fps = 15;
  int quality = 70;
};

struct Camera {
  FlMethodChannel* methods = nullptr;
  FlEventChannel* events = nullptr;
  bool listening = false;

  std::thread thread;
  std::atomic<bool> running{false};
  FlMethodCall* pending_start = nullptr;  // Answered when the camera opened.

  std::mutex mutex;  // Guards the fields below (worker <-> main thread).
  std::vector<uint8_t> latest;
  bool has_latest = false;
  bool frame_posted = false;
  bool start_ready = false;
  std::string start_error;
  bool has_error = false;
  std::string error;
};

Camera cam;

int xioctl(int fd, unsigned long request, void* arg) {
  int r;
  do {
    r = ioctl(fd, request, arg);
  } while (r == -1 && errno == EINTR);
  return r;
}

std::string open_error(int err) {
  switch (err) {
    case EACCES:
    case EPERM:
      return "No permission to use the camera. Add your user to the "
             "\"video\" group (sudo usermod -aG video $USER) and log in "
             "again.";
    case EBUSY:
      return "The camera is in use by another app.";
    case ENOENT:
    case ENODEV:
      return "The camera was unplugged.";
    default:
      return std::string("Could not open the camera: ") + strerror(err);
  }
}

// ------------------------------------------------------------- devices

bool is_capture_device(int fd, std::string* name) {
  v4l2_capability cap = {};
  if (xioctl(fd, VIDIOC_QUERYCAP, &cap) != 0) return false;
  const uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS)
                            ? cap.device_caps
                            : cap.capabilities;
  // UVC cameras also create a metadata node without VIDEO_CAPTURE.
  if (!(caps & V4L2_CAP_VIDEO_CAPTURE) || !(caps & V4L2_CAP_STREAMING)) {
    return false;
  }
  if (name != nullptr) *name = reinterpret_cast<const char*>(cap.card);
  return true;
}

FlValue* list_devices() {
  std::vector<int> numbers;
  if (DIR* dir = opendir("/dev")) {
    while (dirent* e = readdir(dir)) {
      if (strncmp(e->d_name, "video", 5) == 0) {
        char* end = nullptr;
        const long n = strtol(e->d_name + 5, &end, 10);
        if (end != e->d_name + 5 && *end == '\0') {
          numbers.push_back(static_cast<int>(n));
        }
      }
    }
    closedir(dir);
  }
  std::sort(numbers.begin(), numbers.end());

  FlValue* list = fl_value_new_list();
  for (int n : numbers) {
    const std::string path = "/dev/video" + std::to_string(n);
    const int fd = open(path.c_str(), O_RDWR | O_NONBLOCK);
    if (fd < 0) continue;
    std::string name;
    if (is_capture_device(fd, &name)) {
      if (name.empty()) name = path;
      FlValue* map = fl_value_new_map();
      fl_value_set_string_take(map, "id", fl_value_new_string(path.c_str()));
      fl_value_set_string_take(map, "name", fl_value_new_string(name.c_str()));
      fl_value_set_string_take(map, "facing", fl_value_new_string("external"));
      fl_value_append_take(list, map);
    }
    close(fd);
  }
  return list;
}

// ------------------------------------------------------------- format

struct Format {
  uint32_t pixel = 0;
  uint32_t width = 0;
  uint32_t height = 0;
};

bool is_jpeg(uint32_t pixel) {
  return pixel == V4L2_PIX_FMT_MJPEG || pixel == V4L2_PIX_FMT_JPEG;
}

// Picks the mode closest to the wanted size. MJPEG is preferred (the camera
// compresses, nothing to do here), then YUYV.
Format choose_format(int fd, const Settings& s) {
  Format best;
  long long best_score = -1;
  const long long want = static_cast<long long>(s.width) * s.height;
  v4l2_fmtdesc desc = {};
  desc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  for (desc.index = 0; xioctl(fd, VIDIOC_ENUM_FMT, &desc) == 0; desc.index++) {
    const uint32_t pixel = desc.pixelformat;
    if (!is_jpeg(pixel) && pixel != V4L2_PIX_FMT_YUYV) continue;
    std::vector<std::pair<uint32_t, uint32_t>> sizes;
    v4l2_frmsizeenum size = {};
    size.pixel_format = pixel;
    for (size.index = 0; xioctl(fd, VIDIOC_ENUM_FRAMESIZES, &size) == 0;
         size.index++) {
      if (size.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
        sizes.emplace_back(size.discrete.width, size.discrete.height);
      } else {
        // Stepwise / continuous: the driver adjusts the wanted size.
        sizes.emplace_back(static_cast<uint32_t>(s.width),
                           static_cast<uint32_t>(s.height));
        break;
      }
    }
    if (sizes.empty()) {
      sizes.emplace_back(static_cast<uint32_t>(s.width),
                         static_cast<uint32_t>(s.height));
    }
    for (const auto& wh : sizes) {
      const long long area = static_cast<long long>(wh.first) * wh.second;
      long long score = std::llabs(area - want);
      if (area < want) score += 1000000;  // Rather scale down than up.
      if (!is_jpeg(pixel)) score += 1000;  // Needs converting here.
      if (best_score < 0 || score < best_score) {
        best_score = score;
        best = {pixel, wh.first, wh.second};
      }
    }
  }
  return best;
}

// ------------------------------------------------------------- pictures

inline uint8_t clamp8(int v) {
  return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// YUYV (4:2:2) to a JPEG, scaled down to |max_width| when larger.
bool encode_yuyv(const uint8_t* data, uint32_t width, uint32_t height,
                 uint32_t stride, int max_width, int quality,
                 std::vector<uint8_t>* out) {
  if (width < 2 || height == 0) return false;
  GdkPixbuf* pixbuf =
      gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, static_cast<int>(width),
                     static_cast<int>(height));
  if (pixbuf == nullptr) return false;
  const int rowstride = gdk_pixbuf_get_rowstride(pixbuf);
  guchar* pixels = gdk_pixbuf_get_pixels(pixbuf);
  for (uint32_t y = 0; y < height; y++) {
    const uint8_t* src = data + static_cast<size_t>(y) * stride;
    guchar* dst = pixels + static_cast<size_t>(y) * rowstride;
    for (uint32_t x = 0; x + 1 < width; x += 2) {
      const int y0 = src[0] - 16, u = src[1] - 128, y1 = src[2] - 16,
                v = src[3] - 128;
      const int r = 409 * v + 128, g = -100 * u - 208 * v + 128,
                b = 516 * u + 128;
      dst[0] = clamp8((298 * y0 + r) >> 8);
      dst[1] = clamp8((298 * y0 + g) >> 8);
      dst[2] = clamp8((298 * y0 + b) >> 8);
      dst[3] = clamp8((298 * y1 + r) >> 8);
      dst[4] = clamp8((298 * y1 + g) >> 8);
      dst[5] = clamp8((298 * y1 + b) >> 8);
      src += 4;
      dst += 6;
    }
  }
  if (static_cast<int>(width) > max_width + max_width / 4) {
    const int h = std::max(1, static_cast<int>(
                                  static_cast<long long>(height) * max_width /
                                  width));
    GdkPixbuf* scaled =
        gdk_pixbuf_scale_simple(pixbuf, max_width, h, GDK_INTERP_BILINEAR);
    g_object_unref(pixbuf);
    if (scaled == nullptr) return false;
    pixbuf = scaled;
  }
  gchar* buffer = nullptr;
  gsize size = 0;
  g_autofree gchar* q = g_strdup_printf("%d", quality);
  GError* error = nullptr;
  const gboolean ok = gdk_pixbuf_save_to_buffer(
      pixbuf, &buffer, &size, "jpeg", &error, "quality", q, nullptr);
  g_object_unref(pixbuf);
  if (!ok) {
    if (error != nullptr) {
      g_warning("JPEG encoding failed: %s", error->message);
      g_error_free(error);
    }
    return false;
  }
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(buffer);
  out->assign(bytes, bytes + size);
  g_free(buffer);
  return true;
}

// ----------------------------------------------- worker -> main thread

gboolean deliver_started(gpointer) {
  std::string error;
  {
    std::lock_guard<std::mutex> lock(cam.mutex);
    if (!cam.start_ready) return G_SOURCE_REMOVE;
    cam.start_ready = false;
    error = cam.start_error;
  }
  if (!error.empty()) {
    cam.running = false;
    if (cam.thread.joinable()) cam.thread.join();
  }
  if (cam.pending_start != nullptr) {
    if (error.empty()) {
      fl_method_call_respond_success(cam.pending_start, nullptr, nullptr);
    } else {
      fl_method_call_respond_error(cam.pending_start, "camera", error.c_str(),
                                   nullptr, nullptr);
    }
    g_clear_object(&cam.pending_start);
  }
  return G_SOURCE_REMOVE;
}

gboolean deliver_frame(gpointer) {
  std::vector<uint8_t> jpeg;
  {
    std::lock_guard<std::mutex> lock(cam.mutex);
    cam.frame_posted = false;
    if (!cam.has_latest) return G_SOURCE_REMOVE;
    jpeg.swap(cam.latest);
    cam.has_latest = false;
  }
  if (!cam.listening || !cam.running) return G_SOURCE_REMOVE;
  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "jpeg",
                           fl_value_new_uint8_list(jpeg.data(), jpeg.size()));
  fl_value_set_string_take(event, "rotation", fl_value_new_int(0));
  // Shown like a mirror in the self-view (webcams face the user).
  fl_value_set_string_take(event, "mirror", fl_value_new_bool(TRUE));
  fl_event_channel_send(cam.events, event, nullptr, nullptr);
  return G_SOURCE_REMOVE;
}

gboolean deliver_error(gpointer) {
  std::string error;
  {
    std::lock_guard<std::mutex> lock(cam.mutex);
    if (!cam.has_error) return G_SOURCE_REMOVE;
    cam.has_error = false;
    error = cam.error;
  }
  cam.running = false;
  if (cam.thread.joinable()) cam.thread.join();
  if (cam.listening) {
    fl_event_channel_send_error(cam.events, "camera", error.c_str(), nullptr,
                                nullptr, nullptr);
  }
  return G_SOURCE_REMOVE;
}

void post_started(const std::string& error) {
  {
    std::lock_guard<std::mutex> lock(cam.mutex);
    cam.start_error = error;
    cam.start_ready = true;
  }
  g_idle_add(deliver_started, nullptr);
}

void post_error(const std::string& error) {
  {
    std::lock_guard<std::mutex> lock(cam.mutex);
    cam.error = error;
    cam.has_error = true;
  }
  g_idle_add(deliver_error, nullptr);
}

void post_frame(std::vector<uint8_t> jpeg) {
  bool post = false;
  {
    std::lock_guard<std::mutex> lock(cam.mutex);
    cam.latest = std::move(jpeg);
    cam.has_latest = true;
    post = !cam.frame_posted;
    cam.frame_posted = true;
  }
  if (post) g_idle_add(deliver_frame, nullptr);
}

// ------------------------------------------------------------- capture

struct Buffer {
  void* start = MAP_FAILED;
  size_t length = 0;
};

void capture_thread(Settings s) {
  std::string error;
  std::vector<Buffer> buffers;
  const int fd = open(s.path.c_str(), O_RDWR | O_NONBLOCK);
  if (fd < 0) error = open_error(errno);

  Format f;
  uint32_t stride = 0;
  if (error.empty()) {
    if (!is_capture_device(fd, nullptr)) {
      error = "Not a camera: " + s.path;
    } else {
      f = choose_format(fd, s);
      if (f.pixel == 0) error = "The camera has no supported picture format";
    }
  }
  if (error.empty()) {
    v4l2_format fmt = {};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = f.width;
    fmt.fmt.pix.height = f.height;
    fmt.fmt.pix.pixelformat = f.pixel;
    fmt.fmt.pix.field = V4L2_FIELD_ANY;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) != 0) {
      error = errno == EBUSY ? open_error(EBUSY)
                             : std::string("Camera format: ") + strerror(errno);
    } else {
      f = {fmt.fmt.pix.pixelformat, fmt.fmt.pix.width, fmt.fmt.pix.height};
      stride = fmt.fmt.pix.bytesperline ? fmt.fmt.pix.bytesperline
                                        : f.width * 2;
      if (!is_jpeg(f.pixel) && f.pixel != V4L2_PIX_FMT_YUYV) {
        error = "The camera has no supported picture format";
      }
    }
  }
  if (error.empty()) {
    // Ask for the wanted rate; the driver picks the closest it has.
    v4l2_streamparm parm = {};
    parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    parm.parm.capture.timeperframe.numerator = 1;
    parm.parm.capture.timeperframe.denominator =
        static_cast<uint32_t>(std::max(s.fps, 15));
    xioctl(fd, VIDIOC_S_PARM, &parm);  // Best effort.

    v4l2_requestbuffers req = {};
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) != 0 || req.count < 2) {
      error = errno == EBUSY ? open_error(EBUSY)
                             : "The camera can't stream pictures";
    }
    for (uint32_t i = 0; error.empty() && i < req.count; i++) {
      v4l2_buffer buf = {};
      buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
      buf.memory = V4L2_MEMORY_MMAP;
      buf.index = i;
      if (xioctl(fd, VIDIOC_QUERYBUF, &buf) != 0) {
        error = "The camera can't stream pictures";
        break;
      }
      Buffer b;
      b.length = buf.length;
      b.start = mmap(nullptr, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED,
                     fd, buf.m.offset);
      if (b.start == MAP_FAILED) {
        error = "The camera can't stream pictures";
        break;
      }
      buffers.push_back(b);
      if (xioctl(fd, VIDIOC_QBUF, &buf) != 0) {
        error = "The camera can't stream pictures";
      }
    }
    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (error.empty() && xioctl(fd, VIDIOC_STREAMON, &type) != 0) {
      error = errno == EBUSY ? open_error(EBUSY)
                             : std::string("Camera: ") + strerror(errno);
    }
  }
  post_started(error);

  if (error.empty()) {
    const auto interval = std::chrono::milliseconds(1000 / s.fps);
    auto last = std::chrono::steady_clock::now() - interval;
    while (cam.running) {
      fd_set fds;
      FD_ZERO(&fds);
      FD_SET(fd, &fds);
      timeval tv = {0, 200000};  // Check |running| often.
      const int r = select(fd + 1, &fds, nullptr, nullptr, &tv);
      if (r < 0) {
        if (errno == EINTR) continue;
        error = std::string("Camera: ") + strerror(errno);
        break;
      }
      if (r == 0) continue;
      v4l2_buffer buf = {};
      buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
      buf.memory = V4L2_MEMORY_MMAP;
      if (xioctl(fd, VIDIOC_DQBUF, &buf) != 0) {
        if (errno == EAGAIN) continue;
        error = errno == ENODEV ? open_error(ENODEV)
                                : std::string("Camera: ") + strerror(errno);
        break;
      }
      const auto now = std::chrono::steady_clock::now();
      if (now - last >= interval && buf.index < buffers.size() &&
          !(buf.flags & V4L2_BUF_FLAG_ERROR)) {
        last = now;
        const uint8_t* data =
            static_cast<const uint8_t*>(buffers[buf.index].start);
        const size_t used = std::min<size_t>(buf.bytesused,
                                             buffers[buf.index].length);
        std::vector<uint8_t> jpeg;
        if (is_jpeg(f.pixel)) {
          // Already a JPEG; skip broken or oversized pictures.
          if (used > 4 && used <= kMaxJpeg && data[0] == 0xFF &&
              data[1] == 0xD8) {
            jpeg.assign(data, data + used);
          }
        } else if (used >= static_cast<size_t>(stride) * f.height) {
          encode_yuyv(data, f.width, f.height, stride, s.width, s.quality,
                      &jpeg);
        }
        if (!jpeg.empty()) post_frame(std::move(jpeg));
      }
      xioctl(fd, VIDIOC_QBUF, &buf);
    }
    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    xioctl(fd, VIDIOC_STREAMOFF, &type);
    if (cam.running && !error.empty()) post_error(error);
  }

  for (auto& b : buffers) {
    if (b.start != MAP_FAILED) munmap(b.start, b.length);
  }
  if (fd >= 0) close(fd);
}

// ------------------------------------------------------------- channels

void stop_camera() {
  cam.running = false;
  if (cam.thread.joinable()) cam.thread.join();
  {
    std::lock_guard<std::mutex> lock(cam.mutex);
    cam.latest.clear();
    cam.has_latest = false;
    cam.start_ready = false;
    cam.has_error = false;
  }
  if (cam.pending_start != nullptr) {
    fl_method_call_respond_error(cam.pending_start, "camera", "Stopped",
                                 nullptr, nullptr);
    g_clear_object(&cam.pending_start);
  }
}

int arg_int(FlValue* args, const char* key, int fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return fallback;
  }
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_INT) {
    return fallback;
  }
  return static_cast<int>(fl_value_get_int(v));
}

void on_method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (strcmp(method, "requestPermission") == 0) {
    // Linux has no prompt; missing access is reported when opening.
    g_autoptr(FlValue) yes = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(call, yes, nullptr);
  } else if (strcmp(method, "list") == 0) {
    g_autoptr(FlValue) list = list_devices();
    fl_method_call_respond_success(call, list, nullptr);
  } else if (strcmp(method, "start") == 0) {
    stop_camera();
    Settings s;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* id = fl_value_lookup_string(args, "id");
      if (id != nullptr && fl_value_get_type(id) == FL_VALUE_TYPE_STRING) {
        s.path = fl_value_get_string(id);
      }
    }
    s.width = std::max(160, arg_int(args, "width", s.width));
    s.height = std::max(120, arg_int(args, "height", s.height));
    s.fps = std::min(30, std::max(1, arg_int(args, "fps", s.fps)));
    s.quality = std::min(95, std::max(30, arg_int(args, "quality", s.quality)));
    if (s.path.empty()) {
      fl_method_call_respond_error(call, "camera", "No camera chosen", nullptr,
                                   nullptr);
      return;
    }
    cam.pending_start = FL_METHOD_CALL(g_object_ref(call));
    cam.running = true;
    cam.thread = std::thread(capture_thread, s);
  } else if (strcmp(method, "stop") == 0) {
    stop_camera();
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

FlMethodErrorResponse* on_listen(FlEventChannel*, FlValue*, gpointer) {
  cam.listening = true;
  return nullptr;
}

FlMethodErrorResponse* on_cancel(FlEventChannel*, FlValue*, gpointer) {
  cam.listening = false;
  return nullptr;
}

}  // namespace

void camera_capture_init(FlView* view) {
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  cam.methods = fl_method_channel_new(messenger, "p2p_intercom/camera",
                                      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(cam.methods, on_method_call,
                                            nullptr, nullptr);
  cam.events = fl_event_channel_new(messenger, "p2p_intercom/camera/frames",
                                    FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(cam.events, on_listen, on_cancel,
                                       nullptr, nullptr);
}
