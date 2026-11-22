#!/bin/bash
# Glide (experimental), guest side: ./glide.sh <desktop-user> on|off (root).
# The daemon reads the choice from /etc/omacvm/env (guest/install.sh writes it
# and restarts the daemon); this sets up the rest:
#  * ~/.config/hypr/omacvm_glide.lua (scroll factor for the virtual trackpad,
#    Chromium-based apps), loaded from hyprland.lua;
#  * --disable-smooth-scrolling in Chromium's and Chrome's flags files, so
#    Chromium does not animate on top of macOS's momentum (tested with it);
#  * WaylandUnscaledTouchpadScrolling in their last --disable-features (below).
#    Only files that exist; markers remember which ones OmacVM changed, so
#    turning Glide off never removes a flag the user set.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: glide.sh <desktop-user> on|off}; ON=${2:?on|off}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
HY=$H/.config/hypr
LINE='require("hypr.omacvm_glide")'
MARK=$H/.local/state/omacvm/glide-flags
FLAG=--disable-smooth-scrolling
# Chromium's field trial config (Chrome for Testing applies it, 158 measured)
# turns WaylandUnscaledTouchpadScrolling on: a touchpad then scrolls 2.5 pixels
# per unit of the compositor instead of 12, and the page moves a fifth of what
# omacvm_glide.lua's factor for Chromium is tuned for. So Glide turns it off.
# Chromium keeps only its last --disable-features, so the feature goes into
# that one, or into a new line after /etc's list for Chromium, whose launcher
# reads /etc/chromium-flags.conf first.
FEATURE=WaylandUnscaledTouchpadScrolling
FMARK=$H/.local/state/omacvm/glide-features
ETC_FLAGS=/etc/chromium-flags.conf
# disabled add FEATURE [LIST] | remove FEATURE | list: the flags file on stdin
# with FEATURE in Chromium's last --disable-features (a new line with LIST
# first when there is none), or out of every --disable-features, or that last
# list. Status 1 when nothing changes.
disabled() {
  python3 -I -c '
import re, sys
mode, feat = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
lines = sys.stdin.read().splitlines()
tok = re.compile(r"(?<!\S)--disable-features=(\S*)")
hits = [(i, m) for i, l in enumerate(lines) if not l.lstrip().startswith("#") for m in tok.finditer(l)]
vals = lambda m: [v for v in m.group(1).split(",") if v]
if mode == "list":
    print(",".join(vals(hits[-1][1])) if hits else "")
    sys.exit(0)
if mode == "add":
    if hits and feat in vals(hits[-1][1]):
        sys.exit(1)
    if hits:
        i, m = hits[-1]
        lines[i] = lines[i][:m.start()] + "--disable-features=" + ",".join(vals(m) + [feat]) + lines[i][m.end():]
    else:
        first = [v for v in (sys.argv[3] if len(sys.argv) > 3 else "").split(",") if v and v != feat]
        lines.append("--disable-features=" + ",".join(first + [feat]))
else:
    hits = [(i, m) for i, m in hits if feat in vals(m)]
    if not hits:
        sys.exit(1)
    for i, m in reversed(hits):
        rest = [v for v in vals(m) if v != feat]
        lines[i] = lines[i][:m.start()] + ("--disable-features=" + ",".join(rest) if rest else "") + lines[i][m.end():]
    emptied = {i for i, _ in hits if not lines[i].strip()}
    lines = [l for i, l in enumerate(lines) if i not in emptied]
sys.stdout.write("".join(l + "\n" for l in lines))
' "$@"
}
# Hyprland's config is touched (and reloaded below) only when it changes: a
# reload moves the displays, a flicker on every apply.
changed=0
if [[ $ON == on ]]; then
  # In one step: hyprland.lua requires it and Omarchy reloads on every change.
  if ! home_same "$HY/omacvm_glide.lua" omacvm_glide.lua; then
    home_put "$HY/omacvm_glide.lua" < omacvm_glide.lua
    changed=1
  fi
  if ! home_grep "$HY/hyprland.lua" -qxF "$LINE"; then
    printf -- '-- OmacVM Glide (experimental): scrolling settings for the virtual trackpad.\n%s\n' "$LINE" | home_append "$HY/hyprland.lua"
    changed=1
  fi
  home_mkdir "$(dirname "$MARK")"
  for f in "$H/.config/chromium-flags.conf" "$H/.config/chrome-flags.conf" "$H/.config/brave-flags.conf"; do
    [[ -f $f ]] || continue
    if ! home_grep "$f" -qxF -- "$FLAG"; then
      printf '%s\n' "$FLAG" | home_append "$f"
      home_grep "$MARK" -qxF "$f" || echo "$f" | home_append "$MARK"
    fi
    first=
    [[ $f == */chromium-flags.conf && -r $ETC_FLAGS ]] && first=$(disabled list < "$ETC_FLAGS")
    t=$(mktemp)
    if home_cat "$f" | disabled add "$FEATURE" "$first" > "$t"; then
      home_write "$f" < "$t"
      home_grep "$FMARK" -qxF "$f" || echo "$f" | home_append "$FMARK"
    fi
    rm -f "$t"
  done
  echo "scroll momentum: on (restart Chromium-based apps once)"
else
  if home_grep "$HY/hyprland.lua" -qxF "$LINE" || [[ -e $HY/omacvm_glide.lua ]]; then
    home_run sed -i -e '/^-- OmacVM Glide (experimental): scrolling settings for the virtual trackpad.$/d' \
      -e "/^require(\"hypr.omacvm_glide\")$/d" "$HY/hyprland.lua" 2>/dev/null || true
    home_run rm -f "$HY/omacvm_glide.lua"
    changed=1
  fi
  if [[ -f $MARK ]]; then
    while IFS= read -r f; do
      # Only the flags files this script names (the marker is the user's file).
      case $f in "$H/.config/chromium-flags.conf"|"$H/.config/chrome-flags.conf"|"$H/.config/brave-flags.conf") ;; *) continue ;; esac
      [[ -f $f ]] && home_run sed -i "/^$FLAG\$/d" "$f"
    done < <(home_cat "$MARK")
    home_run rm -f "$MARK"
  fi
  if [[ -f $FMARK ]]; then
    while IFS= read -r f; do
      case $f in "$H/.config/chromium-flags.conf"|"$H/.config/chrome-flags.conf"|"$H/.config/brave-flags.conf") ;; *) continue ;; esac
      [[ -f $f ]] || continue
      t=$(mktemp)
      home_cat "$f" | disabled remove "$FEATURE" > "$t" && home_write "$f" < "$t"
      rm -f "$t"
    done < <(home_cat "$FMARK")
    home_run rm -f "$FMARK"
  fi
  echo "scroll momentum: off"
fi
# A running Hyprland picks the change up now.
(( changed )) || exit 0
RUN=/run/user/$(id -u "$U")
# (No session yet, e.g. during a build: no hypr folder, nothing to reload.)
sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -1 || true)
[[ -n $sig ]] && sudo -u "$U" env XDG_RUNTIME_DIR="$RUN" HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl reload >/dev/null 2>&1 || true
