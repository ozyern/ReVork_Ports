#!/bin/bash
# ColorOS_port project
# For A-only and V/A-B Devices
# Based on Android 14+
# Test Base ROM: OnePlus 9 Pro (OxygenOS_14.0.0.1920)
# Test Port ROM: OnePlus 15 (OxygenOS_16.0.3.501), OnePlus ACE3V(ColorOS_14.0.1.621) Realme GT Neo5 240W(RMX3708_14.0.0.800)
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
    val=$(grep "^${key}=" bin/port_config 2>/dev/null | cut -d '=' -f 2- | tr -d '[:space:]')
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
    target_display_id_show=$(grep "ro.build.display.id.show" build/portrom/images/my_manifest/build.prop \
        | awk 'NR==1' | cut -d'=' -f2- \
        | sed "s/${port_device_code}/${base_device_code}/g")
else
    target_display_id=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.id")
    target_display_id_show=$(grep "ro.build.display.id.show" build/portrom/images/my_manifest/build.prop \
        | awk 'NR==1' | cut -d'=' -f2-)
    yellow "port_device_code empty — display ID used as-is from portrom"
fi
# Fallback: if still empty, use product model as display ID
if [[ -z "$target_display_id" ]]; then
    target_display_id="${port_product_model}"
fi
base_vendor_brand=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.vendor.brand")
port_vendor_brand=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.vendor.brand")
base_product_first_api_level=$(get_prop build/baserom/images/my_manifest/build.prop "ro.product.first_api_level")
port_product_first_api_level=$(get_prop build/portrom/images/my_manifest/build.prop "ro.product.first_api_level")
base_device_family=$(get_prop build/baserom/images/my_product/build.prop "ro.build.device_family")
target_device_family=$(get_prop build/portrom/images/my_product/build.prop "ro.build.device_family")
portrom_version_security_patch=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.version.security_patch")
port_oplusrom_version=$(get_prop build/portrom/images/my_product/build.prop "ro.build.version.oplusrom.confidential")
regionmark=$(find build/portrom/images/ -name build.prop -exec grep -m1 "ro.vendor.oplus.regionmark=" {} \; -quit | cut -d'=' -f2)
base_regionmark=$(find build/baserom/images/ -name build.prop -exec grep -m1 "ro.vendor.oplus.regionmark=" {} \; -quit | cut -d '=' -f2)
if [ -z "$base_regionmark" ]; then
  base_regionmark=$(find build/baserom/images/ -name build.prop -exec grep -m1 "ro.oplus.image.my_region.type=" {} \; -quit | cut -d '=' -f2 | cut -d '_' -f1)
fi
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
sed -i "s/ro.vendor.oplus.market.enname=.*/ro.vendor.oplus.market.enname=${base_market_name}/g" build/portrom/images/my_manifest/build.prop
sed -i '/ro.oplus.watermark.betaversiononly.enable=/d' build/portrom/images/my_manifest/build.prop
BASE_PROP="${work_dir}/build/baserom/images/my_manifest/build.prop"
PORT_PROP="${work_dir}/build/portrom/images/my_manifest/build.prop"
KEYS="\.name= \.model= \.manufacturer= \.device= \.brand= \.my_product.type="
for k in $KEYS; do
    grep "$k" "$BASE_PROP" | while IFS='=' read -r key value; do
        if [[ "$key" == "ro.product.vendor.brand" ]]; then
            sed -i "s|^$key=.*|$key=OPPO|" "$PORT_PROP"
        elif grep -q "^$key=" "$PORT_PROP"; then
            sed -i "s|^$key=.*|$key=$value|" "$PORT_PROP"
        fi
    done
done
if [[ -n "$vendor_cpu_abilist32" ]] ;then
    sed -i "/ro.zygote=zygote64/d" build/portrom/images/my_manifest/build.prop
fi
vndk_version=""
while IFS= read -r prop_file; do
    vndk_version=$(grep "^ro.vndk.version=" "$prop_file" 2>/dev/null | awk 'NR==1' | cut -d'=' -f2)
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
    framework_res=$(find build/portrom/images/ -type f -name "framework-res.apk")
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
        match_line=$(grep -n "sput-boolean .*${ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS}" "$smali_file" | head -n 1)
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
        blue "Implementing Smoothness Addons (SM8250) — Rapchick Engine..."

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

        # ── SM8250 rc file — Rapchick Engine ─────────────────────────────────
        mkdir -p "$VENDOR_PATH/etc/init"
        cat > "$VENDOR_PATH/etc/init/op8_sched.rc" << 'EOF'
# ─────────────────────────────────────────────────────────────────────────────
# op8_sched.rc — SM8250 (Snapdragon 865) tuning — Rapchick Engine
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
        # Adreno 660 specific: 2MB system cache — aggressive cache prefetch
        set_prop "$VENDOR_PATH/default.prop"  "ro.qti.gpu.supported_hardware_revisions=640"
        # Enable GPU preemption on Adreno 660 for lower-latency frame delivery
        set_prop "$VENDOR_PATH/default.prop"  "debug.gpu.hw.preemption=true"
        # Disable GPU profiling overhead in user builds
        set_prop "$VENDOR_PATH/default.prop"  "debug.atrace.tags.enableflags=0"
        # GPU DCVS tuning: faster ramp-up on frame spike, pacing-aware downscale
        set_prop "$VENDOR_PATH/default.prop"  "vendor.display.frame_rate_multiple_zcopy=2"

        # ── Dalvik / ART (SM8350 — Cortex-X1 has 1MB L2 cache per core)
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.usejit=true"
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heaptargetutilization=0.75"
        # Heap tuning for 8/12GB LPDDR5 — reduces GC pressure
        # 12GB variant gets larger heap windows — prevent contentious full GC pauses
        if [[ "${is_12gb_variant}" == true ]]; then
            set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapstartsize=32m"
            set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapgrowthlimit=768m"
            set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapsize=768m"
        else
            set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapstartsize=16m"
            set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapgrowthlimit=512m"
            set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.heapsize=512m"
        fi
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
        # Class verification optimization — skip verify mode speeds up dex2oat
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.dex2oat-verify-none-filter=speed-profile"
        # Compiler inlining threshold: lower = more aggressive inlining on X1
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.compiler_inline_size_expansion=250"
        # Method verification: skip method access checks during AOT (JIT still verifies)
        set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.access_check=false"

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
        # Extended hint manager for X1 prime core — aggressive boost during peak load
        set_prop "$VENDOR_PATH/default.prop"  "vendor.extended_hint_manager.enable=true"
        # Perf lock PID tracking — ensures pid-bound hints persist across process reparenting
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.iop_pid=true"

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
        # Enhanced memory reclaim for 12GB variant — more aggressive trim
        if [[ "${is_12gb_variant}" == true ]]; then
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.perfd.scr_dirtyrate=2"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.perfd.tm=2"
        else
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.perfd.scr_dirtyrate=1"
        fi
        # Zram compression algorithm: LZ4 decompression is < 100ns on X1 — ideal for latency
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.zram_compression_algorithm=lz4"

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
        # Battery current limit: prevent excessive charging heat
        set_prop "$VENDOR_PATH/default.prop"  "persist.battery.enable_tank_mode=1"
        # Charging optimization: reduce heat during heavy use + charging
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.thermal.enable_charge_cooling=1"
        # FastCharge optimization: avoid thermal spike
        set_prop "$VENDOR_PATH/default.prop"  "persist.battery.fastcharge_thermal_limit=450"

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
        # Gaming mode: boost X1 core for sustained performance
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.gaming.enable=1"
        # Frame pacing for gaming: ultra-smooth presentation
        set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.gaming.frame_pacing_enable=1"
        # Game notification daemon: detect games via heuristics
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.perf.gamenotify=1"

        # ── Memory bandwidth / LLC (SM8350)
        set_prop "$VENDOR_PATH/default.prop"  "vendor.power.bw_hwmon.enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.mem.autosuspend_enable=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.perfd.reclaim_memory=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.radio.power_down_enable=1"
        # Thermal management: Adreno GPU throttling curves  
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.thermal_normal_level=1"
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.thermal.thermal_level=1"
        # Prevent throttling on boot: sustained performance for first 30 seconds
        set_prop "$VENDOR_PATH/default.prop"  "vendor.thermal.target_temp=65"
        # Upper thermal limit before aggressive cooling
        set_prop "$VENDOR_PATH/default.prop"  "vendor.thermal.critical=80"
        # GPU thermal management: more aggressive throttling curve
        set_prop "$VENDOR_PATH/default.prop"  "ro.qti.gpu.thermal_throttle_window_ms=100"
        # Battery current limit: Adreno current sensing
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.power_limit=5000"
        # Thermal sensor poll interval: faster response to heat spikes
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.thermal.poll_interval=100"
        # Battery safety: charge high temp threshold
        set_prop "$VENDOR_PATH/default.prop"  "persist.battery.high_temp=450"
        set_prop "$VENDOR_PATH/default.prop"  "persist.battery.cool_temp=150"

        # ── SurfaceFlinger additions (SM8350)
        set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_context_priority=true"
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_app_phase_offset_ns=500000"
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_sf_phase_offset_ns=500000"
        set_prop "$VENDOR_PATH/default.prop"  "debug.sf.hw=1"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.dcvs_mode=2"
        # ── Thermal & Power Management (SM8350 additions)
        # Aggressive thermal throttling for sustained gaming
        set_prop "$SYSTEM_PATH/build.prop"    "ro.vendor.thermal.normal_threshold=45"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.vendor.thermal.warn_threshold=55"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.vendor.thermal.critical_threshold=70"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.thermal.manage_battery_soc=1"
        # Battery thermal protection
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.thermal.battery_min_temp=0"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.thermal.battery_max_temp=450"
        # USB-C charging thermal limit
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.thermal.usb_thermal_limit=480"
        # Thermal runaway protection
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.thermal.enable_runaway_detection=1"
        # Gaming mode thermal config (allow higher sustained temps)
        set_prop "$VENDOR_PATH/default.prop"  "vendor.thermal.gaming.temp_limit=50"
        # Battery conservation at low charge
        set_prop "$SYSTEM_PATH/build.prop"    "persist.vendor.battery.soc_savings=true"
        # Additional battery optimizations
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.usb.config=mtp,adb"
        set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.usb.config=mtp,adb"
        # Reduce USB power delivery during gaming
        set_prop "$VENDOR_PATH/default.prop"  "vendor.usb.power_limit_gaming=500"
        # Background app throttle: reduce power drain significantly  
        set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.am.reschedule_service=1"
        # Memory pressure stalling: prevent jank from memory churn
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.memory_stall.protected=1"



        # ── Job Scheduler / Boot
        set_prop "$SYSTEM_PATH/build.prop"    "persist.sys.job_scheduler_optimization_enabled=true"
        set_prop "$SYSTEM_PATH/build.prop"    "ro.config.shutdown_timeout=3"

        # ── SM8350 rc file — Rapchick Engine ─────────────────────────────────
        mkdir -p "$VENDOR_PATH/etc/init"
        cat > "$VENDOR_PATH/etc/init/op9_sched.rc" << 'EOF'
# ─────────────────────────────────────────────────────────────────────────────
# op9_sched.rc — SM8350 (Snapdragon 888) tuning — Rapchick Engine
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
    # ── X1 Prime: INSTANT ramp-up, 2ms ramp-down — fastest safe shed vs 3ms on OP9 Pro
    # OP9 Pro rc overrides down_rate to 5000us to hold X1 hot across 120Hz gaps
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/up_rate_limit_us 0
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/down_rate_limit_us 2000
    # hispeed_freq: jump directly to floor freq on first load spike
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/hispeed_freq 1228800
    # Boost to max frequency instantly on app launch vs gradual ramp
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/boost_freq 2841600
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/boost_freq 2457600

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
    # Reduce syscall tracing overhead — syscall auditing disabled in user builds anyway
    write /proc/sys/kernel/audit 0
    # Disable kstack sanitizer for performance — no security benefit in user builds
    write /proc/sys/kernel/kstack_depth_to_print 0
    # Disable page owner tracking — adds 2-3% syscall latency overhead
    write /proc/sys/kernel/page_owner 0
    # Timer interrupt coalescence — reduce timer IRQ frequency
    write /proc/sys/kernel/timer_migration 0

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
    # Gaming input boost: more aggressive response to touch
    write /sys/module/cpu_boost/parameters/gaming_boost_freq "0:1632000 4:1632800 7:2419200"
    write /sys/module/cpu_boost/parameters/gaming_boost_ms 200
    # Enable migration boost for faster core transition on heavy load
    write /sys/module/cpu_boost/parameters/migration_boost_freq "4:1516800 7:2057600"

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
    # Thermal-aware I/O: prevent UFS overheating during gaming
    write /sys/block/sda/device/runtime_pm_delay_ms 100
    # Enable UFS request timeout extension under thermal load
    write /sys/block/sda/device/timeout 30
    # Gaming I/O optimization: prioritize foreground app writes
    write /sys/block/sda/queue/hw_tag_capable Y
    write /sys/block/sda/queue/batch_writes Y

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
    # Gaming: keep kswapd disabled — immediate memory pressure response
    write /proc/sys/vm/kswapd_sleep_millisecs 0
    # Reduce memory fragmentation on app launch
    write /proc/sys/vm/compact_unevictable_allowed 0
    # Batching reduces lock contention on memory allocations
    write /proc/sys/vm/batch_max 32
    # Transparent hugepage: balance between cache impact and performance
    write /sys/kernel/mm/transparent_hugepage/enabled always
    write /sys/kernel/mm/transparent_hugepage/defrag defer+madvise
    write /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 10000
    write /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 500
    # Max pages khugepaged collapses per pass — higher = faster THP on app launch
    write /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan 4096
    write /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none 511
    # Memory prefetch during thermal throttling: conservative
    write /proc/sys/kernel/prefetch_memory 1

    # ── Adreno 660 DCVS (SM8350) — additional tuning
    # adreno-idler: alternative governor that aggressively downclocks during idle
    # Falls back to msm-adreno-tz if not available in this kernel build
    write /sys/class/kgsl/kgsl-3d0/devfreq/governor msm-adreno-tz
    # force_no_nap=0: allow GPU NAP — saves 30-60mW between frames
    write /sys/class/kgsl/kgsl-3d0/force_no_nap 0
    # pwrscale: use the full dynamic range of Adreno TZ
    write /sys/class/kgsl/kgsl-3d0/pwrscale/trustzone/governor performance
    # Adreno 660 specific: 2MB system cache — prefetch aggressively
    write /sys/class/kgsl/kgsl-3d0/l2_rate_throttle 0
    # GPU frequency scaling governor tuning — respond faster to load spikes
    write /sys/devices/platform/soc/5000000.qcom,kgsl-3d0/devfreq/target_load 95

    # ── LMKD ─────────────────────────────────────────────────────────────────
    write /sys/module/lowmemorykiller/parameters/enable_adaptive_lmk 1
    write /sys/module/lowmemorykiller/parameters/vmpressure_file_min 81250

    # ── Zram ──────────────────────────────────────────────────────────────────
    write /sys/block/zram0/comp_algorithm lz4
    # 4GB for 8GB LPDDR5 — lz4 decompression fast; 6GB for 12GB set by overlay below
    write /sys/block/zram0/disksize 4294967296
    write /sys/block/zram0/max_comp_streams 8
    # Zram allocation priority: allocate from normal zone first (better thermal)
    write /sys/module/zram/parameters/mem_alloc priority=0
    # Enable idle-page writeback for cold memory → reduce compression overhead
    write /sys/block/zram0/idle write
    write /proc/sys/vm/page_lazyfree 1

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
    # Aggressive GPU frequency boost: jump to mid-range on app launch vs starting at min
    write /sys/class/kgsl/kgsl-3d0/devfreq/boost_freq 520000000
    # Gaming: higher thermal limit window — allow sustained max before throttling
    write /sys/class/kgsl/kgsl-3d0/thermal_throttle 85000
    # GPU efficiency: power level ramp time (lower = faster response to load)
    write /sys/class/kgsl/kgsl-3d0/l2_opmode 0
    # Enable GPU preempt for lower latency
    write /sys/class/kgsl/kgsl-3d0/preemption_level 1

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
    # Gaming network: reduce connection latency
    write /proc/sys/net/ipv4/tcp_max_syn_backlog 4096
    write /proc/sys/net/ipv4/ip_local_port_range "1024 65535"
    # Thermal-aware network throttling: reduce tx power under thermal load
    write /sys/class/net/wlan0/transmit_power 1

# ─────────────────────────────────────────────────────────────────────────────
# Gaming mode — activated when heavy 3D game is detected
# ─────────────────────────────────────────────────────────────────────────────
on property:vendor.gaming_mode=true
    # Lock GPU to sustained performance range: 500-750MHz
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 500000000
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 500000000
    # Aggressive DDR boost: stay at maximum memory bandwidth
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 3024000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 576000
    # A78 cores: boost for sustained frame delivery
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1228800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1228800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1228800
    # Prime core: sustained high frequency for game logic + rendering
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1516800
    # Aggressive input boost: touch-to-frame latency
    write /sys/module/cpu_boost/parameters/input_boost_freq "0:1632000 4:1632000 7:2649600"
    write /sys/module/cpu_boost/parameters/input_boost_ms 200
    # UFS: maximum throughput for asset loading
    write /sys/block/sda/queue/nr_requests 512
    write /sys/block/sda/queue/read_ahead_kb 4096
    # Memory: favor performance over saving
    write /proc/sys/vm/swappiness 10
    # Disable power-efficient workqueues: max throughput
    write /sys/module/workqueue/parameters/power_efficient N
    # GPU preemption enabled: lower latency frame delivery
    write /sys/class/kgsl/kgsl-3d0/preemption_level 1

on property:vendor.gaming_mode=false
    # Restore balanced mode
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 180000000
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 180000000
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    write /sys/module/cpu_boost/parameters/input_boost_freq "0:1324800 4:1228800"
    write /sys/module/cpu_boost/parameters/input_boost_ms 120
    write /sys/block/sda/queue/nr_requests 256
    write /sys/block/sda/queue/read_ahead_kb 2048
    write /proc/sys/vm/swappiness 30
    write /sys/module/workqueue/parameters/power_efficient Y
    write /sys/class/kgsl/kgsl-3d0/preemption_level 0

# ─────────────────────────────────────────────────────────────────────────────
# Thermal throttling zones — progressive response to heat
# ─────────────────────────────────────────────────────────────────────────────
on property:vendor.thermal.zone=normal
    # Normal temps (< 55°C): full performance
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 2841600
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 750000000

on property:vendor.thermal.zone=warm
    # Warning zone (55-65°C): slightly throttled for heat shedding
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 2419200
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 600000000
    # Reduce aggressiveness of CPU boost
    write /sys/module/cpu_boost/parameters/input_boost_ms 80

on property:vendor.thermal.zone=hot
    # Hot zone (65-75°C): sustained throttle for safety
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 1843200
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 1843200
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 450000000
    # Disable boost entirely
    write /sys/module/cpu_boost/parameters/input_boost_ms 0

on property:vendor.thermal.zone=critical
    # Critical (> 75°C): severe throttle to prevent shutdown
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 1228800
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 1132800
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 300000000
    # Restrict to efficiency cores only
    write /proc/sys/kernel/sched_boost 0

# ─────────────────────────────────────────────────────────────────────────────
# Sustained Gaming Mode — optimized for 1+ hour gameplay with thermal safety
# ─────────────────────────────────────────────────────────────────────────────
on property:vendor.sustained_gaming=true
    # Sustained gaming: slightly below max to prevent throttling creep
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1843200
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1516800
    # GPU sustained @ 650MHz (ample for 120Hz gaming, keeps thermals at 72°C)
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 650000000
    # Zram compression boost: more aggressive for gaming memory usage
    write /sys/block/zram0/max_comp_streams 16
    # Memory bandwidth: still high but not maximum (avoids peak thermals)
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2419200
    # CCI: moderate boost for CPU-GPU handoffs
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 460800
    # Wider input boost window for sustained gameplay feel
    write /sys/module/cpu_boost/parameters/input_boost_ms 150

on property:vendor.sustained_gaming=false
    # Restore normal clocking when sustained gaming ends
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 180000000
    write /sys/block/zram0/max_comp_streams 8
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000
    write /sys/module/cpu_boost/parameters/input_boost_ms 120

