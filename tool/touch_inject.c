// Fake touchscreen for the e2e scripts (tool/e2e_touch_linux.sh and others).
// Preloaded into the release build, it reads commands appended to
// $TOUCH_INJECT_FILE and turns each into
// a GdkEventTouch dispatched through gtk_main_do_event, so a touch travels
// the same road a finger does from GTK onwards: GTK's event dispatch, the
// Flutter engine's touch manager, the framework, and the app. Xvfb has no
// touch devices and the container has no uinput, so this is as close to a
// real finger as the e2e run gets; the kernel and libinput are not covered.
//
// One command per line, coordinates in logical pixels within the Flutter
// view:  down <finger> <x> <y>  |  move <finger> <x> <y>  |  up <finger> <x> <y>
//
//   cc -shared -fPIC -o touch_inject.so tool/touch_inject.c $(pkg-config --cflags --libs gtk+-3.0)
#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>

static long offset = 0;

static void find_event_box(GtkWidget* w, gpointer out) {
  if (*(GtkWidget**)out) return;
  if (GTK_IS_EVENT_BOX(w)) {
    *(GtkWidget**)out = w;
    return;
  }
  if (GTK_IS_CONTAINER(w)) gtk_container_forall(GTK_CONTAINER(w), find_event_box, out);
}

static GtkWidget* target(void) {
  GtkWidget* box = NULL;
  GList* tops = gtk_window_list_toplevels();
  for (GList* l = tops; l && !box; l = l->next) find_event_box(GTK_WIDGET(l->data), &box);
  g_list_free(tops);
  return box && gtk_widget_get_realized(box) ? box : NULL;
}

static void inject(GdkEventType type, guint finger, double x, double y) {
  GtkWidget* box = target();
  if (!box) {
    g_warning("touch_inject: no Flutter view yet");
    return;
  }
  GdkWindow* window = gtk_widget_get_window(box);
  // A real touchscreen only sends touches to a window that asks for them;
  // otherwise X and Wayland turn the finger into mouse clicks, which the
  // reader ignores. Say once whether the Flutter view asks.
  static gboolean told = FALSE;
  if (!told) {
    told = TRUE;
    g_message("touch_inject: the Flutter view %s touch events",
              gtk_widget_get_events(box) & GDK_TOUCH_MASK ? "selects" : "does NOT select");
  }
  GdkDevice* device = gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_window_get_display(window)));
  gint ox = 0, oy = 0;
  gdk_window_get_origin(window, &ox, &oy);

  GdkEvent* e = gdk_event_new(type);
  e->touch.window = g_object_ref(window);
  e->touch.send_event = FALSE;
  e->touch.time = (guint32)(g_get_monotonic_time() / 1000);
  e->touch.x = x;
  e->touch.y = y;
  e->touch.x_root = ox + x;
  e->touch.y_root = oy + y;
  e->touch.sequence = (GdkEventSequence*)GUINT_TO_POINTER(finger);
  e->touch.emulating_pointer = FALSE;
  gdk_event_set_device(e, device);
  gdk_event_set_source_device(e, device);
  gtk_main_do_event(e);
  gdk_event_free(e);
}

static gboolean poll_commands(gpointer unused) {
  const char* path = g_getenv("TOUCH_INJECT_FILE");
  FILE* f = path ? fopen(path, "r") : NULL;
  if (!f) return G_SOURCE_CONTINUE;
  fseek(f, offset, SEEK_SET);
  char line[128];
  while (fgets(line, sizeof line, f)) {
    if (!strchr(line, '\n')) break;  // Half-written; read it next time.
    offset = ftell(f);
    char cmd[8];
    guint finger;
    double x, y;
    if (sscanf(line, "%7s %u %lf %lf", cmd, &finger, &x, &y) != 4) continue;
    GdkEventType type = !strcmp(cmd, "down")   ? GDK_TOUCH_BEGIN
                        : !strcmp(cmd, "move") ? GDK_TOUCH_UPDATE
                        : !strcmp(cmd, "up")   ? GDK_TOUCH_END
                                               : GDK_NOTHING;
    if (type != GDK_NOTHING) inject(type, finger + 1, x, y);  // Sequence 0 would read as "no touch".
  }
  fclose(f);
  return G_SOURCE_CONTINUE;
}

__attribute__((constructor)) static void start(void) {
  if (g_getenv("TOUCH_INJECT_FILE")) g_timeout_add(10, poll_commands, NULL);
}
