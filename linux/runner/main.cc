#include <cstdio>
#include <cstring>
#include <unistd.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // Answered before GTK starts, so it works without a display.
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--version") == 0) {
      printf("comicredr %s\n", APP_VERSION);
      return 0;
    }
  }
  MyApplication* app = my_application_new();
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  // By now the app has saved everything: the window's close waits for the
  // reading position and the sidecars to be written. Leave without running
  // the libraries' exit handlers, because Flutter's raster thread can still
  // be compiling a shader in the GL driver (Mesa's llvmpipe, for one) and
  // tearing LLVM and EGL down under it segfaults. Seen on windows closed
  // in the first seconds after launch.
  fflush(stdout);
  fflush(stderr);
  _exit(status);
}