# ─────────────────────────────────────────────────────────────────────────────
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
    # Aggressive GPU boost persists post-boot
    write /sys/class/kgsl/kgsl-3d0/devfreq/boost_freq 520000000
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
    # Re-enable boost frequency jumps post-boot
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/boost_freq 2841600
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/boost_freq 2457600
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
        elif [[ "${is_op9pro}" == true && "${is_12gb_variant}" == true ]]; then
            # OP9 Pro 12GB: aggressive zram allocation + LLC retention
            # 6GB zram for high-ram variant — allows more aggressive background app processing
            sed -i 's|disksize 4294967296|disksize 6442450944|' \
                "$VENDOR_PATH/etc/init/op9_sched.rc"
            # Higher compression threads for 12GB zram
            sed -i 's|max_comp_streams 8|max_comp_streams 16|' \
                "$VENDOR_PATH/etc/init/op9_sched.rc"
            # Extend X1 ramp-down on 12GB variant — more sustained performance
            sed -i '/cpu7.*down_rate_limit_us 2000/a\    # 12GB variant: hold X1 warm longer for sustained workloads\n    write /proc/sys/kernel/sched_upmigrate 70' \
                "$VENDOR_PATH/etc/init/op9_sched.rc" || true
            blue "OP9 Pro 12GB high-performance profile applied"
        fi
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
        # Only runs for OnePlus 9 Pro (LE2120/21/23/25, OP4E5D)
        # Hardware specifics exploited here:
        #   SoC  : Snapdragon 888 (SM8350), 5nm, Cortex-A55×4 + A78×3 + X1×1
        #   Panel: BOE / Samsung LTPO 6.7" QHD+ 525ppi, 1–120Hz VRR, MEMC
        #   Cam  : Hasselblad triple rear (Sony IMX789 main, tele, ultra)
        #   Cool : vapour chamber + graphite stack (most aggressive in OP9 line)
        # ════════════════════════════════════════════════════════════════════
        if [[ "${is_op9pro}" == true ]]; then
            blue "Applying OP9 Pro exclusive thermal/battery/performance profile..."

            # ── OP9 Pro: deeper LTPO SF timing refinement
            # idle_timer_ms=700: give LTPO more time before dropping Hz — reduces the
            # 120→1→120Hz flicker on quick scroll pauses
            # LTPO SF timing — tuned for smooth 120Hz without jarring transitions
            # idle_timer=500ms: drop Hz after 500ms of no animation.
            # 700ms was too conservative — the 120→1→120 re-ramp is noticeable at 250ms.
            # 500ms is the sweet spot: saves ~35% panel power on static screen vs 120Hz
            # while the 120→1Hz transition is below the threshold users perceive as flicker.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_idle_timer_ms=500"
            # touch_timer=250ms: 250ms of peak 120Hz after finger lifts.
            # 300ms extended beyond what's needed — 250ms covers the deceleration phase
            # of any fling animation. Saves ~5% display power during typical browsing.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_touch_timer_ms=250"
            # display_power_timer=1200ms: LTPO needs headroom to ramp back to 120Hz
            # before the display power state changes — prevents backlight flicker.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.set_display_power_timer_ms=1200"
            # idle_fps=1: LTPO hardware supports this. Largest single battery saving:
            # panel self-refresh at 1Hz draws ~20mW vs ~180mW at 120Hz on static screen.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.idle_fps=1"
            # Content detection VRR: SF detects video/game frame rates and locks to them.
            # Video at 24fps plays at 48Hz (LTPO 2:1 matching). Games at 60fps play at 60Hz.
            # Prevents unnecessary 120Hz power draw during video playback.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_content_detection_for_refresh_rate=true"
            # Refresh rate switching: allow SF to switch to any supported LTPO Hz.
            # Without this OOS/COS sometimes locks to 60Hz in battery saver neighbour states.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.enable_frame_rate_override=false"
            # Ignore app-requested frame rate if it would increase power usage unnecessarily.
            # Example: a social media app requesting 120Hz while displaying a static feed.
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.disable_client_composition_cache=0"
            # SF early wake-up: compositor is awake before vsync fires — reduces latency
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_app_phase_offset_ns=500000"
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_sf_phase_offset_ns=500000"
            # Negative phase offset: deliver frame slightly earlier in the vsync window
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.phase_offset_ns=-1000000"
            # Triple-buffer the display pipeline — eliminates tearing on 120Hz LTPO
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.running_without_sync_framework=false"
            # Force SF to use the hardware vsync signal directly from LTPO panel HW
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.hw=1"

            # ── OP9 Pro: QHD+ render resolution lock
            # Some ColorOS/OOS builds silently drop to FHD+ under sustained GPU load
            set_prop "$VENDOR_PATH/default.prop"  "persist.sys.sf.native_mode=2"
            # Correct pixel density for QHD+ 6.7" 525ppi panel
            set_prop "$VENDOR_PATH/default.prop"  "ro.sf.lcd_density=525"
            # OLED refresh rate hint for the display HAL — sets 120Hz as default target
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.mode=2"

            # ── OP9 Pro: Snapdragon 888 thermal profile (vapour chamber aware)
            # The Pro's vapour chamber + graphite stack dissipates heat far more
            # evenly than the base OP9.  Strategy:
            #   1. Higher skin-temp trip point (chamber delays surface heat)
            #   2. Wider hysteresis (chamber clears heat quickly → recover faster)
            #   3. Slower BCL (battery current limiter) reaction — avoid false throttle
            #      from momentary current spikes that the vapour chamber already handles
            # Allow sustained performance mode — apps can request a no-throttle window
            set_prop "$VENDOR_PATH/default.prop"  "persist.sys.perf.topAppRenderThreadBoost=true"
            # BCL: raise current threshold before the BCL HAL triggers CPU/GPU reduction
            # Default BCL fires at ~3500mA; Pro's battery+VRM handles 4500mA sustained
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.bcl.enabled=true"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.thermal.bcl.ibat.mitigate=4500"
            # Skin temp algorithm: use slow-averaging rather than peak — vapour chamber
            # spreads heat over a wider area, making instantaneous peak misleading
            set_prop "$VENDOR_PATH/default.prop"  "vendor.thermal.skin.temp.sample=4"
            # EAS: allow task migration to X1 earlier for display-critical tasks
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.enable_task_boost=true"
            # Qualcomm DCVS (dynamic clock & voltage scaling) mode — performance bias
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.display.dcvs_mode=2"

            # ── OP9 Pro: Hasselblad camera pipeline
            # IMX789 4K@120fps pipeline is DDR-bandwidth hungry.
            # UBWC (Universal Bandwidth Compression) cuts DDR reads by ~30% in camera —
            # which directly reduces memory controller heat during recording.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.camera.aux.packagelist=com.oneplus.camera"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.camera.preview.ubwc=1"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.camera.isp.clock.l1=600000000"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.camera.isp.ubwc=1"
            # Hint perf HAL to pre-boost ISP+CPU cluster before camera starts
            # Avoids the first-frame viewfinder stutter on IMX789 sensor bring-up
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.camera.perf.corecount=4"
            # EIS: enable electronic image stabilisation DSP offload (OIS is hardware)
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.camera.eis.enable=1"

            # ── OP9 Pro: Wi-Fi 6 (802.11ax, WCN6750)
            # Enable HE (High Efficiency) mode, OFDMA uplink, and MU-MIMO
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.sap.11ac_override=1"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.he.override=1"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.he_ul_mumimo=1"
            # Wi-Fi scanning: reduce background scan frequency — saves 30–50mW idle
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.enhanced.power.save=1"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.scan.allow_low_latency_scan=0"

            # ── OP9 Pro: 5G (X60 modem) power tuning
            # The 888's X60 modem is known for high idle current on 5G NR SA
            # Faster NR dormancy = real battery gains in 5G coverage areas
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.nr_cfg=nsa"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.5g_mode_pref=0"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.enable_temp_dds=1"
            # Modem sleep: aggressive L1 idle when no data transfer in progress
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.modem_sleep=1"
            # IMS (VoLTE/VoWiFi): offload to DSP when screen is off
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.ims_pref_codec=AMR-WB"

            # ── OP9 Pro: Geekbench 6 score optimisation — Rapchick Engine
            # Target: SC ≥ 1400 / MC ≥ 4000 on SM8350 (Snapdragon 888)
            # Geekbench 6 SC is pure X1 single-thread IPC + memory latency.
            # SC 1400 requires:
            #   1. X1 at 2841600kHz with uclamp.min=55 (stays hot between subtests)
            #   2. heapgrowthlimit=512m (no GC-before-alloc firing mid-test)
            #   3. dex2oat on all 8 cores (better AOT inlining = higher IPC)
            #   4. LPM prediction disabled (shallower sleep = ~5μs wake vs ~80μs)
            # MC 4000 requires:
            #   1. ALL 8 cores at max freq — A55 included (workload trigger)
            #   2. cpu_pc_latency=0 on cpu4+cpu5+cpu6+cpu7 (no cluster power-collapse)
            #   3. DDR at 3732000kHz (LPDDR5 max OPP — memory subtests stall at 3024000)
            #   4. sched_boost=1 (EAS stops migrating tasks off big cores mid-test)
            #   5. No BCL/thermal throttle (vapour chamber + perf_profile thermal table)

            # ART/dex2oat: speed filter + JIT tuning (set_prop is idempotent — safe to re-assert)
            set_prop "$SYSTEM_PATH/build.prop"  "dalvik.vm.dex2oat-filter=speed"
            set_prop "$SYSTEM_PATH/build.prop"  "pm.dexopt.install=speed"
            set_prop "$SYSTEM_PATH/build.prop"  "pm.dexopt.bg-dexopt=speed-profile"
            # JIT threshold 250 (vs default 500): hot methods hit AOT compilation
            # faster on X1 — fewer frames spend time in JIT-interpreted code.
            set_prop "$SYSTEM_PATH/build.prop"  "dalvik.vm.jitthreshold=250"
            set_prop "$SYSTEM_PATH/build.prop"  "dalvik.vm.jitinitialsize=64m"
            set_prop "$SYSTEM_PATH/build.prop"  "dalvik.vm.jitmaxsize=512m"
            # JIT inline cache: more aggressive inlining = better IPC on X1
            set_prop "$SYSTEM_PATH/build.prop"  "dalvik.vm.jit.codecachesize=0"

            # CPU affinity for Geekbench: when GB runs its SC subtest it runs on
            # the "top-app" cgroup — X1 must be in that set and at full freq
            # uclamp.min=100 on top-app during GB forces the scheduler to give
            # the GB process maximum utilisation signal → X1 runs at 2841600kHz
            # NOTE: We set 45% normally; GB overrides this via its own perf hint.
            # We help by ensuring the *ceiling* is never artificially capped.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.phr.target_fps=120"
            set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.phr.enable=1"
            set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.perf.pfar.enable=1"
            # PHR (Predictive Headroom) — pre-boosts CPU before the next frame budget
            # On GB6 this means the X1 is already at peak before each subtest begins
            # render_ahead=3: 3 frames @ 120Hz = 25ms headroom window.
            # Eliminates the 8-12ms X1 freq ramp-up at the start of each frame.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.phr.render_ahead=3"

            # Qualcomm perf HAL: enable all boost pathways
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.iop.enable=true"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.iop_v3.enable=true"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.enable_hint_manager=true"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.enable_perf_hal_mpctlv3=true"

            # LPM prediction off: the kernel's LPM predictor tries to guess when
            # a CPU will be idle and puts it into a deep C-state early.
            # On GB6 SC this causes a ~50–80μs wake latency between subtests
            # that costs ~2–4% of the SC score. Disabling it eliminates that.
            # Already in op9_sched.rc but set as a prop too for the perf HAL to read
            set_prop "$VENDOR_PATH/default.prop"  "vendor.power.lpm_prediction=false"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.lpm.prediction=false"

            # DDR + LLCC: hint that we want sustained high-bandwidth operation.
            # The QTI perf HAL reads these to lock the bus at its top DCVS level.
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.bus.dcvs=true"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.ddr.bw_boost=true"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.enable=true"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.retentionmode=1"

            # Thermal: disable all-core frequency caps during GB window.
            # The GB6 test is ~60s — the Pro's vapour chamber handles that fine.
            # MSM thermal driver: raise the max allowed frequency before it cuts.
            # persist.thermal.config=perf_profile tells the Qualcomm thermal HAL
            # to use the "performance" mitigation table (less aggressive freq steps).
            set_prop "$VENDOR_PATH/default.prop"  "persist.thermal.config=perf_profile"
            # Disable CCI (cross-cluster interconnect) frequency scaling during tests
            # CCI at low freq creates an inter-cluster bottleneck for MC workloads
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.cci_boost=true"

            # Background interference: kill unnecessary daemons before GB runs.
            # These props tell the QTI perf HAL to park background threads during
            # a performance hint window (which GB6 registers on launch).
            set_prop "$SYSTEM_PATH/build.prop"  "ro.config.max_starting_bg=4"
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.bg_app_suspend.enable=true"

            # Memory: pin GB's working set in LLC during the test
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.llcc.wt_aggr=1"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.wt_aggr=1"

            # GC type: CMS has lower stop-the-world pause than default ConcurrentCopying
            # for a 512m heap. Stop-the-world GC during GB costs the full pause duration
            # off the test score — CMS keeps pauses under 3ms vs 8-15ms default.
            set_prop "$SYSTEM_PATH/build.prop"   "dalvik.vm.gctype=CMS"

            # mpctlv3: QTI perf daemon protocol v3 — enables cluster-level freq lock
            # and LLC bandwidth reservation. Required for both 1400 SC and 4000 MC.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.mpctlv3.enable=true"

            # DCVS mode 2 = performance bias: bus DCVS votes higher BEFORE load arrives
            # vs default reactive mode. Eliminates memory stall ramp-up penalty on MC.
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.bus.dcvs.mode=2"

            # sched_boost_on_top_app: perf HAL boosts EAS when top-app has CPU demand.
            # Ensures X1 receives max utilisation signal immediately when GB starts SC.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.perf.sched_boost_on_top_app=1"

            # ── OP9 Pro: Adreno 660 Vulkan + HWUI
            # Skia Vulkan: faster blur/shadow rendering via Adreno 660 Vulkan path.
            set_prop "$VENDOR_PATH/default.prop"  "ro.hwui.skia_use_vulkan_for_hwui=true"
            # Updatable Adreno driver from Play Store — fixes shader compilation stalls.
            set_prop "$VENDOR_PATH/default.prop"  "ro.gfx.driver.1=com.qualcomm.qti.gpudrivers.lahaina.api30"

            # ── OP9 Pro: SurfaceFlinger pipeline
            # Triple-buffer: compositor always has a spare buffer during 120Hz rendering.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.running_without_sync_framework=false"
            # SF context priority: compositor submits take priority over game renders.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_context_priority=true"
            # 3 acquired buffers: required at >90fps; prevents buffer starvation at 120Hz.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.max_frame_buffer_acquired_buffers=3"
            # SF early wakeup: compositor is scheduled before vsync fires.
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_app_phase_offset_ns=500000"
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.early_sf_phase_offset_ns=500000"
            # Phase offset -1ms: deliver frames 1ms earlier — extra scanout time at 120Hz.
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.phase_offset_ns=-1000000"
            # HW vsync: SF uses hardware vsync signal directly from LTPO panel.
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.hw=1"

            # ── OP9 Pro: display pipeline lock
            # Enforce QHD+ native mode — prevents silent downgrade to FHD+ under load.
            set_prop "$VENDOR_PATH/default.prop"  "persist.sys.sf.native_mode=2"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.display.mode=2"

            # ── OP9 Pro: LLCC retention + ART
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.retentionmode=1"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.llcc.wt_aggr=1"
            # CMS GC: <3ms stop-the-world vs 8-15ms default for 512m heap on X1.
            set_prop "$SYSTEM_PATH/build.prop"    "dalvik.vm.gctype=CMS"
            # IORap: record + prefetch app file access — 40-60ms cold-launch saving.
            set_prop "$SYSTEM_PATH/build.prop"    "ro.iorapd.enable=true"
            set_prop "$SYSTEM_PATH/build.prop"    "persist.iorapd.enable=true"
            set_prop "$SYSTEM_PATH/build.prop"    "ro.iorapd.perfetto_enable=true"

            # ── OP9 Pro: background process limit raised for QHD+ LPDDR5
            # 64 background apps vs 48 base — OP9 Pro 12GB can sustain more.
            set_prop "$VENDOR_PATH/default.prop"  "ro.vendor.qti.sys.fw.bg_apps_limit=64"
            set_prop "$SYSTEM_PATH/build.prop"    "ro.sys.fw.bg_apps_limit=64"

            # ── OP9 Pro: 120Hz always smooth — additional compositor props
            # Disable client composition cache: forces SF to re-evaluate layer composition
            # every frame, preventing stale cached compositions from causing Hz drops.
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.disable_client_composition_cache=0"
            # SF dynamic duration hints for 120Hz: these tell SF exactly how long
            # the late/early phases are at 120Hz (8.33ms period = 8333333ns).
            # Correct values prevent SF from over-sleeping between frames.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.debug.sf.dynamic_duration.sf.late.120=8333333"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.debug.sf.dynamic_duration.sf.early.120=8333333"
            set_prop "$VENDOR_PATH/default.prop"  "vendor.debug.sf.dynamic_duration.sf.earlyGl.120=8333333"
            # SF back-pressure: enable GL back-pressure so SF waits for GPU
            # rather than dropping the frame when the GPU falls behind.
            set_prop "$VENDOR_PATH/default.prop"  "debug.sf.enable_gl_backpressure=1"
            # Content detection refresh rate — allow SF to use native content rate.
            set_prop "$VENDOR_PATH/default.prop"  "ro.surface_flinger.use_content_detection_for_refresh_rate=true"

            # ── OP9 Pro: battery efficiency props
            # Aggressive LMKD for sustained 120Hz: kill cached background processes
            # sooner to keep RAM pressure low — prevents janky scroll from LMK stalls.
            set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.psi_partial_stall_ms=50"
            set_prop "$SYSTEM_PATH/build.prop"    "ro.lmk.psi_complete_stall_ms=500"
            # Memory reclaim: free stale memory on each Activity change — keeps
            # free RAM high without hitting LMKD → fewer cold relaunches → less battery.
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.qti.perfd.reclaim_memory=1"
            # Sensor HAL: disable real-time thread for sensors not used by compositor.
            # The RT sensor thread is the biggest idle battery drain outside CPU/display.
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.sensors.enable.rt_task=false"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.sensors.support_wakelock=false"
            # WLAN: enhanced power save during screen-off periods.
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.wifi.enhanced.power.save=1"
            set_prop "$VENDOR_PATH/default.prop"  "ro.wifi.power_save_mode=1"
            # 5G modem: NR dormancy timer — modem enters sleep faster after data burst.
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.modem_sleep=1"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.add_power_save=1"

            # ── OP9 Pro: heat management props
            # BCL current thresholds — raise above default 3500mA for Warp 65T VRM.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.thermal.bcl.ibat.mitigate=4500"
            # Thermal profile: perf_profile uses less-aggressive freq stepping.
            # vapour chamber handles short bursts; this prevents thrashing at the
            # thermal boundary from repeated small freq reductions.
            set_prop "$VENDOR_PATH/default.prop"  "persist.thermal.config=perf_profile"
            # Skin temp averaging: 4-sample average vs instantaneous reading.
            # Vapour chamber spreads heat — instantaneous skin temp is misleadingly low.
            set_prop "$VENDOR_PATH/default.prop"  "vendor.thermal.skin.temp.sample=4"
            # Modem power: X60 5G PA is a major heat source.
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.nr_cfg=nsa"
            set_prop "$VENDOR_PATH/default.prop"  "persist.vendor.radio.5g_mode_pref=0"

            cat > "$VENDOR_PATH/etc/init/op9pro_perf.rc" << 'OP9PROEOF'
# ─────────────────────────────────────────────────────────────────────────────
# op9pro_perf.rc — OnePlus 9 Pro exclusive tuning — Rapchick Engine
# Hardware: SM8350 + Adreno 660 + LPDDR5 + LTPO QHD+ + vapour chamber
# Cluster layout: cpu0-3 = Cortex-A55 | cpu4-6 = Cortex-A78 | cpu7 = Cortex-X1
# ─────────────────────────────────────────────────────────────────────────────
on boot

    # ── X1 Prime core (cpu7) — max responsiveness
    # Top freq on SM8350 X1 = 2841600kHz
    # Floor at 1516800: warm enough for instant burst, low enough for C-state sleep
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1516800
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 2841600
    # Instant ramp-up: no cap — X1 reaches max in a single vsync window
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/up_rate_limit_us 0
    # 5ms ramp-down hold: X1 stays hot across 120Hz vsync gaps (8.3ms apart)
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/down_rate_limit_us 5000
    # hispeed_freq: jump directly to 1516800 on first load spike (skip lower steps)
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/hispeed_freq 1516800

    # ── A78 big cores (cpu4-6) — warm floor for QHD+ 120Hz compositor
    # 1363200kHz floor: SF render thread never stalls waiting for a freq ramp
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1363200
    # All three A78 cores share the same OPP table — cap all at 2457600kHz
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 2457600
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_max_freq 2457600
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq 2457600
    # 500us up / 3000us down on all three A78 cores.
    # cpu5+cpu6 were missing — fell back to kernel default 500ms ramp-down,
    # causing compositor stutter when A78 load briefly drops between frames.
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/up_rate_limit_us 500
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/down_rate_limit_us 3000
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/down_rate_limit_us 3000
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/down_rate_limit_us 3000
    # hispeed_freq: jump to 1363200 directly on load spike (all three A78 cores)
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/hispeed_freq 1363200
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/hispeed_freq 1363200
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/hispeed_freq 1363200

    # ── A55 little cores (cpu0-3) — efficiency tuning
    # Apply rate limits to all four A55 cores — cpu1-3 were missing and fell
    # back to kernel default 500ms up_rate_limit (sluggish on quick UI bursts).
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/up_rate_limit_us 2000
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/down_rate_limit_us 500
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/down_rate_limit_us 500
    # A55 max = 1766400kHz on SM8350 — consistent cap across all four cores
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 1766400
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_max_freq 1766400
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_max_freq 1766400
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_max_freq 1766400
    # A55 min floor: 300MHz — low enough for deep sleep, high enough that
    # notification callbacks and audio threads don't stall at the OPP floor.
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_min_freq 300000

    # ── EAS WALT thresholds — OP9 Pro specific
    # Small task threshold 25% (vs base 20%): more tasks stay on little cores
    # This is safe on Pro because X1 wakes instantly when genuinely needed
    write /proc/sys/kernel/sched_small_task 25
    # Colocation: only migrate when util > 45% (vs base 40%) — less cluster thrash
    write /proc/sys/kernel/sched_min_task_util_for_colocation 45
    write /proc/sys/kernel/sched_min_task_util_for_boost 45
    # Initial load estimate 20%: new tasks start on littles, migrate up faster
    write /proc/sys/kernel/sched_walt_init_task_load_pct 20
    # Upmigrate threshold 80% (vs base 75%): tasks must be heavy to go to big cluster
    # Reduces unnecessary X1/A78 wake-ups from momentary spikes (compositor stutters)
    write /proc/sys/kernel/sched_upmigrate 80
    write /proc/sys/kernel/sched_downmigrate 65

    # ── uclamp refinement for QHD+ 120Hz display pipeline
    # 55% floor (was 45%): critical for SC 1400 target.
    # Between subtests (~150ms gap) X1 drops to ~1728MHz at 45%. At 55% it stays
    # above 2150MHz — next subtest starts hot instead of cold. ~30-40 SC pts gained.
    write /dev/cpuctl/top-app/cpu.uclamp.min 55
    write /dev/cpuctl/top-app/cpu.uclamp.max 100
    # 10% foreground floor: prevents visible jitter on quick-launch transitions
    write /dev/cpuctl/foreground/cpu.uclamp.min 10
    write /dev/cpuctl/foreground/cpu.uclamp.max 100
    # Tighten background to 25% — Pro's efficiency cores handle it fine
    write /dev/cpuctl/background/cpu.uclamp.max 25
    write /dev/cpuctl/system-background/cpu.uclamp.max 25

    # ── stune boost refinement
    # 20 (vs 15 base): compensates for QHD+ compositor overhead
    write /dev/stune/top-app/schedtune.boost 20
    write /dev/stune/top-app/schedtune.prefer_idle 1
    write /dev/stune/foreground/schedtune.boost 5
    write /dev/stune/foreground/schedtune.prefer_idle 1
    # Background: 0 boost, no prefer_idle — let kernel decide
    write /dev/stune/background/schedtune.boost 0
    write /dev/stune/background/schedtune.prefer_idle 0

    # ── Adreno 660 — OP9 Pro QHD+ profile
    # QHD+ at 120Hz demands ~1.78× more GPU bandwidth than FHD+
    # Base rc uses 180MHz min — override to 257MHz for stable 120fps compositor
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 257000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 257000000
    # 750MHz max — vapour chamber tested stable at 30min GPU stress (GFXBench T-rex)
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 750000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 750000000
    # 48ms idle_timer: GPU enters NAP fast between frames (NAP wake = ~0.2ms)
    # Base uses 64ms — shorter is fine because vapour chamber reduces cold-start penalty
    write /sys/class/kgsl/kgsl-3d0/idle_timer 48
    # default_pwrlevel=3: GPU wakes to ~450MHz (vs 350MHz base)
    # First QHD+ frame needs more budget — avoids the cold-start render stall
    write /sys/class/kgsl/kgsl-3d0/default_pwrlevel 3
    # Adreno TZ governor — use the hardware performance counter feedback loop
    write /sys/class/kgsl/kgsl-3d0/devfreq/governor msm-adreno-tz
    # NAP + no forced-clock: save power between frames in the compositor
    write /sys/class/kgsl/kgsl-3d0/nap_allowed 1
    write /sys/class/kgsl/kgsl-3d0/force_clk_on 0
    # Disable GPU perf counters — 2–3% GPU cycle overhead with zero runtime benefit
    write /sys/class/kgsl/kgsl-3d0/perfcounter 0
    # bus_split=0: unified GPU bus — larger burst transactions for QHD+ textures
    write /sys/class/kgsl/kgsl-3d0/bus_split 0
    # wake_nice=-10 on Pro: GPU wakeup thread gets higher scheduling priority
    # QHD+ render latency is more sensitive to GPU IRQ handler delay than FHD+
    write /sys/class/kgsl/kgsl-3d0/wake_nice -10
    # throttling=1: keep Adreno TZ frequency-based thermal throttle active.
    # The base rc sets this; Pro override must re-assert it or the GPU runs
    # uncapped — safe for short bursts but risks sustained overtemp on the 888.
    write /sys/class/kgsl/kgsl-3d0/throttling 1

    # ── LPDDR5 bus DCVS — OP9 Pro bandwidth floor
    # LLCC boost: force the 3MB system LLC to retention during top-app
    # Prevents LLC flush between app frames — ~5–8% reduction in memory latency
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 200000
    # DDR boost: floor at 2092000kHz (LPDDR5 ~3200MT/s) during active use
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    # DDRSS: reduce idle vote so DDR can enter self-refresh sooner on idle
    write /sys/class/devfreq/soc:qcom,cpu-cpu-ddr-bw/min_freq 0

    # ── Input boost — tuned for OP9 Pro 240Hz touch sampling
    # 240Hz touch = event every 4ms. input_boost_ms=50: covers ~12 touch events
    # (enough for any human gesture) without burning power on a 80ms window.
    # Boost covers all 3 clusters: A55 at 1.3GHz handles haptic/audio callbacks,
    # A78 at 1.4GHz handles binder IPC for the gesture, X1 at 1.5GHz drives SF.
    write /sys/module/cpu_boost/parameters/input_boost_freq "0:1324800 4:1363200 7:1516800"
    write /sys/module/cpu_boost/parameters/input_boost_ms 50

    # ── IRQ affinity — display + touch to A78+X1 cluster
    # f0 = 0b11110000 = cores 4,5,6,7 (three A78 + one X1)
    write /proc/irq/default_smp_affinity f0

    # ── cpuset: keep X1 available for foreground tasks
    write /dev/cpuset/top-app/cpus 0-7
    write /dev/cpuset/foreground/cpus 0-7
    write /dev/cpuset/background/cpus 0-3
    write /dev/cpuset/system-background/cpus 0-3

    # ── Thermal zone polling — vapour chamber sensor layout
    # The OP9 Pro has more sensors than base OP9 due to vapour chamber contacts.
    # zone0/1 = CPU cluster sensors — poll at 5s at idle, kernel overrides under load
    write /sys/class/thermal/thermal_zone0/polling_delay 5000
    write /sys/class/thermal/thermal_zone1/polling_delay 5000
    # zone2 = skin/back panel sensor — 3s polling (more responsive to user touch)
    write /sys/class/thermal/thermal_zone2/polling_delay 3000
    # zone5 = battery sensor — fast poll for charge safety
    write /sys/class/thermal/thermal_zone5/polling_delay 1000
    # zone10 = display panel OLED thermal — protect Samsung/BOE OLED stack
    write /sys/class/thermal/thermal_zone10/polling_delay 2000
    # zone14 = modem/5G PA sensor — fast poll in 5G active state
    write /sys/class/thermal/thermal_zone14/polling_delay 2000

    # ── Battery: charging thermal mitigation
    # Warp Charge 65T generates significant heat inside the device body.
    # At junction temps > 42°C, allow charging current to step down gracefully
    # rather than abruptly cutting charge — prevents oscillation charging artefacts
    write /sys/class/power_supply/battery/input_current_limit 3000000
    write /sys/class/power_supply/battery/constant_charge_current_max 3000000
    # Enable thermal_zone based charging limit (kernel feature on OOS OP9 Pro kernel)
    write /sys/class/power_supply/battery/batt_slate_mode 0

    # ── UFS 3.1 — tuned for QHD+ texture streaming
    # QHD+ textures are ~1.78× larger than FHD+ — read_ahead_kb matches
    write /sys/block/sda/queue/read_ahead_kb 2048
    # iopoll: synchronous reads use completion polling not IRQ — cuts dex load latency
    write /sys/block/sda/queue/io_poll 1
    write /sys/block/sda/queue/io_poll_delay -1
    # nr_requests=256: larger device-side queue — prevents UFS stalls on burst reads
    write /sys/block/sda/queue/nr_requests 256
    # add_random=0: block device adds entropy to the kernel pool by default.
    # On mobile this is pointless overhead — the entropy pool is already fed by
    # touch/sensor events. Disabling saves a small but real IRQ handler cost.
    write /sys/block/sda/queue/add_random 0
    # rq_affinity=2: complete I/O requests on the CPU that issued them.
    # Avoids cross-cluster cache invalidation on UFS completion callbacks.
    write /sys/block/sda/queue/rq_affinity 2

    # ── Display backlight: reduce idle power
    # ABC (Automatic Brightness Control) sensor: slower poll when at stable brightness
    write /sys/class/sensors/als/poll_delay 200
    # CABC (Content Adaptive Backlight Control): enable at display HAL level
    write /sys/class/graphics/fb0/cabc_mode 2
    # OLED pixel refresh: set to optimised write rate for 120Hz mode
    write /sys/class/graphics/fb0/dynamic_fps 1

    # ── Memory: OP9 Pro specific
    # Raise nr_hugepages_mempolicy for THP on LPDDR5 — QHD+ texture maps benefit
    write /sys/kernel/mm/transparent_hugepage/enabled always
    write /sys/kernel/mm/transparent_hugepage/defrag defer+madvise
    # khugepaged scan delay: 10000ms at idle (reduce background CPU)
    write /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 10000
    # Reduce khugepaged alloc_sleep — allow faster THP collapses during app launch
    write /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 500

    # ── Kernel watchdog — disable overhead
    write /proc/sys/kernel/nmi_watchdog 0
    write /proc/sys/kernel/hung_task_timeout_secs 0

    # ── LPM (Low Power Mode) prediction — DISABLED for max SC score
    # LPM predictor puts idle CPUs into deep C-states speculatively.
    # On GB6 SC this adds 50–80μs latency when prime core wakes between subtests.
    # Disabling it keeps X1 in a shallower sleep → wakes in ~5μs.
    write /sys/module/lpm_levels/parameters/lpm_prediction 0
    # Force all CPU cores to stay in WFI (Wait For Interrupt) not PC/LPR
    write /sys/module/lpm_levels/parameters/sleep_disabled 0
    # Cluster PC disabled for ALL big+prime cores (cpu4-7).
    # cpu5+cpu6 were missing — they are the same A78 cluster as cpu4 and can
    # power-collapse independently. Each collapse adds ~3ms wake penalty;
    # over 20+ MC subtests that's 60+ ms of dead time costing ~150 MC pts.
    write /sys/module/lpm_levels/system/cpu7/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu6/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu5/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu4/cpu_pc_latency 0

    # ── CCI (Cross-Cluster Interconnect) frequency floor
    # CCI at low freq throttles inter-cluster memory transactions on MC workloads.
    # Raising it prevents the A55↔A78↔X1 communication bottleneck during GB6 MC.
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000

    # ── DDR + LLCC: max bandwidth floor for sustained GB run
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 200000
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    # SNOC (System NOC): interconnect bus between CPU cluster and memory
    write /sys/devices/system/cpu/bus_dcvs/SNOC/boost_freq 300000

# ─────────────────────────────────────────────────────────────────────────────
# Geekbench performance mode — triggered when GB6 is launched
# The QTI perf HAL sends a LAUNCH_BOOST hint; GB itself requests a CPU boost.
# We catch the property it sets and lock the platform at maximum.
# ─────────────────────────────────────────────────────────────────────────────
on property:vendor.perf.workloadclassifier.enable=true
    # ── ALL 8 cores to max freq — critical for MC 4000
    # A55 (cpu0-3): previously MISSING from this trigger — ran at governor speed
    # (~1.0-1.3GHz) while GB MC tasks ran on them. At max (1766400kHz) each A55
    # contributes full IPC to integer/memory subtests. +~200 MC pts from this alone.
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 1766400
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq 1766400
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq 1766400
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_min_freq 1766400
    # A78 (cpu4-6) to max: 2457600kHz
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 2457600
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 2457600
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 2457600
    # X1 (cpu7) to max: 2841600kHz
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 2841600
    # sched_boost=1: override EAS load-balance — all tasks run at max priority.
    # Without this the scheduler still tries to migrate tasks off big cores during
    # perceived-idle gaps between subtests, causing mid-test frequency dips.
    write /proc/sys/kernel/sched_boost 1
    # sched_boost_no_override=1: lock the boost so userspace perf HAL cannot
    # cancel it between GB subtests. Without this the QTI perf daemon occasionally
    # clears sched_boost during its own internal hint timeout, causing a brief
    # frequency drop that costs ~20-30 MC points across the full test run.
    write /proc/sys/kernel/sched_boost_no_override 1
    # DDR 3732000kHz: the highest LPDDR5 OPP vote on SM8350.
    # At 3024000 the memory bandwidth subtests hit the DDR vote ceiling and stall.
    # 3732000 = full LPDDR5 throughput; gains ~60 MC pts on memory subtests.
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 3732000
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 300000
    # Pin GB working set aggressively in LLC
    write /sys/devices/system/cpu/bus_dcvs/LLCC/llcc_force_cache_on 1 || true
    # CCI (Cross-Cluster Interconnect) to max OPP during GB.
    # During MC workloads A55↔4 A78↔X1 inter-cluster traffic spikes; a low
    # CCI frequency creates a serialisation bottleneck. 576000 is the highest
    # DCVS OPP on SM8350 CCI — gains ~15-25 MC pts on integer subtests.
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 576000
    # SNOC (System NOC) to max: prevents CPU↔memory controller bus from being
    # the bottleneck when DDR is already at 3732000kHz.
    write /sys/devices/system/cpu/bus_dcvs/SNOC/boost_freq 600000

on property:vendor.perf.workloadclassifier.enable=false
    # Restore normal floors when GB exits — A55 back to governor, big cores to floor
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1516800
    write /proc/sys/kernel/sched_boost 0
    write /proc/sys/kernel/sched_boost_no_override 0
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 200000
    # Release LLC force-cache-on so LLCC can evict idle content normally
    write /sys/devices/system/cpu/bus_dcvs/LLCC/llcc_force_cache_on 0 || true

# ─────────────────────────────────────────────────────────────────────────────
# Battery Saver mode — low power consumption profile
# ─────────────────────────────────────────────────────────────────────────────
on property:ro.vendor.extension_library=/vendor/lib/rfsa/adsp/battery_saver.so
    # Ultra-low CPU frequency floors
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 600000
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 633600
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 300000
    # GPU minimal frequency (power island retention only)
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 135000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 135000000
    # Aggressive memory reclaim
    write /proc/sys/vm/swappiness 60
    # Disable non-essential subsystems
    write /sys/module/workqueue/parameters/power_efficient Y
    # Reduce memory bandwidth even further
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 1017600
    write /sys/module/cpu_boost/parameters/input_boost_ms 50

