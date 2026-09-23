#!/data/data/com.termux/files/usr/bin/bash
#
# configure-lenses.sh
#
# Reads and writes the GCam port's lens preferences, so the viewfinder
# buttons map to the Titan 2 Elite's real camera IDs.
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# This port (an SDE-framework build) keeps lens mapping in SharedPreferences,
# not in resources or code, so no APK patching is involved. Settings >
# Additional cameras exposes the same values this script writes.
#
# Camera IDs on this device:
#   0  5.59mm  LEVEL_3  RAW                            main, 50 MP
#   1  2.31mm  LEVEL_3  RAW                            front, 32 MP
#   2  6.80mm  FULL     no RAW  SYSTEM                 telephoto, 8 MP
#   3  5.59mm  LEVEL_3  RAW     SYSTEM  LOGICAL[0 2]   fused virtual device
#
# Usage:
#   ./configure-lenses.sh show              print current lens prefs
#   ./configure-lenses.sh export [FILE]     save current config to FILE
#   ./configure-lenses.sh export --all      save every pref, not just lenses
#   ./configure-lenses.sh apply [FILE]      write FILE (or the built-in set)
#   ./configure-lenses.sh restore           roll back to the last backup
#
# Typical workflow: configure it once in the GCam settings menu, run
# "export", commit the resulting file, and from then on "apply lenses.tsv"
# reproduces that configuration on any install.
#
# apply works on a fresh install with no preferences file - it creates one
# with the right ownership and SELinux context, so GCam comes up already
# configured without needing a first launch.

set -u

PKG="com.google.android.GoogleCameraEngR18F1"
DATADIR="/data/data/$PKG"
PREFSDIR="$DATADIR/shared_prefs"
PREFS="$PREFSDIR/${PKG}_preferences.xml"
BACKUP="$PREFS.bak"

# Staging happens inside Termux's own home, not the shell tmp dir. A
# redirect like `su -c "cat X" > Y` is run by the TERMUX shell, not by
# root, so Y must be writable by the Termux uid - which the shell tmp
# directory, owned by shell:shell, normally is not.
TMPD="$HOME/.cache/gcam-lenses"

DEFAULT_EXPORT="lenses.tsv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Keys treated as "lens configuration" by show and by a plain export.
# Widened deliberately: lens logic (pref_gcam_lens_logic_*), the zoom keys
# and the camera list all affect which lenses appear, and a narrower pattern
# silently drops them from an export.
LENS_PATTERN='aux|cameraid|show_buttons|camera_name|lens|zoom|manual_array|list_camera'

# --------------------------------------------------- built-in default set
#
# Used by "apply" when no file is given.
# Format: key<TAB>type<TAB>value    (type is bool or string)
#
# NOTE: this port persists its switches as the STRINGS "1" and "0", not as
# <boolean> entries, despite them being ManagedSwitchPreference in the
# settings XML. Writing them as booleans produces a preference GCam ignores.
# pref_aux_layout: 0 = Vertical, 1 = Horizontal.
#
# pref_enable_manual_array_key ("Use listed IDs") and pref_manual_cameraid_key
# ("Use given values") are the port's overrides: they make it work from the
# ID list given here rather than from whatever it enumerates by itself. On a
# device where the extra cameras are hidden behind SYSTEM_CAMERA, enumeration
# can come back short even when the permission is granted, and these force
# the issue.
#
# Slot N's button opens whatever camera ID sits in
# pref_manual_cameraid_back_N_key.

read -r -d '' BUILTIN <<'EOF'
pref_aux_key	string	1
pref_show_buttons_key	string	1
pref_aux_tele_key	string	1
pref_aux_wide_key	string	1
pref_aux_layout	string	0
pref_enable_manual_array_key	string	1
pref_manual_array_key	string	0,1,2,3
pref_manual_cameraid_key	string	1
pref_manual_cameraid_back_1_key	string	0
pref_manual_cameraid_back_2_key	string	2
pref_manual_cameraid_back_3_key	string	3
pref_gcam_lens_logic_key	string	0
pref_gcam_lens_logic_key_2	string	5
pref_gcam_lens_logic_key_3	string	6
pref_manual_camera_name_key_main	string	1x
pref_manual_camera_name_key_2	string	3.4x
pref_manual_camera_name_key_3	string	3.4xR
EOF


# ==================================================================== output

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }
as_root() { su -c "$*"; }

# ================================================================= preflight

preflight() {
  su -c 'id -u' >/dev/null 2>&1 || die "No root. Grant Termux root access in Magisk."
  as_root "test -d '$DATADIR'" \
    || die "$PKG is not installed. Run gcam-titan2-build.sh first."
}

