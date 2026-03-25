# 🔧 functions.sh Reference (Helper Function Documentation)

This document organizes the functions provided by `functions.sh` from the perspective of "what inputs they take, what they modify, and what they depend on", to make it easier to trace the behavior of `port.sh`.

**Related files:**
- 📄 [functions.sh](functions.sh) — the file itself
- 📄 [port.sh](port.sh#L44) — `source functions.sh` (line 44)
- 📄 [PORT_SH_DOC.md](PORT_SH_DOC.md) — full flow documentation for `port.sh`

---

## 🎯 1. Purpose and Prerequisites

`functions.sh` is sourced by `port.sh` and provides the following:

- 🎨 **Colored log output** (`🔵 blue` / 🟡 `yellow` / 🟢 `green` / ❌ `error`)
- ✅ **Dependency command existence checks** (`check` / `exists` / `abort`)
- 🖼️ **Image extraction** (ext4/EROFS) and AVB disabling (`extract_partition` / `disable_avb_verify`)
- 🔨 **APK/JAR smali patching**, repacking, and signing (`patch_smali` / `smali_wrapper` / `baksmali_wrapper`)
- 🥾 **boot/vendor_boot unpacking and repacking** (`patch_kernel` and others)
- ⚙️ **Feature XML and build.prop diff management** (`add_feature_v2` / `remove_feature` / `add_prop_v2` and others)
- 📲 **Google Apps integration** (`install_google_apps` / `install_default_google_apps`)

**Important:**
- ⚙️ Written for bash (`#!/bin/bash`). On Windows, WSL or MSYS2/Git Bash is required.
- 📁 Most functions depend on directories (`build/` / `tmp/`) and environment variables that are created by `port.sh` beforehand.

---

## 🎨 2. Logging Functions

The `error` / `yellow` / `blue` / `green` functions defined at `functions.sh:4-70` switch display language based on `$LANG` when called with 2 arguments.

- `LANG=ja*` or `LANG=zh_CN*` → use first argument (treated as Japanese)
- `LANG=en*` → use second argument (English)
- Other / unset → use first argument

**Standard calling convention:** `"Japanese text" "English text"` as two arguments.

---

## ✅ 3. Dependency Command Checks

### Function: `exists` ✔️
- 📍 Defined at: `functions.sh:72`
- 📥 Arguments: `(<command>)`
- ⚡ Behavior: Checks existence with `command -v` (returns success/failure exit code)

### Function: `abort` ❌
- 📍 Defined at: `functions.sh:76`
- 📥 Arguments: `(<command>)`
- ⚡ Behavior: Prints an error message and calls `exit 1`

### Function: `check` 🔍
- 📍 Defined at: `functions.sh:82`
- 📥 Arguments: `(<command>...)`
- ⚡ Behavior: Runs `exists` on all commands; calls `abort` for any that are missing

**Used in:** `port.sh` for upfront prerequisite verification, e.g. `check unzip aria2c ...` (around `port.sh:46`)

---

## 🖥️ 4. macOS Aliases

- 📍 Defined around: `functions.sh:88`
- When `OSTYPE=darwin*`, sets aliases to GNU tool variants:
  - `sed=gsed` / `grep=ggrep` / `find=gfind` / etc.

**Purpose:** Compensates for behavioral differences in BSD tools (e.g. `sed -i`) on macOS.

---

## 🔨 5. Smali / APK / JAR Patching Functions

These functions follow the pipeline: **dex → smali → modify → regenerate dex → repack into zip → (APK only) zipalign + sign**.

> ⚠️ **Many external tools are required** — if something fails, check your dependencies (`setup.sh`) and `PATH` first.

### Function: `patch_smali` 🔧
- 📍 Defined at: `functions.sh:105`
- **Key dependencies:**
  - `java`, `7z`, `sed`, `zipalign`, `apksigner`
  - `bin/apktool/smali*.jar`, `bin/apktool/baksmali*.jar`
  - `port_android_sdk`, `is_eu_rom` (controls which jar variant is used)
- **📥 Arguments:**
  1. Target filename (APK/JAR) e.g. `Settings.apk` — located via `find` under `build/portrom/images`
  2. Target smali file (filename or relative path)
  3. Search pattern
  4. Replacement string
  5. (Optional) Pass `regex` to use `sed`'s line-replace mode (`c\`)
- **📤 Output / side effects:**
  - Works in `tmp/<folder>/`
  - Updates the target file in-place (APKs are re-signed with `zipalign` → `apksigner`)

**Use case:** When applying a simple smali substitution to an app or framework file during `port.sh`'s patch phase.

### Functions: `baksmali_wrapper` 📦 / `smali_wrapper` 🔄
- 📍 Defined at: `functions.sh:813` / `functions.sh:787`
- **Purpose:**
  - `baksmali_wrapper`: Extracts dex from an APK and decompiles each dex into smali under `tmp/<n>/classes*/` — the setup step before editing.
  - `smali_wrapper`: Reassembles dex from `tmp/<n>/classes*/` and repacks it back into the source APK.
- **📤 Side effects:**
  - Extracted contents land under `tmp/`
  - `smali_wrapper` appends dex files to the APK with `7z` and logs the result (signing is done separately)

### Function: `fix_oldfaceunlock` 👤
- 📍 Defined at: `functions.sh:839`
- **Purpose:**
  - Aligns behavior to assume the old Face Unlock package (`com.oneplus.faceunlock`).
  - Also includes a forced rewrite of the MiniCapsule camera position string.
- **🔑 Key steps:**
  - Decompile `Settings.apk` with `baksmali_wrapper`, replace the body of the relevant method in `FaceUtils.smali` using `sed` range substitution
  - Replace `unknown_pkg` with `com.oneplus.faceunlock` in `CustomPkgConstants.smali` and related files
  - Decompile `SystemUI.apk`, patch `OpUtils.smali` via `bin/patchmethod.py`
  - In `MiniCapsuleManagerImpl.smali`, replace the range from a specific `invoke-static` to `move-result-object` with a `const-string`
  - Re-sign both APKs with `zipalign` + `apksigner`

### Function: `patch_smartsidecar` 🎨
- 📍 Defined at: `functions.sh:922`
- **Purpose:** Spoofs the brand check in `SmartSideBar.apk` (e.g. the realme brand detection).
- **🔑 Key steps:**
  - Decompile with `baksmali_wrapper`
  - Patch `isRealmeBrand` in `RealmeUtils.smali` via `bin/patchmethod.py`
  - Repack with `smali_wrapper`, re-sign with `zipalign` + `apksigner`

---

## 🖼️ 6. Image Extraction and AVB Disabling

### Function: `extract_partition` 📦
- 📍 Defined at: `functions.sh:192`
- **📥 Arguments:**
  1. `part_img` — e.g. `build/portrom/images/system.img`
  2. `target_dir` — destination directory
- **Dependencies:**
  - `tools_dir/gettype` (detects ext / erofs type)
  - ext: `python3 bin/imgextractor/imgextractor.py`
  - erofs: `extract.erofs`
- **📤 Side effects:**
  - Deletes the source `*.img` after extraction (`rm -rf ${part_img}`)
  - Creates a directory (e.g. `system/`) at the target location

**Note:** Automatically detects filesystem type and uses appropriate extraction tool.

### Function: `disable_avb_verify` 🔓
- 📍 Defined at: `functions.sh:219` (first version) and `functions.sh:234` (second version)
- **📥 Arguments:**
  1. `fstab` — path to fstab file(s)
- **📤 Side effects:**
  - Removes AVB verification flags from fstab
  - Disables vbmeta checks to allow unofficial ROMs to boot

---

## 🥾 7. Boot Image Patching

### Function: `patch_kernel` 🐧
- 📍 Defined at: `functions.sh:640`
- **Purpose:** Unpacks boot.img, replaces kernel/dtb, and repacks
- **Key features:**
  - Handles both compressed and raw ramdisks
  - Disables AVB verification in ramdisk
  - Supports custom kernel injection

### Function: `spoof_bootimg` 🎭
- **Purpose:** Adds `androidboot.vbmeta.device_state=unlocked` flag to boot header
- **Use case:** Bypasses device state verification for custom ROMs

---

## ⚙️ 8. Feature Flag Management

### Function: `add_feature_v2` ➕
- 📍 Defined at: `functions.sh:590`
- **Purpose:** Adds feature flags to XML configuration files
- **Types supported:**
  - `oplus_feature` → `com.oplus.oplus-feature-ext-bruce.xml`
  - `app_feature` → `com.oplus.app-features-ext-bruce.xml`
  - `permission_feature` → `com.oplus.android-features-ext-bruce.xml`
  - `permission_oplus_feature` → `oplus.feature-android-ext-bruce.xml`
- **📥 Usage:** `add_feature_v2 app_feature "feature.name^Label" "another.feature"`

### Function: `remove_feature` ➖
- **Purpose:** Removes feature flags from port ROM
- **Safety:** Won't remove if feature exists in base ROM (unless `force` flag is passed)

---

## 💾 9. Build Property Management

### Function: `add_prop_v2` 📝
- **Purpose:** Adds or modifies build properties in bruce/build.prop
- **Priority:** Checks multiple locations and creates if missing

### Function: `prepare_base_prop` 📋
- **Purpose:** Backs up and initializes build properties for port process
- **Key actions:**
  - Copies base ROM build.prop over port ROM's version
  - Creates bruce/build.prop for selective overrides
  - Sets up import line for property merging

### Function: `add_prop_from_port` 📤
- **Purpose:** Carries over port-specific properties from previous build
- **Behavior:**
  - Preserves ROM version and special properties
  - Merges camera/camerax settings
  - Only carries over properties not in base ROM

---

## 📲 10. Google Apps Integration (NEW) ⭐

### ⚠️ Important: GApps Must Be Downloaded Externally

ColorOS CN ROMs **DO NOT** include Google Apps. You MUST download GApps from external sources:
- **MindTheGapps** (recommended) — https://mindthegapps.com
- **OpenGApps** — https://opengapps.org

---

### Function: `validate_gapps_package` 🔍
- 📍 Defined at: `functions.sh:1177`
- **Purpose:** Validate GApps ZIP package before installation
- **📥 Arguments:** `(gapps_zip_path)`
- **🔑 Validation checks:**
  - ✅ ZIP file exists and is readable
  - ✅ Contains required partition structure (system/my_product/system_ext)
  - ✅ Contains Google Play Services (GMS)
  - ✅ Lists detected core apps (Chrome, Drive, Maps, Photos, Pay)

**Return Values:**
- `0` — Valid GApps package
- `1` — Invalid or missing GApps

**Usage:**
```bash
validate_gapps_package "/path/to/gapps.zip"
```

---

### Function: `install_google_apps` 📲
- 📍 Defined at: `functions.sh:1220`
- **Purpose:** Install validated GApps package into ROM
- **📥 Arguments:** `(gapps_zip_path)`
- **🔑 Features:**
  - Validates package before installation
  - Extracts from all partition types (system, my_product, system_ext)
  - Logs app count per partition
  - Handles errors gracefully with setup guide

**Error Handling:**
If GApps are missing or invalid, displays:
- ❌ Error message
- 📥 Download instructions (MindTheGapps, OpenGApps)
- 📋 Recommended setup steps

**Usage:**
```bash
install_google_apps "/path/to/gapps.zip"
```

**In port.sh:**
```bash
# Pass GApps as 4th parameter
sudo ./port.sh <baserom> <portrom> "" gapps.zip
```

---

### Function: `download_mindthegapps` 🌐
- 📍 Defined at: `functions.sh:1281`
- **Purpose:** Auto-download latest MindTheGapps for ColorOS CN integration
- **📥 Arguments:**
  - `android_version` (13, 14, 15, 16 — default: 13)
  - `output_file` (save location, default: tmp/MindTheGapps.zip)
- **🔑 Features:**
  - Automatic download from official GitHub releases
  - Dynamically fetches latest version with correct timestamp
  - arm64 architecture only (required for OP9/OP9Pro)
  - Progress bar display during download
  - Automatic verification after save
  - Fallback: curl → wget
- **✅ Returns:** 0 on success, 1 on failure
- **📝 Note:** Always gets the latest release, no manual URL updates needed

**Usage:**
```bash
# Download for Android 13 (default location)
download_mindthegapps 13

# Download for Android 15 to custom location
download_mindthegapps 15 "devices/common/MindTheGapps_A15.zip"

# Then use in porting
sudo ./port.sh baserom.zip portrom.zip "" devices/common/MindTheGapps_A15.zip
```

---

### Function: `download_opengapps` 📦
- 📍 Defined at: `functions.sh:1327`
- **Purpose:** Auto-download OpenGApps with variant selection for ColorOS CN
- **📥 Arguments:**
  - `arch` (arm64 or armeabi-v7a, default: arm64)
  - `android_version` (13, 14, 15, 16 — default: 13)
  - `variant` (pico, nano, micro, mini, stock, full, super — default: stock)
  - `output_file` (save location, default: tmp/OpenGApps_${variant}.zip)
- **🔑 Variant Sizes & Content:**
  - **pico** — 20MB (GMS only, minimal)
  - **nano** — 100MB (GMS + essentials)
  - **micro** — 150MB (+ Chrome, Maps, WebView)
  - **mini** — 300MB (+ Drive, Photos, Calendar)
  - **stock** — 500MB (recommended for porting) ⭐
  - **full** — 700MB+ (all Google apps)
  - **super** — 1GB+ (includes Google Play Games, Docs, Sheets)
- **✅ Returns:** 0 on success, 1 on failure
- **📥 Download Time:** 2-10 minutes depending on connection & variant

**Usage:**
```bash
# Download stock variant for Android 13 (default)
download_opengapps arm64 13 stock

# Download mini variant for Android 15
download_opengapps arm64 15 mini "tmp/OpenGApps_A15_mini.zip"

# Download pico (minimal) for storage-constrained devices
download_opengapps arm64 14 pico

# Then use in porting
sudo ./port.sh baserom.zip portrom.zip "" tmp/OpenGApps_A15_mini.zip
```
```

---

### Function: `setup_gapps_for_cos_cn` 📋
- 📍 Defined at: `functions.sh:1329`
- **Purpose:** Complete GApps setup guide for ColorOS CN porting
- **📥 Arguments:** None
- **🔑 Provides:**
  - Comparison of GApps sources (MindTheGapps vs OpenGApps)
  - Step-by-step setup instructions
  - Download links
  - Usage examples
  - Important warnings

**Usage:**
```bash
setup_gapps_for_cos_cn
```

**Output Example:**
```
🎯 Decision: Which GApps source to use?

Option 1️⃣  — MindTheGapps (Recommended)
  • Specifically designed for GMS-less ROMs
  • Best compatibility with ColorOS CN
  • Download: https://mindthegapps.com

Option 2️⃣  — OpenGApps (Alternative)
  • More variants available
  • Larger packages overall
  • Download: https://opengapps.org

📋 Recommended Setup:
  1. Download MindTheGapps for your Android version
  2. Place ZIP in project root or devices/common/
  3. Run: sudo ./port.sh <baserom> <portrom> --- /path/to/gapps.zip
```

---

### Function: `configure_google_play_services` 🔌
- 📍 Defined at: `functions.sh:1373`
- **Purpose:** Configure GMS system properties
- **🔑 Properties set:**
  - `ro.com.google.clientidbase` — Android Google identification
  - `ro.com.google.gmsversion` — GMS version
  - `ro.setupwizard.enterprise_mode` — Setup wizard settings
  - `ro.com.google.gwsdisabled` — Google Web Services
  - Location & account services
  - Network & USB configuration

**Usage:**
```bash
configure_google_play_services
```

---

### Function: `is_coloros_cn` 🔍 — NEW ⭐
- 📍 Defined at: `functions.sh:1149`
- **Purpose:** Auto-detect if port ROM is ColorOS CN (lacks Google Apps)
- **📥 Arguments:**
  - `build_prop_path` (optional, default: `build/portrom/images/my_manifest/build.prop`)
- **🔑 Detection Indicators:**
  - `ro.rom.zone=cn` — Chinese ROM variant
  - `ro.build.fingerprint` contains "CN" marker
  - `ro.build.display.id` contains "CN"
  - Absence of `ro.com.google.clientidbase` property
- **✅ Returns:** 0 if ColorOS CN detected, 1 if global/already has GApps

**Usage:**
```bash
# Check if current port ROM is COS CN
if is_coloros_cn; then
    echo "This is ColorOS CN — needs GApps"
fi

# Check custom build.prop
is_coloros_cn "path/to/build.prop"
```

---

### Function: `auto_download_gapps_for_coscn` 🚀 — NEW ⭐
- 📍 Defined at: `functions.sh:1552`
- **Purpose:** Automatically detect ColorOS CN and download/install GApps (all-in-one)
- **🔄 Called automatically from:** `port.sh` (during patch application phase)
- **📥 Arguments:**
  - `build_prop_path` (optional, default: `build/portrom/images/my_manifest/build.prop`)
  - `android_version` (13-16, default: 13)
  - `gapps_output` (save location, default: `tmp/MindTheGapps_auto.zip`)
- **🔑 Automatic Actions:**
  1. Detects if port ROM is ColorOS CN using `is_coloros_cn()`
  2. If COS CN: Automatically downloads MindTheGapps via `download_mindthegapps()`
  3. If COS CN: Automatically installs via `install_google_apps()`
  4. If global variant: Skips installation and returns success
- **✅ Returns:** 0 on success (installed or skipped), 1 on error

**Default Behavior (Automatic from port.sh):**
```bash
# Just run port.sh normally — GApps auto-installation is built-in!
sudo ./port.sh baserom.zip portrom.zip

# Output during patch application:
# Apply Gapps
# 🚀 ColorOS CN detected — auto-downloading & installing Google Apps...
# ✅ Google Apps installed successfully
```

**Manual Usage (Optional):**
```bash
# Auto-detect and install GApps for COS CN
auto_download_gapps_for_coscn

# Custom Android version
auto_download_gapps_for_coscn "build/portrom/images/my_manifest/build.prop" 15

# Custom save location
auto_download_gapps_for_coscn "build/portrom/images/my_manifest/build.prop" 15 "devices/common/gapps.zip"
```

**Key Benefits:**
- 🤖 **Fully automatic** — No manual intervention needed during port.sh
- 🔍 **Smart detection** — Only downloads if ColorOS CN detected
- 📱 **Pre-installed appearance** — GApps installed to system partitions (appears on first boot)
- ⚡ **Zero-config** — Works out-of-box with port.sh
- ✅ **Safe** — Skips installation if ROM already has GApps

---

## 🎨 11. 3D Wallpaper Integration (ColorOS CN) — NEW ⭐

### Function: `extract_3d_wallpapers` 🎨
- 📍 Defined at: `functions.sh:1277`
- **Purpose:** Extract 3D wallpaper packages and assets from port ROM
- **📥 Arguments:** `(source_rom)` optional
- **🔑 Actions:**
  - Searches for wallpaper APK packages (com.oplus.theme.wallpaper3d, etc.)
  - Copies wallpaper directories to my_product/app
  - Extracts 3D model assets & configurations

**Packages Extracted:**
- `com.oplus.theme.wallpaper3d` — 3D wallpaper engine
- `com.coloros.wallpaper` — ColorOS provider
- `com.oplus.wallpaper.livewallpaper` — Live wallpaper APK
- `com.oplus.wallpaperservice` — Service daemon

### Function: `extract_wallpaper_assets` 📦
- **Purpose:** Extract 3D wallpaper media assets and models
- **📂 Directories scanned:**
  - `my_product/media/wallpapers` — Images & models
  - `my_product/media/3d_wallpapers` — 3D assets
  - `vendor/oplus/wallpaper_data` — Vendor data
  - `system/app/WallpaperCropper` — Tools
  - `system_ext/app/WallpaperPickerGoogle` — UI

### Function: `integrate_3d_wallpaper_configs` ⚙️
- **Purpose:** Configure 3D wallpaper system properties
- **📋 Properties set:**
  - `ro.oplus.wallpaper.3d.enabled=true`
  - `ro.livewallpaper.dynamic.support=true`
  - `persist.sys.wallpaper.animation=true`
  - `ro.oplus.wallpaper.parallax.support=true`
  - `ro.oplus.wallpaper.dark_mode.support=true`

### Function: `copy_wallpaper_from_portrom` 📥
- **Purpose:** Verify & copy wallpaper files from port ROM
- **🔍 Verification:**
  - Checks existence of wallpaper directories
  - Logs file count & structure
  - Preserves directory structure

### Function: `install_3d_wallpaper_apks` 📱
- **Purpose:** Install and integrate wallpaper APKs
- **📥 Target APKs:**
  - `com.oplus.theme.wallpaper3d`
  - `com.coloros.wallpaper`
  - `com.oplus.wallpaper.livewallpaper`
- **🔏 Features:**
  - Searches multiple partition locations
  - Copies to `my_product/app/`
  - Verifies APK signatures

### Function: `add_wallpaper_features` 🎯
- **Purpose:** Add system feature flags for wallpaper support
- **🏷️ Feature flags added:**
  - **oplus_feature:** 3D Wallpaper, Live Picker, Dynamic, Parallax
  - **app_feature:** 3D enabled, High quality rendering
  - **permission_feature:** Access, Read, Manage wallpapers

### Function: `extract_wallpaper_metadata` 📋
- **Purpose:** Extract & log wallpaper-related build properties
- **🔍 Scans for:** Properties containing "wallpaper", "3d", or "live"
- **📊 Output:** Count & list of discovered properties

### Function: `port_3d_wallpapers_full` ⭐ (Main Function)
- 📍 Defined at: `functions.sh:1450`
- **Purpose:** Comprehensive 3D wallpaper porting (all-in-one)
- **🔄 Complete workflow:**
  1. Extract wallpaper packages from base ROM
  2. Copy wallpaper-related files from port ROM
  3. Install wallpaper APKs with dependencies
  4. Configure system properties
  5. Add feature flags
  6. Extract metadata & verify

**Usage:**
```bash
# Full integration in one call
port_3d_wallpapers_full

# Or use individual functions
extract_3d_wallpapers
install_3d_wallpaper_apks
integrate_3d_wallpaper_configs
add_wallpaper_features
```

**Features Applied:**
- ✅ Wallpaper APKs extracted & integrated
- ✅ 3D models copied from port ROM
- ✅ System properties configured
- ✅ Feature flags added to manifest
- ✅ Metadata verified & logged

---

## 📚 12. Utility Functions

### Function: `convert_version_to_number` 🔢
- **Purpose:** Converts semantic version to numeric representation
- **Example:** `14.0.3` → `140003`

### Function: `get_oplusrom_version` 📖
- **Purpose:** Extracts the highest ColorOS version from build properties
- **Scans:** my_manifest, my_product build.prop files

---

## 🚨 13. Error Handling

**Signal Trap:**
```bash
trap 'error "Script interrupted! Exiting to prevent accidental deletion." ; exit 1' SIGINT
```
- Prevents accidental file deletion if script is interrupted with Ctrl+C

---
- `port.sh` relies on this behavior — the source `.img` is gone after extraction.

### Function: `disable_avb_verify` (defined twice with the same name)
- **Definition 1** (single file): `functions.sh:178`
  - Argument: path to a specific `fstab` file
  - Uses `sed` to strip `,avb*` / `avb_keys` entries
- **Definition 2** (directory scan): `functions.sh:214`
  - Argument: a directory — `find` locates all `fstab*` files inside and edits them all
  - If `pack_type=EXT`, also deletes lines containing `erofs`

Important:
- In bash, the later definition takes precedence. So after `functions.sh:214`, **Definition 2 is active**.
- When `port.sh` calls `disable_avb_verify build/portrom/images/`, it is calling **Definition 2** (around `port.sh:2094`).

---

## 7. boot / vendor_boot Patching

### Function: `spoof_bootimg`
- Defined at: `functions.sh:233`
- Arguments: `bootimg` (file path)
- Behavior:
  - Unpacks with `magiskboot unpack` to produce a `header` file
  - Appends `androidboot.vbmeta.device_state=unlocked` to the `cmdline` line
  - Repacks with `magiskboot repack` and overwrites the original file

### Function: `patch_kernel_to_bootimg`
- Defined at: `functions.sh:246`
- Purpose:
  - Unpacks `boot.img`, extracts and patches the ramdisk with `disable_avb_verify`, swaps in the kernel/dtb, and writes the result to `devices/<device>/<bootimg_name>`.
- Note:
  - A newer implementation called `patch_kernel` exists in the same file (see below).
  - `port.sh` primarily uses `patch_kernel` (around `port.sh:1981`).

### Function: `patch_kernel`
- Defined at: `functions.sh:310`
- Arguments:
  1. `kernel_file` — e.g. `Image` extracted from AnyKernel
  2. `dtb_file` — `dtb` extracted from AnyKernel
  3. `bootimg_name` — output filename, e.g. `boot_ksu.img`
- Key behavior:
  1. Locates `boot.img` under `build/baserom/` and copies it to the working directory
  2. Unpacks with `magiskboot unpack`
  3. If `ramdisk.cpio` is present, extracts it and applies `disable_avb_verify`
  4. Replaces `kernel` and `dtb`
  5. If `convert_to_aonly=true`, removes `slotselect` from `fstab.*` files in the ramdisk
  6. Repacks with `magiskboot repack` → output to `devices/<device>/<bootimg_name>`
  7. If `vendor_boot.img` exists, applies the same unpack → dtb swap → repack process, outputting to `devices/<device>/vendor_boot.img`

---

## 8. Feature XML Add / Remove

These functions back the feature flag add/remove operations (`add_feature_v2` / `remove_feature`) in `port.sh`. Target files are XMLs under `build/portrom/images/my_product/etc/{extension,permissions}`, with diffs written to `*-ext-ozyern.xml`.

### Function: `add_feature`
- Defined at: `functions.sh:482`
- Arguments:
  - `feature` — e.g. `oplus.software.xxx`
  - `file` — destination XML file
- Behavior:
  - Scans portrom-side XMLs; skips if the feature already exists
  - Otherwise inserts `<... name="..."/>` just before the closing tag of the target XML

### Function: `add_feature_v2`
- Defined at: `functions.sh:500`
- Arguments:
  - First arg `type`: one of `oplus_feature` / `app_feature` / `permission_feature` / `permission_oplus_feature`
  - Remaining args: one or more feature entries
- Entry format (important):
  - Uses `^` as a separator: `"feature.name^comment^args=\"...\""`
    - Field 1: feature name (the key that actually gets written)
    - Field 2: label to include as an XML comment (optional)
    - Field 3: extra attributes (optional, e.g. `args="..."`)
- Output:
  - Appends to `build/portrom/images/my_product/etc/.../<base>-ext-ozyern.xml` as a diff (creates the file if it doesn't exist)

### Function: `remove_feature`
- Defined at: `functions.sh:589`
- Arguments:
  - `feature`
  - `force` (optional — pass `force` to skip the base ROM check)
- Behavior (without `force`):
  - If the feature exists on the baserom side: **skip deletion** (compatibility takes priority)
  - If the feature is commented out on the baserom side: proceed with deletion
  - Otherwise: delete the matching line from the portrom-side XMLs

---

## 9. build.prop Diff Management

`port.sh` uses a strategy of "use the base device's build.prop as the foundation, and store ported additions in a separate file (`ozyern`)". The following functions implement this.

### Functions: `add_prop` / `remove_prop`
- Defined at: `functions.sh:639` / `functions.sh:653`
- Target: `build/portrom/images/my_product/build.prop`
- `remove_prop` only deletes a prop if it **does not exist** on the base ROM side.

### Functions: `add_prop_v2` / `remove_prop_v2`
- Defined at: `functions.sh:661` / `functions.sh:685`
- Targets:
  - `build/portrom/images/my_product/build.prop`
  - `build/portrom/images/my_product/etc/ozyern/build.prop`
- `add_prop_v2` routes the update to whichever file already contains the prop.
- `remove_prop_v2` does **not** delete — it **comments out** the prop (prepends `#`).
  - Passing `force` skips the base ROM existence check and comments out unconditionally.

### Function: `prepare_base_prop`
- Defined at: `functions.sh:705`
- Purpose:
  - Backs up the current portrom build.prop and overwrites it with the baserom build.prop.
  - Initializes `ozyern/build.prop` and adds the `import /mnt/vendor/.../ozyern/build.prop` line.
- Side effects:
  - Creates `tmp/build.prop.portrom.bak`
  - portrom's build.prop is replaced with baserom's content

### Function: `add_prop_from_port`
- Defined at: `functions.sh:731`
- Inputs:
  - `tmp/build.prop.portrom.bak` (the original portrom props)
  - `build/baserom/.../build.prop` (the base ROM props)
- Output:
  - Appends to `build/portrom/images/my_product/etc/ozyern/build.prop` any props that don't exist in baserom
  - Certain keys (`force_keys`) are always carried over regardless

---

## 10. Version Utilities

### Function: `convert_version_to_number`
- Defined at: `functions.sh:936`
- Arguments: `(<x.y.z>)`
- Output: numeric value `x*10000 + y*100 + z` (for comparison purposes)

### Function: `get_oplusrom_version`
- Defined at: `functions.sh:950`
- Purpose:
  - Scans several candidate `build.prop` files for `ro.build.version.oplusrom.display` and returns the highest version found.

---

## 11. Safe Exit (SIGINT)

At `functions.sh:982`, a `SIGINT` (Ctrl+C) trap is set to exit cleanly.
This prevents leaving the filesystem in a half-broken state during mass `rm -rf` operations or mid-extraction interruptions.