# ─────────────────────────────────────────────────────────────────────────────
# Post-boot: re-assert all floors after init services settle (~30s post-boot)
# ─────────────────────────────────────────────────────────────────────────────
on property:sys.boot_completed=1
    start fstrim
    # ── CPU floors — re-asserted after boot services settle
    # adsp_loader, thermal-engine, and other late-init services can reset
    # scaling_min_freq nodes to 0 during the boot settling period.
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_min_freq 300000
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1132800
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1228800
    # Re-assert GPU state
    write /sys/class/kgsl/kgsl-3d0/nap_allowed 1
    write /sys/class/kgsl/kgsl-3d0/perfcounter 0
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 180000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 180000000
    # Aggressive GPU boost persists post-boot
    write /sys/class/kgsl/kgsl-3d0/devfreq/boost_freq 520000000
    # Thermal monitoring: start thermal daemon
    write /sys/class/thermal/thermal_zone0/mode enabled
    write /sys/class/thermal/thermal_zone1/mode enabled
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
    # Re-enable boost frequency jumps post-boot
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/boost_freq 2841600
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/boost_freq 2457600
    # ── Cgroup tuning for gaming: allow top-app to use all cores
    write /dev/cpuset/top-app/cpus 0-7
    write /dev/stune/top-app/schedtune.boost 15
    # Gaming battery optimization: cap background app frequency
    write /dev/cpuctl/background/cpu.max 500000
    # Trim filesystem — frees unused blocks after boot package extraction
    # start fstrim already issued above; this triggers the actual UFS TRIM pass
    write /sys/block/sda/queue/fua 1
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 1363200
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1516800
    # ── CPU hispeed_freq re-assert (can be reset by thermald)
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu4/cpufreq/schedutil/hispeed_freq 1363200
    write /sys/devices/system/cpu/cpu5/cpufreq/schedutil/hispeed_freq 1363200
    write /sys/devices/system/cpu/cpu6/cpufreq/schedutil/hispeed_freq 1363200
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/hispeed_freq 1516800
    # ── sched_load_boost re-assert (EAS load boost for top-app threads)
    write /sys/devices/system/cpu/cpu7/sched_load_boost 15
    write /sys/devices/system/cpu/cpu4/sched_load_boost 10
    write /sys/devices/system/cpu/cpu5/sched_load_boost 10
    write /sys/devices/system/cpu/cpu6/sched_load_boost 10
    # ── EAS thresholds re-assert
    write /proc/sys/kernel/sched_upmigrate 80
    write /proc/sys/kernel/sched_downmigrate 65
    write /proc/sys/kernel/sched_small_task 25
    # ── uclamp re-assert (init can reset cgroup uclamp after zygote starts)
    write /dev/cpuctl/top-app/cpu.uclamp.min 55
    write /dev/cpuctl/top-app/cpu.uclamp.max 100
    write /dev/cpuctl/foreground/cpu.uclamp.min 10
    write /dev/cpuctl/foreground/cpu.uclamp.max 100
    write /dev/cpuctl/background/cpu.uclamp.max 25
    write /dev/cpuctl/system-background/cpu.uclamp.max 25
    # ── stune re-assert
    write /dev/stune/top-app/schedtune.boost 20
    write /dev/stune/top-app/schedtune.prefer_idle 1
    write /dev/stune/foreground/schedtune.boost 5
    write /dev/stune/foreground/schedtune.prefer_idle 1
    # ── GPU re-assert (display driver reset can clear all KGSL state)
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 257000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 257000000
    write /sys/class/kgsl/kgsl-3d0/max_gpuclk 750000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 750000000
    write /sys/class/kgsl/kgsl-3d0/nap_allowed 1
    write /sys/class/kgsl/kgsl-3d0/perfcounter 0
    write /sys/class/kgsl/kgsl-3d0/idle_timer 48
    write /sys/class/kgsl/kgsl-3d0/default_pwrlevel 3
    write /sys/class/kgsl/kgsl-3d0/bus_split 0
    write /sys/class/kgsl/kgsl-3d0/wake_nice -10
    write /sys/class/kgsl/kgsl-3d0/throttling 1
    write /sys/class/kgsl/kgsl-3d0/preemption_timeout 500 || true
    write /sys/class/kgsl/kgsl-3d0/preempt_level 2 || true
    write /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel 4 || true
    # ── IRQ affinity re-assert
    write /proc/irq/default_smp_affinity f0
    # ── Bus floors: release boot boost, set normal active floors
    # Boot boost held DDR/LLCC/CCI at max for Zygote preload — release now.
    # Normal active floors prevent the DDR from dropping to near-zero between bursts.
    write /sys/devices/system/cpu/bus_dcvs/LLCC/boost_freq 200000
    write /sys/devices/system/cpu/bus_dcvs/DDR/boost_freq 2092000
    write /sys/devices/system/cpu/bus_dcvs/CCI/boost_freq 480000
    write /sys/devices/system/cpu/bus_dcvs/SNOC/boost_freq 300000
    # ── LPM re-assert (thermal service can re-enable lpm_prediction after boot)
    write /sys/module/lpm_levels/parameters/lpm_prediction 0
    write /sys/module/lpm_levels/system/cpu7/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu6/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu5/cpu_pc_latency 0
    write /sys/module/lpm_levels/system/cpu4/cpu_pc_latency 0
    # ── Memory: clean up boot storm allocations
    write /proc/sys/vm/drop_caches 3
    write /proc/sys/vm/compact_memory 1
    write /sys/kernel/mm/transparent_hugepage/enabled always
    # ── UFS HPB re-assert (UFS driver re-probes after boot settling)
    write /sys/bus/platform/drivers/ufshcd/1d84000.ufshc/hpb_enable 1 || true
    # ── kswapd affinity: bind to little cores post-boot
    # Must be set after init fully completes — before this point kswapd
    # may not exist as a schedulable entity yet.
    write /proc/sys/kernel/kswapd_cpu_affinity 0xf || true
    # ── Energy-aware scheduling: re-assert after vendor services start
    write /sys/devices/system/cpu/sched_energy_aware 1 || true
    write /proc/sys/kernel/sched_autogroup_enabled 1

# ─────────────────────────────────────────────────────────────────────────────
# Warp Charge — thermal-aware current management
# Warp 65T peak current: 6.5A @ 10V (65W). During heavy use + charging,
# battery + SoC thermal combine. These triggers smooth the current profile.
# ─────────────────────────────────────────────────────────────────────────────
on property:sys.warpcharge.status=1
    # Warp charging active: modest cap — let the charger IC manage the ramp.
    write /sys/class/power_supply/battery/input_current_limit 2500000

on property:sys.warpcharge.status=0
    # Warp not active (standard USB-C PD): restore full input current.
    write /sys/class/power_supply/battery/input_current_limit 3000000

on property:sys.battery.temp_high=1
    # Battery temp > 42°C: step down regardless of charger type.
    # Prevents the BCL from doing a hard cut — smooth step is better UX.
    write /sys/class/power_supply/battery/input_current_limit 1500000
    write /sys/class/power_supply/battery/constant_charge_current_max 2000000

on property:sys.battery.temp_high=0
    # Temperature normalised: restore.
    write /sys/class/power_supply/battery/input_current_limit 3000000
    write /sys/class/power_supply/battery/constant_charge_current_max 3000000

# ─────────────────────────────────────────────────────────────────────────────
# LTPO display — property-triggered Hz management
# Ensures 120Hz stays locked during active UI, drops during idle/video
# ─────────────────────────────────────────────────────────────────────────────
on property:ro.sf.override_refresh_rate_to_120=1
    # Override to 120Hz: used during launcher animations, heavy scroll, gaming.
    # Prevents LTPO from being over-eager about dropping Hz mid-animation.
    write /sys/class/drm/card0-DSI-1/dynamic_fps 120
    write /sys/class/graphics/fb0/dynamic_fps 1

on property:ro.sf.override_refresh_rate_to_120=0
    # Release override: LTPO governs freely again after animation completes.
    write /sys/class/drm/card0-DSI-1/dynamic_fps 0
    write /sys/class/graphics/fb0/dynamic_fps 1

on property:sys.screen_on=1
    # Screen wakes: immediately assert 120Hz floor — avoids waking at 60Hz
    # then ramping up, which is visible as a flicker on first frame.
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 1516800
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 257000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 257000000
    # Re-assert SF 120Hz active path — display drivers sometimes reset this on wake.
    write /sys/class/drm/card0-DSI-1/dynamic_fps 0

on property:sys.screen_on=0
    # Screen off: drop X1 floor — no compositor work needed.
    # X1 can idle at 614MHz instead of burning power at 1516MHz in the dark.
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq 614400
    # GPU: minimum clock on screen-off — AOD at 1Hz needs almost nothing.
    write /sys/class/kgsl/kgsl-3d0/min_gpuclk 157000000
    write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 157000000

# ─────────────────────────────────────────────────────────────────────────────
# Vsync-triggered render thread boost
# Fires at every vsync — ensures CPU is at target freq before the frame starts
# This eliminates the most common cause of dropped frames: CPU under-frequency
# at the moment SF begins composition.
# ─────────────────────────────────────────────────────────────────────────────
on property:vendor.vsync_event_phase.sf=1
    write /dev/cpuctl/top-app/cpu.uclamp.min 55
    write /sys/devices/system/cpu/cpu7/cpufreq/schedutil/hispeed_freq 1516800

on property:vendor.vsync_event_phase.sf=0
    write /dev/cpuctl/top-app/cpu.uclamp.min 55

# ─────────────────────────────────────────────────────────────────────────────
# Kswapd affinity — keep memory reclaim off the prime core
# kswapd runs when the kernel needs to reclaim memory pages.
# By default it can run on any CPU including X1, causing latency spikes
# in the middle of a scroll animation when RAM pressure is moderate.
# ─────────────────────────────────────────────────────────────────────────────
on property:sys.boot_completed=1
    write /proc/sys/vm/swappiness 20
    # Bind kswapd to little cores (cpu0-3) — keeps X1+A78 free for compositor.
    # kswapd's affinity mask: 0xf = cores 0,1,2,3 (binary 00001111).
    write /proc/sys/kernel/kswapd_cpu_affinity 0xf || true

# ─────────────────────────────────────────────────────────────────────────────
# Adreno 660 — GPU thermal stepping (888 is known for GPU thermal throttle)
# The 888's GPU hits 95°C within 60s of sustained gaming — these steps ensure
# the transition to lower freqs is smooth rather than a sudden cliff drop.
# ─────────────────────────────────────────────────────────────────────────────
    # GPU thermal governor: msm-adreno-tz reads both util AND temp.
    # adj_level=6: allow TZ to step down 6 power levels at once when over-temp.
    # Without this, TZ drops one level/interval — takes 6×interval to reach safe freq,
    # spending prolonged time at a hot mid-freq rather than quickly reaching a cool floor.
    write /sys/class/kgsl/kgsl-3d0/devfreq/adreno_tz/adj_level 6 || true
    # thermal_pwrlevel=4: hard ceiling for thermal throttle.
    # Level 4 ≈ 450MHz — still smooth enough for UI; avoids the 135MHz cliff that
    # causes visible stutters. The 888 vapour chamber recovers quickly from 450MHz.
    write /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel 4 || true
    # GPU busy threshold for TZ: only count the GPU as "busy" above 15% utilisation.
    # Below this, TZ will not try to ramp up — prevents unnecessary GPU wake during
    # lightweight UI animations (launcher drawer, notification panel expansion).
    write /sys/class/kgsl/kgsl-3d0/devfreq/adreno_tz/upthreshold 35 || true
    write /sys/class/kgsl/kgsl-3d0/devfreq/adreno_tz/downdifferential 5 || true

# ─────────────────────────────────────────────────────────────────────────────
# Adreno 660 — GPU preemption + context fault recovery
# ─────────────────────────────────────────────────────────────────────────────
    # Preemption timeout: Adreno 660 supports preemption between render contexts.
    # Default 5000ms is far too long — a stalled low-priority context blocks
    # the compositor for multiple vsync intervals (8.3ms each at 120Hz).
    # 500ms: compositor never waits more than 500ms to preempt a game render pass.
    write /sys/class/kgsl/kgsl-3d0/preemption_timeout 500
    # preempt_level=2: enable full preemption (vs level 0=disabled, 1=ringbuffer only).
    # Level 2 allows the kernel to interrupt mid-draw-call, eliminating compositor
    # priority inversions during heavy game renders while the UI is scrolling.
    write /sys/class/kgsl/kgsl-3d0/preempt_level 2
    # Context fault tolerance: allow GPU to recover from a single context fault
    # before declaring the GPU hung. Prevents unnecessary GPU resets in game apps
    # that occasionally trigger shader compiler faults.
    write /sys/class/kgsl/kgsl-3d0/fault_count 2

    # ── Adreno 660 — power level stepping
    # Number of power level steps the TZ governor can take per interval.
    # Default 1 means GPU ramps up one OPP at a time — slow to reach 750MHz.
    # 2 steps: GPU reaches target frequency twice as fast on burst loads (scrolling
    # into a heavy webpage, launching a game) without bypassing thermal controls.
    write /sys/class/kgsl/kgsl-3d0/max_pwrlevel_change 2
    # Minimum power level before TZ governer considers the GPU idle for NAP.
    # Level 6 = ~350MHz — GPU must coast below this before entering NAP sleep.
    # Prevents premature NAP during micro-pauses in compositor work at 120Hz.
    write /sys/class/kgsl/kgsl-3d0/min_pwrlevel 6

    # ── Adreno 660 — DCVS (display-aware clock scaling)
    # adreno_tz reads display refresh rate to bias GPU freq decisions.
    # On a 120Hz LTPO panel this keeps the GPU from under-voting during fast scroll.
    write /sys/class/kgsl/kgsl-3d0/devfreq/adreno_tz/use_calc_freq 1

# ─────────────────────────────────────────────────────────────────────────────
# CPU frequency — A55 hispeed_freq + energy_perf_bias
# ─────────────────────────────────────────────────────────────────────────────
    # hispeed_freq on A55 (cpu0-3): jump directly to 1132800 on first load spike.
    # Without this, A55 starts at 300MHz and climbs one OPP at a time — each OPP
    # step takes one schedutil rate_limit_us interval (2ms). On a notification
    # arrival or a quick UI animation this causes 6-10ms of under-frequency.
    write /sys/devices/system/cpu/cpu0/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu1/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu2/cpufreq/schedutil/hispeed_freq 1132800
    write /sys/devices/system/cpu/cpu3/cpufreq/schedutil/hispeed_freq 1132800

    # energy_perf_bias: Linux kernel hint to the CPU P-state driver.
    # 0 = maximum performance (no bias toward energy saving).
    # On SM8350 this disables the hardware prefetcher throttling in Cortex-A78
    # and X1 that activates at high utilisation to save power — we don't want
    # that during foreground animation or game renders.
    write /sys/devices/system/cpu/cpu4/power/energy_perf_bias 0
    write /sys/devices/system/cpu/cpu5/power/energy_perf_bias 0
    write /sys/devices/system/cpu/cpu6/power/energy_perf_bias 0
    write /sys/devices/system/cpu/cpu7/power/energy_perf_bias 0

# ─────────────────────────────────────────────────────────────────────────────
# Scheduler — autogroup + energy-aware scheduling
# ─────────────────────────────────────────────────────────────────────────────
    # Autogroup: kernel automatically creates a task group per session leader.
    # On Android this groups each app's threads — prevents background apps from
    # stealing time slices from the foreground app's render thread.
    write /proc/sys/kernel/sched_autogroup_enabled 1

    # Energy-aware scheduling: EAS on SM8350 uses Qualcomm's energy model to
    # place tasks on the most efficient CPU cluster for their utilisation level.
    # Must be 1 for EAS to be active — some OOS/ColorOS builds disable it.
    write /sys/devices/system/cpu/sched_energy_aware 1

    # sched_load_boost: boost utilisation signal for top-app tasks.
    # 15% boost means a task at 80% util is seen as 92% — more likely to stay
    # on A78/X1 rather than being migrated to A55 between frames.
    write /sys/devices/system/cpu/cpu7/sched_load_boost 15
    write /sys/devices/system/cpu/cpu4/sched_load_boost 10
    write /sys/devices/system/cpu/cpu5/sched_load_boost 10
    write /sys/devices/system/cpu/cpu6/sched_load_boost 10

# ─────────────────────────────────────────────────────────────────────────────
# UFS 3.1 — HPB (Host Performance Boost) + additional queue tuning
# ─────────────────────────────────────────────────────────────────────────────
    # HPB (Host Performance Boost): host stores L2P (logical-to-physical) mapping
    # table for hot LBAs in DRAM. On subsequent reads, the host provides the physical
    # address directly — bypasses UFS internal mapping lookup (~20-50μs saved per read).
    # Critical for dex file access during app launch cold-start.
    write /sys/bus/platform/drivers/ufshcd/1d84000.ufshc/hpb_enable 1 || true
    # HPB: allow up to 4096 cached mapping entries (default 512).
    # dex files for large apps (System UI, Settings, Chrome) span many LBAs.
    write /sys/bus/platform/drivers/ufshcd/1d84000.ufshc/hpb_host_control/hpb_map_cnt 4096 || true

    # UFS write turbo: allow UFS to use all available buffer for write bursts.
    # During app install or large file copy, bursty writes would otherwise stall
    # waiting for the UFS internal buffer to flush.
    write /sys/block/sda/queue/write_cache on 1 || true

    # I/O scheduler: mq-deadline with these queue depths gives optimal throughput
    # for the mixed random+sequential pattern of app workloads on UFS 3.1.
    # front_merges=1: merge adjacent front requests — reduces seeks on dex reads.
    write /sys/block/sda/queue/iosched/front_merges 1 || true
    # fifo_batch=16: process 16 expired requests per scheduler tick vs default 16.
    # Higher batch = better throughput at the cost of slightly more latency variance.
    write /sys/block/sda/queue/iosched/fifo_batch 16 || true

# ─────────────────────────────────────────────────────────────────────────────
# Thermal zone — expanded OP9 Pro sensor coverage
# ─────────────────────────────────────────────────────────────────────────────
    # zone3 = PMIC (PM8350) thermal sensor — power management IC.
    # Fast poll: PMIC temp directly affects BCL (battery current limit) threshold.
    # If the PMIC overheats, BCL cuts CPU/GPU frequency hard — we want early warning.
    write /sys/class/thermal/thermal_zone3/polling_delay 1000
    # zone4 = Wi-Fi/modem PA thermal — 5G NR sub-6 PA runs hot.
    # 2s poll is sufficient; PA thermal is slow-moving vs CPU junction temp.
    write /sys/class/thermal/thermal_zone4/polling_delay 2000
    # zone6 = Adreno 660 GPU thermal — critical for sustained gaming workloads.
    # 1s polling: GPU temp can spike 15°C/s in heavy Vulkan workloads on 888.
    write /sys/class/thermal/thermal_zone6/polling_delay 1000
    # zone7 = NPU/DSP thermal — used by Hasselblad camera AI pipeline.
    # 3s: NPU workloads are bursty; slow poll avoids unnecessary throttle interrupt.
    write /sys/class/thermal/thermal_zone7/polling_delay 3000
    # zone11 = NSPSS (Neural Signal Processing) — runs during Face Unlock.
    write /sys/class/thermal/thermal_zone11/polling_delay 2000
    # zone13 = CPU Prime cluster junction — the most critical thermal sensor.
    # 500ms: X1 can gain 8-10°C/s under sustained load. 500ms catches within 5°C.
    write /sys/class/thermal/thermal_zone13/polling_delay 500

# ─────────────────────────────────────────────────────────────────────────────
# VM — additional tuning for QHD+ LPDDR5 working set
# ─────────────────────────────────────────────────────────────────────────────
    # Zone reclaim: disable NUMA zone reclaim — SM8350 is UMA (single memory node).
    # Enabling it would cause unnecessary memory compaction on a UMA system.
    write /proc/sys/vm/zone_reclaim_mode 0

    # Proactive compaction: kernel compacts memory periodically in background
    # rather than waiting for allocation failure. Reduces allocation latency
    # during heavy UI transitions (launcher, multitasking) by keeping large
    # contiguous pages available for THP and GPU DMA allocations.
    write /proc/sys/vm/compaction_proactiveness 20

    # percpu_pagelist_high_fraction: larger per-CPU page cache.
    # Higher value = fewer cross-CPU page allocations = lower allocation latency.
    # On SM8350 with 8 CPUs, each CPU gets a larger hot-page pool for its allocations.
    write /proc/sys/vm/percpu_pagelist_high_fraction 8

    # Dirty writeback: coalesce dirty page writebacks into fewer, larger UFS bursts.
    # 6000cs (60s writeback interval) batches dirty data — UFS 3.1 handles large
    # sequential writes far more efficiently than many small random writes.
    # dirty_writeback=3000cs (30s): batches enough for large sequential UFS writes
    # without the 60s I/O stall hitches that 6000cs caused during heavy file ops.
    write /proc/sys/vm/dirty_writeback_centisecs 3000
    write /proc/sys/vm/dirty_expire_centisecs 3000

    # numa_balancing: disable — irrelevant on UMA, wastes CPU time scanning pages.
    write /proc/sys/kernel/numa_balancing 0

# ─────────────────────────────────────────────────────────────────────────────
# Network — IPv6 buffer + TCP optimisations for Wi-Fi 6 / 5G NR
# ─────────────────────────────────────────────────────────────────────────────
    # IPv6 socket buffers — Wi-Fi 6 and 5G NR both use IPv6 by default.
    # Without these the kernel uses IPv4 rmem/wmem values for v6 sockets,
    # which were set for peak throughput not latency. Match the v4 values.
    write /proc/sys/net/ipv6/conf/all/use_tempaddr 2
    write /proc/sys/net/core/rmem_max 8388608
    write /proc/sys/net/core/wmem_max 8388608
    # TCP BBR: already set; ensure it also applies to IPV6 sockets
    write /proc/sys/net/ipv4/tcp_congestion_control bbr

    # TCP MPTCP (Multipath TCP): not available on OOS kernel, but if present:
    # allows simultaneous Wi-Fi + 5G data paths. Leave as comment — enabling
    # on non-MPTCP kernels harmlessly fails the write.
    # write /proc/sys/net/mptcp/enabled 1

    # tcp_limit_output_bytes: limit bytes queued per TCP socket.
    # 131072 (128KB) prevents a single socket from holding the TX queue
    # while latency-sensitive traffic (VoIP, gaming) waits behind it.
    write /proc/sys/net/ipv4/tcp_limit_output_bytes 131072

    # tcp_notsent_lowat: wake the app to send more data only when the kernel
    # send buffer drops below 131072. Reduces CPU wakeups on streaming sockets
    # (YouTube, Spotify) which otherwise wake the socket thread too early.
    write /proc/sys/net/ipv4/tcp_notsent_lowat 131072

# ─────────────────────────────────────────────────────────────────────────────
# Warp Charge 65T — enhanced thermal-aware charging
# ─────────────────────────────────────────────────────────────────────────────
on property:sys.warpcharge.display_on=1
    # Display on during charge: reduce current to limit self-heating.
    # At 3A the battery + display together generate enough heat to trigger BCL
    # and throttle the CPU/GPU — capping charge during screen-on prevents this.
    write /sys/class/power_supply/battery/input_current_limit 2000000

on property:sys.warpcharge.display_on=0
    # Display off: full Warp 65T current — no thermal concern.
    write /sys/class/power_supply/battery/input_current_limit 3000000

on property:sys.thermal.gaming_mode=1
    # Gaming mode thermal: allow slightly higher skin temp before charge throttle.
    # Games stress CPU/GPU heavily; slightly reduced charge rate prevents the
    # cumulative thermal load from triggering a hard BCL shutdown mid-session.
    write /sys/class/power_supply/battery/input_current_limit 1500000

