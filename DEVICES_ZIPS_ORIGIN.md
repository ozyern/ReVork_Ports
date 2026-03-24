# 📦 devices/ ZIP Files — Origin Estimation and Justification

This document organizes the `devices/**/*.zip` files by "where they came from (extracted vs. handcrafted)" and "why they were deemed necessary", traceable as far as the repository itself allows.

**Bottom line:**
- ✅ **"What each ZIP is used for"** can be traced with high confidence from the conditional branches in `port.sh` (when and where it gets unzipped) and the ZIP contents (which partition files get replaced).
- ⚠️ **"Which specific device/build it was extracted from"** cannot always be determined from the repository alone — many ZIPs don't contain a build fingerprint (`ro.build.fingerprint` etc.), so those are **estimates only**.

---

## 🔍 1. Evidence Used (What's Visible From This Repo)

### A. Where `port.sh` Applies Each ZIP
`devices/*.zip` files are generally extracted with `unzip -o ... -d build/portrom/images/`, **overwriting** files in the already-extracted partition directories.
So if a ZIP entry is under `vendor/...` it lands in vendor, and `odm/...` lands in ODM.

### B. ZIP Contents (What's Inside)
The contents reveal:
- `*.apk / *.jar / *.so / *.odex / *.vdex / *.art / firmware` present
  → Almost certainly **extracted from a real device ROM** (system/vendor/odm etc.) — generating these from scratch isn't realistic
- Only `*.xml / *.rc / *.conf / fstab`
  → Could be an edited version of an extracted file, but this alone isn't conclusive

### C. `git log` (When Added and Commit Messages)
The commit that added each ZIP is a useful clue as to **why it was needed** (e.g. "AOD fix", "FaceUnlock fix").

---

## 📋 2. How to Definitively Identify the Source ROM

For ZIPs that can't be confirmed from the repo alone, the reliable approach is to obtain a suspected ROM (OTA/fastboot), extract it, and **compare file hashes** against the ZIP entries.

1. Extract the ROM the same way `port.sh` would, so `system/ vendor/ odm/ my_product/ ...` are visible
2. Extract the ZIP to a temp folder
3. Compare `sha256` hashes for matching paths:
   - ✅ Exact match → very likely from that ROM (or the same build lineage)
   - ⚠️ Close but not matching → possibly based on a nearby build with modifications

---

## 📝 3. Per-ZIP Summary (With Confidence Ratings)

Legend:
- 🎯 **Purpose**: what `port.sh` intends to fix by using this ZIP
- ⏱️ **Applied when**: the condition under which `port.sh` unzips it
- 📦 **Contents**: key entries in the ZIP
- 🔗 **Origin**: extracted / handcrafted estimate (with confidence)
- 💡 **Justification**: what can be inferred from commit messages, branches, and contents

---

### `devices/common/a13_base_fix.zip` 🔧
- ✏️ Added: `ca0aee6` (2025-05-06) `Update: Initial support for bringing ColorOS 14 to OnePlus 8/8Pro`
- **🎯 Purpose**: Bridges ODM/VINTF/SELinux/service differences when porting an A14 ROM onto an A13 base device
- **⏱️ Applied when**: `base_android_version==13` and `port_android_version==14`, if the file exists
- **📦 Contents**:
  - `odm/etc/init/vendor.oplus.hardware.*.rc`
  - `odm/etc/vintf/manifest/*.xml`
  - `odm/framework/vendor.oplus.hardware.charger-*.jar`
  - `vendor/etc/selinux/vendor_sepolicy.cil` / `vendor_file_contexts`
- **🔗 Origin**: Extracted (high confidence) — contains HAL, SELinux, VINTF, and JAR files
- **💡 Justification**: A13→A14 mismatches in VINTF/SELinux/HAL frequently cause service startup failures and `vintf` errors at boot; this ZIP brings in a known-working set of definitions to resolve them

---

### `devices/common/aod_fix_sm8350.zip` 📲
- ✏️ Added: `47a4e13` (2025-05-12) `Update: SM8350: Fix AOD issue`
- **🎯 Purpose**: Works around AOD display issues (brightness etc.) on SM8350 devices
- **⏱️ Applied when**: **Not currently referenced in `port.sh`** — not automatically applied
- **📦 Contents**:
  - `vendor/bin/hw/vendor.qti.hardware.display.composer-service` only
- **🔗 Origin**: Extracted (high confidence) — vendor executable binary
- **💡 Justification**: Commit message explicitly states "AOD issue"; the fix works by replacing `display.composer-service`

---

