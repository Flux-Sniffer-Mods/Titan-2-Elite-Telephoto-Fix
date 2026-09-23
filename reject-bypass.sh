#!/data/data/com.termux/files/usr/bin/bash
#
# reject-bypass.sh — unlock the hidden system cameras on the Unihertz Titan 2 Elite
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# WHAT IT DOES
#   Patches the running /system/bin/cameraserver, in memory, at four sites so it
#   stops hiding the telephoto and logical cameras (IDs 2 and 3) from
#   third-party apps. Everything is RAM-only (dm-verity untouched, a reboot
#   restores stock) and every write is read back and verified; any mismatch
#   rolls back the whole batch.
#
#     0xf3158  getSystemCameraKind            ldr w8,[x23,0xc8] -> mov w8,#0
#              THE ROOT. Classifies each camera as public or system-only; every
#              other filter calls it. Forcing the cached classification to 0
#              (PUBLIC) makes nothing treat a camera as system-only, so
#              enumeration returns all four and opens succeed. Single-instruction
#              edit — the function still runs its mutex unlock / refcount
#              cleanup, so no deadlock.
#     0x11ec70 filterAPI1SystemCameraLocked   b.eq -> nop
#     0x2bd240 hasPermissionsForSystemCamera  entry -> mov w0,#1 ; ret
#     0x102b00 shouldRejectSystemCameraConnection entry -> mov w0,#0 ; ret
#     The first is the true root; the other three are belt-and-suspenders.
#
#   NOTE. A telephoto PHOTO-mode "cave" (injecting postRawSensitivityBoostRange
#   into camera 2) once lived here as Part 2. It was proven a dead end — the
#   vendor HAL refuses tele stills at the HAL/TEE boundary regardless — and has
#   been removed. Telephoto stills now come through GCam's intent-capture path
#   (the TeleZoom "TELE" button / TeleShot), not from cameraserver. See
#   the README ("How it works, in depth"), Parts B and D. This script is unlock-only.
#
# HOW IT GETS WRITE ACCESS
#   cameraserver is on /system (dm-verity, no on-disk patch) and runs in the
#   SELinux domain u:r:cameraserver:s0, which blocks even root from ptracing it.
#   A live Magisk policy rule lifts exactly that:
#       magiskpolicy --live "allow su cameraserver process ptrace"
#   after which /proc/<pid>/mem is writable.
#
#   * --revert restores the exact original bytes from a live-captured backup.
#   * Dry-run by default — nothing is written without --apply.
#   * BuildID note: offsets are for cameraserver BuildID 6410613c. A firmware
#     update moves them; re-derive with r2 (see the README ("How it works, in depth")).
#
# USAGE
#   ./reject-bypass.sh            dry run (plan only, writes nothing)
#   ./reject-bypass.sh --apply    patch the four unlock sites (this boot only)
#   ./reject-bypass.sh --revert   restore the original bytes
#   ./reject-bypass.sh --status   show which sites are currently patched
#   ./reject-bypass.sh --install  add a Magisk boot service (asks to confirm)
#   ./reject-bypass.sh --uninstall remove that boot service
#
#   For a boot service, prefer the packaged Magisk module
#   (magisk-module/ -> titan2-tele-unlock-magisk.zip); --install here is a
#   lightweight alternative; it does not keep a standing SELinux rule.

set -u

# ---- system-camera unlock sites ----------------------------------------------
# Format: fileoff:word0[:word1...]  (each word is a 32-bit LE instruction value;
# single-word sites just list one). See header for what each site does.
UNLOCK_SITES="0xf3158:0x52800008 0x2bd240:0x52800020:0xd65f03c0 0x102b00:0x52800000:0xd65f03c0 0x11ec70:0xd503201f"

BIN=/system/bin/cameraserver
TMP=/data/local/tmp
UNLOCK_BK=$TMP/rb_backup.json
PY3="$(command -v python3 || echo /data/data/com.termux/files/usr/bin/python3)"
MP=magiskpolicy; su -c 'command -v magiskpolicy' >/dev/null 2>&1 || MP=/data/adb/magisk/magiskpolicy

MODE="${1:-dryrun}"
case "$MODE" in
  --apply) MODE=apply;;
  --revert) MODE=revert;;
  --status) MODE=status;;
  --install) MODE=install;;
  --uninstall) MODE=uninstall;;
  ""|--dry*) MODE=dryrun;;
  *) echo "usage: $0 [--apply|--revert|--status|--install|--uninstall]"; exit 1;;
