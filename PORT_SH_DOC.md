# port.sh Detailed Reference (Implementation Tracking)

This document explains `port.sh` following its **actual implementation** — covering variables, branch conditions, execution order, which ZIPs/overlays get merged and when, and exactly what gets rewritten. Since there are a large number of branches depending on device, ROM version, and region, each patch is documented alongside the condition that triggers it.

Note: Details for each function in `functions.sh` (inputs/outputs/side effects/tool dependencies) are covered in [FUNCTIONS_SH_DOC.md](FUNCTIONS_SH_DOC.md).

---

## 0. Purpose (What This Script Ultimately Produces)

`port.sh` can produce two types of output depending on `pack_method` in `bin/port_config`.

**1) `pack_method=stock`**
- Assembles a directory structure similar to Android's `target_files` format (`out/target/product/<device>/`) and generates a **full OTA ZIP** using `otatools/bin/ota_from_target_files`.
- Example output (after rename): `out/<target_folder>/ota_full-<rom_version>-<model>-<timestamp>-<region>-<spl>-<hash>.zip`

**2) `pack_method!=stock`**
- Generates `super.img` with `lpmake`, compresses it to `super.zst` with `zstd`, and creates a **fastboot flash ZIP** (Windows/Mac/Linux scripts + firmware-update + META-INF).
- Example output: `out/<OS>_<rom_version>_<hash>_<model>_<timestamp>_<pack_type>.zip`

In both cases, the script **extracts ROM partitions, modifies them, repacks them, and disables vbmeta verification**.

---

## 1. Usage and Arguments

```
sudo ./port.sh <baserom> <portrom> [portrom2] [portparts]
```

- `<baserom>`: Official ROM for the target/base device (OTA ZIP or fastboot ZIP). URLs are also accepted.
- `<portrom>`: Source ROM to port from (ColorOS / OxygenOS / realme UI family). URLs also accepted.
- `[portrom2]`: Second source ROM for mixed porting. Setting this enables `mix_port=true`.
- `[portparts]`: Partitions to take from `portrom2` during mixed porting.
  - **Implementation note**: Assigned as `mix_port_part=($portparts)`, so pass as **space-separated** values (not comma-separated as some docs suggest).
  - Default when unset: `("my_stock" "my_region" "my_manifest" "my_product")`

---

## 2. Required Tools (Implementation Dependencies)

`port.sh` uses `functions.sh`'s `check` at the top to verify these exist:
- `unzip` `aria2c` `7z` `zip` `java` `python3` `zstd` `bc` `xmlstarlet`

However, the following are **also required but not checked**:
- `git` — used with `git init` / `git apply` for framework.jar smali patches
- `jq` — used to edit `unit_config_list.json` in the AIUnit patch
- `md5sum` — used to hash the output ZIP
- `unix2dos` — used to convert line endings in Windows batch scripts
- `payload-dumper` — expected in `PATH` via `bin/<OS>/<ARCH>`
- `brotli` and `sdat2img.py` — used when converting `.new.dat.br` format base ROMs
- `extract.erofs`, `gettype`, `mkfs.erofs` — for EROFS extraction and generation
- `magiskboot` — used in `functions.sh` for kernel/boot patching
- `ksud` — used when injecting KernelSU into init_boot

In short, you need everything installed by `setup.sh` + bundled binaries + `git`/`jq`/etc., or the script will fail partway through.

---

## 3. Key Configuration (Reading `bin/port_config`)

`port.sh` reads the following from `bin/port_config` using `grep key | cut -d= -f2`:

- `partition_to_port` → `port_partition`
  Partitions to extract from the source ROM (used with `payload-dumper --partitions` and unzip).
- `possible_super_list` → `super_list`
  Candidate partitions to extract, repack, and include in super.
- `repack_with_ext4` → `repackext4` → `pack_type`
  If `true`, sets `pack_type=EXT`; otherwise `pack_type=EROFS`.
  - **Implementation note**: Repacking is currently hardcoded to `mkfs.erofs`. There is no EXT4 branch in `port.sh` — `pack_type` mainly affects logging and fstab handling in `functions.sh`.
- `super_extended` → `super_extended`
  Affects super size selection, debloat conditions, and reserve.img handling.
- `pack_method` → `pack_method`
  When set to `stock`, enters the OTA generation route using `otatools/bin/ota_from_target_files`.
- `pack_with_dsu`, `ddr_type`, `reusable_partition_list` are read but not referenced later in `port.sh` (reserved for future use / not implemented).

---

## 4. Directory Structure (Critical)

Main working directories created by `port.sh`:

- `build/baserom/`
  - `images/` — extracted `.img` files from baserom, or post-extraction directories
  - May also contain `firmware-update/` or `storage-fw/` depending on source ZIP contents
