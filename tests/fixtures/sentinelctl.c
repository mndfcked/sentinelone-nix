#include <stdio.h>

extern int fixture_value(void);

int main(void) {
  int value = fixture_value();
  printf("ADMIN_VALUE=%d\n", value);
  return value == 45 ? 0 : 1;
}
