#include <cstdio>
#include <cstring>

#include "my_application.h"

int main(int argc, char** argv) {
  // Answered before GTK starts, so it works without a display.
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--version") == 0) {
      printf("comicredr %s\n", APP_VERSION);
      return 0;
    }
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
