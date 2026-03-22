# ColorOS Port Repository Overview

This repository contains a set of scripts and associated resources for porting and repacking ColorOS/OxygenOS/realme UI OTA/fastboot packages onto OnePlus/Oppo devices. The following is a comprehensive breakdown of the role and interactions of each file and folder.

## Entry Points

### `setup.sh`
A setup script that installs dependencies via `apt` (Linux) or `brew` (macOS). Installs `aria2`, `python3`, `busybox`, `zip`, `unzip`, `p7zip`, `openjdk`, `zstd`, `xmlstarlet`, and the other tools that `port.sh` requires.

### `port.sh`
The main porting script. Arguments: `<baserom> <portrom> [portrom2] [portparts]`. URLs are accepted and downloaded with `aria2c`.

Simplified processing flow:
1. Reads `bin/port_config` to determine target partitions and ext4/EROFS repack strategy.
2. Extracts BASEROM/PORTROM from `payload.bin` / `*.img` (using `payload-dumper`, `brotli+sdat2img`, or `unzip`). Supports mixed porting if a second source ROM is specified.
3. Extracts partitions under `build/baserom` / `build/portrom` (ext4 → `bin/imgextractor`; EROFS → `extract.erofs`). Some partitions like vendor/odm are taken from the base ROM.
4. Reads Android/SDK/device code/region info from `my_manifest` / `build.prop` files and overwrites them with base device values. Handles 32-bit zygote → 64-bit-only conversion and brand detection (ColorOS / OxygenOS / realme UI) as needed.
5. Applies a large number of individual patches using helpers from `functions.sh` and `bin/patchmethod*.py`. Examples: face unlock, AI Call, OTA dm-verity bypass, Gallery AI Editor, battery SOH, game volume, Dolby, AOD, SystemUI smali rewrites, feature flag XML add/remove, build property adjustments. ZIPs and overlays from `devices/common` and `devices/<device>` are applied here.
6. Optionally removes the data encryption flag (when `remove_data_encryption=true`). Runs `disable_avb_verify` to strip AVB verification from fstab.
7. Regenerates `fs_config` / `file_contexts` with `bin/fspatch.py` / `bin/contextpatch.py`, then repacks each partition with `mkfs.erofs` (or `make_ext4fs`). Gets the device-specific super size with `bin/getSuperSize.sh` and builds `super.img` with `lpmake`.
8. Disables vbmeta verification with `bin/patch-vbmeta.py`. Places fastboot scripts (Windows/Mac/Linux) and `META-INF/updater` in `out/<OS>_<version>/` and generates the final ZIP.

### `functions.sh`
Utility library sourced by `port.sh`. Provides colored logging and existence checks, plus:
- `patch_smali` / `baksmali_wrapper` / `smali_wrapper`: APK/JAR smali extraction, substitution, repack + `zipalign` / `apksigner` signing.
- `extract_partition`: Detects ext4/EROFS and extracts using the appropriate tool; discards the source `.img` afterward.
- `disable_avb_verify`: Removes AVB options from fstab. (Note: defined twice with the same name — the second definition takes effect.)
- `patch_kernel` / `patch_kernel_to_bootimg` / `spoof_bootimg`: Uses `magiskboot` to unpack boot/vendor_boot, disable AVB, and inject a custom kernel.
- Feature flag XML add/remove (`add_feature[_v2]` / `remove_feature`), build.prop editing (`add_prop*` / `remove_prop*` / `prepare_base_prop` / `add_prop_from_port`).
- Old-style face unlock fix (`fix_oldfaceunlock`), Smart Sidebar brand spoof (`patch_smartsidecar`), ColorOS version extraction (`get_oplusrom_version`), etc.

---

## Configuration Files

### `bin/port_config`
- `partition_to_port`: List of logical partitions to extract from PORTROM and repack.
- `possible_super_list`: Candidate partitions to include in `super.img`.
- `repack_with_ext4` / `remove_data_encryption` / `super_extended` / `pack_method`: Controls packing format and encryption disable behavior.

### `bin/getSuperSize.sh`
Returns the super partition byte size for a given device code. Used by `port.sh` during packaging.

---

## Tools (`bin/`)