- `build/portrom/`
  - `images/` — mix of `.img` files from portrom, post-extraction directories, and regenerated `.img` files
  - Intermediate outputs like `super.zst` are produced here
- `build/<version_name>/`
  - Extraction cache for portrom. If this exists on the next run, extraction is skipped and files are copied from here.
- `tmp/`
  - Temporary area for APK/JAR decompilation (smali), AnyKernel extraction, etc.
- `out/`
  - Final output location (OTA ZIP or fastboot ZIP).
  - When `pack_method=stock`, a target_files-like structure is built under `out/target/product/<device>/`.

---

## 5. Execution Flow by Phase

### Phase A: Initialization and PATH
1. Variable initialization:
   - `baserom=$1`, `portrom=$2`, `portrom2=$3`, `portparts=$4`
   - `work_dir=$(pwd)`
   - `tools_dir=$work_dir/bin/$(uname)/$(uname -m)`
   - `PATH` gets `bin/<OS>/<ARCH>/` and `otatools/bin/` prepended
2. `source functions.sh`
3. `check ...` verifies tool availability
4. `bin/port_config` is read to determine `port_partition`, `super_list`, `pack_type`, etc.

### Phase B: Download if Arguments are URLs
- If `baserom`/`portrom` are not files but match `grep http`, download with `aria2c`.
- Query strings stripped via `basename | sed 's/\?t.*//'`.
- If the file still doesn't exist after download, `error` and exit.

### Phase C: ROM Package Type Detection
Detection is done by inspecting ZIP contents with `unzip -l`.

**Baserom detection:**
- Contains `payload.bin` → `baserom_type=payload` (also extracts `oplus_hex_nv_id` from metadata)
- Matches `br$` (i.e., contains `.new.dat.br`) → `baserom_type=br`
- Matches `\.img$` → `baserom_type=img`
- None of the above → abort

**Portrom detection:**
- Contains `payload.bin` → `portrom_type=payload`
- Matches `\.img$` → `portrom_type=img`
- None of the above → abort

If `META-INF/com/android/metadata` exists:
- `version_name=` and `ota_version=` are extracted from it
Otherwise:
- `version_name` comes from the filename, `ota_version` defaults to `"V16.0.0"`

**Portrom2 (mixed porting):**
- If `portrom2` is specified, sets `mix_port=true`
- If `portparts` is specified, sets `mix_port_part=($portparts)`; otherwise uses the default 4 partitions
- `portrom2`'s contents are checked for `payload`/`img` type, and `version_name2` is determined

### Phase D: Cleanup
Deleted:
- `app/` `tmp/` `config/` `build/baserom/` `build/portrom/`
- `find . -type d -name 'ColorOS_*' | xargs rm -rf`

Then:
- `build/baserom/images/` and `build/portrom/images/` are created
- `tmp/` is created and `TMPDIR` is set

### Phase E: Baserom Extraction (payload / br / img)

**`baserom_type=payload`:**
- `payload-dumper --out build/baserom/images/ "$baserom"`

**`baserom_type=br`:**
1. `unzip -q "$baserom" -d build/baserom`
2. If filenames contain numbers, normalize them (handles things like `name123.transfer.list`)
3. For each `<i>` in `$super_list` where `<i>.new.dat.br` exists:
   - `brotli -d <i>.new.dat.br`
   - `python3 sdat2img.py <i>.transfer.list <i>.new.dat build/baserom/images/<i>.img`
   - Delete `.new.dat*`, `transfer.list`, `patch.*` after conversion

**`baserom_type=img`:**
- `unzip -q "$baserom" -d build/baserom/tmp/`
- `find ... -name "*.img" -exec mv ... build/baserom/images/`
- Delete `build/baserom/tmp`

### Phase F: Portrom Extraction (Cache-First)

**If cache exists:**
If `build/<version_name>/` exists, skip extraction and copy each `<part>.img` listed in `port_partition` directly.

**`portrom_type=payload`:**
- `payload-dumper --partitions "$port_partition" --out build/<version_name>/ "$portrom"`
- Copy extracted `.img` files to `build/portrom/images/`

**`portrom_type=img`:**
1. Split `port_partition` by `IFS=','` into an array
2. Build a target list of `<part>.img` / `<part>_a.img` / `<part>_b.img`
3. `unzip -q "$portrom" <targets...> -d build/<version_name>/`
4. Copy all `find build/<version_name> -name "*.img"` to `build/portrom/images/`

### Phase G: Portrom2 Extraction (Mixed Porting)
Same process as Phase F. At the end, only partitions listed in `mix_port_part` are copied (overwriting) into `build/portrom/images/`.

