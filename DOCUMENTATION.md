# 📚 ColorOS Port Repository Overview

This repository contains a set of scripts and associated resources for porting and repacking ColorOS/OxygenOS/realme UI OTA/fastboot packages onto OnePlus/Oppo devices. The following is a comprehensive breakdown of the role and interactions of each file and folder.

---

## 🚀 Entry Points

### `setup.sh` ⚙️
A setup script that installs dependencies via `apt` (Linux) or `brew` (macOS). 

**Installs:**
- `aria2` — Fast parallel downloader
- `python3` — sdat2img, patching scripts
- `busybox`, `zip`, `unzip`, `p7zip` — Archive tools
- `openjdk` — APKTool runtime
- `zstd` — Zstandard compression
- `xmlstarlet` — XML processing
- And all other tools that `port.sh` requires

### `port.sh` 🔄
The main porting script. 

**Arguments:** `<baserom> <portrom> [portrom2] [portparts]`
- Supports URLs (will be downloaded with `aria2c`)
- Supports mixed porting from multiple source ROMs

**Simplified processing flow:**

1. **📥 ROM Download & Extraction**
   - Reads `bin/port_config` to determine target partitions
   - Extracts BASEROM/PORTROM from `payload.bin` / `*.img` (using `payload-dumper`, `brotli+sdat2img`, or `unzip`)
   - Supports mixed porting if a second source ROM is specified

2. **🗂️ Partition Extraction**
   - Extracts partitions under `build/baserom` / `build/portrom`
   - ext4 → `bin/imgextractor`; EROFS → `extract.erofs`
   - Some partitions like vendor/odm are taken from the base ROM

3. **🏷️ System Property Import**
   - Reads Android/SDK/device code/region info from `my_manifest` / `build.prop`
   - Overwrites with base device values
   - Handles 32-bit zygote → 64-bit-only conversion
   - Brand detection (ColorOS / OxygenOS / realme UI) as needed

4. **🔨 Patch Application** (80+ individual fixes)
   - Face unlock, AI Call, OTA dm-verity bypass
   - Gallery AI Editor, battery SOH, game volume
   - Dolby, AOD, SystemUI smali rewrites
   - Feature flag XML add/remove, build property adjustments
   - ZIPs and overlays from `devices/common` and `devices/<device>`
   - **✨ NEW:** Google Apps auto-detection & installation (GApps — ColorOS CN only)
   - **✨ NEW:** 3D Wallpaper integration (ColorOS CN)

5. **🔓 Security & Encryption**
   - Optionally removes the data encryption flag (`remove_data_encryption=true`)
   - Runs `disable_avb_verify` to strip AVB verification from fstab

6. **📦 Partition Repacking**
   - Regenerates `fs_config` / `file_contexts` with `bin/fspatch.py` / `bin/contextpatch.py`
   - Repacks each partition with `mkfs.erofs` (or `make_ext4fs`)
   - Gets device-specific super size with `bin/getSuperSize.sh`
   - Builds `super.img` with `lpmake`

7. **✒️ Final Signature & Packaging**
   - Disables vbmeta verification with `bin/patch-vbmeta.py`
   - Places fastboot scripts (Windows/Mac/Linux)
   - Generates `META-INF/updater` and final ZIP in `out/<OS>_<version>/`

### `functions.sh` 📚
Utility library sourced by `port.sh`. Provides:

**Logging & Checks:**
- 🎨 Colored logging (`blue`, `yellow`, `green`, `error`)
- ✅ Dependency command existence checks

**APK/JAR Editing:**
- `patch_smali` / `baksmali_wrapper` / `smali_wrapper` — Decompile, modify, repack + sign

**Image & Filesystem:**
- `extract_partition` — Detects ext4/EROFS and extracts
- `disable_avb_verify` — Removes AVB options from fstab

**Boot Image:**
- `patch_kernel` / `patch_kernel_to_bootimg` / `spoof_bootimg` — Kernel patching with magiskboot

**Feature & Properties:**
- `add_feature_v2` / `remove_feature` — Feature flag XML management
- `add_prop_v2` / `remove_prop_v2` / `prepare_base_prop` — Build.prop editing

**Google Apps:** ✨ NEW & AUTOMATIC
- `is_coloros_cn` — Auto-detect if port ROM is ColorOS CN
- `auto_download_gapps_for_coscn` — Auto-detect & download/install GApps (all-in-one) 🚀
- `validate_gapps_package` — Validate GApps ZIP structure before integration
- `install_google_apps` — Install external GApps package into ROM
- `download_mindthegapps` — Auto-download MindTheGapps (recommended for CN)
- `download_opengapps` — Auto-download OpenGApps with variant selection
- `setup_gapps_for_cos_cn` — Complete GApps setup wizard with usage guide
- `configure_google_play_services` — Configure GMS properties for Play Services

