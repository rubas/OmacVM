#!/bin/bash
# What the vsync queue does with a frame it skips (omacvm-cocoa-present-direct.patch):
#   - test-present-direct.c runs the vsync queue and its skip code, taken from a ui/cocoa.m, with the
#     tiled present on and off: a direct frame skipped with none after it (the trims after a tick)
#     leaves the guest's buffer unused, so the present after the tick sends it again; a drawn frame
#     skipped with none after it waits in present_pend for the tile frame that lies over it, or else
#     the next tick shows it (a scroll that ends on a trimmed frame ends on screen too);
#   - with a patched ui/cocoa.m: the wiring of that resend;
#   - with --self-test [<ui/cocoa.m without the patch>]: the skip test fails on that code and every
#     wiring check not marked "(kept)" fails too (CI: the code before the patch, copied in
#     test-present-direct-before.inc; the runtime build: the real cocoa.m before the patch).
#   test-present-direct.sh <patched ui/cocoa.m> | --self-test [<ui/cocoa.m without the patch>]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-direct.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The definition (not a prototype) of the function whose first line starts with $2.
body() { awk -v h="$2" 'index($0, h) == 1 && $0 !~ /;$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
# A before B (fixed strings), in that order in the text.
order() { awk -v a="$2" -v b="$3" '!x && index($0, a) {x=NR; next} x && index($0, b) {y=NR; exit} END {exit !(x && y)}' <<<"$1"; }

# present-frames.inc from a cocoa.m, in the file's order: the queue's sizes and times, PresentFrame,
# present_sync, the skip code, and the queue (a frame comes, a tick).
extract() {
  local m=$1 h
  grep -E '^#define PRESENT_(QUEUE|IDLE_S|INPUT_NS|CLOSE_S) ' "$m" > "$work/present-frames.inc"
  awk '/^typedef struct PresentFrame \{$/ {on=1} on {print} on && /^\} PresentFrame;$/ {exit}' "$m" >> "$work/present-frames.inc"
  awk 'p == "static struct {" && /^    PresentFrame queue\[PRESENT_QUEUE\];/ {on=1; print p} {p=$0} on {print} on && /^};$/ {exit}' \
    "$m" >> "$work/present-frames.inc"
  for h in 'static void present_frame_put(PresentFrame *f)' 'static void present_frame_absorb(PresentFrame *newer, PresentFrame *older)'; do
    body "$m" "$h" >> "$work/present-frames.inc"
  done
  grep -x 'static PresentFrame present_pend;' "$m" >> "$work/present-frames.inc"
  for h in 'static void present_frame_skip(PresentFrame *older, PresentFrame *next)' \
           'static void present_window_reset(double now)' 'static void cocoa_gl_present_queue_frame(PresentFrame f)' \
           'static double present_wanted_hz(void)' 'static bool cocoa_gl_present_vsync(double T'; do
    body "$m" "$h" >> "$work/present-frames.inc"
  done
}
# 1 when the extracted PresentFrame marks direct frames
direct_field() { grep -qE '^ +bool direct;' "$work/present-frames.inc" && echo 1 || echo 0; }
build() { # $1 = HAVE_DIRECT
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-present-tiles-logic.patch" || return 1
  cc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -DHAVE_DIRECT="$1" -I"$work" -I"$work/ui" \
    "$here/test-present-direct.c" -o "$work/t" -lm 2>"$work/cc.log" || { cat "$work/cc.log" >&2; return 1; }
}

wiring() {
  local m=$1 send direct present bh vsync trims
  send=$(body "$m" 'static void cocoa_gl_present_send(IOSurfaceRef surf, GLsync sync, void *gfence,')
  direct=$(body "$m" 'static bool cocoa_gl_present_direct(const DisplayGLTexture *texture, IOSurfaceRef gsurf,')
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  bh=$(body "$m" 'static void cocoa_gl_present_bh(void *opaque)')
  vsync=$(body "$m" 'static bool cocoa_gl_present_vsync(double T')
  chk "a frame sent with the guest's fence is a direct frame" has "$send" '.direct = ops != NULL,'
  chk "the direct present sends the guest's buffer with its fence" has "$direct" \
    'cocoa_gl_present_send(gsurf, NULL, texture->iosurface_ops->fence(gl_scanout_id),'
  chk "a direct frame asks the present after each tick for its frame again" has "$direct" \
    'qatomic_set(&present_tiles_full, true);'
  chk "the guest's buffer is sent again when nothing uses it and the layer does not show it" has "$present" \
    '(gsurf == qatomic_read(&present_shown) || IOSurfaceGetUseCount(gsurf)) ?'
  chk "(kept) the present after a tick runs for a whole frame" order "$bh" 'if (qatomic_read(&present_tiles_full)) {' 'gl_dirty = true;'
  chk "(kept) a shown frame schedules the present after the tick" order "$vsync" 'present_frame_show(&show);' 'qemu_bh_schedule(present_bh);'
  trims=$(grep -cF 'present_frame_skip(&present_sync.queue[0], present_sync.queued > 1 ?' <<<"$vsync")
  chk "(kept) both trims of the tick skip through present_frame_skip" test "$trims" = 2
}

if [[ ${1:-} == --self-test ]]; then
  if [[ $# -ge 2 ]]; then
    extract "$2"
    old=$2
  else
    cp "$here/test-present-direct-before.inc" "$work/present-frames.inc"
    old=
  fi
  build "$(direct_field)" || exit 1
  "$work/t" > "$work/old.out"
  # its last line: every check ran (a crash or a test that never started says nothing)
  if ! grep -qx 'test-present-direct: FAIL' "$work/old.out"; then
    echo "FAIL the skip test passes or does not run on the code before the patch" >&2; cat "$work/old.out" >&2; exit 1
  fi
  # the build's log and CI look for the word FAIL: say these as "fails before"
  grep '^FAIL ' "$work/old.out" | sed 's/^FAIL /  fails before the patch, as it should: /'
  if [[ -n $old ]]; then
    passed=$(wiring "$old" | grep '^ok ' | grep -v '^ok (kept) ')
    if [[ -n $passed ]]; then echo "FAIL these wiring checks pass on the code before the patch:" >&2; echo "$passed" >&2; exit 1; fi
  fi
  if [[ -n $old ]]; then echo "ok   the skip test and every new wiring check fail on the code before the patch"
  else echo "ok   the skip test fails on the code before the patch"; fi
  exit 0
fi

m=${1:?usage: test-present-direct.sh <patched ui/cocoa.m> | --self-test [<ui/cocoa.m without the patch>]}
extract "$m"
[[ $(direct_field) == 1 ]] || { echo "test-present-direct: $m: PresentFrame has no direct (patch not applied?)" >&2; exit 1; }
build 1 || exit 1
fail=0
"$work/t" || fail=1
out=$(wiring "$m")
echo "$out" | sed 's/^/  wiring: /'
grep -q '^FAIL' <<<"$out" && fail=1
if (( fail )); then echo "test-present-direct: $m: FAIL" >&2; exit 1; fi
echo "test-present-direct: $m: all ok"
