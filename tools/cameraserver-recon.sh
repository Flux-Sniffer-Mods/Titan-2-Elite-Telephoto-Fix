#!/data/data/com.termux/files/usr/bin/bash
#
# cameraserver-recon.sh  —  READ-ONLY reconnaissance
#
#   Repo: https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
#
# Purpose: locate the four system-camera check sites inside /system/bin/cameraserver
# so their patch offsets can be derived — needed when a firmware update moves them
# from the values baked into reject-bypass.sh. It only READS the binary and the
# running process; it modifies nothing. Requires radare2 with the r2ghidra plugin.
# It:
#   1. injects a live SELinux rule allowing ptrace of cameraserver
#   2. locates the loaded cameraserver .text in memory
#   3. finds the five "system only device" check sites and disassembles
#      the branch logic around each
#   4. reports whether they look NOP-able
#
# It does NOT write to cameraserver's memory. Nothing is patched. The only
# system change is the injected SELinux rule, which this script REMOVES again
# at the end (and which does not survive reboot anyway, being --live).
#
# Requires: root + Magisk (for magiskpolicy), and one of: gdb, or Python.
#   pkg install gdb binutils python
#
# Recovery note: this touches nothing persistent. A reboot returns the device
# to exactly its prior state regardless of what happens here.

set -u

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
step(){ printf '\n%s==> %s%s\n' "$BLD" "$*" "$RST"; }
ok(){ printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '  %s[!]%s  %s\n' "$YLW" "$RST" "$*"; }
die(){ printf '\n%s[FAIL]%s %s\n\n' "$RED" "$RST" "$*" >&2; cleanup; exit 1; }

RULE_ADDED=0
cleanup(){
  if [ "$RULE_ADDED" = "1" ]; then
    # There is no rule that negates an injected allow within a boot. The honest
    # position: the allow persists until reboot, which fully clears --live rules.
    printf '  %s[cleanup]%s injected ptrace rule stays until reboot; reboot to clear it\n' "$YLW" "$RST"
  fi
}
trap cleanup EXIT

BIN=/system/bin/cameraserver
# /data/local/tmp is one mount visible identically to Termux and to root's
# global namespace — unlike $HOME, which in a Termux-in-chroot setup is a
# private mount root does not see the same way. All I/O stays here.
OUT=/data/local/tmp/cameraserver-recon.txt
su -c ": > $OUT; chmod 666 $OUT"

# ------------------------------------------------------------------ preflight
step "Preflight"
su -c 'id -u' >/dev/null 2>&1 || die "no root"
command -v su >/dev/null || die "no su"
su -c 'command -v magiskpolicy' >/dev/null 2>&1 \
  || su -c 'ls /data/adb/magisk/magiskpolicy' >/dev/null 2>&1 \
  || die "magiskpolicy not found (need Magisk)"
MP="magiskpolicy"; su -c 'command -v magiskpolicy' >/dev/null 2>&1 || MP="/data/adb/magisk/magiskpolicy"
ok "root + magiskpolicy present"

getenf=$(su -c getenforce)
ok "SELinux: $getenf"

PID=$(su -c "pidof cameraserver" | awk '{print $1}')
[ -n "$PID" ] || die "cameraserver not running"
ok "cameraserver pid: $PID"

HAVE_GDB=0; su -c "command -v gdb" >/dev/null 2>&1 && HAVE_GDB=1
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] && HAVE_PY=1 || HAVE_PY=0
ok "tools: gdb=$HAVE_GDB python3=$HAVE_PY"

# ------------------------------------------------------- inject ptrace rule
step "Injecting live SELinux rule (allow su -> cameraserver ptrace)"
warn "this is the only system change; it is reverted on exit and cleared on reboot"
su -c "$MP --live \"allow su cameraserver process ptrace\"" || die "magiskpolicy failed"
su -c "$MP --live \"allow su cameraserver process signal\"" 2>/dev/null
RULE_ADDED=1
ok "rule injected"