ℹ️ **Automatic GApps Installation for ColorOS CN**
   - 🤖 Automatically detected & downloaded during port.sh
   - 📱 GApps appear pre-installed on first boot (like global ROMs)
   - ⏭️ No manual download/installation needed
   - ⚡ Uses latest MindTheGapps from GitHub releases
   - ✅ Skips installation if ROM already has GApps

**3D Wallpaper:** ✨ NEW
- `extract_3d_wallpapers` — Extract wallpaper packages from port ROM
- `install_3d_wallpaper_apks` — Install wallpaper APKs with dependencies
- `integrate_3d_wallpaper_configs` — Configure wallpaper system properties
- `add_wallpaper_features` — Add wallpaper feature flags
- `port_3d_wallpapers_full` — Complete wallpaper integration (all-in-one)

---

## ⚙️ Configuration Files

### `bin/port_config` 🔧
Configuration parameters for ROM porting:

- `partition_to_port` — List of logical partitions to extract from PORTROM and repack
- `possible_super_list` — Candidate partitions to include in `super.img`
- `repack_with_ext4` / `remove_data_encryption` — Packing format & encryption behavior
- `super_extended` / `pack_method` — Advanced packing options

### `bin/getSuperSize.sh` 📏
Returns the super partition byte size for a given device code. Used by `port.sh` during packaging.

---

## 🛠️ Tools (`bin/`)

### 🖥️ OS/Architecture Binaries
Located under `bin/Linux/{x86_64,aarch64}` and `bin/Darwin/{X86_64,aarch64}`:

**Key tools:**
- `payload-dumper(-go)` — Extract OTA payload.bin
- `lpunpack` / `lpmake` — Super partition manipulation
- `mkfs.erofs` — EROFS filesystem creation
- `img2simg` / `simg2img` — Sparse image conversion
- `magiskboot` — Boot image patching
- `vbmeta-disable-verification` — AVB bypassing
- `zstd` — Compression
- `gettype` — Filesystem type detection

### 📱 APK/JAR Editing
**Location:** `bin/apktool/`
- `apktool.jar` — APK decompiling/rebuilding
- `smali` / `baksmali` (standard + 3.0.5 variants) — Smali assembly/disassembly
- `APKEditor.jar` — Resource editing

### 🖼️ Image Extraction
**Location:** `bin/imgextractor/`
- `imgextractor.py` + `ext4.py` — Python implementation for Android sparse/ext4 images
- Works on Windows without requiring external binaries

### 🔨 Smali Auto-Patching
- `bin/patchmethod.py` — Replace method with stub
- `bin/patchmethod_v2.py` — Enhanced: cross-dir detection, hook insertion

### 🔐 SELinux / Permissions
- `bin/contextpatch.py` — Infer SELinux contexts for missing paths
- `bin/fspatch.py` — Fill missing UID/GID/permissions/symlinks in `fs_config`

### ✒️ AVB & Utilities
- `bin/patch-vbmeta.py` — Rewrite vbmeta flags to disable verity
- `bin/lpunpack.py` — Parse super metadata, extract partitions
- `bin/flash/` directory — Flashboot templates & updater binary

---

## 📁 Device Resources (`devices/`)

For detailed origin & justification of each device ZIP: see [DEVICES_ZIPS_ORIGIN.md](DEVICES_ZIPS_ORIGIN.md)

### 📦 Common ZIPs – Feature Fixes (`devices/common/`)

| ZIP File | Purpose | Content |
|----------|---------|---------|
| `a13_base_fix.zip` 🔧 | ODM/HAL bridging for A13→A14 | Init scripts, SELinux, VINTF |
| `aod_fix_sm8350.zip` 📲 | Always-On Display fix | Display composer binary |
| `charger-v6-update.zip` 🔋 | Charger HAL V3→V6 upgrade | Init, VINTF, NDK .so files |
| `cryptoeng_fix_a13.zip` 🔐 | Privacy/App Lock HAL | URCC NDK .so files |
| `dolby_fix.zip` 🎵 | Dolby audio restoration | AudioEffectCenter APK + config |
| `face_unlock_fix_common.zip` 👤 | Face Unlock dependencies | TrustZone APK, EVA models, overlays |
| `hdr_fix.zip` 🌈 | HDR display configuration | Display config XML |
| `nfc_fix_a16_v2.zip` 📡 | NFC for Android 16 | NfcNci APK + libnfc-nci.conf |
| `ril_fix_a13_to_a15.zip` 📞 | RIL/modem communication | commcenterd, radio libs, firmware |
| `voice_trigger_fix.zip` 🎤 | Voice assistant models | OVoiceManagerService APK + models |
| `wifi_fix_a16.zip` 📡 | WiFi for Android 16 | com.android.wifi.apex |
| `wallpaper_3d_fix.zip` 🎨 | 3D Wallpaper for CN ROMs | Wallpaper APKs, 3D models, assets |

