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

## 📲 10. Google Apps Integration (NEW)

### Function: `install_google_apps` 🔵
- 📍 Defined at: `functions.sh:1177`
- **Purpose:** Installs Google Play Services and associated apps
- **📥 Arguments:**
  - `gapps_zip` (optional) — custom GApps package path
- **🔑 Features:**
  - Auto-detects custom GApps ZIP structure
  - Falls back to default package if not provided
  - Integrates with my_product/system_ext partitions

**Usage:**
```bash
install_google_apps "path/to/gapps.zip"  # Custom
install_google_apps                       # Default package
```

### Function: `install_default_google_apps` 📦
- **Includes:**
  - 📱 Chrome, Maps, Drive, Photos, Pay
  - 📧 Gmail, Messages, Docs/Sheets
  - 🎥 YouTube, Photos, Search
  - 💳 Wallet & Payment apps

### Function: `configure_google_play_services` 🔌
- **Purpose:** Adds GMS configuration properties
- **Enables:** GPlay Store, Analytics, Regional settings
- **Adds properties:** GMS version, client IDs, DataRoaming

---

## 📚 11. Utility Functions

### Function: `convert_version_to_number` 🔢
- **Purpose:** Converts semantic version to numeric representation
- **Example:** `14.0.3` → `140003`

### Function: `get_oplusrom_version` 📖
- **Purpose:** Extracts the highest ColorOS version from build properties
- **Scans:** my_manifest, my_product build.prop files

---

## 🚨 12. Error Handling

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