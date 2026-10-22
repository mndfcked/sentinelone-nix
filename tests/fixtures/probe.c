#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PROBE_VERSION
#define PROBE_VERSION "A"
#endif

extern int fixture_value(void);

static int start_child(void) {
  pid_t child = fork();
  if (child < 0) {
    perror("fork");
    return 1;
  }

  if (child == 0) {
    execl("/opt/sentinelone/bin/distro-child", "distro-child", "service", (char *)NULL);
    perror("exec distro child");
    _exit(127);
  }

  FILE *pid_file = fopen("/run/sentinelone-runtime-child.pid", "w");
  if (pid_file == NULL) {
    perror("open child pid file");
    return 1;
  }
  fprintf(pid_file, "%ld\n", (long)child);
  fclose(pid_file);
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "service") == 0) {
    int value = fixture_value();
    printf("RUNTIME_VERSION=%s VALUE=%d\n", PROBE_VERSION, value);
    fflush(stdout);
    if (value != 45 || start_child() != 0) {
      return 1;
    }
    for (;;) {
      pause();
    }
  }

  if (argc > 1 && strcmp(argv[1], "child") == 0) {
    execl("/opt/sentinelone/bin/distro-child", "distro-child", "check", (char *)NULL);
    perror("exec distro child");
    return 127;
  }

  if (argc > 1 && strcmp(argv[1], "exec") == 0 && argc > 2) {
    execv(argv[2], &argv[2]);
    perror("exec trusted Nix child");
    return 127;
  }

  int value = fixture_value();
  printf("FIXTURE_VALUE=%d\n", value);
  return value == 45 ? 0 : 1;
}