---

### 🎨 3D Wallpaper Assets Support

**ColorOS CN 3D Wallpaper Files:**
- Automatically extracted from port ROM
- Includes: `com.oplus.theme.wallpaper3d`, `com.coloros.wallpaper`
- Live wallpaper APKs with full animation support
- 3D model assets & textures
- Parallax scrolling configuration
- Dark mode wallpaper adaptation

### 👤 OnePlus/OPPO Device Resources (`devices/<device>/`)

- **OnePlus 8 / 8 Pro:** `keymaster.img`, `tz.img`, vendor `build.prop` overlays
- **OnePlus 8T:** Display overlay, refresh rate fix script
- **OnePlus 9 / 9 Pro:** Face Unlock HAL + Camera 5.0 fixes
- **OnePlus 9R / OP4E5D:** Recovery fstab, releasetools.py, OTA updater

### 🎨 Feature Templates (`devices/common/*.xml`)
Pre-built feature flag templates populated by `add_feature_v2` calls:
- `oplus.feature.android-ext-bruce.xml`
- `com.oplus.app-features-ext-bruce.xml`
- `com.oplus.oplus-features-ext-bruce.xml`
- And others

---

## 🔧 OTA / Build Tools (`otatools/`)

### 📋 Host Tools (`otatools/bin/`)
Android host build tools:
- `apksigner`, `signapk`, `boot_signer` — APK/boot signing
- `ota_from_target_files`, `merge_target_files` — OTA generation
- `mkbootimg`, `img_from_target_files` — Boot/image tools
- `lpmake`, `lpunpack` — Super partition tools

### 📚 Framework (`otatools/framework/`)
JAR files for signing and OTA generation

### 🔑 Test Keys (`otatools/key/`)
Signing keys:
- `testkey.pk8` / `x509.pem` — RSA private key & certificate
- Used to sign APKs and verify modifications

### 📦 Libraries (`otatools/lib64/`)
Shared libraries linked by host tools

---

## 💾 Flash Scripts & Output

### 🔌 Fastboot Flash Templates
- `bin/flash/windows_flash_script.bat` — Windows fastboot script template
- `bin/flash/mac_linux_flash_script.sh` — macOS/Linux fastboot script template

**Dynamically substituted with:**
- Device info, region, boot image names
- Used to flash `super.zst` and firmware images

### 📦 Flash Updater
- `bin/flash/update-binary` — Executed from META-INF during sideloading
- Device-specific variant can override: `devices/<device>/update-binary`

### 📤 Final Output (`out/<OS>_<rom_version>*.zip`)
The final ROM package contains:
- `super.zst` — Super partition (compressed)
- `firmware-update/` — Individual .img files
- Flash scripts (Windows/Mac/Linux)
- `META-INF/` with updater
- `patch-vbmeta.py` — Post-flash AVB disabler

---

## 📖 Documentation Files

### 📄 Main Docs
- [README.md](README.md) 🎀 — Project overview, features, installation
- [DOCUMENTATION.md](DOCUMENTATION.md) 📚 — This file (repository structure)
- [DEVICES_ZIPS_ORIGIN.md](DEVICES_ZIPS_ORIGIN.md) 📦 — Per-ZIP origin & justification
- [FUNCTIONS_SH_DOC.md](FUNCTIONS_SH_DOC.md) 🔧 — Function reference
- [PORT_SH_DOC.md](PORT_SH_DOC.md) 🎯 — port.sh flow & logic

---

## 💡 Development Tips

### 📂 Working Directories
- `build/` — Extracted partitions (`build/baserom`, `build/portrom`)
- `tmp/` — Intermediate files (smali, dex, APK temp work)
- `out/` — Final output ROMs

**Reusing builds:** If `build/<version_name>/` exists, extraction is skipped

### ✒️ Signing Process
APKs/JARs modified at smali or resource level are re-signed:
- `zipalign` — 4-byte alignment
- `apksigner` — Sign with `otatools/key/testkey*`

### 🖥️ Filesystem Variants
- **Default:** EROFS (read-only, smaller)
- **Alternative:** Edit `bin/port_config` → `repack_with_ext4=true` for ext4 (R/W)

### 🐧 Custom Kernels
`port.sh` detects and integrates:
- AnyKernel-format ZIPs
- Standalone `boot.img` files
- Generates: `boot_ksu.img`, `boot_noksu.img`, `boot_custom.img`
- Includes in final output

---

## 🎯 ColorOS/OxygenOS Regional Support

### 🌍 Automatic Detection
Script auto-detects variant:
- OnePlus 9 Pro CN (OP4E5D)
- OnePlus 9RT CN (OP4E3F)
- Global variants

### 🔑 CN-Specific Properties Applied
- Aggressive thermal management
- GMS compatibility adjustments
- Regional carrier optimization