### Phase H: Baserom Partition Extraction
```bash
for part in system product system_ext my_product my_manifest; do
  extract_partition build/baserom/images/${part}.img build/baserom/images
done
```
- `extract_partition` (from `functions.sh`) uses `gettype` to detect ext4/erofs and extracts to a directory.
- The source `.img` is deleted after extraction (inside the function via `rm -rf ${part_img}`).

### Phase I: Move Baserom vendor/odm to portrom and Extract
Targets: `vendor odm my_company my_preload system_dlkm vendor_dlkm my_engineering`

Process:
1. If a `<image>.img` exists on the baserom side, `mv` it to `build/portrom/images/<image>.img`
2. `extract_partition build/portrom/images/<image>.img build/portrom/images/`

Purpose:
- Pre-extracting vendor/odm ensures that subsequent patch application, feature XML manipulation, and SELinux config generation have their prerequisites in place.

### Phase J: Finalize super_list and Extract Portrom Partitions
- If `build/portrom/images/system_dlkm` doesn't exist, replace `super_list` with a fixed list (for devices without system_dlkm).
- For each `part` in `$super_list`: if not yet extracted, run `extract_partition` in the background, then `wait` for all to complete.
  - After extraction, if the same `.img` still exists on the baserom side, delete it (`rm -rf build/baserom/images/${part}.img`).

### Phase K: ROM Metadata (Android/SDK/Device/Region/Brand)
A large number of detection flags are set here. Key ones:

- `base_android_version` / `port_android_version`
- `base_android_sdk` / `port_android_sdk`
- `base_rom_version` / `port_rom_version` (from `ro.build.display.ota`)
- `base_device_code` / `port_device_code` (from `ro.oplus.version.my_manifest`)
- `base_product_device` / `port_product_device` (from `ro.product.device`)
- `base_product_model` / `port_product_model` (from `ro.product.model`)
- `base_market_name` / `port_market_name` (from `ro.vendor.oplus.market.name`)
- `base_my_product_type` / `port_my_product_type` (from `ro.oplus.image.my_product.type`)
- `regionmark` (first match of `ro.vendor.oplus.regionmark=` in portrom's build.props)
- `base_regionmark` (same for baserom; falls back to first `ro.oplus.image.my_region.type=` value)
- `vendor_cpu_abilist32` (from `ro.vendor.product.cpu.abilist32`)
- `base_area`/`base_brand` and `port_area`/`port_brand` (grepped from `ro.oplus.image.system_ext.area/brand`)

Brand detection flags:
- Baserom side: `baseIsColorOSCN` / `baseIsOOS` / `baseIsRealmeUI`
- Portrom side: `portIsColorOSGlobal` / `portIsOOS` / `portIsColorOS` / `portIsRealmeUI`

A/B detection:
- If `ro.build.ab_update=true` is found in vendor, sets `is_ab_device=true`

64-bit-only detection (portrom is 64-bit-only but vendor has 32-bit info):
- If `build/portrom/images/system/system/bin/app_process32` is missing AND `vendor_cpu_abilist32` is non-empty:
  - Force vendor/build.prop `abilist` to `arm64-v8a`
  - Clear `abilist32`
  - Set `ro.zygote` in vendor/default.prop to `zygote64`

### Phase L: my_manifest Alignment (Matching the Base Device)
Minimum actions performed here:
- Set `ro.build.display.id` to `target_display_id`
- Align `ro.product.first_api_level` to the base ROM value
- Add `ro.build.display.id.show` if missing, replace if present
- Delete `ro.build.version.release` (to avoid manifest-side conflicts)
- Unify market name to the base ROM's value
- Delete `ro.oplus.watermark.betaversiononly.enable`

Additionally, hardcoded paths exist:
- `BASE_PROP="/home/bruce/coloros_port/build/baserom/images/my_manifest/build.prop"`
- `PORT_PROP="/home/bruce/coloros_port/build/portrom/images/my_manifest/build.prop"`

These copy `.name/.model/.manufacturer/.device/.brand/.my_product.type` keys from baserom to portrom.
**Note: If your working directory differs from `bruce`'s, this block will break. Be aware.**

### Phase M: VNDK Apex Missing File補完
- Scan vendor `.prop` files to find `ro.vndk.version`
- If `system_ext/apex/com.android.vndk.v${vndk_version}.apex` is missing from portrom, copy it from baserom

### Phase N: Security Patch Date Alignment Across All build.props
- For every `build.prop` under `build/portrom/images` (found with `find`):
  - Overwrite `ro.build.version.security_patch=...` with `portrom_version_security_patch`

---

## 6. Patch Phase (The Main Work)

The middle and latter portions of `port.sh` consist largely of:
- "If target file exists..."
- "If condition matches (Android version / region / SoC / brand)..."

...followed by ZIP extraction, APK/JAR smali patching, XML feature add/remove, and build.prop editing in large quantities.

Key patches are organized by category below.

### 6.1 services.jar (Signature Scheme / SharedUID Relaxation)
Target: `build/portrom/images/system/system/framework/services.jar`

Cache: If `build/<app_patch_folder>/patched/services.jar` exists, copy it and skip.

Otherwise:
1. Decompile `services.jar` to smali with `APKEditor.jar` → `tmp/services`
2. Stub out `ScanPackageUtils.smali`'s `assertMinSignatureSchemeIsValid` via `patchmethod.py`
3. Find `getMinimumSignatureSchemeVersionForTargetSdk`, delete up to `move-result`, insert `const/4 vX, 0x0` (sets minimum signature scheme requirement to 0)
4. In `ReconcilePackageUtils.smali`, insert `const/4 <reg>, 0x1` just before the `sput-boolean` to `ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS` (allows system shareduid for non-preload apps)
5. Rebuild with `APKEditor.jar`, save as `patched/services.jar`, copy back

### 6.2 framework.jar (Property Hook Patch)
Target: `build/portrom/images/system/system/framework/framework.jar`

Cache: If `build/<app_patch_folder>/patched/framework.jar` exists, copy it and skip.

Otherwise:
1. Copy to `tmp/framework.jar`
2. Only proceeds if `devices/common/0001-core-framework-Introduce-OplusPropsHookUtils-V6.patch` exists
3. Decompile with `APKEditor.jar` → `tmp/framework` (smali)
4. `git init` in `tmp/framework` → initial commit → `git apply` the patch
5. Rebuild with `APKEditor.jar`, save as `patched/framework.jar`, copy back

Purpose:
- Sets up the infrastructure for `persist.oplus.prophook.*`-style per-app property spoofing (patch content is in the patch file itself).

### 6.3 oplus-services.jar (GMS Restriction Removal)
Target: `oplus-services.jar` (found via `find build/portrom/images -name "oplus-services.jar"`)

Cache: If `build/<app_patch_folder>/patched/oplus-services.jar` exists, copy and skip.

Otherwise:
1. Decompile → `tmp/OplusService`
2. Stub `isGmsRestricted` in `OplusBgSceneManager.smali` to return `false` via `patchmethod.py`
3. Rebuild and copy back

### 6.4 Face Unlock (SoC 8250/8350)
Condition: `base_device_family == OPSM8250` or `OPSM8350`

Process:
- If `devices/common/face_unlock_fix_common.zip` exists, clean vendor overlay and unzip it
- If `OPFaceUnlock.apk` exists on the baserom side (old face unlock):
  - Unzip `devices/<base_product_device>/face_unlock_fix.zip`
  - Delete old OnePlus faceunlock HAL/RC/VINTF/so files (to avoid conflicts)

### 6.5 A13→A14 Generation Gap Bridging
Condition: `base_android_version == 13` and `port_android_version == 14`

Process:
- Unzip `devices/common/a13_base_fix.zip`
- Delete conflicting charger/wifi/felica/midas services, manifests, jars, and .so files

### 6.6 Port is Android 15+ — RIL/charger/NFC/cryptoeng
Condition: `port_android_version >= 15`

SoC-specific:
- `OPSM8250` → unzip `devices/common/ril_fix_sm8250.zip` + delete some libraries
- `OPSM8350` → unzip `devices/common/ril_fix_sm8350.zip` + delete some libraries

Charger v3→v6 (when base is Android 14):
- If `vendor.oplus.hardware.charger-V3-service` exists, unzip `devices/common/charger-v6-update.zip`
- Delete v3 bin/rc/ndk .so files

When base is Android 13 (large gap bridging):
- Unzip `devices/common/ril_fix_a13_to_a15.zip`
- Add `persist.vendor.radio.virtualcomm=1` to `odm/build.prop` if not present
- Mass-delete conflicting faceunlock/charger/wifi/felica files
- NFC: unzip `devices/common/nfc_fix_for_a13.zip` → delete old nfc service files
- cryptoeng: unzip `devices/common/cryptoeng_fix_a13.zip` if present (intended to restore privacy features like app lock)

### 6.7 SurfaceFlinger Game FPS Default
- Append `ro.surface_flinger.game_default_frame_rate_override=120` to `vendor/default.prop`

### 6.8 AI Call (HeyTapSpeechAssist.apk)
Target: `HeyTapSpeechAssist.apk` (`targetAICallAssistant`)

Cache: If `build/<app_patch_folder>/patched/HeyTapSpeechAssist.apk` exists, copy and skip.

Otherwise:
1. Decompile → `tmp/HeyTapSpeechAssist`
2. Patch `getSupportAiCall` in `AiCallCommonBean.smali` to return `true`
3. Replace all `Build.MODEL` reads across all smali with `const-string <reg>, "PLG110"` (model spoof)
4. Rebuild and copy back

### 6.9 OTA.apk (dm-verity / Lock State Check Bypass)
First attempts to substitute based on region:
- If `regionmark == CN` → copy `devices/common/OTA_CN.apk` to `system_ext/app/OTA/OTA.apk`
- Otherwise → copy `devices/common/OTA_IN.apk`

If that fails (`ota_patched==false`):
1. Decompile `OTA.apk` → `tmp/OTA`
2. `patchmethod_v2.py -d tmp/OTA -k ro.boot.vbmeta.device_state locked -return false`
   - Stubs out the method that checks the "locked" state to always return false, bypassing dm-verity-style checks
3. Rebuild and copy back

### 6.10 AIUnit.apk (High-End AI Feature Unlock)
Target: `AIUnit.apk`

Model variable:
- Default: `MODEL=PLG110`
- If `regionmark != CN`: `MODEL=CPH2745`

Process (if no cache):
1. Replace `Build.MODEL` reads with `const-string` for model spoofing
2. Patch `isAllWhiteConditionMatch`, `isWhiteConditionsMatch`, `isSupport` in `UnitConfig.smali` to return `true`
3. Edit `unit_config_list.json` with `jq`:
   - If `whiteModels` is empty, insert new model list
   - If it exists, add without duplicates
   - Lower `minAndroidApi` to 30
4. Rebuild and copy back

### 6.11 Android 16 Port + base<15 — AI Eraser Workaround
Condition: `port_android_version == 16` and `base_android_version < 15`

Process:
- Copy `odm/lib64/libaiboost.so` to `my_product/lib64/libaiboost.so`

### 6.12 Gallery AI Editor / xeu_toolbox
Branch logic:
- If `devices/common/xeutoolbox.zip` exists AND `base_android_version < 15` AND `portIsColorOSGlobal != true`:
  - Append to sepolicy/file_contexts, then unzip (routes xeu_toolbox through `toolbox_exec`)
- Otherwise, if `base_android_version < 15` and `portIsColorOS != true`:
  - Decompile `OppoGallery2.apk`
  - `patchmethod_v2.py -d tmp/Gallery -k 'const-string.*"ro.product.first_api_level"' -hook 'const/16 reg, 0x22'`
    - Spoofs first_api_level to 0x22 (34) to enable AI Editor

### 6.13 Battery.apk (Battery State of Health)
Condition: `base_device_family` is `OPSM8250` or `OPSM8350`

Process:
- Decompile `Battery.apk`, replace `getUIsohValue`'s body with the smali from `devices/common/patch_battery_soh.txt`
  - Reads from `/sys/class/oplus_chg/battery/battery_soh`

### 6.14 Settings.apk (Charging Info Display)
Condition: `regionmark != CN` and `base_product_model != "IN20*"` (note: wildcard comparison in implementation is actually a string comparison — be aware)

Process:
- Patch `isPreferenceSupport` in `DeviceChargeInfoController.smali` to return `true`

### 6.15 OplusLauncher.apk (RAM Usage Display Unlock)
Condition: `OplusLauncher.apk` exists and `base_product_first_api_level > 34`

Process:
- Replace `SystemPropertiesHelper.getFirstApiLevel`'s body with `return 0x22`, aligning first_api_level to 34

### 6.16 SystemUI.apk (Panoramic AOD / MyDevice / Charge Color)
Cache: If `build/<app_patch_folder>/patched/SystemUI.apk` exists, copy and skip.

Otherwise:
1. Decompile → `tmp/SystemUI`
2. In `SmoothTransitionController.smali`: stub/patch `setPanoramicStatusForApplication` and `setPanoramicSupportAllDayForApplication` to return `true`
3. Patch `AODDisplayUtil.isPanoramicProcessTypeNotSupportAllDay` to return `false`
4. If `base_product_first_api_level > 34`: patch `StatusBarFeatureOption.isChargeVoocSpecialColorShow` to `true`
5. If `regionmark != CN`: patch `FeatureOption.isSupportMyDevice` to `true`
6. Replace `style/null` with `7f1403f6` in all `styles.xml` files (temporary resource reference fix)
7. Rebuild and copy back

### 6.17 Aod.apk (Force Always-On AOD on Older Devices)
Condition: `Aod.apk` exists and `base_product_first_api_level <= 35`

Process:
- Patch `CommonUtils.isSupportFullAod` to return `true`
- Patch `SettingsUtils.getKeyAodAllDaySupportSettings` to return `true`

### 6.18 Debloat (del-app Removal, App Deletion, Via Browser)
Heavily branched. Key steps:
- Scan `build/portrom/images/**/del-app/*` directories; delete anything not in `kept_apps`
- Delete directories matching names in the `debloat_apps` array
- `debloat_apps` changes significantly based on device model (KB2000/LE2101, etc.) and `is_ab_device`
- Copy `devices/common/via` to `product/app/` (browser replacement)

### 6.19 build.prop "Base Swap" and Full Replacement
This script doesn't just edit build.prop — it has a diff-management system.

**1) `prepare_base_prop` (functions.sh)**
- Backs up portrom's build.prop, copies baserom's build.prop over as the "foundation"
- Creates `my_product/etc/bruce/build.prop` for diff props, adds an import line to build.prop

