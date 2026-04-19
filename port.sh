#!/bin/bash
# ColorOS_port project
# For A-only and V/A-B Devices
# Based on Android 14+
# Test Base ROM: OnePlus 9 Pro (OxygenOS_14.0.0.1920)
# Test Port ROM: OnePlus 15 (OxygenOS_16.0.3.501), OPPO Find X9 Pro( ColorOS_16.0.5.701) Realme GT Neo5 240W(RMX3708_14.0.0.800)
###############################################################################
# port.sh (ColorOS/OxygenOS/realme UI Porting Script)
###############################################################################
set -euo pipefail

# ── ERR trap: report exact line + command on any set -e failure ─────────
trap 'echo "[ERROR] Script died at line $LINENO — command: $BASH_COMMAND" >&2' ERR


build_user="Ozyern"
build_host=$(hostname)"@ReVork"
baserom="${1:-}"
portrom="${2:-}"
portrom2="${3:-}"
portparts="${4:-}"

if [[ -z "$baserom" || -z "$portrom" ]]; then
    echo "Usage: $0 <baserom> <portrom> [portrom2] [portparts]"
    echo "  baserom   : path or URL to base ROM (OTA/fastboot zip)"
    echo "  portrom   : path or URL to port source ROM"
    echo "  portrom2  : (optional) second port source ROM for mixed port"
    echo "  portparts : (optional) space-separated partition list to pull from portrom2"
    exit 1
fi

work_dir=$(pwd)

# ── Build timer — printed in the final banner ────────────────────────────────
_BUILD_START=${SECONDS}

tools_dir=${work_dir}/bin/$(uname)/$(uname -m)
export PATH="${work_dir}/bin/$(uname)/$(uname -m)/:${work_dir}/otatools/bin/:${PATH}"

# ── chmod +x — make every tool executable before first use ───────────────────
# Fixes "Permission denied" on payload-dumper, brotli, sdat2img, mkfs.erofs, etc.
# Runs once at startup so every call succeeds regardless of how tools arrived
# (git clone, zip extract, rsync, NFS mount — all may strip execute bits).
#
# Scope:
#   bin/<OS>/<arch>/   — payload-dumper, brotli, gettype, mkfs.erofs, lpmake …
#   bin/<OS>/<arch>/   (recursively, for apktool, imgextractor sub-dirs)
#   otatools/bin/      — ota_from_target_files, map_file_generator, sign tools
#   bin/               — getSuperSize.sh, fspatch.py, contextpatch.py, etc.

find "${work_dir}/bin/$(uname)/$(uname -m)/" \
     -type f \
     -exec chmod +x {} + 2>/dev/null || true

find "${work_dir}/otatools/bin/" \
     -maxdepth 2 -type f \
     -exec chmod +x {} + 2>/dev/null || true

find "${work_dir}/bin/" \
     -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) \
     -exec chmod +x {} + 2>/dev/null || true

# Java tools don't need +x but mark any wrapper scripts inside apktool/
find "${work_dir}/bin/apktool/" \
     -maxdepth 2 -type f -name "*.sh" \
     -exec chmod +x {} + 2>/dev/null || true

# source functions.sh FIRST — colour helpers (green/blue/error) are defined there
source functions.sh
check unzip aria2c 7z zip java python3 zstd bc xmlstarlet

green "Tool permissions set (chmod +x)" "All tools marked executable"

# ──────────────────────────────────────────────────────────────────────────────
# GitHub Release auto-download logic (from toraidl/coloros_port)
# ──────────────────────────────────────────────────────────────────────────────

export REPO_OWNER="${REPO_OWNER:-toraidl}"
export REPO_NAME="${REPO_NAME:-coloros_port}"
export RELEASE_TAG="${RELEASE_TAG:-assets}"

check_gh_cli() {
  if ! command -v gh &> /dev/null ; then
    error "GitHub CLI (gh) not found."
    return 1
  fi
  return 0
}

generate_asset_name() {
  local file_path="$1"
  local dir_path=$(dirname "$file_path")
  local filename=$(basename "$file_path")
  local asset_name=""

  if [[ "$dir_path" == *"devices/"* ]]; then
    local prefix=$(echo "$dir_path" | sed 's/.*devices\///' | cut -d '/' -f1)
    asset_name="${prefix}_${filename}"
  elif [[ "$dir_path" == *"assets"* ]]; then
    asset_name="assets_${filename}"
  else
    asset_name="$filename"
  fi

  echo "$asset_name"
}

download_from_release() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    local asset_name
    asset_name=$(generate_asset_name "$file_path")
    local download_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}/${asset_name}"

    blue "Attempting download from GitHub Release: $file_path"
    blue "  Asset: $asset_name"
    blue "  URL:   $download_url"

    mkdir -p "$(dirname "$file_path")"

    # Try GitHub CLI first (handles auth, private repos)
    if check_gh_cli; then
      if gh release download "$RELEASE_TAG" --repo "$REPO_OWNER/$REPO_NAME" --pattern "$asset_name" --dir "$(dirname "$file_path")" 2>/dev/null; then
        local downloaded_file
        downloaded_file=$(find "$(dirname "$file_path")" -name "$asset_name" -type f -print -quit)
        if [[ -f "$downloaded_file" ]]; then
          mv "$downloaded_file" "$file_path"
          if _validate_download "$file_path"; then
            green "Downloaded via gh: $file_path"
            return 0
          else
            yellow "gh download corrupt, trying curl..."
            rm -f "$file_path"
          fi
        fi
      fi
    fi

    # curl fallback — use --fail so HTTP 4xx/5xx = exit 1, not a saved error page
    local tmp_file="${file_path}.$$"
    if curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 15 \
            -o "$tmp_file" "$download_url" 2>/dev/null; then
      if _validate_download "$tmp_file"; then
        mv "$tmp_file" "$file_path"
        green "Downloaded via curl: $file_path"
        return 0
      else
        rm -f "$tmp_file"
        yellow "Downloaded file is corrupt (not a valid zip): $asset_name"
        yellow "Please upload a valid zip to the GitHub Release or place it manually at: $file_path"
        return 1
      fi
    else
      rm -f "$tmp_file"
      yellow "Download failed (HTTP error or network issue): $download_url"
      yellow "Please place the file manually at: $file_path"
      return 1
    fi
  fi
  return 0
}

# _validate_download FILE — returns 0 if file is a valid zip, 1 otherwise
_validate_download() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # Must be non-empty AND pass zip integrity check
  [[ -s "$f" ]] || return 1
  unzip -t "$f" > /dev/null 2>&1
}