# Create an empty preferences file, owned correctly, if none exists.
# This is what lets a fresh install be configured before its first launch.
ensure_prefs() {
  if as_root "test -f '$PREFS'"; then
    return
  fi

  warn "no preferences file yet; creating one"

  mkdir -p "$TMPD"

  # The app's uid owns its data directory; reuse it rather than guessing.
  local uid
  uid=$(as_root "stat -c '%u' '$DATADIR'") || die "could not stat $DATADIR"

  as_root "mkdir -p '$PREFSDIR'"
  as_root "chown $uid:$uid '$PREFSDIR'"
  as_root "chmod 0771 '$PREFSDIR'"

  printf "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>\n" \
    > "$TMPD/new.xml"
  as_root "cp '$TMPD/new.xml' '$PREFS'"
  rm -f "$TMPD/new.xml"

  as_root "chown $uid:$uid '$PREFS'"
  as_root "chmod 0660 '$PREFS'"
  as_root "restorecon -R '$PREFSDIR'" 2>/dev/null
  ok "created $PREFS (uid $uid)"
}

# ====================================================================== show

do_show() {
  step "Current lens preferences"
  local out
  out=$(as_root "grep -iE '$LENS_PATTERN' '$PREFS'" 2>/dev/null)
  if [ -z "$out" ]; then
    warn "none set"
  else
    printf '%s\n' "$out" | sed 's/^[[:space:]]*/  /'
  fi
  echo
}

# ==================================================================== export

do_export() {
  local target="$DEFAULT_EXPORT" all=0 arg
  for arg in "$@"; do
    case "$arg" in
      --all) all=1 ;;
      -*)    die "unknown option: $arg" ;;
      *)     target="$arg" ;;
    esac
  done

  step "Exporting current configuration"
  as_root "test -f '$PREFS'" || die "no preferences file to export.
       Launch GCam and configure it first."

  mkdir -p "$TMPD"
  as_root "cat '$PREFS'" > "$TMPD/in.xml" || die "could not read preferences"
  [ -s "$TMPD/in.xml" ] || die "read back an empty preferences file"

  ALL="$all" PATTERN="$LENS_PATTERN" python3 - \
      "$TMPD/in.xml" "$target" <<'PYEOF' || die "export failed"
import os, sys
import xml.dom.minidom as minidom
import re

src, dst = sys.argv[1], sys.argv[2]
want_all = os.environ["ALL"] == "1"
pattern  = re.compile(os.environ["PATTERN"], re.I)

# Parse properly rather than by regex. Android emits several shapes for the
# same thing - <string name="k">v</string>, <string name="k" /> for an empty
# value, <boolean name="k" value="true"/> with or without a space - and a
# regex that misses one silently drops the preference.
try:
    doc = minidom.parse(src)
except Exception as e:
    sys.exit("! preferences file is not valid XML: %s" % e)

rows, total = [], 0
for node in doc.documentElement.childNodes:
    if node.nodeType != node.ELEMENT_NODE:
        continue
    kind = node.tagName
    key  = node.getAttribute("name")
    if not key:
        continue
    total += 1

    if kind == "string":
        value = "".join(c.data for c in node.childNodes
                        if c.nodeType in (c.TEXT_NODE, c.CDATA_SECTION_NODE))
        rows.append((key, "string", value))
    elif kind == "boolean":
        rows.append((key, "bool", node.getAttribute("value")))
    elif kind in ("int", "long", "float"):
        rows.append((key, kind, node.getAttribute("value")))
    else:
        # <set> and anything else has no single-value representation
        print("  skipping %s (unsupported type <%s>)" % (key, kind))

if not want_all:
    rows = [r for r in rows if pattern.search(r[0])]

rows.sort()

with open(dst, "w", encoding="utf-8") as f:
    f.write("# GCam lens configuration, exported by configure-lenses.sh\n")
    f.write("# Apply with: ./configure-lenses.sh apply %s\n" % os.path.basename(dst))
    f.write("# key<TAB>type<TAB>value\n")
    for key, kind, value in rows:
        f.write("%s\t%s\t%s\n" % (key, kind, value))

if not rows:
    print()
    print("  NOTHING EXPORTED.")
    print("  The preferences file holds %d preference(s), none matching" % total)
    print("  the lens pattern. Likely causes:")
    print("    - GCam is still running and has not flushed to disk.")
    print("      Close it fully (or: am force-stop), then export again.")
    print("    - The settings were never committed - back out of the")
    print("      settings screen to the viewfinder before exporting.")
    print("    - App data was cleared since you configured it.")
    print("  Run './configure-lenses.sh export --all' to see everything")
    print("  that IS stored.")
    sys.exit(1)

print("  %d of %d preference(s) written" % (len(rows), total))
for key, kind, value in rows:
    print("    %-36s %s" % (key, value))
PYEOF

  rm -f "$TMPD/in.xml"
  ok "saved to $target"
  [ "$all" = "1" ] && warn "exported every preference; review before committing"
  echo
}

# ===================================================================== apply