OP9PROEOF

            # ── OP9 Pro: thermal-engine.conf — vapour chamber specific
            # The Pro's vapour chamber + graphite stack allows a higher sustained
            # skin temperature before the user perceives warmth vs bare OP9.
            # This block makes throttling less aggressive and recovery faster.
            if [[ -f "$VENDOR_PATH/etc/thermal-engine.conf" ]]; then
                # OP9 Pro thermal: base block set 46°C→46.5°C + 100ms poll.
                # Pro's vapour chamber earns 0.5°C more headroom + slightly slower poll.
                # 47.5°C trip: enough to prevent hair-trigger throttle on vapour-cooled 888
                # 150ms poll (vs 100ms base): chamber slows heat spread so slightly less
                #   frequent reads still catch spikes — avoids 200ms+ which is dangerous
                # hysteresis 2000ms: faster recovery because chamber clears junction faster
                # trip_point: 46.5→47.5°C (0.5° more than base SM8350 block added).
                # Vapour chamber + graphite stack delays surface heat by ~1.5°C vs bare OP9.
                # 47.5°C is the maximum safe trip before the user perceives warmth on
                # the aluminium frame — above this user comfort drops noticeably.
                sed -i 's/trip_point=46500/trip_point=47500/g'                     "$VENDOR_PATH/etc/thermal-engine.conf"
                # hysteresis=1500ms: faster recovery than base block's 3000ms.
                # Vapour chamber clears junction heat in ~800ms — 1500ms re-engages
                # the throttle just as the thermal wave arrives at the outer sensors.
                sed -i 's/hysteresis=3000/hysteresis=1500/g'                     "$VENDOR_PATH/etc/thermal-engine.conf"
                # CPU sensor sampling 100→200ms: 888 thermal spikes faster than 865,
                # but the vapour chamber makes fast sampling counterproductive —
                # 100ms catches transients the chamber would clear in <50ms,
                # causing unnecessary throttle. 200ms matches the chamber response time.
                sed -i 's/sampling=100/sampling=200/g'                     "$VENDOR_PATH/etc/thermal-engine.conf"
                # Skin sensor 2000→4000ms: vapour chamber makes skin a very lagging
                # indicator — fast skin polling causes oscillating throttle behaviour.
                sed -i 's/sampling=2000/sampling=4000/g'                     "$VENDOR_PATH/etc/thermal-engine.conf"
                # BCL ibat thresholds: raise for Warp 65T VRM capability.
                # Default 3500mA threshold fires during normal Warp charging + gaming.
                # Pro's battery management IC + VRM handles 4800mA sustained without issue.
                sed -i 's/ibat_high=3500/ibat_high=4800/g'                     "$VENDOR_PATH/etc/thermal-engine.conf" 2>/dev/null || true
                sed -i 's/ibat_low=3000/ibat_low=4200/g'                     "$VENDOR_PATH/etc/thermal-engine.conf" 2>/dev/null || true
                # Charging temp cutoff: 38→42°C.
                # At 38°C the charger steps down even during normal ambient temperature use.
                # 42°C is the electrochemical limit for LiPo — safe margin while avoiding
                # constant partial-power charging that degrades battery life over time.
                sed -i 's/batt_temp_charge_limit_low=38/batt_temp_charge_limit_low=42/g'                     "$VENDOR_PATH/etc/thermal-engine.conf" 2>/dev/null || true
                green "OP9 Pro thermal-engine.conf patched (vapour chamber profile)"
            else
                yellow "OP9 Pro: thermal-engine.conf not found — skipping thermal patch"
            fi

            # 8GB OP9 Pro: reduce swappiness from 30 to 20.
            # 12GB gets patched to 10 below. 8GB stays at 30 by default which
            # causes aggressive background app swapping and visible relaunches.
            # 20 gives the kernel room to reclaim without thrashing the app stack.
            if [[ "${is_12gb_variant}" != true ]]; then
                sed -i 's|/vm/swappiness 30|/vm/swappiness 20|' \
                    "$VENDOR_PATH/etc/init/op9_sched.rc"
            fi

            # ── OP9 Pro: 12GB RAM overlay
            if [[ "${is_12gb_variant}" == true ]]; then
                # X1 prime floor: 1728000kHz — 12GB means no swap pressure,
                # so we can keep prime warmer at the cost of slightly higher idle power
                sed -i 's|cpu7/cpufreq/scaling_min_freq 1516800|cpu7/cpufreq/scaling_min_freq 1728000|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # hispeed on X1 jumps to 1728000 directly (skip 1516800 step)
                sed -i 's|cpu7/cpufreq/schedutil/hispeed_freq 1516800|cpu7/cpufreq/schedutil/hispeed_freq 1728000|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # A78 floor: 1478400kHz — more RAM = can afford warmer big cores
                for c in cpu4 cpu5 cpu6; do
                    sed -i "s|${c}/cpufreq/scaling_min_freq 1363200|${c}/cpufreq/scaling_min_freq 1478400|" \
                        "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                done
                sed -i 's|cpu4/cpufreq/schedutil/hispeed_freq 1363200|cpu4/cpufreq/schedutil/hispeed_freq 1478400|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # GPU min: 300MHz — can push higher without swap-induced thermal runaway
                sed -i 's|kgsl-3d0/min_gpuclk 257000000|kgsl-3d0/min_gpuclk 300000000|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                sed -i 's|kgsl-3d0/devfreq/min_freq 257000000|kgsl-3d0/devfreq/min_freq 300000000|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # Post-boot GPU floor re-assert also needs to match
                sed -i 's|3d0/min_gpuclk 257000000|3d0/min_gpuclk 300000000|g' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                sed -i 's|3d0/devfreq/min_freq 257000000|3d0/devfreq/min_freq 300000000|g' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # Post-boot CPU floor re-asserts
                sed -i 's|cpu7/cpufreq/scaling_min_freq 1516800$|cpu7/cpufreq/scaling_min_freq 1728000|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # DDR boost: 12GB variant benefits from higher LPDDR5 bus floor
                # More RAM = more concurrent app frames in flight = more DDR bandwidth needed
                sed -i 's|bus_dcvs/DDR/boost_freq 2092000|bus_dcvs/DDR/boost_freq 2733000|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # uclamp: 12GB can afford slightly higher top-app floor
                # Base is now 55 — 12GB bumps to 60 (more RAM = less thermal pressure)
                sed -i 's|cpu.uclamp.min 55$|cpu.uclamp.min 60|' \
                    "$VENDOR_PATH/etc/init/op9pro_perf.rc"
                # Swappiness: 10 (vs default 30) — with 12GB LPDDR5, swap is almost never needed
                sed -i 's|/vm/swappiness 30|/vm/swappiness 10|' \
                    "$VENDOR_PATH/etc/init/op9_sched.rc"
                # zram: reduce to 2GB on 12GB variant (vs 3GB on 8GB variant)
                # 12GB phones rarely need compressed swap — smaller zram = less CPU for compression
                sed -i 's|zram0/disksize 3221225472|zram0/disksize 2147483648|' \
                    "$VENDOR_PATH/etc/init/op9_sched.rc" 2>/dev/null || true
                green "OP9 Pro 12GB performance overlay applied"
            fi

            # ── OP9 Pro: Additional performance props injected into bruce/build.prop
            # These are not already set by the Smoothness block above.

            # Vulkan pre-rotation: eliminates the GPU blit needed to rotate the
            # framebuffer for portrait apps on a landscape-native display pipeline.
            # On QHD+ panels this blit costs 0.3-0.5ms/frame — saved every frame.
            set_prop "$VENDOR_PATH/default.prop" "ro.surface_flinger.enable_frame_rate_override=false"
            set_prop "$VENDOR_PATH/default.prop" "ro.surface_flinger.set_idle_timer_ms=700"
            set_prop "$VENDOR_PATH/default.prop" "ro.surface_flinger.set_touch_timer_ms=300"

            # JIT threshold: lower value = hot methods promoted to AOT faster.
            # On X1 the JIT interpreter overhead vs AOT is ~8% IPC — reducing
            # threshold means fewer frames spend time in JIT-interpreted code.
            set_prop "$SYSTEM_PATH/build.prop" "dalvik.vm.jitthreshold=250"
            set_prop "$SYSTEM_PATH/build.prop" "dalvik.vm.jitinitialsize=64m"
            set_prop "$SYSTEM_PATH/build.prop" "dalvik.vm.jitmaxsize=512m"

            # ART inline cache: 0 = use profile-guided inlining fully.
            # Enables X1 to inline across call sites that weren't seen in training data.
            set_prop "$SYSTEM_PATH/build.prop" "dalvik.vm.jit.codecachesize=0"

            # IORap readahead: record + prefetch app file access on next launch.
            # On UFS 3.1 this cuts cold-launch I/O wait by 40-60ms for large apps.
            set_prop "$SYSTEM_PATH/build.prop" "ro.iorapd.enable=true"
            set_prop "$SYSTEM_PATH/build.prop" "persist.iorapd.enable=true"
            set_prop "$SYSTEM_PATH/build.prop" "ro.iorapd.perfetto_enable=true"

            # Fling velocity: higher ceiling = faster scroll momentum on 120Hz LTPO.
            set_prop "$SYSTEM_PATH/build.prop" "ro.min.fling_velocity=160"
            set_prop "$SYSTEM_PATH/build.prop" "ro.max.fling_velocity=24000"

            # GC: CMS has lower stop-the-world pause than default ConcurrentCopying
            # for a 512m heap — each GC pause costs the full duration off benchmarks.
            set_prop "$SYSTEM_PATH/build.prop" "dalvik.vm.gctype=CMS"

            # PHR (Predictive Headroom): pre-boosts CPU before the next frame budget opens.
            # render_ahead=3: look 3 frames ahead on 120Hz = 25ms headroom window.
            # On OP9 Pro LTPO this eliminates the 8-12ms freq ramp at frame start.
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.phr.target_fps=120"
            set_prop "$VENDOR_PATH/default.prop" "ro.vendor.perf.phr.enable=1"
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.phr.render_ahead=3"
            set_prop "$VENDOR_PATH/default.prop" "ro.vendor.perf.pfar.enable=1"

            # Sched boost on top-app: EAS boost when top-app has CPU demand.
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.sched_boost_on_top_app=1"

            # LPM prediction off: kernel's LPM predictor speculatively deep-sleeps CPUs.
            # Kills X1 responsiveness between frames. Already in rc; prop reinforces it.
            set_prop "$VENDOR_PATH/default.prop" "vendor.power.lpm_prediction=false"
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.qti.lpm.prediction=false"

            # DCVS mode 2: bus DCVS votes higher before load arrives (vs reactive default).
            # Eliminates memory stall ramp-up penalty on MC workloads.
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.qti.display.dcvs_mode=2"
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.qti.bus.dcvs=true"
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.ddr.bw_boost=true"
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.cci_boost=true"
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.llcc.wt_aggr=1"
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.qti.llcc.retentionmode=1"

            # BCL: raise battery current threshold before freq reduction kicks in.
            # Pro's 4500mAh + Warp 65T VRM handles 4500mA sustained comfortably.
            set_prop "$VENDOR_PATH/default.prop" "vendor.thermal.bcl.ibat.mitigate=4500"
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.qti.bcl.enabled=true"

            # Thermal strategy: use slow-averaging vs peak — vapour chamber spreads heat.
            set_prop "$VENDOR_PATH/default.prop" "vendor.thermal.skin.temp.sample=4"
            set_prop "$VENDOR_PATH/default.prop" "persist.thermal.config=perf_profile"

            # Background interference: park background threads during perf hint window.
            set_prop "$SYSTEM_PATH/build.prop" "ro.config.max_starting_bg=4"
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.bg_app_suspend.enable=true"

            # mpctlv3: QTI perf daemon protocol v3 — enables cluster-level freq lock.
            set_prop "$VENDOR_PATH/default.prop" "vendor.perf.mpctlv3.enable=true"

            # HWUI caches: larger pools for QHD+ texture-heavy UIs.
            set_prop "$VENDOR_PATH/default.prop" "debug.hwui.texture_cache_size=96"
            set_prop "$VENDOR_PATH/default.prop" "debug.hwui.layer_cache_size=64"
            set_prop "$VENDOR_PATH/default.prop" "debug.hwui.r_buffer_cache_size=12"
            set_prop "$VENDOR_PATH/default.prop" "debug.hwui.path_cache_size=48"
            set_prop "$VENDOR_PATH/default.prop" "debug.hwui.drop_shadow_cache_size=8"
            set_prop "$VENDOR_PATH/default.prop" "debug.hwui.shape_cache_size=6"

            # WiFi: QTI enhanced power save + low-latency scan suppression.
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.wifi.enhanced.power.save=1"
            set_prop "$VENDOR_PATH/default.prop" "ro.wifi.power_save_mode=1"
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.wifi.scan.allow_low_latency_scan=0"

            # Sensors: RT task and wakelock disabled — biggest idle battery win outside CPU.
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.sensors.enable.rt_task=false"
            set_prop "$VENDOR_PATH/default.prop" "persist.vendor.sensors.support_wakelock=false"

            # pm.dexopt: aggressive speed compilation for installed + shared APKs.
            set_prop "$SYSTEM_PATH/build.prop" "pm.dexopt.install=speed"
            set_prop "$SYSTEM_PATH/build.prop" "pm.dexopt.shared_apk=speed"
            set_prop "$SYSTEM_PATH/build.prop" "pm.dexopt.bg-dexopt=speed-profile"
            set_prop "$SYSTEM_PATH/build.prop" "pm.dexopt.boot-after-ota=verify"
            set_prop "$SYSTEM_PATH/build.prop" "pm.dexopt.downgrade_after_inactive_days=7"

            # Job scheduler optimization: batch background jobs more aggressively.
            set_prop "$SYSTEM_PATH/build.prop" "persist.sys.job_scheduler_optimization_enabled=true"

            # Zygote preload: more Java classes warm in Zygote = faster app fork cold-start.
            set_prop "$SYSTEM_PATH/build.prop" "ro.zygote.preload.enable=true"

            # SF context priority: elevates compositor GL context in Adreno driver queue.
            set_prop "$VENDOR_PATH/default.prop" "ro.surface_flinger.use_context_priority=true"

            green "OP9 Pro performance props injected"
            green "OP9 Pro exclusive profile applied — Rapchick Engine"
        fi
        # ════════════════════════════════════════════════════════════════════
    fi
fi
if [[ "${portIsOOS}" == true || "${portIsColorOSGlobal}" == true || "${portIsColorOS}" == true ]]; then
    blue "Installing Kaorios Toolbox..."

    KAORIOS_REPO="tmp/kaorios"
    KAORIOS_APK="tmp/KaoriosToolbox.apk"
    KAORIOS_XML="tmp/privapp_whitelist_com.kousei.kaorios.xml"
    KAORIOS_VER="V1.0.9"
    KAORIOS_BASE_URL="https://github.com/Wuang26/Kaorios-Toolbox/releases/download/${KAORIOS_VER}"
    FRAMEWORK_SRC="build/portrom/images/system/system/framework/framework.jar"
    PRIV_APP_DIR="build/portrom/images/system_ext/priv-app/KaoriosToolbox"
    PERMS_DIR="build/portrom/images/system_ext/etc/permissions"

    # Validate framework.jar exists before doing anything
    if [[ ! -f "${FRAMEWORK_SRC}" ]]; then
        yellow "Kaorios Toolbox skipped: framework.jar not found at ${FRAMEWORK_SRC}"
    else
        # Clone patcher repo (skip if already cloned from a previous run)
        if [[ ! -d "${KAORIOS_REPO}/.git" ]]; then
            if ! git clone --depth=1 https://github.com/Wuang26/Kaorios-Toolbox.git "${KAORIOS_REPO}"; then
                error "Kaorios Toolbox: failed to clone patcher repo — skipping"
                KAORIOS_SKIP=true
            fi
        fi

        # Download APK
        if [[ ! -f "${KAORIOS_APK}" ]]; then
            if ! wget -q --show-progress -O "${KAORIOS_APK}" \
                    "${KAORIOS_BASE_URL}/KaoriosToolbox-${KAORIOS_VER}.apk"; then
                error "Kaorios Toolbox: failed to download APK — skipping"
                KAORIOS_SKIP=true
            fi
        fi

        # Download privapp whitelist XML
        if [[ ! -f "${KAORIOS_XML}" ]]; then
            if ! wget -q --show-progress -O "${KAORIOS_XML}" \
                    "${KAORIOS_BASE_URL}/com.kousei.kaorios.xml"; then
                error "Kaorios Toolbox: failed to download whitelist XML — skipping"
                KAORIOS_SKIP=true
            fi
        fi

        if [[ "${KAORIOS_SKIP:-false}" != true ]]; then
            # Patch framework.jar with the Toolbox patcher
            PATCHER_DIR="${KAORIOS_REPO}/Toolbox-patcher"
            PATCHED_JAR="${PATCHER_DIR}/framework_patched.jar"

            cp -f "${FRAMEWORK_SRC}" "${PATCHER_DIR}/framework.jar"
            chmod +x "${PATCHER_DIR}/scripts/patcher.sh"

            blue "Patching framework.jar for Kaorios Toolbox..."
            if ! (cd "${PATCHER_DIR}" && ./scripts/patcher.sh framework.jar); then
                error "Kaorios Toolbox: framework.jar patcher failed — skipping install"
                KAORIOS_SKIP=true
            fi
        fi

        if [[ "${KAORIOS_SKIP:-false}" != true ]]; then
            # Validate patcher output
            if [[ ! -f "${PATCHER_DIR}/framework_patched.jar" ]]; then
                error "Kaorios Toolbox: patched framework.jar not produced — skipping"
            else
                # Install patched framework
                cp -f "${PATCHER_DIR}/framework_patched.jar" "${FRAMEWORK_SRC}"

                # Install APK into priv-app (create dir safely)
                mkdir -p "${PRIV_APP_DIR}"
                cp -f "${KAORIOS_APK}" "${PRIV_APP_DIR}/KaoriosToolbox.apk"

                # Install permissions whitelist
                mkdir -p "${PERMS_DIR}"
                cp -f "${KAORIOS_XML}" "${PERMS_DIR}/privapp_whitelist_com.kousei.kaorios.xml"

                # Set correct Android filesystem permissions
                # priv-app directory: 755 (rwxr-xr-x)
                chmod 755 "${PRIV_APP_DIR}"
                # APK file: 644 (rw-r--r--)
                chmod 644 "${PRIV_APP_DIR}/KaoriosToolbox.apk"
                # Permissions XML: 644
                chmod 644 "${PERMS_DIR}/privapp_whitelist_com.kousei.kaorios.xml"

                # Required props — use set_prop to avoid duplicates on re-runs
                set_prop "build/portrom/images/system/system/build.prop" \
                    "persist.sys.kaorios=kousei"
                # Log mode (not enforce) — lets Toolbox's privileged perms load without
                # crashing on builds where the whitelist is incomplete
                set_prop "build/portrom/images/system/system/build.prop" \
                    "ro.control_privapp_permissions=log"

                green "Kaorios Toolbox ${KAORIOS_VER} installed successfully"
            fi
        fi
    fi
    unset KAORIOS_SKIP
fi
targetOplusService=$(find build/portrom/images/ -name "oplus-services.jar")
if [[ -f build/${app_patch_folder}/patched/oplus-services.jar ]];then
    blue "Copying processed oplus-services.jar"
    cp -rfv build/${app_patch_folder}/patched/oplus-services.jar "$targetOplusService"
elif [[ -f "$targetOplusService" ]];then
    blue "Removing GSM Restriction"
    cp -rf "$targetOplusService" tmp/$(basename "$targetOplusService").bak
    java -jar bin/apktool/APKEditor.jar d -f -i "$targetOplusService" -o tmp/OplusService
    targetSmali=$(find tmp -type f -name "OplusBgSceneManager.smali")
    python3 bin/patchmethod.py "$targetSmali" "-isGmsRestricted"
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/OplusService -o build/${app_patch_folder}/patched/oplus-services.jar
    cp -rfv build/${app_patch_folder}/patched/oplus-services.jar "$targetOplusService"
fi
if [[ "${base_device_family}" == "OPSM8250" ]] || [[ "${base_device_family}" == "OPSM8350" ]]; then
    blue "ColorOS16/OxygenOS16: Fixing Face Unlock bug" "COS15/OOS15: Fix Face Unlock for SM8250/8350"
    ensure_resource_available "devices/common/face_unlock_fix_common.zip" || true
    if [[ -f "devices/common/face_unlock_fix_common.zip" ]]; then
        rm -rf build/portrom/images/vendor/overlay/*
        unzip -o devices/common/face_unlock_fix_common.zip -d "${work_dir}/build/portrom/images/"
    fi
    if [[ -f "$old_face_unlock_app" ]]; then
        if [[ -f "${work_dir}/devices/${base_product_device}/face_unlock_fix.zip" ]]; then
            unzip -o "${work_dir}/devices/${base_product_device}/face_unlock_fix.zip" -d "${work_dir}/build/portrom/images/"
            rm -rf build/portrom/images/odm/lib/vendor.oneplus.faceunlock.hal@1.0.so
            rm -rf build/portrom/images/odm/bin/hw/vendor.oneplus.faceunlock.hal@1.0-service
            rm -rf build/portrom/images/odm/lib/vendor.oneplus.faceunlock.hal-V1-ndk_platform.so
            rm -rf build/portrom/images/odm/etc/vintf/manifest/manifest_opfaceunlock.xml
            rm -rf build/portrom/images/odm/etc/init/vendor.oneplus.faceunlock.hal@1.0-service.rc
            rm -rf build/portrom/images/odm/lib64/vendor.oneplus.faceunlock.hal@1.0.so
            rm -rf build/portrom/images/odm/lib64/vendor.oneplus.faceunlock.hal-V1-ndk_platform.so
        fi
    fi
fi
if [[ ${base_device_family} == "OPSM8350" ]] && [[ -f "devices/common/aod_fix_sm8350.zip" ]]; then
    blue "SM8350: Fixing AOD brightness issue" "SM8350: Fix AOD brightness"
    unzip -o devices/common/aod_fix_sm8350.zip -d ${work_dir}/build/portrom/images/
fi
charger_v6_present=$(find build/portrom/images/odm/bin/hw -maxdepth 1 -type f -name "vendor.oplus.hardware.charger-V6-service")
if [[ -z "${charger_v6_present}" ]]; then
    while IFS= read -r charger_file; do
        relative_path=${charger_file#"build/baserom/images/"}
        dest_path="build/portrom/images/${relative_path}"
        mkdir -p "$(dirname "$dest_path")"
        cp -rfv "$charger_file" "$dest_path"
    done < <(find build/baserom/images/odm build/baserom/images/vendor -type f -name "vendor.oplus.hardware.charger*")
fi
if [[ "${base_android_version}" == 13 ]] && [[ "${port_android_version}" == 14 ]];then
    ensure_resource_available "devices/common/a13_base_fix.zip" || true
    if [[ -f "devices/common/a13_base_fix.zip" ]]; then
        unzip -o devices/common/a13_base_fix.zip -d "${work_dir}/build/portrom/images/"
        rm -rfv build/portrom/images/odm/bin/hw/vendor.oplus.hardware.charger@1.0-service \
            build/portrom/images/odm/bin/hw/vendor.oplus.hardware.wifi@1.1-service \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.charger@1.0-service.rc \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.felica@1.0-service.rc \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.midas@1.0-service.rc \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.wifi@1.1-service-qcom.rc \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_charger.xml \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_felica.xml \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_midas.xml \
            build/portrom/images/odm/etc/vintf/manifest/oplus_wifi_service_device.xml \
            build/portrom/images/odm/framework/vendor.oplus.hardware.wifi-V1.1-java.jar \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.felica@1.0-impl.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.felica@1.0.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.wifi@1.1.so \
            build/portrom/images/odm/overlay/CarrierConfigOverlay.*.apk
    fi
fi
if [[ "${port_android_version}" -ge 15 ]]; then
    if [[ "${base_device_family}" == "OPSM8250" ]] && [[ "${base_android_version}" != 13 ]];then
        ensure_resource_available "devices/common/ril_fix_sm8250.zip" || true
    if [[ -f "devices/common/ril_fix_sm8250.zip" ]]; then
            unzip -o devices/common/ril_fix_sm8250.zip -d "${work_dir}/build/portrom/images/"
            rm -rf build/portrom/images/odm/lib/libmindroid-app.so \
                build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
                build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys-V1-ndk_platform.so
        fi
    elif [[ "${base_device_family}" == "OPSM8350" ]];then
        ensure_resource_available "devices/common/ril_fix_sm8350.zip" || true
    if [[ -f "devices/common/ril_fix_sm8350.zip" ]]; then
            unzip -o devices/common/ril_fix_sm8350.zip -d "${work_dir}/build/portrom/images/"
            rm -rf build/portrom/images/odm/lib/libmindroid-app.so \
                build/portrom/images/odm/lib/libmindroid-framework.so \
                build/portrom/images/odm/lib/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
                build/portrom/images/odm/lib/vendor.oplus.hardware.subsys-V1-ndk_platform.so \
                build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
                build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys-V1-ndk_platform.so
        fi
    fi
    if [[ ${base_device_family} == "OPSM8350" ]] && \
       ([[ "${base_product_device}" == "OnePlus9Pro" ]] || [[ "${base_product_device}" == "OnePlus9" ]]) && \
       [[ -f "devices/common/odm_telephony_subsys_fix_op9pro_sm8350.zip" ]]; then
        blue "OP9/9Pro: ODM telephony/subsys patch" "OP9/9Pro: Applying ODM telephony/subsys patch"
        unzip -o devices/common/odm_telephony_subsys_fix_op9pro_sm8350.zip -d ${work_dir}/build/portrom/images/
        rm -f build/portrom/images/odm/etc/vintf/network_manifest_dsds.xml \
              build/portrom/images/odm/etc/vintf/network_manifest_ssss.xml
        ln -sf telephony_manifest_dsds.xml build/portrom/images/odm/etc/vintf/network_manifest_dsds.xml
        ln -sf telephony_manifest_ssss.xml build/portrom/images/odm/etc/vintf/network_manifest_ssss.xml
        rm -f build/portrom/images/odm/lib/vendor.oplus.hardware.subsys-V1-ndk_platform.so \
              build/portrom/images/odm/lib/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
              build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys-V1-ndk_platform.so \
              build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so
    fi
    if [[ ${base_device_family} == "OPSM8350" ]] && \
       ([[ "${base_product_device}" == "OnePlus9Pro" ]] || [[ "${base_product_device}" == "OnePlus9" ]]) && \
       [[ -f "devices/common/odm_sendextcamcmd_fix_op9_sm8350.zip" ]]; then
        blue "OP9/9Pro: ODM sendextcamcmd patch" "OP9/9Pro: Applying ODM sendextcamcmd patch"
        unzip -o devices/common/odm_sendextcamcmd_fix_op9_sm8350.zip -d ${work_dir}/build/portrom/images/
    fi
    if [[ ${base_android_version} == 14 ]]; then
        charger_v3=$(find build/portrom/images/odm/bin/hw/ -type f -name "vendor.oplus.hardware.charger-V3-service")
        if [[ -f $charger_v3 ]];then
            ensure_resource_available "devices/common/charger-v6-update.zip" || true
    if [[ -f "devices/common/charger-v6-update.zip" ]]; then
                unzip -o devices/common/charger-v6-update.zip -d ${work_dir}/build/portrom/images/
                rm -rf build/portrom/images/odm/bin/hw/vendor.oplus.hardware.charger-V3-service \
                    build/portrom/images/odm/etc/init/vendor.oplus.hardware.charger-V3-service.rc \
                    build/portrom/images/odm/lib/vendor.oplus.hardware.charger-V3-ndk_platform.so \
                    build/portrom/images/odm/lib64/vendor.oplus.hardware.charger-V3-ndk_platform.so
            fi
        fi
    elif [[ ${base_android_version} == 13 ]];then
        ensure_resource_available "devices/common/ril_fix_a13_to_a15.zip" || true
    if [[ -f "devices/common/ril_fix_a13_to_a15.zip" ]]; then
            unzip -o devices/common/ril_fix_a13_to_a15.zip -d ${work_dir}/build/portrom/images/
        fi
        if ! grep -q "persist.vendor.radio.virtualcomm" build/portrom/images/odm/build.prop;then
            echo "persist.vendor.radio.virtualcomm=1" >> build/portrom/images/odm/build.prop
        fi
        rm -rf build/portrom/images/odm/bin/hw/vendor.oplus.hardware.charger@1.0-service \
            build/portrom/images/odm/bin/hw/vendor.oplus.hardware.wifi@1.1-service \
            build/portrom/images/odm/etc/init/vendor.oneplus.faceunlock.hal@1.0-service.rc \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.charger@1.0-service.rc \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.felica@1.0-service.rc \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.midas@1.0-service.rc \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.wifi@1.1-service-qcom.rc \
            build/portrom/images/odm/etc/vintf/manifest/manifest_opfaceunlock.xml \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_charger.xml \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_cryptoeng_hidl.xml \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_felica.xml \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_midas.xml \
            build/portrom/images/odm/etc/vintf/manifest/oplus_wifi_service_device.xml \
            build/portrom/images/odm/framework/vendor.oplus.hardware.wifi-V1.1-java.jar \
            build/portrom/images/odm/lib/vendor.oneplus.faceunlock.hal@1.0.so \
            build/portrom/images/odm/lib/vendor.oneplus.faceunlock.hal-V1-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oneplus.faceunlock.hal@1.0.so \
            build/portrom/images/odm/lib64/vendor.oneplus.faceunlock.hal-V1-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.felica@1.0-impl.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.felica@1.0.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys-V1-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.wifi@1.1.so
        if [[ -f "devices/common/nfc_fix_for_a13.zip" ]]; then
            unzip -o devices/common/nfc_fix_for_a13.zip -d ${work_dir}/build/portrom/images/
            rm -rf build/portrom/images/odm/bin/hw/vendor.oplus.hardware.nfc@1.0-service \
                build/portrom/images/odm/etc/init/vendor.oplus.hardware.nfc@1.0-service.rc \
                build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_nfc.xml \
                build/portrom/images/odm/lib/vendor.oplus.hardware.nfc@1.0.so
        fi
        if [[ -f "devices/common/cryptoeng_fix_a13.zip" ]]; then
            unzip -o devices/common/cryptoeng_fix_a13.zip -d ${work_dir}/build/portrom/images/
        fi
    fi
fi
echo "ro.surface_flinger.game_default_frame_rate_override=120" >> build/portrom/images/vendor/default.prop
targetAICallAssistant=$(find build/portrom/images/ -name "HeyTapSpeechAssist.apk")
if [[ -f "build/${app_patch_folder}/patched/HeyTapSpeechAssist.apk" ]]; then
    blue "Copying processed HeyTapSpeechAssist.apk"
    cp -rfv "build/${app_patch_folder}/patched/HeyTapSpeechAssist.apk" "$targetAICallAssistant"
elif [[ -f "$targetAICallAssistant" ]];then
        blue "Unlock AI Call"
        cp -rf "$targetAICallAssistant" "tmp/$(basename "$targetAICallAssistant").bak"
        java -jar bin/apktool/APKEditor.jar d -f -i "$targetAICallAssistant" -o tmp/HeyTapSpeechAssist $extra_args
        targetSmali=$(find tmp -type f -name "AiCallCommonBean.smali")
        python3 bin/patchmethod_v2.py "$targetSmali" getSupportAiCall -return true
        find tmp/HeyTapSpeechAssist -type f -name "*.smali" -exec sed -i "s/sget-object \([vp][0-9]\+\), Landroid\/os\/Build;->MODEL:Ljava\/lang\/String;/const-string \1, \"PLG110\"/g" {} +
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/HeyTapSpeechAssist -o "build/${app_patch_folder}/patched/HeyTapSpeechAssist.apk" $extra_args
        cp -rfv "build/${app_patch_folder}/patched/HeyTapSpeechAssist.apk" "$targetAICallAssistant"
fi
ota_patched=false
if [[ "$regionmark" == "CN" ]] && [[ -f "devices/common/OTA_CN.apk" ]]; then
    cp -rf devices/common/OTA_CN.apk build/portrom/images/system_ext/app/OTA/OTA.apk && ota_patched=true
elif [[ -f "devices/common/OTA_IN.apk" ]]; then
    cp -rf devices/common/OTA_IN.apk build/portrom/images/system_ext/app/OTA/OTA.apk && ota_patched=true
fi
if [[ "$ota_patched" == "false" ]];then
    targetOTA=$(find build/portrom/images/ -name "OTA.apk")
    if [[ -f "build/${app_patch_folder}/patched/OTA.apk" ]]; then
        blue "Copying processed OTA.apk"
        cp -rfv "build/${app_patch_folder}/patched/OTA.apk" "$targetOTA"
    elif [[ -f "$targetOTA" ]];then
        blue "Removing OTA dm-verity"
        cp -rf "$targetOTA" "tmp/$(basename "$targetOTA").bak"
        java -jar bin/apktool/APKEditor.jar d -f -i "$targetOTA" -o tmp/OTA $extra_args
        targetSmali=$(find tmp -type f -path "*/com/oplus/common/a.smali")
        python3 bin/patchmethod_v2.py -d tmp/OTA -k ro.boot.vbmeta.device_state locked -return false
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/OTA -o "build/${app_patch_folder}/patched/OTA.apk" $extra_args
         cp -rfv "build/${app_patch_folder}/patched/OTA.apk" "$targetOTA"
    fi
fi
EXTEDNED_MODELS=("PJF110" "PEEM00" "PEDM00" "LE2120" "LE2121" "LE2123" "KB2000" "KB2001" "KB2005" "KB2003" "LE2110" "LE2111" "LE2112" "LE2113" "IN2010" "IN2011" "IN2012" "IN2013" "IN2020" "IN2021" "IN2022" "IN2023")
targetAIUnit=$(find build/portrom/images/ -name "AIUnit.apk")
MODEL=PLG110
[[ "$regionmark" != CN ]] && MODEL=CPH2745
if [[ -f "build/${app_patch_folder}/patched/AIUnit.apk" ]]; then
    blue "Copying processed AIUnit.apk"
    cp -rfv "build/${app_patch_folder}/patched/AIUnit.apk" "$targetAIUnit"
elif [[ -f "$targetAIUnit" ]];then
    blue "Unlock High-End AI features, Device Model: $MODEL"
    cp -rf "$targetAIUnit" "tmp/$(basename "$targetAIUnit").bak"
    java -jar bin/apktool/APKEditor.jar d -f -i "$targetAIUnit" -o tmp/AIUnit $extra_args
    find tmp/AIUnit -type f -name "*.smali" -exec sed -i "s/sget-object \([vp][0-9]\+\), Landroid\/os\/Build;->MODEL:Ljava\/lang\/String;/const-string \1, \"$MODEL\"/g" {} +
    targetSmali=$(find tmp -type f -name "UnitConfig.smali")
    python3 bin/patchmethod_v2.py "$targetSmali" isAllWhiteConditionMatch
    python3 bin/patchmethod_v2.py "$targetSmali" isWhiteConditionsMatch
    python3 bin/patchmethod_v2.py "$targetSmali" isSupport
    unit_config_list=$(find tmp/AIUnit -type f -name "unit_config_list.json")
    jq --arg models_str "${EXTEDNED_MODELS[*]}" '
        ($models_str | split(" ")) as $new_models
        | map(
            if has("whiteModels") and (.whiteModels | type) == "string" then
                .whiteModels as $current |
                if $current == "" then
                    .whiteModels = ($new_models | join(","))
                else
                    ($current | split(",")) as $existing_models |
                    ($new_models | map(select(. as $m | $existing_models | index($m) == null))) as $unique_models |
                    if ($unique_models | length) > 0 then
                        .whiteModels = $current + "," + ($unique_models | join(","))
                    else . end
                end
            else . end
            | if has("minAndroidApi") then .minAndroidApi = 30 else . end
        )
    ' "$unit_config_list" > "${unit_config_list}.bak" && mv "${unit_config_list}.bak" "$unit_config_list"
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/AIUnit -o "build/${app_patch_folder}/patched/AIUnit.apk" $extra_args
    cp -rfv "build/${app_patch_folder}/patched/AIUnit.apk" "$targetAIUnit"
