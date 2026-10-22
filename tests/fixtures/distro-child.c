#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern int fixture_value(void);

int main(int argc, char **argv) {
  int value = fixture_value();
  printf("DISTRO_CHILD_VALUE=%d\n", value);
  fflush(stdout);

  if (argc > 1 && strcmp(argv[1], "service") == 0) {
    for (;;) {
      pause();
    }
  }

  return value == 45 ? 0 : 1;
}
