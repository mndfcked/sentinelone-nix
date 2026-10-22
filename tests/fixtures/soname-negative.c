#include <stdio.h>

extern int required_value(void);

int main(void) {
  printf("REQUIRED_VALUE=%d\n", required_value());
  return required_value() == 9 ? 0 : 1;
}
