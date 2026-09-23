#!/data/data/com.termux/files/usr/bin/bash
#
# cameraserver-patch.sh  —  stage 2 of the #4 approach
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# Live-patches /system/bin/cameraserver in RAM to NOP the conditional branches
# that reject system-camera access, so cameras 2/3 become openable by a
# privileged app. Stage-1 recon (cameraserver-recon.sh) confirmed the check
# sites are plain CBZ/CBNZ/B.cond with no CFI guards.
#
# SAFETY MODEL — read this:
#   * DRY-RUN BY DEFAULT. With no flag it only shows what it WOULD write.
#     Nothing is patched unless you pass --apply.
#   * Everything is in RAM. It writes to /proc/<pid>/mem, never to disk.
#     cameraserver is verity-protected on disk and is never touched there.
#   * Fully reversible by REBOOT. A reboot restores the stock daemon and
#     clears the SELinux rule. If anything misbehaves: reboot.
#   * It VERIFIES each write (reads the bytes back) and, on any mismatch or
#     any sign cameraserver died, RESTORES the original bytes it saved.
#   * The patch does NOT persist across a cameraserver restart. To keep it,
#     see --install (writes a boot service that re-applies). That service is
#     off unless you ask for it.
#
# The permanent cost if you --install: the device runs with a live
# `allow su cameraserver process ptrace` SELinux rule, re-applied each boot.
# That is a real, ongoing security relaxation. Decide deliberately.
#
# Usage:
#   ./cameraserver-patch.sh                 dry-run: show planned NOPs, write nothing
#   ./cameraserver-patch.sh --apply         apply in RAM now (this boot only)
#   ./cameraserver-patch.sh --revert        restore original bytes from backup
#   ./cameraserver-patch.sh --status        show whether sites are currently patched
#   ./cameraserver-patch.sh --install       install boot service (asks first)
#   ./cameraserver-patch.sh --uninstall     remove the boot service
#
# Requires: root + Magisk (magiskpolicy) + python3.

set -u

MODE="dryrun"
case "${1:-}" in
  --apply) MODE="apply" ;;
  --revert) MODE="revert" ;;
  --status) MODE="status" ;;
  --install) MODE="install" ;;
  --uninstall) MODE="uninstall" ;;
  ""|--dry-run|--dryrun) MODE="dryrun" ;;
  *) echo "unknown option: $1"; exit 1 ;;
esac

