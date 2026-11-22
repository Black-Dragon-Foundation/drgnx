/* Smiðja, the workbench model: its C ABI (nidhogg/smidja; README.md, "The door").
   C passes an op and its arguments as flat values and builds the Lisp value from the answer; Smiðja never sees a Lisp
   object and never calls Emacs.  Call only on the thread that holds Emacs's global lock.  */

#ifndef SMIDJA_H
#define SMIDJA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Codes.  */
#define SMIDJA_OK 0
#define SMIDJA_E_PANIC (-1)
#define SMIDJA_E_ARG (-2)
#define SMIDJA_E_OP (-3)

/* Value tags.  A list's INT_ counts the values that follow it (prefix order).  */
#define SMIDJA_NIL 0
#define SMIDJA_INT 1
#define SMIDJA_STR 2
#define SMIDJA_LIST 3
#define SMIDJA_SYM 4
#define SMIDJA_FLOAT 5

typedef struct
{
  int32_t tag;
  int64_t int_;
  double float_;
  const unsigned char *ptr;
  size_t len;
} smidja_val;

/* The number of the op named by the LEN bytes at NAME ("open", "set_edges"; `-' may stand for `_'), or -1.  */
int32_t smidja_op (const unsigned char *name, size_t len);

/* One call: OP on the N values at ARGS; on SMIDJA_OK *NOUT values are at *OUT (prefix order), valid until the next
   call on this thread.  A refused intent is an answer, (refused REASON).  */
int32_t smidja_call (int32_t op, const smidja_val *args, size_t n, const smidja_val **out, size_t *nout);

#ifdef __cplusplus
}
#endif

#endif /* SMIDJA_H */
