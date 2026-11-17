#include <stdio.h>

/* A block comment
   over two lines. */
struct point {
  int x;
  int y;
};

static int sum (int a,
                int b)
{
  if (a > b)
    {
      return a + b;
    }
  return b;
}

#ifdef DEBUG
int debug = 1;
#endif