### `devices/common/charger-v6-update.zip` 🔋
- ✏️ Added: `05caf0a` (2025-05-12) `Hello ColorOS 15/OxygenOS 15`
- **🎯 Purpose**: Updates Charger HAL from V3 to V6 to match COS15/OOS15 expectations
- **⏱️ Applied when**: `port_android_version>=15` and `base_android_version==14`, and `vendor.oplus.hardware.charger-V3-service` exists (around `port.sh:779`)
- **📦 Contents**:
  - `odm/etc/init/vendor.oplus.hardware.charger-V6-service.rc`
  - `odm/etc/vintf/manifest/manifest_oplus_charger_aidl.xml`
  - `odm/lib64/vendor.oplus.hardware.charger-V6-ndk_platform.so`
- **🔗 Origin**: Extracted (high confidence)
- **💡 Justification**: The trigger is detecting a V3 service binary — the design assumes "leaving the old charger implementation in place causes issues"

---

### `devices/common/cryptoeng_fix_a13.zip` 🔐
- ✏️ Added: `70c560e` (2025-12-10) `Hello ColorOS 16/OxygenOS 16`
- **🎯 Purpose**: Replaces CryptoEng/URCC HAL files (intended to restore privacy/app lock functionality)
- **⏱️ Applied when**: `port_android_version>=15` and `base_android_version==13` branch, if the file exists (around `port.sh:823`)
- **📦 Contents**:
  - `odm/lib64/vendor.oplus.hardware.urcc-V1-ndk_platform.so` and similar
- **🔗 Origin**: Extracted (high confidence)
- **💡 Justification**: Missing or incompatible HAL dependencies silently kill features; this ZIP bundles the ODM NDK `.so` files needed to restore them

---

### `devices/common/dolby_fix.zip` 🎵
- ✏️ Added: `d020fe7` (2025-05-12) `Update: Add support for SM8350 devices (OnePlus 9 Series, Find X3 Pro)`
- **🎯 Purpose**: Restores Dolby audio support (AudioEffectCenter APK + Dolby XML config)
- **⏱️ Applied when**: Dolby branch conditions are met, if the file exists (around `port.sh:1244`)
- **📦 Contents**:
  - `my_product/app/AudioEffectCenter/AudioEffectCenter.apk`
  - `odm/etc/dolby/multimedia_dolby_dax_default.xml`
- **🔗 Origin**: Extracted (high confidence)
- **💡 Justification**: Dolby assets are typically present in the source ROM but missing or broken on the base device — injecting the APK and config together restores functionality

---

### `devices/common/face_unlock_fix_common.zip` 👤
- ✏️ Added: `6703287` (2024-06-11) `Initial support for porting latest ColorOS 14 to OnePlus8T`
- ✏️ Last updated: `05caf0a` (2025-05-12) `Hello ColorOS 15/OxygenOS 15`
- **🎯 Purpose**: Provides shared Face Unlock dependencies (model data + TrustZone access + overlays)
- **⏱️ Applied when**: SM8250 or SM8350 FaceUnlock fix branch, if the file exists (around `port.sh:716`)
- **📦 Contents**:
  - `vendor/app/TrustZoneAccessService/TrustZoneAccessService.apk`
  - `vendor/etc/eva/**` (face detection/landmark models)
  - `vendor/overlay/*.apk` (Wi-Fi, SecureElement, FrameworksRes, etc.)
- **🔗 Origin**: Extracted (high confidence)
- **💡 Justification**: Face Unlock requires model files, TrustZone access, and overlays all in place — any missing piece breaks the entire feature

---

### `devices/common/hdr_fix.zip` 🌈
- ✏️ Added: `70c560e` (2025-12-10) `Hello ColorOS 16/OxygenOS 16`
- **🎯 Purpose**: Adjusts HDR display configuration (`multimedia_display_feature_config.xml`)
- **⏱️ Applied when**: `base_android_version<=14`, if the file exists (around `port.sh:1967`)
- **📦 Contents**:
  - `my_product/vendor/etc/multimedia_display_feature_config.xml` only
- **🔗 Origin**: Extracted or extracted + edited (medium confidence) — a single XML; while it could be handcrafted, the content is heavily vendor-implementation-specific
- **💡 Justification**: HDR/display behavior can change with a single XML difference; this overwrites with a known-good configuration

---