# --------------------------------------------------- locate .text in memory
step "Locating cameraserver's loaded code"
{
  echo "== maps (executable regions of the main binary) =="
  su -c "cat /proc/$PID/maps" | grep -E "r-xp .*cameraserver$"
} | tee -a "$OUT"
BASE=$(su -c "cat /proc/$PID/maps" | grep -E "r-xp .*/system/bin/cameraserver$" | head -1 | cut -d- -f1)
[ -n "$BASE" ] && ok "text base: 0x$BASE" || warn "could not read exec base from maps"

# --------------------------------------------- find the check-site strings
step "Finding the 'system only device' string references in the binary"
{
  echo
  echo "== the five enforcement strings and their file offsets =="
} >> "$OUT"
# get file offsets of the strings (static), then we map to runtime via base
su -c "strings -t x $BIN" 2>/dev/null | grep -iE "system only device|extra agui permission|inadequete permission" | tee -a "$OUT"

# ---------------------------------------------------- disassemble around them
step "Reading the check sites (READ ONLY via /proc/$PID/mem)"
# This path needs only the ptrace rule + root, not gdb. It reads the mapped
# .text, finds the runtime addresses of the enforcement strings, scans for
# adrp/add pairs that reference them (how AArch64 loads a string address),
# and dumps the 16 instructions before each — where the enforcing branch sits.
su -c "cat /proc/$PID/maps > /data/local/tmp/.cs_maps 2>/dev/null; cp $BIN /data/local/tmp/.cs_bin; chmod 666 /data/local/tmp/.cs_maps /data/local/tmp/.cs_bin"

if [ "$HAVE_PY" = "1" ]; then
  su -c "$PY3 - $PID /data/local/tmp/.cs_maps /data/local/tmp/.cs_bin" <<'PYEOF' | tee -a "$OUT" | tail -70
import sys, struct
pid, maps_path, bin_path = sys.argv[1], sys.argv[2], sys.argv[3]

raw = open(bin_path, "rb").read()

# ---- parse ELF64 section headers: name -> (vaddr, offset, size) ----
e_shoff = struct.unpack_from("<Q", raw, 0x28)[0]
e_shentsize = struct.unpack_from("<H", raw, 0x3a)[0]
e_shnum = struct.unpack_from("<H", raw, 0x3c)[0]
e_shstrndx = struct.unpack_from("<H", raw, 0x3e)[0]
secs = []
for i in range(e_shnum):
    o = e_shoff + i*e_shentsize
    name,typ,flags,addr,off,size,link,info,align,entsz = struct.unpack_from("<IIQQQQIIQQ", raw, o)
    secs.append((name,addr,off,size))
shstr = secs[e_shstrndx][2]
def secname(n):
    e = raw.index(b"\0", shstr+n); return raw[shstr+n:e].decode("latin1")
sections = {}
for name,addr,off,size in secs:
    sections[secname(name)] = (addr, off, size)

text_va, text_off, text_sz = sections.get(".text", (0,0,0))
rodata_va, rodata_off, rodata_sz = sections.get(".rodata", (0,0,0))
print(f"  ELF: .text vaddr=0x{text_va:x} off=0x{text_off:x} size=0x{text_sz:x}")
print(f"       .rodata vaddr=0x{rodata_va:x} off=0x{rodata_off:x} size=0x{rodata_sz:x}")

# ---- parse /proc/pid/maps: list (start,end,fileoff,perms) for the binary ----
segs = []
for line in open(maps_path):
    if line.rstrip().endswith("/system/bin/cameraserver"):
        rng, perms, fileoff = line.split()[0], line.split()[1], line.split()[2]
        a,b = rng.split("-")
        segs.append((int(a,16), int(b,16), int(fileoff,16), perms))
for a,b,fo,pr in segs:
    print(f"  seg 0x{a:x}-0x{b:x} off=0x{fo:x} {pr}")