ensure_resource_available() {
  local path="$1"

  # If file exists, validate it — a previously-downloaded corrupt file should be re-fetched
  if [[ -f "$path" ]]; then
    if _validate_download "$path"; then
      return 0
    else
      yellow "Cached file is corrupt, re-downloading: $path"
      rm -f "$path"
    fi
  fi

  blue "Resource missing, attempting GitHub download: $path"

  if download_from_release "$path"; then
    green "Resource acquired: $path"
    return 0
  else
    yellow "Could not auto-fetch resource: $path"
    yellow "Please place the file manually at: $path"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Configurable settings via `bin/port_config`
# ──────────────────────────────────────────────────────────────────────────────
read_config() {
    local key="$1" default="${2:-}"
    local val
    val=$({ grep "^${key}=" bin/port_config 2>/dev/null || true; } | cut -d '=' -f 2- | tr -d '[:space:]')
    echo "${val:-$default}"
}

port_partition=$(read_config "partition_to_port" "system,system_ext,product,my_product,my_manifest,my_stock,my_region")
super_list=$(read_config "possible_super_list" "system system_ext vendor product my_product odm my_engineering my_stock my_heytap my_carrier my_region my_bigball my_manifest my_company my_preload")
repackext4=$(read_config "repack_with_ext4" "false")
super_extended=$(read_config "super_extended" "false")
pack_with_dsu=$(read_config "pack_with_dsu" "false")
pack_method=$(read_config "pack_method" "flashable")
ddr_type=$(read_config "ddr_type" "")

if [[ "${repackext4}" == true ]]; then
    pack_type=EXT
else
    pack_type=EROFS
fi

# Determine if input is a local file or URL; download if it is a URL
download_if_url() {
    local var_name="$1"
    local url="${!var_name}"
    local label="$2"

    if [[ ! -f "$url" && "$url" =~ ^https?:// ]]; then
        blue "${label} is a URL. Starting download..." "Download link detected, start downloading.."
        aria2c --async-dns=false --max-download-limit=1024M --file-allocation=none -s10 -x10 -j10 "$url"
        local filename
        filename=$(basename "$url" | sed 's/\?t.*//')
        if [[ ! -f "$filename" ]]; then
            error "Download failed for ${label}" "Download error!"
            exit 1
        fi
        printf -v "$var_name" '%s' "$filename"
    elif [[ -f "$url" ]]; then
        green "${label}: $url" "${label}: $url"
    else
        error "${label} argument is invalid: $url" "${label}: Invalid parameter"
        exit 1
    fi
}

download_if_url baserom "Base ROM"
download_if_url portrom "Port source ROM"
if [[ "$(basename "$baserom")" =~ ColorOS_ ]]; then
    device_code=$(basename "$baserom" | cut -d '_' -f 2)
else
    device_code="op8t"
fi
blue "Validating Base ROM" "Validating BASEROM.."
if unzip -l "${baserom}" | grep -q "payload.bin"; then
    baserom_type="payload"
    oplus_hex_nv_id=$(unzip -p "${baserom}" META-INF/com/android/metadata 2>/dev/null | grep "oplus_hex_nv_id=" | cut -d= -f2)
elif unzip -l "${baserom}" | grep -Eq "br$"; then
    baserom_type="br"
    oplus_hex_nv_id=$(unzip -p "${baserom}" META-INF/com/android/metadata 2>/dev/null | grep "oplus_hex_nv_id=" | cut -d= -f2)
elif unzip -l "${baserom}" | grep -Eq "\.img$"; then
    baserom_type="img"
else
    error "payload.bin / *.br / *.img not found in Base ROM (please retry with official ROM)" \
          "payload.bin / *.br / *.img not found, please use official OTA or fastboot package."
    exit 1
fi
green "Base ROM Format: ${baserom_type}" "Detected base package type: ${baserom_type}"
blue "Validating Port ROM" "Validating PORTROM.."
if unzip -l "${portrom}" | grep -q "payload.bin"; then
    portrom_type="payload"
elif unzip -l "${portrom}" | grep -Eq "\.img$"; then
    portrom_type="img"
else
    error "payload.bin / *.img not found in Port source ROM (please specify an official ROM containing system.img)" \
          "payload.bin or *.img not found, please use an official ROM package containing system.img as PORTROM."
    exit 1
fi
if unzip -l "${portrom}" | grep -q "META-INF/com/android/metadata"; then
    version_name=$(unzip -p "${portrom}" META-INF/com/android/metadata 2>/dev/null | grep "version_name=" | cut -d= -f2)
    ota_version=$(unzip -p "${portrom}" META-INF/com/android/metadata 2>/dev/null | grep "ota_version=" | cut -d= -f2)
else
    version_name="$(basename "${portrom%.*}")"
    ota_version="V16.0.0"
fi
green "Basic ROM validation successful: ${portrom_type}" "ROM validation passed. Type: ${portrom_type}"
[[ -n "${version_name}" ]] && echo "Version Name: ${version_name}"
version_name2=""
portrom2_type=""
mix_port=false
if [[ -n "$portrom2" ]]; then
    mix_port=true
fi
if [[ -n "$portparts" ]]; then
    read -ra mix_port_part <<< "$portparts"
else
    mix_port_part=("my_stock" "my_region" "my_manifest" "my_product")
fi
if [[ "$mix_port" == true ]];then
    blue "Mixed Port Mode"
    blue "Validating second Port source ROM" "Validating PORTROM.."
    if unzip -l "${portrom2}" | grep -q "payload.bin"; then
        green "Validation for second ROM successful" "ROM validation passed."
        portrom2_type="payload"
        version_name2=$(unzip -p "${portrom2}" META-INF/com/android/metadata 2>/dev/null | grep "version_name=" | cut -d= -f2)
    elif unzip -l "${portrom2}" | grep -Eq "\.img$"; then
        portrom2_type="img"
        version_name2="$(basename "${portrom2%.*}")"
    else
        error "payload.bin / *.img not found in source ROM (please specify an official ROM containing system.img)" \
          "payload.bin or *.img not found, please use an official ROM package containing system.img as PORTROM."
        exit 1
    fi
fi
green "Basic ROM validation successful" "ROM validation passed."
blue "Cleaning up temporary working files" "Cleaning up.."
rm -rf app
rm -rf tmp
rm -rf config
rm -rf build/baserom/
rm -rf build/portrom/
find . -type d -name 'ColorOS_*' |xargs rm -rf
green "Cleanup complete" "Files cleaned up."
mkdir -p build/baserom/images/
mkdir -p build/portrom/images/
mkdir tmp
export TMPDIR=$work_dir/tmp/
# ===== Base ROM Extraction =====
if [[ ${baserom_type} == 'payload' ]]; then
    blue "Extracting Base ROM [payload.bin]" "Extracting files from BASEROM [payload.bin]"
    payload-dumper --out build/baserom/images/ "${baserom}" \
        || { error "payload-dumper failed for baserom" "payload-dumper failed"; exit 1; }
    green "Base ROM extraction complete [payload.bin]" "[payload.bin] extracted."
elif [[ ${baserom_type} == 'br' ]]; then
    blue "Extracting Base ROM [*.new.dat.br]" "Extracting files from BASEROM [*.new.dat.br]"
    unzip -q "${baserom}" -d build/baserom || \
        error "Failed to extract Base ROM [new.dat.br]" "Extracting [new.dat.br] error"
    green "Base ROM extraction complete [new.dat.br]" "[new.dat.br] extracted."
    blue "Unpacking and converting Base ROM [new.dat.br]" "Unpacking BASEROM [new.dat.br]"
    for file in build/baserom/*; do
        filename=$(basename -- "$file")
        extension="${filename##*.}"
        name="${filename%.*}"
        if [[ $name =~ [0-9] ]]; then
            new_name=$(echo "$name" | sed 's/[0-9]\+\(\.[^0-9]\+\)/\1/g' | sed 's/\.\./\./g')
            mv -fv "$file" "build/baserom/${new_name}.${extension}"
        fi
    done
    for i in ${super_list}; do
        if [[ -f build/baserom/${i}.new.dat.br ]]; then
            ${tools_dir}/brotli -d build/baserom/${i}.new.dat.br >/dev/null 2>&1
            python3 ${tools_dir}/sdat2img.py \
                build/baserom/${i}.transfer.list \
                build/baserom/${i}.new.dat \
                build/baserom/images/${i}.img >/dev/null 2>&1
            rm -rf build/baserom/${i}.new.dat* build/baserom/${i}.transfer.list build/baserom/${i}.patch.*
        fi
    done
    green "Base ROM unpacking and conversion complete [new.dat.br]" "[new.dat.br] unpack complete."
elif [[ ${baserom_type} == 'img' ]]; then
    blue "Base ROM format: [img] (extracting .img files)" "Extracting BASEROM containing .img files"
    mkdir -p build/baserom/images/
    unzip -q "${baserom}" -d build/baserom/tmp/ || \
        error "Failed to extract Base ROM" "Extracting BASEROM error"
    find build/baserom/tmp/ -type f -name "*.img" -exec mv -fv {} build/baserom/images/ \;
    rm -rf build/baserom/tmp/
    green "Base ROM extraction complete [*.img]" "[*.img] extracted."
else
    error "Unknown Base ROM format: ${baserom_type}" "Unknown base package type: ${baserom_type}"
    exit 1
fi
# ===== Port Source ROM Extraction =====
if [[ -n ${version_name} ]] && [[ -d "build/${version_name}" ]]; then
    blue "Port source ROM cache detected: build/${version_name} (reusing)" \
         "Cached ${version_name} folder detected, copying..."
    IFS=',' read -ra PARTS <<< "$port_partition"
    for i in "${PARTS[@]}"; do
        if [[ -f "build/${version_name}/${i}.img" ]]; then
            cp -fv "build/${version_name}/${i}.img" build/portrom/images/
        else
            yellow "Cache: ${i}.img not in cache folder — skipping"
        fi
    done
else
    mkdir -p "build/${version_name}/" build/portrom/images/
    if [[ ${portrom_type} == 'payload' ]]; then
        blue "Extracting Port source ROM [payload.bin]" "Extracting PORTROM [payload.bin]"
        payload-dumper --partitions "${port_partition}" --out "build/${version_name}/" "${portrom}" \
            || { error "payload-dumper failed for portrom" "payload-dumper failed"; exit 1; }
        cp -rfv "build/${version_name}/"*.img build/portrom/images/
        green "Port source ROM extraction complete [payload.bin]" "[payload.bin] extracted."
    elif [[ ${portrom_type} == 'img' ]]; then
        blue "Port source ROM format: [img] (extracting required .img files only)" "Extracting PORTROM containing .img files"
        IFS=',' read -ra PARTS <<< "$port_partition"
        declare -a unzip_targets=()
        for part in "${PARTS[@]}"; do
          unzip_targets+=("${part}.img" "${part}_a.img" "${part}_b.img")
        done
        blue "Selectively extracting only required .img files" "Extracting specific img files from PORTROM"
        unzip -q "${portrom}" "${unzip_targets[@]}" -d "build/${version_name}/" || \
        error "Failed to extract specified .img files (verify if ${port_partition} exists in ROM)" \
          "Failed to extract specified img files from PORTROM."
         green "Specified partition extraction successful" "Selected partitions extracted successfully."
        find "build/${version_name}/" -type f -name "*.img" -exec cp -fv {} build/portrom/images/ \;
        green "Port source ROM extraction complete [*.img]" "[*.img] extracted."
    else
        error "Unknown Port source ROM format: ${portrom_type}" "Unknown port package type: ${portrom_type}"
        exit 1
    fi
fi
if [[ -n "${version_name2}" ]] && [[ -d "build/${version_name2}" ]];then
    blue "Second Port source ROM cache detected: build/${version_name2} (reusing)" "cached ${version_name2} folder detected, copying"
    for i in "${mix_port_part[@]}"; do
        if [[ -f "build/${version_name2}/${i}.img" ]]; then
            cp -fv "build/${version_name2}/${i}.img" build/portrom/images/
        else
            yellow "Cache: ${i}.img not in cache folder — skipping"
        fi
    done
elif [[ -n "${version_name2}" ]];then
    if [[ "${portrom2_type}" == 'payload' ]]; then
        blue "Extracting second Port source ROM [payload.bin]" "Extracting files from PORTROM [payload.bin]"
        mkdir -p "build/${version_name2}/"
        payload-dumper --partitions "${port_partition}" --out "build/${version_name2}/" "${portrom2}" \
            || { error "payload-dumper failed for portrom2" "payload-dumper failed"; exit 1; }
        for i in "${mix_port_part[@]}"; do
            if [[ -f "build/${version_name2}/${i}.img" ]]; then
                cp -fv "build/${version_name2}/${i}.img" build/portrom/images/
            else
                yellow "portrom2: ${i}.img not found — skipping"
            fi
        done
    elif [[ "${portrom2_type}" == 'img' ]]; then
        blue "Second Port source ROM format: [img] (extracting required .img files only)" "Extracting PORTROM containing .img files"
        IFS=',' read -ra PARTS <<< "$port_partition"
        declare -a unzip_targets=()
        for part in "${PARTS[@]}"; do
          unzip_targets+=("${part}.img" "${part}_a.img" "${part}_b.img")
        done
        blue "Selectively extracting only required .img files" "Extracting specific img files from PORTROM"
        unzip -q "${portrom2}" "${unzip_targets[@]}" -d "build/${version_name2}/" || \
        error "Failed to extract specified .img files (verify if ${port_partition} exists in ROM)" \
          "Failed to extract specified img files from PORTROM."
         green "Specified partition extraction successful" "Selected partitions extracted successfully."
        find "build/${version_name2}/" -type f -name "*.img" -exec cp -fv {} build/portrom/images/ \;
        green "Port source ROM extraction complete [*.img]" "[*.img] extracted."
    fi
fi
app_patch_folder="${version_name2:-${version_name}}"
for part in system product system_ext my_product my_manifest;do
    extract_partition "build/baserom/images/${part}.img" build/baserom/images
done
for image in vendor odm my_company my_preload system_dlkm vendor_dlkm my_engineering;do
    if [ -f "build/baserom/images/${image}.img" ];then
        mv -f "build/baserom/images/${image}.img" "build/portrom/images/${image}.img"
        extract_partition "build/portrom/images/${image}.img" build/portrom/images/
    fi
done
if [[ ! -d "build/portrom/images/system_dlkm" ]]; then
    # system_dlkm not present; use a reduced default super_list
    super_list="system system_ext vendor product my_product odm my_engineering my_stock my_heytap my_carrier my_region my_bigball my_manifest my_company my_preload"
fi
green "Starting logical partition expansion" "Starting extract portrom partition from img"
for part in ${super_list};do
    if [[ ! -d "build/portrom/images/${part}" ]]; then
        blue "Extracting [${part}]..." "Extracting [${part}]"
        (
        extract_partition "${work_dir}/build/portrom/images/${part}.img" "${work_dir}/build/portrom/images/" && \
        rm -rf "${work_dir}/build/baserom/images/${part}.img"
        ) &
    else
        yellow "Skipping extraction from PORTROM [${part}]" "Skip extracting [${part}] from PORTROM"
    fi
done
wait
rm -rf config
blue "Retrieving ROM build info" "Fetching ROM build prop."

# Helper: read a prop value from a file (first match)
get_prop() {
    local file="$1" key="$2"
    # grep -m1 exits 1 when key not found; || true ensures the pipeline always exits 0
    # so callers using set -euo pipefail never crash on a missing prop.
    { grep "^${key}=" "$file" 2>/dev/null || true; } | awk 'NR==1' | cut -d'=' -f2-
}

base_android_version=$(get_prop build/baserom/images/system/system/build.prop "ro.build.version.release")
port_android_version=$(get_prop build/portrom/images/system/system/build.prop "ro.build.version.release")
green "Android: Base [Android ${base_android_version}] / Source [Android ${port_android_version}]"

base_android_sdk=$(get_prop build/baserom/images/system/system/build.prop "ro.system.build.version.sdk")
port_android_sdk=$(get_prop build/portrom/images/system/system/build.prop "ro.system.build.version.sdk")
green "SDK: Base [SDK ${base_android_sdk}] / Source [SDK ${port_android_sdk}]"

base_rom_version=$(get_prop build/baserom/images/my_manifest/build.prop "ro.build.display.ota" | cut -d'_' -f2-)
port_rom_version=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.ota" | cut -d'_' -f2-)
green "ROM: Base [${base_rom_version}] / Source [${port_rom_version}]"

# Device code: try ro.oplus.version.my_manifest first (OOS/older ColorOS),
# fall back to ro.product.model (newer ColorOS like OP15/CPH2745) if empty.
# NOTE: do NOT use [[ -z ]] && var=$(...) under set -euo pipefail — if the
# subshell's grep exits 1 (prop not found), pipefail propagates it and set -e
# kills the script. Use explicit if/else instead.
base_device_code=$(get_prop build/baserom/images/my_manifest/build.prop "ro.oplus.version.my_manifest" | cut -d'_' -f1)
if [[ -z "$base_device_code" ]]; then
    base_device_code=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.model")
fi
if [[ -z "$base_device_code" ]]; then
    base_device_code=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.device")
fi

port_device_code=$(get_prop build/portrom/images/my_manifest/build.prop "ro.oplus.version.my_manifest" | cut -d'_' -f1)
if [[ -z "$port_device_code" ]]; then
    port_device_code=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.model")
fi
if [[ -z "$port_device_code" ]]; then
    port_device_code=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.device")
fi

green "Device Code: Base [${base_device_code}] / Source [${port_device_code}]"

base_product_device=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.device")
port_product_device=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.device")
green "product.device: Base [${base_product_device}] / Source [${port_product_device}]"

base_product_name=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.name")
port_product_name=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.name")
green "product.name: Base [${base_product_name}] / Source [${port_product_name}]"

base_product_model=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.model")
port_product_model=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.model")
green "product.model: Base [${base_product_model}] / Source [${port_product_model}]"

if grep -q "ro.vendor.oplus.market.name" build/baserom/images/my_manifest/build.prop; then
    base_market_name=$(get_prop build/baserom/images/my_manifest/build.prop "ro.vendor.oplus.market.name")
else
    base_market_name=$(get_prop build/portrom/images/odm/build.prop "ro.vendor.oplus.market.name")
fi
# Keep this lookup non-fatal when a prop/file is missing under set -euo pipefail.
base_market_enname=$(get_prop build/baserom/images/my_manifest/build.prop "ro.vendor.oplus.market.enname")
if [[ -z "$base_market_enname" ]]; then
    base_market_enname=$(get_prop build/portrom/images/odm/build.prop "ro.vendor.oplus.market.enname")
fi
if [[ -z "$base_market_enname" ]]; then
    base_market_enname=$(grep -r --include="*.prop" "ro.vendor.oplus.market.enname" build/portrom/images/ 2>/dev/null | head -n1 | cut -d'=' -f2 || true)
fi
if [[ -z "$base_market_enname" ]]; then
    base_market_enname="${base_market_name}"
fi
port_market_name=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.vendor.oplus.market.name" build/portrom/images/ 2>/dev/null | head -n1 | cut -d'=' -f2 || true)
green "Market Name: Base [${base_market_name}] / Source [${port_market_name}]"

base_my_product_type=$(get_prop build/baserom/images/my_product/build.prop "ro.oplus.image.my_product.type")
port_my_product_type=$(get_prop build/portrom/images/my_product/build.prop "ro.oplus.image.my_product.type")
green "my_product Type: Base [${base_my_product_type}] / Source [${port_my_product_type}]"

# Build the target display ID: replace port device code with base device code.
# Guard: if port_device_code is empty, sed "s//x/g" exits 1 and kills the script
# under set -euo pipefail. Use parameter substitution to skip the sed when empty.
if [[ -n "$port_device_code" ]]; then
    target_display_id=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.id" \
        | sed "s/${port_device_code}/${base_device_code}/g")
    target_display_id_show=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.id.show" \
        | sed "s/${port_device_code}/${base_device_code}/g")
else
    target_display_id=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.id")
    target_display_id_show=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.id.show")
    yellow "port_device_code empty — display ID used as-is from portrom"
fi
# Fallback: if still empty, use product model as display ID
if [[ -z "$target_display_id" ]]; then
    target_display_id="${port_product_model}"
fi
if [[ -z "$target_display_id_show" ]]; then
    target_display_id_show="${target_display_id}"
fi
base_vendor_brand=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.vendor.brand")
port_vendor_brand=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.vendor.brand")
port_ssi_brand=$(get_prop build/portrom/images/system_ext/etc/build.prop "ro.oplus.image.system_ext.brand")
base_product_first_api_level=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.first_api_level")
port_product_first_api_level=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.first_api_level")
base_device_family=$(get_prop build/baserom/images/my_product/build.prop "ro.build.device_family")
target_device_family=$(get_prop build/portrom/images/my_product/build.prop "ro.build.device_family")
portrom_version_security_patch=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.version.security_patch")
port_oplusrom_version=$(get_prop build/portrom/images/my_product/build.prop "ro.build.version.oplusrom.confidential")
port_release_or_codename=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.version.release_or_codename")
regionmark=$(find build/portrom/images/ -name build.prop -exec grep -m1 "ro.vendor.oplus.regionmark=" {} \; -quit | cut -d'=' -f2)
base_regionmark=$(find build/baserom/images/ -name build.prop -exec grep -m1 "ro.vendor.oplus.regionmark=" {} \; -quit | cut -d '=' -f2)
if [ -z "$base_regionmark" ]; then
  base_regionmark=$(find build/baserom/images/ -name build.prop -exec grep -m1 "ro.oplus.image.my_region.type=" {} \; -quit | cut -d '=' -f2 | cut -d '_' -f1)
fi
base_ab_partitions=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.ab_ota_partitions")
vendor_cpu_abilist32=$(get_prop build/portrom/images/vendor/build.prop "ro.vendor.product.cpu.abilist32")
base_area=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.area" build/baserom/images/ 2>/dev/null | head -n1 | cut -d "=" -f2 | tr -d '\r' || true)
base_brand=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.brand" build/baserom/images/ 2>/dev/null | head -n1 | cut -d "=" -f2 | tr -d '\r' || true)
baseIsColorOSCN=false
baseIsOOS=false
baseIsRealmeUI=false
if [[ "$base_area" == "domestic" && "$base_brand" != "realme" ]]; then
    baseIsColorOSCN=true
elif [[ "$base_brand" == "realme" ]];then
    baseIsRealmeUI=true
elif [[ "$base_area" == "gdpr" && "$base_brand" == "oneplus" ]]; then
    baseIsOOS=true
fi
port_area=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.area" build/portrom/images/ 2>/dev/null | head -n1 | cut -d "=" -f2 | tr -d '\r' || true)
port_brand=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.brand" build/portrom/images/ 2>/dev/null | head -n1 | cut -d "=" -f2 | tr -d '\r' || true)
portIsColorOSGlobal=false
portIsOOS=false
portIsColorOS=false
portIsRealmeUI=false
port_oplusrom_version=$(get_oplusrom_version)
if [[ "$port_brand" == "realme" ]];then
    portIsRealmeUI=true
fi
if [[ "$port_area" == "gdpr" && "$port_brand" != "oneplus" ]]; then
    portIsColorOSGlobal=true
elif [[ "$port_area" == "gdpr" && "$port_brand" == "oneplus" ]]; then
    portIsOOS=true
else
    portIsColorOS=true
fi
if grep -q "ro.build.ab_update=true" build/portrom/images/vendor/build.prop; then
    is_ab_device=true
else
    is_ab_device=false
fi
if [[ ! -f build/portrom/images/system/system/bin/app_process32 && -n "$vendor_cpu_abilist32" ]]; then
    blue "64-bit only portrom detected — converting vendor to 64-bit-only"
    sed -i "s/ro.vendor.product.cpu.abilist=.*/ro.vendor.product.cpu.abilist=arm64-v8a/g" build/portrom/images/vendor/build.prop
    sed -i "s/ro.vendor.product.cpu.abilist32=.*/ro.vendor.product.cpu.abilist32=/g" build/portrom/images/vendor/build.prop
    sed -i "s/ro.zygote=.*/ro.zygote=zygote64/g" build/portrom/images/vendor/default.prop
fi
if [[ -f "devices/${base_product_device}/config" ]];then
   source "devices/${base_product_device}/config"
fi
if [[ -n "$target_display_id" ]]; then
    sed -i "s/ro.build.display.id=.*/ro.build.display.id=${target_display_id}/g" build/portrom/images/my_manifest/build.prop
fi
sed -i "s/ro.product.first_api_level=.*/ro.product.first_api_level=${base_product_first_api_level}/g" build/portrom/images/my_manifest/build.prop
if ! grep -q "ro.build.display.id.show" build/portrom/images/my_manifest/build.prop ;then
    echo "ro.build.display.id.show=$target_display_id_show" >> build/portrom/images/my_manifest/build.prop
else
    sed -i "s/ro.build.display.id.show=.*/ro.build.display.id.show=${target_display_id_show}/g" build/portrom/images/my_manifest/build.prop
fi
sed -i '/ro.build.version.release=/d' build/portrom/images/my_manifest/build.prop
sed -i "s/ro.vendor.oplus.market.name=.*/ro.vendor.oplus.market.name=${base_market_name}/g" build/portrom/images/my_manifest/build.prop
sed -i "s/ro.vendor.oplus.market.enname=.*/ro.vendor.oplus.market.enname=${base_market_enname}/g" build/portrom/images/my_manifest/build.prop
sed -i "s/ro.product.ab_ota_partitions=.*/ro.product.ab_ota_partitions=${base_ab_partitions}/g" build/portrom/images/my_manifest/build.prop
sed -i '/ro.oplus.watermark.betaversiononly.enable=/d' build/portrom/images/my_manifest/build.prop
if [[ $base_android_version -le 14 ]];then
    BASE_PROP="build/baserom/images/my_manifest/build.prop"
    PORT_PROP="build/portrom/images/my_manifest/build.prop"

    KEYS="\.name= \.model= \.manufacturer= \.device= \.brand= \.my_product.type="
    for k in $KEYS; do
        { grep "$k" "$BASE_PROP" || true; } | while IFS='=' read -r key value; do
            if [[ "$key" == "ro.product.vendor.brand" ]]; then
                # 特殊处理：强制写 OPPO
                sed -i "s|^$key=.*|$key=OPPO|" "$PORT_PROP"
            elif grep -q "^$key=" "$PORT_PROP"; then
                sed -i "s|^$key=.*|$key=$value|" "$PORT_PROP"
            fi
        done
    done
fi
if [[ -n "$vendor_cpu_abilist32" ]] ;then
    sed -i "/ro.zygote=zygote64/d" build/portrom/images/my_manifest/build.prop
fi
vndk_version=""
while IFS= read -r prop_file; do
    vndk_version=$(get_prop "$prop_file" "ro.vndk.version")
    if [[ -n "$vndk_version" ]]; then
        yellow "ro.vndk.version=${vndk_version} (found in ${prop_file})"
        break
    fi
done < <(find build/portrom/images/vendor/ -name "*.prop")
base_vndk=$(find build/baserom/images/system_ext/apex -type f -name "com.android.vndk.v${vndk_version}.apex" 2>/dev/null | head -n1)
port_vndk=$(find build/portrom/images/system_ext/apex -type f -name "com.android.vndk.v${vndk_version}.apex" 2>/dev/null | head -n1)
if [[ -n "$vndk_version" && ! -f "${port_vndk}" ]]; then
    if [[ -f "${base_vndk}" ]]; then
        yellow "apex not found, copying from Base ROM" "target apex is missing, copying from baserom"
        cp -rf "${base_vndk}" "build/portrom/images/system_ext/apex/"
    else
        yellow "vndk apex not found in either base or port ROM — skipping (vndk=${vndk_version})"
    fi
fi
find build/portrom/images -name "build.prop" -exec sed -i "s/ro.build.version.security_patch=.*/ro.build.version.security_patch=${portrom_version_security_patch}/g" {} \;
###############################################################################
# Patches for services.jar / framework.jar / oplus-services.jar
###############################################################################
old_face_unlock_app=$(find build/baserom/images/my_product -name "OPFaceUnlock.apk")
extra_args=""
if [[ -f build/${app_patch_folder}/patched/services.jar ]];then
    blue "Copying processed services.jar"
    cp -rfv build/${app_patch_folder}/patched/services.jar build/portrom/images/system/system/framework/services.jar
elif [[ -f build/portrom/images/system/system/framework/services.jar ]];then
    if [[ ! -d tmp ]];then
        mkdir -p tmp/
    fi
    mkdir -p tmp/services/
    cp -rf build/portrom/images/system/system/framework/services.jar tmp/services.jar
    framework_res=$(find build/portrom/images/ -type f -name "framework-res.apk" | head -n 1)
    extra_args=""
    if [[ -f "$framework_res" ]];then
        extra_args="-framework $framework_res"
    fi
    java -jar bin/apktool/APKEditor.jar d -f -i tmp/services.jar -o tmp/services
    smalis=("ScanPackageUtils")
    methods=("--assertMinSignatureSchemeIsValid")
    for (( i=0; i<${#smalis[@]}; i++ )); do
        smali="${smalis[i]}"
        method="${methods[i]}"
        target_file=$(find tmp/services -type f -name "${smali}.smali")
        if [[ -f "$target_file" ]]; then
            for single_method in $method; do
                python3 bin/patchmethod.py "$target_file" "$single_method" && echo "${target_file} patched successfully"
            done
        fi
    done
    target_method='getMinimumSignatureSchemeVersionForTargetSdk'
    old_smali_dir=""
    while read -r smali_file; do
        smali_dir=$(echo "$smali_file" | cut -d "/" -f 3)
        if [[ $smali_dir != $old_smali_dir ]]; then
            smali_dirs+=("$smali_dir")
        fi
        method_line=$(grep -n "$target_method" "$smali_file" | cut -d ':' -f 1 || true)
        if [[ -z "$method_line" ]]; then
            yellow "Skipping $smali_file — method not found"
            old_smali_dir=$smali_dir
            continue
        fi
        register_number=$(tail -n +"${method_line:-1}" "$smali_file" | grep -m 1 "move-result" | tr -dc '0-9' || true)
        if [[ -z "$register_number" ]]; then
            yellow "Skipping $smali_file — move-result not found"
            old_smali_dir=$smali_dir
            continue
        fi
        move_result_end_line=$(awk -v ML=${method_line:-1} 'NR>=ML && /move-result /{print NR; exit}' "$smali_file")
        if [[ -z "$move_result_end_line" ]]; then
            yellow "Skipping $smali_file — move-result end not found"
            old_smali_dir=$smali_dir
            continue
        fi
        orginal_line_number=$method_line
        replace_with_command="const/4 v${register_number}, 0x0"
        { sed -i "${orginal_line_number},${move_result_end_line}d" "$smali_file" && sed -i "${orginal_line_number}i\\${replace_with_command}" "$smali_file"; } && blue "${smali_file} Patch successful" "${smali_file} patched"
        old_smali_dir=$smali_dir
    done < <(find tmp/services/smali/*/com/android/server/pm/ tmp/services/smali/*/com/android/server/pm/pkg/parsing/ -maxdepth 1 -type f -name "*.smali" -exec grep -H "$target_method" {} \; | cut -d ':' -f 1)
    ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS='ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS'
    find tmp/services/ -type f -name "ReconcilePackageUtils.smali" | while read smali_file; do
        match_line=$({ grep -n "sput-boolean .*${ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS}" "$smali_file" || true; } | head -n 1)
        if [[ -n "$match_line" ]]; then
            line_number=$(echo "$match_line" | cut -d ':' -f 1)
            reg=$(echo "$match_line" | sed -n 's/.*sput-boolean \([^,]*\),.*/\1/p')
            echo "Found in $smali_file at line $line_number using register $reg"
            sed -i "${line_number}i\ const/4 $reg, 0x1" "$smali_file"
            echo "→ Patched successfully in $smali_file"
        else
            echo "× Not found in $smali_file"
        fi
    done
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/services -o build/${app_patch_folder}/patched/services.jar
    cp -rfv build/${app_patch_folder}/patched/services.jar build/portrom/images/system/system/framework/services.jar
fi
if [[ -f build/${app_patch_folder}/patched/framework.jar ]];then
    blue "Copying processed framework.jar"
    cp -rfv build/${app_patch_folder}/patched/framework.jar build/portrom/images/system/system/framework/framework.jar
else
    cp -rf build/portrom/images/system/system/framework/framework.jar tmp/framework.jar
    if [[ -f devices/common/0001-core-framework-Introduce-OplusPropsHookUtils-V6.patch ]]; then
        java -jar bin/apktool/APKEditor.jar d -f -i tmp/framework.jar -o tmp/framework -no-dex-debug
        pushd tmp/framework
        [[ -d .git ]] && rm -rf .git
        git init
        git config user.name "patchuser"
        git config user.email "patchuser@example.com"
        git add . > /dev/null 2>&1
        git commit -m "Initial smali source" > /dev/null 2>&1
        echo "🔧 Applying patch: 0001-core-framework-Introduce-OplusPropsHookUtils-V6.patch ..."
        git apply ${work_dir}/devices/common/0001-core-framework-Introduce-OplusPropsHookUtils-V6.patch && echo "✅ Patch application successful" || echo "❌ Patch application failed"
        popd
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/framework -o build/${app_patch_folder}/patched/framework.jar
        cp -rfv build/${app_patch_folder}/patched/framework.jar build/portrom/images/system/system/framework/framework.jar
    else
        echo "⚠️ 0001-core-framework-Introduce-OplusPropsHookUtils-V6.patch not found; skipping"
    fi
fi
# Helper used by Smoothness Addon blocks (SM8250 and SM8350)
# Appends a prop to a file only if the key is not already present
set_prop() {
    local file="$1" prop="$2"
    grep -q "^${prop%%=*}=" "$file" || echo "$prop" >> "$file"
}

# force_prop: always sets a prop, replacing any existing value.
# set_prop only appends when absent — force_prop is needed when the key already
# exists with the wrong value (e.g. CTS fingerprint overwrite on CN ROMs).
force_prop() {
    local file="$1" prop="$2"
    local key="${prop%%=*}"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${prop}|" "$file"
    else
        echo "$prop" >> "$file"
    fi
}

if [[ "${base_device_family}" == "OPSM8250" ]] && \
   [[ "${base_product_device}" =~ ^(OnePlus8Pro|OnePlus8|OnePlus8T|OnePlus9R|KB2000|KB2001|KB2003|KB2005|IN2010|IN2011|IN2012|IN2013|IN2020|IN2021|IN2022|IN2023)$ ]]; then

    SYSTEM_PATH="build/portrom/images/system/system"
    VENDOR_PATH="build/portrom/images/vendor"

    if [[ ! -f "$SYSTEM_PATH/build.prop" || ! -f "$VENDOR_PATH/default.prop" ]]; then
        yellow "Smoothness Addons (SM8250) skipped: required prop files not found"
    else
        blue "Implementing Smoothness Addons (SM8250) — Feather Engine..."

        # ── Sub-variant detection ─────────────────────────────────────────────
        # OP8 Pro: 120Hz AMOLED QHD+ curved, OP8T: 120Hz flat FHD+
        # OP8:     60Hz AMOLED, OP9R (SM8250): 90Hz FHD+ AMOLED
        is_op8pro=false; is_op8t=false; is_op9r_8250=false
        case "${base_product_device}" in
            OnePlus8Pro|IN2020|IN2021|IN2022|IN2023) is_op8pro=true ;;
            OnePlus8T|KB2000|KB2001|KB2003|KB2005)   is_op8t=true  ;;
            OnePlus9R|LE2100|LE2101)                  is_op9r_8250=true ;;
        esac

        # ── RAM variant detection ─────────────────────────────────────────────
        # IN2023 = OnePlus 8 Pro 12GB.  All other IN20xx = 8GB.
        is_12gb_variant=false
        if [[ "$base_product_model" == "IN2023" ]]; then
            is_12gb_variant=true
            blue "12GB RAM variant detected (${base_product_model}) — applying 12GB profile"
        fi

        # ── SurfaceFlinger / Rendering ────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.max_frame_buffer_acquired_buffers=3"
        # Threaded Skia: GPU commands spread across cores — better frame times
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.renderer=skiaglthreaded"
        set_prop "$VENDOR_PATH/default.prop"  "debug.renderengine.backend=skiaglthreaded"
        # Reduce jank when GPU falls behind display timeline
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.enable_gl_backpressure=1"
        # Stop SF capping refresh via its own frame rate override path
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.enable_frame_rate_override=false"
        set_prop "$VENDOR_PATH/default.prop"  "debug.egl.hw=1"
        # SF context priority: elevates GL context in Adreno driver queue
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_context_priority=true"
        # Triple-buffer: eliminates tearing on 120Hz panels
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.running_without_sync_framework=false"
        # SF early wake-up: compositor ready before vsync fires
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_app_phase_offset_ns=500000"
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_sf_phase_offset_ns=500000"
        # SF HW vsync: use direct hardware vsync signal
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.hw=1"
        # Protect contents OFF: skip per-frame DRM check on non-DRM buffers
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.protect_contents=false"
        # BufferQueue early release: SF drops acquired buffers sooner
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.enable_frame_rate_flexibility=true"

        # ── SurfaceFlinger idle timers (per panel type) ───────────────────────
        if [[ "${is_op8pro}" == true ]]; then
            # OP8 Pro: 120Hz curved AMOLED — drop refresh after 500ms of no animation
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_idle_timer_ms=500"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_touch_timer_ms=200"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_display_power_timer_ms=1000"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.idle_fps=60"
        elif [[ "${is_op9r_8250}" == true ]]; then
            # OP9R on SM8250: 90Hz FHD+ — conservative timers, no idle drop below 90
    # [deduped] set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_idle_timer_ms=300"
    # [deduped] set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_touch_timer_ms=100"
    # [deduped] set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_display_power_timer_ms=500"
    # [deduped] set_prop "$VENDOR_PATH/default.prop"  "vendor.display.idle_fps=60"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_content_detection_for_refresh_rate=false"
        else
            # OP8 / OP8T: 120Hz flat FHD+
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_idle_timer_ms=400"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_touch_timer_ms=150"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_display_power_timer_ms=750"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.idle_fps=60"
        fi

        # ── Adreno 650 (SM8250) ───────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "ro.hardware.vulkan=adreno"
        set_prop "$VENDOR_PATH/default.prop"  "ro.hardware.egl=adreno"
        set_prop "$VENDOR_PATH/default.prop"  "persist.graphics.vulkan.disable=false"
        # Updatable Adreno driver for Kona — enables newer driver blobs from Play Store
        set_prop "$VENDOR_PATH/default.prop"  "ro.gfx.driver.1=com.qualcomm.qti.gpudrivers.kona.api30"
        # Skia Vulkan backend: uses Adreno 650's Vulkan path for HWUI — faster blur/shadow
        set_prop "$VENDOR_PATH/default.prop"  "ro.hwui.skia_use_vulkan_for_hwui=true"
        # DCVS mode 2 = performance bias: bus DCVS votes higher before load arrives
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.dcvs_mode=2"

        # ── Dalvik / ART ──────────────────────────────────────────────────────
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.usejit=true"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heaptargetutilization=0.75"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapstartsize=16m"
        # heapgrowthlimit = heapsize: ART never triggers GC-before-allocation
        # Each GC pause = 8-15ms = ~2-3 SC Geekbench points lost
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapgrowthlimit=512m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapsize=512m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapminfree=8m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapmaxfree=32m"
        # AOT speed filter: biggest Geekbench SC impact; faster app cold launch
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-filter=speed"
        # All 8 cores: Gold+Prime participate in hot-path inlining analysis
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-threads=8"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-cpu-set=0,1,2,3,4,5,6,7"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-swap=false"
        # JIT: lower threshold so hot methods promote to AOT faster
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.jitthreshold=500"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.jitinitialsize=64m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.jitmaxsize=512m"
        # Boot-time dex2oat on all cores — first-boot compilation finishes faster
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.boot-dex2oat-threads=8"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.boot-dex2oat-cpu-set=0,1,2,3,4,5,6,7"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.image-dex2oat-filter=speed-profile"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.image-dex2oat-threads=4"
        # dex2oat JVM heap: without this dex2oat GCs heavily during compilation
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-Xms=64m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-Xmx=512m"

        # ── Audio latency ─────────────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "af.fast_track_multiplier=1"
        set_prop "$VENDOR_PATH/default.prop"  "audio.deep_buffer.media=false"

        # ── Qualcomm Perf HAL ─────────────────────────────────────────────────
        # These talk directly to the QTI perf daemon — actual impact on launch/scroll
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.iop.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.iop_v3.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.scroll_opt=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.gestureflingboost.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.enable_hint_manager=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.enable_perf_hal_mpctlv3=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.ux_frameboost.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.framepacing.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.topAppRenderThreadBoost.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.vsync_boost.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.app_launch_hint_enable=1"
        # PHR: pre-boosts CPU before next frame budget — X1 already at peak before subtest
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.phr.target_fps=120"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.phr.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.phr.render_ahead=2"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.sched_boost_on_top_app=1"
        # LPM: disable prediction to keep prime in shallower C-state
        set_prop "$VENDOR_PATH/default.prop"  "vendor.power.lpm_prediction=false"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.lpm.prediction=false"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.bus.dcvs=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.ddr.bw_boost=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.cci_boost=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.llcc.wt_aggr=1"

        # ── Background process / memory limits ────────────────────────────────
        set_prop "$SYSTEM_PATH/build.prop"    "ro.sys.fw.bg_apps_limit=48"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bg_apps_limit=48"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bservice_enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.purgeable_assets=1"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.min.fling_velocity=160"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.max.fling_velocity=8000"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.max_starting_bg=4"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.bg_app_suspend.enable=true"

        # ── LPDDR5 / LLCC ────────────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.retentionmode=1"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.zygote.preload.enable=true"

        # ── HWUI caches ───────────────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.texture_cache_size=72"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.layer_cache_size=48"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.r_buffer_cache_size=8"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.path_cache_size=32"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.drop_shadow_cache_size=6"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.shape_cache_size=4"
        # HWUI hint manager: pushes perf hints into QTI HAL during heavy draw passes
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.use_hint_manager=true"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.target_cpu_time_percent=33"
        # Disable Skia atrace callbacks — pure CPU waste when no profiler is attached
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.skia_atrace_enabled=false"

        # ── QTI cgroup colocation ─────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.cgroup_follow.enable=true"

        # ── Modem / radio ─────────────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "persist.radio.add_power_save=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.process_sups_ind=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.use_data_netmgrd=true"

        # ── Wi-Fi ─────────────────────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.enhanced.power.save=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.wifi.power_save_mode=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.scan.allow_low_latency_scan=0"

        # ── Sensors ───────────────────────────────────────────────────────────
        # Sensor HAL real-time thread OFF — biggest idle battery win outside CPU
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.sensors.enable.rt_task=false"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.sensors.support_wakelock=false"

        # ── ART / dexopt lifecycle ────────────────────────────────────────────
        # IORap: AOSP-side app launch prefetch — complements vendor.perf.iop
        set_prop "$SYSTEM_PATH/build.prop"    "persist.device_config.runtime_native_boot.iorap_readahead_enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.downgrade_after_inactive_days=7"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.install=speed"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.shared_apk=speed"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.bg-dexopt=speed-profile"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.boot-after-ota=verify"

        # ── Job Scheduler / Boot ──────────────────────────────────────────────
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.job_scheduler_optimization_enabled=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.shutdown_timeout=3"

        # ── Battery: LMKD PSI ────────────────────────────────────────────────
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.use_psi=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.psi_partial_stall_ms=70"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.psi_complete_stall_ms=700"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.thrashing_limit=100"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.swap_free_low_percentage=10"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.kill_timeout_ms=100"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.critical_upgrade=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.upgrade_pressure=40"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.downgrade_pressure=60"

        # ── Memory trim / bandwidth ───────────────────────────────────────────
        set_prop "$SYSTEM_PATH/build.prop"    "ro.sys.fw.use_trim_settings=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.sys.fw.trim_enable_memory=3221225472"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.power.bw_hwmon.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.mem.autosuspend_enable=1"
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.suspend.mode=deep"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.perfd.reclaim_memory=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.radio.power_down_enable=1"

        # ── Misc ──────────────────────────────────────────────────────────────
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.inputopts.enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.hw_quickpoweron=true"
        set_prop "$VENDOR_PATH/default.prop"  "ro.config.low_power_audio=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.bt.a2dp_offload_cap=sbc-aptx-aptxhd-aac-ldac"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.audio.feature.a2dp_offload.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.audio.fluence.speaker=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.idle_time=0"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.idle_time_inactive=0"
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.strictmode.disable=true"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bg_apps_limit_io=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.hw_fast_dormancy=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.radio.sw_mbn_update=0"

        # ── Qualcomm Predictive Headroom (PHR)
        #  PHR predicts the next frame deadline and pre-boosts CPU/GPU before the frame window opens
        # More consistent frametimes in games vs reactive boosting alone
        # Target 60fps — covers most mobile games; PHR uses this to size the boost window
        # Per-Frame Adaptive Rendering — companion feature, adjusts render complexity per frame budget
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.pfar.enable=1"

        # ── App launch speed
        #  IORap daemon + Perfetto tracing — records which files apps access on launch,
        # then prefetches them the next time; complements vendor.perf.iop_v3 at AOSP layer
        set_prop "$SYSTEM_PATH/build.prop"    "ro.iorapd.enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "persist.iorapd.enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.iorapd.perfetto_enable=true"
        # QTI app launch hint — perf daemon boosts CPU/UFS on Activity.startActivity()
        # Preload more Java classes into Zygote at startup — app forks pay lower cold-start cost

        # ── Boot / reboot speed
        #  Boot-time dex2oat on all big+prime cores — first-boot compilation finishes faster
        # Boot image (framework classes) compiled with profile — good balance of size + speed
        # How many seconds to wait for services to exit cleanly on shutdown/reboot

        # ── Battery: fast radio dormancy
        #  After a data transfer ends, the radio drops to low-power idle faster
        # Significant battery win during intermittent data use (notifications, sync)
    # [deduped] set_prop "$VENDOR_PATH/default.prop"  "ro.config.hw_fast_dormancy=1"

        # ── Battery: userspace LMKD via PSI (Android 10+ correct mechanism)
        # The legacy /sys/module/lowmemorykiller/ node is often unloaded on OOS14+
        # These props are what lmkd actually reads on Android 14
        # Kill background apps only when PSI pressure is high, not on minor spikes

        # ── dex2oat JVM heap — compiler runs faster with enough heap
        # Without these the dex2oat process itself GCs heavily during compilation
        # Impact: faster first-boot preopt, faster app installs, faster OTA apply

        # ── Memory trim threshold (QTI)
        #  ActivityManager trims process memory when free RAM drops below 3GB
        # Keeps the working set fresh without hitting LMKD — better battery + perf

        # ── Input latency (QTI input stack)
        #  Routes touch events through a faster QTI processing path vs stock AOSP
        # Reduces touch-to-frame latency by ~2-5ms on Qualcomm targets

        # ── Quick power-on shortcut
        #  OEM fast cold-boot path — skips redundant hardware init sequences

        # ── Screen-off audio: DSP low-power path
        #  Routes audio through the DSP's low-power island when screen is off
        # Meaningful battery saving during music playback / background streaming

        # ── Bluetooth A2DP DSP offload
        #  Routes BT audio encoding/decoding through Hexagon ADSP instead of app CPU
        # ~30-50mA battery saving during Bluetooth audio — CPU stays at low freq

        # ── Display power management
        #  idle_time=0: no display power throttling while screen is on
        # Prevents the brief jank when display transitions back from idle mode mid-scroll

        # ── StrictMode overhead disabled
        #  StrictMode runs disk/network violation checks on the UI thread in non-debug builds
        # Disabling removes the check overhead (~0.1-0.3ms per operation) from the frame budget

        # ── I/O blkio cgroup weights
        #  App launches and foreground reads compete with background sync for UFS bandwidth
        # Higher weight = foreground I/O wins scheduling priority over background

        # ── Battery: memory bandwidth governor
        # bw_hwmon: hardware bus monitor scales DRAM freq on real utilisation counters
        # Idle → DDR drops to lowest OPP. App launch → scales up via HW counter IRQ.
        # DRAM is 15-20% of total SoC power budget — biggest single battery win below display
        # Memory controller auto-suspend: enters DRAM self-refresh faster on screen-off
        # Deep Linux suspend: PSCI s2idle power states, not just task freeze
        # perfd memory reclaim: free stale memory regions on each Activity change
        # Keeps free RAM high without LMKD kills → fewer cold relaunches → less CPU+battery
        # Radio: drop modem to minimum power state between data bursts

        # ── HWUI hint manager
        # HWUI pushes perf hints directly into QTI perf HAL during heavy draw passes
        # Eliminates latency between "heavy frame starts" and "CPU boost arrives"
        # 33%: give CPU 1/3 of frame budget; leave the rest for GPU + driver overhead
        # Disable Skia atrace callbacks — fires trace events on every draw call with no profiler
        # On non-debug OOS builds this is pure CPU waste (~0.05ms/frame)

        # ── SurfaceFlinger protect_contents
        # Skip per-frame DRM protection check on non-DRM buffers — removes a branch
        # from the composition loop; visible in frame time variance on heavy UIs

        # ── QTI cgroup task colocation
        # Co-locate render + binder threads on the same cluster — reduces cross-cluster
        # IPC latency for UI thread ↔ RenderThread communication

        # ── Render thread boost + vsync boost
        # Direct boost to the identified RenderThread — not just top-app cgroup
        # Perf HAL boost at every vsync signal — CPU at target freq before frame starts

        # ── SM8250 rc file — Feather Engine ─────────────────────────────────
        mkdir -p "$VENDOR_PATH/etc/init"
        cat > "$VENDOR_PATH/etc/init/op8_sched.rc" << 'EOF'
# ─────────────────────────────────────────────────────────────────────────────
# op8_sched.rc — SM8250 (Snapdragon 865) tuning — Feather Engine
# Cluster layout: cpu0-3 = Cortex-A55 | cpu4-6 = Cortex-A77 | cpu7 = Cortex-A77 Prime
# ─────────────────────────────────────────────────────────────────────────────
on boot

    # ── CPU Scheduler ────────────────────────────────────────────────────────
    write /proc/sys/kernel/sched_migration_cost_ns 3500000
    # upmigrate/downmigrate: tasks move to big cluster when util > 75%, leave at 60%
    write /proc/sys/kernel/sched_upmigrate 75
    write /proc/sys/kernel/sched_downmigrate 60
    write /proc/sys/kernel/sched_child_runs_first 1
    write /proc/sys/kernel/sched_latency_ns 10000000
    write /proc/sys/kernel/sched_wakeup_granularity_ns 2000000
    write /proc/sys/kernel/sched_min_granularity_ns 1500000
    # Prevent schedutil from clobbering QTI perf HAL boost requests
    write /proc/sys/kernel/sched_boost_no_override 1
    # Load balancer migrates tasks in smaller batches — fewer 2ms latency spikes
    write /proc/sys/kernel/sched_nr_migrate 8

    # ── WALT scheduler thresholds ─────────────────────────────────────────────
    # Small task ≤ 20%: pinned to little cores, never migrated to big
    write /proc/sys/kernel/sched_small_task 20
    # Colocation boost threshold: tasks below 40% util don't pull big cores active
    write /proc/sys/kernel/sched_min_task_util_for_colocation 40
    write /proc/sys/kernel/sched_min_task_util_for_boost 40
    # New tasks start at 15% load estimate — migrate up on first burst
    write /proc/sys/kernel/sched_walt_init_task_load_pct 15

    # ── Schedutil rate limits (SM8250: A55×4 | A77×3 | A77-Prime×1) ──────────
    # Little cores (cpu0-3): slow ramp-up = battery, fast ramp-down = cool
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/down_rate_limit_us 500
    # Big cores (cpu4-6): fast ramp-up = performance, moderate ramp-down
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/down_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/down_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/down_rate_limit_us 2000
    # Prime core (cpu7): INSTANT ramp-up, slow ramp-down holds it hot between bursts
    # up_rate=0 restores ~100 SC Geekbench points lost from 1000us cap
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/up_rate_limit_us 0
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/down_rate_limit_us 3000
    # hispeed_freq: prime jumps directly to 1516800 on first load spike
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/hispeed_freq 1516800

    # ── CPU frequency floors ──────────────────────────────────────────────────
    # Big core floor at 1132800kHz — SF render thread never stalls at freq ramp
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    # Prime floor at 1228800kHz — warm for instant GB SC responsiveness
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    # Prime max: 3187200kHz (SM8250 top freq)
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 3187200

    # ── LPM (Low Power Mode) prediction OFF ──────────────────────────────────
    # Speculative C-state puts prime in deep sleep between GB6 subtests (+50-80μs wake)
    # Disabling keeps prime in WFI — wakes in ~5μs instead → ~30-40 SC pts gained
    write /sys/module/lpm_levels/parameters/lpm_prediction 0
    write /sys/module/lpm_levels/parameters/sleep_disabled 0
    # Disable cluster power-collapse on prime — avoids 3ms wake penalty
    write /sys/module/lpm_levels/system/cpu7/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu4/cpu_pc_latency 0

    # ── Power-efficient workqueues: background kernel work to little cores ─────
    write /sys/module/workqueue/parameters/power_efficient Y

    # ── Kernel overhead ───────────────────────────────────────────────────────
    # perf_cpu_time_max_percent: cap kernel perf subsystem overhead at 3% (default 25%)
    write /proc/sys/kernel/perf_cpu_time_max_percent 3
    # Watchdog: pure overhead on healthy Android — disable
    write /proc/sys/kernel/nmi_watchdog 0
    write /proc/sys/kernel/hung_task_timeout_secs 0
    # RNG: batch entropy wakeups → fewer idle interrupts → better deep-idle residency
    write /proc/sys/kernel/random/read_wakeup_threshold 64
    write /proc/sys/kernel/random/write_wakeup_threshold 128

    # ── cpuset: enforce cluster affinity ──────────────────────────────────────
    # top-app gets ALL cores including prime — without this it falls back to default
    write /dev/cpuset/top-app/cpus 0-7
    write /dev/cpuset/foreground/cpus 0-6
    write /dev/cpuset/background/cpus 0-3
    write /dev/cpuset/system-background/cpus 0-3

    # ── FIFO UI scheduling ────────────────────────────────────────────────────
    # Elevates RenderThread + UI thread to SCHED_FIFO — eliminates scheduler jitter
    # causing 1-4ms frame drops during scroll/animation
    setprop sys.use_fifo_ui 1

    # ── stune: EAS utilization boosts ────────────────────────────────────────
    write /dev/stune/top-app/schedtune.boost 15
    write /dev/stune/top-app/schedtune.prefer_idle 1
    write /dev/stune/foreground/schedtune.boost 5
    write /dev/stune/foreground/schedtune.prefer_idle 1
    write /dev/stune/background/schedtune.boost 0
    write /dev/stune/background/schedtune.prefer_idle 0

    # ── uclamp: utilization floor/ceiling per cgroup ──────────────────────────
    # 40% floor: prime stays warm between GB6 subtests (costing ~30 SC pts without it)
    write /dev/cpuctl/top-app/cpu.uclamp.min 40
    write /dev/cpuctl/top-app/cpu.uclamp.max 100
    write /dev/cpuctl/foreground/cpu.uclamp.min 5
    write /dev/cpuctl/foreground/cpu.uclamp.max 100
    # Background ceiling: prevents rogue tasks from saturating big/prime cores
    write /dev/cpuctl/background/cpu.uclamp.max 50
    write /dev/cpuctl/system-background/cpu.uclamp.max 40

    # ── IRQ affinity — display/touch to big+prime cluster ────────────────────
    # f0 = 0b11110000 = cores 4,5,6,7 → lower display IRQ latency
    write /proc/irq/default_smp_affinity f0

    # ── CCI (Cross-Cluster Interconnect) frequency floor ─────────────────────
    # Low CCI bottlenecks inter-cluster memory transactions on MC workloads
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000

    # ── LPDDR5 bus floor ─────────────────────────────────────────────────────
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 200000
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000

    # ── Input boost ───────────────────────────────────────────────────────────
    # On first touch: littles→1.3GHz, bigs→1.1GHz, prime→1.5GHz for 120ms
    write /sys/module/cpu_boost/parameters/input_boost_freq "0:1324800 4:1132800 7:1516800"
    write /sys/module/cpu_boost/parameters/input_boost_ms 120

    # ── I/O (UFS 3.0) ─────────────────────────────────────────────────────────
    write /sys/block/sda/queue/scheduler mq-deadline
    write /sys/block/sda/queue/read_ahead_kb 2048
    write /sys/block/sda/queue/nr_requests 256
    write /sys/block/sda/queue/add_random 0
    # wbt_lat_usec=75ms: prevents I/O from starving foreground reads
    write /sys/block/sda/queue/wbt_lat_usec 75000
    # io_poll: completion polling not IRQ — cuts dex load latency
    write /sys/block/sda/queue/io_poll 1
    write /sys/block/sda/queue/io_poll_delay -1
    # rq_affinity=2: complete I/O on the issuing CPU — avoids cross-cluster cache invalidation
    write /sys/block/sda/queue/rq_affinity 2

    # ── VM / Memory ───────────────────────────────────────────────────────────
    write /proc/sys/vm/swappiness 30
    write /proc/sys/vm/dirty_ratio 20
    write /proc/sys/vm/dirty_background_ratio 5
    write /proc/sys/vm/vfs_cache_pressure 50
    write /proc/sys/vm/dirty_writeback_centisecs 3000
    write /proc/sys/vm/dirty_expire_centisecs 3000
    write /proc/sys/vm/page-cluster 0
    # 24MB free pages: prevents GC stalls on sudden allocation bursts
    write /proc/sys/vm/extra_free_kbytes 24576
    write /proc/sys/vm/min_free_kbytes 12288
    # watermark_scale=20: keep ~25MB above low-watermark → less reclaim latency
    write /proc/sys/vm/watermark_scale_factor 20
    # stat_interval=10: zone stats spinlock fires 10x less — visible in malloc perf
    write /proc/sys/vm/stat_interval 10
    # oom_kill_allocating_task=0: OOM killer kills background, not the triggering app
    write /proc/sys/vm/oom_kill_allocating_task 0
    # THP: transparent hugepages for LPDDR5 — reduces TLB pressure on texture maps
    write /sys/kernel/mm/transparent_hugepage/enabled always
    write /sys/kernel/mm/transparent_hugepage/defrag defer+madvise
    write /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 10000
    write /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 500

    # ── LMKD ─────────────────────────────────────────────────────────────────
    write /sys/module/lowmemorykiller/parameters/enable_adaptive_lmk 1
    write /sys/module/lowmemorykiller/parameters/vmpressure_file_min 81250

    # ── Zram ──────────────────────────────────────────────────────────────────
    write /sys/block/zram0/comp_algorithm lz4
    # 4GB zram for 8GB LPDDR5 — lz4 keeps decompression fast under pressure
    write /sys/block/zram0/disksize 4294967296
    # 8 parallel compression streams — all cores participate, reduces swap write latency
    write /sys/block/zram0/max_comp_streams 8

    # ── Adreno 650 GPU ────────────────────────────────────────────────────────
    write /sys/class/kgsl/kgsl-3d0/devfreq/governor msm-adreno-tz
    write /sys/class/kgsl/kgsl-3d0/force_clk_on 0
    # 56ms idle_timer: GPU NAP fast between frames (NAP wake = 0.3ms vs full-sleep 3ms)
    write /sys/class/kgsl/kgsl-3d0/idle_timer 56
    # 200MHz min: handles all UI compositing without 257MHz idle heat
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 200000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 200000000
    # 587MHz max cap: Adreno 650 stable ceiling — prevents thermal throttle cliff
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 587000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 587000000
    write /sys/class/kgsl/kgsl-3d0/bus_split 0
    write /sys/class/kgsl/kgsl-3d0/throttling 1
    # perfcounter=0: ~2-3% GPU cycle overhead — nothing reads these in production
    write /sys/class/kgsl/kgsl-3d0/perfcounter 0
    write /sys/class/kgsl/kgsl-3d0/nap_allowed 1
    # default_pwrlevel=4: GPU wakes to ~350MHz not minimum — faster first-frame ramp
    write /sys/class/kgsl/kgsl-3d0/default_pwrlevel 4
    # wake_nice=-5: GPU wakeup thread slightly elevated priority
    write /sys/class/kgsl/kgsl-3d0/wake_nice -5

    # ── Network ───────────────────────────────────────────────────────────────
    write /proc/sys/net/ipv4/tcp_fastopen 3
    write /proc/sys/net/core/rmem_max 8388608
    write /proc/sys/net/core/wmem_max 8388608
    write /proc/sys/net/ipv4/tcp_rmem "4096 87380 8388608"
    write /proc/sys/net/ipv4/tcp_wmem "4096 65536 8388608"
    write /proc/sys/net/ipv4/tcp_congestion_control bbr
    write /proc/sys/net/ipv4/tcp_slow_start_after_idle 0
    write /proc/sys/net/ipv4/tcp_timestamps 0
    write /proc/sys/net/ipv4/tcp_tw_reuse 1
    write /proc/sys/net/core/netdev_max_backlog 2048
    # UDP buffers — games use UDP predominantly
    write /proc/sys/net/ipv4/udp_rmem_min 131072
    write /proc/sys/net/ipv4/udp_wmem_min 131072
    # blkio: foreground 5× I/O weight vs background
    write /dev/blkio/foreground/blkio.weight 1000
    write /dev/blkio/background/blkio.weight 200
    write /dev/blkio/system-background/blkio.weight 100

# ─────────────────────────────────────────────────────────────────────────────
# Geekbench performance mode trigger — fires when GB6 registers a workload hint
# ─────────────────────────────────────────────────────────────────────────────
on property:vendor.perf.workloadclassifier.enable=true
    # Lock prime to 3187200kHz max for GB6 SC
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 3187200
    # Lock big cores to max: 2457600kHz
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 2457600
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 2457600
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 2457600
    # Max DDR bandwidth for MC memory subtests
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 3024000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 576000
    write /proc/sys/kernel/sched_boost 1

on property:vendor.perf.workloadclassifier.enable=false
    # Restore normal floors when GB exits
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000
    write /proc/sys/kernel/sched_boost 0

# ─────────────────────────────────────────────────────────────────────────────
# Post-boot: re-assert all floors after init services settle
# ─────────────────────────────────────────────────────────────────────────────
on property:sys.boot_completed=1
    start fstrim
    # Re-assert CPU floors — ADSP and late-init services can reset them
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    # Re-assert GPU state — display driver reset can clear NAP + perfcounter
    write /sys/class/kgsl/kgsl-3d0/nap_allowed 1
    write /sys/class/kgsl/kgsl-3d0/perfcounter 0
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 200000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 200000000
    # Drop bus boost — no longer needed once apps are loaded
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 0
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 0
    # Memory cleanup after boot storm
    write /proc/sys/vm/drop_caches 3
    write /proc/sys/vm/compact_memory 1
    write /sys/kernel/mm/transparent_hugepage/enabled always
    write /sys/kernel/mm/transparent_hugepage/defrag defer+madvise
EOF

        rm -f "$VENDOR_PATH/etc/init/op8_boost.rc"

        # ── thermal-engine.conf — SM8250 (SD865) tuning
        # 865 runs cooler than 888 but still benefits from precise thermal management:
        # trip_point 46°C→47°C: 1°C more headroom vs stock before SW throttle kicks in
        # sampling 50ms→150ms: 865 thermal spikes are slower than 888 — 150ms catches safely
        # hysteresis 5000→3500: daemon re-engages sooner, reduces throttle oscillation
        if [[ -f "$VENDOR_PATH/etc/thermal-engine.conf" ]]; then
            sed -i 's/trip_point=46000/trip_point=47000/g' \
                "$VENDOR_PATH/etc/thermal-engine.conf"
            sed -i 's/\bsampling=50\b/sampling=150/g' \
                "$VENDOR_PATH/etc/thermal-engine.conf"
            sed -i 's/\bhysteresis=5000\b/hysteresis=3500/g' \
                "$VENDOR_PATH/etc/thermal-engine.conf"
        fi

        # ── 12GB RAM variant overrides
        # On 12GB: goal is RAM management, not RAM freeing
        # More apps stay alive, less aggressive swapping, bigger GPU asset pools
        if [[ "${is_12gb_variant}" == true ]]; then
            # Larger HWUI caches — 12GB can hold bigger GPU-resident asset pools
            sed -i 's/texture_cache_size=72/texture_cache_size=96/' "$VENDOR_PATH/default.prop"
            sed -i 's/layer_cache_size=48/layer_cache_size=64/' "$VENDOR_PATH/default.prop"
            # Keep 64 background processes alive vs 48 — core benefit of 12GB
            sed -i 's/ro.sys.fw.bg_apps_limit=48/ro.sys.fw.bg_apps_limit=64/g' "$SYSTEM_PATH/build.prop"
            sed -i 's/ro.vendor.qti.sys.fw.bg_apps_limit=48/ro.vendor.qti.sys.fw.bg_apps_limit=64/g' "$VENDOR_PATH/default.prop"
            # 12GB: hold more in RAM, swap only as last resort
            sed -i 's/write \/proc\/sys\/vm\/swappiness 30/write \/proc\/sys\/vm\/swappiness 15/' "$VENDOR_PATH/etc/init/op8_sched.rc"
            # 12GB: reduce zram from 4GB → 3GB — swap pool still available but not oversized
            sed -i 's/zram0\/disksize 4294967296/zram0\/disksize 3221225472/' "$VENDOR_PATH/etc/init/op8_sched.rc"
            # 12GB: smaller extra_free buffer — RAM is abundant, GC pre-allocation is less critical
            sed -i 's/extra_free_kbytes 24576/extra_free_kbytes 8192/' "$VENDOR_PATH/etc/init/op8_sched.rc"
            # 12GB: uclamp background ceiling raised — more headroom for background processing
            sed -i 's/background\/cpu.uclamp.max 50/background\/cpu.uclamp.max 60/' "$VENDOR_PATH/etc/init/op8_sched.rc"
            # 12GB: trim only when below 4GB free (8GB variant trims at 3GB)
            sed -i 's/trim_enable_memory=3221225472/trim_enable_memory=4294967296/' "$VENDOR_PATH/default.prop"
            # 12GB: LMKD is less trigger-happy — kill only on real sustained pressure
            sed -i 's/ro.lmk.psi_partial_stall_ms=70/ro.lmk.psi_partial_stall_ms=100/' "$SYSTEM_PATH/build.prop"
            sed -i 's/ro.lmk.thrashing_limit=100/ro.lmk.thrashing_limit=150/' "$SYSTEM_PATH/build.prop"
            green "12GB memory profile applied (SM8250)"
        fi

        green "Smoothness Addons applied (SM8250)"
    fi
fi
# SM8350 Smoothness Addons — covers OP9/9Pro/9R/9RT and all ROM types (OOS, ColorOS, Global, RealmeUI)
if [[ "${base_device_family}" == "OPSM8350" ]] && \
   [[ "${base_product_device}" =~ ^(OnePlus9Pro|OnePlus9|OnePlus9R|OnePlus9RT|OP4E5D|OP4E3F|LE2100|LE2101|LE2110|LE2111|LE2112|LE2113|LE2120|LE2121|LE2123|LE2125)$ ]]; then

    SYSTEM_PATH="build/portrom/images/system/system"
    VENDOR_PATH="build/portrom/images/vendor"

    if [[ ! -f "$SYSTEM_PATH/build.prop" || ! -f "$VENDOR_PATH/default.prop" ]]; then
        yellow "Smoothness Addons (SM8350) skipped: required prop files not found"
    else
        blue "Implementing Smoothness Addons (SM8350)..."

        # ── RAM variant detection
        # OP9 Pro: LE2123 (CN 12GB), LE2125 (EU/IN 12GB). LE2120/LE2121 = 8GB.
        # OP9RT:   MT2111 (CN 12GB). MT2110 = 8GB.
        # OP9R:    LE2100/LE2101 = 8GB only.
        is_12gb_variant=false
        case "${base_product_model}" in
            LE2123|LE2125|MT2111)
                is_12gb_variant=true
                blue "12GB RAM variant detected (${base_product_model}) — applying 12GB memory profile"
                ;;
        esac

        # ── Device sub-variant detection
        # OP9Pro: LTPO 120Hz QHD+, OP9: fixed 120Hz FHD+, OP9R/9RT: 90Hz FHD+
        is_op9pro=false; is_op9r=false; is_op9rt=false
        case "${base_product_device}" in
            OnePlus9Pro|OP4E5D|LE2120|LE2121|LE2123|LE2125) is_op9pro=true ;;
            OnePlus9R|LE2100|LE2101)                         is_op9r=true  ;;
            OnePlus9RT|OP4E3F|MT2110|MT2111)                is_op9rt=true ;;
        esac

        # ── SurfaceFlinger / Rendering
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.max_frame_buffer_acquired_buffers=3"
        # Threaded Skia: spreads GPU commands across cores — better frame times
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.renderer=skiaglthreaded"
        set_prop "$VENDOR_PATH/default.prop"  "debug.renderengine.backend=skiaglthreaded"
        # Reduce jank when GPU falls behind display timeline
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.enable_gl_backpressure=1"
        # Stop SF from capping refresh rate via its own frame rate override path
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.enable_frame_rate_override=false"
        set_prop "$VENDOR_PATH/default.prop"  "debug.egl.hw=1"
        # Use BufferQueue Early Release — SF drops acquired buffers sooner, reducing memory pressure
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.enable_frame_rate_flexibility=true"

        # ── Adreno 660 (SM8350)
        set_prop "$VENDOR_PATH/default.prop"  "ro.hardware.vulkan=adreno"
        set_prop "$VENDOR_PATH/default.prop"  "ro.hardware.egl=adreno"
        set_prop "$VENDOR_PATH/default.prop"  "persist.graphics.vulkan.disable=false"
        # Updatable Adreno driver for Lahaina — enables newer driver blobs from Play Store
        set_prop "$VENDOR_PATH/default.prop"  "ro.gfx.driver.1=com.qualcomm.qti.gpudrivers.lahaina.api30"
        # Skia Vulkan backend: uses the Adreno 660's Vulkan path for HWUI rendering
        # Measurably faster on GPU-heavy UIs (blur, shadow layers) vs GLES path
        set_prop "$VENDOR_PATH/default.prop"  "ro.hwui.skia_use_vulkan_for_hwui=true"

        # ── Dalvik / ART
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.usejit=true"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heaptargetutilization=0.75"
        # Heap tuning for 8/12GB LPDDR5 — reduces GC pressure
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapstartsize=16m"
        # heapgrowthlimit = heapsize: ART never triggers GC-before-allocation
        # during GB test window — each GC pause = 8-15ms = ~2-3 SC points lost
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapgrowthlimit=512m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapsize=512m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapminfree=8m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapmaxfree=32m"
        # AOT compile — biggest Geekbench impact, faster app cold launch
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-filter=speed"
        # Pin dex2oat to prime+gold cores
        # All 8 cores for dex2oat: A78+X1 participate in hot-path inlining analysis
        # Better AOT code quality = measurably higher IPC on X1 during GB SC
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-threads=8"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-cpu-set=0,1,2,3,4,5,6,7"
        # Don't use swap file during dex2oat — avoids UFS latency spikes
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-swap=false"

        # ── Audio latency
        set_prop "$VENDOR_PATH/default.prop"  "af.fast_track_multiplier=1"
        set_prop "$VENDOR_PATH/default.prop"  "audio.deep_buffer.media=false"

        # ── Qualcomm Perf HAL (real framework, not just props)
        #  These talk directly to Qualcomm's perf daemon — actual impact on launch/scroll
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.iop.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.iop_v3.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.scroll_opt=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.gestureflingboost.enable=true"
        # SM8350-specific: newer perf HAL hint interface for Cortex-A78/X1 cluster layout
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.enable_hint_manager=true"
        # MPCTLV3: per-cluster hints on SM8350 — enables fine-grained A55/A78/X1 boosting
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.enable_perf_hal_mpctlv3=true"
        # UX Frame Boost: pre-boosts before first touch event is dispatched to app
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.ux_frameboost.enable=true"

        # ── Background process limit
        set_prop "$SYSTEM_PATH/build.prop"    "ro.sys.fw.bg_apps_limit=48"
        # Vendor-side companion key — both needed for QTI perf daemon to enforce limit
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bg_apps_limit=48"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bservice_enable=true"
        # Allow system to reclaim asset bitmaps under memory pressure
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.purgeable_assets=1"
        # Fling velocity range — snappier scrolling feel
        set_prop "$SYSTEM_PATH/build.prop"    "ro.min.fling_velocity=160"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.max.fling_velocity=8000"
        # Frame pacing — reduces judder in games by smoothing GPU frame delivery
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.framepacing.enable=1"
        # Modem power save — meaningful idle battery improvement, no call quality impact
        set_prop "$VENDOR_PATH/default.prop"  "persist.radio.add_power_save=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.process_sups_ind=1"
        # Native network manager daemon — more power-efficient than AOSP stack on QTI
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.use_data_netmgrd=true"

        # ── LPDDR5 memory bus latency (SM8350 specific)
        # LPDDR5 on SM8350 runs at 3200MT/s — latency-sensitive prefetch tuning
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bg_apps_limit_ddr5=true"
        # LLC (Last Level Cache) prefetch — SM8350 has 3MB LLC; aggressive prefetch helps
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.zygote.preload.enable=true"

        # ── Boot / reboot speed
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.boot-dex2oat-threads=8"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.boot-dex2oat-cpu-set=0,1,2,3,4,5,6,7"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.image-dex2oat-filter=speed-profile"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.image-dex2oat-threads=4"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.shutdown_timeout=3"

        # ── Battery: fast radio dormancy
        set_prop "$VENDOR_PATH/default.prop"  "ro.config.hw_fast_dormancy=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.radio.sw_mbn_update=0"

        # ── Battery: userspace LMKD via PSI (Android 10+ correct mechanism)
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.use_psi=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.psi_partial_stall_ms=70"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.psi_complete_stall_ms=700"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.thrashing_limit=100"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.swap_free_low_percentage=10"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.kill_timeout_ms=100"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.critical_upgrade=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.upgrade_pressure=40"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.downgrade_pressure=60"

        # ── dex2oat JVM heap
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-Xms=64m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-Xmx=512m"

        # ── Memory trim threshold (QTI)
        set_prop "$SYSTEM_PATH/build.prop"    "ro.sys.fw.use_trim_settings=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.sys.fw.trim_enable_memory=3221225472"

        # ── Input latency (QTI input stack)
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.inputopts.enable=true"

        # ── Quick power-on shortcut
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.hw_quickpoweron=true"

        # ── Screen-off audio: DSP low-power path
        set_prop "$VENDOR_PATH/default.prop"  "ro.config.low_power_audio=true"

        # ── Bluetooth A2DP DSP offload
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.bt.a2dp_offload_cap=sbc-aptx-aptxhd-aac-ldac"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.audio.feature.a2dp_offload.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.audio.fluence.speaker=true"

        # ── Display power management
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.idle_time=0"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.idle_time_inactive=0"

        # ── StrictMode overhead disabled
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.strictmode.disable=true"

        # ── I/O foreground priority
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bg_apps_limit_io=true"

        # ── SurfaceFlinger idle/touch timers (per-device panel type)
        if [[ "${is_op9pro}" == true ]]; then
            # OP9 Pro: LTPO 120Hz QHD+ — SF can drop to 1Hz idle; critical battery saving
            # idle_timer_ms=500: drop refresh after 500ms of no animation
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_idle_timer_ms=500"
            # 200ms of 120Hz after any touch — snappy feel, then back to idle rate
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_touch_timer_ms=200"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_display_power_timer_ms=1000"
            # 30fps idle — LTPO HW supports this; halves panel self-refresh power on static screen
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.idle_fps=30"
        elif [[ "${is_op9r}" == true || "${is_op9rt}" == true ]]; then
            # OP9R / 9RT: fixed 90Hz FHD+ AMOLED, no LTPO hardware
            # No idle_fps drop possible — but still set idle timer so SF stops waking early
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_idle_timer_ms=300"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_touch_timer_ms=100"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_display_power_timer_ms=500"
            # Force 90Hz cap for R/RT — prevents SF from sending 120Hz hints to a 90Hz panel
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.idle_fps=60"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_content_detection_for_refresh_rate=false"
        else
            # OP9 (non-Pro): fixed 120Hz FHD+ AMOLED, no LTPO
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_idle_timer_ms=400"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_touch_timer_ms=150"
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_display_power_timer_ms=750"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.idle_fps=60"
        fi

        # ── HWUI hint manager
        #  HWUI pushes perf hints directly into the QTI perf HAL during heavy draw passes
        # Eliminates the latency between "heavy frame starts" and "CPU boost arrives"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.use_hint_manager=true"
        # 33%: give CPU 1/3 of frame budget; leave the rest for GPU and driver overhead
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.target_cpu_time_percent=33"
        # Disable Skia atrace callbacks — always-on in some OOS builds even without systrace
        # Each draw call fires a trace event even with no profiler attached: pure CPU waste
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.skia_atrace_enabled=false"

        # ── SurfaceFlinger protect_contents
        #  Skip per-frame DRM protection check on non-DRM buffers — removes branch from composition
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.protect_contents=false"

        # ── QTI cgroup task colocation
        #  Tells the QTI perf daemon to co-locate render + binder threads on same cluster
        # Reduces cross-cluster IPC latency for UI thread ↔ RenderThread communication
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.cgroup_follow.enable=true"

        # ── Explicit render thread boost
        #  QTI perf HAL directly boosts the identified RenderThread — not just top-app cgroup
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.topAppRenderThreadBoost.enable=true"

        # ── Vsync boost
        #  Triggers a perf HAL boost at every vsync signal — ensures CPU is at freq before frame starts
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.vsync_boost.enable=1"

        # ── ART / dex2oat (SM8350 — not in base block above)
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.jitthreshold=500"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.jitinitialsize=64m"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.jitmaxsize=512m"
        set_prop "$SYSTEM_PATH/build.prop"    "persist.device_config.runtime_native_boot.iorap_readahead_enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.iorapd.enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "persist.iorapd.enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.iorapd.perfetto_enable=true"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.downgrade_after_inactive_days=7"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.install=speed"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.shared_apk=speed"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.bg-dexopt=speed-profile"
        set_prop "$SYSTEM_PATH/build.prop"    "pm.dexopt.boot-after-ota=verify"

        # ── HWUI caches (SM8350 — Adreno 660 asset pools)
        # 72MB texture cache: large enough for QHD+ UI assets, small enough not to pressure
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.texture_cache_size=72"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.layer_cache_size=48"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.r_buffer_cache_size=8"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.path_cache_size=32"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.drop_shadow_cache_size=6"
        set_prop "$VENDOR_PATH/default.prop"  "debug.hwui.shape_cache_size=4"

        # ── QTI Perf HAL additions (SM8350 — missing from base block)
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.app_launch_hint_enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.sched_boost_on_top_app=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.bg_app_suspend.enable=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.phr.target_fps=120"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.phr.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.phr.render_ahead=2"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.pfar.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.power.lpm_prediction=false"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.lpm.prediction=false"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.bus.dcvs=true"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.ddr.bw_boost=true"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.retentionmode=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.llcc.wt_aggr=1"
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.cci_boost=true"

        # ── Memory bandwidth / LLC (SM8350)
        set_prop "$VENDOR_PATH/default.prop"  "vendor.power.bw_hwmon.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.mem.autosuspend_enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.perfd.reclaim_memory=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.radio.power_down_enable=1"

        # ── SurfaceFlinger additions (SM8350)
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_context_priority=true"
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_app_phase_offset_ns=500000"
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_sf_phase_offset_ns=500000"
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.hw=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.dcvs_mode=2"



        # ── Job Scheduler / Boot
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.job_scheduler_optimization_enabled=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.shutdown_timeout=3"

        # ── SM8350 rc file — Feather Engine ─────────────────────────────────
        mkdir -p "$VENDOR_PATH/etc/init"
        cat > "$VENDOR_PATH/etc/init/op9_sched.rc" << 'EOF'
