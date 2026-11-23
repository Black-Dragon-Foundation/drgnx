#!/usr/bin/env bash
# The keys of a build job's cargo target cache (docs/develop/ci.md, "What is cached"), one place for every job.
#
#   cache-key.sh JOB             prints three lines for $GITHUB_OUTPUT:
#       key=       cargo-OS-ARCH-JOB-mt1-RUSTC-HASH-SHA12     what the job saves (a commit's own entry)
#       restore1=  the key through `HASH-`                     the newest entry of this toolchain and lock
#       restore2=  the key through `RUSTC-`                    the newest entry of this toolchain
#   cache-key.sh --self-test     the keys against fixtures, and the rule that no restore key leaves the toolchain
#
# RUSTC is `rustc -V` as words joined by `-` (`rustc-1.100.0-abc123def-2026-11-01`): a restore never crosses a toolchain,
# so the check on a run's log (run-checks.sh cache) can read the toolchain out of any key as `-rustc-VERSION-`.  HASH
# covers Cargo.lock and .cargo/config.toml, never the Cargo.toml files (a manifest edit that leaves the lock alone keeps
# the entry; cargo rebuilds what changed).  SHA12 makes each commit's entry new: GitHub's keys are immutable, so a key
# without it would exact-hit for ever and never refresh (the plan's C1).  cache-prune.sh drops the superseded ones.
#
# Environment: RUNNER_OS, RUNNER_ARCH, GITHUB_SHA; TOOLCHAIN (a rustup toolchain: `rustc +TOOLCHAIN -V`), or RUSTC_V (the
# `rustc -V` line itself); LOCK (default Cargo.lock) and CONFIG (default .cargo/config.toml), from the current directory.
# bash 3.2-safe (macOS).
set -u

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

keys() {
  local job=$1 v lock cfg hash sha rustc base
  v=${RUSTC_V:-}
  if [ -z "$v" ]; then
    if [ -n "${TOOLCHAIN:-}" ]; then v=$(rustc "+$TOOLCHAIN" -V); else v=$(rustc -V); fi || return 2
  fi
  [ -n "$v" ] || { echo "cache-key.sh: no rustc -V" >&2; return 2; }
  : "${RUNNER_OS:?cache-key.sh: RUNNER_OS}" "${RUNNER_ARCH:?cache-key.sh: RUNNER_ARCH}" "${GITHUB_SHA:?cache-key.sh: GITHUB_SHA}"
  lock=${LOCK:-Cargo.lock} cfg=${CONFIG:-.cargo/config.toml}
  [ -f "$lock" ] || { echo "cache-key.sh: no $lock" >&2; return 2; }
  hash=$({ cat "$lock"; [ ! -f "$cfg" ] || cat "$cfg"; } | sha256 | cut -c1-16)
  rustc=$(printf '%s' "$v" | tr -cs 'A-Za-z0-9.' '-' | sed 's/^-//; s/-$//')
  sha=$(printf '%s' "$GITHUB_SHA" | cut -c1-12)
  base="cargo-$RUNNER_OS-$RUNNER_ARCH-$job-mt1-$rustc-"
  printf 'key=%s%s-%s\nrestore1=%s%s-\nrestore2=%s\n' "$base" "$hash" "$sha" "$base" "$hash" "$base"
}