**2) `add_prop_from_port` (functions.sh)**
- Extracts props from the old portrom build.prop backup that don't exist in baserom, appends to bruce/build.prop
- Force-overwrites certain props like `ro.build.version.oplusrom*`

**3) For all `find build/portrom/images -name build.prop`:**
- Set timezone to `Asia/Shanghai`
- Replace `port_device_code` with `base_device_code`
- Replace model/name/device with base ROM values
- Replace `ro.build.user` with `build_user`
- Set region lock flags to `false`
- If Global ColorOS: replace lines ending with `=OnePlus` to `=OPPO` (crude but matches implementation)

**4) Example additions to bruce/build.prop:**
- `persist.adb.notify=0`
- `persist.sys.usb.config=mtp,adb`
- `persist.sys.disable_rescue=true`

### 6.20 Dolby + Volume Handling
Condition: `ro.oplus.audio.effect.type` in baserom's `my_product/build.prop` equals `dolby`

Process:
- Copy Dolby permission XML from base
- Unzip `devices/common/dolby_fix.zip` (AudioEffectCenter.apk + dolby XML)
- Copy audio-related XMLs broadly from base (intended to fix WeChat/WhatsApp volume issues)

### 6.21 Feature XML Mass Add/Remove
Uses `add_feature_v2` (functions.sh) to append `<feature>` entries to multiple XML files.

