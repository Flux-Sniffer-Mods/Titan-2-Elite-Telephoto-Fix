# Titan 2 Elite Telephoto Fix

Enable the **6.80 mm optical telephoto camera** on the Unihertz Titan 2 Elite in
Google Camera (GCam). The lens is physically present but hidden by the stock
firmware; this project unlocks it and adds telephoto photo and video to GCam.

- **Telephoto video** works in GCam's normal video mode — zoom past ~2× and the
  camera hardware switches to the 6.8 mm lens.
- **Telephoto photos** work through a one-tap **TELE** button added inside GCam,
  producing Google-processed 6.8 mm JPEGs in your gallery.

The device must be **rooted with Magisk**. Everything runs on the phone; no PC is
required.

---

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Using it](#using-it)
- [Troubleshooting](#troubleshooting)
- [Background: what this fixes](#background-what-this-fixes)
- [How it works, in depth (the investigation)](#how-it-works-in-depth-the-investigation)
- [Building it yourself](#building-it-yourself)
- [Repository layout](#repository-layout)
- [Reverting / uninstalling](#reverting--uninstalling)
- [Credits and license](#credits-and-license)

---

## Requirements

- **Unihertz Titan 2 Elite**, bootloader unlocked, **rooted with Magisk**.
- A **Google Camera port** for the device. This project was built and tested
  against `IlluminatiEliteGCam_v1.4_Titan2Elite.apk` (Google Camera 8.4.300,
  Android package `com.google.android.GoogleCameraEngR18F1`). The release module
  bundles a patched build of this port.
- About 200 MB free storage for the install.

> **Firmware version matters.** Part of the fix is a byte patch to the system
> `cameraserver` process, and the patch locations are specific to cameraserver
> build `6410613c`. A firmware/OTA update can move them. The installer detects a
> mismatch and warns you; if that happens, the offsets must be re-derived (see
> [Re-deriving offsets after a firmware update](#re-deriving-offsets-after-a-firmware-update)).

---

## Install

The entire install is a single Magisk module.

1. Download **`titan2-telephoto-FULL.zip`** from the
   [Releases page](https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix/releases).
2. In the **Magisk app → Modules → Install from storage**, select that zip.
3. **Reboot** when it finishes.

On the first boot after flashing, the module automatically:

1. **Applies the camera unlock.** This is a temporary patch to the running
   `cameraserver` process (it lives in RAM, so the module re-applies it on every
   boot — nothing on your system partition is modified).
2. **Installs the TeleZoom app.** A small helper app that powers the in-camera
   TELE button. It has no launcher icon; you never open it directly.
3. **Installs the patched Google Camera.** The bundled GCam build with the
   telephoto hooks baked in.

> **This replaces Google Camera.** The module installs its patched GCam under the
> port's package name, so if you already have that exact GCam installed, it is
> replaced and its in-app settings are reset. This is expected. Your photos in
> `DCIM` are untouched.

That is the whole install. You do **not** need LSPosed, Xposed, Termux, or any
manual command for normal use.

After rebooting, open Google Camera and try the telephoto (see below).

---

## Using it

**Telephoto video.** Open GCam, switch to video, and zoom in past roughly 2×. The
hardware switches to the 6.8 mm telephoto lens. To confirm it is the real optical
lens and not a digital crop, cover each rear lens with a fingertip while zoomed
in — covering the telephoto blacks out the preview.

**Telephoto photo.** On GCam's main screen there is now a round **TELE** button
on the right edge. Tap it: the camera reopens already framed through the
telephoto. Take the shot and confirm it; the photo is saved to
`DCIM/Camera` as `TELE_<timestamp>.jpg`. The camera stays in telephoto mode so
you can take several in a row; press back or the ✕ to leave.

To check the unlock is active at any time:

```sh
sh /data/adb/modules/titan2_tele_unlock/unlock-cameraserver.sh status
```

All four patch sites should report `patched`.

> **Note on GCam's main Photo mode.** The regular Photo shutter still uses the
> wide lens even when zoomed. This is a genuine limitation of this GCam port, not
> a bug in the install — its high-quality photo pipeline requires a RAW image
> stream that the telephoto sensor cannot produce. The TELE button exists
> precisely to route around this using a different, RAW-free capture path. The
> full reasoning is in [the investigation below](#phase-7--the-app-layer-solution-telezoom--teleshot).

---

## Troubleshooting

**The telephoto doesn't switch.** Check the unlock with the `status` command
above. If sites show `orig/other`, the RAM patch didn't apply — reboot, or apply
it manually:

```sh
sh /data/adb/modules/titan2_tele_unlock/unlock-cameraserver.sh apply
```

**Google Camera shows a black preview / crashes on open.** Almost always a
signature or font-initialization issue in a self-built patch; the bundled release
build already handles it. If you built your own, see
[Building it yourself](#building-it-yourself).

**The flash-time message says the BuildID is not `6410613c`.** Your firmware
differs from what the offsets target. The unlock will likely fail; see
[Re-deriving offsets after a firmware update](#re-deriving-offsets-after-a-firmware-update).

**Check what the module did on boot:**

```sh
su -c "logcat -d" | grep titan2-telephoto
```

You should see lines for the unlock, the app install, and the GCam install.

---

## Background: what this fixes

The Titan 2 Elite has four camera sensors. The firmware exposes only two of them
to apps and flags the other two — including the telephoto — as `SYSTEM_CAMERA`,
an Android designation that hides a camera from ordinary apps unless they hold a
special signature-level permission. Google Camera, like any normal app, cannot
open it, so out of the box there is no way to use the tele lens in GCam.

This project removes that restriction and then teaches GCam to actually drive the
tele. The result is a Google Camera that can shoot telephoto stills and video on
hardware the manufacturer left dormant.

The [Install](#install) section above is all you need to use it. The rest of this
document explains how the lock works and how each layer was defeated — a complete
account, written for someone starting from zero.

---

## How it works, in depth (the investigation)

This section is the complete technical story of the project — every phase, in the
order it happened, including the approaches that failed. It is written for a
reader starting from zero: terms are explained as they appear, and the dead ends
are kept because they are what revealed the real limits of the hardware.

Throughout: Unihertz Titan 2 Elite, MediaTek Dimensity 7300, Android 16, rooted
with Magisk, unlocked bootloader. GCam port `IlluminatiEliteGCam_v1.4_Titan2Elite.apk`
(Google Camera 8.4.300, package `com.google.android.GoogleCameraEngR18F1`, original
signing certificate `9e1954c7`).

### Phase 0 — the goal and the shape of the problem

Android's camera service enumerates every physical sensor. On this device
(`dumpsys media.camera`) there are four:

| ID | Focal length | Level | RAW | Flags | Role |
|----|--------------|-------|-----|-------|------|
| 0 | 5.59 mm | LEVEL_3 | yes | — | main, 50 MP |
| 1 | 2.31 mm | LEVEL_3 | yes | — | front, 32 MP |
| **2** | **6.80 mm** | FULL | **no** | `SYSTEM_CAMERA` | **telephoto, 8 MP** ← the goal |
| 3 | 5.59 mm | LEVEL_3 | yes | `SYSTEM_CAMERA`, `LOGICAL_MULTI_CAMERA[0 2]` | logical fusion of main + tele |

Two concepts do most of the work below:

- **`SYSTEM_CAMERA`** is Android's "hidden camera" flag. Since Android 11 the
  framework hides any camera carrying it from apps that lack the special
  `signature|privileged` `SYSTEM_CAMERA` permission — a permission only the
  vendor's platform-signed stock camera holds. A third-party app that calls
  `getCameraIdList()` therefore sees only cameras 0 and 1.
- **Camera 3 is a *logical multi-camera*.** In Android a logical camera is a
  virtual device sitting in front of several physical sensors (here the main and
  the tele) that can switch between them. On this phone, the logic that decides
  *which* physical lens is active lives inside camera 3. This becomes the key to
  reaching the telephoto later.

The problem splits into two independent obstacles, discovered in sequence:
**access** (cameras 2 and 3 are hidden) and, once access is solved, **stills**
(the telephoto has no RAW mode, which GCam's photo pipeline turns out to require).

### Phase 1 — the permission route (tried, partially works, abandoned)

The obvious first idea is to simply give GCam the permission. Every variation
failed, and each failure narrowed down where the real gate lives:

- **`pm grant … SYSTEM_CAMERA`** — refused. It is not a runtime permission, so it
  cannot be granted this way.
- **Privileged install with an allowlist** — patch GCam's manifest to declare
  `SYSTEM_CAMERA` and install it as a privileged system app (this is what the
  now-superseded `axml_add_perm.py`, `axml_verify.py`, `gcam-titan2-build.sh`, and
  `patch-any-apk.sh` do). Afterward `dumpsys package` reports the app as
  `PRIVILEGED` with the permission `granted=true` — **and the camera service still
  refuses.** Confirmed with two independent privileged apps (the GCam port and
  Open Camera); both still enumerated only cameras 0 and 1.
- **Re-signing the APK** to match the stock camera's signature — a trap. GCam runs
  its own Google-certificate self-check and a changed signature makes it fail with
  a black preview (see Phase 6).

The reframing lesson: the native check is satisfied by the platform **signature**,
not by the privileged flag, and re-signing to fake the signature breaks the app.
The manifest tooling is kept in `tools/legacy/` as reusable, but the permission
route does not open the gate on this device.

### Phase 2 — reading the enforcement down to the metal

To find *why* a granted permission isn't enough, the firmware was decompiled. The
enforcement chain, from app down to the secure world, turned out to be:

1. **AOSP `SYSTEM_CAMERA` permission check** — gated on the platform signature.
2. **Unihertz-modified `cameraserver`.** The string
   `Rejecting access to system only camera %s without extra agui permissions`
   exists in exactly one binary, `/system/bin/cameraserver`. Unihertz extended
   AOSP's camera server to additionally consult a vendor daemon and reject unknown
   callers.
3. **`IAgoldDaemon`** — a vendor service whose camera-package check is answered via
   `checkTeeKey` / `checkGoogleKey`, i.e. from behind the **TEE** (the phone's
   secure enclave). The stock camera is registered as the allowed client by
   `/system_ext/framework/agui-services.jar`.
4. **MediaTek HAL** — builds and flags the logical camera but does not itself
   enforce the package gate.

Dead ends ruled out here, with evidence: Qualcomm-style aux-unlock properties
(`vendor.camera.aux.packagelist` — nothing in this MediaTek HAL reads them), a
`/vendor` config overlay (the directory doesn't exist), patching the vendor daemon
on disk (`/vendor` is dm-verity protected and the real decision is behind the TEE
anyway), and session-ID reuse (the check is per-call, keyed on the caller's
kernel-attached UID). A stock AOSP GSI would sidestep the whole vendor chain but
wipes user data and risks breaking Unihertz-specific hardware, so it was left
untried.

### Phase 3 — the breakthrough: patch `cameraserver` in RAM

Every system-camera check ultimately runs inside `/system/bin/cameraserver`.
Neutralize the functions that enforce the hiding and the cameras become visible
and openable to any app. Two obstacles stood in the way, and both were solved:

1. **SELinux.** `cameraserver` runs in the domain `u:r:cameraserver:s0`, which
   forbids even root from attaching to it (`ptrace`). A live Magisk policy rule
   lifts exactly that: `magiskpolicy --live "allow su cameraserver process ptrace"`.
   That rule is added only for the moment the patch is written and then **removed
   again immediately** with a matching `deny`. Leaving it as a *standing* rule
   would loosen system SELinux policy and make Google Play Protect flag the device
   as modified; adding it transiently avoids that, and on setups where root can
   already ptrace across domains it is never added at all.
2. **dm-verity.** The binary lives on the verity-protected `/system` partition, so
   it cannot be edited on disk. Instead it is patched **in the running process's
   memory** (`/proc/<pid>/mem`) — verity never sees a change, and a reboot fully
   restores the original bytes. This is why the boot module re-applies the patch
   every boot.

The functions were located by decompiling `cameraserver` with **r2ghidra
on-device**, anchoring on the *unique* string `without extra agui permissions` and
following the call graph. A naive approach fails badly here: the generic log
string `system only device` appears roughly 1500 times, and matching on it
produced 1203 false-positive "sites". The lesson — anchor on a string unique to
the decision, then follow cross-references, rather than pattern-matching a common
string.

**The four patch sites** (all applied by `reject-bypass.sh` and by the boot
module; all RAM-only):

| Address | Function | Change | Why |
|---------|----------|--------|-----|
| `0xf3158` | `getSystemCameraKind` | `ldr w8,[x23,0xc8]` (`b940cae8`) → `mov w8,#0` (`52800008`) | **The root cause.** This classifier decides whether each camera is public or system-only, and every other filter calls it. Forcing it to always answer "public" opens both enumeration and access in one edit. It is a single-instruction change that leaves the function's mutex-unlock and refcount cleanup intact — do **not** entry-override this one, it holds a lock. |
| `0x11ec70` | `filterAPI1SystemCameraLocked` | `b.eq` (`54000520`) → `nop` (`d503201f`) | stops the legacy-API enumeration loop from skipping system cameras |
| `0x2bd240` | `hasPermissionsForSystemCamera` | entry → `mov w0,#1; ret` (`52800020 d65f03c0`) | always report the system-camera permission as held |
| `0x102b00` | `shouldRejectSystemCameraConnection` | entry → `mov w0,#0; ret` (`52800000 d65f03c0`) | never reject a system-camera connection |

Offsets are specific to cameraserver BuildID `6410613c`; a firmware update moves
them (see [Re-deriving offsets](#re-deriving-offsets-after-a-firmware-update)).

**Result — access is solved.** After the patch, a normal app's log shows
`CameraManager2: GotArray:0 1 2 3` (previously `0 1`), the telephoto opens in
third-party apps, and the **finger test** (cover the 6.8 mm lens at high zoom and
the preview darkens) confirms it is the real optical sensor, not a digital crop.
`reject-bypass.sh` resolves each file offset to its live address via the binary's
ELF sections and `/proc/<pid>/maps`, backs up the original bytes, writes and
read-back-verifies each word, and rolls the whole batch back on any mismatch.

### Phase 4 — GCam video works, photo crashes

Telephoto **video** records and saves in GCam immediately (finger-test confirmed).
Access is genuinely, fully solved.

Photo mode, however, black-screens on the tele. Logcat showed a
`NullPointerException` in GCam's `OneCamera` path — a `getClass()` call on a null
value at `gyc.get` — logged as *"OneCamera failed to open."* Diffing the camera
characteristics of camera 0 against camera 2 found the cause: **camera 2 is missing
`android.control.postRawSensitivityBoostRange`** (tag `0x0003001B`), a property it
has no reason to expose because it has no RAW mode. GCam reads that property
unconditionally, gets null, and crashes. Configuration levers (`raw_key_tele=0`,
disabling HDR+, model swaps, operation-mode changes, ZSL/HDR-region toggles) do
not help — GCam checks the property's *presence*, not any preference.

### Phase 5 — the characteristic-injection "cave" (built, verified, abandoned)

The plan: inject the missing property (`postRawSensitivityBoostRange = [100,100]`,
meaning no boost, which is correct for a no-RAW sensor) into the characteristics
that `cameraserver` returns for camera 2.

Reconnaissance showed the property is **pure HAL passthrough** — searching the
binary for its tag (`/x 1b000300`, in the correct little-endian byte order) found
it nowhere, so there was no existing code emitting it to patch. The solution was a
**hook plus a code cave**, both inside `cameraserver`:

- **Hook:** `DeviceInfo3::getCameraCharacteristics` at `0x145920` is the innermost
  producer that every client funnels through. Its two success paths converge on a
  `mov w0,wzr` at `0x145a94`; that instruction was overwritten with a branch into a
  cave (`b 0x2d7310`).
- **Cave at `0x2d7310`:** the *dead* HIDL stub
  `BnHwCameraService::_hidl_getCameraCharacteristics` (804 bytes). HIDL — an older
  Android interface mechanism — is unregistered on this device (`lshal` shows only
  the newer AIDL services), so the stub is never called and its space is free to
  reuse. The cave checks whether the property already exists (cameras 0/1/3 have
  it, so they are skipped), calls the buffer's own `update()` to add `{100,100}`,
  restores the original instruction, and branches back. 17 instructions.

This was fully assembled, byte-verified, and wired into `reject-bypass.sh`, with
apply-ordering and full rollback simulated against a mock memory image. **It worked
mechanically** — a Camera2 probe confirmed the injected property on camera 2 — **but
it did not help**, because two deeper walls exist below `cameraserver`, in the
vendor HAL:

- **Camera 2 direct stills:** the vendor HAL refuses tuning entirely —
  *"Tuning … only available for primary sensor"* — so `OneCamera` fails to open.
  This is at the HAL/TEE boundary, unreachable from `cameraserver`.
- **Camera 3 (logical) direct stills:** the HAL refuses the RAW16 image stream that
  GCam configures — *"createConfiguredSurface: No supported stream configurations
  with format 0x20"*. These are around ten genuine capability checks backed by
  actual hardware limits, not a software allowlist, so forcing them only moves the
  crash downstream.

The cave was therefore unnecessary and was crash-looping `cameraserver`, so it was
fully reverted; only the clean four-site unlock remains. Three tooling bugs from
this phase are worth recording:

- On this build, the assemblers (`rasm2` and radare2's `wa`) resolve branch targets
  relative to the *current cursor position*, not the address being patched, so
  `bl`/`b`/`tbnz` instructions assembled silently wrong. Branch encodings were
  computed by hand instead (`BL = 0x94000000 | (((tgt − pc) >> 2) & 0x3ffffff)`,
  little-endian) and written directly.
- A single dropped `add sp, sp, 0x10` left the stack 16 bytes low on the injection
  path, tripping the stack-canary check and aborting `cameraserver`. A partially
  applied binary patch is worse than none — the tooling now treats every batch as
  all-or-nothing.
- An earlier writable radare2 session had modified the on-disk copy of the binary,
  so callee addresses derived from it were wrong. Always derive addresses from a
  pristine copy (compare hashes).

The phase ended with the insight that redirected everything: the stock camera
never opens camera 2 directly. It **zooms** the logical device past the optical
crossover (~2× in practice), and MediaTek's seamless-zoom logic
(`MtkCam/ZoomRatioConverter`, `multiCamZoomOverrideMode`) switches to the 6.8 mm
lens. GCam caps its own zoom and never crosses that point. The fight moved from
`cameraserver` to the app layer.

### Phase 6 — the re-sign trap

Worth stating on its own because it cost real time: at one point a **re-signed**
GCam APK was installed and black-screened. The cause had nothing to do with the
camera — GCam failed its own `GoogleCertificatesRslt` integrity check because the
signature had changed. **Always use the original, unmodified APK.** This is the
reason the project hooks GCam at runtime rather than decompiling and recompiling
it: recompiling forces a re-sign, which breaks the app.

### Phase 7 — the app-layer solution (TeleZoom / TeleShot)

Because in-process hooks cannot crash `cameraserver`, the work moved to an
**LSPosed module, "TeleZoom"** (`com.fluxsniffer.telezoom`), that hooks GCam
directly. (LSPosed is a framework for running "Xposed" hooks — code injected into
another app to change its behavior. The device stack was ReZygisk +
zygisk_lsposed.) Each build corrected an assumption from live logs:

- **The zoom mechanism.** The first hook tried to raise `CONTROL_ZOOM_RATIO`, but
  it never fired — GCam drives zoom with a **crop rectangle**
  (`SCALER_CROP_REGION`), not a zoom ratio. GCam sends the full sensor array at 1×
  and shrinks the crop as you zoom in.
- **v1 (crop-snap).** Snap the crop to the telephoto framing. It fired, but the
  finger test failed — a crop alone does not switch the lens.
- **The device insight.** `dumpsys` showed GCam only ever opens physical camera 0,
  while the stock camera opens logical camera 3 when the tele is active. The lens
  switch lives on the logical camera, so a crop on camera 0 can never reach it.
- **v2 (redirect).** Rewrite GCam's `openCamera("0")` to `"3"` so it opens the
  logical camera. Video preview worked on camera 3 — but the crop *still* didn't
  switch the lens.
- **v3 (zoom-ratio translation).** On camera 3, translate GCam's crop zoom into a
  real `CONTROL_ZOOM_RATIO` (plus a full-field crop of the same shape). **This made
  telephoto video work** — the ratio reaches the HAL and it switches lenses. Photo
  mode still didn't switch: its stream set included a full-size RAW16 stream, and
  any RAW stream pins the session to the main sensor.
- **v4–v6 (hide RAW).** Hide the RAW capability so GCam's photo mode wouldn't
  request a RAW stream. Result: photo mode failed to open with a null-pointer crash
  after querying RAW10 sizes. For comparison, the *stock* camera runs the tele with
  only non-RAW streams (`1200×1080`, `3680×3312 YUV`, `3264×2448`, `192×144`).

This closed the question of GCam's main Photo mode. Decompiling GCam with **jadx**
confirmed why: the photo capture graph is selected by GCam's **Dagger dependency
wiring per mode**, fixed at compile time, and every photo variant is built around a
RAW stream (the plumbing classes `hdb`/`OneCamera` and `gmy` carry no mode logic to
hook). A diagnostic build traced the exact null to `gyc.get` — the same site as the
original camera-2 failure — through
`fvq.n ← hdn.get ← gwh.get ← hcv.get ← gqr.get ← hdj.a ← evt.a ← ghn.a`. **GCam's
main Photo mode cannot use the telephoto on this port.**

### Phase 8 — the working stills route: TeleShot

Since the main Photo mode is a dead end, the working route sidesteps it by using
the one GCam mode that configures **no RAW stream**: its image-capture *intent*
mode — the path GCam runs when another app asks it for a single picture (`hdn`
case 7, which sets up only a viewfinder and a non-RAW stream the telephoto can
serve).

**TeleShot** (built into the TeleZoom app) drives this:

- It launches GCam's `IMAGE_CAPTURE` intent with TeleZoom's own content provider
  (`com.fluxsniffer.telezoom.shot`) as the output destination. (GCam refuses plain
  `file://` paths and refuses pending-MediaStore items here, so a content provider
  is required.) TeleZoom holds the zoom on the telephoto for the session, GCam
  captures and processes the shot on the 6.8 mm lens, and TeleShot copies the
  finished JPEG into `DCIM/Camera` and stamps its EXIF timestamp.
- Verified output: `TELE_*.jpg` at 3504×2628, EXIF focal length 6.8 mm — genuine
  telephoto stills.

A floating **TELE button** is injected into GCam's main screen to launch this in
one tap; in that mode the zoom is scaled so GCam's "1×" is the telephoto framing,
and the flow loops so you can take several shots in a row.

### Phase 9 — shipping without Xposed (LSPatch), and a font bug

TeleZoom can run as a normal LSPosed module, but that requires the user to install
LSPosed. To remove that dependency, the release instead **bakes TeleZoom into the
GCam APK** with **LSPatch**, a tool that embeds Xposed-style hooks directly into an
app (using a signature-bypass mode so GCam's own certificate check still passes).

One subtle bug surfaced: LSPatch loads embedded hooks slightly later in startup
than a normal Xposed environment, which left Android's downloadable-fonts component
without the app context it expects. GCam's font initialization then crashed with a
null-context error, appearing as a **black photo preview**. TeleZoom fixes it by
supplying that context itself; the fix is a no-op under normal LSPosed and only
matters in the baked build. With that in place, the patched GCam runs cleanly with
no LSPosed installed — which is exactly what the release module ships.

### Re-deriving offsets after a firmware update

The four `cameraserver` patch addresses are specific to build `6410613c`. If an
update changes the binary, the offsets move and the unlock fails.
`tools/cameraserver-recon.sh` re-locates the functions by their string anchors
(which survive updates even when addresses change) so new offsets can be derived.
This is an advanced step and requires radare2 with the r2ghidra plugin.

### What is proven, and what is closed

| Capability | Status | How |
|-----------|--------|-----|
| Enumerate/open cameras 2 & 3 from third-party apps | **Solved** | four-site `cameraserver` RAM patch |
| Telephoto **video** in GCam | **Working** | logical-camera redirect + zoom-ratio translation |
| Telephoto **stills** | **Working** | TeleShot intent-capture route (non-RAW graph) |
| GCam's **main Photo shutter** on the tele | **Closed** | the port's photo pipeline is compile-time wired to require RAW, which pins the main sensor |
| Camera 2 direct stills | **Closed** | vendor HAL: "tuning only for primary sensor" |
| Camera 3 direct RAW stills | **Closed** | HAL rejects the RAW16 stream configuration |

The through-line: every wall past the access unlock lives in the vendor HAL or the
TEE, not in anything a RAM patch or an app hook can reach. This phone is designed
so that telephoto imaging goes through the seamless-zoom mechanism on the logical
camera using a non-RAW pipeline — which is exactly what the working solutions do,
and exactly what GCam's RAW-bound photo mode cannot.

### Reusable lessons

1. **Anchor decompilation on a unique string, then follow the call graph.** A
   common log string gives a thousand false positives; a unique one plus its
   cross-references gives the exact function.
2. **Patch the classifier, not every consumer.** One edit to
   `getSystemCameraKind` beat chasing four downstream filters.
3. **You can RAM-patch a verity-protected binary on a rooted device:**
   `magiskpolicy --live` lifts the ptrace block, `/proc/<pid>/mem` becomes
   writable, and a reboot cleanly restores everything. Add such a policy rule only
   transiently (remove it right after) — a standing rule trips Play Protect.
4. **A partial binary patch is worse than none** (the dropped stack adjustment).
5. **Assemblers may resolve branches against the wrong base** — verify by
   disassembling the bytes you actually wrote, or encode branches by hand.
6. **Re-signing an app can break its own integrity checks** — prefer runtime hooks
   over recompilation when the app self-verifies.
7. **Know where the real wall is.** The access gate was in software and fell; the
   photo wall is a hardware-capability gate in the HAL/TEE and did not move for any
   amount of framework or app patching.
8. **When an app's pipeline is dependency-wired per mode**, a runtime hook can't
   re-pick the graph — find a different *entry mode* (here, the image-capture
   intent) that already wires the graph you need.
9. **Termux-in-chroot environment traps:** stage files through `/data/local/tmp`
   (visible in both mount namespaces); never `su -c "bash …"` (root's shell has no
   `bash`), self-elevate per command instead; `/sdcard` is FUSE and `pm install` is
   denied there, so stage APKs to `/data/local/tmp`; reload an LSPosed hook with a
   true cold start (force-stop + `killall`), not a warm `am start`.

## Building it yourself

The release is prebuilt and needs nothing but Magisk. Build your own only to
modify the project or to target a different GCam port. Compilation needs Termux
tools that a Magisk module cannot run, so the flow is: **build once in Termux →
package the module → flash it.**

```sh
# In Termux on the rooted device, with a CLEAN (unpatched) GCam port APK on hand:
pkg install -y openjdk-17 aapt d8 apksigner zip unzip curl python git
git clone https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix
cd Titan-2-Elite-Telephoto-Fix

bash tools/cache-android-jar.sh                 # reuse an android.jar already on device
bash make-full-module.sh /path/to/clean-gcam.apk    # builds + patches + packages
# result: titan2-telephoto-FULL.zip  (flash it, or attach it to a Release)
```

`make-full-module.sh` builds the TeleZoom app, uses LSPatch to bake it into your
clean GCam, and bundles both into the full module. It fetches `android.jar` and
LSPatch automatically if they aren't already cached; override with `ANDROID_JAR=`
and `LSPATCH_JAR=`.

To run TeleZoom as a plain **LSPosed** module instead of baking it in: build the
app with `TeleZoom/build-on-device.sh`, install it, enable it in LSPosed with GCam
in scope, and apply the unlock with `reject-bypass.sh --apply` (or install the
Magisk module for the boot-time unlock). See `TeleZoom/README.md`.

---

## Repository layout

```
make-full-module.sh          Build the full module from source: builds TeleZoom, LSPatches your
                             clean GCam, and packages the flashable module (the main build entry point).
reject-bypass.sh         Apply/revert the cameraserver unlock by hand (RAM patch).
quickstart.sh            Prints the short install summary.
install.sh               Termux end-to-end build+install (for the LSPosed route).

magisk-module/           Source of the boot module:
  service.sh               first-boot: unlock + install app + install patched GCam
  unlock-cameraserver.sh   the four-site RAM patch, self-contained
  customize.sh             flash-time checks (arch, firmware BuildID)
  module.prop, uninstall.sh, META-INF/  Magisk boilerplate

TeleZoom/                Source of the in-GCam code and the helper app:
  app/src/main/java/com/fluxsniffer/telezoom/
    ZoomHook.java            the hooks (redirect, zoom-ratio, TELE button, font fix)
    TeleShot.java            the telephoto-stills flow
    ShotProvider.java        the private destination GCam writes photos to
  build-on-device.sh       builds the app in Termux (no Android Studio needed)

tools/
  cache-android-jar.sh     find and cache an android.jar from the device
  cameraserver-recon.sh    re-derive patch offsets after a firmware update
  camera-array.sh, collect-diag.sh   diagnostics
  legacy/                  superseded approaches (permission route, lens-config,
                           photo-cave), kept for reference — see tools/legacy/README.md

CHANGELOG.md              Version history.
LICENSE                   MIT
```

The prebuilt module (which bundles the third-party GCam port) is distributed as a
**GitHub Release asset**, not committed to the source tree — so the repository
stays source-only and links the port rather than redistributing it in-tree.

---

## Reverting / uninstalling

- **Remove the module** in the Magisk app. A reboot also clears the RAM-based
  unlock on its own.
- **Restore stock Google Camera** by reinstalling your own GCam build if you want
  the unpatched one back.
- **Remove the helper app:** `pm uninstall com.fluxsniffer.telezoom`.

---

## Credits and license

Created by **Flux-Sniffer-Mods**. Released under the **MIT License** (see `LICENSE`).

The Google Camera port is third-party work by its original authors and is **not**
redistributed in this source repository. The release module bundles a patched
build purely for convenience on your own device; the repository itself links to,
rather than vendors, the port.