if [ "${1:-}" = --self-test ]; then
  rc=0 d=$(mktemp -d "${TMPDIR:-/tmp}/cache-key-test.XXXXXX")
  trap 'rm -r "$d"' EXIT
  printf 'lock-a\n' > "$d/Cargo.lock"
  printf '[workspace]\n' > "$d/Cargo.toml"
  export RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 LOCK="$d/Cargo.lock" CONFIG="$d/none.toml"
  fail() { echo "cache-key.sh self-test FAIL: $*"; rc=1; }
  get() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
  out=$(RUSTC_V='rustc 1.100.0 (abc123def 2026-11-01)' keys fedora45) || fail "keys exited $?"
  base=cargo-Linux-X64-fedora45-mt1-rustc-1.100.0-abc123def-2026-11-01
  [ "$(get "$out" key)" = "$base-86eb008250d4212c-0123456789ab" ] || fail "key: $(get "$out" key)"
  [ "$(get "$out" restore1)" = "$base-86eb008250d4212c-" ] || fail "restore1: $(get "$out" restore1)"
  [ "$(get "$out" restore2)" = "$base-" ] || fail "restore2: $(get "$out" restore2)"
  # a restore key never leaves the toolchain: both keep the rustc part, and no restore key of another toolchain is a prefix of this key
  for r in restore1 restore2; do
    case $(get "$out" $r) in *-mt1-rustc-1.100.0-abc123def-2026-11-01-*) ;; *) fail "$r lacks the rustc part: $(get "$out" $r)" ;; esac
  done
  other=$(RUSTC_V='rustc 1.101.0 (fff000111 2026-12-01)' keys fedora45) || fail "keys of another toolchain exited $?"
  for r in restore1 restore2; do
    case $(get "$out" key) in "$(get "$other" $r)"*) fail "the key of 1.100.0 matches 1.101.0's $r (a restore across toolchains)" ;; esac
  done
  # another job, another architecture: never each other's
  o2=$(RUSTC_V='rustc 1.100.0 (abc123def 2026-11-01)' keys msrv195) || fail "keys of another job exited $?"
  case $(get "$out" key) in "$(get "$o2" restore2)"*) fail "the keys of two jobs share a restore prefix" ;; esac
  o3=$(RUSTC_V='rustc 1.100.0 (abc123def 2026-11-01)' RUNNER_ARCH=ARM64 keys fedora45) || fail "keys of ARM64 exited $?"
  case $(get "$out" key) in "$(get "$o3" restore2)"*) fail "the keys of two architectures share a restore prefix" ;; esac
  # a manifest edit leaves the hash part alone; a lock edit moves it
  printf '[workspace]\nmembers = ["x"]\n' > "$d/Cargo.toml"
  out2=$(RUSTC_V='rustc 1.100.0 (abc123def 2026-11-01)' keys fedora45) || fail "keys after a manifest edit exited $?"
  [ "$(get "$out2" key)" = "$(get "$out" key)" ] || fail "a Cargo.toml edit changed the key"
  printf 'lock-b\n' > "$d/Cargo.lock"
  out3=$(RUSTC_V='rustc 1.100.0 (abc123def 2026-11-01)' keys fedora45) || fail "keys after a lock edit exited $?"
  [ "$(get "$out3" restore1)" != "$(get "$out" restore1)" ] || fail "a Cargo.lock edit left the key"
  [ "$(get "$out3" restore2)" = "$(get "$out" restore2)" ] || fail "a Cargo.lock edit moved the toolchain prefix"
  # the config is part of the hash
  printf '[build]\n' > "$d/none.toml"
  out4=$(RUSTC_V='rustc 1.100.0 (abc123def 2026-11-01)' keys fedora45) || fail "keys with a config exited $?"
  [ "$(get "$out4" key)" != "$(get "$out3" key)" ] || fail "a .cargo/config.toml left the key"
  # no commit, no lock: an error, never a key
  ( unset GITHUB_SHA; RUSTC_V='rustc 1.100.0 (x 2026-11-01)' keys fedora45 >/dev/null 2>&1 ) && fail "a key without GITHUB_SHA"
  ( LOCK="$d/missing.lock" RUSTC_V='rustc 1.100.0 (x 2026-11-01)' keys fedora45 >/dev/null 2>&1 ) && fail "a key without a lock"
  [ "$rc" = 0 ] && echo "cache-key.sh self-test: ok"
  exit $rc
fi

[ $# -eq 1 ] || { echo "usage: cache-key.sh JOB | --self-test" >&2; exit 2; }
keys "$1"
