#ifndef RUNNER_WINDOW_TRAY_H_
#define RUNNER_WINDOW_TRAY_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// System tray icon for Linux, like the Windows one (windows/runner/
// flutter_window.cpp), behind the same "gundil/window" channel used by
// lib/src/window_bridge.dart:
// * minimize and the close button hide the window to the tray (unless the
//   user turned "Minimize to tray" off),
// * the tray menu shows the status (who is speaking) with Open / Exit,
// * "notify" shows a desktop notification while the window is hidden.
//
// The icon uses the StatusNotifierItem protocol through libayatana-
// appindicator3 (or libappindicator3), loaded at run time. Without the
// library, or without a tray on the desktop (plain GNOME needs the
// AppIndicator extension), nothing hides: the app behaves like a normal
// window and closing it quits.

// Call once, right after creating the window and before adding the Flutter
// view (the close handler must run before the embedder's own).
void window_tray_init(GtkApplication* app, GtkWindow* window);

// Call once the Flutter view exists: sets up the "gundil/window" channel.
void window_tray_attach_view(FlView* view);

// Whether a tray icon can be shown right now.
gboolean window_tray_available();

// Shows the window again (tray menu, notification click, second launch).
void window_tray_present();

#endif  // RUNNER_WINDOW_TRAY_H_
