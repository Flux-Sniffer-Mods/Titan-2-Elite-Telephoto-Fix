#!/system/bin/sh
# Titan 2 Elite — cameraserver system-camera unlock (4 sites, RAM only).
#
# Reports every camera as PUBLIC so third-party apps (and the TeleZoom GCam build)
# can open the hidden 6.80mm telephoto. The patch is written to the running
# cameraserver's memory only — nothing on /system is modified, and a reboot fully
# restores it (which is why the boot service re-applies it every boot). Offsets are
# for cameraserver BuildID 6410613c; a firmware update moves them (re-derive with
# tools/cameraserver-recon.sh).
#
# SELinux note (important): cameraserver's domain normally blocks ptrace even for
# root. This script does NOT leave a standing "allow su cameraserver ptrace" policy
# rule — a permanent rule loosens system SELinux policy and causes Google Play
# Protect to report the device as modified. Instead it tries the patch first, and
# only if the kernel blocks memory access does it add the rule, retry, and remove
# the rule again immediately (a matching "deny"), so the live policy is left exactly
# as it was.
#
# Usage: unlock-cameraserver.sh [apply|status|revert]   (default: apply)
TAG="titan2-telephoto"
LOG(){ log -t "$TAG" "$*"; echo "$TAG: $*"; }

CMD="${1:-apply}"

PY3="$(command -v python3 2>/dev/null)"
[ -z "$PY3" ] && PY3="/data/data/com.termux/files/usr/bin/python3"
[ -x "$PY3" ] || PY3="python3"

POL=magiskpolicy; command -v "$POL" >/dev/null 2>&1 || POL=/data/adb/magisk/magiskpolicy
# sepol allow | deny  — add or remove the transient ptrace rule
sepol(){ "$POL" --live "$1 su cameraserver process ptrace" 2>/dev/null \
        || supolicy --live "$1 su cameraserver process ptrace" 2>/dev/null || true; }

PID="$(pidof cameraserver)"
if [ -z "$PID" ]; then LOG "cameraserver not running yet"; [ "$CMD" = status ] && exit 0; fi

# run_patch: the actual memory patcher (self-contained Python). Prints a status line.
run_patch(){ "$PY3" - "$CMD" "$PID" <<'PYEOF'
import sys, struct, os, json
cmd = sys.argv[1]
pid = sys.argv[2] if len(sys.argv) > 2 else None
BK  = "/data/local/tmp/titan2_unlock_backup.json"

# (file offset, [patched 32-bit LE instruction words]) — the four unlock sites.
SITES = [
    (0xf3158,  [0x52800008]),               # getSystemCameraKind: ldr -> mov w8,#0 (report PUBLIC)
    (0x11ec70, [0xd503201f]),               # filterAPI1SystemCameraLocked: b.eq -> nop
    (0x2bd240, [0x52800020, 0xd65f03c0]),   # hasPermissionsForSystemCamera: mov w0,#1; ret
    (0x102b00, [0x52800000, 0xd65f03c0]),   # shouldRejectSystemCameraConnection: mov w0,#0; ret
]

def seg_base():
    # map file offset -> runtime address via cameraserver's executable mapping
    for line in open(f"/proc/{pid}/maps"):
        if line.rstrip().endswith("/system/bin/cameraserver") and "r-xp" in line:
            a = line.split("-")[0]; off = int(line.split()[2], 16)
            return int(a, 16) - off
    raise SystemExit("cameraserver exec segment not found")

def rw(addr, data=None):
    with open(f"/proc/{pid}/mem", "r+b") as m:
        m.seek(addr)
        return m.read(4) if data is None else m.write(data)

if not pid:
    print("no cameraserver pid"); sys.exit(0)
base = seg_base()

if cmd == "status":
    allok = True
    for off, words in SITES:
        want = struct.pack("<I", words[0]); cur = rw(base + off)
        if cur != want: allok = False
        print(f"  0x{off:x} {'patched' if cur==want else 'orig/other'} ({cur.hex()})")
    sys.exit(0 if allok else 1)

if cmd == "revert":
    if not os.path.exists(BK):
        print("no backup to revert from (reboot restores stock)"); sys.exit(1)
    bk = json.load(open(BK))
    for off_s, orig_hex in reversed(list(bk.items())):
        rw(base + int(off_s, 16), bytes.fromhex(orig_hex))
    print("reverted 4 sites"); sys.exit(0)

# apply: capture originals once, write, read-back verify, roll back on any failure.
backup = {}; written = []
try:
    for off, words in SITES:
        orig = b"".join(rw(base + off + 4*i) for i in range(len(words)))
        backup[f"0x{off:x}"] = orig.hex()
    if not os.path.exists(BK):
        json.dump(backup, open(BK, "w"))
    for off, words in SITES:
        data = b"".join(struct.pack("<I", w) for w in words)
        rw(base + off, data); written.append(off)
        if rw(base + off) != struct.pack("<I", words[0]):
            raise RuntimeError(f"verify failed @0x{off:x}")
    print("applied 4 sites OK")
except Exception as e:
    for off in reversed(written):
        rw(base + off, bytes.fromhex(backup[f"0x{off:x}"]))
    print(f"apply FAILED ({e}); rolled back"); sys.exit(1)
PYEOF
}

# Try without touching SELinux first; only bracket with the rule if the op is blocked.
OUT="$(run_patch 2>/dev/null)"; RC=$?
case "$OUT" in
  *"not permitted"*|*"Permission denied"*|*EPERM*|*EACCES*|"")
    sepol allow
    OUT="$(run_patch 2>/dev/null)"; RC=$?
    sepol deny        # remove the rule immediately — no standing policy change
    ;;
esac
[ -n "$OUT" ] && printf '%s\n' "$OUT"
[ "$CMD" = apply ] && { [ $RC -eq 0 ] && LOG "unlock applied" || LOG "unlock apply failed rc=$RC"; }
exit $RC
