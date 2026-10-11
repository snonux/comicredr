#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  // org.snonux.comicredr/window: the reader asks for fullscreen through it,
  // and hears back when the window manager changes it.
  FlMethodChannel* window_channel;
  gboolean fullscreen;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// setFullscreen(bool): the window covers the whole screen with no title bar
// or header bar (GTK hides a header bar in fullscreen), or comes back.
static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  FlValue* args = fl_method_call_get_args(call);
  if (g_strcmp0(fl_method_call_get_name(call), "setFullscreen") == 0 &&
      args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
    if (fl_value_get_bool(args)) {
      gtk_window_fullscreen(self->window);
    } else {
      gtk_window_unfullscreen(self->window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Tells the reader when the window manager takes the window in or out of
// fullscreen by itself, so the two never disagree.
static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (!(event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN)) return FALSE;
  gboolean full = (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
  if (full == self->fullscreen) return FALSE;
  self->fullscreen = full;
  if (self->window_channel != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_bool(full);
    fl_method_channel_invoke_method(self->window_channel, "fullscreenChanged",
                                    value, nullptr, nullptr, nullptr);
  }
  return FALSE;
}

// GTK's window close does not send Flutter an app-exit request. Keep the
// window and its Dart isolate alive until the reader has flushed its sidecar.
struct CloseRequest {
  MyApplication* application;
  GtkWidget* window;
};

static gboolean close_window_idle(gpointer user_data) {
  CloseRequest* request = static_cast<CloseRequest*>(user_data);
  if (g_object_get_data(G_OBJECT(request->window), "comicredr-destroyed") == nullptr) {
    gtk_widget_destroy(request->window);
  }
  g_object_unref(request->window);
  g_object_unref(request->application);
  g_free(request);
  return G_SOURCE_REMOVE;
}

static void close_flushed_cb(GObject* object, GAsyncResult* result,
                             gpointer user_data) {
  CloseRequest* request = static_cast<CloseRequest*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  if (response == nullptr) {
    g_warning("Could not flush before closing: %s",
              error == nullptr ? "no response" : error->message);
  } else {
    fl_method_response_get_result(response, &error);
    if (error != nullptr) g_warning("Could not flush before closing: %s", error->message);
  }
  if (response != nullptr && error == nullptr) {
    g_debug("ComicRedr reader flushed before window close");
  }
  // The response callback runs inside Flutter's messenger. Tearing its view
  // down here reenters engine disposal (and can abort in g_mutex_clear).
  g_idle_add(close_window_idle, request);
}

static gboolean window_delete_cb(GtkWidget* widget, GdkEvent* event,
                                 gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  // A stalled Dart flush must not trap the window. A second close request
  // explicitly gives up waiting; the pending reply then only releases refs.
  if (g_object_get_data(G_OBJECT(widget), "comicredr-closing") != nullptr) {
    g_debug("ComicRedr second close forced window destruction");
    gtk_widget_destroy(widget);
    return TRUE;
  }
  gpointer channel_data = g_object_get_data(G_OBJECT(widget), "comicredr-window-channel");
  if (channel_data == nullptr) return FALSE;
  FlMethodChannel* channel = FL_METHOD_CHANNEL(channel_data);
  g_object_set_data(G_OBJECT(widget), "comicredr-closing", GINT_TO_POINTER(1));
  // The flush snapshots the reader's current position. Stop further key,
  // pointer and touch input from reaching Flutter while it is in flight;
  // the window manager's close request can still force the second close.
  GtkWidget* view = gtk_bin_get_child(GTK_BIN(widget));
  if (view != nullptr) gtk_widget_set_sensitive(view, FALSE);
  CloseRequest* request = g_new0(CloseRequest, 1);
  request->application = MY_APPLICATION(g_object_ref(self));
  request->window = GTK_WIDGET(g_object_ref(widget));
  fl_method_channel_invoke_method(channel, "beforeClose", nullptr, nullptr,
                                  close_flushed_cb, request);
  return TRUE;
}

static void window_destroy_cb(GtkWidget* widget, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_object_set_data(G_OBJECT(widget), "comicredr-destroyed", GINT_TO_POINTER(1));
  if (self->window == GTK_WINDOW(widget)) self->window = nullptr;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_cb), self);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroy_cb), self);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "ComicRedr");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "ComicRedr");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // The window icon: the theme's copy once `make install` has put it there,
  // otherwise the PNG CMake copies into the bundle, so a bare build or a
  // copied bundle still shows it.
  if (gtk_icon_theme_has_icon(gtk_icon_theme_get_default(), APPLICATION_ID)) {
    gtk_window_set_icon_name(window, APPLICATION_ID);
  } else {
    g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
    if (exe != nullptr) {
      g_autofree gchar* dir = g_path_get_dirname(exe);
      g_autofree gchar* icon =
          g_build_filename(dir, "data", APPLICATION_ID ".png", nullptr);
      gtk_window_set_icon_from_file(window, icon, nullptr);
    }
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->window_channel);
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "org.snonux.comicredr/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel,
                                            window_method_cb, self, nullptr);
  g_object_set_data_full(G_OBJECT(window), "comicredr-window-channel",
                         g_object_ref(self->window_channel), g_object_unref);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