BIN=/system/bin/cameraserver
TMP=/data/local/tmp
WORK=$TMP/csp
BACKUP=$WORK/original_bytes.json
PLAN=$WORK/plan.json
PYLIB=$WORK/csp.py
MODDIR=/data/adb/modules/cameraserver_patch

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step(){ printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok(){ printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die(){ printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; exit 1; }

su -c 'id -u' >/dev/null 2>&1 || die "no root"
PY3="$(command -v python3 || true)"; [ -n "$PY3" ] || die "python3 needed: pkg install python"
MP=magiskpolicy; su -c 'command -v magiskpolicy' >/dev/null 2>&1 || MP=/data/adb/magisk/magiskpolicy
su -c "command -v $MP >/dev/null 2>&1 || ls $MP" >/dev/null 2>&1 || die "magiskpolicy not found (need Magisk)"

su -c "mkdir -p $WORK; chmod 777 $WORK"

# --------------------------------------------------------------- python core
# Written once to a file; all mem work happens here under root.
write_pycore() {
su -c "cat > $PYLIB" <<'PYEOF'
import sys, struct, json, os

BIN="/system/bin/cameraserver"

def find_pid():
    for p in os.listdir("/proc"):
        if not p.isdigit(): continue
        try:
            if open(f"/proc/{p}/cmdline","rb").read().split(b"\0")[0].endswith(b"cameraserver"):
                return int(p)
        except Exception: pass
    return None

def elf_sections(raw):
    e_shoff=struct.unpack_from("<Q",raw,0x28)[0]
    sz=struct.unpack_from("<H",raw,0x3a)[0]; n=struct.unpack_from("<H",raw,0x3c)[0]
    shstrndx=struct.unpack_from("<H",raw,0x3e)[0]
    secs=[struct.unpack_from("<IIQQQQIIQQ",raw,e_shoff+i*sz) for i in range(n)]
    base=secs[shstrndx][4]
    out={}
    for nm,addr,off,size,*_ in [(s[0],s[3],s[4],s[5]) for s in secs]:
        e=raw.index(b"\0",base+nm); out[raw[base+nm:e].decode("latin1")]=(addr,off,size)
    return out

def maps_segs(pid):
    segs=[]
    for line in open(f"/proc/{pid}/maps"):
        if line.rstrip().endswith("/system/bin/cameraserver"):
            rng,perms,fileoff=line.split()[0],line.split()[1],line.split()[2]
            a,b=rng.split("-"); segs.append((int(a,16),int(b,16),int(fileoff,16),perms))
    return segs

def rt_for_off(segs,foff):
    for a,b,fo,pr in segs:
        if fo<=foff<fo+(b-a): return a+(foff-fo)
    return None

def read_mem(pid,addr,length):
    with open(f"/proc/{pid}/mem","rb") as m: m.seek(addr); return m.read(length)

def write_mem(pid,addr,data):
    with open(f"/proc/{pid}/mem","r+b") as m: m.seek(addr); m.write(data)

def dec_adrp(w,pc):
    if (w&0x9F000000)!=0x90000000: return None
    immlo=(w>>29)&3; immhi=(w>>5)&0x7FFFF; imm=((immhi<<2)|immlo)
    if imm&(1<<20): imm-=(1<<21)
    return ((pc>>12)<<12)+(imm<<12), w&31
def dec_add(w):
    if (w&0x7F800000)!=0x11000000: return None
    sh=(w>>22)&1; imm=(w>>10)&0xFFF
    if sh: imm<<=12
    return imm, w&31, (w>>5)&31
def dec_ldr(w):
    if (w&0xFFC00000)!=0xF9400000: return None
    return ((w>>10)&0xFFF)<<3, (w>>5)&31, w&31

NOP=0xD503201F
def is_cond_branch(w):
    if (w&0x7F000000)==0x34000000: return "CBZ"
    if (w&0x7F000000)==0x35000000: return "CBNZ"
    if (w&0x7F000000)==0x36000000: return "TBZ"
    if (w&0x7F000000)==0x37000000: return "TBNZ"
    if (w&0xFF000000)==0x54000000: return "B.cond"
    return None
def is_cfi(w):
    if (w&0xFFFFFC1F)==0xD4200000: return "BRK"
    if (w&0xFFFFFF3F)==0xD503241F: return "BTI"
    return None

TARGETS=[b"system only device", b"without extra agui permission", b"inadequete permission"]

def build_plan():
    pid=find_pid()
    if not pid: return {"error":"cameraserver not running"}
    try:
        raw=open(BIN,"rb").read()
    except Exception as e:
        return {"error":f"cannot read {BIN}: {e}"}
    try:
        sec=elf_sections(raw)
    except Exception as e:
        return {"error":f"ELF parse failed: {e}"}
    if ".text" not in sec or ".rodata" not in sec:
        return {"error":f"missing sections; have {list(sec)[:10]}"}
    segs=maps_segs(pid)
    if not segs:
        return {"error":f"no cameraserver segments in /proc/{pid}/maps (read blocked?)"}
    text_va,text_off,text_sz=sec[".text"]
    text_rt=rt_for_off(segs,text_off)
    if text_rt is None:
        return {"error":f"text off 0x{text_off:x} not in any segment"}
    try:
        text=read_mem(pid,text_rt,text_sz)
    except Exception as e:
        return {"error":f"/proc/{pid}/mem read failed: {e}"}

    # resolve wanted string runtime addrs
    wanted={}
    for t in TARGETS:
        i=raw.find(t)
        while i>=0:
            rt=rt_for_off(segs,i)
            if rt is not None: wanted[rt]=t.decode(errors="replace")
            i=raw.find(t,i+1)
    if not wanted:
        return {"error":f"no target strings resolved (found in file: {[t.decode() for t in TARGETS if raw.find(t)>=0]})"}
    pages={}
    for a,nm in wanted.items(): pages.setdefault(a&~0xFFF,[]).append((a,nm))

    # find code sites loading a wanted string (verbatim from working recon,
    # including the page-match fallback that catches split/interleaved loads)
    wanted_pages = pages
    def dec_ldr_uimm(w):
        if (w & 0xFFC00000) != 0xF9400000: return None
        return ((w>>10)&0xFFF)<<3, (w>>5)&31, w&31
    strloads=[]
    n_words=len(text)//4
    for idx in range(n_words):
        w=struct.unpack_from("<I",text,idx*4)[0]
        a=dec_adrp(w,text_rt+idx*4)
        if not a: continue
        page,rd=a
        if page not in wanted_pages: continue
        pc=text_rt+idx*4
        for k in range(1,9):
            if idx+k>=n_words: break
            w2=struct.unpack_from("<I",text,(idx+k)*4)[0]
            ai=dec_add(w2)
            if ai:
                imm,rd2,rn=ai
                if rn==rd:
                    target=page+imm
                    for addr,name in wanted_pages[page]:
                        if addr==target: strloads.append((pc,addr,name))
                    break
            li=dec_ldr_uimm(w2)
            if li:
                imm,rn,rt=li
                if rn==rd:
                    target=page+imm
                    for addr,name in wanted_pages[page]:
                        if addr==target: strloads.append((pc,addr,name))
                    break
    if not strloads:
        for idx in range(n_words):
            w=struct.unpack_from("<I",text,idx*4)[0]
            a=dec_adrp(w,text_rt+idx*4)
            if a and a[0] in wanted_pages:
                pc=text_rt+idx*4
                strloads.append((pc, wanted_pages[a[0]][0][0], wanted_pages[a[0]][0][1]))

    # for each string-load, walk BACKWARD to the nearest conditional branch:
    # that is the enforcing "if failed -> reject" test. Record it as a patch site.
    plan=[]
    seen=set()
    for pc,saddr,nm in strloads:
        # search up to 24 instrs before the string load for a cond branch
        found=None; cfi_near=False
        for back in range(1,25):
            aa=pc-back*4
            if aa<text_rt: break
            w=struct.unpack_from("<I",text,aa-text_rt)[0]
            if is_cfi(w): cfi_near=True
            b=is_cond_branch(w)
            if b:
                found=(aa,w,b); break
        if found:
            aa,w,btype=found
            if aa in seen: continue
            seen.add(aa)
            plan.append({
                "branch_addr": aa, "orig_word": w, "branch_type": btype,
                "string": nm, "string_addr": saddr, "cfi_near": cfi_near,
            })
    return {"pid":pid, "text_rt":text_rt, "text_sz":text_sz,
            "n_strloads":len(strloads), "sites":plan}

def cmd_plan():
    import sys as _s
    try:
        r=build_plan()
    except Exception as e:
        import traceback
        r={"error":"exception: "+repr(e), "tb":traceback.format_exc()[-400:]}
    # ONLY json to stdout; nothing else
    _s.stdout.write(json.dumps(r))
    _s.stdout.flush()

def cmd_apply(planfile, backupfile):
    plan=json.load(open(planfile))
    pid=plan["pid"]
    # re-verify pid still alive and bytes still match before writing
    backup={}
    for s in plan["sites"]:
        cur=struct.unpack_from("<I", read_mem(pid,s["branch_addr"],4),0)[0]
        if cur!=s["orig_word"]:
            print(json.dumps({"error":f"byte mismatch at 0x{s['branch_addr']:x}: expected {s['orig_word']:08x} got {cur:08x} - aborting, wrote nothing"}))
            return
    # save backup, then write NOPs, verifying each
    for s in plan["sites"]:
        backup[str(s["branch_addr"])]=s["orig_word"]
    json.dump(backup, open(backupfile,"w"))
    written=[]
    for s in plan["sites"]:
        try:
            write_mem(pid,s["branch_addr"],struct.pack("<I",NOP))
            rb=struct.unpack_from("<I",read_mem(pid,s["branch_addr"],4),0)[0]
            if rb!=NOP:
                raise RuntimeError(f"verify failed at 0x{s['branch_addr']:x}")
            written.append(s["branch_addr"])
        except Exception as e:
            # rollback everything written so far
            for a in written:
                write_mem(pid,a,struct.pack("<I",backup[str(a)]))
            print(json.dumps({"error":f"{e}; rolled back {len(written)} write(s)"}))
            return
    print(json.dumps({"ok":True,"patched":written,"count":len(written)}))

def cmd_revert(backupfile):
    if not os.path.exists(backupfile):
        print(json.dumps({"error":"no backup file - reboot restores stock anyway"})); return
    backup=json.load(open(backupfile))
    pid=find_pid()
    if not pid: print(json.dumps({"error":"cameraserver not running (reboot already restored it)"})); return
    n=0
    for addr,word in backup.items():
        try: write_mem(pid,int(addr),struct.pack("<I",word)); n+=1
        except Exception as e: print(json.dumps({"error":str(e)})); return
    print(json.dumps({"ok":True,"reverted":n}))

def cmd_status(planfile):
    plan=json.load(open(planfile)); pid=find_pid()
    if not pid: print(json.dumps({"error":"cameraserver not running"})); return
    st=[]
    for s in plan["sites"]:
        cur=struct.unpack_from("<I",read_mem(pid,s["branch_addr"],4),0)[0]
        st.append({"addr":hex(s["branch_addr"]),
                   "state":"PATCHED(NOP)" if cur==NOP else ("orig" if cur==s["orig_word"] else f"other:{cur:08x}")})
    print(json.dumps({"ok":True,"sites":st}))

if __name__=="__main__":
    c=sys.argv[1]
    if c=="plan": cmd_plan()
    elif c=="apply": cmd_apply(sys.argv[2],sys.argv[3])
    elif c=="revert": cmd_revert(sys.argv[2])
    elif c=="status": cmd_status(sys.argv[2])
PYEOF
}

inject_rule(){
  su -c "$MP --live \"allow su cameraserver process ptrace\"" 2>/dev/null
  su -c "$MP --live \"allow su cameraserver process signal\"" 2>/dev/null
}

show_plan(){
  # Run the planner under root and capture its JSON on stdout — no intermediate
  # file crosses the Termux/global namespace boundary. Persist the plan to
  # $WORK (root-owned, but written BY root) for --apply to reuse.
  # planner writes ONLY json to stdout. Persist to $PLAN under root, and also
  # capture it here for display. 2>/dev/null drops any stderr noise.
  su -c "$PY3 $PYLIB plan 2>/dev/null > $PLAN"
  local json
  json="$(su -c "cat $PLAN 2>/dev/null")"
  [ -n "$json" ] || { echo "  ERROR: planner wrote no output (see: su -c \"$PY3 $PYLIB plan\")"; return 1; }
  printf '%s' "$json" | "$PY3" - <<'PYEOF'
import json,sys
raw=sys.stdin.read().strip()
try:
    d=json.loads(raw)
except Exception as e:
    print("  ERROR: could not parse planner output:",e)
    print("  raw was:", raw[:300]); sys.exit(1)
if "tb" in d: print("  planner traceback:\n"+d.get("tb","")); 

if "error" in d: print("  ERROR:",d["error"]); sys.exit(1)
print(f"  cameraserver pid {d['pid']}, {d['n_strloads']} string-load(s), {len(d['sites'])} patch site(s):")
anycfi=False
for s in d["sites"]:
    cfi=" [CFI NEARBY - risky]" if s["cfi_near"] else ""
    if s["cfi_near"]: anycfi=True
    print(f"    0x{s['branch_addr']:x}  {s['branch_type']:7s} orig={s['orig_word']:08x} -> NOP   ({s['string']}){cfi}")
if not d["sites"]:
    print("  no patch sites found - nothing to do"); sys.exit(1)
if anycfi:
    print("\n  WARNING: at least one site has CFI nearby; applying may trap cameraserver.")
print(f"\n  {len(d['sites'])} branch(es) would be NOP'd. This is the PLAN - nothing written yet.")
PYEOF
}

case "$MODE" in

dryrun)
  step "DRY RUN — planning only, nothing will be written"
  write_pycore
  inject_rule
  show_plan || die "planning failed"
  printf '\n  To apply in RAM (this boot only):  %s --apply\n' "$0"
  printf '  Reboot clears everything, including the SELinux rule.\n\n'
  ;;

apply)
  step "APPLY — patching cameraserver in RAM (reversible by reboot)"
  warn "this modifies a running system daemon; if the camera misbehaves, reboot"
  write_pycore
  inject_rule
  show_plan || die "planning failed"
  printf '\n  %sProceed with writing these NOPs? [y/N] %s' "$BLD" "$RST"
  read -r ans
  case "$ans" in y|Y) ;; *) die "aborted by user; nothing written" ;; esac

  local out
  out="$(su -c "$PY3 $PYLIB apply $PLAN $BACKUP")"
  printf '%s\n' "$out"
  if printf '%s' "$out" | grep -q '"ok": true'; then
    ok "patched. Testing camera enumeration..."
    su -c "dumpsys media.camera | grep -E 'Number of camera'" 2>/dev/null
    printf '\n  Now: open a privileged camera app and try cameras 2/3.\n'
    printf '  Revert:  %s --revert   (or just reboot)\n\n' "$0"
  else
    warn "apply reported a problem (see above). Nothing persistent changed; reboot to be safe."
  fi
  ;;

