#!/usr/bin/env bash
# The pack-built grammars the hub's tests parse with (language packs Task 6a): builds the hub's ten built-in packs'
# grammars with the pack job (`ratatoskr packs sync --builtin`) into CACHE/KEY, KEY being a hash of their pins, and
# prints the two variables a test run needs. An unchanged set of pins reuses the folder; a pin change builds a new one.
# Needs network, git and a C compiler: run it in a container (never on the host). Usage:
#   eval "$(bash test/packs/hub-grammars.sh CACHE)"      # sets DRGNX_PACK_LOCK and DRGNX_PACK_GRAMMARS
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cache=${1:?usage: hub-grammars.sh CACHE}
packs="rust c cpp shell python javascript typescript tsx go java csharp"
# fixtures5: the fixture grammars below are part of the folder, so a change to them is a new key
key=$({ echo fixtures5; for p in $packs json; do grep -ho ':\(commit\|tree-sha256\|src\) "[^"]*"' "$here/packs/$p/pack.eld"; done; } | sha256sum | cut -c1-16)
dir="$cache/$key"

# Two broken grammars for the parse worker's tests (language packs Task 6b): the JSON grammar at its pinned commit with its
# lexer patched, `loopy` to spin for ever and `crashy` to fault, on the first token. They load and report their ABI like
# any grammar, so a parse is what fails: `libloopy.so` and `libcrashy.so`, symbols `tree_sitter_loopy` and
# `tree_sitter_crashy`, under FIXTURES.
# What the `probe` grammar does when its library loads: tries to leave the sandbox, says PROBE ESCAPE WHAT on stderr for each
# way that worked (a secret read, a TCP or Unix connection, 2 GiB of address space) and exits 77 if any did (`PROBE CLEAN` otherwise). Files it
# manages to create (beside the library, in /etc, /usr, /var/tmp) are left, named `PROBE WROTE PATH`: a sandbox may
# give a process a private /var/tmp, so whether a write left the sandbox is for the test to see on the outside. The bait comes in the environment: PROBE_SECRET (a
# file), PROBE_PORT (a TCP listener on 127.0.0.1) and PROBE_SOCK (a Unix socket server).
probe_c() {
  cat <<'EOF'
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

static int escape(const char *what, const char *path) {
  fprintf(stderr, "PROBE ESCAPE %s %s\n", what, path);
  return 1;
}

__attribute__((constructor)) static void probe(void) {
  int bad = 0;
  char path[4096];
  Dl_info info;
  if (dladdr((void *)probe, &info) && info.dli_fname) {
    char dir[4096];
    strncpy(dir, info.dli_fname, sizeof dir - 1);
    dir[sizeof dir - 1] = 0;
    char *slash = strrchr(dir, '/');
    if (slash) *slash = 0;
    snprintf(path, sizeof path, "%s/probe-wrote-%d", dir, (int)getpid());
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) { close(fd); fprintf(stderr, "PROBE WROTE %s\n", path); }
  }
  const char *elsewhere[] = {"/etc/drgnx-probe", "/usr/drgnx-probe", "/var/tmp/drgnx-probe", 0};
  for (int i = 0; elsewhere[i]; i++) {
    snprintf(path, sizeof path, "%s-%d", elsewhere[i], (int)getpid());
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) { close(fd); fprintf(stderr, "PROBE WROTE %s\n", path); }
  }
  const char *secret = getenv("PROBE_SECRET");
  if (secret) {
    int fd = open(secret, O_RDONLY);
    if (fd >= 0) { close(fd); bad |= escape("read secret", secret); }
  }
  const char *port = getenv("PROBE_PORT");
  if (port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)atoi(port));
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) bad |= escape("connect tcp", port);
    if (s >= 0) close(s);
  }
  const char *sock = getenv("PROBE_SOCK");
  if (sock) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {0};
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock, sizeof a.sun_path - 1);
    if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) bad |= escape("connect unix", sock);
    if (s >= 0) close(s);
  }
  {
    // 2 GiB of address space: the worker's cap is 1 GiB, so a sandboxed worker's mmap must fail
    void *big = mmap(0, 2UL << 30, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (big != MAP_FAILED) { munmap(big, 2UL << 30); bad |= escape("allocate 2 GiB", "-"); }
  }
  if (bad) { fprintf(stderr, "PROBE FAILED\n"); _exit(77); }
  fprintf(stderr, "PROBE CLEAN\n");
}
EOF
}

fixtures() {
  out=$1
  mkdir -p "$out" "$out/src"
  repo=$(grep -ho ':repo "[^"]*"' "$here/packs/json/pack.eld" | head -1 | cut -d'"' -f2)
  commit=$(grep -ho ':commit "[^"]*"' "$here/packs/json/pack.eld" | head -1 | cut -d'"' -f2)
  git init -q "$out/src" && git -C "$out/src" fetch -q --depth 1 "$repo" "$commit" && git -C "$out/src" checkout -q FETCH_HEAD
  for kind in loopy crashy probe; do
    case $kind in
      loopy) body='{ volatile int spin = 1; while (spin) {} }' ;;
      crashy) body='*(volatile int *)0 = 1;' ;;
      probe) body='' ;;
    esac
    sed "s|^  START_LEXER();\$|  START_LEXER(); $body|" "$out/src/src/parser.c" > "$out/$kind.c"
    [ $kind = probe ] || grep -q "START_LEXER(); " "$out/$kind.c"
    if [ $kind = probe ]; then probe_c >> "$out/$kind.c"; fi
    cc -shared -fPIC -O1 -D_GNU_SOURCE -I"$out/src/src" -Dtree_sitter_json=tree_sitter_$kind -o "$out/lib$kind.so" "$out/$kind.c" -ldl
  done
  rm -rf "$out/src" "$out/loopy.c" "$out/crashy.c"
}
if [ ! -f "$dir/drgnx.lock.eld" ]; then
  mkdir -p "$cache"
  tmp="$(mktemp -d "$cache/.build.XXXXXX")"
  trap 'rm -rf -- "$tmp"' EXIT
  (cd "$here/runtime" && cargo run --locked -q -p drgnx-ratatoskr --bin ratatoskr -- packs sync --builtin "$tmp" $packs) >&2
  fixtures "$tmp/fixtures"
  # a run that built the same key at the same time wins; ours is dropped
  mv -T "$tmp" "$dir" 2>/dev/null || true
fi
echo "export DRGNX_PACK_LOCK='$dir/drgnx.lock.eld' DRGNX_PACK_GRAMMARS='$dir/grammars'"
