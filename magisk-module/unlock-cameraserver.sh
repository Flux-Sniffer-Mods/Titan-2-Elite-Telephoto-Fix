#!/system/bin/sh
# Titan 2 Elite — cameraserver system-camera unlock (4 sites, RAM only).
# Reports every camera PUBLIC so third-party apps (and the TeleZoom GCam build)
# can open the hidden 6.80mm telephoto. No photo-cave. Offsets are for
# cameraserver BuildID 6410613c; a firmware update moves them (see --verify).
#
# Usage: unlock-cameraserver.sh [apply|status|revert]   (default: apply)
TAG="titan2-tele-unlock"
LOG() { log -t "$TAG" "$*"; echo "$TAG: $*"; }

# site : fileoffset : original_word : patched_word   (32-bit LE instruction values)
SITES="
0xf3158:b940cae8:52800008
0x11ec70:54000520:d503201f
0x2bd240:d2000020_THUNK:52800020,d65f03c0
0x102b00:d2000000_THUNK:52800000,d65f03c0
"
# (2bd240 / 102b00 are 2-word entry overrides; see PY below.)

PY3="$(command -v python3 2>/dev/null)"
[ -z "$PY3" ] && PY3="/data/data/com.termux/files/usr/bin/python3"
[ -x "$PY3" ] || PY3="python3"

CMD="${1:-apply}"

# Ensure root can ptrace cameraserver (SELinux) — live rule, resets on reboot.
magiskpolicy --live "allow su cameraserver process ptrace" 2>/dev/null \
  || supolicy --live "allow su cameraserver process ptrace" 2>/dev/null || true

PID="$(pidof cameraserver)"
if [ -z "$PID" ]; then LOG "cameraserver not running yet"; [ "$CMD" = status ] && exit 0; fi

"$PY3" - "$CMD" "$PID" <<'PYEOF'
import sys, struct, re, os, json

cmd = sys.argv[1]
pid = sys.argv[2] if len(sys.argv) > 2 else None
BK = "/data/local/tmp/titan2_unlock_backup.json"

# (fileoffset, [patched_words])  — the 4 unlock sites, no caves.
SITES = [
    (0xf3158,  [0x52800008]),               # getSystemCameraKind: ldr -> mov w8,#0
    (0x11ec70, [0xd503201f]),               # filterAPI1SystemCameraLocked: b.eq -> nop
    (0x2bd240, [0x52800020, 0xd65f03c0]),   # hasPermissionsForSystemCamera: mov w0,#1; ret
    (0x102b00, [0x52800000, 0xd65f03c0]),   # shouldRejectSystemCameraConnection: mov w0,#0; ret
]

def seg_base():
    # first executable mapping of cameraserver -> file->runtime bias
    for line in open(f"/proc/{pid}/maps"):
        if "cameraserver" in line and "r-xp" in line:
            a = line.split("-")[0]
            off = int(line.split()[2], 16)
            return int(a, 16) - off
    raise SystemExit("cameraserver exec segment not found")

def rw(addr, data=None):
    with open(f"/proc/{pid}/mem", "r+b") as m:
        m.seek(addr)
        if data is None:
            return m.read(4)
        m.write(data)

if not pid:
    print("no cameraserver pid"); sys.exit(0)
base = seg_base()

if cmd == "status":
    ok = True
    for off, words in SITES:
        cur = rw(base + off)
        want = struct.pack("<I", words[0])
        state = "patched" if cur == want else "orig/other"
        if cur != want: ok = False
        print(f"  0x{off:x} {state} ({cur.hex()})")
    sys.exit(0 if ok else 1)

if cmd == "revert":
    if not os.path.exists(BK):
        print("no backup to revert from"); sys.exit(1)
    bk = json.load(open(BK))
    for off_s, orig_hex in reversed(list(bk.items())):
        off = int(off_s, 16)
        rw(base + off, bytes.fromhex(orig_hex))
    print("reverted 4 sites"); sys.exit(0)

# apply: back up originals (once), write, read-back verify, rollback on fail.
backup = {}
written = []
try:
    for off, words in SITES:
        orig = b""
        for i in range(len(words)):
            orig += rw(base + off + 4*i)
        backup[f"0x{off:x}"] = orig.hex()
    if not os.path.exists(BK):
        json.dump(backup, open(BK, "w"))
    for off, words in SITES:
        data = b"".join(struct.pack("<I", w) for w in words)
        rw(base + off, data)
        written.append((off, len(data)))
        if rw(base + off, None) != struct.pack("<I", words[0]):
            raise RuntimeError(f"verify failed @0x{off:x}")
    print("applied 4 sites OK")
except Exception as e:
    for off, n in reversed(written):
        rw(base + off, bytes.fromhex(backup[f"0x{off:x}"]))
    print(f"apply FAILED ({e}); rolled back"); sys.exit(1)
PYEOF
RC=$?
[ "$CMD" = apply ] && { [ $RC -eq 0 ] && LOG "unlock applied" || LOG "unlock apply failed rc=$RC"; }
exit $RC
