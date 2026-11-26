#!/bin/bash
# TLC checks model/Present.tla, the window's direct present:
#   - Present.cfg: the present keeps its promise (the layer ends on the buffer the guest
#     flushed last), its use counts match the frames that hold them, and its work ends;
#   - PresentBug.cfg: the present before #49 (a skipped direct frame waited in present_pend
#     with the tiled present on) breaks the promise, so the model still sees what it is for.
#   model/check.sh   (java 11 or newer on PATH; TLC 1.7.4 is downloaded once, checksum-pinned)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
jar=${TLC_JAR:-${XDG_CACHE_HOME:-$HOME/.cache}/omacvm/tla2tools-1.7.4.jar}
sha=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-model.XXXXXX")
trap 'rm -rf "$work"' EXIT
if [[ ! -f $jar ]]; then
  # into the cache only once checked, so a bad download or a second run never leaves a wrong jar
  curl -fsSL --retry 3 -o "$work/tla2tools.jar" https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
  echo "$sha  $work/tla2tools.jar" | shasum -a 256 -c - >/dev/null || { echo "model/check.sh: the download is not TLC 1.7.4" >&2; exit 1; }
  mkdir -p "$(dirname "$jar")"
  mv -f "$work/tla2tools.jar" "$jar"
fi
echo "$sha  $jar" | shasum -a 256 -c - >/dev/null || { echo "model/check.sh: $jar is not TLC 1.7.4" >&2; exit 1; }

tlc() { # $1 = config name; TLC's exit status
  java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -metadir "$work/$1" \
    -config "$here/$1.cfg" "$here/Present.tla" > "$work/$1.out" 2>&1
}
rc=0; tlc Present || rc=$?
if (( rc != 0 )); then cat "$work/Present.out" >&2; echo "FAIL model/Present.cfg: TLC exited $rc" >&2; exit 1; fi
grep -E 'distinct states found|depth of the complete' "$work/Present.out" | sed 's/^/  /'
echo "ok   the present keeps its promise, holds no use it lost, and its work ends (Present.cfg)"
rc=0; tlc PresentBug || rc=$?
# 12: TLC found a state that breaks an invariant
if (( rc != 12 )) || ! grep -q 'Invariant Promise is violated' "$work/PresentBug.out"; then
  cat "$work/PresentBug.out" >&2; echo "FAIL model/PresentBug.cfg: TLC found no break of the promise in the present before #49 (exit $rc)" >&2; exit 1
fi
echo "ok   the present before #49 breaks the promise (PresentBug.cfg)"