### OS/Architecture Binaries
Bundled under `bin/Linux/{x86_64,aarch64}` and `bin/Darwin/{X86_64,aarch64}`:
`payload-dumper(-go)`, `lpunpack` / `lpmake`, `mkfs.erofs`, `img2simg` / `simg2img`, `magiskboot`, `vbmeta-disable-verification`, `zstd`, `gettype`, etc. All called by `port.sh`.

### APK/JAR Editing
- `bin/apktool/`: `apktool.jar`, `smali` / `baksmali` (standard + 3.0.5 variants), `APKEditor.jar`. Used during smali patching.

### Image Extraction
- `bin/imgextractor/imgextractor.py` + `ext4.py`: Python implementation for extracting Android sparse/ext4 images, including on Windows. Called from `extract_partition`.

### Smali Auto-Patching
- `bin/patchmethod.py`: Replaces a specified method with a `true` / `false` / `void` stub.
- `bin/patchmethod_v2.py`: Enhanced version — supports cross-directory method detection, replacement, and hook insertion.

### SELinux / Permission補完
- `bin/contextpatch.py`: Compares an extracted directory against an existing `*_file_contexts` file and assigns estimated SELinux contexts to any missing paths (using a `fix_permission` table and similar-path inference).
- `bin/fspatch.py`: Fills in missing UID/GID/permissions/symlink targets in `fs_config`.

### AVB / Other Utilities
- `bin/patch-vbmeta.py`: Rewrites vbmeta header flags to disable verity/verification.
- `bin/lpunpack.py`: Parses super image metadata and extracts partitions (text/JSON output supported).
- `bin/flash/`: Contains `update-binary` (META-INF updater), `windows_flash_script.bat` and `mac_linux_flash_script.sh` (fastboot flash templates), and `platform-tools-windows/` (adb/fastboot, etc.).
- `bin/port_config`: Port parameters (described above).

---

## Device-Specific and Common Resources (`devices/`)

For tracing the origin and justification of each `devices/**/*.zip`: see [DEVICES_ZIPS_ORIGIN.md](DEVICES_ZIPS_ORIGIN.md)

### Common ZIPs / Images (`devices/common/`)
- `a13_base_fix.zip`: ODM HAL/services for A13-generation devices (charger, performance, WiFi, power stats, etc.), fastchg firmware, vintf/selinux definitions. Foundational patch for bridging base ROM differences.
- `aod_fix_sm8350.zip`: Contains `vendor.qti.hardware.display.composer-service` to work around AOD brightness issues on SM8350.
- `charger-v6-update.zip`: Updates Charger V6 HAL, RC, JAR, NDK `.so`, and config (`charge.cfg`, etc.).
- `cryptoeng_fix_a13.zip`: Fixes for CryptoEng/URCC HAL (binary + NDK `.so`).
- `dolby_fix.zip`: Adds `AudioEffectCenter.apk` (with vdex) and `multimedia_dolby_dax_default.xml` to restore Dolby functionality.
- `face_unlock_fix_common.zip`: `TrustZoneAccessService.apk`, a full set of face detection/landmark/itof models, and SecureElement/WiFi overlays. Shared Face Unlock dependencies.
- `hdr_fix.zip`: Adjusts HDR display settings via a `multimedia_display_feature_config.xml` overlay.
- `nfc_fix_a16_v2.zip`: `NfcNci.apk` and `libnfc-nci.conf` for Android 16.
- `ril_fix_a13_to_a15.zip`: Full communication stack (commcenterd, subsys_daemon, telephony manifests, radio/commcenter HAL/selinux, fastchg firmware, NFC config, Goodix FP HAL, etc.) and qcril libraries. Fixes RIL issues going from A13 to A15.
- `ril_fix_sm8250.zip`: Communication stack and subsys/radio libs for SM8250.
- `ril_fix_sm8350.zip`: Communication stack for SM8350 (netmgrd, qcrilNr, etc.).
- `voice_trigger_fix.zip`: `OVoiceManagerService.apk` + OVMS models (wakeup/print), ACDB/SoundTrigger config.
- `wifi_fix_a16.zip`: `com.android.wifi.apex` paired with the Google wifi apex.
- Other: Feature flag XML templates (e.g. `oplus.feature.*.xml`), `patch_battery_soh.txt` (smali fragment that reads battery SOH from `/sys`), empty `my_company_empty.img` / `my_preload_empty.img`.