### `devices/common/nfc_fix_a16_v2.zip` 📡
- ✏️ Added: `70c560e` (2025-12-10) `Hello ColorOS 16/OxygenOS 16`
- **🎯 Purpose**: Restores NFC for Android 16 (NfcNci APK + config)
- **⏱️ Applied when**: `port_android_version==16` and `base_android_version<15`, replaces NfcNci if the file exists (around `port.sh:1940`)
- **📦 Contents**:
  - `system/system/priv-app/NfcNci/NfcNci.apk`
  - `system/system/etc/libnfc-nci.conf`
- **🔗 Origin**: Extracted (high confidence)
- **💡 Justification**: NFC on A16 requires the APK and config to be in sync; mismatches with an older base cause compatibility failures, so both are replaced together

---

### `devices/common/ril_fix_a13_to_a15.zip` 📞
- **🎯 Purpose**: Restores full RIL/modem communication stack
- **📦 Contents**: commcenterd, subsys_daemon, radio firmware, telephony HAL
- **🔗 Origin**: Extracted (high confidence)

---
- Added: `6703287` (2024-06-11) `Initial support for porting latest ColorOS 14 to OnePlus8T`
- Last updated: `05caf0a` (2025-05-12) `Hello ColorOS 15/OxygenOS 15`
- **Purpose**: Fixes mobile network/RIL stack issues when running A15+ on an A13 base (commcenter, subsys, radio, etc.)
- **Applied when**: `port_android_version>=15` and `base_android_version==13`, applied unconditionally (around `port.sh:787`)
- **Contents**:
  - `odm/etc/fstab.at.qcom` (includes `my_*` mount points)
  - `odm/etc/init/commcenterd.rc`, `subsys_daemon.rc`, etc.
  - `odm/lib64/libqti-radio-service.so`, `libsubsys-*`, and many more
  - `odm/etc/selinux/precompiled_sepolicy*`
- **Origin**: Extracted (high confidence)
- **Justification**: Mobile connectivity requires HAL, daemons, SELinux, and manifests all to be consistent — this ZIP bundles the complete set, designed on the premise that "without this, it won't work"

---

### `devices/common/ril_fix_sm8250.zip`
- Added: `6703287` (2024-06-11) `Initial support for porting latest ColorOS 14 to OnePlus8T`
- Last updated: `70c560e` (2025-12-10) `Hello ColorOS 16/OxygenOS 16`
- **Purpose**: Replaces the RIL/communication stack for SM8250 (OnePlus 8 series)
- **Applied when**: `port_android_version>=15` and `base_device_family==OPSM8250` and `base_android_version!=13` (around `port.sh:762`)
- **Contents**: Communication-related `.so` files and manifests under `odm/` and `vendor/`
- **Origin**: Extracted (high confidence)
- **Justification**: RIL issues are common across SoC/generation gaps; separate ZIPs per device family allow targeted replacement

---

### `devices/common/ril_fix_sm8350.zip`
- Added: `6703287` (2024-06-11) `Initial support for porting latest ColorOS 14 to OnePlus8T`
- Last updated: `d020fe7` (2025-05-12) `Update: Add support for SM8350 devices (OnePlus 9 Series, Find X3 Pro)`
- **Purpose**: Replaces the RIL/communication stack for SM8350 (OnePlus 9 series)
- **Applied when**: `port_android_version>=15` and `base_device_family==OPSM8350` (around `port.sh:762`)
- **Contents**:
  - `odm/etc/vintf/*telephony_manifest*`
  - `vendor/lib64/libqcrilNr.so`, etc.
- **Origin**: Extracted (high confidence)
- **Justification**: Commit message specifically mentions "SM8350 support"; per-SoC design injects the required libraries

---

### `devices/common/voice_trigger_fix.zip`
- Added: `6703287` (2024-06-11) `Initial support for porting latest ColorOS 14 to OnePlus8T`
- Last updated: `05caf0a` (2025-05-12) `Hello ColorOS 15/OxygenOS 15`
- **Purpose**: Restores voice wakeup on OnePlus 8T (OVoiceManagerService + sound trigger config)
- **Applied when**: `base_product_device==OnePlus8T` (around `port.sh:1705`)
- **Contents**:
  - `my_product/priv-app/OVoiceManagerService/OVoiceManagerService.apk`
  - `odm/etc/sound_trigger_*.xml`
- **Origin**: Extracted (high confidence)
- **Justification**: Device-specific branch = confirmed to be missing or broken on that specific device; introduced as a targeted fix

---

### `devices/common/wifi_fix_a16.zip`
- Added: `70c560e` (2025-12-10) `Hello ColorOS 16/OxygenOS 16`
- **Purpose**: Replaces the Wi-Fi APEX for Android 16
- **Applied when**: `port_android_version==16` and `base_android_version<15` and `regionmark==CN` (around `port.sh:1944`)
- **Contents**:
  - `system/system/apex/com.android.wifi.apex`
  - `system/system/apex/com.google.android.wifi_compressed.apex` (very small — likely a dummy/disabler)