do_apply() {
  local source_file="${1:-}"
  local settings

  # Precedence: an explicit file, else a lenses.tsv shipped next to this
  # script (the committed known-good configuration), else the built-in set.
  if [ -n "$source_file" ]; then
    [ -f "$source_file" ] || die "no such file: $source_file"
    settings=$(cat "$source_file")
    step "Applying $source_file"
  elif [ -f "$SCRIPT_DIR/$DEFAULT_EXPORT" ]; then
    source_file="$SCRIPT_DIR/$DEFAULT_EXPORT"
    settings=$(cat "$source_file")
    step "Applying $DEFAULT_EXPORT"
  else
    settings="$BUILTIN"
    step "Applying built-in default mapping"
  fi

  ensure_prefs

  # SharedPreferences are cached in memory and rewritten wholesale when the
  # process exits, so editing the file while GCam runs gets silently undone.
  as_root "am force-stop $PKG"
  ok "GCam stopped"

  as_root "cp '$PREFS' '$BACKUP'" || die "could not back up preferences"
  ok "backup: $BACKUP"

  # Ownership must survive the write, or GCam cannot read its own prefs.
  local owner
  owner=$(as_root "stat -c '%u:%g' '$PREFS'") || die "could not stat preferences"

  mkdir -p "$TMPD"
  as_root "cat '$PREFS'" > "$TMPD/in.xml" || die "could not read preferences"
  [ -s "$TMPD/in.xml" ] || die "read back an empty preferences file"

  # The settings go in a FILE, not on stdin. `python3 -` reads its program
  # from stdin, and the heredoc below already occupies it - a pipe here
  # would be silently discarded and every line would be missed.
  printf '%s\n' "$settings" > "$TMPD/settings.tsv"

  python3 - "$TMPD/in.xml" "$TMPD/out.xml" "$TMPD/settings.tsv" \
      <<'PYEOF' || die "preference edit failed"
import re, sys
import xml.dom.minidom as minidom

src, dst, settings_path = sys.argv[1], sys.argv[2], sys.argv[3]
xml = open(src, encoding="utf-8").read()
settings = open(settings_path, encoding="utf-8").read()

def esc(v):
    return v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

count = 0
for line in settings.splitlines():
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue

    parts = line.split("\t")
    if len(parts) != 3:
        sys.exit("! malformed line (expected key<TAB>type<TAB>value): %r" % line)
    key, kind, value = parts

    if kind in ("bool", "boolean", "int", "long", "float"):
        tag = "boolean" if kind in ("bool", "boolean") else kind
        entry   = '    <%s name="%s" value="%s" />' % (tag, key, esc(value))
        pattern = r'[ \t]*<%s name="%s"[^/]*/>' % (tag, re.escape(key))
    elif kind == "string":
        entry   = '    <string name="%s">%s</string>' % (key, esc(value))
        pattern = r'[ \t]*<string name="%s">.*?</string>' % re.escape(key)
    else:
        sys.exit("! unknown type %r for key %r" % (kind, key))

    if re.search(pattern, xml, re.S):
        xml = re.sub(pattern, entry.replace("\\", "\\\\"), xml, count=1, flags=re.S)
        print("  ~ %-36s %s" % (key, value))
    else:
        xml = xml.replace("</map>", entry + "\n</map>", 1)
        print("  + %-36s %s" % (key, value))
    count += 1

# A malformed preferences file makes Android discard the whole thing,
# silently resetting every setting. Refuse to write one.
minidom.parseString(xml)

if count == 0:
    sys.exit("! no preferences were applied - the settings source was empty")

open(dst, "w", encoding="utf-8").write(xml)
print("  %d preference(s) applied" % count)
PYEOF

  as_root "cp '$TMPD/out.xml' '$PREFS'" \
    || die "could not write preferences back"
  as_root "chown $owner '$PREFS'"
  as_root "chmod 0660 '$PREFS'"
  as_root "restorecon '$PREFS'" 2>/dev/null

  rm -f "$TMPD/in.xml" "$TMPD/out.xml" "$TMPD/settings.tsv"
  ok "written, ownership and context restored"

  step "Done"
  printf '  Launch GCam and check the viewfinder buttons.\n\n'
  printf '  To confirm a button really switches lenses rather than cropping\n'
  printf '  the main sensor: cover the telephoto and shoot at that zoom. If\n'
  printf '  the frame still comes through, it is a crop.\n\n'
}

# =================================================================== restore

do_restore() {
  step "Restoring previous preferences"
  as_root "test -f '$BACKUP'" || die "no backup at $BACKUP"
  as_root "am force-stop $PKG"
  local owner
  owner=$(as_root "stat -c '%u:%g' '$PREFS'")
  as_root "cp '$BACKUP' '$PREFS'"
  as_root "chown $owner '$PREFS'"
  as_root "chmod 0660 '$PREFS'"
  as_root "restorecon '$PREFS'" 2>/dev/null
  ok "restored from $BACKUP"
  echo
}

# ======================================================================= main

action="${1:-apply}"
shift 2>/dev/null || true

case "$action" in
  show)    preflight; do_show ;;
  export)  preflight; do_export "$@" ;;
  apply)   preflight; do_show; do_apply "${1:-}" ;;
  restore) preflight; do_restore ;;
  *)       die "Usage: $0 [show|export [FILE|--all]|apply [FILE]|restore]" ;;
esac