Categories:
- `oplus_features=(...)` → `add_feature_v2 oplus_feature ...`
- `app_features=(...)` → `add_feature_v2 app_feature ...`
- `permission_feature` / `permission_oplus_feature` entries also added

Other:
- Wireless charging added/removed per device model
- Call recording restriction: `xmlstarlet` deletes the app_feature node

### 6.22 AI Memory / aisubsystem / GT Mode
- Unzip `ai_memory*.zip` depending on realme/region
- Append `<enable>` for `com.oplus.aimemory` etc. in `app_v2.xml`
- If `devices/common/GTMode/overlay` exists, copy overlay and add features

### 6.23 Bypass Charging / Voice Isolation / Alert Slider
- Insert `com.oplus.plc_charge.support` into `com.oplus.app-features-ext-bruce.xml`
- Add voice isolation permission feature
- Check for alert slider feature and add if applicable

### 6.24 Unwanted Feature Removal (Large List)
Examples removed with `remove_feature`:
- Curved display, palmprint, vibration-related, foldable-related, eSIM-related features, etc.

eSIM removal also checks for the physical `EuiccGoogle` directory — if found, deletes the directory and removes the feature.

### 6.25 Camera (Prioritize Baserom Camera Assets)
Two main routes:
- If `base_android_version < 33`: port old camera assets like `OnePlusCamera.apk` from baserom (device-dependent)
- Otherwise: overwrite `OplusCamera` directory with baserom's version; copy camera jar files from baserom's `product_overlay/framework`

Additional patches:
- On SoC 8250: delete `sys_camera_optimize_config.xml` (prevents QR scanner crash)

For specific devices (OnePlus9/9Pro/OP4E5D/OP4E3F): apply camera 5.0 fix ZIP based on ROM brand and Android version:
- `camera5.0-fix_cos.zip` / `camera5.0-fix_cos_global.zip` / `camera5.0-fix_oos.zip`
- `camera5.0-fix_odm.zip`
- For older versions: `live_photo_adds.zip` (live photo support)

### 6.26 Voice Trigger (OnePlus 8T)
Condition: `base_product_device == OnePlus8T`

Process:
- Add voice wakeup feature
- Unzip `devices/common/voice_trigger_fix.zip`

### 6.27 Non-ASCII Removal from file_contexts
Purpose: `mkfs.erofs` can fail when file_contexts contains non-ASCII characters.

Process:
- `find build/portrom/images/config -name "*file_contexts" -exec perl -i -ne 'print if /^[\x00-\x7F]+$/' {}`

### 6.28 Boot Animation / Quickboot / Wallpaper / Overlay
- Copy boot animation from baserom based on OS type combination (OOS/ColorOS CN/Global)
- Copy quickboot from baserom by default
- Unzip `wallpaper.zip` if conditions match
- Copy `devices/common/overlay/*` and `devices/<device>/overlay/*` if they exist