def runtime_addr_for_fileoff(foff):
    # find the segment whose file range contains foff, map to runtime
    for a,b,fo,pr in segs:
        span = b - a
        if fo <= foff < fo + span:
            return a + (foff - fo)
    return None

def read_mem(addr, length):
    with open(f"/proc/{pid}/mem","rb") as m:
        m.seek(addr); return m.read(length)

# ---- find each enforcement string's RUNTIME address via its file offset ----
targets = [b"system only device", b"without extra agui permission", b"inadequete permission"]
# locate them in the file first (rodata)
strfile = {}
for t in targets:
    i = raw.find(t)
    while i >= 0:
        strfile.setdefault(t, []).append(i)
        i = raw.find(t, i+1)
wanted = {}   # runtime_addr -> string
for t, offs in strfile.items():
    for fo in offs:
        rt = runtime_addr_for_fileoff(fo)
        if rt:
            wanted[rt] = t.decode(errors="replace")
            print(f"  '{t.decode(errors='replace')}' file@0x{fo:x} -> runtime 0x{rt:x}")

if not wanted:
    print("  no enforcement strings resolved to runtime addresses"); sys.exit(0)

# ---- read live .text and scan for adrp+add referencing those addrs ----
text_rt = runtime_addr_for_fileoff(text_off)
try:
    text = read_mem(text_rt, text_sz)
    print(f"  read {len(text)} bytes live .text @ 0x{text_rt:x}")
except Exception as e:
    print(f"  .text read failed: {e}"); sys.exit(0)

def dec_adrp(w, pc):
    if (w & 0x9F000000) != 0x90000000: return None
    immlo=(w>>29)&3; immhi=(w>>5)&0x7FFFF
    imm=((immhi<<2)|immlo)
    if imm & (1<<20): imm-=(1<<21)
    return ((pc>>12)<<12)+(imm<<12), w & 31
def dec_add(w):
    if (w & 0x7F800000) != 0x11000000: return None
    sh=(w>>22)&1; imm=(w>>10)&0xFFF
    if sh: imm<<=12
    return imm, w&31, (w>>5)&31
def dec_ldr_lit(w, pc):
    # LDR (literal) sometimes used for string ptrs
    return None

# Scan for adrp whose target PAGE matches a wanted string's page, then look
# ahead up to 8 instructions for an add/ldr that completes the low bits.
# This catches interleaved and split address loads that a strict adrp+add
# adjacency test misses.
wanted_pages = {}
for addr, name in wanted.items():
    wanted_pages.setdefault(addr & ~0xFFF, []).append((addr, name))

def dec_ldr_uimm(w):
    # LDR (immediate, unsigned offset), 64-bit: 11 111 0 01 01 imm12 Rn Rt
    if (w & 0xFFC00000) != 0xF9400000: return None
    imm = ((w>>10)&0xFFF) << 3
    return imm, (w>>5)&31, w&31   # (byte offset, Rn, Rt)

sites=[]
n_words = len(text)//4
for idx in range(n_words):
    w = struct.unpack_from("<I", text, idx*4)[0]
    a = dec_adrp(w, text_rt + idx*4)
    if not a: continue
    page, rd = a
    if page not in wanted_pages: continue
    pc = text_rt + idx*4
    # look ahead for the low-bits completion using register rd
    for k in range(1, 9):
        if idx+k >= n_words: break
        w2 = struct.unpack_from("<I", text, (idx+k)*4)[0]
        ai = dec_add(w2)
        if ai:
            imm, rd2, rn = ai
            if rn == rd:
                target = page + imm
                for addr,name in wanted_pages[page]:
                    if addr == target:
                        sites.append((pc, addr, name)); 
                break
        li = dec_ldr_uimm(w2)
        if li:
            imm, rn, rt = li
            if rn == rd:
                target = page + imm
                for addr,name in wanted_pages[page]:
                    if addr == target:
                        sites.append((pc, addr, name));
                break
    # also record page-only matches as candidates even if low bits not found,
    # so we never silently miss a site