For details, see [README.md → ColorOS China Optimization](README.md#-coloros-china-optimization-guide)

---

To understand what gets applied and when, follow the `blue` / `yellow` / `green` colored log output from `port.sh` as a guide through the execution flow.

---

## setup.sh — Detailed Notes
- **Purpose**: Installs all packages required by `port.sh` in one step for Linux/macOS.
- **Behavior**:
  - **Linux x86_64**: Warns and exits if not running as root. Runs `apt update/upgrade`, then installs: `aria2 python3 busybox zip unzip p7zip-full openjdk-21-jre zstd bc android-sdk-libsparse-utils xmlstarlet` (prompts to re-run on failure).
  - **Linux aarch64**: Same but without `aria2`; installs `zipalign` by its package name.
  - **macOS x86_64**: Runs `pip3 install busybox` (typo in original, but busybox-equivalent), then `brew install aria2 openjdk zstd coreutils gdu gnu-sed gnu-getopt grep xmlstarlet`. GNU tools are required on macOS because `functions.sh` references them via aliases.

---

## functions.sh — Detailed Notes

Utility library sourced by `port.sh`. For full details on each function's inputs, outputs, side effects, and tool dependencies, see [FUNCTIONS_SH_DOC.md](FUNCTIONS_SH_DOC.md).

### Logging / Environment
- `error` / `yellow` / `blue` / `green`: Reads `$LANG` to display colored output in Japanese or English (used widely by both `port.sh` and `setup.sh`).
- `exists` / `abort` / `check`: Checks for required commands; if any are missing, tells the user to run `setup.sh` and exits.
- On macOS, aliases `sed` / `tr` / `grep` / `du` / `date` / `stat` / `find` to their GNU versions.

### Image / Partition Handling
- `extract_partition`: Uses `gettype` to detect ext4/erofs; extracts with `bin/imgextractor/imgextractor.py` (ext4) or `extract.erofs` (erofs). Deletes the source `.img` after extraction.
- `disable_avb_verify` (two definitions): Strips `,avb*` and `avb_keys` from fstab files to disable AVB verification. Applied to both portrom and baserom fstab files.
- `spoof_bootimg`: Unpacks `boot.img`, appends `androidboot.vbmeta.device_state=unlocked` to the cmdline, and repacks.
- `patch_kernel_to_bootimg` / `patch_kernel`: Uses `magiskboot` to unpack boot/vendor_boot, apply AVB disabling to the ramdisk, swap in kernel/dtb, and repack. No re-signing required for either A-only or A/B.

### Smali / APK / JAR Editing
- `patch_smali`: Extracts a target APK/JAR to a temp directory, applies `sed` substitution to the target smali (string replace or line-level replace), regenerates the dex, repacks into the ZIP, and re-signs with `zipalign` + `apksigner` (using otatools testkey).
- `baksmali_wrapper` / `smali_wrapper`: Wrappers for extracting dex → smali and reassembling smali → dex → APK. Used by `fix_oldfaceunlock`, `patch_smartsidecar`, etc.
- `patchmethod.py` / `patchmethod_v2.py` (called as scripts): Force a method's return value (true/false/void) or replace the entire method body.

### build.prop and Feature Flag Operations
- `add_feature` / `add_feature_v2`: Appends `<feature>` nodes to `com.oplus.*-features*.xml` etc. (supports existence checks and comment labels).
- `remove_feature`: Keeps the feature if it exists on the base device; only removes it from the port side if the base doesn't have it (force mode available).
- `update_prop_from_base` / `add_prop` / `remove_prop` / `add_prop_v2` / `remove_prop_v2`: Copies/adds/comments-out values in `build.prop` files from base to port. `prepare_base_prop` + `add_prop_from_port` implements a diff-management system where the base's `build.prop` is the foundation and `bruce/build.prop` holds the deltas.

### Notable Individual Patches
- `fix_oldfaceunlock`: Rewrites Settings/SystemUI smali to enable the old Face Unlock implementation and corrects related package names to OnePlus equivalents. Also adjusts MiniCapsule camera position strings.
- `patch_smartsidecar`: Forces the brand detection method in SmartSideBar to always return true.
- Combined with `add_feature` calls, a wide range of adjustments are triggered from `port.sh` itself — AOD, Dolby, AI Call, charging info, game volume, and more.

### Utilities
- `convert_version_to_number` / `get_oplusrom_version`: Numerically extracts the highest version from `ro.build.version.oplusrom.display` and similar props for comparison.
- `trap ... SIGINT`: Prints a warning and exits cleanly on script interruption.

These functions are called in sequence by `port.sh`, supporting the full pipeline: partition extraction → patch application → repack → signing and output generation. Following the `blue` / `yellow` / `green` log messages is the most effective way to trace which functions are called and when.