esac

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step(){ printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok(){ printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die(){ printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*"; exit 1; }

su -c 'id -u' >/dev/null 2>&1 || die "no root"
[ -n "$PY3" ] || die "python3 needed"

# SELinux note: cameraserver runs in a domain that normally blocks ptrace even for
# root. We do NOT add a standing policy rule (a permanent 'allow su cameraserver
# ptrace' rule loosens system policy and trips Google Play Protect). Instead each
# memory operation is bracketed: try it as-is; only if the kernel blocks it do we
# add the rule, do the op, and immediately remove it again with a matching deny so
# the live policy ends up exactly as it started.
SEPOL_RULE="allow su cameraserver process ptrace"
sepol_add(){ su -c "$MP --live \"$SEPOL_RULE\"" 2>/dev/null; }
sepol_del(){ su -c "$MP --live \"deny su cameraserver process ptrace\"" 2>/dev/null; }

su -c "cat > $TMP/rb.py" <<'PYEOF'
import sys, struct, os, json
BIN="/system/bin/cameraserver"

# argv: <cmd> <sites> [backup_path]
#   sites token form:  off:w0[:w1...]  words are 32-bit LE instruction VALUES
BACKUP = sys.argv[3] if len(sys.argv) > 3 else "/data/local/tmp/rb_backup.json"

SITES=[]
for tok in sys.argv[2].split():
    parts=tok.split(":")
    off=int(parts[0],16)
    words=[]
    for w in parts[1:]:
        if w=="none": break
        words.append(int(w,16))
    SITES.append((off,words))

def pid():
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if open(f"/proc/{p}/cmdline","rb").read().split(b"\0")[0].endswith(b"cameraserver"): return int(p)
            except: pass
    return None
def segs(p):
    o=[]
    for l in open(f"/proc/{p}/maps"):
        if l.rstrip().endswith("/system/bin/cameraserver"):
            r,perm,fo=l.split()[0],l.split()[1],l.split()[2]; a,b=r.split("-")
            o.append((int(a,16),int(b,16),int(fo,16)))
    return o
def rt(S,fo):
    for a,b,f in S:
        if f<=fo<f+(b-a): return a+(fo-f)
    return None
def rd(p,a,n):
    with open(f"/proc/{p}/mem","rb") as m: m.seek(a); return m.read(n)
def wr(p,a,d):
    with open(f"/proc/{p}/mem","r+b") as m: m.seek(a); m.write(d)

def resolve(P):
    S=segs(P)
    out=[]
    for off,words in SITES:
        a=rt(S,off)
        if a is None: return None,f"offset {off:#x} not mapped"
        out.append((a,words,off))
    return out,None

def main():
    cmd=sys.argv[1]; P=pid()
    if not P: print(json.dumps({"error":"cameraserver not running"})); return
    res,err=resolve(P)
    if err: print(json.dumps({"error":err})); return
    if cmd=="plan":
        rows=[]
        for a,words,off in res:
            cur=[struct.unpack_from("<I",rd(P,a+4*i,4),0)[0] for i in range(len(words))]
            rows.append({"off":hex(off),"addr":hex(a),"words":len(words),"done":cur==words})
        print(json.dumps({"pid":P,"sites":rows}))
    elif cmd=="apply":
        bk={}; written=[]
        try:
            for a,words,off in res:
                for i in range(len(words)):
                    bk[str(a+4*i)]=struct.unpack_from("<I",rd(P,a+4*i,4),0)[0]
            json.dump(bk,open(BACKUP,"w"))
            for a,words,off in res:
                for i,w in enumerate(words):
                    wr(P,a+4*i,struct.pack("<I",w))
                    if struct.unpack_from("<I",rd(P,a+4*i,4),0)[0]!=w:
                        raise RuntimeError(f"verify fail at {a+4*i:#x}")
                    written.append(a+4*i)
            print(json.dumps({"ok":True,"patched":[hex(x) for x in written],"backup":BACKUP}))
        except Exception as e:
            for addr in reversed(list(bk.keys())):
                wr(P,int(addr),struct.pack("<I",bk[addr]))
            print(json.dumps({"error":str(e),"rolled_back":True}))
    elif cmd=="revert":
        if not os.path.exists(BACKUP): print(json.dumps({"error":f"no backup at {BACKUP}; reboot restores stock"})); return
        bk=json.load(open(BACKUP)); n=0
        for a,w in reversed(list(bk.items())): wr(P,int(a),struct.pack("<I",w)); n+=1
        print(json.dumps({"ok":True,"reverted":n,"backup":BACKUP}))
    elif cmd=="status":
        rows=[]
        for a,words,off in res:
            cur=[struct.unpack_from("<I",rd(P,a+4*i,4),0)[0] for i in range(len(words))]
            rows.append({"off":hex(off),"patched":cur==words})
        print(json.dumps({"sites":rows,"all_patched":all(r["patched"] for r in rows)}))
main()
PYEOF

# run <cmd> <sites> <backup>: execute the patch helper, adding the SELinux rule
# only if the first attempt is blocked, and always removing it afterwards.
run(){
  local out
  out="$(su -c "$PY3 $TMP/rb.py $1 \"$2\" \"$3\"" 2>/dev/null)"
  case "$out" in
    *Operation\ not\ permitted*|*Permission\ denied*|*EPERM*|*EACCES*|"")
      sepol_add
      out="$(su -c "$PY3 $TMP/rb.py $1 \"$2\" \"$3\"" 2>/dev/null)"
      sepol_del
      ;;
  esac
  printf '%s' "$out"
}