if not sites:
    # fallback: report all adrp hits to the wanted pages so we can inspect manually
    for idx in range(n_words):
        w = struct.unpack_from("<I", text, idx*4)[0]
        a = dec_adrp(w, text_rt + idx*4)
        if a and a[0] in wanted_pages:
            pc = text_rt + idx*4
            nm = wanted_pages[a[0]][0][1]
            sites.append((pc, wanted_pages[a[0]][0][0], nm + " [page-match only]"))

print(f"\n  found {len(sites)} code site(s) loading an enforcement string:")
def cls(w):
    if (w&0x7F000000)==0x34000000: return "CBZ"
    if (w&0x7F000000)==0x35000000: return "CBNZ"
    if (w&0x7F000000)==0x36000000: return "TBZ"
    if (w&0x7F000000)==0x37000000: return "TBNZ"
    if (w&0xFF000000)==0x54000000: return "B.cond"
    if w==0xD503201F: return "NOP"
    if (w&0xFC000000)==0x14000000: return "B"
    if (w&0xFC000000)==0x94000000: return "BL"
    if (w&0xFFFFFC1F)==0xD65F0000: return "RET"
    if (w&0xFFFFFC1F)==0xD4200000: return "BRK"
    if (w&0xFFFFFC1F)==0xD503241F or (w&0xFFFFFF1F)==0xD503241F: return "BTI"
    return ""
for pc, addr, name in sites[:10]:
    print(f"\n  --- '{name}' @ 0x{addr:x}  loaded by code @ 0x{pc:x} ---")
    lo = pc - 20*4
    for aa in range(lo, pc+8, 4):
        w = struct.unpack_from("<I", text, aa-text_rt)[0]
        tag = cls(w)
        mark = " <== BRANCH" if tag in ("CBZ","CBNZ","TBZ","TBNZ","B.cond") else (" <== CFI" if tag in ("BRK","BTI") else "")
        print(f"    0x{aa:x}: {w:08x}  {tag}{mark}")

print("\n  READ COMPLETE - nothing written.")
PYEOF
else
  warn "python3 not available; install it: pkg install python"
fi
su -c "rm -f /data/local/tmp/.cs_maps /data/local/tmp/.cs_bin"

# optional gdb cross-check if present
if [ "$HAVE_GDB" = "1" ]; then
  step "gdb cross-check (read-only attach)"
  su -c "cat > /data/local/tmp/.recon.gdb" <<GDB
set pagination off
attach $PID
info functions SystemCamera
detach
quit
GDB
  su -c "gdb -q -x /data/local/tmp/.recon.gdb" 2>&1 | grep -iE "SystemCamera|hasPermission" | head -10 | tee -a "$OUT"
  su -c "rm -f /data/local/tmp/.recon.gdb"
fi

# ------------------------------------------------------------------- verdict
step "Verdict"
{
  echo
  echo "== what to look for in the above =="
  echo "For each 'system only device' site, the enforcing pattern is:"
  echo "   <call permission/tee check>  -> result in w0"
  echo "   cbz/cbnz or tbz/tbnz w0, <reject>   <- THE BRANCH"
  echo "   ...reject path loads the 'system only device' string..."
  echo
  echo "PATCHABLE if: each site is a single conditional branch we can invert"
  echo "  or NOP so it always takes the allow path. Five sites = five edits."
  echo "NOT cleanly patchable if: the checks are inlined/duplicated, CFI-guarded"
  echo "  (look for 'brk' landing pads / bti), or the branch target is computed."
} | tee -a "$OUT"

su -c "chmod 666 $OUT"
ok "report: $OUT"
printf '\n  Nothing was patched. Read it with:\n'
printf '    cat %s\n' "$OUT"
printf '  or:  cp %s /sdcard/  (then open from a file manager)\n' "$OUT"
printf '  branches are cleanly NOP-able before any write is attempted.\n\n'
