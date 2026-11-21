/* A C file in the GNU style: return types on their own line. */

#include <stddef.h>

#define WIDGET_MAX 16
#define WIDGET_SIZE(w) ((w)->n * 2)

/* A widget.  */
struct widget
{
  int n;
  struct widget *next;
};

typedef struct widget widget_t;

enum widget_kind { WIDGET_SMALL, WIDGET_LARGE };

static int widget_count;

/* Make a widget of N.  */
static struct widget *
make_widget (int n)
{
  static struct widget w;
  w.n = n;
  widget_count++;
  return &w;
}

int
widget_total (const struct widget *w)
{
  int t = 0;
  for (; w; w = w->next)
    t += WIDGET_SIZE (w);
  return t;
}