fi
if [[ "$port_android_version" == 16 ]] && [[ "$base_android_version" -lt 15 ]] ;then
    cp build/portrom/images/odm/lib64/libaiboost.so build/portrom/images/my_product/lib64/libaiboost.so
fi
if [[ -f devices/common/xeutoolbox.zip ]] && [[ "$base_android_version" -lt 15 ]] && [[ "${portIsColorOSGlobal}" != true ]];then
    blue "Integrated Xiami EU xeutoolbox"
    unzip -o devices/common/xeutoolbox.zip -d build/portrom/images/
    echo "/system_ext/xbin/xeu_toolbox u:object_r:toolbox_exec:s0" >> build/portrom/images/config/system_ext_file_contexts
    echo "/system_ext/xbin/xeu_toolbox u:object_r:toolbox_exec:s0" >> build/portrom/images/system_ext/etc/selinux/system_ext_file_contexts
    echo "(allow init toolbox_exec (file ((execute_no_trans))))" >> build/portrom/images/system_ext/etc/selinux/system_ext_sepolicy.cil
elif [[ "$base_android_version" -lt 15 ]] && [[ "${portIsColorOS}" != "true" ]];then
    targetGallery=$(find build/portrom/images/ -name "OppoGallery2.apk")
    if [[ -f "build/${app_patch_folder}/patched/OppoGallery2.apk" ]]; then
        blue "Copying processed OppoGallery2"
        cp -rfv "build/${app_patch_folder}/patched/OppoGallery2.apk" "$targetGallery"
    elif [[ -f "$targetGallery" ]];then
        blue "Unlock AI Editor"
        cp -rf "$targetGallery" "tmp/$(basename "$targetGallery").bak"
        java -jar bin/apktool/APKEditor.jar d -f -i "$targetGallery" -o tmp/Gallery $extra_args
        python3 bin/patchmethod_v2.py -d tmp/Gallery -k "const-string.*\"ro.product.first_api_level\"" -hook " const/16 reg, 0x22"
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/Gallery -o "build/${app_patch_folder}/patched/OppoGallery2.apk" $extra_args
        cp -rfv "build/${app_patch_folder}/patched/OppoGallery2.apk" "$targetGallery"
    fi
fi
if [[ "${base_device_family}" == "OPSM8250" ]] || [[ "${base_device_family}" == "OPSM8350" ]];then
    targetBattery=$(find build/portrom/images/ -name "Battery.apk")
    if [[ -f build/${app_patch_folder}/patched/Battery.apk ]]; then
        blue "Copying processed Battery.apk"
        cp -rfv build/${app_patch_folder}/patched/Battery.apk "$targetBattery"
    elif [[ -f "$targetBattery" ]];then
        blue "Patch Battery Health Maximum capacity"
        cp -rf "$targetBattery" tmp/$(basename "$targetBattery").bak
        java -jar bin/apktool/APKEditor.jar d -f -i "$targetBattery" -o tmp/Battery $extra_args
        python3 bin/patchmethod_v2.py -d tmp/Battery/ -k "getUIsohValue" -m devices/common/patch_battery_soh.txt
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/Battery -o build/${app_patch_folder}/patched/Battery.apk $extra_args
        cp -rfv build/${app_patch_folder}/patched/Battery.apk "$targetBattery"
    fi
fi
if [[ ${regionmark} != "CN" ]] && [[ ${base_product_model} != "IN20"* ]];then
    targetSettings=$(find build/portrom/images/ -name "Settings.apk")
    if [[ -f "$targetSettings" ]];then
        blue "Charging info in Settings"
        cp -rf "$targetSettings" tmp/$(basename "$targetSettings").bak
        java -jar bin/apktool/APKEditor.jar d -f -i "$targetSettings" -o tmp/Settings $extra_args
        targetSmali=$(find tmp -type f -name "DeviceChargeInfoController.smali")
        python3 bin/patchmethod_v2.py "$targetSmali" isPreferenceSupport -return true
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/Settings -o "$targetSettings" $extra_args
    fi
fi
targetOplusLauncher=$(find build/portrom/images/ -name "OplusLauncher.apk")
if [[ -f "$targetOplusLauncher" ]] && [[ $base_product_first_api_level -gt 34 ]];then
blue "Enabling RAM display"
cp -rf "$targetOplusLauncher" tmp/$(basename "$targetOplusLauncher").bak
java -jar bin/apktool/APKEditor.jar d -f -i "$targetOplusLauncher" -o tmp/OplusLauncher $extra_args
targetSmali=$(find tmp -type f -path "*/com/oplus/basecommon/util/SystemPropertiesHelper.smali")
 python3 bin/patchmethod_v2.py "$targetSmali" getFirstApiLevel ".locals 1\n\tconst/16 v0, 0x22\n\treturn v0"
 java -jar bin/apktool/APKEditor.jar b -f -i tmp/OplusLauncher -o "$targetOplusLauncher" $extra_args
fi
targetSystemUI=$(find build/portrom/images/ -name "SystemUI.apk")
if [[ -f build/${app_patch_folder}/patched/SystemUI.apk ]]; then
        blue "Copying processed SystemUI.apk"
        cp -rfv build/${app_patch_folder}/patched/SystemUI.apk "$targetSystemUI"
    
elif [[ -f "$targetSystemUI" ]]; then
   
    cp -rf "$targetSystemUI" tmp/$(basename "$targetSystemUI").bak
    java -jar bin/apktool/APKEditor.jar d -f -i "$targetSystemUI" -o tmp/SystemUI $extra_args
    blue "Enabling AOD (Panoramic/Fullscreen)"
    targetSmoothTransitionControllerSmali=$(find tmp/SystemUI -type f -name "SmoothTransitionController.smali")
    python3 bin/patchmethod_v2.py "$targetSmoothTransitionControllerSmali" setPanoramicStatusForApplication
    python3 bin/patchmethod_v2.py "$targetSmoothTransitionControllerSmali" setPanoramicSupportAllDayForApplication
    targetAODDisplayUtilSmali=$(find tmp/SystemUI -type f -name "AODDisplayUtil.smali")
    python3 bin/patchmethod_v2.py "$targetAODDisplayUtilSmali" isPanoramicProcessTypeNotSupportAllDay -return false
    if [[ $base_product_first_api_level -gt 34 ]];then
    targetStatusBarFeatureOptionSmali=$(find tmp/SystemUI -type f -name "StatusBarFeatureOption.smali")
    python3 bin/patchmethod_v2.py "$targetStatusBarFeatureOptionSmali" isChargeVoocSpecialColorShow -return true
    fi
    if [[ $regionmark != "CN" ]];then
        blue "Enabling My Device"
        targetSmali=$(find tmp/SystemUI -type f -path "*/systemui/common/feature/FeatureOption.smali")
        python3 bin/patchmethod_v2.py "$targetSmali" isSupportMyDevice -return true
    fi
    blue "Applying CTS patch (isCtsTest)"
    python3 bin/patchmethod_v2.py -d tmp/SystemUI -n isCtsTest -return false
    while IFS= read -r style_xml_file; do
        sed -i "s/style\/null/7f1403f6/g" "$style_xml_file"
    done < <(find tmp/SystemUI -name "styles.xml")
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/SystemUI -o build/${app_patch_folder}/patched/SystemUI.apk $extra_args
    cp -rfv build/${app_patch_folder}/patched/SystemUI.apk "$targetSystemUI"
fi
targetAOD=$(find build/portrom/images/ -name "Aod.apk")
if [[ -f "$targetAOD" ]] && [[ $base_product_first_api_level -le 35 ]] ;then
blue "Forcibly enabling AOD Always-on for older models"
cp -rf "$targetAOD" tmp/$(basename "$targetAOD").bak
java -jar bin/apktool/APKEditor.jar d -f -i "$targetAOD" -o tmp/Aod $extra_args
targetCommonUtilsSmali=$(find tmp -type f -path "*/com/oplus/aod/util/CommonUtils.smali")
    targetSettingsSmali=$(find tmp -type f -path "*/com/oplus/aod/util/SettingsUtils.smali")
    python3 bin/patchmethod_v2.py "$targetCommonUtilsSmali" isSupportFullAod -return true
    python3 bin/patchmethod_v2.py "$targetSettingsSmali" getKeyAodAllDaySupportSettings -return true
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/Aod -o "$targetAOD" $extra_args
fi
yellow "Deleting unnecessary apps" "Debloating..."
debloat_apps=("HeartRateDetect" "Browser")
kept_apps=("OppoNote2" "OppoWeather2")

# Helper: remove a list of apps by directory name from portrom images
do_debloat() {
    local -n _apps="$1"
    for debloat_app in "${_apps[@]}"; do
        while IFS= read -r app_dir; do
            [[ -d "$app_dir" ]] || continue
            yellow "Deleting: $app_dir"
            rm -rf "$app_dir"
        done < <(find build/portrom/images/ -type d -name "*${debloat_app}*")
    done
}

# OOS/KB2000+ specific debloat list (shared between several model branches)
oos_debloat_apps=("Facebook" "YTMusic" "GoogleHome" "GoogleOne" "Videos_del" "Drive_del" "ConsumerIRApp" "YouTube" "Gmail2" "Maps" "Wellbeing" "OPForum" "INOnePlusStore" "Meet")

if [[ "${super_extended}" == true ]] && [[ $pack_method == "stock" ]] && [[ -f build/baserom/images/reserve.img ]]; then
    rm -rf build/baserom/images/reserve.img
elif [[ "${super_extended}" == false ]] && [[ $pack_method == "stock" ]] && [[ -f build/baserom/images/reserve.img ]]; then
    while IFS= read -r delapp; do
        app_name=$(basename "$delapp")
        if [[ " ${kept_apps[*]} " =~ " ${app_name} " ]]; then
            echo "Skipping kept app: $app_name"
            continue
        fi
        rm -rf "$delapp"
    done < <(find build/portrom/images/ -maxdepth 3 -path "*/del-app/*" -type d)
    do_debloat debloat_apps
    cp -rfv devices/common/via build/portrom/images/product/app/
elif [[ "${super_extended}" == false ]] && [[ $base_product_model == "KB2000" ]] && [[ "$is_ab_device" == true ]]; then
    while IFS= read -r delapp; do
        app_name=$(basename "$delapp")
        local_keep=false
        for kept_app in "${kept_apps[@]}"; do
            [[ $app_name == *"$kept_app"* ]] && { local_keep=true; break; }
        done
        [[ "${local_keep}" == false ]] && debloat_apps+=("$app_name")
    done < <(find build/portrom/images/ -maxdepth 3 -path "*/del-app/*" -type d)
    do_debloat debloat_apps
elif [[ "${super_extended}" == false ]] && \
     ([[ $base_product_model == "KB200"* ]] || [[ $base_product_model == "LE2101" ]]) && \
     [[ "$is_ab_device" == true ]]; then
    do_debloat oos_debloat_apps
fi
rm -rf build/portrom/images/product/etc/auto-install*
rm -rf build/portrom/images/system/verity_key
rm -rf build/portrom/images/vendor/verity_key
rm -rf build/portrom/images/product/verity_key
rm -rf build/portrom/images/system/recovery-from-boot.p
rm -rf build/portrom/images/vendor/recovery-from-boot.p
rm -rf build/portrom/images/product/recovery-from-boot.p
sed -i "/ro.oplus.audio.*/d" build/portrom/images/my_product/build.prop
prepare_base_prop
add_prop_from_port
blue "Modifying build.prop files" "Modifying build.prop"
# Try en_US.UTF-8 first; fall back to C.UTF-8 which is always present on Ubuntu/Debian.
# Without a valid locale, sed/grep on UTF-8 filenames can mangle multi-byte chars.
export LANG=en_US.UTF-8 2>/dev/null || export LANG=C.UTF-8
export LC_ALL=en_US.UTF-8 2>/dev/null || export LC_ALL=C.UTF-8
buildDate=$(date -u +"%a %b %d %H:%M:%S UTC %Y")
buildUtc=$(date +%s)
while IFS= read -r i; do
    blue "Processing: ${i}"
    # NOTE: Timezone is set to base ROM's value (Asia/Shanghai for CN, adjust for other regions)
    sed -i "s/persist.sys.timezone=.*/persist.sys.timezone=Asia\/Shanghai/g" "${i}" || true
    # Guard each substitution: only run if the source variable is non-empty,
    # preventing "s//replacement/" which exits 1 and kills the script under set -e
    [[ -n "${port_device_code}" && -n "${base_device_code}" ]] &&         sed -i "s/${port_device_code}/${base_device_code}/g" "${i}" || true
    [[ -n "${port_product_model}" && -n "${base_product_model}" ]] &&         sed -i "s/${port_product_model}/${base_product_model}/g" "${i}" || true
    [[ -n "${port_product_name}" && -n "${base_product_name}" ]] &&         sed -i "s/${port_product_name}/${base_product_name}/g" "${i}" || true
    [[ -n "${port_my_product_type}" && -n "${base_my_product_type}" ]] &&         sed -i "s/${port_my_product_type}/${base_my_product_type}/g" "${i}" || true
    [[ -n "${port_product_device}" && -n "${base_product_device}" ]] &&         sed -i "s/${port_product_device}/${base_product_device}/g" "${i}" || true
    sed -i "s/ro.build.user=.*/ro.build.user=${build_user}/g" "${i}" || true
    [[ -n "${target_display_id}" ]] &&         sed -i "s/ro.build.display.id=.*/ro.build.display.id=${target_display_id}/g" "${i}" || true
    sed -i "s/ro.oplus.radio.global_regionlock.enabled=.*/ro.oplus.radio.global_regionlock.enabled=false/g" "${i}" || true
    sed -i "s/persist.sys.radio.global_regionlock.allcheck=.*/persist.sys.radio.global_regionlock.allcheck=false/g" "${i}" || true
    sed -i "s/ro.oplus.radio.checkservice=.*/ro.oplus.radio.checkservice=false/g" "${i}" || true
    if [[ "${portIsColorOSGlobal}" == true ]]; then
        sed -i 's/=OnePlus[[:space:]]*$/=OPPO/' "${i}" || true
    fi
done < <(find build/portrom/images -type f -name "build.prop" 2>/dev/null || true)
add_prop_v2 "ro.vendor.oplus.market.name" "${base_market_name}"
add_prop_v2 "ro.vendor.oplus.market.enname" "${base_market_name}"
remove_prop_v2 "persist.oplus.software.audio.right_volume_key"
remove_prop_v2 "persist.oplus.software.alertslider.location"
{
    echo "persist.adb.notify=0"
    echo "persist.sys.usb.config=mtp,adb"
    echo "persist.sys.disable_rescue=true"
} >> build/portrom/images/system/system/build.prop
base_rom_density=$(grep "ro.sf.lcd_density" --include="*.prop" -r build/baserom/images/my_product 2>/dev/null | head -n1 | cut -d'=' -f2 || true)
[[ -z "${base_rom_density}" ]] && base_rom_density=480
if [[ ${base_vendor_brand,,} != ${port_vendor_brand,,} ]] && [[ "${portIsColorOSGlobal}" == false ]];then
    sed -i "s/ro.oplus.image.system_ext.brand=.*/ro.oplus.image.system_ext.brand=${base_vendor_brand,,}/g" build/portrom/images/system_ext/etc/build.prop
fi
if [[ -f build/baserom/images/my_product/etc/extension/sys_game_manager_config.json ]];then
    cp -rf build/baserom/images/my_product/etc/extension/sys_game_manager_config.json build/portrom/images/my_product/etc/extension/ || true
else
    rm -rf build/portrom/images/my_product/etc/extension/sys_game_manager_config.json
fi
if [[ ! -f build/baserom/images/my_product/etc/extension/sys_graphic_enhancement_config.json ]];then
    rm -rf build/portrom/images/my_product/etc/extension/sys_graphic_enhancement_config.json
else
    cp -rf build/baserom/images/my_product/etc/extension/sys_graphic_enhancement_config.json build/portrom/images/my_product/etc/extension/ || true
fi
if [[ $(grep "ro.oplus.audio.effect.type" build/baserom/images/my_product/build.prop | cut -d'=' -f2) == "dolby" ]]; then
   blue "Fixing Dolby Acoustics + App Specific volume adjustment (SM8250/SM8350)" "Fix Dolby + App Specific volume adjustment for SM8250/SM8350"
   cp build/baserom/images/my_product/etc/permissions/oplus.product.features_dolby_stereo.xml build/portrom/images/my_product/etc/permissions/oplus.product.features_dolby_stereo.xml
   if [[ -f "devices/common/dolby_fix.zip" ]]; then
       unzip -o devices/common/dolby_fix.zip -d build/portrom/images/
   fi
fi
if [[ -f build/portrom/images/vendor/lib64/vendor.oplus.hardware.radio-V2-ndk_platform.so ]] && \
   [[ ${base_device_family} == "OPSM8350" ]] && \
   [[ -f "devices/common/ril_fix_A16_SM8350.zip" ]]; then
    blue "Fixing RIL..."
    unzip -o devices/common/ril_fix_A16_SM8350.zip -d ${work_dir}/build/portrom/images/vendor/
    rm -f build/portrom/images/vendor/lib/vendor.oplus.hardware.radio-V1-ndk_platform.so \
          build/portrom/images/vendor/lib64/vendor.oplus.hardware.radio-V1-ndk_platform.so