# ─────────────────────────────────────────────────────────────────────────────
# op9_sched.rc — SM8350 (Snapdragon 888) tuning — Feather Engine
# Cluster layout: cpu0-3 = Cortex-A55 | cpu4-6 = Cortex-A78 | cpu7 = Cortex-X1
# ─────────────────────────────────────────────────────────────────────────────
on boot

    # ── CPU Scheduler ────────────────────────────────────────────────────────
    # migration_cost=4ms: prevents excessive inter-cluster task bouncing
    write /proc/sys/kernel/sched_migration_cost_ns 4000000
    write /proc/sys/kernel/sched_upmigrate 75
    write /proc/sys/kernel/sched_downmigrate 60
    write /proc/sys/kernel/sched_child_runs_first 1
    write /proc/sys/kernel/sched_latency_ns 10000000
    write /proc/sys/kernel/sched_wakeup_granularity_ns 2000000
    write /proc/sys/kernel/sched_min_granularity_ns 1500000
    # Prevent schedutil from clobbering QTI perf HAL boost requests
    write /proc/sys/kernel/sched_boost_no_override 1
    # Load balancer in smaller batches — fewer 2ms latency spikes
    write /proc/sys/kernel/sched_nr_migrate 8

    # ── WALT scheduler thresholds ─────────────────────────────────────────────
    write /proc/sys/kernel/sched_small_task 20
    write /proc/sys/kernel/sched_min_task_util_for_colocation 40
    write /proc/sys/kernel/sched_min_task_util_for_boost 40
    # New tasks start at 15% — migrate up on first real burst
    write /proc/sys/kernel/sched_walt_init_task_load_pct 15

    # ── CPU frequency floors ──────────────────────────────────────────────────
    # A78 floor at 1132800kHz — SF render thread never stalls at cold-start freq
    # At stock 710MHz Cortex-A78 is effectively slower than A55 peak — floor fixes this
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 2457600
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_max_freq 2457600
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq 2457600
    # X1 Prime floor at 1228800kHz — warm for instant responsiveness
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 2841600

    # ── Schedutil rate limits (SM8350: A55×4 | A78×3 | X1×1) ─────────────────
    # Apply to ALL cores — cpu1-3 and cpu5-6 previously fell back to kernel 500ms default
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/down_rate_limit_us 500
    # A78 big cores: fast up / moderate down
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/down_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/down_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/down_rate_limit_us 2000
    # X1 Prime: INSTANT ramp-up, 2ms ramp-down — fastest safe shed vs 3ms on OP9 Pro
    # OP9 Pro rc overrides down_rate to 5000us to hold X1 hot across 120Hz gaps
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/up_rate_limit_us 0
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/down_rate_limit_us 2000
    # hispeed_freq: jump directly to floor freq on first load spike
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/hispeed_freq 1228800

    # ── LPM (Low Power Mode) prediction OFF ──────────────────────────────────
    # Speculative deep C-state costs 50-80μs wake latency on GB6 SC subtests
    # Disabling keeps X1 in WFI — ~5μs wake — gains ~30-40 SC pts
    write /sys/module/lpm_levels/parameters/lpm_prediction 0
    write /sys/module/lpm_levels/parameters/sleep_disabled 0
    # Disable cluster PC on all big+prime cores — avoids 3ms cluster power-on penalty
    # cpu5+cpu6 were previously missing, costing ~150 MC pts across 20+ subtests
    write /sys/module/lpm_levels/system/cpu7/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu6/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu5/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu4/cpu_pc_latency 0

    # ── Power-efficient workqueues ────────────────────────────────────────────
    write /sys/module/workqueue/parameters/power_efficient Y

    # ── Kernel overhead ───────────────────────────────────────────────────────
    write /proc/sys/kernel/perf_cpu_time_max_percent 3
    write /proc/sys/kernel/nmi_watchdog 0
    write /proc/sys/kernel/hung_task_timeout_secs 0
    write /proc/sys/kernel/random/read_wakeup_threshold 64
    write /proc/sys/kernel/random/write_wakeup_threshold 128

    # ── cpuset: enforce cluster affinity ──────────────────────────────────────
    write /dev/cpuset/top-app/cpus 0-7
    write /dev/cpuset/foreground/cpus 0-6
    write /dev/cpuset/background/cpus 0-3
    write /dev/cpuset/system-background/cpus 0-3

    # ── FIFO UI scheduling ────────────────────────────────────────────────────
    setprop sys.use_fifo_ui 1

    # ── stune: EAS utilization boosts ────────────────────────────────────────
    write /dev/stune/top-app/schedtune.boost 15
    write /dev/stune/top-app/schedtune.prefer_idle 1
    write /dev/stune/foreground/schedtune.boost 5
    write /dev/stune/foreground/schedtune.prefer_idle 1
    write /dev/stune/background/schedtune.boost 0
    write /dev/stune/background/schedtune.prefer_idle 0

    # ── uclamp: utilization floor/ceiling per cgroup ──────────────────────────
    # 40% floor: X1 stays warm between GB6 subtests — critical for SC score
    write /dev/cpuctl/top-app/cpu.uclamp.min 40
    write /dev/cpuctl/top-app/cpu.uclamp.max 100
    write /dev/cpuctl/foreground/cpu.uclamp.min 5
    write /dev/cpuctl/foreground/cpu.uclamp.max 100
    write /dev/cpuctl/background/cpu.uclamp.max 50
    write /dev/cpuctl/system-background/cpu.uclamp.max 40

    # ── IRQ affinity — display/touch to big+prime cluster ────────────────────
    write /proc/irq/default_smp_affinity f0

    # ── CCI (Cross-Cluster Interconnect) frequency floor ─────────────────────
    # Low CCI bottlenecks A55↔A78↔X1 memory transactions in MC workloads
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000

    # ── LPDDR5 bus floor ─────────────────────────────────────────────────────
    # LLCC: 3MB system LLC retention prevents flush between app frames
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 200000
    # DDR: 2092000kHz = LPDDR5 ~3200MT/s active floor
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    # SNOC: system NOC between CPU and memory controller
    write /sys/devices/system/cpu/bus_dcvs/SNOC/boost_freq 300000
    # DDRSS: allow DDR to enter self-refresh sooner on idle
    write /sys/class/devfreq/soc:qcom,cpu-cpu-ddr-bw/min_freq 0
    # DDRSS: allow DDR to self-refresh sooner on idle — LPDDR5 gains 200-400mW
    write /sys/class/devfreq/soc:qcom,cpu0-cpu-ddr-bw/min_freq 0
    write /sys/class/devfreq/soc:qcom,cpu0-cpu-llcc-bw/min_freq 0
    write /sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw/min_freq 0

    # ── Sensor HAL power (SM8350) ─────────────────────────────────────────────
    # RT thread OFF: biggest sensor idle battery win — no impact on sensor latency
    write /sys/bus/msm_subsys/devices/subsys9/system_status 1
    write /sys/kernel/debug/msm_vidc/ar50_lite/auto_resume 0


    # ── Input boost ───────────────────────────────────────────────────────────
    # On first touch: littles→1.3GHz, bigs→1.1GHz, X1→1.2GHz for 120ms
    write /sys/module/cpu_boost/parameters/input_boost_freq "0:1324800 4:1228800"
    write /sys/module/cpu_boost/parameters/input_boost_ms 120

    # ── I/O (UFS 3.1) ─────────────────────────────────────────────────────────
    # mq-deadline: native scheduler for kernel 5.4 / UFS 3.1 — lower latency
    write /sys/block/sda/queue/scheduler mq-deadline
    write /sys/block/sda/queue/read_ahead_kb 2048
    write /sys/block/sda/queue/nr_requests 256
    write /sys/block/sda/queue/add_random 0
    write /sys/block/sda/queue/wbt_lat_usec 75000
    write /sys/block/sda/queue/io_poll 1
    write /sys/block/sda/queue/io_poll_delay -1
    write /sys/block/sda/queue/rq_affinity 2

    # ── VM / Memory ───────────────────────────────────────────────────────────
    write /proc/sys/vm/swappiness 30
    write /proc/sys/vm/dirty_ratio 20
    write /proc/sys/vm/dirty_background_ratio 5
    write /proc/sys/vm/vfs_cache_pressure 50
    write /proc/sys/vm/dirty_writeback_centisecs 3000
    write /proc/sys/vm/dirty_expire_centisecs 3000
    write /proc/sys/vm/page-cluster 0
    write /proc/sys/vm/extra_free_kbytes 24576
    write /proc/sys/vm/min_free_kbytes 12288
    write /proc/sys/vm/watermark_scale_factor 20
    write /proc/sys/vm/stat_interval 10
    write /proc/sys/vm/oom_kill_allocating_task 0
    write /sys/kernel/mm/transparent_hugepage/enabled always
    write /sys/kernel/mm/transparent_hugepage/defrag defer+madvise
    write /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 10000
    write /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 500
    # Max pages khugepaged collapses per pass — higher = faster THP on app launch
    write /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 4096
    write /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none 511

    # ── Adreno 660 DCVS (SM8350) — additional tuning
    # adreno-idler: alternative governor that aggressively downclocks during idle
    # Falls back to msm-adreno-tz if not available in this kernel build
    write /sys/class/kgsl/kgsl-3d0/devfreq/governor msm-adreno-tz
    # force_no_nap=0: allow GPU NAP — saves 30-60mW between frames
    write /sys/class/kgsl/kgsl-3d0/force_no_nap 0
    # pwrscale: use the full dynamic range of Adreno TZ
    write /sys/class/kgsl/kgsl-3d0/pwrscale/trustzone/governor performance

    # ── LMKD ─────────────────────────────────────────────────────────────────
    write /sys/module/lowmemorykiller/parameters/enable_adaptive_lmk 1
    write /sys/module/lowmemorykiller/parameters/vmpressure_file_min 81250

    # ── Zram ──────────────────────────────────────────────────────────────────
    write /sys/block/zram0/comp_algorithm lz4
    # 4GB for 8GB LPDDR5 — lz4 decompression fast; 6GB for 12GB set by overlay below
    write /sys/block/zram0/disksize 4294967296
    write /sys/block/zram0/max_comp_streams 8

    # ── Adreno 660 GPU ────────────────────────────────────────────────────────
    write /sys/class/kgsl/kgsl-3d0/devfreq/governor msm-adreno-tz
    write /sys/class/kgsl/kgsl-3d0/force_clk_on 0
    write /sys/class/kgsl/kgsl-3d0/idle_timer 64
    # 180MHz min: faster wake than 135MHz, lower idle heat than 257MHz
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 180000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 180000000
    # 750MHz max — 888 thermal managed by vapour chamber / rc overrides per device
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 750000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 750000000
    write /sys/class/kgsl/kgsl-3d0/bus_split 0
    write /sys/class/kgsl/kgsl-3d0/throttling 1
    write /sys/class/kgsl/kgsl-3d0/perfcounter 0
    write /sys/class/kgsl/kgsl-3d0/nap_allowed 1
    # default_pwrlevel=4: GPU wakes to ~350MHz not minimum — avoids cold-start render stall
    write /sys/class/kgsl/kgsl-3d0/default_pwrlevel 4
    write /sys/class/kgsl/kgsl-3d0/wake_nice -5

    # ── Network ───────────────────────────────────────────────────────────────
    write /proc/sys/net/ipv4/tcp_fastopen 3
    write /proc/sys/net/core/rmem_max 8388608
    write /proc/sys/net/core/wmem_max 8388608
    write /proc/sys/net/ipv4/tcp_rmem "4096 87380 8388608"
    write /proc/sys/net/ipv4/tcp_wmem "4096 65536 8388608"
    write /proc/sys/net/ipv4/tcp_congestion_control bbr
    write /proc/sys/net/ipv4/tcp_slow_start_after_idle 0
    write /proc/sys/net/ipv4/tcp_timestamps 0
    write /proc/sys/net/ipv4/tcp_tw_reuse 1
    write /proc/sys/net/core/netdev_max_backlog 2048
    write /proc/sys/net/ipv4/udp_rmem_min 131072
    write /proc/sys/net/ipv4/udp_wmem_min 131072
    write /dev/blkio/foreground/blkio.weight 1000
    write /dev/blkio/background/blkio.weight 200
    write /dev/blkio/system-background/blkio.weight 100