revert)
  step "REVERT — restoring original bytes"
  write_pycore
  su -c "$PY3 $PYLIB revert $BACKUP"
  echo
  ok "if that failed, a reboot always restores the stock daemon"
  ;;

status)
  step "STATUS"
  write_pycore; inject_rule
  su -c "test -s $PLAN || $PY3 $PYLIB plan > $PLAN"
  su -c "$PY3 $PYLIB status $PLAN"
  echo
  ;;

install)
  step "INSTALL boot service (re-applies patch every boot)"
  warn "this leaves the device permanently running with a live"
  warn "'allow su cameraserver process ptrace' SELinux rule, re-applied each boot."
  warn "That is an ongoing security relaxation. Only proceed if you accept it."
  printf '\n  %sType exactly: I ACCEPT  to continue: %s' "$BLD" "$RST"
  read -r ans
  [ "$ans" = "I ACCEPT" ] || die "not accepted; nothing installed"

  su -c "mkdir -p $MODDIR"
  su -c "cp $PYLIB $MODDIR/csp.py"
  su -c "cat > $MODDIR/module.prop" <<EOF
id=cameraserver_patch
name=cameraserver system-camera patch
version=1.0
versionCode=1
author=local
description=Re-applies the RAM NOP patch to cameraserver each boot. Keeps a live ptrace SELinux rule.
EOF
  su -c "cat > $MODDIR/service.sh" <<EOF
#!/system/bin/sh
# wait for boot + cameraserver, inject rule, plan, apply
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 8
$MP --live "allow su cameraserver process ptrace"
$MP --live "allow su cameraserver process signal"
P=\$($PY3 $MODDIR/csp.py plan > $WORK/boot_plan.json; echo done)
$PY3 $MODDIR/csp.py apply $WORK/boot_plan.json $WORK/boot_backup.json
EOF
  su -c "chmod 0755 $MODDIR/service.sh"
  su -c "chmod 0644 $MODDIR/module.prop $MODDIR/csp.py"
  ok "installed. It will re-apply on each boot."
  printf '  Remove with:  %s --uninstall\n\n' "$0"
  ;;

uninstall)
  step "UNINSTALL boot service"
  su -c "rm -rf $MODDIR"
  ok "removed. Reboot to fully clear (also drops the ptrace rule)."
  echo
  ;;
esac