show_sites(){ "$PY3" -c 'import json,sys
d=json.load(sys.stdin)
if "error" in d: print("  ERROR:",d["error"]); sys.exit(1)
for s in d.get("sites",[]):
    k="done" if "done" in s else "patched"
    print("  ",s["off"],k+"="+str(s.get(k)))'; }

case "$MODE" in
dryrun)
  step "DRY RUN — plan only (writes nothing)"
  echo "  system-camera unlock:"; run plan "$UNLOCK_SITES" "$UNLOCK_BK" | show_sites
  printf '\n  Apply: %s --apply     Reboot reverts everything.\n\n' "$0"
  ;;
apply)
  step "APPLY — system-camera unlock"
  run plan "$UNLOCK_SITES" "$UNLOCK_BK" | show_sites 2>/dev/null
  printf '  %sWrite the four unlock sites? [y/N] %s' "$BLD" "$RST"; read -r a
  case "$a" in y|Y);; *) die "aborted";; esac
  out="$(run apply "$UNLOCK_SITES" "$UNLOCK_BK")"; echo "$out"
  if echo "$out" | grep -q '"ok": true'; then
    ok "unlock patched. Camera enumeration now:"
    su -c "dumpsys media.camera | grep -E 'Number of camera'"
    printf '\n  Revert: %s --revert   (or reboot)\n\n' "$0"
  else
    warn "unlock problem (see above). Reboot to be safe."
  fi
  ;;
revert)
  step "REVERT — restore original cameraserver bytes"
  run revert "$UNLOCK_SITES" "$UNLOCK_BK"
  echo; ok "reboot also restores stock"
  ;;
status)
  step "STATUS — system-camera unlock"
  run status "$UNLOCK_SITES" "$UNLOCK_BK" | show_sites
  echo
  ;;
install)
  step "INSTALL boot service (re-applies the unlock every boot)"
  warn "prefer the packaged module in magisk-module/. The SELinux ptrace rule is"
  warn "added only if needed and removed immediately — no standing rule is kept."
  printf '  %sType exactly: I ACCEPT  %s' "$BLD" "$RST"; read -r a
  [ "$a" = "I ACCEPT" ] || die "not accepted"
  M=/data/adb/modules/reject_bypass
  su -c "mkdir -p $M"
  su -c "cp $TMP/rb.py $M/rb.py" 2>/dev/null || { su -c "$MP --live \"allow su cameraserver process ptrace\""; run plan "$UNLOCK_SITES" "$UNLOCK_BK" >/dev/null; su -c "cp $TMP/rb.py $M/rb.py"; }
  su -c "cat > $M/module.prop" <<EOF
id=reject_bypass
name=cameraserver system-camera reject bypass
version=2.0
versionCode=3
author=local
description=Re-applies the RAM patch (system-camera unlock) each boot. Adds the SELinux ptrace rule only if needed and removes it immediately (no standing rule).
EOF
  su -c "cat > $M/service.sh" <<EOF
#!/system/bin/sh
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 10
# Try the patch first; only add the SELinux ptrace rule if blocked, then remove it
# again so no standing rule is left in the live policy (which would trip Play Protect).
out="\$($PY3 $M/rb.py apply "$UNLOCK_SITES" "$UNLOCK_BK" 2>/dev/null)"
case "\$out" in
  *"not permitted"*|*"Permission denied"*|"")
    $MP --live "allow su cameraserver process ptrace"
    $PY3 $M/rb.py apply "$UNLOCK_SITES" "$UNLOCK_BK"
    $MP --live "deny su cameraserver process ptrace"
    ;;
esac
EOF
  su -c "chmod 0755 $M/service.sh"; su -c "chmod 0644 $M/module.prop $M/rb.py"
  ok "installed at $M — re-applies the unlock each boot"
  printf "  Remove: %s --uninstall\n\n" "$0";;
uninstall)
  step "UNINSTALL boot service"
  su -c "rm -rf /data/adb/modules/reject_bypass"
  ok "removed; reboot to fully clear"; echo;;
esac