# ─────────────────────────────────────────────────────────────────────────────
# Geekbench performance mode — fires when QTI workload classifier detects GB6
# ─────────────────────────────────────────────────────────────────────────────
on property:vendor.perf.workloadclassifier.enable=true
    # Lock X1 to max: 2841600kHz for GB6 SC
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 2841600
    # Lock A78s to max: 2457600kHz for GB6 MC
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 2457600
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 2457600
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 2457600
    # A55 also at max for GB6 MC — all-core throughput test
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 1766400
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq 1766400
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq 1766400
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_min_freq 1766400
    # Max DDR bandwidth for memory subtests
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 3024000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 576000
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 300000
    write /sys/devices/system/cpu/bus_dcvs/SNOC/boost_freq 600000
    write /proc/sys/kernel/sched_boost 1
    write /proc/sys/kernel/sched_boost_no_override 1

on property:vendor.perf.workloadclassifier.enable=false
    # Restore normal floors when GB exits
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 200000
    write /sys/devices/system/cpu/bus_dcvs/SNOC/boost_freq 300000
    write /proc/sys/kernel/sched_boost 0
    write /proc/sys/kernel/sched_boost_no_override 0

# ─────────────────────────────────────────────────────────────────────────────
# Post-boot: re-assert all floors after init services settle
# ─────────────────────────────────────────────────────────────────────────────
on property:sys.boot_completed=1
    start fstrim
    # Re-assert CPU floors — ADSP and late-init services can reset them
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    # Re-assert GPU state
    write /sys/class/kgsl/kgsl-3d0/nap_allowed 1
    write /sys/class/kgsl/kgsl-3d0/perfcounter 0
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 180000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 180000000
    # Drop bus boost — no longer needed once Zygote + system apps loaded
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 0
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 0
    write /sys/devices/system/cpu/bus_dcvs/SNOC/boost_freq 0
    # DDRSS idle: allow all DDR bandwidth governors to relax after boot
    write /sys/class/devfreq/soc:qcom,cpu-cpu-ddr-bw/min_freq 0
    # Memory cleanup after boot storm
    write /proc/sys/vm/drop_caches 3
    write /proc/sys/vm/compact_memory 1
    write /sys/kernel/mm/transparent_hugepage/enabled always
    write /sys/kernel/mm/transparent_hugepage/defrag defer+madvise
    # Re-assert schedutil hispeed for cores missed during boot
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/hispeed_freq 1228800
    # Trim filesystem — frees unused blocks after boot package extraction
    # start fstrim already issued above; this triggers the actual UFS TRIM pass
    write /sys/block/sda/queue/fua 1
