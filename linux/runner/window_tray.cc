#include "window_tray.h"

#include <dlfcn.h>
#include <string.h>

namespace {

// libappindicator3 API (loaded with dlopen; see window_tray.h).
constexpr int kCategoryCommunications = 1;  // APP_INDICATOR_CATEGORY_...
constexpr int kStatusActive = 1;            // APP_INDICATOR_STATUS_ACTIVE

using NewWithPathFn = void* (*)(const gchar* id, const gchar* icon_name,
                                int category, const gchar* icon_theme_path);
using SetStatusFn = void (*)(void* indicator, int status);
using SetMenuFn = void (*)(void* indicator, GtkMenu* menu);
using SetTitleFn = void (*)(void* indicator, const gchar* title);
using SetSecondaryFn = void (*)(void* indicator, GtkWidget* item);

constexpr char kWatcherName[] = "org.kde.StatusNotifierWatcher";
constexpr char kIconName[] = "gundil-intercom";

struct Tray {
  GtkApplication* app = nullptr;
  GtkWindow* window = nullptr;
  FlMethodChannel* channel = nullptr;

  void* indicator = nullptr;
  SetTitleFn set_title = nullptr;
  GtkWidget* status_item = nullptr;

  // A tray (StatusNotifierWatcher) is running on the desktop.
  gboolean watcher = FALSE;
  // "Minimize to tray" setting (from Dart).
  gboolean enabled = TRUE;
  // "Exit" was chosen: the next close really quits.
  gboolean quitting = FALSE;
  gboolean hint_shown = FALSE;
  gchar* icon_path = nullptr;
};

Tray tray;

gboolean tray_active() {
  return tray.indicator != nullptr && tray.watcher && tray.enabled;
}

gboolean window_shown() {
  GtkWidget* w = GTK_WIDGET(tray.window);
  if (!gtk_widget_get_visible(w)) return FALSE;
  GdkWindow* gdk = gtk_widget_get_window(w);
  return gdk == nullptr ||
         (gdk_window_get_state(gdk) & GDK_WINDOW_STATE_ICONIFIED) == 0;
}

void send_notification(const gchar* title, const gchar* body) {
  g_autoptr(GNotification) n = g_notification_new(title);
  g_notification_set_body(n, body);
  if (tray.icon_path != nullptr) {
    g_autoptr(GFile) file = g_file_new_for_path(tray.icon_path);
    g_autoptr(GIcon) icon = g_file_icon_new(file);
    g_notification_set_icon(n, icon);
  }
  g_application_send_notification(G_APPLICATION(tray.app), "gundil-status", n);
}

void hide_to_tray() {
  gtk_widget_hide(GTK_WIDGET(tray.window));
  if (!tray.hint_shown) {
    tray.hint_shown = TRUE;
    send_notification("Gundil Intercom is still running",
                      "It keeps receiving in the background. Open it from "
                      "the tray icon, or choose Exit there to quit.");
  }
}

gboolean hide_idle(gpointer) {
  if (tray_active()) hide_to_tray();
  return G_SOURCE_REMOVE;
}

// Close button: hide instead of quitting while the tray is on.
gboolean on_delete(GtkWidget*, GdkEvent*, gpointer) {
  if (tray.quitting || !tray_active()) return FALSE;  // Quit as usual.
  hide_to_tray();
  return TRUE;
}

// Minimize: hide to the tray (X11; Wayland doesn't report minimizing).
gboolean on_window_state(GtkWidget*, GdkEventWindowState* event, gpointer) {
  if ((event->changed_mask & GDK_WINDOW_STATE_ICONIFIED) &&
      (event->new_window_state & GDK_WINDOW_STATE_ICONIFIED) &&
      tray_active()) {
    g_idle_add(hide_idle, nullptr);
  }
  return FALSE;
}

void on_open(GtkMenuItem*, gpointer) { window_tray_present(); }

void on_exit(GtkMenuItem*, gpointer) {
  tray.quitting = TRUE;
  gtk_widget_destroy(GTK_WIDGET(tray.window));  // Last window: app quits.
}

void on_watcher_appeared(GDBusConnection*, const gchar*, const gchar*,
                         gpointer) {
  tray.watcher = TRUE;
}

void on_watcher_vanished(GDBusConnection*, const gchar*, gpointer) {
  tray.watcher = FALSE;
  // The tray went away (panel restarted, extension turned off): never leave
  // the window hidden with no way to get it back.
  if (!gtk_widget_get_visible(GTK_WIDGET(tray.window))) {
    window_tray_present();
  }
}

gboolean watcher_running() {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) return FALSE;
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", kWatcherName),
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  if (reply == nullptr) return FALSE;
  gboolean has_owner = FALSE;
  g_variant_get(reply, "(b)", &has_owner);
  return has_owner;
}