### OnePlus 8 / 8 Pro (`devices/OnePlus8*`)
- `keymaster.img` / `tz.img`: Trusted execution environment images.
- `overlay/vendor/build.prop` + `overlay/vendor/etc/fstab.qcom`: Aligns vendor properties and fstab (with `my_*` mounts and entries supporting both ext4/EROFS) to base device specs.

### OnePlus 8T (`devices/OnePlus8T`)
- `overlay/my_product/.../android_framework_res_overlay.display.product.20806.apk`: Display-related overlay.
- `overlay/system/system/bin/fix_refresh_rate.sh` + `overlay/system_ext/etc/init/frame_drop_fix_service.rc`: An init service that resets the refresh rate from 60Hz → 120Hz after boot completes, preventing frame drops.

### OnePlus 9 (`devices/OnePlus9/face_unlock_fix.zip`)
- Face Unlock HAL (`vendor.oplus.hardware.biometrics.face@1.0-service`), libraries, and firmware.

### OnePlus 9 Pro (`devices/OnePlus9Pro`)
- `camera5.0-fix_oos.zip` / `camera5.0-fix_cos_global.zip`: Places `OplusCamera.apk` (with oat/prof), `com.oplus.camera.unit.sdk` JAR/odex, `libMsEffectSdk.so`, etc. into `my_product` to restore Camera 5.0.
- `camera5.0-fix_odm.zip`: Camera configs/protobufs, Meishe LUT files, live photo models and libraries (`libAlgoInterface/Process`, `libPreviewDecisionOld`, `libmsnativefilter`, etc.), and RC files.
- `face_unlock_fix.zip`: Same face unlock package as OnePlus 9.

### OnePlus 9R / OP4E5D
- `recovery.fstab`: Recovery fstab including A/B and logical partitions.
- `releasetools.py`: Bundles firmware images into the OTA ZIP during the OTA build process; uses `get_xblddr_type` detection to select DDR4/DDR5 flashing logic.
- `OTA/bin/updater`: Custom OTA updater binary.

### Other
- Feature flag template files such as `oplus.feature.android-ext-bruce.xml` are bundled alongside `devices/common`. They are populated by `add_feature` calls as needed.

---

## OTA / Build Tools (`otatools/`)
- `otatools/bin`: Android host tools — `apksigner`, `signapk`, `boot_signer`, `ota_from_target_files`, `merge_target_files`, `mkbootimg`, `img_from_target_files`, etc. Used by `port.sh` for APK signing and target_files manipulation.
- `otatools/framework`: JAR files for signing.
- `otatools/key`: Test keys (`testkey.pk8` / `x509.pem` / `key`).
- `otatools/lib64`: Shared libraries linked by the above tools.

---

## Flash Scripts / Output

### `bin/flash/windows_flash_script.bat` / `bin/flash/mac_linux_flash_script.sh`
Templates that `port.sh` dynamically substitutes with device info, region, and boot image names to produce scripts for fastboot-flashing the generated `super.zst` and firmware images.

### `bin/flash/update-binary`
The updater executed from META-INF. If a device-specific `devices/<device>/update-binary` exists, it takes priority.

### `out/<OS>_<rom_version>*.zip`
The final output of `port.sh`. Contains `super.zst`, individual `.img` files under `firmware-update/`, flash scripts, META-INF, and a `patch-vbmeta.py`-processed vbmeta.

---

## README Files
- `README.md` / `README_en-US.md`: Project overview, supported devices, known issues, and Linux usage instructions. Primary targets are OnePlus 8/9 series based on ColorOS 14.

---

## Development Tips
- **Working directories**: `build/` holds extracted partitions, `tmp/` holds intermediate files, `out/` holds final outputs. If `build/<version_name>/` already exists from a previous run, extraction is skipped and files are reused.
- **Signing**: APKs/JARs modified at the smali or resource level are re-signed with `zipalign` + `apksigner` using `otatools/key/testkey*`.
- **Filesystem**: EROFS by default. Setting ext4 in `bin/port_config` switches to a behavior that favors RW mounts.
- **Custom kernels**: `port.sh` detects AnyKernel-format ZIPs or `boot.img` files, generates `boot_ksu.img` / `boot_noksu.img` / `boot_custom.img`, and includes them in the output.

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