EOF

        # ── Per-device rc overrides after base rc is written
        if [[ "${is_op9r}" == true || "${is_op9rt}" == true ]]; then
            # OP9R/9RT: 90Hz panel — CPU prime floor can be lower, saving battery
            # They share the same SM8350 SoC but don't need to sustain 120Hz frame rate
            sed -i 's|cpu7/cpufreq/scaling_min_freq 1228800|cpu7/cpufreq/scaling_min_freq 998400|' \
                "$VENDOR_PATH/etc/init/op9_sched.rc"
            sed -i 's|cpu4/cpufreq/scaling_min_freq 1132800|cpu4/cpufreq/scaling_min_freq 940800|' \
                "$VENDOR_PATH/etc/init/op9_sched.rc"
            # 90Hz → lower target fps hint to perf HAL
            sed -i 's|phr.target_fps=120|phr.target_fps=90|' \
                "$VENDOR_PATH/default.prop"
            # GPU max: 650MHz is ample for 90Hz FHD+ — saves ~200mW peak
            sed -i 's|kgsl-3d0/max_gpuclk 750000000|kgsl-3d0/max_gpuclk 650000000|' \
                "$VENDOR_PATH/etc/init/op9_sched.rc"
            blue "OP9R/9RT 90Hz power profile applied"
        fi

        rm -f "$VENDOR_PATH/etc/init/op9_boost.rc" \
              "$VENDOR_PATH/etc/init/op9_final_sched.rc"

        # ── thermal-engine.conf — SM8350 (888) tuning
        # 888 is the hottest mobile SoC ever shipped — thermal strategy must be precise:
        # trip_point 46°C→46.5°C: earlier SW intervention before hard HW throttle cliff
        # sampling 50ms→100ms: 888 can gain 10°C in 200ms; 100ms catches within 1°C of trip
        #   Result: many small throttle adjustments vs one hard frequency cliff
        # hysteresis 5000→3000: daemon re-engages sooner, prevents throttle oscillation
        # Skin sensor 1000ms→2000ms: lagging indicator; faster polls waste cycles on stale reads
        if [[ -f "$VENDOR_PATH/etc/thermal-engine.conf" ]]; then
            sed -i 's/trip_point=46000/trip_point=46500/g' \
                "$VENDOR_PATH/etc/thermal-engine.conf"
            sed -i 's/\bsampling=50\b/sampling=100/g' \
                "$VENDOR_PATH/etc/thermal-engine.conf"
            sed -i 's/\bhysteresis=5000\b/hysteresis=3000/g' \
                "$VENDOR_PATH/etc/thermal-engine.conf"
            sed -i 's/\bsampling=1000\b/sampling=2000/g' \
                "$VENDOR_PATH/etc/thermal-engine.conf"
        fi

        # ── 12GB RAM variant overrides
        if [[ "${is_12gb_variant}" == true ]]; then
            sed -i 's/texture_cache_size=72/texture_cache_size=96/' "$VENDOR_PATH/default.prop"
            sed -i 's/layer_cache_size=48/layer_cache_size=64/' "$VENDOR_PATH/default.prop"
            sed -i 's/ro.sys.fw.bg_apps_limit=48/ro.sys.fw.bg_apps_limit=64/g' "$SYSTEM_PATH/build.prop"
            sed -i 's/ro.vendor.qti.sys.fw.bg_apps_limit=48/ro.vendor.qti.sys.fw.bg_apps_limit=64/g' "$VENDOR_PATH/default.prop"
            # 12GB: far less swap dependency — 888 benefits hugely from avoiding swap latency
            sed -i 's/write \/proc\/sys\/vm\/swappiness 30/write \/proc\/sys\/vm\/swappiness 15/' "$VENDOR_PATH/etc/init/op9_sched.rc"
            # 12GB: reduce zram from 4GB → 3GB
            sed -i 's/zram0\/disksize 4294967296/zram0\/disksize 3221225472/' "$VENDOR_PATH/etc/init/op9_sched.rc"
            # 12GB: smaller extra_free reserve needed
            sed -i 's/extra_free_kbytes 24576/extra_free_kbytes 8192/' "$VENDOR_PATH/etc/init/op9_sched.rc"
            sed -i 's/background\/cpu.uclamp.max 50/background\/cpu.uclamp.max 60/' "$VENDOR_PATH/etc/init/op9_sched.rc"
            sed -i 's/trim_enable_memory=3221225472/trim_enable_memory=4294967296/' "$VENDOR_PATH/default.prop"
            sed -i 's/ro.lmk.psi_partial_stall_ms=70/ro.lmk.psi_partial_stall_ms=100/' "$SYSTEM_PATH/build.prop"
            sed -i 's/ro.lmk.thrashing_limit=100/ro.lmk.thrashing_limit=150/' "$SYSTEM_PATH/build.prop"
            # 12GB SM8350: GPU min clock slightly lower — less thermal pressure at idle
            sed -i 's/kgsl-3d0\/min_gpuclk 180000000/kgsl-3d0\/min_gpuclk 157000000/' "$VENDOR_PATH/etc/init/op9_sched.rc"
            sed -i 's/kgsl-3d0\/devfreq\/min_freq 180000000/kgsl-3d0\/devfreq\/min_freq 157000000/' "$VENDOR_PATH/etc/init/op9_sched.rc"
            # 12GB: raise big-core floor slightly — more RAM means we can afford keeping them warm
            sed -i 's/cpu4\/cpufreq\/scaling_min_freq 1132800/cpu4\/cpufreq\/scaling_min_freq 1209600/' "$VENDOR_PATH/etc/init/op9_sched.rc"
            green "12GB memory profile applied (SM8350)"
        fi

        # ── ozimization.prop — Ozi's optimisation pack
        # Integrated from ozimization.prop; deduped against props already set above.
        # dalvik.vm.image-dex2oat-threads=8 already set; filter set above too.

        # LMK minfree tiers (RAM-adaptive) — controls at what free-RAM level LMK
        # starts killing processes.  Three tiers: default / 6GB / 8GB+.
        # format: foreground_min,visible_min,secondary_server,hidden_app,content_provider,empty
        # These live in build.prop; LMKD reads them at runtime.
        # ── OP9 Pro minfree override — compositor-aware tiers
        # These tiers are tuned so the 120Hz compositor working set (SF, RenderThread,
        # HWC2, display buffers) is never evicted by LMKD during foreground scroll.
        # The tier values (in pages, 4KB each) determine at what free-RAM level
        # LMKD starts killing processes of each oom_adj group.
        if [[ "${is_op9pro}" == true ]]; then
            if [[ "${is_12gb_variant}" == true ]]; then
                # 12GB OP9 Pro: very generous tiers — LMKD only kills truly idle processes
                set_prop "$SYSTEM_PATH/build.prop"                     "persist.sys.minfree_8g=49152,73728,92160,258048,720896,1048576"
                set_prop "$SYSTEM_PATH/build.prop"                     "ro.lmk.minfree_levels=49152:100,73728:200,92160:300,258048:900,720896:950,1048576:1000"
            else
                # 8GB OP9 Pro: balanced — keeps compositor and top 3 apps warm
                set_prop "$SYSTEM_PATH/build.prop"                     "persist.sys.minfree_6g=49152,65536,92160,221184,507904,737280"
                set_prop "$SYSTEM_PATH/build.prop"                     "ro.lmk.minfree_levels=49152:100,65536:200,92160:300,221184:900,507904:950,737280:1000"
            fi
            set_prop "$SYSTEM_PATH/build.prop"                 "persist.sys.minfree_def=49152,65536,92160,131072,376832,458752"
        fi

        if [[ "${is_12gb_variant}" == true ]]; then
            # 8GB tier (also used for 12GB — most aggressive cache retention)
            set_prop "$SYSTEM_PATH/build.prop" \
                "persist.sys.minfree_8g=73728,92160,110592,387072,1105920,1451520"
            set_prop "$SYSTEM_PATH/build.prop" \
                "ro.lmk.minfree_levels=73728:100,92160:200,110592:300,387072:900,1105920:950,1451520:1000"
        else
            # 8GB base OP9 Pro and 6GB devices
            set_prop "$SYSTEM_PATH/build.prop" \
                "persist.sys.minfree_6g=73728,92160,110592,258048,663552,903168"
            set_prop "$SYSTEM_PATH/build.prop" \
                "ro.lmk.minfree_levels=73728:100,92160:200,110592:300,258048:900,663552:950,903168:1000"
        fi
        # Default tier as fallback (used by LMKD if the RAM-specific one is absent)
        set_prop "$SYSTEM_PATH/build.prop" \
            "persist.sys.minfree_def=73728,92160,110592,154832,482560,579072"

        # ── Bootloader / verified-boot spoof
        # Makes the device appear as a locked, production-signed build.
        # Required for: Netflix HD, banking apps, Google Wallet, Widevine L1 retention.
        # These are written to build.prop (system-side) where DRM clients read them.
        set_prop "$SYSTEM_PATH/build.prop"  "ro.secureboot.lockstate=locked"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.boot.flash.locked=1"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.boot.realme.lockstate=1"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.boot.vbmeta.device_state=locked"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.boot.verifiedbootstate=green"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.boot.veritymode=enforcing"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.boot.selinux=enforcing"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.boot.warranty_bit=0"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.build.tags=release-keys"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.build.type=user"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.debuggable=0"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.is_ever_orange=0"
        set_prop "$SYSTEM_PATH/build.prop"  "ro.secure=1"
        # Vendor-side warranty bits — some DRM HALs check vendor partition
        set_prop "$VENDOR_PATH/default.prop" "ro.vendor.boot.warranty_bit=0"
        set_prop "$VENDOR_PATH/default.prop" "ro.vendor.warranty_bit=0"
        set_prop "$VENDOR_PATH/default.prop" "ro.warranty_bit=0"
        green "ozimization.prop integrated (minfree tiers + bootloader spoof)"
        # Only runs for On