### 6.29 AON Service / realme Gesture / Brightness
- Unzip `aon_fix_sm8250.zip` or `aon_fix_sm8350.zip` based on SoC (if present)
- realme gesture: unzip `realme_gesture.zip`, patch `ro.camera.privileged.3rdpartyApp` to append `com.aiunit.aon;com.oplus.gesture;`
- Append brightness-related props to bruce/build.prop; branches per device (e.g., OnePlus8Pro) to remove certain props

### 6.30 WeChat Live Photos / atfwd Policy / Torch
- Edit `Multimedia_Daemon_List.xml` with `xmlstarlet` to set wechat-livephoto attribute to `all`
- If `atfwd@2.0.policy` exists, append `getid/gettid/setpriority: 1`
- Append torch intensity settings to camera config for specific devices

### 6.31 Android 16 Port + base<15 — Additional Fixes
Condition: `port_android_version == 16` and `base_android_version < 15`

Examples:
- Delete `system_ext/priv-app/com.qualcomm.location`
- NFC: unzip `nfc_fix_a16_v2.zip` (first deletes existing NfcNci)
- Wi-Fi: if CN region, unzip `wifi_fix_a16.zip` and delete Google wifi apex
- If OOS 16.0.1: unzip `oos_1601_fix.zip`
- Find X3 Pro: delete brightness-related props/files

---

## 7. Custom Kernel Integration (AnyKernel ZIP) and init_boot KernelSU

### 7.1 AnyKernel Detection and boot.img Generation
Process:
1. Scan `devices/<device>/` for `*.zip` files
2. Use `unzip -l` to find ZIPs containing `anykernel.sh`
3. Extract to different directories based on ZIP name:
   - `*-KSU*` → `tmp/anykernel-ksu/`
   - `*-NoKSU*` → `tmp/anykernel-noksu/`
   - Other → `tmp/anykernel/`
4. For each extracted directory, pull out `Image` (kernel), `dtb`, and `dtbo.img`, then call `patch_kernel` from `functions.sh` to generate `boot_ksu.img` / `boot_noksu.img` / `boot_custom.img`
5. Copy `dtbo.img` to `devices/<device>/dtbo_*.img` for later use during packaging

### 7.2 KernelSU init_boot Patching with ksud
1. Find `ro.build.kernel.id` in `build/portrom/images/**/build.prop`
2. Determine KMI based on `kernel_major` (e.g., 6.1/6.6/6.12):
   - 6.1 → `android14-6.1`
   - 6.6 → `android15-6.6`
   - 6.12 → `android16-6.12`
3. If KMI is determined:
   - Copy `build/baserom/images/init_boot.img` to `tmp/init_boot/`
   - Run `ksud boot-patch -b init_boot.img --magiskboot magiskboot --kmi <kmi>`
   - Copy output `kernelsu_*.img` to `build/baserom/images/init_boot-kernelsu.img`

---

## 8. AVB / Data Encryption

### 8.1 AVB Disable
- `disable_avb_verify build/portrom/images/` (functions.sh)
  - Strips `,avb...` / `avb_keys...` etc. from fstab files.

### 8.2 Data Encryption Removal (If Enabled in Config)
Condition: `remove_data_encryption=true` in `bin/port_config`

Process:
- For all `fstab.*` files under `find build/portrom/images`:
  - Delete `fileencryption=...` and `metadata_encryption=...`
  - Replace `fileencryption` with `encryptable`

---

## 9. Repacking (fs_config / file_contexts Generation → mkfs.erofs)

Prerequisites:
- All partitions must already be extracted as directories under `build/portrom/images/<part>/`.

### 9.1 Super Size Determination
- If `super_extended=true`: call `getSuperSize.sh others`
- Certain models have exceptions (KB2000/LE2101, etc.)
- Otherwise: call `getSuperSize.sh $base_product_device`

### 9.2 fs_config / file_contexts Generation Per Partition
For each `pname` in `$super_list` where the directory exists:
1. `python3 bin/fspatch.py build/portrom/images/$pname build/portrom/images/config/${pname}_fs_config`
2. `python3 bin/contextpatch.py build/portrom/images/$pname build/portrom/images/config/${pname}_file_contexts`

### 9.3 Repacking with mkfs.erofs
Currently hardcoded to:
```bash
mkfs.erofs -zlz4hc,9 --mount-point ${pname} \
  --fs-config-file build/portrom/images/config/${pname}_fs_config \
  --file-contexts build/portrom/images/config/${pname}_file_contexts \
  -T 1648635685 \
  build/portrom/images/${pname}.img build/portrom/images/${pname}
```

**Note: Even if `pack_type=EXT`, this still runs as EROFS — there is no EXT4 path in the implementation.**

---

## 10. vbmeta Patching

Find all `vbmeta*.img` files under `build/baserom/` and run `bin/patch-vbmeta.py` on each to disable verity/verification.