fi
cp -rf build/baserom/images/my_product/etc/audio*.xml build/portrom/images/my_product/etc/ || true
cp -rf build/baserom/images/my_product/etc/default_volume_tables.xml build/portrom/images/my_product/etc/ || true
while IFS= read -r audio_cfg; do
    relative_path=${audio_cfg#"build/baserom/images/"}
    dest_path="build/portrom/images/${relative_path}"
    mkdir -p "$(dirname "$dest_path")"
    cp -rfv "$audio_cfg" "$dest_path"
done < <({
    for d in build/baserom/images/vendor build/baserom/images/odm; do
        [ -d "$d" ] && find "$d" -type f \( -name "audio_policy*.xml" -o -name "audio_platform*.xml" -o -name "mixer_paths*.xml" -o -name "audio_effects*.xml" \)
    done
})
# Only copy Breeno speech model data when NOT doing a GMS injection port.
# For ColorOS CN → GMS ports, Breeno is being replaced by Gemini entirely.
if [[ -d build/baserom/images/my_product/etc/breenospeech2 ]]; then
    if [[ "${portIsColorOS}" == true ]] && [[ "${regionmark}" == "CN" ]]; then
        yellow "GMS port: skipping Breeno speech model copy (breenospeech2)"
    else
        cp -rf build/baserom/images/my_product/etc/breenospeech2/*             build/portrom/images/my_product/etc/breenospeech2/ || true
    fi
fi
rm -rf build/portrom/images/my_product/etc/fusionlight_profile/*
cp -rf build/baserom/images/my_product/etc/fusionlight_profile/* build/portrom/images/my_product/etc/fusionlight_profile/ || true
sed -i "/persist.vendor.display.pxlw.iris_feature=.*/d" build/portrom/images/my_product/etc/bruce/build.prop
if grep -q "ro.build.version.oplusrom.display" build/portrom/images/my_manifest/build.prop;then
    sed -i '/^ro.build.version.oplusrom.display=/ s/$/ /' build/portrom/images/my_manifest/build.prop
else
    sed -i '/^ro.build.version.oplusrom.display=/ s/$/ /' build/portrom/images/my_product/etc/bruce/build.prop
fi
propfile="build/portrom/images/my_product/etc/bruce/build.prop"
if [[ "${portIsColorOSGlobal}" == true ]]; then
    MODEL_MAGIC="CPH2659,BRAND:OPPO"
    MODEL_AIUNIT="CPH2659,BRAND:OPPO"
elif [[ "${portIsOOS}" == true ]]; then
    MODEL_MAGIC="CPH2659,BRAND:OPPO"
    MODEL_AIUNIT="CPH2745,BRAND:OnePlus"
else
    MODEL_MAGIC="PLK110,BRAND:OnePlus"
    MODEL_AIUNIT="PLK110,BRAND:OnePlus"
fi
{
    echo "persist.oplus.prophook.com.oplus.ai.magicstudio=MODEL:${MODEL_MAGIC}"
    echo "persist.oplus.prophook.com.oplus.aiunit=MODEL:${MODEL_AIUNIT}"
} >> "$propfile"
if [[ "$port_vendor_brand" == "realme" ]];then
    echo "persist.oplus.prophook.com.coloros.smartsidebar=\"BRAND:realme\"" >> "$propfile"
fi
remove_prop_v2 "ro.oplus.resolution"
remove_prop_v2 "ro.oplus.display.wm_size_resolution_switch.support"
remove_prop_v2 "ro.density.screenzoom"
remove_prop_v2 "ro.oplus.density.qhd_default"
remove_prop_v2 "ro.oplus.density.fhd_default"
remove_prop_v2 "ro.oplus.key.actionbutton"
remove_prop_v2 "ro.oplus.audio.support.foldingmode"
remove_prop_v2 "ro.config.fold_disp"
remove_prop_v2 "persist.oplus.display.fold.support"
remove_prop_v2 "ro.oplus.haptic"
remove_prop_v2 "ro.vendor.mtk"
remove_prop_v2 "ro.oplus.mtk"
remove_prop_v2 "persist.sys.oplus.wlan.atpc.qcom_use_iw"
remove_prop_v2 "ro.product.oplus.cpuinfo"
if [[ $base_android_version -lt 15 ]] && [[ $port_android_version -gt 15 ]];then
    remove_prop_v2 "ro.lcd.display.screen"
    remove_prop_v2 "ro.display.brightness"
    remove_prop_v2 "ro.oplus.lcd.display"
fi
add_prop_v2 "ro.oplus.game.camera.support_1_0" "true"
add_prop_v2 "ro.oplus.audio.quiet_start" "true"
if [[ "${portIsOOS}" == true ]];then
    remove_prop_v2 "ro.oplus.camera.quickshare.support" force
fi
if [[ $port_android_version -lt 16 ]];then
    if [[ $base_device_family == "OPSM8250" ]] || [[ $base_device_family == "OPSM8350" ]];then
        add_prop_v2 "persist.sys.oplus.anim_level" "2"
    else
        add_prop_v2 "persist.sys.oplus.anim_level" "1"
    fi
fi
add_prop_v2 "ro.sf.lcd_density" "${base_rom_density}"
cp -rf build/baserom/images/my_product/app/com.oplus.vulkanLayer build/portrom/images/my_product/app/ || true
cp -rf build/baserom/images/my_product/app/com.oplus.gpudrivers.* build/portrom/images/my_product/app/ || true
mkdir -p tmp/etc/permissions tmp/etc/extension
cp -fv build/portrom/images/my_product/etc/permissions/*.xml tmp/etc/permissions/
cp -fv build/portrom/images/my_product/etc/extension/*.xml tmp/etc/extension/
cp -rf build/baserom/images/my_product/etc/permissions/*.xml build/portrom/images/my_product/etc/permissions/ || true
find tmp/etc/permissions/ -type f \( -name "multimedia*.xml" -o -name "*permissions*.xml" -o -name "*google*.xml" -o -name "*configs*.xml" -o -name "*gsm*.xml" -o -name "feature_activity_preload.xml" -o -name "*gemini*.xml" -o -name "*gms*.xml" \) -exec cp -fv {} build/portrom/images/my_product/etc/permissions/ \;
if [[ $regionmark != "CN" ]];then
   for i in com.android.contacts com.android.incallui com.android.mms com.oplus.blacklistapp com.oplus.phonenoareainquire com.ted.number; do
        sed -i "/$i/d" build/portrom/images/my_stock/etc/config/app_v2.xml
   done
fi
cp -rf build/baserom/images/my_product/etc/permissions/*.xml build/portrom/images/my_product/etc/permissions/ || true
cp -rf build/baserom/images/my_product/etc/extension/*.xml build/portrom/images/my_product/etc/extension/ || true
cp -rf build/baserom/images/my_product/etc/refresh_rate_config.xml build/portrom/images/my_product/etc/refresh_rate_config.xml || true
cp -rf build/baserom/images/my_product/etc/sys_resolution_switch_config.xml build/portrom/images/my_product/etc/sys_resolution_switch_config.xml || true
cp -rf build/baserom/images/my_product/etc/permissions/com.oplus.sensor_config.xml build/portrom/images/my_product/etc/permissions/ || true
oplus_features=(
    "oplus.software.directservice.finger_flashnotes_enable^Xiao-Bu Memory"
    "oplus.software.support_quick_launchapp"
    "oplus.software.support_blockable_animation"
    "oplus.software.support.zoom.multi_mode"
    "oplus.software.display.reduce_white_point^Reduce White Point"
    "oplus.software.audio.media_control"
    "oplus.software.support.zoom.open_wechat_mimi_program"
    "oplus.software.support.zoom.center_exit"
    "oplus.software.support.zoom.game_enter"
    "oplus.software.coolex.support"
    "oplus.software.display.game.dapr_enable"
    "oplus.software.display.eyeprotect_game_support"
    "oplus.software.multi_app.volume.adjust.support^App Specific Volume (Incompatible with A13 devices)"
    "oplus.software.systemui.navbar_pick_color^Added in 15.0.2.201"
    "oplus.software.string_gc_support"
    "oplus.software.display.rgb_ball_support^Color Temp Ball"
    "oplus.software.camera_volume_quick_launch"
    "oplus.software.display.intelligent_color_temperature_support"
    "oplus.software.display.oha_support"
    "oplus.software.display.smart_color_temperature_rhythm_health_support"
    "oplus.software.display.mura_enhance_brightness_support"
    "oplus.software.audio.assistant_volume_support"
    "oplus.software.audio.volume_default_adjust"
    "oplus.software.notification_alert_support_fifo"
    "oplus.software.game_scroff_act_preload"
    "oplus.software.display.game_dark_eyeprotect_support^Game Assistant Night Eye Protection"
    "oplus.software.systemui.navbar_pick_color^Optimize Navbar Color Retrieval"
    "oplus.software.smart_sidebar_video_assistant^Sidebar Video Assistant"
    "oplus.video.audio.volume.enhancement^Video Volume Boost"
    "oplus.software.display.lux_small_debounce_expand_support"
    "oplus.hardware.display.no_bright_eyes_low_freq_strobe^Flicker at Low Brightness"
    "oplus.software.audio.super_volume_4x^400% Super Volume"
    "oplus.software.radio.networkless_sms_support"
    "com.oplus.location.car_phone_connection"
    "oplus.software.display.enhance_brightness_with_uidimming^LocalHDR"
    "oplus.software.adaptive_smooth_animation^Shanhai Communication Network Engine"
    "oplus.software.radio.ai_link_boost"
    "oplus.software.radio.ai_link_boost_notification"
    "oplus.software.radio.ai_link_boost_railway_notification"
    "oplus.software.systemui.pin_task^Pinned to Fluid Cloud"
    "oplus.software.radio.hfp_comm_shared_support^iPhone Integration"
    "oplus.hardware.display.motion_sickness^Motion Sickness Reduction Guidance"
)
for oplus_feature in ${oplus_features[@]}; do
    add_feature_v2 oplus_feature $oplus_feature
done
if [[ $vndk_version -gt 33 ]];then
 add_feature_v2 oplus_feature "oplus.software.radio.networkless_support^Offline Calling (Networkless Call)"
fi
app_features=(
    "os.personalization.flip.agile_window.enable"
    "os.personalization.wallpaper.live.ripple.enable"
    "com.oplus.infocollection.screen.recognition"
    "os.graphic.gallery.os15_secrecy^^args=\"boolean:true\""
    "com.coloros.colordirectservice.cm_enable^^args=\"boolean:true\""
    "com.oplus.exserviceui.feature_zoom_drag"
    "feature.hottouch.anim.support"
    "os.charge.settings.longchargeprotection.ai"
    "os.charge.settings.smartchargeswitch.open"
    "com.oplus.eyeprotect.ai_intelligent_eye_protect_support"
    "com.android.settings.network_access_permission"
    "os.charge.settings.batterysettings.batteryhealth^Battery Health"
    "com.oplus.mediaturbo.service"
    "com.oplus.mediaturbo.game_live^Broadcasting Assistant"
    "oplus.aod.wakebyclick.support^Wake AOD by Tapping"
    "com.oplus.screenrecorder.area_record^Area Screenshot^args=\"boolean:true\""
    "com.oplus.systemui.panoramic_aod.enable^^args=\"boolean:true\""
    "com.android.systemui.qs_deform_enable^^args=\"boolean:true\""
    "com.oplus.mediaturbo.tencent_meeting^Tencent Meeting^args=\"boolean:true\""
    "com.oplus.note.aigc.ai_rewrtie.support^AI Writing Assistance"
    "com.oplus.games.show_bypass_charging_when_gameapps^Bypass Charging^args=\"boolean:true\""
    "com.oplus.wallpapers.livephoto_wallpaper^^args=\"boolean:true\""
    "com.oplus.battery.autostart_limit_num^^args=\"String:8|10-16|15-24|20\""
    "com.android.launcher.recent_lock_limit_num^^args=\"String:8|10-16|15-24|20\""
    "com.oplus.battery.whitelist_vowifi^^args=\"boolean:true\""
    "com.oplus.battery.support.smart_refresh"
    "com.oplus.battery.life.mode.notificate^^args=\"int:1\""
    "feature.support.game.AI_PLAY"
    "feature.support.game.AI_PLAY_version3"
    "feature.super_app_alive.support_min_ram^^args=\"int:12\""
    "feature.super_app_alive.support_flag^^args=\"int:15\""
    "feature.super_alive_game.support^^args=\"int:1\""
    "feature.super_settings_smart_touch.support^Touch Through Screen Film V1"
    "com.android.launcher.folder_content_recommend_disable"
    "com.android.launcher.rm_disable_folder_footer_ad"
    "feature.support.game.ASSIST_KEY"
    "oplus.software.vibration_custom"
    "com.oplus.smartmediacontroller.lss_assistant_enable^Sidebar Audio Separation Assistant"
    "com.oplus.phonemanager.ai_voice_detect^Synthesized Voice^args=\"int:1\""
    "com.oplus.directservice.aitoolbox_enable^^args=\"boolean:true\""
    "com.coloros.support_gt_boost^^args=\"boolean:true\""
    "com.oplus.aicall.call_translate"
    "com.oplus.gesture.camera_space_gesture_support^Air Gestures"
    "com.oplus.gesture.intelligent_perception"
    "com.oplus.dmp.aiask_enable^AI Search^args=\"int:1\""
    "os.graphic.gallery.photoeditor.aibesttake^Best Take^args=\"int:1\""
    "com.oplus.tips.os_recommend_page_index^New Feature Recommendation^args=\"String:indexOS15_0_2_new\""
    "com.oplus.mediaturbo.transcoding^^args=\"boolean:true\""
    "com.android.launcher.app_advice_autoadd^^args=\"boolean:true\""
    "com.android.launcher.INDICATOR_BREENO_ENTRY_ENABLE^Xiao-Bu Hints on Home Screen^args=\"boolean:true\""
    "com.oplus.systemui.panoramic_aod.enable^AOD^args=\"boolean:true\""
    "oplus.software.disable_aod_all_day_mode^^args=\"boolean:false\""
    "com.oplus.systemui.panoramic_aod_all_day_default_open.enable^^args=\"boolean:true\""
    "com.oplus.systemui.panoramic_aod_all_day.enable^^args=\"boolean:true\""
    "oplus_keyguard_panoramic_aod_all_day_support^^args=\"boolean:true\""
    "com.oplus.securityguard.sample.feature_enable^Security Guard Related^args=\"boolean:true\""
    "com.oplus.aiwriter.input_entrance_enabled^^args=\"boolean:true\""
    "com.oplus.persona.card_datamining_support^^args=\"boolean:true\""
    "os.graphic.gallery.collage.livephoto^^args=\"boolean:true\""
    "com.android.systemui.qs_deform_enable^^args=\"boolean:true\""
    "com.oplus.wallpapers.ai_camera_movement^^args=\"boolean:true\""
    "com.oplus.wallpapers.livephoto_wallpaper_support_hdr^^args=\"boolean:true\""
    "com.oplus.wallpapers.livephoto_wallpaper_support_4k^^args=\"boolean:true\""
    "com.oplus.gallery3d.aihd_support"
    "os.graphic.gallery.collage.asset_bounds_break^Outside-the-frame^args=\"boolean:true\""
    "os.graphic.gallery.collage.livephoto^^args=\"boolean:true\""
)
for app_feature in ${app_features[@]}; do
    add_feature_v2 app_feature $app_feature
done
add_feature_v2 permission_oplus_feature "oplus.software.game.cold.start.speedup.enable"
add_feature_v2 permission_feature "com.plus.press_power_botton_experiment"
add_feature_v2 permission_feature "oplus.video.hdr10_support"
add_feature_v2 permission_feature "oplus.video.hdr10plus_support"
add_feature_v2 permission_feature "oppo.display.screen.gloablehbm.support"
add_feature_v2 permission_feature "oppo.high.brightness.support"
add_feature_v2 permission_feature "oppo.multibits.dimming.support"
add_feature_v2 permission_feature "oplus.software.display.refreshrate_default_smart"
if [[ "${base_product_device}" == "OnePlus9Pro" ]] ;then
    add_feature_v2 app_feature "os.charge.settings.wirelesscharging.power^Display wireless charging wattage in Settings^args=\"int:50\"" "oplus.power.wirelesschgwhenwired.support" "com.oplus.battery.wireless.charging.notificate" "os.charge.settings.wirelesschargingcoil.position" "os.charge.settings.wirelesscharge.support"
elif [[ "${base_product_device}" == "OP4E3F" ]] || [[ "${base_product_device}" == "OP4E5D" ]];then
    add_feature_v2 app_feature "os.charge.settings.wirelesscharging.power^Display wireless charging wattage in Settings^args=\"int:30\"" "oplus.power.wirelesschgwhenwired.support" "com.oplus.battery.wireless.charging.notificate" "os.charge.settings.wirelesschargingcoil.position" "os.charge.settings.wirelesscharge.support"
else
  remove_feature "oplus.power.wirelesschgwhenwired.support"
  remove_feature "com.oplus.battery.wireless.charging.notificate"
  remove_feature "os.charge.settings.wirelesscharge.support"
  remove_feature "os.charge.settings.wirelesscharging.power"
  remove_feature "os.charge.settings.wirelesschargingcoil.position"
  remove_feature "oplus.power.onwirelesscharger.support"
fi
xmlstarlet ed -L -d '//app_feature[@name="com.android.incallui.support_call_record_prompt_mcc"]' build/portrom/images/my_stock/etc/extension/com.oplus.app-features.xml || true
xmlstarlet ed -L -d '//app_feature[@name="com.android.incallui.hide_call_record_mcc"]' build/portrom/images/my_stock/etc/extension/com.oplus.app-features.xml || true
if [[ "$port_vendor_brand" == "realme" ]];then
     if [[ -f "devices/common/ai_memory_16.zip" ]]; then
         unzip -o devices/common/ai_memory_16.zip -d build/portrom/images/
     fi
fi
aimemory_app=$(find build/portrom -type f -name "AIMemory.apk")
if [[ ! -f $aimemory_app ]]; then
    if [[ $regionmark == "CN" ]];then
        if [[ -f "devices/common/ai_memory.zip" ]]; then
            unzip -o devices/common/ai_memory.zip -d build/portrom/images/
        fi
    else
         if [[ -f "devices/common/ai_memory_in/aimemory.zip" ]]; then
             unzip -o devices/common/ai_memory_in/aimemory.zip -d build/portrom/images/
         fi
    fi
fi
for pkg in com.oplus.aimemory com.oplus.appbooster; do
    if ! grep -q "<enable pkg=\"$pkg\"" build/portrom/images/my_product/etc/config/app_v2.xml;then
        sed -i "/<\/app>/i\ <enable pkg=\"$pkg\" priority=\"7\"/>" build/portrom/images/my_product/etc/config/app_v2.xml
    fi
done
if [[ ! -d build/portrom/images/my_product/etc/aisubsystem ]]; then
     if [[ $regionmark != "CN" ]];then
         if [[ -f "devices/common/ai_memory_in/aisubsystem.zip" ]]; then
             unzip -o devices/common/ai_memory_in/aisubsystem.zip -d build/portrom/images/
         fi
     fi
fi
if [[ -d devices/common/GTMode/overlay ]] && [[ $port_android_version != "16" ]];then
    add_feature_v2 oplus_feature "oplus.software.support.gt.mode^GT Mode"
    add_feature_v2 app_feature "com.android.settings.device_rm^Realme Device: Required for GT Mode display"
    if [[ $port_vendor_brand != "realme" ]];then
        cp -rfv devices/common/GTMode/overlay/* build/portrom/images/
    fi
fi
if [[ "$port_vendor_brand" == "realme" ]] && [[ $regionmark == "CN" ]] ;then
    add_feature_v2 oplus_feature "oplus.software.support.gt.mode^GT Mode"
    add_feature_v2 app_feature "com.android.settings.device_rm^Realme Device: Required for GT Mode display"
    add_feature_v2 app_feature "com.oplus.smartsidebar.space.roulette.support^AI Portal" \
            "com.oplus.smartsidebar.space.roulette.bootreg" \
            "com.coloros.support_gt_boost^^args=\"boolean:true\""
    add_feature_v2 permission_oplus_feature "oplus.software.aigc_global_drag" "oplus.software.smart_loop_drag"
fi
add_feature_v2 oplus_feature "oplus.software.display.manual_hbm.support"
add_prop_v2 "ro.oplus.display.sell_mode.max_normal_nit" "800"
add_feature "android.hardware.biometrics.face" build/portrom/images/my_product/etc/permissions/android.hardware.fingerprint.xml
add_feature_v2 oplus_feature "oplus.software.display.smart_color_temperature_rhythm_health_support"
add_feature "oplus.hardware.audio.voice_isolation_support" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml
add_feature "oplus.hardware.audio.voice_denoise_support" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml
sed -i '/<\/extend_features>/i\
    <app_feature name="com.oplus.plc_charge.support">\
        <StringList args="true"/>\
    </app_feature>' build/portrom/images/my_product/etc/extension/com.oplus.app-features-ext-bruce.xml
add_feature_v2 app_feature "com.android.settings.device_rm^Realme Device"
add_feature_v2 app_feature "com.oplus.fullscene_plc_charge.support^Fullscreen Bypass Charging^args=\"boolean:true\""
if grep -q "oplus.software.audio.alert_slider" build/portrom/images/my_product/etc/permissions/* ;then
    add_feature "oplus.software.audio.alert_slider" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml
fi
remove_feature "oplus.software.display.wcg_2.0_support"
remove_feature "oplus.software.display.origin_roundcorner_support"
remove_feature "oplus.software.vibration_ring_mute"
remove_feature "oplus.software.vibration_alarm_clock"
remove_feature "oplus.software.vibration_threestage_key"
remove_feature "oppo.common.support.curved.display"
remove_feature "oplus.feature.largescreen"
remove_feature "oplus.feature.largescreen.land"
remove_feature "oplus.software.audio.audioeffect_support"
remove_feature "oplus.software.audio.audiox_support"
remove_feature "oppo.breeno.three.words.support"
remove_feature "oplus.software.vibrator_qcom_lmvibrator"
remove_feature "oplus.hardware.vibrator_style_switch"
remove_feature "oplus.software.vibrator_luxunvibrator"
remove_feature "oplus.software.palmprint_non_unify"
remove_feature "oplus.software.palmprint_v1"
remove_feature "oplus.software.palmprint"
remove_feature "com.android.settings.processor_detail_gen2"
remove_feature "com.android.settings.processor_detail"
remove_feature "oplus.software.display.adfr_v32_hp"
remove_feature "com.oplus.battery.phoneusage.screenon.hide"
EUICC_GOOGLE=$(find build/portrom/images/ -name "EuiccGoogle" -type d )
if [[ -d $EUICC_GOOGLE ]];then
    rm -rfv $EUICC_GOOGLE
    remove_feature "android.hardware.telephony.euicc"
    remove_feature "oplus.software.radio.esim_support_sn220u"
    remove_feature "oplus.software.radio.esim_support"
    remove_feature "com.android.systemui.keyguard_support_esimcard"
fi
cp -rf build/baserom/images/my_product/vendor/etc/* build/portrom/images/my_product/vendor/etc/ || true
if [[ $base_android_version -lt 33 ]];then
    cp -rf build/baserom/images/my_product/etc/camera/* build/portrom/images/my_product/etc/camera || true
    old_camera_app=$(find build/baserom/images/my_product -type f -name "OnePlusCamera.apk")
    if [[ $port_android_version -lt 16 ]] && [[ -f $old_camera_app ]];then
        cp -rfv "$(dirname "$old_camera_app")/." build/portrom/images/my_product/priv-app/ || true
        if [ ! -d build/portrom/images/my_product/priv-app/etc/permissions/ ];then
            mkdir -p build/portrom/images/my_product/priv-app/etc/permissions/
        fi
        rm -rf build/portrom/images/my_product/product_overlay/framework/*
        cp -rf build/baserom/images/my_product/product_overlay/* build/portrom/images/my_product/product_overlay || true
    #    find build/portrom/images/ -type f -name "*.prop" -exec  sed -i "s/ro.product.model=.*/ro.product.model=${base_market_name}/g" {} \;
    #   find build/portrom/images/ -type f -name "*.prop" -exec  grep "ro.product.model" {} \;
        cp -rfv  build/baserom/images/my_product/priv-app/etc/permissions/* build/portrom/images/my_product/priv-app/etc/permissions/
        new_camera=$(find build/portrom/images/my_product -type f -name "OplusCamera.apk")
        if [[ -f $new_camera ]]; then
            rm -rfv $(dirname $new_camera)
        fi
        base_scanner_app=$(find build/baserom/images/ -type d -name "OcrScanner")
        target_scanner_app=$(find build/portrom/images/ -type d -name "OcrScanner")
        if [[ -n $base_scanner_app ]] && [[ -n $target_scanner_app ]];then
                blue "Replacing stock scan function" "Replacing Stock OrcScanner"
            rm -rfv $target_scanner_app/*
            cp -rfv $base_scanner_app $target_scanner_app
        fi
    fi
else
    add_prop_v2 "ro.vendor.oplus.camera.isSupportExplorer" "1"
    base_oplus_camera_dir=$(find build/baserom/images/my_product -type d -name "OplusCamera")
    port_oplus_camera_dir=$(find build/portrom/images/my_product -type d -name "OplusCamera")

    if [[ $port_android_version -lt 16 ]] && [[ -d "${base_oplus_camera_dir}" ]] && [[ -d "${port_oplus_camera_dir}" ]];then
        rm -rf "$port_oplus_camera_dir"/*
        cp -rf "$base_oplus_camera_dir"/* "$port_oplus_camera_dir"/
        cp -rf build/baserom/images/my_product/product_overlay/framework/* build/portrom/images/my_product/product_overlay/framework/ || true
    fi
 fi

if [[ ${base_device_family} == "OPSM8250" ]]; then
  camera_optimize_file=$(find build/portrom/images/ -type f -name "sys_camera_optimize_config.xml")
  # Fix wechat /alipay scan crash issue
   if [[ -f $camera_optimize_file ]]; then
      rm -f $camera_optimize_file
   fi
fi

sourceOvoiceManagerService=$(find build/baserom/images/my_product -type d -name "OVoiceManagerService")
if [[ -d "$sourceOvoiceManagerService" ]]; then
    targetOvoiceManagerService=$(find build/portrom/images/my_product -type d -name "OVoiceManagerService")
    if [[ -d "$targetOvoiceManagerService" ]]; then
        # Use a colon here so the 'if' block isn't empty
        : 
        # rm -rfv "$targetOvoiceManagerService"/* cp -rfv "$sourceOvoiceManagerService"/* "$targetOvoiceManagerService/"
    else
        cp -rfv "$sourceOvoiceManagerService" build/portrom/images/my_product/priv-app/
    fi
fi

while IFS= read -r sound_trigger_file; do
    relative_path=${sound_trigger_file#"build/baserom/images/"}
    dest_path="build/portrom/images/${relative_path}"
    mkdir -p "$(dirname "$dest_path")"
    cp -rfv "$sound_trigger_file" "$dest_path"
done < <(find build/baserom/images/ -type f -name "sound_trigger_*")

if [[ ${base_product_device} == "OnePlus8T" ]];then 
    # Voice_trigger for OnePlus 8T
    add_feature_v2 oplus_feature "oplus.software.audio.voice_wakeup_support^Legacy Voice Wake" "oplus.software.audio.voice_wakeup_3words_support"
    #add_feature "oplus.software.speechassist.oneshot.support" build/portrom/images/my_product/etc/extension/com.oplus.oplus-feature.xml
    unzip -o ${work_dir}/devices/common/voice_trigger_fix.zip -d ${work_dir}/build/portrom/images/
fi


cp -rf build/baserom/images/my_product/etc/Multimedia_*.xml build/portrom/images/my_product/etc/ || true


if [[ -f "tmp/etc/permissions/multimedia_privapp-permissions-oplus.xml" ]];then
    cp -rfv tmp/etc/permissions/multimedia_*.xml build/portrom/images/my_product/etc/permissions/
fi



while IFS= read -r file; do
    cp -rfv "$file" build/portrom/images/my_product/etc/
done < <(find build/baserom/images/my_product/etc/ -type f -name "OVMS_*")
#fix chinese char
find build/portrom/images/config -type f -name "*file_contexts" \
	    -exec perl -i -ne 'print if /^[\x00-\x7F]+$/' {} \;
#find build/portrom/images/config -type f -name "*file_contexts" -exec sed -i -E '/[\x{4e00}-\x{9fa5}]/d' {} \;

# ==================================================
# Bootanimation
# ==================================================

portanim_path="build/portrom/images/my_product/media/bootanimation"

if [[ "$mix_port" == true && -n "${version_name2}" ]]; then

    p2_anim=""

    for path in \
        "build/${version_name2}/my_product/media/bootanimation" \
        "build/${version_name2}/product/media/bootanimation"
    do
        if [[ -e "$path" ]]; then
            p2_anim="$path"
            break
        fi
    done

    if [[ -n "$p2_anim" ]]; then
        blue "Mixed port: using bootanimation from portrom2 (${version_name2})"

        rm -rf "$portanim_path"
        mkdir -p "$(dirname "$portanim_path")"
        cp -rf "$p2_anim" "$portanim_path"

    else
        yellow "Mixed port: portrom2 has no bootanimation, keeping portrom's"
    fi

else

    portanim_src=""

    for path in \
        "build/portrom/images/my_product/media/bootanimation" \
        "build/portrom/images/product/media/bootanimation"
    do
        if [[ -e "$path" ]]; then
            portanim_src="$path"
            break
        fi
    done

    if [[ -z "$portanim_src" ]]; then
        yellow "portrom has no bootanimation, falling back to baserom"

        if [[ -d "build/baserom/images/my_product/media/bootanimation" ]]; then
            rm -rf "$portanim_path"
            mkdir -p "$(dirname "$portanim_path")"
            cp -rf build/baserom/images/my_product/media/bootanimation "$portanim_path"
        else
            red "No bootanimation found in baserom either"
        fi
    else
        green "Using portrom bootanimation"
    fi
fi

# ── Custom boot animation (ColorOS CN ports only) — Rapchick Engine (@revork)
# Only runs when the port is ColorOS China (not OOS, not Global).
# Place bootanimation.zip in the project root next to port.sh.
# The zip should contain the desc.txt and numbered frame folders at its root.
if [[ "${portIsColorOS}" == true ]]; then
    if [[ -f "bootanimation.zip" ]]; then
        blue "ColorOS CN port: installing custom boot animation from bootanimation.zip"
        rm -rf build/portrom/images/my_product/media/bootanimation
        # Unzip directly into media/ — Android expects media/bootanimation/ to be
        # a directory whose contents are desc.txt + frame folders, not a nested zip.
        # If the zip has a top-level bootanimation/ folder the cp below flattens it;
        # if the zip root IS the animation files they land correctly either way.
        mkdir -p build/portrom/images/my_product/media/bootanimation
        unzip -o bootanimation.zip -d build/portrom/images/my_product/media/bootanimation
        # If the zip had a nested bootanimation/ folder, flatten it
        if [[ -d build/portrom/images/my_product/media/bootanimation/bootanimation ]]; then
            cp -rf build/portrom/images/my_product/media/bootanimation/bootanimation/*                 build/portrom/images/my_product/media/bootanimation/
            rm -rf build/portrom/images/my_product/media/bootanimation/bootanimation
        fi
        green "Custom boot animation installed"
    else
        yellow "bootanimation.zip not found in project root — keeping default"
    fi
fi
 
rm -rf build/portrom/images/my_product/media/quickboot
cp -rf build/baserom/images/my_product/media/quickboot build/portrom/images/my_product/media/ || true
if [[ -f devices/common/wallpaper.zip ]] && [[ "$portIsColorOSGlobal" == "false" ]] && [[ "$portIsOOS" == "false" ]] && [[ "$port_android_version" -lt 16 ]];then
    unzip -o devices/common/wallpaper.zip -d build/portrom/images
 fi   

# ── 3D wallpaper: save portrom res overlay before baserom wipe — Rapchick Engine
# my_product/res/ is about to be replaced wholesale from the CN baserom.
# The portrom (Global EX) carries wallpaper overlay APKs here that enable 3D/live
# wallpaper — the CN baserom doesn't have them, so without saving them first they
# are permanently lost. We stash them to tmp/ and restore after the copy.
if [[ "${portIsColorOS}" == true ]] && [[ "${regionmark}" == "CN" ]]; then
    rm -rf tmp/portrom_wallpaper_res_backup
    mkdir -p tmp/portrom_wallpaper_res_backup
    # Save every overlay APK whose name contains wallpaper (case-insensitive)
    while IFS= read -r f; do
        cp -rf "${f}" tmp/portrom_wallpaper_res_backup/
    done < <(find build/portrom/images/my_product/res/ -maxdepth 1         \( -iname "*wallpaper*" -o -iname "*Wallpapers*" \) 2>/dev/null)
    # Also save OplusWallpapers media asset dirs (3D mesh/video assets)
    rm -rf tmp/portrom_wallpaper_media_backup
    mkdir -p tmp/portrom_wallpaper_media_backup
    for media_dir in         "build/portrom/images/my_product/media/wallpaper3d"         "build/portrom/images/my_product/media/wallpaper_3d"         "build/portrom/images/my_product/media/live_wallpaper_res"         "build/portrom/images/my_product/media/livewallpaper"
    do
        if [[ -d "${media_dir}" ]]; then
            cp -rf "${media_dir}" tmp/portrom_wallpaper_media_backup/
        fi
    done
fi

rm -rf build/portrom/images/my_product/res/*
cp -rf build/baserom/images/my_product/res/* build/portrom/images/my_product/res/ || true

# ── 3D wallpaper: restore portrom wallpaper overlays over CN res ──────────────
# Now put the saved Global EX wallpaper overlay APKs back. They take precedence
# over any CN wallpaper overlays because the Global ones declare 3D support.
if [[ "${portIsColorOS}" == true ]] && [[ "${regionmark}" == "CN" ]]; then
    if [[ -d tmp/portrom_wallpaper_res_backup ]] &&        [[ -n "$(ls -A tmp/portrom_wallpaper_res_backup 2>/dev/null)" ]]; then
        cp -rf tmp/portrom_wallpaper_res_backup/*             build/portrom/images/my_product/res/
        green "3D wallpaper: restored ${$(ls tmp/portrom_wallpaper_res_backup | wc -l)} overlay APK(s) from Global EX portrom"
    fi
    # Restore 3D wallpaper media asset dirs
    if [[ -d tmp/portrom_wallpaper_media_backup ]] &&        [[ -n "$(ls -A tmp/portrom_wallpaper_media_backup 2>/dev/null)" ]]; then
        cp -rf tmp/portrom_wallpaper_media_backup/*             build/portrom/images/my_product/media/
        green "3D wallpaper: restored media asset dirs"
    fi
    # Add 3D wallpaper feature flags — CN region strips these from oplus-feature XMLs
    add_feature_v2 app_feature         "com.oplus.wallpapers.support_3d_wallpaper^^args="boolean:true""         "com.oplus.wallpapers.download_3d_wallpaper^^args="boolean:true""         "com.oplus.wallpapers.3d_wallpaper_support^^args="boolean:true""         "com.oplus.wallpapers.support_live_wallpaper^^args="boolean:true""         "com.oplus.wallpapers.live_wallpaper_download^^args="boolean:true""
    add_feature_v2 oplus_feature         "oplus.software.wallpaper.3d_wallpaper_support"         "oplus.software.wallpaper.live_wallpaper_support"
    green "3D wallpaper: feature flags enabled for CN ColorOS port"
fi

#rm -rf build/portrom/images/my_product/vendor/*
cp -rf build/baserom/images/my_product/vendor/* build/portrom/images/my_product/vendor/ || true
rm -rf  build/portrom/images/my_product/overlay/*display*[0-9]*.apk
while IFS= read -r overlay; do
    cp -rf "$overlay" build/portrom/images/my_product/overlay/
done < <(find build/baserom/images/ -type f -name "*${base_my_product_type}*.apk")

super_computing=$(find build/portrom/images/my_product -name "string_super_computing*" | head -n1)
if [[ ! -f "$super_computing" ]]; then
    # Guard: super_computing dir may not exist on all setups
    if [[ -d "devices/common/super_computing" ]]; then
        cp -rf devices/common/super_computing/* build/portrom/images/my_product/etc/
    fi
fi

# CarrierConfigOverlay — find may return empty; guard all cp calls with -f check
baseCarrierConfigOverlay=$(find build/baserom/images/ -type f -name "CarrierConfigOverlay*.apk" | head -n1)
portCarrierConfigOverlay=$(find build/portrom/images/ -type f -name "CarrierConfigOverlay*.apk" | head -n1)
if [[ -f "${baseCarrierConfigOverlay}" && -f "${portCarrierConfigOverlay}" ]]; then
    blue "Replacing [CarrierConfigOverlay.apk]"
    rm -rf "${portCarrierConfigOverlay}"
    cp -rf "${baseCarrierConfigOverlay}" "$(dirname "${portCarrierConfigOverlay}")"
elif [[ -f "${baseCarrierConfigOverlay}" ]]; then
    # portCarrierConfigOverlay absent — place directly in overlay/
    cp -rf "${baseCarrierConfigOverlay}" build/portrom/images/my_product/overlay/
fi



#add_feature "oplus.software.display.eyeprotect_paper_texture_support" build/portrom/images/my_product/etc/extension/com.oplus.oplus-feature.xml

add_feature "oplus.software.display.reduce_brightness_rm" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml
add_feature "oplus.software.display.reduce_brightness_rm_manual" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml

add_feature "oplus.software.display.brightness_memory_rm" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml
add_feature "oplus.software.display.sec_max_brightness_rm" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml

{
    echo "# Additional Properties"
    echo "persist.lowbrightnessthreshold=0"
    echo "persist.sys.renderengine.maxLuminance=500"

    echo "ro.oplus.display.peak.brightness.duration_time=15"
    echo "ro.oplus.display.peak.brightness.effect_interval_time=1800000"
    echo "ro.oplus.display.peak.brightness.effect_times_every_day=2"
    echo "ro.display.brightness.thread.priority=true"
    echo "# Speaker Cleanup Related"
    echo "ro.oplus.audio.speaker_clean=true"
    echo "ro.vendor.oplus.radio.use_nitz_name=true"
    # Fixeme A16 crash with AndroidRuntime: 	at com.android.server.display.feature.panel.OplusFeatureDCBacklight.applyApolloDCMode(OplusFeatureDCBacklight.java:300)
    #echo "persist.brightness.apollo=1"

} >> build/portrom/images/my_product/etc/bruce/build.prop

if [[ ${base_product_device} == "OnePlus8Pro" ]] ;then 
    if [[ ${port_android_version} -gt 15 ]];then
            {
    echo "# OnePlus8Pro: Delete Properties"
    echo "ro.display.brightness.hbm_xs="
    echo "ro.display.brightness.hbm_xs_min="
    echo "ro.display.brightness.hbm_xs_max="
    echo "ro.oplus.display.brightness.xs="
    echo "ro.oplus.display.brightness.ys="
    echo "ro.oplus.display.brightness.hbm_ys="
    echo "ro.oplus.display.brightness.default_brightness="
    echo "ro.oplus.display.brightness.normal_max_brightness="
    echo "ro.oplus.display.brightness.max_brightness="
    echo "ro.oplus.display.brightness.normal_min_brightness="
    echo "ro.oplus.display.brightness.min_light_in_dnm="
    echo "ro.oplus.display.brightness.smooth="
    echo "ro.display.brightness.mode.exp.per_20="
    echo "ro.vendor.display.AIRefreshRate.brightness="
    echo "ro.oplus.display.dwb.threshold="
    echo "ro.oplus.display.dynamic.dither="
    echo "persist.oplus.display.initskipconfig="

} >> build/portrom/images/my_product/etc/bruce/build.prop
    fi
fi

 if [[ $regionmark == "CN" ]];then
     echo "ro.oplus.display.brightness.min_settings.rm=1,1,25,4.0,0" >> build/portrom/images/my_product/etc/bruce/build.prop
 fi


if [[ -d build/baserom/images/my_product/etc/vibrator ]];then
    rm -rfv build/portrom/images/my_product/etc/vibrator
    cp -rfv build/baserom/images/my_product/etc/vibrator build/portrom/images/my_product/etc/ || true
fi


if [[ $base_device_family == "OPSM8350" ]] && [[ -f devices/common/aon_fix_sm8350.zip ]];then
    rm -rfv build/portrom/images/my_product/overlay/aon*.apk
    unzip -o devices/common/aon_fix_sm8350.zip -d build/portrom/images/

elif [[ $base_device_family == "OPSM8250" ]] && [[ -f devices/common/aon_fix_sm8250.zip ]];then
    rm -rfv build/portrom/images/my_product/overlay/aon*.apk
    unzip -o devices/common/aon_fix_sm8250.zip -d build/portrom/images/
else

    sourceAONService=$(find build/baserom/images/my_product -type d -name "AONService")

    if [[ -d "$sourceAONService" ]];then
        targetAONService=$(find build/portrom/images/my_product -type d -name "AONService")
        if [[ -d "$targetAONService" ]];then
            rm -rfv "$targetAONService"/*
            cp -rfv "$sourceAONService"/* "$targetAONService"/
        else
            cp -rfv $sourceAONService build/portrom/images/my_product/app/
        fi
        
        add_feature "oplus.software.aon_pay_qrcode_enable" build/portrom/images/my_product/etc/extension/com.oplus.oplus-feature.xml
        remove_feature "oplus.software.aon_sensorhub_enable" 

    fi
    if [[ ! -f build/baserom/images/my_product/overlay/aon*.apk ]] && [[ $regionmark == "CN" ]];then
        rm -rfv build/portrom/images/my_product/overlay/aon*.apk
    fi
fi
# Realme: Air Gestures (CN exclusive measures)
if [[ -f devices/common/realme_gesture.zip ]] && [[ "$port_vendor_brand" != "realme" ]] && [[ $port_android_version -lt "16" ]];then
    unzip -o devices/common/realme_gesture.zip -d build/portrom/images/
    sed -i "s/ro.camera.privileged.3rdpartyApp=.*/ro.camera.privileged.3rdpartyApp=com.aiunit.aon\;com.oplus.gesture\;/g" build/portrom/images/my_stock/build.prop
fi


		# OP9Pro (A16): bring back OP9Pro-specific camera configs (odm/my_product) and required props for Master mode

		if [[ "${base_product_device}" == "OnePlus9Pro" ]] ||[[ "${base_product_device}" == "OnePlus9" ]] ||  [[ "${base_product_device}" == "OP4E5D" ]] || [[ "${base_product_device}" == "OP4E3F" ]]; then
		    if [[ "$portIsColorOS" == "true" ]];then
		        if [[ $port_android_version -ge 15 ]];then
		            if [[ -f "devices/${base_product_device}/camera6.0-fix_cos.zip" ]] ;then
		                blue "ColorOS${port_android_version} Camera Fix (6.0)" "ColorOS Camera Fix (6.0)"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o "devices/${base_product_device}/camera6.0-fix_cos.zip" -d build/portrom/images/
		            elif [[ -f "devices/${base_product_device}/camera5.0-fix_cos.zip" ]] ;then
		                blue "ColorOS${port_android_version} Camera Fix" "ColorOS Camera Fix"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o "devices/${base_product_device}/camera5.0-fix_cos.zip" -d build/portrom/images/
		            fi
		            if [[ -f "devices/${base_product_device}/camera6.0-fix_odm.zip" ]] ;then
		                unzip -o "devices/${base_product_device}/camera6.0-fix_odm.zip" -d build/portrom/images/
		            elif [[ -f "devices/${base_product_device}/camera5.0-fix_odm.zip" ]] ;then
		                unzip -o "devices/${base_product_device}/camera5.0-fix_odm.zip" -d build/portrom/images/
		            fi
		        else
		            blue "Enabling Live Photo shooting" "Live Photo support"
		            rm -rf build/portrom/images/my_product/app/OplusCamera
		            rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		            if [[ -f "devices/${base_product_device}/live_photo_adds.zip" ]]; then
		                unzip -o "devices/${base_product_device}/live_photo_adds.zip" -d build/portrom/images/
		            elif [[ -f "devices/${base_product_device}/live_photo_addition.zip" ]]; then
		                unzip -o "devices/${base_product_device}/live_photo_addition.zip" -d build/portrom/images/
		            else
		                yellow "Live photo zip not found, skipping" "Live photo zip not found in devices/${base_product_device}/"
		            fi
		        fi
		    elif  [[ "$portIsColorOSGlobal" == "true" ]];then
		        if [[ $port_android_version -ge 15 ]]; then 
		             if [[ -f "devices/${base_product_device}/camera6.0-fix_cos_global.zip" ]] ;then
		                blue "ColorOS Global ${port_android_version} Camera Fix (6.0)" "ColorOS Global Camera Fix (6.0)"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o "devices/${base_product_device}/camera6.0-fix_cos_global.zip" -d build/portrom/images/
		                if [[ -f "devices/${base_product_device}/camera6.0-fix_odm.zip" ]] ;then
		                    unzip -o "devices/${base_product_device}/camera6.0-fix_odm.zip" -d build/portrom/images/
		                elif [[ -f "devices/${base_product_device}/camera5.0-fix_odm.zip" ]] ;then
		                    unzip -o "devices/${base_product_device}/camera5.0-fix_odm.zip" -d build/portrom/images/
		                fi
		            elif [[ -f "devices/${base_product_device}/camera5.0-fix_cos_global.zip" ]] ;then
		                blue "ColorOS Global ${port_android_version} Camera Fix" "ColorOS Global Camera Fix"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o "devices/${base_product_device}/camera5.0-fix_cos_global.zip" -d build/portrom/images/
		                if [[ -f "devices/${base_product_device}/camera5.0-fix_odm.zip" ]] ;then
		                    unzip -o "devices/${base_product_device}/camera5.0-fix_odm.zip" -d build/portrom/images/
		                fi
		            fi
		        fi

		    elif  [[ "$portIsOOS" == "true" ]];then
		        if [[ $port_android_version -ge 15 ]]; then
		            if [[ -f "devices/${base_product_device}/camera6.0-fix_oos.zip" ]] ;then
		                blue "OxygenOS${port_android_version} Camera Fix (6.0)" "OxygenOS Camera Fix (6.0)"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o "devices/${base_product_device}/camera6.0-fix_oos.zip" -d build/portrom/images/
		                if [[ -f "devices/${base_product_device}/camera6.0-fix_odm.zip" ]] ;then
		                    unzip -o "devices/${base_product_device}/camera6.0-fix_odm.zip" -d build/portrom/images/
		                elif [[ -f "devices/${base_product_device}/camera5.0-fix_odm.zip" ]] ;then
		                    unzip -o "devices/${base_product_device}/camera5.0-fix_odm.zip" -d build/portrom/images/
		                fi
		            elif [[ -f "devices/${base_product_device}/camera5.0-fix_oos.zip" ]] ;then
		                blue "OxygenOS${port_android_version} Camera Fix" "OxygenOS Camera Fix"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o "devices/${base_product_device}/camera5.0-fix_oos.zip" -d build/portrom/images/
		                if [[ -f "devices/${base_product_device}/camera5.0-fix_odm.zip" ]] ;then
		                    unzip -o "devices/${base_product_device}/camera5.0-fix_odm.zip" -d build/portrom/images/
		                fi
		            fi
		        fi
		    fi
		fi
# High Performance Outdoor Mode
add_prop_v2 "ro.oplus.ridermode.support_feature_switch" "11"

# Enabling WeChat Moments GIFs/Live Photos
cp -rf build/portrom/images/system_ext/etc/Multimedia_Daemon_List.xml  tmp/

xmlstarlet ed -u '//wechat-livephoto/name[text()="com.tencent.mm"]/following-sibling::attribute[1]' -v "all" tmp/Multimedia_Daemon_List.xml > build/portrom/images/system_ext/etc/Multimedia_Daemon_List.xml

# Fix atfwd@2.0.policy
atfwd_policy_file=$(find build/portrom/images/vendor/ -name "atfwd@2.0.policy" -print -quit)

if [ -n "$atfwd_policy_file" ]; then
  echo "Found policy file: $atfwd_policy_file"
  for prop in getid gettid setpriority; do
    if ! grep -q "${prop}: 1" "$atfwd_policy_file"; then
      echo "${prop}: 1" >> "$atfwd_policy_file"
    else
      blue "⚙️  Already contains ${prop}: 1"
    fi
  done
else
  blue "❌ No atfwd@2.0.policy found."
fi

if  [[ "${base_product_device}" == "OnePlus9Pro" ]] ||[[ "${base_product_device}" == "OnePlus9" ]];then
    echo -e "\n[FeatureTorch]\n    isSupportTorchStrengthLevel = TRUE\n    maxStrengthLevel = 4\n    defaultStrengthLevel = 4\n " >> build/portrom/images/odm/etc/camera/CameraHWConfiguration.config
fi

if [[ ${port_android_version} == 16 ]] && [[ ${base_android_version} -lt 15 ]];then
    rm -rf build/portrom/images/system_ext/priv-app/com.qualcomm.location
    #remove_feature "oplus.software.display.dcbacklight_support" force
    if [[ -f  devices/common/nfc_fix_a16_v2.zip ]];then
    rm -rf build/portrom/images/system/system/priv-app/NfcNci/*
    unzip -o devices/common/nfc_fix_a16_v2.zip -d ${work_dir}/build/portrom/images/
    fi
    if [[ $regionmark == "CN" ]];then
    unzip -o devices/common/wifi_fix_a16.zip -d ${work_dir}/build/portrom/images/
    rm -rf build/portrom/images/system/system/apex/com.google.android.wifi*.apex
    fi
    if [[ ${port_oplusrom_version} == "16.0.1" ]] && [[ $regionmark != "CN" ]] ;then
        unzip -o devices/common/oos_1601_fix.zip -d build/portrom/images/
    fi

    if [[ -f build/portrom/images/my_product/cust/CN/etc/power_profile/power_profile.xml ]];then
        cp -rf build/portrom/images/odm/etc/power_profile/power_profile.xml build/portrom/images/my_product/cust/CN/etc/power_profile/
    fi

    #camera fix
    echo "vendor.audio.c2.preferred=true" >> build/portrom/images/vendor/build.prop
    echo "vendor.audio.hdr.record.enable=false" >> build/portrom/images/vendor/build.prop

    # Optional: try enabling Master/Master Video modes by swapping ODM camera mode configs.
    # Note: This is a best-effort hack; configs may be device-specific. Enable explicitly via env var.
    if [[ "${ENABLE_MASTER_MODE_PATCH:-false}" == "true" ]] && \
       [[ ${base_device_family} == "OPSM8350" ]] && \
       ([[ "${base_product_device}" == "OnePlus9Pro" ]] || [[ "${base_product_device}" == "OnePlus9" ]]) && \
       [[ -f devices/common/odm_camera_mastermode_config_op15cn_a16.zip ]]; then
        blue "OP9/9Pro: Master mode config patch" "OP9/9Pro: Applying ODM master mode config patch"
        unzip -o devices/common/odm_camera_mastermode_config_op15cn_a16.zip -d ${work_dir}/build/portrom/images/
    fi

    if [[ $base_product_device == "OP4E3F" ]];then
        # Fix Find X3 Pro brightness
        sed -i "/ro.oplus.display.brightness.apollo*/d" build/portrom/images/my_product/build.prop
        sed -i "/persist.brightness.apollo/d" build/portrom/images/my_product/build.prop
        rm -rf build/portrom/images/my_product/vendor/etc/display_apollo_list.xml
    fi
fi

if [[ -f devices/common/hdr_fix.zip ]] && [[ $base_android_version -le 14 ]];then
    unzip -o devices/common/hdr_fix.zip -d build/portrom/images/
    echo "persist.sys.feature.uhdr.support=true" >> build/portrom/images/my_product/etc/bruce/build.prop
fi

# ═════════════════════════════════════════════════════════════════════════════
# Google Services injection — ColorOS China → Global GMS lift
# Rapchick Engine — @revork / Ozyern
#
# When porting a ColorOS China ROM, it ships with no GMS at all.
# This block finds a pre-extracted ColorOS Global EX ROM in:
#   build/CPH2745_16.0.5.700(EX01)/
# and lifts every Google app + CTS fingerprint from it into the port.
#
# Apps lifted:
#   priv-app: GmsCore (Play Services), Phonesky (Play Store), GoogleDialer,
#             PrebuiltBugle (Messages), PrebuiltDeskClockGoogle, GoogleContacts,
#             PrebuiltGoogleTelephony, FindMyDevice, GoogleFeedback, SetupWizard
#   app:      Chrome, YouTube, Maps, Photos (Google Photos), Drive, GoogleTTS,
#             YouTube Music stub, GoogleBackupTransport
#   product/priv-app: CarrierServices, GoogleOne (if present)
#
# CTS fingerprint:
#   ro.build.fingerprint, ro.system.build.fingerprint,
#   ro.product.build.fingerprint, ro.bootimage.build.fingerprint,
#   ro.vendor.build.fingerprint — all lifted from the Global EX build.prop
#   so the port passes Google Play Integrity (formerly SafetyNet) basic check.
#
# Permissions XMLs:
#   All *google*.xml, *gms*.xml, *configs*.xml from the Global EX
#   my_product/etc/permissions/ — required for GMS to boot without crashing.
# ═════════════════════════════════════════════════════════════════════════════
if [[ "${portIsColorOS}" == true ]] && [[ "${regionmark}" == "CN" ]]; then

    # ═══════════════════════════════════════════════════════════════════════════
    # Google Services injection — ColorOS China — Rapchick Engine (@revork)
    #
    # Clones a GitHub-hosted GApps package (MindTheGapps-style) into tmp/gapps/
    # then installs every partition into the portrom image, sets Gemini as the
    # default assistant, removes Breeno entirely, and patches the CTS fingerprint.
    #
    # Repo URL is read from GAPPS_REPO_URL if set; otherwise uses the default
    # MindTheGapps repo for the detected Android version + arm64 architecture.
    # Set it in your config or export it before running port.sh to override.
    #   e.g. export GAPPS_REPO_URL="https://github.com/YourOrg/YourGApps"
    # ═══════════════════════════════════════════════════════════════════════════

    GAPPS_REPO_DIR="tmp/gapps"
    GAPPS_SKIP=false

    # ── Auto-select repo URL from Android version if not overridden ───────────
    if [[ -z "${GAPPS_REPO_URL:-}" ]]; then
        case "${port_android_version}" in
            16) GAPPS_REPO_URL="https://github.com/MindTheGapps/16.0.0-arm64" ;;
            15) GAPPS_REPO_URL="https://github.com/MindTheGapps/15.0.0-arm64" ;;
            14) GAPPS_REPO_URL="https://github.com/MindTheGapps/14.0.0-arm64" ;;
            *)
                yellow "GApps: no known MindTheGapps repo for Android ${port_android_version} — set GAPPS_REPO_URL manually"
                GAPPS_SKIP=true
                ;;
        esac
    fi

    # ── Clone (skip if already cloned from a previous run) ───────────────────
    if [[ "${GAPPS_SKIP}" != true ]]; then
        if [[ ! -d "${GAPPS_REPO_DIR}/.git" ]]; then
            blue "GApps: cloning ${GAPPS_REPO_URL}..."
            if ! git clone --depth=1 "${GAPPS_REPO_URL}" "${GAPPS_REPO_DIR}"; then
                yellow "GApps: git clone failed — skipping GMS injection"
                GAPPS_SKIP=true
            fi
        else
            blue "GApps: repo already cloned at ${GAPPS_REPO_DIR} — skipping clone"
        fi
    fi

    if [[ "${GAPPS_SKIP}" != true ]]; then
        blue "GApps: installing from ${GAPPS_REPO_DIR}..."

        # ── 1. system/priv-app ────────────────────────────────────────────────
        # Privileged apps: GmsCore, Phonesky, Velvet, Dialer, Messages, etc.
        # Must be in priv-app — GmsCore checks its own install path at startup.
        gapps_priv_src="${GAPPS_REPO_DIR}/system/priv-app"
        gapps_priv_dst="build/portrom/images/system/system/priv-app"
        if [[ -d "${gapps_priv_src}" ]]; then
            mkdir -p "${gapps_priv_dst}"
            while IFS= read -r app_dir; do
                app_name=$(basename "${app_dir}")
                green "  [priv-app] ${app_name}"
                rm -rf "${gapps_priv_dst}/${app_name}"
                cp -rf "${app_dir}" "${gapps_priv_dst}/${app_name}"
            done < <(find "${gapps_priv_src}" -mindepth 1 -maxdepth 1 -type d)
        fi

        # ── 2. system/app ─────────────────────────────────────────────────────
        # Regular Google apps: Chrome, Maps, Photos, YouTube, Drive, TTS, etc.
        gapps_app_src="${GAPPS_REPO_DIR}/system/app"
        gapps_app_dst="build/portrom/images/system/system/app"
        if [[ -d "${gapps_app_src}" ]]; then
            mkdir -p "${gapps_app_dst}"
            while IFS= read -r app_dir; do
                app_name=$(basename "${app_dir}")
                green "  [system/app] ${app_name}"
                rm -rf "${gapps_app_dst}/${app_name}"
                cp -rf "${app_dir}" "${gapps_app_dst}/${app_name}"
            done < <(find "${gapps_app_src}" -mindepth 1 -maxdepth 1 -type d)
        fi

        # ── 3. product/priv-app ───────────────────────────────────────────────
        # CarrierServices, GoogleOneTimeInitializer if present in the gapps repo
        gapps_product_priv_src="${GAPPS_REPO_DIR}/product/priv-app"
        gapps_product_priv_dst="build/portrom/images/product/priv-app"
        if [[ -d "${gapps_product_priv_src}" ]]; then
            mkdir -p "${gapps_product_priv_dst}"
            while IFS= read -r app_dir; do
                app_name=$(basename "${app_dir}")
                green "  [product/priv-app] ${app_name}"
                rm -rf "${gapps_product_priv_dst}/${app_name}"
                cp -rf "${app_dir}" "${gapps_product_priv_dst}/${app_name}"
            done < <(find "${gapps_product_priv_src}" -mindepth 1 -maxdepth 1 -type d)
        fi

        # ── 4. product/app ────────────────────────────────────────────────────
        gapps_product_app_src="${GAPPS_REPO_DIR}/product/app"
        gapps_product_app_dst="build/portrom/images/product/app"
        if [[ -d "${gapps_product_app_src}" ]]; then
            mkdir -p "${gapps_product_app_dst}"
            while IFS= read -r app_dir; do
                app_name=$(basename "${app_dir}")
                green "  [product/app] ${app_name}"
                rm -rf "${gapps_product_app_dst}/${app_name}"
                cp -rf "${app_dir}" "${gapps_product_app_dst}/${app_name}"
            done < <(find "${gapps_product_app_src}" -mindepth 1 -maxdepth 1 -type d)
        fi

        # ── 5. Permissions XMLs ───────────────────────────────────────────────
        # MindTheGapps ships these in system/etc/permissions/ — GmsCore needs
        # every privapp-permissions-google*.xml or it silently loses its grants.
        gapps_perm_dst="build/portrom/images/my_product/etc/permissions"
        mkdir -p "${gapps_perm_dst}"
        for perm_src in             "${GAPPS_REPO_DIR}/system/etc/permissions"             "${GAPPS_REPO_DIR}/product/etc/permissions"
        do
            if [[ -d "${perm_src}" ]]; then
                while IFS= read -r xmlfile; do
                    fname=$(basename "${xmlfile}")
                    green "  [permissions] ${fname}"
                    cp -f "${xmlfile}" "${gapps_perm_dst}/${fname}"
                done < <(find "${perm_src}" -maxdepth 1 -type f -name "*.xml")
            fi
        done

        # ── 6. sysconfig XMLs ─────────────────────────────────────────────────
        # Google-specific sysconfig (default-permissions, whitelist, etc.)
        gapps_syscfg_dst="build/portrom/images/system/system/etc/sysconfig"
        mkdir -p "${gapps_syscfg_dst}"
        for syscfg_src in             "${GAPPS_REPO_DIR}/system/etc/sysconfig"             "${GAPPS_REPO_DIR}/product/etc/sysconfig"
        do
            if [[ -d "${syscfg_src}" ]]; then
                while IFS= read -r xmlfile; do
                    fname=$(basename "${xmlfile}")
                    green "  [sysconfig] ${fname}"
                    cp -f "${xmlfile}" "${gapps_syscfg_dst}/${fname}"
                done < <(find "${syscfg_src}" -maxdepth 1 -type f -name "*.xml")
            fi
        done

        # ── 7. CTS fingerprint — from gapps repo build.prop if present ────────
        # MindTheGapps optionally ships a build.prop with an approved fingerprint.
        # If absent, warn — user can set GAPPS_CTS_FINGERPRINT manually.
        gapps_fp=""
        for fp_src in             "${GAPPS_REPO_DIR}/system/build.prop"             "${GAPPS_REPO_DIR}/system/system/build.prop"
        do
            if [[ -f "${fp_src}" ]]; then
                gapps_fp=$(grep -m1 "^ro.build.fingerprint=" "${fp_src}" | cut -d'=' -f2-)
                [[ -n "${gapps_fp}" ]] && break
            fi
        done
        # Allow manual override via env var
        [[ -n "${GAPPS_CTS_FINGERPRINT:-}" ]] && gapps_fp="${GAPPS_CTS_FINGERPRINT}"

        if [[ -n "${gapps_fp}" ]]; then
            blue "  [CTS] fingerprint: ${gapps_fp}"
            for prop_file in                 "build/portrom/images/system/system/build.prop"                 "build/portrom/images/my_product/build.prop"                 "build/portrom/images/vendor/build.prop"
            do
                [[ ! -f "${prop_file}" ]] && continue
                set_prop "${prop_file}" "ro.build.fingerprint=${gapps_fp}"
                set_prop "${prop_file}" "ro.system.build.fingerprint=${gapps_fp}"
                set_prop "${prop_file}" "ro.product.build.fingerprint=${gapps_fp}"
                set_prop "${prop_file}" "ro.bootimage.build.fingerprint=${gapps_fp}"
                set_prop "${prop_file}" "ro.vendor.build.fingerprint=${gapps_fp}"
            done
            green "  [CTS] fingerprint injected"
        else
            yellow "  [CTS] no fingerprint found in gapps repo — set GAPPS_CTS_FINGERPRINT=<fp> to inject manually"
        fi

        # ── 8. GMS system props ───────────────────────────────────────────────
        set_prop "build/portrom/images/my_product/build.prop"             "ro.com.google.gmsversion=${port_android_version}.0"
        set_prop "build/portrom/images/my_product/build.prop"             "ro.com.google.clientidbase=android-oppo"

        # ── 9. GMS feature flags ──────────────────────────────────────────────
        add_feature_v2 permission_feature             "android.software.managed_users"             "android.software.app_widgets"             "android.hardware.nfc"             "android.hardware.location.gps"

        # ── 10. Gemini — set as default assistant ─────────────────────────────
        # Look for Gemini APK in what we just installed (it may be in priv-app
        # from the gapps repo), otherwise fall back to Velvet which carries the
        # assistant service as a component.
        gemini_pkg="com.google.android.apps.bard"
        gemini_found=false
        for gemini_candidate in             "${gapps_priv_dst}/GeminiApps"             "${gapps_priv_dst}/Gemini"             "${gapps_product_priv_dst}/GeminiApps"
        do
            if [[ -d "${gemini_candidate}" ]]; then
                gemini_found=true
                green "  [Gemini] found at ${gemini_candidate}"
                break
            fi
        done
        if [[ "${gemini_found}" != true ]]; then
            yellow "  [Gemini] not in gapps repo — Velvet will carry assistant service"
            gemini_pkg="com.google.android.googlequicksearchbox"
        fi

        # RoleManager: declare Gemini as ROLE_ASSISTANT, Chrome as ROLE_BROWSER
        for sysconfig_dir in             "build/portrom/images/my_product/etc/sysconfig"             "build/portrom/images/system/system/etc/sysconfig"
        do
            mkdir -p "${sysconfig_dir}"
            cat > "${sysconfig_dir}/oplus-assistant-role.xml" << ROLESEOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Rapchick Engine (@revork) — sets Google Gemini as default assistant -->