- **Origin**: Extracted or extracted + repackaged (medium confidence)
- **Justification**: The script deletes `com.google.android.wifi*.apex` after applying this ZIP — designed to resolve APEX conflicts or mismatches specific to the CN region

---

### `devices/OnePlus9/face_unlock_fix.zip`
- Added: `6703287` (2024-06-11) `Initial support for porting latest ColorOS 14 to OnePlus8T`
- Last updated: `795e3e3` (2025-05-12) `Update: SM8350: Fix face_unlock issue on OOS15`
- **Purpose**: Provides FaceUnlock HAL, libraries, and firmware for OnePlus 9
- **Applied when**: SM8250 or SM8350 FaceUnlock fix branch, when the old face unlock APK (`$old_face_unlock_app`) exists on the base ROM, applies `devices/${base_product_device}/face_unlock_fix.zip` (around `port.sh:715`)
- **Contents**:
  - `odm/bin/hw/vendor.oplus.hardware.biometrics.face@1.0-service`
  - `odm/lib64/libstfaceunlockocl.so` (large)
  - `odm/vendor/firmware/facereg.*`
- **Origin**: Extracted (high confidence)
- **Justification**: Commit message says "Fix face_unlock issue on OOS15" — replacing these packages resolves a compatibility break introduced in the OOS15 generation

---

### `devices/OnePlus9Pro/face_unlock_fix.zip`
- Added/Last updated: Same lineage as `devices/OnePlus9/face_unlock_fix.zip`
- **Purpose / Applied when / Origin**: Same rationale as the OnePlus9 version — the target differs based on `base_product_device`

---

### `devices/OnePlus9Pro/camera5.0-fix_oos.zip`
- Added: `d8ebfa6` (2025-05-06) `Update: Initial support for packing ROM with AB OTA package (payload.bin format)`
- Last updated: `9500b97` (2025-12-22) `Update some files thanks to bruce`
- **Purpose**: Restores Camera 5.0 on OOS15 (OplusCamera APK + unit SDK + oat/vdex/odex)
- **Applied when**: `portIsOOS==true`, if the file exists (around `port.sh:1898`)
- **Contents**:
  - `my_product/app/OplusCamera/OplusCamera.apk` (very large)
  - `my_product/app/OplusCamera/oat/arm64/*.art`, `*.odex`, `*.vdex`
  - `my_product/product_overlay/framework/com.oplus.camera.unit.sdk*.jar` + `oat/arm64/*.odex`, `*.vdex`
- **Origin**: Extracted (high confidence)
- **Justification**: Including `oat/vdex/odex` means it was taken directly from `my_product` on a real device. The intent is to replace a non-functioning camera on the ported ROM with a known-working bundle

---

### `devices/OnePlus9Pro/camera5.0-fix_cos_global.zip`
- Added/Last updated: Same lineage as `camera5.0-fix_oos.zip`
- **Purpose**: Restores Camera 5.0 for ColorOS Global 15
- **Applied when**: `portIsColorOSGlobal==true`, if the file exists (around `port.sh:1888`)
- **Contents**:
  - `my_product/app/OplusCamera/OplusCamera.apk`
  - `my_product/lib64/libMsEffectSdk.so` (differs from OOS version)
  - `my_product/product_overlay/framework/com.oplus.camera.unit.sdk*.jar`, etc.
- **Origin**: Extracted (high confidence)
- **Justification**: The Global branch exists because camera package compatibility differs between ROM families — a separate set is prepared for each

---

### `devices/OnePlus9Pro/camera5.0-fix_odm.zip`
- Added/Last updated: Same lineage as `camera5.0-fix_oos.zip`
- **Purpose**: Injects ODM-side Camera 5.0 dependencies (config, models, libs, RC files)
- **Applied when**: Applied alongside the camera fix ZIPs above (around `port.sh:1880/1895/1905`)
- **Contents**:
  - `odm/etc/camera/**` (live photo models, etc.)
  - `odm/etc/init/init.camera_process.rc`
  - `odm/lib*/*.so` (algorithm, Meishe, filter libraries, etc.)
- **Origin**: Extracted (high confidence)
- **Justification**: Camera depends not just on the APK in `my_product` but also on ODM-side configs, libs, and RC files — this ZIP fills in the lower-level dependencies that the camera stack requires