---

## 11. Additional Images (Overrides from `devices/<device>`)

Copy these if they exist:
- `devices/<device>/recovery.img` → `build/baserom/images/`
- `devices/<device>/vendor_boot.img` → `build/baserom/images/`
- `devices/<device>/abl.img` → `build/portrom/images/`
- `devices/<device>/odm.img` → `build/portrom/images/`
- `devices/<device>/tz.img` → `build/baserom/images/`
- `devices/<device>/keymaster.img` → `build/baserom/images/`

For A/B devices:
- If `my_preload.img`/`my_company.img` are missing, supplement with empty images from `devices/common/*_empty.img`

For A-only devices:
- Delete `my_preload.img` and `my_company.img`

---

## 12. Output Generation (pack_method Branch)

### 12.1 `pack_method=stock` (ota_from_target_files Route)
1. Recreate `out/target/product/<device>/`
2. Create `IMAGES/`, `META/`, `SYSTEM/PRODUCT/SYSTEM_EXT/VENDOR/ODM/`
3. Move `build/portrom/images/*.img` to `IMAGES/`
4. If baserom has `firmware-update/`:
   - Copy `boot.img` to `IMAGES/`
   Otherwise:
   - Move `build/baserom/images/*.img` to `IMAGES/`
5. If `devices/<device>/boot_ksu.img` exists:
   - Replace `IMAGES/boot.img` and `IMAGES/dtbo.img` with it
   Otherwise: run `spoof_bootimg` to append `unlocked` to boot cmdline
6. Create `META/ab_partitions.txt`:
   - List basenames of all `IMAGES/*.img` files; for partitions in `super_list`, also generate `.map` files with `map_file_generator`
7. Create `META/dynamic_partitions_info.txt`, `META/misc_info.txt`, `META/update_engine_config.txt`
   - Contents vary between A/B and non-A/B (`virtual_ab=true` etc.)
8. For A-only devices:
   - Copy `OTA/bin/updater`, `releasetools.py`, `recovery.fstab` from devices directory (falls back to common)
   - Collect firmware-update and storage-fw from baserom
9. Copy `build.prop` files to each directory via `prop_paths`
10. Run `otatools/bin/ota_from_target_files` to generate the full OTA ZIP
11. Compute md5, rename to final filename

### 12.2 `pack_method!=stock` (Fastboot ZIP Route)
Uses all the `.img` files built so far, packs them into super with `lpmake`, and generates flash scripts.

Overview:
1. Build `lpmake` arguments (differ between A/B and A-only)
2. Generate `build/portrom/images/super.img`
3. Compress to `build/portrom/super.zst` with `zstd`
4. Populate `out/<OS>_<rom_version>/` with:
   - `super.zst`
   - `firmware-update/*.img`
   - `META-INF/com/google/android/update-binary`
   - `windows_flash_script.bat` / `mac_linux_flash_script.sh`
   - Windows platform-tools (adb/fastboot etc.)
   - Use `sed` to substitute `device_code`/`REGIONMARK`/boot names in scripts
5. Run `unix2dos` on Windows batch files for proper line endings
6. Run `patch-vbmeta.py` on output `vbmeta*.img` files
7. Conditionally include/replace KSU/NoKSU/Custom boot and dtbo images
8. `zip -r` everything, compute md5, rename to final filename

---

## 13. How to Navigate the Code (Recommended Approach)

1. Use `blue "..."` log messages in `port.sh` as **phase boundaries** to understand which block is running.
2. For each phase, check what files it actually touches:
   - APK/JAR: smali is generated under `tmp/<name>/` — you can diff changes there
   - ZIPs: check the relevant files under `devices/common` and `devices/<device>`
   - Features: diff `build/portrom/images/my_product/etc/extension/*.xml` and `.../permissions/*.xml`
3. If `build/<version_name>/patched/` exists, subsequent runs copy from there instead of reprocessing. This is often why smali isn't regenerated on a second run — be aware.

---

## 14. Common Pitfalls

- **`pack_type=EXT` doesn't fully work**
  `mkfs.erofs` is called unconditionally — there is no code path that actually produces EXT4.

- **`jq` is required but not checked by `check`**
  The AIUnit patch will fail silently or error out if `jq` is not installed.

- **framework.jar patching depends on `git`**
  If `git` is missing, the patch file is missing, or `git apply` fails, this step is skipped or errors out.

- **`BASE_PROP`/`PORT_PROP` are hardcoded absolute paths**
  If your working directory isn't `/home/bruce/coloros_port`, the my_manifest sync block will break. Update these to use `$work_dir`.

- **Non-ASCII characters in file_contexts are intentionally stripped**
  This may not be SELinux-perfect, but it's the pragmatic solution to keep `mkfs.erofs` from failing.