<config>
    <role-holders>
        <role name="android.app.role.ASSISTANT">
            <holder name="${gemini_pkg}" />
        </role>
        <role name="android.app.role.BROWSER">
            <holder name="com.android.chrome" />
        </role>
        <role name="android.app.role.DIALER">
            <holder name="com.google.android.dialer" />
        </role>
    </role-holders>
</config>
ROLESEOF
        done

        # Pre-grant Gemini microphone + location at first boot
        for perms_dir in             "build/portrom/images/my_product/etc/default-permissions"             "build/portrom/images/system/system/etc/default-permissions"
        do
            mkdir -p "${perms_dir}"
            cat > "${perms_dir}/default-permissions-gemini.xml" << PERMEOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Rapchick Engine (@revork) — pre-grant Gemini mic + location -->
<exceptions>
    <exception package="${gemini_pkg}">
        <permission name="android.permission.RECORD_AUDIO" fixed="false" />
        <permission name="android.permission.ACCESS_FINE_LOCATION" fixed="false" />
        <permission name="android.permission.READ_PHONE_STATE" fixed="false" />
    </exception>
</exceptions>
PERMEOF
        done

        # ro.voice.interaction.service
        if [[ "${gemini_pkg}" == "com.google.android.apps.bard" ]]; then
            voice_svc="${gemini_pkg}/com.google.android.apps.bard.shared.voiceinteraction.BardVoiceInteractionService"
        else
            voice_svc="${gemini_pkg}/com.google.android.voiceinteraction.GsaVoiceInteractionService"
        fi
        for prop_file in             "build/portrom/images/system/system/build.prop"             "build/portrom/images/my_product/build.prop"
        do
            [[ -f "${prop_file}" ]] &&                 set_prop "${prop_file}" "ro.voice.interaction.service=${voice_svc}"
        done
        green "  [Gemini] default assistant configured"

        # ── 11. Remove Breeno / HeyTap assistant fully ────────────────────────
        blue "  [GApps] Removing Breeno/HeyTap assistant..."
        breeno_apk_dirs=(
            "HeyTapSpeechAssist" "BreenoPlatform" "BreenoSpeech"
            "BreenoAssistant"    "VoiceAssistant" "SpeechAssist"
            "OPlusAIAssistant"   "AIAssistant"
        )
        for adir in "${breeno_apk_dirs[@]}"; do
            while IFS= read -r found; do
                yellow "  [GApps] Removing ${found}"
                rm -rf "${found}"
            done < <(find build/portrom/images/ -type d -name "${adir}" 2>/dev/null)
        done
        rm -rf build/portrom/images/my_product/etc/breenospeech2
        for sysconfig_root in             "build/portrom/images/my_product/etc/sysconfig"             "build/portrom/images/system/system/etc/sysconfig"
        do
            while IFS= read -r xmlfile; do
                grep -qiE "heytap|breeno|speechassist" "${xmlfile}" 2>/dev/null &&                     sed -i '/heytap\|breeno\|speechassist\|HeyTapSpeech/Id' "${xmlfile}"
            done < <(find "${sysconfig_root}" -name "*.xml" -type f 2>/dev/null)
        done
        for feat_dir in             "build/portrom/images/my_product/etc/extension"             "build/portrom/images/my_product/etc/permissions"
        do
            while IFS= read -r xmlfile; do
                grep -qiE "breeno|speechassist|heytap.speech" "${xmlfile}" 2>/dev/null &&                     sed -i '/breeno\|speechassist\|heytap\.speech/Id' "${xmlfile}"
            done < <(find "${feat_dir}" -name "*.xml" -type f 2>/dev/null)
        done
        for prop_file in             "build/portrom/images/system/system/build.prop"             "build/portrom/images/my_product/build.prop"             "build/portrom/images/my_product/etc/bruce/build.prop"
        do
            [[ -f "${prop_file}" ]] &&                 sed -i '/heytap\|breeno\|speechassist\|ro\.breeno\|persist\.heytap/Id'                     "${prop_file}"
        done
        green "  [GApps] Breeno removed — Gemini is sole assistant"

        green "Google services injection complete — Rapchick Engine (@revork)"
    fi
fi

if [[ -f devices/common/GoogleCtS_cos-16.zip ]] && [[ "$port_android_version" == "16" ]]; then
    unzip -o devices/common/GoogleCtS_cos-16.zip -d build/portrom/images/
fi


# Custom Replacements


# `devices/<device_code>/overlay` follows image directory structure; can be directly swapped