void create_indicator(const gchar* icon_dir) {
  void* lib = dlopen("libayatana-appindicator3.so.1", RTLD_LAZY);
  if (lib == nullptr) lib = dlopen("libappindicator3.so.1", RTLD_LAZY);
  if (lib == nullptr) {
    g_message("No libayatana-appindicator3: tray icon disabled");
    return;
  }
  auto new_with_path = reinterpret_cast<NewWithPathFn>(
      dlsym(lib, "app_indicator_new_with_path"));
  auto set_status =
      reinterpret_cast<SetStatusFn>(dlsym(lib, "app_indicator_set_status"));
  auto set_menu =
      reinterpret_cast<SetMenuFn>(dlsym(lib, "app_indicator_set_menu"));
  auto set_secondary = reinterpret_cast<SetSecondaryFn>(
      dlsym(lib, "app_indicator_set_secondary_activate_target"));
  tray.set_title =
      reinterpret_cast<SetTitleFn>(dlsym(lib, "app_indicator_set_title"));
  if (new_with_path == nullptr || set_status == nullptr ||
      set_menu == nullptr) {
    g_message("Incomplete appindicator library: tray icon disabled");
    return;
  }

  GtkWidget* menu = gtk_menu_new();
  tray.status_item = gtk_menu_item_new_with_label("Gundil Intercom");
  gtk_widget_set_sensitive(tray.status_item, FALSE);
  GtkWidget* open = gtk_menu_item_new_with_mnemonic("_Open Gundil Intercom");
  GtkWidget* exit = gtk_menu_item_new_with_mnemonic("E_xit");
  g_signal_connect(open, "activate", G_CALLBACK(on_open), nullptr);
  g_signal_connect(exit, "activate", G_CALLBACK(on_exit), nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), tray.status_item);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), open);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), exit);
  gtk_widget_show_all(menu);

  tray.indicator = new_with_path("gundil-intercom", kIconName,
                                 kCategoryCommunications, icon_dir);
  if (tray.indicator == nullptr) return;
  set_menu(tray.indicator, GTK_MENU(menu));
  // Middle click (and a plain click on some panels) opens the window.
  if (set_secondary != nullptr) set_secondary(tray.indicator, open);
  if (tray.set_title != nullptr) {
    tray.set_title(tray.indicator, "Gundil Intercom");
  }
  set_status(tray.indicator, kStatusActive);
}

void set_status_text(const gchar* text) {
  if (tray.status_item != nullptr) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(tray.status_item), text);
  }
  if (tray.indicator != nullptr && tray.set_title != nullptr) {
    tray.set_title(tray.indicator, text);
  }
}

const gchar* lookup_string(FlValue* map, const gchar* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* v = fl_value_lookup_string(map, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return "";
  return fl_value_get_string(v);
}

void on_method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "setTrayEnabled") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      tray.enabled = fl_value_get_bool(args);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "trayAvailable") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(window_tray_available());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "setTooltip") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
      set_status_text(fl_value_get_string(args));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "notify") == 0) {
    // Only while the window isn't visible (the app shows it itself).
    if (!window_shown()) {
      send_notification(lookup_string(args, "title"),
                        lookup_string(args, "text"));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "show") == 0) {
    window_tray_present();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void window_tray_init(GtkApplication* app, GtkWindow* window) {
  tray.app = app;
  tray.window = window;

  // The icon is installed next to the executable: <bundle>/data/.
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* exe_dir = exe ? g_path_get_dirname(exe) : nullptr;
  g_autofree gchar* icon_dir =
      exe_dir ? g_build_filename(exe_dir, "data", nullptr) : nullptr;
  if (icon_dir != nullptr) {
    tray.icon_path = g_build_filename(icon_dir, "gundil-intercom.png", nullptr);
    gtk_window_set_icon_from_file(window, tray.icon_path, nullptr);
  }

  tray.watcher = watcher_running();
  create_indicator(icon_dir);
  g_bus_watch_name(G_BUS_TYPE_SESSION, kWatcherName,
                   G_BUS_NAME_WATCHER_FLAGS_NONE, on_watcher_appeared,
                   on_watcher_vanished, nullptr, nullptr);

  // Connected before the Flutter view exists, so these run before the
  // embedder's own close handling (which would quit).
  g_signal_connect(window, "delete-event", G_CALLBACK(on_delete), nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(on_window_state),
                   nullptr);
}

void window_tray_attach_view(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  tray.channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "gundil/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(tray.channel, on_method_call,
                                            nullptr, nullptr);
}

gboolean window_tray_available() {
  return tray.indicator != nullptr && tray.watcher;
}

void window_tray_present() {
  if (tray.window == nullptr) return;
  gtk_widget_show(GTK_WIDGET(tray.window));
  gtk_window_deiconify(tray.window);
  gtk_window_present(tray.window);
}