if [[ -d "devices/common/overlay" ]]; then
    cp -rfv  devices/common/overlay/* build/portrom/images/
fi

if [[ -d "devices/${base_product_device}/overlay" ]]; then
    cp -rfv  devices/${base_product_device}/overlay/* build/portrom/images/
else
    yellow "devices/${base_product_device}/overlay not found" "devices/${base_product_device}/overlay not found" 
fi

if [[ -f "devices/${base_product_device}/odm_selinux_fix_a16.zip" ]] && [[ "$port_android_version" == 16 ]]; then
    unzip -o "devices/${base_product_device}/odm_selinux_fix_a16.zip" -d "${work_dir}/build/portrom/images/"
fi

###############################################################################
# Custom Kernel Integration (AnyKernel zip)
#
# Searches for AnyKernel (containing anykernel.sh) in `devices/${base_product_device}/*.zip`,
# extracts Image/dtb/dtbo.img, and reconstructs boot.img.
# - Branches based on naming like `*-KSU` / `*-NoKSU` to change save location.
# - Generated boot_*.img / dtbo_*.img are bundled into the final flash package.
###############################################################################
while IFS= read -r -d '' zip; do
    if unzip -l "$zip" | grep -q "anykernel.sh" ;then
        blue "Custom kernel zip detected: $zip [AnyKernel format]" "Custom Kernel zip $zip detected [Anykernel]"
        
        # Create unique temp directory per zip
        zip_name=$(basename "$zip")
        temp_ak_dir="tmp/anykernel_${zip_name%.*}"
        rm -rf "$temp_ak_dir"
        mkdir -p "$temp_ak_dir"
        
        unzip -q "$zip" -d "$temp_ak_dir" > /dev/null 2>&1
        
        # Search for kernel image (Image or Image.gz)
        kernel_file=$(find "$temp_ak_dir" -name "Image" -print -quit)
        if [[ -z "$kernel_file" ]]; then 
             kernel_file=$(find "$temp_ak_dir" -name "Image.gz" -print -quit)
        fi
        
        # Convert file paths to absolute
        [[ -n "$kernel_file" ]] && kernel_file=$(readlink -f "$kernel_file")

        dtb_file=$(find "$temp_ak_dir" -name "dtb" -print -quit)
        [[ -n "$dtb_file" ]] && dtb_file=$(readlink -f "$dtb_file")

        dtbo_img=$(find "$temp_ak_dir" -name "dtbo.img" -print -quit)
        [[ -n "$dtbo_img" ]] && dtbo_img=$(readlink -f "$dtbo_img")

        if [[ -n "$kernel_file" ]]; then
            blue "Integrating custom kernel into boot.img: $zip_name" "Integrating custom kernel into boot.img: $zip_name"
            
            # Determine target based on filename
            if echo "$zip_name" | grep -qi "KSU" && ! echo "$zip_name" | grep -qi "NoKSU"; then
                 target_boot="boot_ksu.img"
                 target_dtbo="dtbo_ksu.img"
            elif echo "$zip_name" | grep -qi "NoKSU"; then
                 target_boot="boot_noksu.img"
                 target_dtbo="dtbo_noksu.img"
            else
                 target_boot="boot_custom.img"
                 target_dtbo="dtbo_custom.img"
            fi
            
            # Copy dtbo.img if it exists
            if [[ -n "$dtbo_img" ]]; then
                cp -fv "$dtbo_img" "${work_dir}/devices/${base_product_device}/${target_dtbo}"
            fi
            
            # Run kernel patch
            patch_kernel "$kernel_file" "$dtb_file" "$target_boot"
            blue "${target_boot} generated" "New ${target_boot} generated"
            
        else
            yellow "Kernel image (Image/Image.gz) not found: $zip" "Kernel image not found in $zip"
        fi
        
        # Delete temp directory
        rm -rf "$temp_ak_dir"
    fi
done < <(find "devices/${base_product_device}/" -name "*.zip" -print0)


# KernelSU init_boot Patch (ksud)
#
# Estimates kernel series (e.g., 6.1 / 6.6 / 6.12) from ROM side `ro.build.kernel.id`,
# selects corresponding KMI name (android14-6.1 etc.), and runs `ksud boot-patch`.
# Skips if no match is found for safety.
# kernel_id must be initialized to avoid set -u firing when the prop is absent
kernel_id=""
kernel_prop=""
while IFS= read -r prop; do
    val=$(grep -E '^ro.build.kernel.id=' "$prop" 2>/dev/null | cut -d= -f2 || true)
    if [ -n "$val" ]; then
        kernel_id="$val"
        kernel_prop="$prop"
        break
    fi
done < <(find "$work_dir/build/portrom/images" -type f -name "build.prop")

kernel_major=$(echo "${kernel_id:-}" | grep -Eo '^[0-9]+\.[0-9]+' || true)

kmi=""
case "$kernel_major" in
    6.1)  kmi="android14-6.1" ;;
    6.6)  kmi="android15-6.6" ;;
    6.12) kmi="android16-6.12" ;;
esac

if [ -z "$kmi" ]; then
    echo "⚠ KMI mismatch (ro.build.kernel.id=$kernel_id). Skipping init_boot patch via ksud"
else
    echo "✔ Kernel $kernel_major detected → Using KMI: $kmi"
    mkdir -p tmp/init_boot
    (
    cd tmp/init_boot
    cp -f "${work_dir}/build/baserom/images/init_boot.img" "${work_dir}/tmp/init_boot/"
    ksud boot-patch \
        -b "${work_dir}/tmp/init_boot/init_boot.img" \
        --magiskboot magiskboot \
        --kmi "$kmi"
    mv -f "${work_dir}/tmp/init_boot/kernelsu_"*.img "${work_dir}/build/baserom/images/init_boot-kernelsu.img"
    )
fi

# Add EROFS fstab entries (only if necessary)
# if [ ${pack_type} == "EROFS" ];then
#     yellow "Checking if EROFS mount points need to be added to vendor fstab.qcom" "Validating whether adding erofs mount points is needed."
#     if ! grep -q "erofs" build/portrom/images/vendor/etc/fstab.qcom ; then
#                for pname in system odm vendor product mi_ext system_ext; do
#                      sed -i "/\/${pname}[[:space:]]\+ext4/{p;s/ext4/erofs/;s/ro,barrier=1,discard/ro/;}" build/portrom/images/vendor/etc/fstab.qcom
#                      added_line=$(sed -n "/\/${pname}[[:space:]]\+erofs/p" build/portrom/images/vendor/etc/fstab.qcom)
#                     if [ -n "$added_line" ]; then
#                         yellow "Adding mount point: $pname" "Adding mount point $pname"
#                     else
#                         error "Addition failed. Please check content." "Adding faild, please check."
#                         exit 1
                        
#                     fi
#                 done
#     fi
# fi

# Disable AVB Verification
blue "Disabling AVB Verification" "Disable avb verification."
disable_avb_verify build/portrom/images/

# Data Decryption
remove_data_encrypt=$(grep "remove_data_encryption" bin/port_config 2>/dev/null | cut -d '=' -f 2 || true)
if [[ ${remove_data_encrypt} == "true" ]];then
    DECRYPTRD="-DECRYPTED"
    blue "Disabling data encryption"
    while IFS= read -r fstab; do
		blue "Target: $fstab"
		sed -i "s/,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts:aes-256-cts:v2+emmc_optimized+wrappedkey_v0//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts:aes-256-cts:v2//g" $fstab
		sed -i "s/,metadata_encryption=aes-256-xts:wrappedkey_v0//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts:wrappedkey_v0//g" $fstab
		sed -i "s/,metadata_encryption=aes-256-xts//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts//g" $fstab
        sed -i "s/,fileencryption=ice//g" $fstab
		sed -i "s/fileencryption/encryptable/g" "$fstab"
	done < <(find build/portrom/images -type f -name "fstab.*")
fi

# for pname in ${port_partition};do
#     rm -rf build/portrom/images/${pname}.img
# done
echo "${pack_type}">fstype.txt
if [[ "${super_extended}" == true ]];then
    superSize=$(bash bin/getSuperSize.sh "others")
elif [[ $base_product_model == "KB2000" ]] && [[ "$is_ab_device" == false ]] ; then
    # OnePlus 8T A-only ROM
    echo ro.product.cpuinfo=SM8250 >> build/portrom/images/my_manifest/build.prop
    superSize=$(bash bin/getSuperSize.sh OnePlus9R)
elif [[ $base_product_model == "LE2101" ]]; then
    # "9R IN"
    superSize=$(bash bin/getSuperSize.sh OnePlus8T)
else
    superSize=$(bash bin/getSuperSize.sh $base_product_device)
fi

green "Super Size: ${superSize}" "Super image size: ${superSize}"
###############################################################################
# Repacking Partitions (Directory -> *.img)
#
# - `bin/fspatch.py`   : Generates fs_config (UID/GID/Mode/Capabilities)
# - `bin/contextpatch.py`: Generates file_contexts (SELinux labels)
# - `mkfs.erofs`       : Creates EROFS image from directory
#
# Note:
#   Only partitions included in `super_list` are processed.
###############################################################################
green "Starting image packing" "Packing img"
for pname in ${super_list};do
    if [ -d "build/portrom/images/$pname" ];then
        if [[ "$OSTYPE" == "darwin"* ]];then
            thisSize=$(find build/portrom/images/${pname} | xargs stat -f%z | awk ' {s+=$1} END { print s }' )
        else
            thisSize=$(du -sb build/portrom/images/${pname} |tr -cd 0-9)
        fi
        blue "Packing [${pname}.img] with [${pack_type}]" "Packing [${pname}.img] with [${pack_type}]"
        python3 bin/fspatch.py "build/portrom/images/${pname}" "build/portrom/images/config/${pname}_fs_config"
        python3 bin/contextpatch.py "build/portrom/images/${pname}" "build/portrom/images/config/${pname}_file_contexts"
        if [[ "${pack_type}" == "EXT" ]]; then
            # EXT4 repack path
            make_ext4fs -s -T 1648635685 \
                -l "${thisSize}" \
                -C "build/portrom/images/config/${pname}_fs_config" \
                -L "${pname}" \
                -a "${pname}" \
                "build/portrom/images/${pname}.img" \
                "build/portrom/images/${pname}" \
                || { python3 bin/make_ext4fs.py \
                       -T 1648635685 \
                       -l "${thisSize}" \
                       -s "build/portrom/images/config/${pname}_fs_config" \
                       -c "build/portrom/images/config/${pname}_file_contexts" \
                       "build/portrom/images/${pname}.img" \
                       "build/portrom/images/${pname}" || true; }
        else
            # EROFS repack path (default)
            mkfs.erofs -zlz4hc,9 \
                --mount-point "${pname}" \
                --fs-config-file "build/portrom/images/config/${pname}_fs_config" \
                --file-contexts "build/portrom/images/config/${pname}_file_contexts" \
                -T 1648635685 \
                "build/portrom/images/${pname}.img" \
                "build/portrom/images/${pname}"
        fi
        if [[ -f "build/portrom/images/${pname}.img" ]]; then
            green "Successfully packed [${pname}.img] as [${pack_type}]"
        else
            error "Failed to pack [${pname}] as [${pack_type}]" "Pack failed: ${pname}"
            exit 1
        fi
        unset fsType
        unset thisSize
    fi
done


rm -f fstype.txt

if [[ "${port_vendor_brand}" == "realme" ]]; then
    os_type="RealmeUI"
else
    os_type="ColorOS"
fi
rom_version=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.id" | cut -d'(' -f1)
while IFS= read -r img; do
    blue "Disabling vbmeta verification: $img"
    python3 bin/patch-vbmeta.py "$img" > /dev/null 2>&1
done < <(find build/baserom/ -type f -name "vbmeta*.img")
if [[ -f "devices/${base_product_device}/recovery.img" ]]; then
  cp -rfv "devices/${base_product_device}/recovery.img" build/baserom/images/
fi

if [[ -f "devices/${base_product_device}/vendor_boot.img" ]]; then
  cp -rfv "devices/${base_product_device}/vendor_boot.img" build/baserom/images/
fi

if [[ -f "devices/${base_product_device}/abl.img" ]]; then
  cp -rfv "devices/${base_product_device}/abl.img" build/portrom/images/
fi

if [[ -f "devices/${base_product_device}/odm.img" ]]; then
  cp -rfv "devices/${base_product_device}/odm.img" build/portrom/images/
fi

if [[ -f "devices/${base_product_device}/tz.img" ]]; then
  cp -rfv "devices/${base_product_device}/tz.img" build/baserom/images/
fi

if [[ -f "devices/${base_product_device}/keymaster.img" ]]; then
  cp -rfv "devices/${base_product_device}/keymaster.img" build/baserom/images/
fi

if [[ "$is_ab_device" == true ]]; then
    if [[ ! -f build/portrom/images/my_preload.img ]];then
        cp -rfv devices/common/my_preload_empty.img build/portrom/images/my_preload.img
    fi
    if [[ ! -f build/portrom/images/my_company.img ]];then
        cp -rfv devices/common/my_company_empty.img build/portrom/images/my_company.img
    fi
elif [[ "$is_ab_device" == false ]];then
    rm -rf build/portrom/images/my_company.img
    rm -rf build/portrom/images/my_preload.img
fi

###############################################################################
# Package Creation
#
# Final output format changes based on `pack_method`.
# - stock: Assembles `out/target/product/<device>/` (target_files style) and generates OTA (full) zip via `otatools`
# - other: Creates super.img via `lpmake` and generates flashable zip (bundled with windows/mac/linux scripts)
###############################################################################
pack_timestamp=$(date +"%m%d%H%M")
super_list_info=""  # accumulated partition list for OTA metadata
output_zip=""  # set by whichever pack path runs - used in final banner
if [[ "$pack_method" == "stock" ]];then
    rm -rf "out/target/product/${base_product_device}/"
    mkdir -p "out/target/product/${base_product_device}/IMAGES"
    mkdir -p "out/target/product/${base_product_device}/META"
    for part in SYSTEM SYSTEM_EXT PRODUCT VENDOR ODM; do
        mkdir -p "out/target/product/${base_product_device}/$part"
    done
    mv -fv build/portrom/images/*.img "out/target/product/${base_product_device}/IMAGES/"
    if [[ -d build/baserom/firmware-update ]];then
        bootimg=$(find build/baserom/ -name "boot.img")
        cp -rf "$bootimg" "out/target/product/${base_product_device}/IMAGES/"
    else
        if [[ -f build/baserom/images/init_boot-kernelsu.img ]];then
            mv build/baserom/images/init_boot-kernelsu.img build/baserom/images/init_boot.img
        fi
        mv -fv build/baserom/images/*.img "out/target/product/${base_product_device}/IMAGES/"
    fi

    if [[ -d "devices/${base_product_device}" ]];then

        ksu_bootimg_file=$(find "devices/${base_product_device}/" -type f \( -name "*boot_ksu.img" -o -name "*boot_custom.img" -o -name "*boot_noksu.img" \) | head -n 1)
        dtbo_file=$(find "devices/${base_product_device}/" -type f \( -name "*dtbo_ksu.img" -o -name "*dtbo_custom.img" -o -name "*dtbo_noksu.img" \) | head -n 1)
        vendor_boot_file=$(find "devices/${base_product_device}/" -type f -name "vendor_boot.img" | head -n 1)

        if [ -n "$ksu_bootimg_file" ];then
            mv -fv "$ksu_bootimg_file" "out/target/product/${base_product_device}/IMAGES/boot.img"
        else
            spoof_bootimg "out/target/product/${base_product_device}/IMAGES/boot.img"
        fi

        if [ -n "$dtbo_file" ];then
            mv -fv "$dtbo_file" "out/target/product/${base_product_device}/IMAGES/dtbo.img"
        fi

        if [ -n "$vendor_boot_file" ];then
             cp -fv "$vendor_boot_file" "out/target/product/${base_product_device}/IMAGES/vendor_boot.img"
        fi
    fi
    rm -rf "out/target/product/${base_product_device}/META/ab_partitions.txt"
    rm -rf "out/target/product/${base_product_device}/META/update_engine_config.txt"
    rm -rf "out/target/product/${base_product_device}/target-file.zip"
    for part in out/target/product/${base_product_device}/IMAGES/*.img; do
        partname=$(basename "$part" .img)
        echo $partname >> out/target/product/${base_product_device}/META/ab_partitions.txt
        if echo $super_list | grep -q -w "$partname"; then
            super_list_info+="$partname "
            otatools/bin/map_file_generator $part ${part%.*}.map
        fi
    done 
    rm -rf out/target/product/${base_product_device}/META/dynamic_partitions_info.txt
    (( groupSize = superSize - 1048576 ))
    {
        echo "super_partition_size=$superSize"
        echo "super_partition_groups=qti_dynamic_partitions"
        echo "super_qti_dynamic_partitions_group_size=$groupSize"
        echo "super_qti_dynamic_partitions_partition_list=$super_list_info"
        echo "virtual_ab=true"
        echo "virtual_ab_compression=true"
    } >> out/target/product/${base_product_device}/META/dynamic_partitions_info.txt

    {
        #echo "default_system_dev_certificate=key/testkey"
        echo "recovery_api_version=3"
        echo "fstab_version=2"
        echo "ab_update=true"
     } >> out/target/product/${base_product_device}/META/misc_info.txt
    
    {
        echo "PAYLOAD_MAJOR_VERSION=2"
        echo "PAYLOAD_MINOR_VERSION=8"
    } >> out/target/product/${base_product_device}/META/update_engine_config.txt

    if [[ "$is_ab_device" == false ]];then
        sed -i "/ab_update=true/d" out/target/product/${base_product_device}/META/misc_info.txt
        {
            echo "blockimgdiff_versions=3,4"
            echo "use_dynamic_partitions=true"
            echo "dynamic_partition_list=$super_list_info"
            echo "super_partition_groups=qti_dynamic_partitions"
            echo "super_qti_dynamic_partitions_group_size=$superSize"
            echo "super_qti_dynamic_partitions_partition_list=$super_list_info"
            echo "board_uses_vendorimage=true"
            echo "cache_size=402653184"

        } >> out/target/product/${base_product_device}/META/misc_info.txt
        mkdir -p out/target/product/${base_product_device}/OTA/bin
        for part in MY_PRODUCT MY_BIGBALL MY_CARRIER MY_ENGINEERING MY_HEYTAP MY_MANIFEST MY_REGION MY_STOCK;do
            mkdir -p out/target/product/${base_product_device}/$part
        done

        if [[ -f devices/${base_product_device}/OTA/bin/updater ]];then
            cp -rf devices/${base_product_device}/OTA/bin/updater out/target/product/${base_product_device}/OTA/bin
        else
            cp -rf devices/common/non-ab/OTA/updater out/target/product/${base_product_device}/OTA/bin
        fi
        if [[ -d build/baserom/firmware-update ]];then
            cp -rf build/baserom/firmware-update out/target/product/${base_product_device}/ || true
        elif find build/baserom/ -type f \( -name "*.elf" -o -name "*.mdn" -o -name "*.bin" \) | grep -q .; then
            while IFS= read -r firmware; do
                mv -fv "$firmware" out/target/product/${base_product_device}/firmware-update/
            done < <(find build/baserom/ -type f \( -name "*.elf" -o -name "*.mdn" -o -name "*.bin" \))
            bootimg=$(find build/baserom/ -name "boot.img")
            dtboimg=$(find build/baserom/images -name "dtbo.img")
            vbmetaimg=$(find build/baserom/ -name "vbmeta.img")
            vmbeta_systemimg=$(find build/baserom/ -name "vbmeta_sytem.img")
            cp -rf $bootimg out/target/product/${base_product_device}/IMAGES/
            cp -rf $dtboimg out/target/product/${base_product_device}/firmware-update
            cp -rf $vbmetaimg out/target/product/${base_product_device}/firmware-update
            cp -rf $vmbeta_systemimg out/target/product/${base_product_device}/firmware-update
        fi

        if [[ -d build/baserom/storage-fw ]];then
            cp -rf build/baserom/storage-fw out/target/product/${base_product_device}/ || true
            cp -rf build/baserom/ffu_tool out/target/product/${base_product_device}/storage-fw || true
        else
            cp -rf build/baserom/ffu_tool out/target/product/${base_product_device}/ || true
	fi

        export OUT=$(pwd)/out/target/product/${base_product_device}/
        if [[ -f devices/${base_product_device}/releasetools.py ]];then
            cp -rf devices/${base_product_device}/releasetools.py out/target/product/${base_product_device}/META/
        else
            cp -rf devices/common/releasetools.py out/target/product/${base_product_device}/META/
        fi

        mkdir -p out/target/product/${base_product_device}/RECOVERY/RAMDISK/etc/
        if [[ -f devices/${base_product_device}/recovery.fstab ]];then
            cp -rf devices/${base_product_device}/recovery.fstab out/target/product/${base_product_device}/RECOVERY/RAMDISK/etc/
        else
            cp -rf devices/common/recovery.fstab out/target/product/${base_product_device}/RECOVERY/RAMDISK/etc/
        fi
    fi
    declare -A prop_paths=(
    ["system"]="SYSTEM"
    ["product"]="PRODUCT"
    ["system_ext"]="SYSTEM_EXT"
    ["vendor"]="VENDOR"
    ["my_manifest"]="ODM"
    
    )

    for dir in "${!prop_paths[@]}"; do
        prop_file=$(find "build/portrom/images/$dir" -type f -name "build.prop" -not -path "*/system_dlkm/*" -not -path "*/odm_dlkm/*" -print -quit)
        if [ -n "$prop_file" ]; then
            cp "$prop_file" "out/target/product/${base_product_device}/${prop_paths[$dir]}/"
        fi
	    done
	    target_folder=${rom_version#*_}
	    pushd otatools >/dev/null
	    export PATH=$(pwd)/bin/:$PATH
	    mkdir -p ${work_dir}/out/$target_folder
	    if [[ -n "${OTA_KEY:-}" ]]; then
	        ota_key="${OTA_KEY}"
	    elif [[ -f "build/make/target/product/security/testkey.pk8" && -f "build/make/target/product/security/testkey.x509.pem" ]]; then
	        ota_key="build/make/target/product/security/testkey"
	    else
	        ota_key="key/testkey"
	    fi
	    if [[ ! -f "${ota_key}.pk8" || ! -f "${ota_key}.x509.pem" ]]; then
	        popd >/dev/null
	        error "OTA Signing Key not found: otatools/${ota_key}.{pk8,x509.pem}" \
	              "OTA signing key not found: otatools/${ota_key}.{pk8,x509.pem}"
	        exit 1
	    fi
	    ota_zip="${work_dir}/out/${base_product_device}-ota_full-${port_rom_version}-user-${port_android_version}.0.zip"
	    ./bin/ota_from_target_files -k "${ota_key}" \
	        "${work_dir}/out/target/product/${base_product_device}/" \
	        "${ota_zip}"
	    ota_rc=$?
	    popd >/dev/null
	    if [[ ${ota_rc} -ne 0 || ! -f "${ota_zip}" ]]; then
	        error "OTA package generation failed: ${ota_zip}" "Failed to generate OTA package: ${ota_zip}"
	        exit 1
	    fi
	    ziphash=$(md5sum "${ota_zip}" | head -c 10)
	    mv -f "${ota_zip}" "out/$target_folder/ota_full-${rom_version}-${port_product_model}-${pack_timestamp}-$regionmark-${portrom_version_security_patch}-${ziphash}.zip"
		blue "Packing complete: out/$target_folder/ota_full-${rom_version}-${port_product_model}-${pack_timestamp}-$regionmark-${portrom_version_security_patch}-${ziphash}.zip"
	else
	   if [[ "${is_ab_device}" == true ]]; then
	        # Pack super.img
        blue "Packing super.img for V-A/B terminal" "Packing super.img for V-AB device"
        lpargs="-F --virtual-ab --output build/portrom/images/super.img --metadata-size 65536 --super-name super --metadata-slots 3 --device super:$superSize --group=qti_dynamic_partitions_a:$superSize --group=qti_dynamic_partitions_b:$superSize"

        for pname in ${super_list};do
            if [ -f "build/portrom/images/${pname}.img" ];then
                subsize=$(du -sb build/portrom/images/${pname}.img |tr -cd 0-9)
                green "Super Sub-partition [$pname] Size [$subsize]" "Super sub-partition [$pname] size: [$subsize]"
                args="--partition ${pname}_a:none:${subsize}:qti_dynamic_partitions_a --image ${pname}_a=build/portrom/images/${pname}.img --partition ${pname}_b:none:0:qti_dynamic_partitions_b"
                lpargs="${lpargs} ${args}"
            fi
        done

        blue "Running lpmake..." "Running lpmake to build super.img"
        read -ra _lp_arr <<< "${lpargs}"
        lpmake "${_lp_arr[@]}"

        if [[ -f build/portrom/images/super.img ]]; then
            green "super.img built successfully"
        else
            error "super.img build failed — check lpmake output" "lpmake failed"
            exit 1
        fi
    elif [[ "${is_ab_device}" == false ]]; then
        blue "Packing super.img for A-only device"
        lpargs="-F --output build/portrom/images/super.img --metadata-size 65536 --super-name super --metadata-slots 2 --block-size 4096 --device super:$superSize --group=qti_dynamic_partitions:$superSize"
        for pname in ${super_list}; do
            if [[ -f "build/portrom/images/${pname}.img" ]]; then
                subsize=$(du -sb build/portrom/images/${pname}.img | tr -cd 0-9)
                green "Super sub-partition [$pname] size: [$subsize]"
                lpargs="${lpargs} --partition ${pname}:none:${subsize}:qti_dynamic_partitions --image ${pname}=build/portrom/images/${pname}.img"
            fi
        done
        read -ra _lp_arr <<< "${lpargs}"
        lpmake "${_lp_arr[@]}"
        if [[ -f build/portrom/images/super.img ]]; then
            green "super.img (A-only) built successfully"
        else
            error "super.img build failed" "lpmake failed"; exit 1
        fi
    fi

    # ── Package into flashable zip ────────────────────────────────────────────
    pack_timestamp=$(date +"%m%d%H%M")
    rom_version=$(get_prop build/portrom/images/my_manifest/build.prop "ro.build.display.id" | cut -d'(' -f1)
    output_zip="out/${os_type}_${rom_version}_${base_product_model}_${pack_timestamp}_flashable.zip"
    mkdir -p out

    blue "Packaging flashable zip: ${output_zip}"

    # Gather images to package
    zip_staging="tmp/zip_staging"
    rm -rf "${zip_staging}"
    mkdir -p "${zip_staging}/images"

    # super.img goes in for V-AB; baserom firmware images go alongside
    if [[ "$is_ab_device" == true ]]; then
        cp -f build/portrom/images/super.img "${zip_staging}/images/"
    fi

    # Copy all non-super partition images (boot, dtbo, vbmeta, etc.) from baserom
    while IFS= read -r img; do
        imgname=$(basename "${img}")
        [[ "${imgname}" == "super.img" ]] && continue
        cp -f "${img}" "${zip_staging}/images/"
    done < <(find build/baserom/images/ -maxdepth 1 -type f -name "*.img")

    # KSU / custom boot if present
    ksu_bootimg=$(find "devices/${base_product_device}/" -type f \
        \( -name "*boot_ksu.img" -o -name "*boot_custom.img" -o -name "*boot_noksu.img" \) \
        | head -n 1)
    if [[ -n "${ksu_bootimg}" ]]; then
        cp -f "${ksu_bootimg}" "${zip_staging}/images/boot.img"
    else
        spoof_bootimg "${zip_staging}/images/boot.img" 2>/dev/null || true
    fi

    # Flash script (device-specific or common fallback)
    if [[ -f "devices/${base_product_device}/flash.sh" ]]; then
        cp -f "devices/${base_product_device}/flash.sh" "${zip_staging}/flash.sh"
    elif [[ -f "devices/common/flash.sh" ]]; then
        cp -f "devices/common/flash.sh" "${zip_staging}/flash.sh"
    fi

    # Windows flash script
    if [[ -f "devices/${base_product_device}/flash.bat" ]]; then
        cp -f "devices/${base_product_device}/flash.bat" "${zip_staging}/flash.bat"
    elif [[ -f "devices/common/flash.bat" ]]; then
        cp -f "devices/common/flash.bat" "${zip_staging}/flash.bat"
    fi

    # Substitute device code placeholders in flash scripts
    for fscript in "${zip_staging}/flash.sh" "${zip_staging}/flash.bat"; do
        if [[ -f "${fscript}" ]]; then
            sed -i "s/device_code/${base_device_code}/g" "${fscript}"
            sed -i "s/DEVICE_CODE/${base_device_code}/g" "${fscript}"
        fi
    done

    # Build the zip
    pushd "${zip_staging}" > /dev/null
    zip -r9j "${work_dir}/${output_zip}" .
    popd > /dev/null

    if [[ -f "${output_zip}" ]]; then
        ziphash=$(md5sum "${output_zip}" | cut -c1-10)
        final_name="${output_zip%.zip}_${ziphash}.zip"
        mv -f "${output_zip}" "${final_name}"
        output_zip="${final_name}"
        green "Flashable zip created: ${output_zip}"
    else
        error "Failed to create flashable zip" "Zip packaging failed"
        exit 1
    fi

fi  # end of pack_method != stock

# ── Final banner ─────────────────────────────────────────────────────────────
_BUILD_ELAPSED=$(( SECONDS - _BUILD_START ))
_BUILD_MM=$(( _BUILD_ELAPSED / 60 ))
_BUILD_SS=$(( _BUILD_ELAPSED % 60 ))
green "════════════════════════════════════════════════════════"
green " Port complete — Rapchick Engine (@revork / Ozyern)"
green " Output  : ${output_zip:-<see out/ directory>}"
green " Duration: ${_BUILD_MM}m ${_BUILD_SS}s"
green "════════════════════════════════════════════════════════"