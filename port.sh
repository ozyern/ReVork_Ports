#!/bin/bash

# ColorOS_port project
# For A-only and V/A-B (not tested) Devices
# Based on Android 14 

# Test Base ROM: OnePlus 9 Pro (OxygenOS_14.0.0.1920)
# Test Port ROM: OnePlus 15 (OxygenOS_16.0.3.501), OnePlus ACE3V(ColorOS_14.0.1.621) Realme GT Neo5 240W(RMX3708_14.0.0.800)

###############################################################################
# port.sh (ColorOS/OxygenOS/realme UI Porting Script)
#
# Purpose:
#   - Use a Base ROM (BASEROM) as a foundation and integrate elements from 
#     a source ROM (PORTROM) to create a bootable ROM package for daily use.
#
# Input (Basic):
#   - $1: baserom   ... Official ROM for the base device (OTA/fastboot). URL supported.
#   - $2: portrom   ... Source ROM to port (ColorOS/OOS/realme UI). URL supported.
#   - $3: portrom2  ... Second source ROM (for mixed porting - optional).
#   - $4: portparts ... Partition names to adopt from portrom2 during mixed port (optional).
#
# Important:
#   - Most settings are controlled via `bin/port_config` (target partitions, repack method, etc.).
#   - This script utilizes log functions (blue/yellow/green/error) from `functions.sh`.
###############################################################################

build_user="Ozyern"
build_host="@reimagine"

# Receive BASEROM/PORTROM via external arguments
baserom="$1"
portrom="$2"
portrom2="$3"
portparts="$4"
work_dir=$(pwd)
tools_dir=${work_dir}/bin/$(uname)/$(uname -m)
export PATH=$(pwd)/bin/$(uname)/$(uname -m)/:$(pwd)/otatools/bin/:$PATH

# Import functions
source functions.sh

check unzip aria2c 7z zip java python3 zstd bc xmlstarlet

# Configurable settings via `bin/port_config`
port_partition=$(grep "partition_to_port" bin/port_config |cut -d '=' -f 2)
super_list=$(grep "possible_super_list" bin/port_config |cut -d '=' -f 2)
repackext4=$(grep "repack_with_ext4" bin/port_config |cut -d '=' -f 2)
super_extended=$(grep "super_extended" bin/port_config |cut -d '=' -f 2)
pack_with_dsu=$(grep "pack_with_dsu" bin/port_config | cut -d '=' -f 2)
pack_method=$(grep "pack_method" bin/port_config | cut -d '=' -f 2)
ddr_type=$(grep "ddr_type" bin/port_config | cut -d '=' -f 2)

# `pack_type` serves as a marker for how partitions are repacked later.
# - EXT  : Intended for regeneration with ext4 tools
# - EROFS: Intended for regeneration with EROFS
if [[ ${repackext4} == true ]]; then
    pack_type=EXT
else
    pack_type=EROFS
fi

# Determine if input is a local file or URL; download if it is a URL
if [ ! -f "${baserom}" ] && [ "$(echo "$baserom" | grep http)" != "" ];then
    blue "Base ROM is a URL. Starting download..." "Download link detected, start downloading.."
    aria2c --async-dns=false --max-download-limit=1024M --file-allocation=none -s10 -x10 -j10 "${baserom}"
    # URLs with `?t=...` can mess up filenames; strip query parts after saving
    baserom=$(basename "${baserom}" | sed 's/\?t.*//')
    if [ ! -f "${baserom}" ];then
        error "Download failed" "Download error!"
    fi
elif [ -f "${baserom}" ];then
    green "Base ROM: ${baserom}" "BASEROM: ${baserom}"
else
    error "Base ROM argument is invalid" "BASEROM: Invalid parameter"
    exit 1
fi

if [ ! -f "${portrom}" ] && [ "$(echo "${portrom}" | grep http)" != "" ];then
    blue "Port source ROM is a URL. Starting download..." "Download link detected, start downloading.."
    aria2c --async-dns=false --max-download-limit=1024M --file-allocation=none -s10 -x10 -j10 "${portrom}"
    # URLs with `?t=...` can mess up filenames; strip query parts after saving
    portrom=$(basename "${portrom}" | sed 's/\?t.*//')
    if [ ! -f "${portrom}" ];then
        error "Download failed" "Download error!"
    fi
elif [ -f "${portrom}" ];then
    green "Port source ROM: ${portrom}" "PORTROM: ${portrom}"
else
    error "Port source ROM argument is invalid" "PORTROM: Invalid parameter"
    exit 1
fi

if [ "$(echo "$baserom" | grep ColorOS_)" != "" ];then
    device_code=$(basename "$baserom" | cut -d '_' -f 2)
else
    device_code="op8t"
fi

blue "Validating Base ROM" "Validating BASEROM.."

# Determine Base ROM format (payload / *.new.dat.br / *.img)
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

# Determine Port source ROM format (payload / *.img)
if unzip -l "${portrom}" | grep -q "payload.bin"; then
    portrom_type="payload"
elif unzip -l "${portrom}" | grep -Eq "\.img$"; then
    portrom_type="img"
else
    error "payload.bin / *.img not found in Port source ROM (please specify an official ROM containing system.img)" \
          "payload.bin or *.img not found, please use an official ROM package containing system.img as PORTROM."
    exit 1
fi

# Extract ROM version info if metadata exists (otherwise estimate from filename)
if unzip -l "${portrom}" | grep -q "META-INF/com/android/metadata"; then
    version_name=$(unzip -p "${portrom}" META-INF/com/android/metadata 2>/dev/null | grep "version_name=" | cut -d= -f2)
    ota_version=$(unzip -p "${portrom}" META-INF/com/android/metadata 2>/dev/null | grep "ota_version=" | cut -d= -f2)
else
    version_name="$(basename "${portrom%.*}")"
    ota_version="V16.0.0"
fi

green "Basic ROM validation successful: ${portrom_type}" "ROM validation passed. Type: ${portrom_type}"
[[ -n "${version_name}" ]] && echo "Version Name: ${version_name}"


if [[ -n "$portrom2" ]];then
    mix_port=true
fi

if [[ -n "$portparts" ]];then
    mix_port_part=($portparts)
else
    mix_port_part=("my_stock" "my_region" "my_manifest" "my_product")
fi

if [[ "$mix_port" == true ]];then
    blue "Mixed Port Mode"
    blue "Validating second Port source ROM" "Validating PORTROM.."
    if unzip -l "${portrom2}" | grep  -q "payload.bin"; then
        green "Validation for second ROM successful" "ROM validation passed."
        portrom2_type="payload"
	version_name2=$(unzip -p "${portrom2}" META-INF/com/android/metadata | grep "version_name=" | cut -d = -f2)
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
    payload-dumper --out build/baserom/images/ "${baserom}"
    green "Base ROM extraction complete [payload.bin]" "[payload.bin] extracted."

elif [[ ${baserom_type} == 'br' ]]; then
    blue "Extracting Base ROM [*.new.dat.br]" "Extracting files from BASEROM [*.new.dat.br]"
    unzip -q "${baserom}" -d build/baserom || \
        error "Failed to extract Base ROM [new.dat.br]" "Extracting [new.dat.br] error"
    green "Base ROM extraction complete [new.dat.br]" "[new.dat.br] extracted."

    blue "Unpacking and converting Base ROM [new.dat.br]" "Unpacking BASEROM [new.dat.br]"
    # Pre-processing to generate *.img from *.new.dat.br.
    # Some ROMs use suffixes like `system.new.dat.1.br`; normalize names for later reference.
    for file in build/baserom/*; do
        filename=$(basename -- "$file")
        extension="${filename##*.}"
        name="${filename%.*}"

        if [[ $name =~ [0-9] ]]; then
            new_name=$(echo "$name" | sed 's/[0-9]\+\(\.[^0-9]\+\)/\1/g' | sed 's/\.\./\./g')
            mv -fv "$file" "build/baserom/${new_name}.${extension}"
        fi
    done

    # Decrypt with `brotli` -> Sparse conversion with `sdat2img` to create `.img` for each partition
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
    # Consolidate `.img` files from extraction directory to `build/baserom/images/`
    find build/baserom/tmp/ -type f -name "*.img" -exec mv -fv {} build/baserom/images/ \;
    rm -rf build/baserom/tmp/
    green "Base ROM extraction complete [*.img]" "[*.img] extracted."
else
    error "Unknown Base ROM format: ${baserom_type}" "Unknown base package type: ${baserom_type}"
    exit 1
fi


# ===== Port Source ROM Extraction =====
if [[ -n ${version_name} ]] && [[ -d build/${version_name} ]]; then 
    blue "Port source ROM cache detected: build/${version_name} (reusing)" \
         "Cached ${version_name} folder detected, copying..."
    IFS=',' read -ra PARTS <<< "$port_partition"
    for i in "${PARTS[@]}"; do
        cp -rfv "build/${version_name}/${i}.img" build/portrom/images/
    done

else
    mkdir -p build/${version_name}/ build/portrom/images/

    if [[ ${portrom_type} == 'payload' ]]; then
        blue "Extracting Port source ROM [payload.bin]" "Extracting PORTROM [payload.bin]"
        payload-dumper --partitions "${port_partition}" --out "build/${version_name}/" "${portrom}"
        cp -rfv build/${version_name}/*.img build/portrom/images/
        green "Port source ROM extraction complete [payload.bin]" "[payload.bin] extracted."

    elif [[ ${portrom_type} == 'img' ]]; then
        blue "Port source ROM format: [img] (extracting required .img files only)" "Extracting PORTROM containing .img files"
        # Convert `port_partition` (comma separated) to array
        IFS=',' read -ra PARTS <<< "$port_partition"

        # List target files for `unzip` (including a/b slot names)
        declare -a unzip_targets=()
        for part in "${PARTS[@]}"; do
          unzip_targets+=("${part}.img" "${part}_a.img" "${part}_b.img")
        done

        blue "Selectively extracting only required .img files" "Extracting specific img files from PORTROM"

        # Extract only specified `.img` partitions (avoid full ROM extraction)
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
    #IFS=',' read -ra PARTS <<< "$port_partition"
    for i in "${mix_port_part[@]}"; do
        # if [[ -f "build/${version_name}/${i}_patched.img" ]];then
        #     skip_list2+=("$i")
        #     cp -rfv "build/${version_name}/${i}_patched.img" "build/portrom/images/${i}.img"
        #else
            cp -rfv "build/${version_name2}/${i}.img" build/portrom/images/
        #fi
    done
elif [[ -n "${version_name2}" ]];then
    if [[ "${portrom2_type}" == 'payload' ]]; then
        blue "Extracting second Port source ROM [payload.bin]" "Extracting files from PORTROM [payload.bin]"
        mkdir -p "build/${version_name2}/"
        payload-dumper --partitions "${port_partition}" --out "build/${version_name2}/" "${portrom2}"
        for i in "${mix_port_part[@]}"; do
            cp -rfv "build/${version_name2}/${i}.img" build/portrom/images/
        done
    elif [[ "${portrom2_type}" == 'img' ]]; then
        blue "Second Port source ROM format: [img] (extracting required .img files only)" "Extracting PORTROM containing .img files"
        # Convert `port_partition` (comma separated) to array
        IFS=',' read -ra PARTS <<< "$port_partition"

        # List target files for `unzip` (including a/b slot names)
        declare -a unzip_targets=()
        for part in "${PARTS[@]}"; do
          unzip_targets+=("${part}.img" "${part}_a.img" "${part}_b.img")
        done

        blue "Selectively extracting only required .img files" "Extracting specific img files from PORTROM"

        # Extract only specified `.img` partitions (avoid full ROM extraction)
        unzip -q "${portrom2}" "${unzip_targets[@]}" -d "build/${version_name2}/" || \
        error "Failed to extract specified .img files (verify if ${port_partition} exists in ROM)" \
          "Failed to extract specified img files from PORTROM."

         green "Specified partition extraction successful" "Selected partitions extracted successfully."
        find "build/${version_name2}/" -type f -name "*.img" -exec cp -fv {} build/portrom/images/ \;
        green "Port source ROM extraction complete [*.img]" "[*.img] extracted."
    fi
fi

if [[ -n "${version_name}" ]] && [[ -n "${version_name2}" ]];then
    app_patch_folder="${version_name2}"
elif [[ -n "${version_name}" ]];then
    app_patch_folder="${version_name}"
fi

for part in system product system_ext my_product my_manifest;do
    extract_partition "build/baserom/images/${part}.img" build/baserom/images
done

###############################################################################
# Image Consolidation (Moving BASEROM -> PORTROM side)
#
# Some partitions present on the Base ROM side (vendor/odm etc.) are moved
# to the port side working directory (build/portrom/images/).
# This prepares for repacking the super.img using a unified set of images on the "PORTROM side".
###############################################################################
# Move those to portrom folder. We need to pack those imgs into final port rom
for image in vendor odm my_company my_preload system_dlkm vendor_dlkm my_engineering;do
    if [ -f "build/baserom/images/${image}.img" ];then
        mv -f "build/baserom/images/${image}.img" "build/portrom/images/${image}.img"

        # Extracting vendor at first, we need to determine which super parts to pack from Baserom fstab.
        extract_partition "build/portrom/images/${image}.img" build/portrom/images/

    fi
done

if [ ! -d "build/portrom/images/system_dlkm" ];then
        super_list="system system_ext vendor product my_product odm my_engineering my_stock my_heytap my_carrier my_region my_bigball my_manifest my_company my_preload"
fi
# Extract the partitions list that need to pack into the super.img
#super_list=$(sed '/^#/d;/^\//d;/overlay/d;/^$/d;/\^loop/d' build/portrom/images/vendor/etc/fstab.qcom \
#                | awk '{ print $1}' | sort | uniq)

# Expand images (unpack each partition's `.img` into directories)
green "Starting logical partition expansion" "Starting extract portrom partition from img"
for part in ${super_list};do
    # If in skip_list1 / skip_list2, skip extraction (assuming patched image is reused)
#    if [[ " ${skip_list1[@]} " =~ " ${part} " ]] || [[ " ${skip_list2[@]} " =~ " ${part} " ]]; then
 #       yellow "Skipping partition [${part}] (reusing patched version)" "Skip [${part}], already reused from patched image"
   #      continue
   # fi
    # Skip already extracted parts from BASEROM
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

# Android Version
base_android_version=$(< build/baserom/images/system/system/build.prop grep "ro.build.version.release" |awk 'NR==1' |cut -d '=' -f 2)
port_android_version=$(< build/portrom/images/system/system/build.prop grep "ro.build.version.release" |awk 'NR==1' |cut -d '=' -f 2)
green "Android: Base [Android ${base_android_version}] / Source [Android ${port_android_version}]" "Android Version: BASEROM:[Android ${base_android_version}], PORTROM [Android ${port_android_version}]"

# SDK Version
base_android_sdk=$(< build/baserom/images/system/system/build.prop grep "ro.system.build.version.sdk" |awk 'NR==1' |cut -d '=' -f 2)
port_android_sdk=$(< build/portrom/images/system/system/build.prop grep "ro.system.build.version.sdk" |awk 'NR==1' |cut -d '=' -f 2)
green "SDK: Base [SDK ${base_android_sdk}] / Source [SDK ${port_android_sdk}]" "SDK Verson: BASEROM: [SDK ${base_android_sdk}], PORTROM: [SDK ${port_android_sdk}]"

# ROM Version
base_rom_version=$(<  build/baserom/images/my_manifest/build.prop grep "ro.build.display.ota" | awk 'NR==1' | cut -d '=' -f 2 | cut -d "_" -f 2-)
port_rom_version=$(<  build/portrom/images/my_manifest/build.prop grep "ro.build.display.ota" | awk 'NR==1' | cut -d '=' -f 2 | cut -d "_" -f 2-)
green "ROM: Base [${base_rom_version}] / Source [${port_rom_version}]" "ROM Version: BASEROM: [${base_rom_version}], PORTROM: [${port_rom_version}] "

# ColorOS (and terminal identification) info retrieval

base_device_code=$(< build/baserom/images/my_manifest/build.prop grep "ro.oplus.version.my_manifest" | awk 'NR==1' | cut -d '=' -f 2 | cut -d "_" -f 1)
port_device_code=$(< build/portrom/images/my_manifest/build.prop grep "ro.oplus.version.my_manifest" | awk 'NR==1' | cut -d '=' -f 2 | cut -d "_" -f 1)

green "Device Code: Base [${base_device_code}] / Source [${port_device_code}]" "Device Code: BASEROM: [${base_device_code}], PORTROM: [${port_device_code}]"
base_product_device=$(< build/baserom/images/my_manifest/build.prop grep "ro.product.device" |awk 'NR==1' |cut -d '=' -f 2)
port_product_device=$(< build/portrom/images/my_manifest/build.prop grep "ro.product.device" |awk 'NR==1' |cut -d '=' -f 2)
green "product.device: Base [${base_product_device}] / Source [${port_product_device}]" "Product Device: BASEROM: [${base_product_device}], PORTROM: [${port_product_device}]"

base_product_name=$(< build/baserom/images/my_manifest/build.prop grep "ro.product.name" |awk 'NR==1' |cut -d '=' -f 2)
port_product_name=$(< build/portrom/images/my_manifest/build.prop grep "ro.product.name" |awk 'NR==1' |cut -d '=' -f 2)
green "product.name: Base [${base_product_name}] / Source [${port_product_name}]" "Product Name: BASEROM: [${base_product_name}], PORTROM: [${port_product_name}]"

base_product_model=$(< build/baserom/images/my_manifest/build.prop grep "ro.product.model" |awk 'NR==1' |cut -d '=' -f 2)
port_product_model=$(< build/portrom/images/my_manifest/build.prop grep "ro.product.model" |awk 'NR==1' |cut -d '=' -f 2)
green "product.model: Base [${base_product_model}] / Source [${port_product_model}]" "Product Model: BASEROM: [${base_product_model}], PORTROM: [${port_product_model}]"
if grep -q "ro.vendor.oplus.market.name" build/baserom/images/my_manifest/build.prop;then
    base_market_name=$(< build/baserom/images/my_manifest/build.prop grep "ro.vendor.oplus.market.name" |awk 'NR==1' |cut -d '=' -f 2)
else
    base_market_name=$(< build/portrom/images/odm/build.prop grep "ro.vendor.oplus.market.name" |awk 'NR==1' |cut -d '=' -f 2)
fi

port_market_name=$(grep -r --include="*.prop"  --exclude-dir="odm" "ro.vendor.oplus.market.name" build/portrom/images/ | head -n 1 | awk "NR==1" | cut -d "=" -f2)

green "Market Name: Base [${base_market_name}] / Source [${port_market_name}]" "Market Name: BASEROM: [${base_market_name}], PORTROM: [${port_market_name}]"

base_my_product_type=$(< build/baserom/images/my_product/build.prop grep "ro.oplus.image.my_product.type" |awk 'NR==1' |cut -d '=' -f 2)
port_my_product_type=$(< build/portrom/images/my_product/build.prop grep "ro.oplus.image.my_product.type" |awk 'NR==1' |cut -d '=' -f 2)

green "my_product Type: Base [${base_my_product_type}] / Source [${port_my_product_type}]" "My_Product Type: BASEROM: [${base_my_product_type}], PORTROM: [${port_my_product_type}]"

target_display_id=$(< build/portrom/images/my_manifest/build.prop grep "ro.build.display.id=" |awk 'NR==1' |cut -d '=' -f 2 | sed "s/$port_device_code/$base_device_code/g")

target_display_id_show=$(< build/portrom/images/my_manifest/build.prop grep "ro.build.display.id.show" |awk 'NR==1' |cut -d '=' -f 2 | sed "s/$port_device_code/$base_device_code/g") 

base_vendor_brand=$(< build/baserom/images/my_manifest/build.prop grep "ro.product.vendor.brand" |awk 'NR==1' |cut -d '=' -f 2)
port_vendor_brand=$(< build/portrom/images/my_manifest/build.prop grep "ro.product.vendor.brand" |awk 'NR==1' |cut -d '=' -f 2)

base_product_first_api_level=$(< build/baserom/images/my_manifest/build.prop grep "ro.product.first_api_level" |awk 'NR==1' |cut -d '=' -f 2)
port_product_first_api_level=$(< build/portrom/images/my_manifest/build.prop grep "ro.product.first_api_level" |awk 'NR==1' |cut -d '=' -f 2)

base_device_family=$(< build/baserom/images/my_product/build.prop grep "ro.build.device_family" |awk 'NR==1' |cut -d '=' -f 2)
target_device_family=$(< build/portrom/images/my_product/build.prop grep "ro.build.device_family" |awk 'NR==1' |cut -d '=' -f 2)

# Security Patch Date
portrom_version_security_patch=$(< build/portrom/images/my_manifest/build.prop grep "ro.build.version.security_patch" |awk 'NR==1' |cut -d '=' -f 2 )
port_oplusrom_version=$(< build/portrom/images/my_product/build.prop grep "ro.build.version.oplusrom.confidential" |awk 'NR==1' |cut -d '=' -f 2 )

#regionmark=$(< build/portrom/images/my_bigball/etc/region/build.prop grep "ro.vendor.oplus.regionmark" |awk 'NR==1' |cut -d '=' -f 2)
regionmark=$(find build/portrom/images/ -name build.prop -exec grep -m1 "ro.vendor.oplus.regionmark=" {} \; -quit | cut -d '=' -f2)

base_regionmark=$(find build/baserom/images/ -name build.prop -exec grep -m1 "ro.vendor.oplus.regionmark=" {} \; -quit | cut -d '=' -f2)
if [ -z "$base_regionmark" ]; then
  base_regionmark=$(find build/baserom/images/ -name build.prop -exec grep -m1 "ro.oplus.image.my_region.type=" {} \; -quit | cut -d '=' -f2 | cut -d '_' -f1)
fi

vendor_cpu_abilist32=$(< build/portrom/images/vendor/build.prop grep "ro.vendor.product.cpu.abilist32" |awk 'NR==1' |cut -d '=' -f 2 )

base_area=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.area" build/baserom/images/ | head -n1 | cut -d "=" -f2 | tr -d '\r')
base_brand=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.brand" build/baserom/images/ | head -n1 | cut -d "=" -f2 | tr -d '\r')

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

port_area=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.area" build/portrom/images/ | head -n1 | cut -d "=" -f2 | tr -d '\r')
port_brand=$(grep -r --include="*.prop" --exclude-dir="odm" "ro.oplus.image.system_ext.brand" build/portrom/images/ | head -n1 | cut -d "=" -f2 | tr -d '\r')

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


if grep -q "ro.build.ab_update=true" build/portrom/images/vendor/build.prop;  then
    is_ab_device=true
else
    is_ab_device=false

fi

if [[ ! -f build/portrom/images/system/system/bin/app_process32 && -n "$vendor_cpu_abilist32" ]]; then
    blue "64bit only protrom detected. convert vendor to 64bit-only  "
    sed -i "s/ro.vendor.product.cpu.abilist=.*/ro.vendor.product.cpu.abilist=arm64-v8a/g" build/portrom/images/vendor/build.prop
    sed -i "s/ro.vendor.product.cpu.abilist32=.*/ro.vendor.product.cpu.abilist32=/g" build/portrom/images/vendor/build.prop
    sed -i "s/ro.zygote=.*/ro.zygote=zygote64/g" build/portrom/images/vendor/default.prop
    #cp -rfv devices/32-libs/* build/portrom/images/
fi

if [[ -f "devices/${base_product_device}/config" ]];then
   source "devices/${base_product_device}/config"
fi
#rm -rf build/portrom/images/my_manifest
#cp -rf build/baserom/images/my_manifest build/portrom/images/
#cp -rf build/baserom/images/config/my_manifest_* build/portrom/images/config/
sed -i "s/ro.build.display.id=.*/ro.build.display.id=${target_display_id}/g" build/portrom/images/my_manifest/build.prop
sed -i "s/ro.product.first_api_level=.*/ro.product.first_api_level=${base_product_first_api_level}/g" build/portrom/images/my_manifest/build.prop


if  ! grep -q  "ro.build.display.id.show" build/portrom/images/my_manifest/build.prop ;then
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
            # Special case: brand is forcibly written as OPPO
            sed -i "s|^$key=.*|$key=OPPO|" "$PORT_PROP" 
        elif grep -q "^$key=" "$PORT_PROP"; then
            sed -i "s|^$key=.*|$key=$value|" "$PORT_PROP"
        fi
    done
done
# OOS 16 mixed port
if [[ -n "$vendor_cpu_abilist32" ]] ;then
    sed -i "/ro.zygote=zygote64/d" build/portrom/images/my_manifest/build.prop
fi
# `default.prop` may not exist on some devices
for prop_file in $(find build/portrom/images/vendor/ -name "*.prop"); do
    vndk_version=$(< "$prop_file" grep "ro.vndk.version" | awk "NR==1" | cut -d '=' -f 2)
    if [ -n "$vndk_version" ]; then
        yellow "ro.vndk.version is $vndk_version" "ro.vndk.version found in $prop_file: $vndk_version"
        break  
    fi
done
base_vndk=$(find build/baserom/images/system_ext/apex -type f -name "com.android.vndk.v${vndk_version}.apex")
port_vndk=$(find build/portrom/images/system_ext/apex -type f -name "com.android.vndk.v${vndk_version}.apex")

if [ ! -f "${port_vndk}" ]; then
    yellow "apex not found, copying from Base ROM" "target apex is missing, copying from baserom"
    cp -rf "${base_vndk}" "build/portrom/images/system_ext/apex/"
fi
find build/portrom/images -name "build.prop" -exec sed -i "s/ro.build.version.security_patch=.*/ro.build.version.security_patch=${portrom_version_security_patch}/g" {} \;


###############################################################################
# Patches for services.jar / framework.jar / oplus-services.jar
#
# Addresses common device-specific issues (signatures, permissions, Face Unlock, etc.) 
# through smali patches or replacements.
# Reuses existing output in `build/${app_patch_folder}/patched/` to speed up processing.
###############################################################################
old_face_unlock_app=$(find build/baserom/images/my_product -name "OPFaceUnlock.apk")
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
        echo "smali is $smali"
        echo "target_file is $target_file"
        
        if [[ -f "$target_file" ]]; then
            for single_method in $method; do
                python3 bin/patchmethod.py "$target_file" "$single_method" && echo "${target_file} patched successfully"
            done
        fi
    done

    target_method='getMinimumSignatureSchemeVersionForTargetSdk' 
    old_smali_dir=""
    declare -a smali_dirs

    while read -r smali_file; do
        smali_dir=$(echo "$smali_file" | cut -d "/" -f 3)

        if [[ $smali_dir != $old_smali_dir ]]; then
            smali_dirs+=("$smali_dir")
        fi

        method_line=$(grep -n "$target_method" "$smali_file" | cut -d ':' -f 1)
        register_number=$(tail -n +"$method_line" "$smali_file" | grep -m 1 "move-result" | tr -dc '0-9')
        move_result_end_line=$(awk -v ML=$method_line 'NR>=ML && /move-result /{print NR; exit}' "$smali_file")
        orginal_line_number=$method_line
        replace_with_command="const/4 v${register_number}, 0x0"
        { sed -i "${orginal_line_number},${move_result_end_line}d" "$smali_file" && sed -i "${orginal_line_number}i\\${replace_with_command}" "$smali_file"; } && blue "${smali_file}  Patch successful" "${smali_file} patched"
        old_smali_dir=$smali_dir
    done < <(find tmp/services/smali/*/com/android/server/pm/ tmp/services/smali/*/com/android/server/pm/pkg/parsing/ -maxdepth 1 -type f -name "*.smali" -exec grep -H "$target_method" {} \; | cut -d ':' -f 1)

    ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS='ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS' 

    find tmp/services/ -type f -name "ReconcilePackageUtils.smali" | while read smali_file; do
        match_line=$(grep -n "sput-boolean .*${ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS}" "$smali_file" | head -n 1)

        if [[ -n "$match_line" ]]; then
            line_number=$(echo "$match_line" | cut -d ':' -f 1)
            reg=$(echo "$match_line" | sed -n 's/.*sput-boolean \([^,]*\),.*/\1/p')

            echo "Found in $smali_file at line $line_number using register $reg"

            # Insert `const/4 vX, 0x1` immediately before this line
            sed -i "${line_number}i\    const/4 $reg, 0x1" "$smali_file"
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

# ==================================================
# OnePlus 8/8Pro Perfoamnce Addons
# Snapdragon 865 (SM8250)
# ==================================================

if [[ "${portIsOOS}" == true ]] && \
   [[ "${base_device_family}" == "OPSM8250" ]] && \
   ([[ "${base_product_device}" == "OnePlus8Pro" ]] || [[ "${base_product_device}" == "OnePlus8" ]]); then

    RED='\033[0;31m'
    NC='\033[0m'

    echo -e "${RED}Implementing Smoothness Addons (SM8250)...${NC}"

    SYSTEM_PATH="build/portrom/images/system/system"
    VENDOR_PATH="build/portrom/images/vendor"

    [ -f "$SYSTEM_PATH/build.prop" ] || exit 0
    [ -f "$VENDOR_PATH/default.prop" ] || exit 0

    # ==================================================
    # UI RENDERING IMPROVEMENTS
    # ==================================================

    grep -q "debug.sf.latch_unsignaled" $VENDOR_PATH/default.prop || \
    echo "debug.sf.latch_unsignaled=1" >> $VENDOR_PATH/default.prop

    grep -q "ro.surface_flinger.max_frame_buffer_acquired_buffers" $VENDOR_PATH/default.prop || \
    echo "ro.surface_flinger.max_frame_buffer_acquired_buffers=3" >> $VENDOR_PATH/default.prop

    grep -q "debug.hwui.renderer" $VENDOR_PATH/default.prop || \
    echo "debug.hwui.renderer=skiagl" >> $VENDOR_PATH/default.prop

    grep -q "debug.egl.hw" $VENDOR_PATH/default.prop || \
    echo "debug.egl.hw=1" >> $VENDOR_PATH/default.prop

    # ==================================================
    # ART RUNTIME BALANCE
    # ==================================================

    grep -q "dalvik.vm.usejit" $SYSTEM_PATH/build.prop || \
    echo "dalvik.vm.usejit=true" >> $SYSTEM_PATH/build.prop

    grep -q "dalvik.vm.heaptargetutilization" $SYSTEM_PATH/build.prop || \
    echo "dalvik.vm.heaptargetutilization=0.75" >> $SYSTEM_PATH/build.prop

    # ==================================================
    # SCHEDULER RAMP POLISH (SAFE)
    # ==================================================

    rm -f $VENDOR_PATH/etc/init/op8_sched.rc
    rm -f $VENDOR_PATH/etc/init/op8_boost.rc

cat > $VENDOR_PATH/etc/init/op8_sched.rc << 'EOF'
on boot
    write /proc/sys/kernel/sched_migration_cost_ns 3500000
    write /proc/sys/kernel/sched_upmigrate 85
    write /proc/sys/kernel/sched_downmigrate 75
EOF

    # ==================================================
    # VERY LIGHT THERMAL RELAX (865 HANDLES THIS WELL)
    # ==================================================

    if [ -f "$VENDOR_PATH/etc/thermal-engine.conf" ]; then
        sed -i '0,/trip_point=46000/s/trip_point=46000/trip_point=47500/' $VENDOR_PATH/etc/thermal-engine.conf
    fi

    echo -e "${RED}Implemented Smoothness Addons (SM8250) ✓${NC}"

fi

# ==================================================
# OnePlus 9/9 Pro Perforamnce booster
# ==================================================

if [[ "${portIsOOS}" == true ]] && \
   [[ "${base_device_family}" == "OPSM8350" ]] && \
   ([[ "${base_product_device}" == "OnePlus9Pro" ]] || [[ "${base_product_device}" == "OnePlus9" ]]); then

    RED='\033[0;31m'
    NC='\033[0m'

    echo -e "${RED}Implementing Smoothness Addons...${NC}"

    SYSTEM_PATH="build/portrom/images/system/system"
    VENDOR_PATH="build/portrom/images/vendor"

    [ -f "$SYSTEM_PATH/build.prop" ] || exit 0
    [ -f "$VENDOR_PATH/default.prop" ] || exit 0

    # ==================================================
    # UI RENDERING IMPROVEMENTS (NO POWER INTERFERENCE)
    # ==================================================

    grep -q "debug.sf.latch_unsignaled" $VENDOR_PATH/default.prop || \
    echo "debug.sf.latch_unsignaled=1" >> $VENDOR_PATH/default.prop

    grep -q "ro.surface_flinger.max_frame_buffer_acquired_buffers" $VENDOR_PATH/default.prop || \
    echo "ro.surface_flinger.max_frame_buffer_acquired_buffers=3" >> $VENDOR_PATH/default.prop

    grep -q "debug.hwui.renderer" $VENDOR_PATH/default.prop || \
    echo "debug.hwui.renderer=skiagl" >> $VENDOR_PATH/default.prop

    grep -q "debug.egl.hw" $VENDOR_PATH/default.prop || \
    echo "debug.egl.hw=1" >> $VENDOR_PATH/default.prop

    # ==================================================
    # ART RUNTIME BALANCE
    # ==================================================

    grep -q "dalvik.vm.usejit" $SYSTEM_PATH/build.prop || \
    echo "dalvik.vm.usejit=true" >> $SYSTEM_PATH/build.prop

    grep -q "dalvik.vm.heaptargetutilization" $SYSTEM_PATH/build.prop || \
    echo "dalvik.vm.heaptargetutilization=0.75" >> $SYSTEM_PATH/build.prop

    # ==================================================
    # SCHEDULER RAMP TWEAK (SAFE)
    # DOES NOT OVERRIDE POWERHAL
    # ==================================================

    rm -f $VENDOR_PATH/etc/init/op9_sched.rc
    rm -f $VENDOR_PATH/etc/init/op9_boost.rc
    rm -f $VENDOR_PATH/etc/init/op9_final_sched.rc

cat > $VENDOR_PATH/etc/init/op9_sched.rc << 'EOF'
on boot
    write /proc/sys/kernel/sched_migration_cost_ns 4000000
    write /proc/sys/kernel/sched_upmigrate 90
    write /proc/sys/kernel/sched_downmigrate 80
EOF

    # ==================================================
    # VERY LIGHT THERMAL RELAX (OPTIONAL BUT SAFE)
    # ==================================================

    if [ -f "$VENDOR_PATH/etc/thermal-engine.conf" ]; then
        sed -i '0,/trip_point=46000/s/trip_point=46000/trip_point=47000/' $VENDOR_PATH/etc/thermal-engine.conf
    fi

    echo -e "${RED}Implemented Smoothness Addons ✓${NC}"

fi

# Kaorios Toolbox
if [[ "${portIsOOS}" == true || "${portIsColorOSGlobal}" == true ]]; then
    blue "Implement Kaorios Toolbox"
    git clone https://github.com/Wuang26/Kaorios-Toolbox.git tmp/kaorios
    wget -O tmp/KaoriosToolbox.apk https://github.com/Wuang26/Kaorios-Toolbox/releases/download/V1.0.9/KaoriosToolbox-V1.0.9.apk
    wget -O tmp/privapp_whitelist_com.kousei.kaorios.xml https://github.com/Wuang26/Kaorios-Toolbox/releases/download/V1.0.9/com.kousei.kaorios.xml
    cp -rf build/portrom/images/system/system/framework/framework.jar tmp/kaorios/Toolbox-patcher/framework.jar
    pushd tmp/kaorios/Toolbox-patcher/
    chmod +x scripts/patcher.sh
    ./scripts/patcher.sh framework.jar
    popd
    cp -rf tmp/kaorios/Toolbox-patcher/framework_patched.jar build/portrom/images/system/system/framework/framework.jar
    mkdir build/portrom/images/system_ext/priv-app/KaoriosToolbox
    cp -rf tmp/KaoriosToolbox.apk build/portrom/images/system_ext/priv-app/KaoriosToolbox/
    cp -rf tmp/privapp_whitelist_com.kousei.kaorios.xml build/portrom/images/system_ext/etc/permissions/
    chmod 755 build/portrom/images/system_ext/priv-app/KaoriosToolbox
    chmod 644 build/portrom/images/system_ext/etc/permissions/privapp_whitelist_com.kousei.kaorios.xml
    chmod 644 build/portrom/images/system_ext/priv-app/KaoriosToolbox/KaoriosToolbox.apk
    echo "# Kaorios Toolbox required props" >> build/portrom/images/system/system/build.prop
    echo "persist.sys.kaorios=kousei" >> build/portrom/images/system/system/build.prop
    echo "ro.control_privapp_permissions=" >> build/portrom/images/system/system/build.prop
fi

targetOplusService=$(find build/portrom/images/ -name "oplus-services.jar")
if [[ -f build/${app_patch_folder}/patched/oplus-services.jar ]];then
    blue "复制已经处理过的oplus-services.jar"
    cp -rfv build/${app_patch_folder}/patched/oplus-services.jar $targetOplusService

elif [[ -f $targetOplusService ]];then
    blue "Removing GSM Restriction"
    cp -rf $targetOplusService tmp/$(basename $targetOplusService).bak
    java -jar bin/apktool/APKEditor.jar d -f -i $targetOplusService -o tmp/OplusService
    targetSmali=$(find tmp -type f -name "OplusBgSceneManager.smali")
    python3 bin/patchmethod.py $targetSmali "-isGmsRestricted"
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/OplusService -o build/${app_patch_folder}/patched/oplus-services.jar
    cp -rfv build/${app_patch_folder}/patched/oplus-services.jar $targetOplusService

fi

if [[ "${base_device_family}" == "OPSM8250" ]] || [[ "${base_device_family}" == "OPSM8350" ]]; then
    blue "ColorOS16/OxygenOS16: Fixing Face Unlock bug" "COS15/OOS15: Fix Face Unlock for SM8250/8350"
    #pushd tmp/services
    #patch -p1 < ${work_dir}/devices/${base_product_device}/0001-face-unlock-fix-for-op8t.patch
    #popd
	if [[ -f devices/common/face_unlock_fix_common.zip ]];then
        rm -rf build/portrom/images/vendor/overlay/*
        unzip -o devices/common/face_unlock_fix_common.zip -d "${work_dir}/build/portrom/images/"

    fi

    if [[ -f "$old_face_unlock_app" ]]; then
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

if [[ ${base_device_family} == "OPSM8350" ]] && [[ -f devices/common/aod_fix_sm8350.zip ]]; then
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
    if [[ -f devices/common/a13_base_fix.zip ]];then
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

if [[  "${port_android_version}" -ge 15 ]]; then
    if [[ "${base_device_family}" == "OPSM8250" ]] && [[ "${base_android_version}" != 13 ]];then
        unzip -o devices/common/ril_fix_sm8250.zip -d "${work_dir}/build/portrom/images/"
        rm -rf build/portrom/images/odm/lib/libmindroid-app.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys-V1-ndk_platform.so
    elif [[ "${base_device_family}" == "OPSM8350" ]];then
        unzip -o devices/common/ril_fix_sm8350.zip -d "${work_dir}/build/portrom/images/"
        rm -rf build/portrom/images/odm/lib/libmindroid-app.so \
            build/portrom/images/odm/lib/libmindroid-framework.so \
            build/portrom/images/odm/lib/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
            build/portrom/images/odm/lib/vendor.oplus.hardware.subsys-V1-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys-V1-ndk_platform.so
    fi

    # OnePlus 9 / 9 Pro (SM8350): Telephony/subsys/commcenter VINTF + libs alignment (used by some A15/A16 ports)
    if [[ ${base_device_family} == "OPSM8350" ]] && \
       ([[ "${base_product_device}" == "OnePlus9Pro" ]] || [[ "${base_product_device}" == "OnePlus9" ]]) && \
       [[ -f devices/common/odm_telephony_subsys_fix_op9pro_sm8350.zip ]]; then
        blue "OP9/9Pro: ODM telephony/subsys patch" "OP9/9Pro: Applying ODM telephony/subsys patch"
        unzip -o devices/common/odm_telephony_subsys_fix_op9pro_sm8350.zip -d ${work_dir}/build/portrom/images/

        # Make network_manifest_* follow telephony_manifest_* (symlink) to match patched ODM layout
        rm -f build/portrom/images/odm/etc/vintf/network_manifest_dsds.xml \
              build/portrom/images/odm/etc/vintf/network_manifest_ssss.xml
        ln -sf telephony_manifest_dsds.xml build/portrom/images/odm/etc/vintf/network_manifest_dsds.xml
        ln -sf telephony_manifest_ssss.xml build/portrom/images/odm/etc/vintf/network_manifest_ssss.xml

        # Drop older subsys interface libs if present (avoid VINTF mismatch picking wrong version)
        rm -f build/portrom/images/odm/lib/vendor.oplus.hardware.subsys-V1-ndk_platform.so \
              build/portrom/images/odm/lib/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so \
              build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys-V1-ndk_platform.so \
              build/portrom/images/odm/lib64/vendor.oplus.hardware.subsys_radio-V1-ndk_platform.so
    fi

    # OnePlus 9 / 9 Pro (SM8350): camera extension cmd compat (for Camera 6.x ports)
    if [[ ${base_device_family} == "OPSM8350" ]] && \
       ([[ "${base_product_device}" == "OnePlus9Pro" ]] || [[ "${base_product_device}" == "OnePlus9" ]]) && \
       [[ -f devices/common/odm_sendextcamcmd_fix_op9_sm8350.zip ]]; then
        blue "OP9/9Pro: ODM sendextcamcmd patch" "OP9/9Pro: Applying ODM sendextcamcmd patch"
        unzip -o devices/common/odm_sendextcamcmd_fix_op9_sm8350.zip -d ${work_dir}/build/portrom/images/
    fi

    if [[ ${base_android_version} == 14 ]]; then
        charger_v3=$(find build/portrom/images/odm/bin/hw/ -type f -name "vendor.oplus.hardware.charger-V3-service")
        if [[ -f $charger_v3 ]];then
        unzip -o devices/common/charger-v6-update.zip -d ${work_dir}/build/portrom/images/
        rm -rf build/portrom/images/odm/bin/hw/vendor.oplus.hardware.charger-V3-service \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.charger-V3-service.rc \
            build/portrom/images/odm/lib/vendor.oplus.hardware.charger-V3-ndk_platform.so \
            build/portrom/images/odm/lib64/vendor.oplus.hardware.charger-V3-ndk_platform.so
        fi
    elif [[ ${base_android_version} == 13 ]];then
        #Ril Fix
        unzip -o devices/common/ril_fix_a13_to_a15.zip -d ${work_dir}/build/portrom/images/
        #Ril Fix for OxygenOS firmware (IN2013/IN2023)
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
        #Nfc Fix
        unzip -o devices/common/nfc_fix_for_a13.zip -d ${work_dir}/build/portrom/images/
        rm -rf build/portrom/images/odm/bin/hw/vendor.oplus.hardware.nfc@1.0-service \
            build/portrom/images/odm/etc/init/vendor.oplus.hardware.nfc@1.0-service.rc \
            build/portrom/images/odm/etc/vintf/manifest/manifest_oplus_nfc.xml \
            build/portrom/images/odm/lib/vendor.oplus.hardware.nfc@1.0.so
        if [[ -f devices/common/cryptoeng_fix_a13.zip ]];then
        # Fix Privacy related features(App lock、App hide)
            unzip -o devices/common/cryptoeng_fix_a13.zip -d ${work_dir}/build/portrom/images/
        fi
    fi
fi
echo "ro.surface_flinger.game_default_frame_rate_override=120" >>  build/portrom/images/vendor/default.prop
#Unlock AI CAll
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
# patch_smali_with_apktool "HeyTapSpeechAssist.apk" "com/heytap/speechassist/aicall/setting/config/AiCallCommonBean.smali" ".method public final getSupportAiCall()Z/,/.end method" ".method public final getSupportAiCall()Z\n\t.locals 1\n\tconst\/4 v0, 0x1\n\treturn v0\n.end method" "regex"

ota_patched=false
if [[ "$regionmark" == "CN" ]];then
    cp -rf devices/common/OTA_CN.apk build/portrom/images/system_ext/app/OTA/OTA.apk && ota_patched=true

else
    cp -rf devices/common/OTA_IN.apk build/portrom/images/system_ext/app/OTA/OTA.apk && ota_patched=true
fi


if [[ "$ota_patched" == "false" ]];then
    # Remove OTA dm-verity
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
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/OTA -o  "build/${app_patch_folder}/patched/OTA.apk"  $extra_args
         cp -rfv "build/${app_patch_folder}/patched/OTA.apk" "$targetOTA"
    fi
fi


    EXTEDNED_MODELS=("PJF110" "PEEM00" "PEDM00" "LE2120" "LE2121" "LE2123" "KB2000" "KB2001" "KB2005" "KB2003" "LE2110" "LE2111" "LE2112" "LE2113" "IN2010" "IN2011" "IN2012" "IN2013" "IN2020" "IN2021" "IN2022" "IN2023")

    targetAIUnit=$(find build/portrom/images/ -name "AIUnit.apk")
    MODEL=PLG110
    #PKZ110 Reno 14 Pro
    #CPH2723 OnePlus 13s
    #CPH2671 #Oppo Find N5 Global
    #CPH2749 OnePlus 15
    [[ "$regionmark" != CN ]] && MODEL=CPH2745

    if [[ -f "build/${app_patch_folder}/patched/AIUnit.apk" ]]; then
            blue "Copying processed OTA.apk"
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
    # Define array variables
    ($models_str | split(" ")) as $new_models
    |

    # Execute `map` on input JSON array
    map(
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
        |

        if has("minAndroidApi") then .minAndroidApi = 30 else . end
    )
    ' "$unit_config_list" > "${unit_config_list}.bak" && mv "${unit_config_list}.bak" "$unit_config_list"
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/AIUnit -o "build/${app_patch_folder}/patched/AIUnit.apk"  $extra_args
        cp -rfv "build/${app_patch_folder}/patched/AIUnit.apk" "$targetAIUnit"
    fi

if [[ "$port_android_version" == 16 ]] && [[ "$base_android_version" -lt 15 ]] ;then
    # workaround fix AI Eraser
    cp build/portrom/images/odm/lib64/libaiboost.so build/portrom/images/my_product/lib64/libaiboost.so
    # sed -i 's|^/odm/lib64/libaiboost\.so.*$|/odm/lib64/libaiboost\.so u:object_r:same_process_hal_file:s0|' build/portrom/images/config/odm_file_contexts
    # echo "/(vendor|odm)/lib(64)?/libaiboost\.so  u:object_r:same_process_hal_file:s0" >> build/portrom/images/vendor/etc/selinux/vendor_file_contexts
fi

if [[ -f devices/common/xeutoolbox.zip ]] && [[ "$base_android_version" -lt 15 ]] && [[ "${portIsColorOSGlobal}" != true ]];then
    blue "Integrated Xiami EU xeutoolbox"
    # this causes OOS/Cos 16.0.1 boot into bootloader
    #python3 bin/insert_selinux_policy.py build/portrom/images/system_ext/etc/selinux/system_ext_sepolicy.cil --config "${work_dir}/devices/common/xeu_toolbox_policy.json"
    #echo "/system_ext/xbin/xeu_toolbox  u:object_r:xeu_toolbox_exec:s0" >> build/portrom/images/system_ext/etc/selinux/system_ext_file_contexts

    echo "/system_ext/xbin/xeu_toolbox  u:object_r:toolbox_exec:s0" >> build/portrom/images/config/system_ext_file_contexts
    echo "/system_ext/xbin/xeu_toolbox  u:object_r:toolbox_exec:s0" >> build/portrom/images/system_ext/etc/selinux/system_ext_file_contexts
    echo "(allow init toolbox_exec (file ((execute_no_trans))))" >> build/portrom/images/system_ext/etc/selinux/system_ext_sepolicy.cil
    unzip -o devices/common/xeutoolbox.zip -d build/portrom/images/
elif [[ "$base_android_version" -lt 15 ]] && [[ "${portIsColorOS}" != "true" ]];then
    targetGallery=$(find build/portrom/images/ -name "OppoGallery2.apk")
    if [[ -f "build/${app_patch_folder}/patched/OppoGallery2.apk" ]]; then
            blue "Copying processed OppoGallery2"
            cp -rfv "build/${app_patch_folder}/patched/OppoGallery2.apk" "$targetGallery"

    elif [[ -f "$targetGallery" ]];then
        blue "Unlock AI Editor"
        cp -rf "$targetGallery" "tmp/$(basename "$targetGallery").bak"
        java -jar bin/apktool/APKEditor.jar d -f -i "$targetGallery" -o tmp/Gallery $extra_args
        python3 bin/patchmethod_v2.py -d tmp/Gallery -k "const-string.*\"ro.product.first_api_level\"" -hook "     const/16 reg, 0x22"
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/Gallery -o "build/${app_patch_folder}/patched/OppoGallery2.apk" $extra_args
        cp -rfv "build/${app_patch_folder}/patched/OppoGallery2.apk" "$targetGallery"
    fi
fi

if [[ "${base_device_family}" == "OPSM8250" ]] || [[ "${base_device_family}" == "OPSM8350" ]];then
    # Patch Battery Health Maximum capacity
    targetBattery=$(find build/portrom/images/ -name "Battery.apk")
    if [[ -f build/${app_patch_folder}/patched/Battery.apk ]]; then
        blue "Copying processed Battery.apk"
        cp -rfv build/${app_patch_folder}/patched/Battery.apk $targetBattery
     
    elif  [[ -f $targetBattery ]];then
        blue "Patch Battery Health Maximum capacity"
        cp -rf $targetBattery tmp/$(basename $targetBattery).bak
        java -jar bin/apktool/APKEditor.jar d -f -i $targetBattery -o tmp/Battery $extra_args
        python3 bin/patchmethod_v2.py -d tmp/Battery/ -k "getUIsohValue" -m devices/common/patch_battery_soh.txt 
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/Battery -o build/${app_patch_folder}/patched/Battery.apk $extra_args
        cp -rfv build/${app_patch_folder}/patched/Battery.apk $targetBattery 
    fi
fi 

if [[ ${regionmark} != "CN" ]] && [[ ${base_product_model} != "IN20"* ]];then

    # Charging info in Settings
    targetSettings=$(find build/portrom/images/ -name "Settings.apk")

    if [[ -f $targetSettings ]];then
        blue "Charging info in Settings"
        cp -rf $targetSettings tmp/$(basename $targetSettings).bak
        java -jar bin/apktool/APKEditor.jar d -f -i $targetSettings -o tmp/Settings $extra_args
        targetSmali=$(find tmp -type f -name "DeviceChargeInfoController.smali")
        python3 bin/patchmethod_v2.py $targetSmali isPreferenceSupport
        java -jar bin/apktool/APKEditor.jar b -f -i tmp/Settings -o $targetSettings $extra_args
    fi
fi 

targetOplusLauncher=$(find build/portrom/images/ -name "OplusLauncher.apk")

if [[ -f $targetOplusLauncher ]] && [[ $base_product_first_api_level -gt 34 ]];then
	blue "Enabling RAM display"
	cp -rf $targetOplusLauncher tmp/$(basename $targetOplusLauncher).bak
	java -jar bin/apktool/APKEditor.jar d -f -i $targetOplusLauncher -o tmp/OplusLauncher $extra_args
	targetSmali=$(find tmp -type f -path "*/com/oplus/basecommon/util/SystemPropertiesHelper.smali")
 python3 bin/patchmethod_v2.py $targetSmali getFirstApiLevel ".locals 1\n\tconst/16 v0, 0x22\n\treturn v0"
 java -jar bin/apktool/APKEditor.jar b -f -i tmp/OplusLauncher -o $targetOplusLauncher $extra_args
fi

targetSystemUI=$(find build/portrom/images/ -name "SystemUI.apk")
if [[ -f build/${app_patch_folder}/patched/SystemUI.apk ]]; then
        blue "Copying processed SystemUI.apk"
        cp -rfv build/${app_patch_folder}/patched/SystemUI.apk $targetSystemUI
     
elif [[ -f "$targetSystemUI" ]]; then
    
    cp -rf $targetSystemUI tmp/$(basename $targetSystemUI).bak
    java -jar bin/apktool/APKEditor.jar d -f -i $targetSystemUI -o tmp/SystemUI $extra_args
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
        targetSmali=$(find tmp -type f -name "FeatureOption.smali")
        python3 bin/patchmethod_v2.py $targetSmali isSupportMyDevice
    fi
    # CTS Patch: Always force isCtsTest to false to avoid hidden notification icons
    blue "Applying CTS patch (isCtsTest)"
    python3 bin/patchmethod_v2.py -d tmp/SystemUI -n isCtsTest -return false

    # tmp workround
    for style_xml_file in $(find tmp/SystemUI -name "styles.xml");do
        sed -i "s/style\/null/7f1403f6/g" $style_xml_file
    done
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/SystemUI -o build/${app_patch_folder}/patched/SystemUI.apk $extra_args
    cp -rfv build/${app_patch_folder}/patched/SystemUI.apk $targetSystemUI
fi

targetAOD=$(find build/portrom/images/ -name "Aod.apk")

if [[ -f $targetAOD ]] && [[ $base_product_first_api_level -le 35 ]] ;then
	blue "Forcibly enabling AOD Always-on for older models"
	cp -rf $targetAOD tmp/$(basename $targetAOD).bak
	java -jar bin/apktool/APKEditor.jar d -f -i $targetAOD -o tmp/Aod $extra_args
	targetCommonUtilsSmali=$(find tmp -type f -path "*/com/oplus/aod/util/CommonUtils.smali")
    targetSettingsSmali=$(find tmp -type f -path "*/com/oplus/aod/util/SettingsUtils.smali")
    python3 bin/patchmethod_v2.py $targetCommonUtilsSmali isSupportFullAod -return true
    python3 bin/patchmethod_v2.py $targetSettingsSmali getKeyAodAllDaySupportSettings -return true
    java -jar bin/apktool/APKEditor.jar b -f -i tmp/Aod -o $targetAOD $extra_args
fi
yellow "Deleting unnecessary apps" "Debloating..." 
# List of apps to be removed

debloat_apps=("HeartRateDetect" "Browser")
#kept_apps=("Clock" "FileManager" "KeKeThemeSpace" "SogouInput" "Weather" "Calendar")
#kept_apps=("BackupAndRestore" "Calculator2" "Calendar" "Clock" "FileManager" "OppoNote2" "OppoWeather2" "UPTsmService" "Music")
kept_apps=("OppoNote2" "OppoWeather2")
#kept_apps=()

if [[ $super_extended == "true" ]] && [[ $pack_method == "stock" ]] && [[ -f build/baserom/images/reserve.img ]]; then
    rm -rf build/baserom/images/reserve.img
elif [[ $super_extended == "false" ]] && [[ $pack_method == "stock" ]] && [[ -f build/baserom/images/reserve.img ]]; then
    #extract_partition "${work_dir}/build/baserom/images/reserve.img" "${work_dir}/build/baserom/images/"
    #if [[ -f ext/del-app-ksu-module/system/product/app/* ]];then
    ##    rm -rf ext/del-app-ksu-module/system/product/app/*
    #fi
    #ext_moudle_app_folder="ext/del-app-ksu-module/system/product/app"
    for delapp in $(find build/portrom/images/ -maxdepth 3 -path "*/del-app/*" -type d);do
        
        app_name=$(basename "$delapp")

        # Check if the app is in kept_apps, skip if true
        if [[ " ${kept_apps[@]} " =~ " ${app_name} " ]]; then
            echo "Skipping kept app: $app_name"
        continue
        fi
        #mv -fv $delapp ${ext_moudle_app_folder}/
        rm -rfv $delapp 
    done 

    for debloat_app in "${debloat_apps[@]}"; do
    # Find the app directory
    app_dir=$(find build/portrom/images/ -type d -name "*$debloat_app*")
    
    # Check if the directory exists before removing
    if [[ -d "$app_dir" ]]; then
        yellow "Deleting directory: $app_dir" "Removing directory: $app_dir"
        rm -rfv "$app_dir"
    fi
    done

    cp -rfv devices/common/via build/portrom/images/product/app/
elif [[ $super_extended == "false" ]] && [[ $base_product_model == "KB2000" ]] && [[ "$is_ab_device" == true ]];then
    for delapp in $(find build/portrom/images/ -maxdepth 3 -path "*/del-app/*" -type d ); do
        app_name=$(basename ${delapp})
        
        keep=false
        for kept_app in "${kept_apps[@]}"; do
            if [[ $app_name == *"$kept_app"* ]]; then
                keep=true
                break
            fi
        done
        
        if [[ $keep == false ]]; then
            debloat_apps+=("$app_name")
        fi

    done
    for debloat_app in "${debloat_apps[@]}"; do
    # Find the app directory
    app_dir=$(find build/portrom/images/ -type d -name "*$debloat_app*")
    
    # Check if the directory exists before removing
    if [[ -d "$app_dir" ]]; then
        yellow "Deleting directory: $app_dir" "Removing directory: $app_dir"
        rm -rfv "$app_dir"
    fi
    done
elif [[ $super_extended == "false" ]] && [[ $base_product_model == "KB200"* ]] && [[ "$is_ab_device" == true ]];then
    debloat_apps=("Facebook" "YTMusic" "GoogleHome" "GoogleOne" "Videos_del" "Drive_del" "ConsumerIRApp" "YouTube" "Gmail2" "Maps" "Wellbeing" "OPForum" "INOnePlusStore" "YTMusic_del" "ConsumerIRApp" "Meet")
    for debloat_app in "${debloat_apps[@]}"; do
    # Find the app directory
    app_dir=$(find build/portrom/images/ -type d -name "*$debloat_app*")
    
    # Check if the directory exists before removing
    if [[ -d "$app_dir" ]]; then
        yellow "Deleting directory: $app_dir" "Removing directory: $app_dir"
        rm -rfv "$app_dir"
    fi
    done
    
    #rm -rfv build/portrom/images/my_stock/del-app/*
elif [[ $super_extended == "false" ]] && [[ $base_product_model == "LE2101" ]];then
      debloat_apps=("Facebook" "YTMusic" "GoogleHome" "GoogleOne" "Videos_del" "Drive_del" "ConsumerIRApp" "YouTube" "Gmail2" "Maps" "Wellbeing" "OPForum" "INOnePlusStore" "YTMusic_del" "ConsumerIRApp" "Meet")
    for debloat_app in "${debloat_apps[@]}"; do
    # Find the app directory
    app_dir=$(find build/portrom/images/ -type d -name "*$debloat_app*")
    
    # Check if the directory exists before removing
    if [[ -d "$app_dir" ]]; then
        yellow "Deleting directory: $app_dir" "Removing directory: $app_dir"
        rm -rfv "$app_dir"
    fi
    done
  #rm -rfv build/portrom/images/my_stock/del-app/*
fi
rm -rf build/portrom/images/product/etc/auto-install*
rm -rf build/portrom/images/system/verity_key
rm -rf build/portrom/images/vendor/verity_key
rm -rf build/portrom/images/product/verity_key
rm -rf build/portrom/images/system/recovery-from-boot.p
rm -rf build/portrom/images/vendor/recovery-from-boot.p
rm -rf build/portrom/images/product/recovery-from-boot.p

# Fix build.prop

sed -i "/ro.oplus.audio.*/d" build/portrom/images/my_product/build.prop

prepare_base_prop
add_prop_from_port

blue "Modifying build.prop" "Modifying build.prop"


#change the locale to English
export LC_ALL=en_US.UTF-8
buildDate=$(date -u +"%a %b %d %H:%M:%S UTC %Y")
buildUtc=$(date +%s)
for i in $(find build/portrom/images -type f -name "build.prop");do
    blue "Processing: ${i}" "modifying ${i}"
    # sed -i "s/ro.build.date=.*/ro.build.date=${buildDate}/g" ${i}
    # sed -i "s/ro.build.date.utc=.*/ro.build.date.utc=${buildUtc}/g" ${i}
    # sed -i "s/ro.odm.build.date=.*/ro.odm.build.date=${buildDate}/g" ${i}
    # sed -i "s/ro.odm.build.date.utc=.*/ro.odm.build.date.utc=${buildUtc}/g" ${i}
    # sed -i "s/ro.vendor.build.date=.*/ro.vendor.build.date=${buildDate}/g" ${i}
    # sed -i "s/ro.vendor.build.date.utc=.*/ro.vendor.build.date.utc=${buildUtc}/g" ${i}
    # sed -i "s/ro.system.build.date=.*/ro.system.build.date=${buildDate}/g" ${i}
    # sed -i "s/ro.system.build.date.utc=.*/ro.system.build.date.utc=${buildUtc}/g" ${i}
    # sed -i "s/ro.product.build.date=.*/ro.product.build.date=${buildDate}/g" ${i}
    # sed -i "s/ro.product.build.date.utc=.*/ro.product.build.date.utc=${buildUtc}/g" ${i}
    # sed -i "s/ro.system_ext.build.date=.*/ro.system_ext.build.date=${buildDate}/g" ${i}
    # sed -i "s/ro.system_ext.build.date.utc=.*/ro.system_ext.build.date.utc=${buildUtc}/g" ${i}
    sed -i "s/persist.sys.timezone=.*/persist.sys.timezone=Asia\/Shanghai/g" ${i}
    # Global replacement of device codes (Source -> Base Device)
    sed -i "s/$port_device_code/$base_device_code/g" ${i}
    sed -i "s/$port_product_model/$base_product_model/g" ${i}
    sed -i "s/$port_product_name/$base_product_name/g" ${i}
    sed -i "s/$port_my_product_type/$base_my_product_type/g" ${i}
    sed -i "s/$port_product_device/$base_product_device/g" ${i}
    # Overwrite build user info
    sed -i "s/ro.build.user=.*/ro.build.user=${build_user}/g" ${i}
    sed -i "s/ro.build.display.id=.*/ro.build.display.id=${target_display_id}/g" ${i}
    sed -i "s/ro.oplus.radio.global_regionlock.enabled=.*/ro.oplus.radio.global_regionlock.enabled=false/g" ${i}
    sed -i "s/persist.sys.radio.global_regionlock.allcheck=.*/persist.sys.radio.global_regionlock.allcheck=false/g" ${i}
    sed -i "s/ro.oplus.radio.checkservice=.*/ro.oplus.radio.checkservice=false/g" ${i}
    if [[ $portIsColorOSGlobal == true ]];then
        sed -i 's/=OnePlus[[:space:]]*$/=OPPO/' ${i}
    fi

done

# Camera (and some system apps) read these props; ensure they exist even if absent in the source build.prop.
add_prop_v2 "ro.vendor.oplus.market.name" "${base_market_name}"
add_prop_v2 "ro.vendor.oplus.market.enname" "${base_market_name}"

remove_prop_v2 "persist.oplus.software.audio.right_volume_key"
remove_prop_v2 "persist.oplus.software.alertslider.location"


sed -i -e '$a\'$'\n''persist.adb.notify=0' build/portrom/images/system/system/build.prop
sed -i -e '$a\'$'\n''persist.sys.usb.config=mtp,adb' build/portrom/images/system/system/build.prop
sed -i -e '$a\'$'\n''persist.sys.disable_rescue=true' build/portrom/images/system/system/build.prop

base_rom_density=$(grep "ro.sf.lcd_density" --include="*.prop" -r build/baserom/images/my_product | head -n 1 | cut -d "=" -f2)
[ -z ${base_rom_density} ] && base_rom_density=480

# if grep -q "ro.sf.lcd_density" build/portrom/images/my_product/build.prop ;then
#         sed -i "s/ro.sf.lcd_density=.*/ro.sf.lcd_density=${base_rom_density}/g" build/portrom/images/my_product/build.prop
# else
#         echo "ro.sf.lcd_density=${base_rom_density}" >> build/portrom/images/my_product/build.prop
# fi

# brand require lowercase 
if [[ ${base_vendor_brand,,} != ${port_vendor_brand,,} ]] && [[ $portIsColorOSGlobal == false ]];then
    # Global ColorOS needs to be Oppo brand or stuck on 
    sed -i "s/ro.oplus.image.system_ext.brand=.*/ro.oplus.image.system_ext.brand=${base_vendor_brand,,}/g" build/portrom/images/system_ext/etc/build.prop
fi

# fix bootloop
if [[ -f build/baserom/images/my_product/etc/extension/sys_game_manager_config.json ]];then
    cp -rf build/baserom/images/my_product/etc/extension/sys_game_manager_config.json build/portrom/images/my_product/etc/extension/
else
    rm -rf build/portrom/images/my_product/etc/extension/sys_game_manager_config.json
fi

if [[ ! -f build/baserom/images/my_product/etc/extension/sys_graphic_enhancement_config.json ]];then
    rm -rf build/portrom/images/my_product/etc/extension/sys_graphic_enhancement_config.json
else
    cp -rf build/baserom/images/my_product/etc/extension/sys_graphic_enhancement_config.json build/portrom/images/my_product/etc/extension/
fi

if [[ $(cat build/baserom/images/my_product/build.prop | grep "ro.oplus.audio.effect.type" | cut -d "=" -f 2) == "dolby" ]] ;then
   blue "Fixing Dolby Acoustics + App Specific volume adjustment (SM8250/SM8350)" "Fix Dolby + App Specific volume adjustment for SM8250/SM8350"
    #cp $source_dolby_lib build/portrom/images/system_ext/lib64/
    cp build/baserom/images/my_product/etc/permissions/oplus.product.features_dolby_stereo.xml build/portrom/images/my_product/etc/permissions/oplus.product.features_dolby_stereo.xml
    unzip -o devices/common/dolby_fix.zip -d build/portrom/images/ 
fi

if [[ -f build/portrom/images/vendor/lib64/vendor.oplus.hardware.radio-V2-ndk_platform.so ]] && \
   [[ ${base_device_family} == "OPSM8350" ]] && \
   [[ -f devices/common/ril_fix_A16_SM8350.zip ]]; then
    blue "Fixing RIL..."
    unzip -o devices/common/ril_fix_A16_SM8350.zip -d ${work_dir}/build/portrom/images/vendor/
    rm -f build/portrom/images/vendor/lib/vendor.oplus.hardware.radio-V1-ndk_platform.so \
          build/portrom/images/vendor/lib64/vendor.oplus.hardware.radio-V1-ndk_platform.so
fi

# Fix wechat/whatsapp volume isue
cp -rf build/baserom/images/my_product/etc/audio*.xml build/portrom/images/my_product/etc/
cp -rf build/baserom/images/my_product/etc/default_volume_tables.xml build/portrom/images/my_product/etc/
while IFS= read -r audio_cfg; do
    relative_path=${audio_cfg#"build/baserom/images/"}
    dest_path="build/portrom/images/${relative_path}"
    mkdir -p "$(dirname "$dest_path")"
    cp -rfv "$audio_cfg" "$dest_path"
done < <(find build/baserom/images/vendor build/baserom/images/odm -type f \( -name "audio_policy*.xml" -o -name "audio_platform*.xml" -o -name "mixer_paths*.xml" -o -name "audio_effects*.xml" \))

if [[ -d build/baserom/images/my_product/etc/breenospeech2 ]];then
    cp -rf build/baserom/images/my_product/etc/breenospeech2/* build/portrom/images/my_product/etc/breenospeech2/
fi
rm -rf build/portrom/images/my_product/etc/fusionlight_profile/*
cp -rf build/baserom/images/my_product/etc/fusionlight_profile/* build/portrom/images/my_product/etc/fusionlight_profile/
# Fix game audio issue on 15.0.2 (13t)


sed -i "/persist.vendor.display.pxlw.iris_feature=.*/d" build/portrom/images/my_product/etc/bruce/build.prop

if grep -q "ro.build.version.oplusrom.display" build/portrom/images/my_manifest/build.prop;then
    sed -i '/^ro.build.version.oplusrom.display=/ s/$/ /' build/portrom/images/my_manifest/build.prop
else
    sed -i '/^ro.build.version.oplusrom.display=/ s/$/ /' build/portrom/images/my_product/etc/bruce/build.prop
fi

propfile="build/portrom/images/my_product/etc/bruce/build.prop"

if [[ $portIsColorOSGlobal == true ]]; then
    MODEL_MAGIC="CPH2659,BRAND:OPPO"
    MODEL_AIUNIT="CPH2659,BRAND:OPPO"

elif [[ $portIsOOS == true ]]; then
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
remove_prop_v2 "ro.oplus.resolution"
remove_prop_v2 "ro.oplus.density.qhd_default"
remove_prop_v2 "ro.oplus.density.fhd_default"
remove_prop_v2 "ro.oplus.key.actionbutton"
remove_prop_v2 "ro.oplus.audio.support.foldingmode"
remove_prop_v2 "ro.config.fold_disp"
remove_prop_v2 "persist.oplus.display.fold.support"
remove_prop_v2 "ro.oplus.haptic"

remove_prop_v2 "ro.vendor.mtk"
remove_prop_v2 "ro.oplus.mtk"
# OnePlus 8T: Fix OpSynergy crash 
remove_prop_v2 "persist.sys.oplus.wlan.atpc.qcom_use_iw"

remove_prop_v2 "ro.product.oplus.cpuinfo"
remove_prop_v2
if [[ $base_android_version -lt 15 ]] && [[ $port_android_version -gt 15 ]];then
    remove_prop_v2 "ro.lcd.display.screen" 
    remove_prop_v2 "ro.display.brightness"
    remove_prop_v2 "ro.oplus.lcd.display"
    #remove_prop_v2 "ro.display.brightness.curve.name" force
fi

add_prop_v2 "ro.oplus.game.camera.support_1_0" "true"
add_prop_v2 "ro.oplus.audio.quiet_start" "true"
if [[ $portIsOOS == "true" ]];then
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

cp -rf build/baserom/images/my_product/app/com.oplus.vulkanLayer build/portrom/images/my_product/app/
cp -rf build/baserom/images/my_product/app/com.oplus.gpudrivers.* build/portrom/images/my_product/app/

mkdir -p tmp/etc/permissions tmp/etc/extension
cp -fv build/portrom/images/my_product/etc/permissions/*.xml tmp/etc/permissions/
cp -fv build/portrom/images/my_product/etc/extension/*.xml tmp/etc/extension/
cp -rf build/baserom/images/my_product/etc/permissions/*.xml build/portrom/images/my_product/etc/permissions/
find tmp/etc/permissions/ -type f \( -name "multimedia*.xml" -o -name "*permissions*.xml" -o -name "*google*.xml"  -o -name "*configs*.xml" -o -name "*gsm*.xml" -o -name "feature_activity_preload.xml" -o -name "*gemini*.xml" -o -name "*gms*.xml" \) -exec cp -fv {} build/portrom/images/my_product/etc/permissions/ \;


if [[ $regionmark != "CN" ]];then
   for i in com.android.contacts com.android.incallui com.android.mms com.oplus.blacklistapp com.oplus.phonenoareainquire com.ted.number; do 
        sed -i "/$i/d" build/portrom/images/my_stock/etc/config/app_v2.xml
   done
fi

cp -rf build/baserom/images/my_product/etc/permissions/*.xml build/portrom/images/my_product/etc/permissions/
cp -rf build/baserom/images/my_product/etc/extension/*.xml build/portrom/images/my_product/etc/extension/
cp -rf  build/baserom/images/my_product/etc/refresh_rate_config.xml build/portrom/images/my_product/etc/refresh_rate_config.xml

#cp -rf build/baserom/images/my_product/etc/extension/*.xml build/portrom/images/my_product/etc/extension/

cp -rf  build/baserom/images/my_product/etc/sys_resolution_switch_config.xml build/portrom/images/my_product/etc/sys_resolution_switch_config.xml

cp -rf build/baserom/images/my_product/etc/permissions/com.oplus.sensor_config.xml build/portrom/images/my_product/etc/permissions/
# add_feature "com.android.systemui.support_media_show" build/portrom/images/my_product/etc/extension/com.oplus.app-features.xml

###############################################################################
# Adding/Deleting Feature Flags (XML)
#
# `add_feature_v2` / `remove_feature` mainly edits `com.oplus.*-features*.xml` 
# to enable or disable functional flags.
# The `^...` in strings is a "description label" (human readable); only the left side is evaluated.
###############################################################################

oplus_features=(
    "oplus.software.directservice.finger_flashnotes_enable^Xiao-Bu Memory" 
    "oplus.software.support_quick_launchapp"  
    "oplus.software.support_blockable_animation" 
    "oplus.software.support.zoom.multi_mode" 
    #"oplus.software.radio.networkless_support^Offline Calling (Networkless Call)" 
    #"oplus.software.display.ai_eyeprotect_v1_support^AI Eye Protection"
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
    "oplus.software.camera_volume_quick_launch" #GT5Pro
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
#add_feature "com.android.systemui.aod_notification_infor_text" build/portrom/images/my_product/etc/extension/com.oplus.app-features.xml
#add_feature 'com.oplus.mediacontroller.fluidConfig^^args=\"String:{&quot;statusbar_enable_default&quot;:1}' build/portrom/images/my_product/etc/extension/com.oplus.app-features.xml


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
    #"feature.super_settings_smart_touch_v2.support^Touch Through Screen Film V2"
    "com.oplus.games.show_bypass_charging_when_gameapps^Bypass Charging^args=\"boolean:true\""
    "com.oplus.wallpapers.livephoto_wallpaper^^args=\"boolean:true\""
    "com.oplus.battery.autostart_limit_num^^args=\"String:8|10-16|15-24|20\""
    "com.android.launcher.recent_lock_limit_num^^args=\"String:8|10-16|15-24|20\""
    "com.oplus.battery.whitelist_vowifi^^args=\"boolean:true\""
    "com.oplus.battery.support.smart_refresh" # GT5Pro
    "com.oplus.battery.life.mode.notificate^^args=\"int:1\"" # 13T indicate if the device is support life mode 1.0：1 2.0：2 
    "feature.support.game.AI_PLAY" #GT5Pro
    "feature.support.game.AI_PLAY_version3" # GT5Pro

    "feature.super_app_alive.support_min_ram^^args=\"int:12\""
    "feature.super_app_alive.support_flag^^args=\"int:15\""
    "feature.super_alive_game.support^^args=\"int:1\""
    "feature.super_settings_smart_touch.support^Touch Through Screen Film V1"
    "com.android.launcher.folder_content_recommend_disable"
    "com.android.launcher.rm_disable_folder_footer_ad"
    "feature.support.game.ASSIST_KEY"
    "oplus.software.vibration_custom"
    "com.oplus.smartmediacontroller.lss_assistant_enable^Sidebar Audio Separation Assistant"
    # Enabling "com.android.incallui.share_screen_and_touch_cmd_support^In-call Touch/Screen Sharing" crashes OOS calls; disabled
    "com.oplus.phonemanager.ai_voice_detect^Synthesized Voice^args=\"int:1\""
    "com.oplus.directservice.aitoolbox_enable^^args=\"boolean:true\""
    "com.coloros.support_gt_boost^^args=\"boolean:true\""
    "com.oplus.aicall.call_translate"
    "com.oplus.gesture.camera_space_gesture_support^Air Gestures" # Needs replacement with OplusGesture app for RM devices
    "com.oplus.gesture.intelligent_perception"
    "com.oplus.dmp.aiask_enable^AI Search^args=\"int:1\""
    "os.graphic.gallery.photoeditor.aibesttake^Best Take^args=\"int:1\""
    "com.oplus.tips.os_recommend_page_index^New Feature Recommendation^args=\"String:indexOS15_0_2_new\""
    "com.oplus.mediaturbo.transcoding^^args=\"boolean:true\""
    "com.android.launcher.app_advice_autoadd^^args=\"boolean:true\""
    "com.android.launcher.INDICATOR_BREENO_ENTRY_ENABLE^Xiao-Bu Hints on Home Screen^args=\"boolean:true\""
    #ColorOS 16 new added
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

# Call recording restrictions (Remove region/carrier control)
xmlstarlet ed -L -d '//app_feature[@name="com.android.incallui.support_call_record_prompt_mcc"]' build/portrom/images/my_stock/etc/extension/com.oplus.app-features.xml 

xmlstarlet ed -L -d '//app_feature[@name="com.android.incallui.hide_call_record_mcc"]' build/portrom/images/my_stock/etc/extension/com.oplus.app-features.xml 

#echo "ro.build.version.oplusrom=$ota_version" >> build/portrom/images/system/system/build.prop
#echo "oplus_hex_nv_id=$oplus_hex_nv_id" >> build/portrom/images/system/system/build.prop

if [[ "$port_vendor_brand" == "realme" ]];then
     unzip -o devices/common/ai_memory_16.zip -d build/portrom/images/
fi

aimemory_app=$(find build/portrom -type f -name "AIMemory.apk")

if [[ ! -f $aimemory_app ]]; then
    
    if [[ $regionmark == "CN" ]];then 
        unzip -o devices/common/ai_memory.zip -d build/portrom/images/
    else
         unzip -o devices/common/ai_memory_in/aimemory.zip -d build/portrom/images/
    fi
fi

for pkg in com.oplus.aimemory com.oplus.appbooster; do 
    if ! grep -q "<enable pkg=\"$pkg\"" build/portrom/images/my_product/etc/config/app_v2.xml;then
        sed -i "/<\/app>/i\  <enable pkg=\"$pkg\" priority=\"7\"/>" build/portrom/images/my_product/etc/config/app_v2.xml
    fi
done

if [[ ! -d build/portrom/images/my_product/etc/aisubsystem ]]; then
     if [[ $regionmark != "CN" ]];then 
         unzip -o devices/common/ai_memory_in/aisubsystem.zip -d build/portrom/images/
     fi
fi

###############################################################################
# GT Mode / Smart Sidebar etc. (Feature flags for Realme series)
#
# If `devices/common/GTMode/overlay` exists, add required features for GT Mode 
# and swap overlays depending on device/region (Realme / CN, etc.).
###############################################################################
if [[ -d devices/common/GTMode/overlay ]] && [[ $port_android_version != "16" ]];then
    #add_feature "oplus.software.support.gt.mode" build/portrom/images/my_product/etc/permissions/oplus.feature.android.xml
    add_feature_v2 oplus_feature "oplus.software.support.gt.mode^GT Mode" 
    add_feature_v2 app_feature "com.android.settings.device_rm^Realme Device: Required for GT Mode display"
    #add_feature "com.oplus.battery.support.gt_open_gamecenter" build/portrom/images/my_product/etc/extension/com.oplus.app-features.xml
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

    #temp
    #unzip -o devices/common/glassui_rui7.zip -d build/portrom/images/
fi

#echo "ro.surface_flinger.supports_background_blur=1" >> build/portrom/images/my_product/build.prop
#echo "ro.surface_flinger.media_panel_bg_blur=1" >> build/portrom/images/my_product/build.prop

# High Brightness Mode (Manual HBM) switch
add_feature_v2 oplus_feature "oplus.software.display.manual_hbm.support"
add_prop_v2 "ro.oplus.display.sell_mode.max_normal_nit" "800"

add_feature "android.hardware.biometrics.face"  build/portrom/images/my_product/etc/permissions/android.hardware.fingerprint.xml


add_feature_v2 oplus_feature "oplus.software.display.smart_color_temperature_rhythm_health_support"

# Audio Enhancements (Voice isolation / Noise reduction)
add_feature "oplus.hardware.audio.voice_isolation_support" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml
add_feature "oplus.hardware.audio.voice_denoise_support" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml

# Bypass Charging
sed -i '/<\/extend_features>/i\
    <app_feature name="com.oplus.plc_charge.support">\
        <StringList args="true"/>\
    </app_feature>' build/portrom/images/my_product/etc/extension/com.oplus.app-features-ext-bruce.xml
add_feature_v2 app_feature "com.android.settings.device_rm^Realme Device"
add_feature_v2  app_feature "com.oplus.fullscene_plc_charge.support^Fullscreen Bypass Charging^args=\"boolean:true\""
# Alert Slider (Three-stage)
if grep -q "oplus.software.audio.alert_slider"  build/portrom/images/my_product/etc/permissions/* ;then
    add_feature "oplus.software.audio.alert_slider" build/portrom/images/my_product/etc/permissions/oplus.product.feature_multimedia_unique.xml
fi

remove_feature "oplus.software.display.wcg_2.0_support" # Avoid soft reboot on screen color mode switch
remove_feature "oplus.software.display.origin_roundcorner_support"
remove_feature "oplus.software.vibration_ring_mute"
remove_feature  "oplus.software.vibration_alarm_clock"
remove_feature  "oplus.software.vibration_ringtone"
remove_feature  "oplus.software.vibration_threestage_key"
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
#remove_feature "os.charge.settings.batterysettings.batteryhealth"
remove_feature "oplus.software.display.adfr_v32_hp"  # OOS: Disabled because Xiao-Bu Memory crashes

remove_feature "com.oplus.battery.phoneusage.screenon.hide"

EUICC_GOOGLE=$(find build/portrom/images/ -name "EuiccGoogle" -type d )
if [[ -d $EUICC_GOOGLE ]];then
    rm -rfv $EUICC_GOOGLE
    remove_feature "android.hardware.telephony.euicc"
    remove_feature "oplus.software.radio.esim_support_sn220u"
    remove_feature "oplus.software.radio.esim_support"
    remove_feature "com.android.systemui.keyguard_support_esimcard"
fi

cp -rf  build/baserom/images/my_product/vendor/etc/* build/portrom/images/my_product/vendor/etc/

 # Camera
 if [[ $base_android_version -lt 33 ]];then
    cp -rf  build/baserom/images/my_product/etc/camera/* build/portrom/images/my_product/etc/camera

    # A16+ ports (Camera 6.x) should keep portrom's OplusCamera; do not replace with OnePlusCamera from baserom.
    old_camera_app=$(find build/baserom/images/my_product -type f -name "OnePlusCamera.apk")
    if [[ $port_android_version -lt 16 ]] && [[ -f $old_camera_app ]];then
        cp -rfv $(dirname "$old_camera_app")* build/portrom/images/my_product/priv-app/
        if [ ! -d build/portrom/images/my_product/priv-app/etc/permissions/ ];then
            mkdir -p build/portrom/images/my_product/priv-app/etc/permissions/
        fi
        rm -rf build/portrom/images/my_product/product_overlay/framework/*
        cp -rf build/baserom/images/my_product/product_overlay/* build/portrom/images/my_product/product_overlay/
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
        cp -rf build/baserom/images/my_product/product_overlay/framework/* build/portrom/images/my_product/product_overlay/framework/
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
        # rm -rfv $targetOvoiceManagerService/* cp -rfv "$sourceOvoiceManagerService"/* "$targetOvoiceManagerService/"
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


cp -rf build/baserom/images/my_product/etc/Multimedia_*.xml build/portrom/images/my_product/etc/


if [[ -f "tmp/etc/permissions/multimedia_privapp-permissions-oplus.xml" ]];then
    cp -rfv tmp/etc/permissions/multimedia_*.xml build/portrom/images/my_product/etc/permissions/
fi



for file in $(find build/baserom/images/my_product/etc/ -type f -name "OVMS_*");do
    if [[ -f "$file" ]];then
        cp -rfv $file build/portrom/images/my_product/etc/
    fi
done
#fix chinese char
find build/portrom/images/config -type f -name "*file_contexts" \
	    -exec perl -i -ne 'print if /^[\x00-\x7F]+$/' {} \;
#find build/portrom/images/config -type f -name "*file_contexts" -exec sed -i -E '/[\x{4e00}-\x{9fa5}]/d' {} \;

# bootanimation
if [[ $baseIsOOS == "true" && $portIsOOS == "true" ]]; then
    rm -rf build/portrom/images/my_product/media/bootanimation
    cp -rf build/baserom/images/my_product/media/bootanimation build/portrom/images/my_product/media/
elif [[ $baseIsColorOSCN == "true" && ( $portIsColorOSGlobal == "true" || $portIsColorOS == "true" ) ]]; then
    rm -rf build/portrom/images/my_product/media/bootanimation
    cp -rf build/baserom/images/my_product/media/bootanimation build/portrom/images/my_product/media/
fi
 
rm -rf build/portrom/images/my_product/media/quickboot
cp -rf build/baserom/images/my_product/media/quickboot build/portrom/images/my_product/media/
if [[ -f devices/common/wallpaper.zip ]] && [[ "$portIsColorOSGlobal" == "false" ]] && [[ "$portIsOOS" == "false" ]] && [[ "$port_android_version" -lt 16 ]];then
    unzip -o devices/common/wallpaper.zip -d build/portrom/images
 fi   

rm -rf build/portrom/images/my_product/res/*
cp -rf build/baserom/images/my_product/res/* build/portrom/images/my_product/res/

#rm -rf build/portrom/images/my_product/vendor/*
cp -rf build/baserom/images/my_product/vendor/* build/portrom/images/my_product/vendor/
rm -rf  build/portrom/images/my_product/overlay/*display*[0-9]*.apk
for overlay in $(find build/baserom/images/ -type f -name "*${base_my_product_type}*".apk);do
    cp -rf $overlay build/portrom/images/my_product/overlay/
done

super_computing=$(find build/portrom/images/my_product -name "string_super_computing*")
if [[ ! -f $super_computing ]];then
    cp -rf devices/common/super_computing/* build/portrom/images/my_product/etc/
fi

baseCarrierConfigOverlay=$(find build/baserom/images/ -type f -name "CarrierConfigOverlay*.apk")
portCarrierConfigOverlay=$(find build/portrom/images/ -type f -name "CarrierConfigOverlay*.apk")
if [ -f "${baseCarrierConfigOverlay}" ] && [ -f "${portCarrierConfigOverlay}" ];then
    blue "Replacing [CarrierConfigOverlay.apk]" "Replacing [CarrierConfigOverlay.apk]"
    rm -rf ${portCarrierConfigOverlay}
    cp -rf ${baseCarrierConfigOverlay} $(dirname ${portCarrierConfigOverlay})
else
    cp -rf ${baseCarrierConfigOverlay} build/portrom/images/my_product/overlay/
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
    cp -rfv build/baserom/images/my_product/etc/vibrator build/portrom/images/my_product/etc/
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
            rm -rfv $targetAONService/* cp -rfv $sourceAONService/* $targetAONService/
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
		            if [[ -f devices/${base_product_device}/camera6.0-fix_cos.zip ]] ;then
		                blue "ColorOS${port_android_version} Camera Fix (6.0)" "ColorOS Camera Fix (6.0)"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o devices/${base_product_device}/camera6.0-fix_cos.zip -d build/portrom/images/
		            elif [[ -f devices/${base_product_device}/camera5.0-fix_cos.zip ]] ;then
		                blue "ColorOS${port_android_version} Camera Fix" "ColorOS Camera Fix"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o devices/${base_product_device}/camera5.0-fix_cos.zip -d build/portrom/images/
		            fi
		            if [[ -f devices/${base_product_device}/camera6.0-fix_odm.zip ]] ;then
		                unzip -o devices/${base_product_device}/camera6.0-fix_odm.zip -d build/portrom/images/
		            elif [[ -f devices/${base_product_device}/camera5.0-fix_odm.zip ]] ;then
		                unzip -o devices/${base_product_device}/camera5.0-fix_odm.zip -d build/portrom/images/
		            fi
		        else
		            blue "Enabling Live Photo shooting" "Live Photo support"
		            rm -rf build/portrom/images/my_product/app/OplusCamera
		            rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		            unzip -o devices/${base_product_device}/live_photo_adds.zip -d build/portrom/images/
		        fi
		    elif  [[ "$portIsColorOSGlobal" == "true" ]];then
		        if [[ $port_android_version -ge 15 ]]; then 
		             if [[ -f devices/${base_product_device}/camera6.0-fix_cos_global.zip ]] ;then
		                blue "ColorOS Global ${port_android_version} Camera Fix (6.0)" "ColorOS Global Camera Fix (6.0)"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o devices/${base_product_device}/camera6.0-fix_cos_global.zip -d build/portrom/images/
		                if [[ -f devices/${base_product_device}/camera6.0-fix_odm.zip ]] ;then
		                    unzip -o devices/${base_product_device}/camera6.0-fix_odm.zip -d build/portrom/images/
		                elif [[ -f devices/${base_product_device}/camera5.0-fix_odm.zip ]] ;then
		                    unzip -o devices/${base_product_device}/camera5.0-fix_odm.zip -d build/portrom/images/
		                fi
		            elif [[ -f devices/${base_product_device}/camera5.0-fix_cos_global.zip ]] ;then
		                blue "ColorOS Global ${port_android_version} Camera Fix" "ColorOS Global Camera Fix"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o devices/${base_product_device}/camera5.0-fix_cos_global.zip -d build/portrom/images/
		                if [[ -f devices/${base_product_device}/camera5.0-fix_odm.zip ]] ;then
		                    unzip -o devices/${base_product_device}/camera5.0-fix_odm.zip -d build/portrom/images/
		                fi
		            fi
		        fi

		    elif  [[ "$portIsOOS" == "true" ]];then
		        if [[ $port_android_version -ge 15 ]]; then
		            if [[ -f devices/${base_product_device}/camera6.0-fix_oos.zip ]] ;then
		                blue "OxygenOS${port_android_version} Camera Fix (6.0)" "OxygenOS Camera Fix (6.0)"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o devices/${base_product_device}/camera6.0-fix_oos.zip -d build/portrom/images/
		                if [[ -f devices/${base_product_device}/camera6.0-fix_odm.zip ]] ;then
		                    unzip -o devices/${base_product_device}/camera6.0-fix_odm.zip -d build/portrom/images/
		                elif [[ -f devices/${base_product_device}/camera5.0-fix_odm.zip ]] ;then
		                    unzip -o devices/${base_product_device}/camera5.0-fix_odm.zip -d build/portrom/images/
		                fi
		            elif [[ -f devices/${base_product_device}/camera5.0-fix_oos.zip ]] ;then
		                blue "OxygenOS${port_android_version} Camera Fix" "OxygenOS Camera Fix"
		                rm -rf build/portrom/images/my_product/app/OplusCamera
		                rm -rf build/portrom/images/my_product/product_overlay/framework/com.oplus.camera.*.jar
		                echo "ro.vendor.oplus.camera.isSupportLumo=1" >> build/portrom/images/my_product/etc/bruce/build.prop
		                unzip -o devices/${base_product_device}/camera5.0-fix_oos.zip -d build/portrom/images/
		                if [[ -f devices/${base_product_device}/camera5.0-fix_odm.zip ]] ;then
		                    unzip -o devices/${base_product_device}/camera5.0-fix_odm.zip -d build/portrom/images/
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
    if [[ "${ENABLE_MASTER_MODE_PATCH}" == "true" ]] && \
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
while IFS= read -r prop; do
    val=$(grep -E '^ro.build.kernel.id=' "$prop" | cut -d= -f2)
    if [ -n "$val" ]; then
        kernel_id="$val"
        kernel_prop="$prop"
        break
    fi
done < <(find "$work_dir/build/portrom/images" -type f -name "build.prop")

kernel_major=$(echo "$kernel_id" | grep -Eo '^[0-9]+\.[0-9]+')

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
remove_data_encrypt=$(grep "remove_data_encryption" bin/port_config |cut -d '=' -f 2)
if [[ ${remove_data_encrypt} == "true" ]];then
    DECRYPTRD="-DECRYPTED"
    blue "Disabling data encryption"
    for fstab in $(find build/portrom/images -type f -name "fstab.*");do
		blue "Target: $fstab"
		sed -i "s/,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts:aes-256-cts:v2+emmc_optimized+wrappedkey_v0//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts:aes-256-cts:v2//g" $fstab
		sed -i "s/,metadata_encryption=aes-256-xts:wrappedkey_v0//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts:wrappedkey_v0//g" $fstab
		sed -i "s/,metadata_encryption=aes-256-xts//g" $fstab
		sed -i "s/,fileencryption=aes-256-xts//g" $fstab
        sed -i "s/,fileencryption=ice//g" $fstab
		sed -i "s/fileencryption/encryptable/g" $fstab
	done
fi

# for pname in ${port_partition};do
#     rm -rf build/portrom/images/${pname}.img
# done
echo "${pack_type}">fstype.txt
if [[ $super_extended == true ]];then
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
        blue "Packing [${pname}.img] with [$pack_type] filesystem" "Packing [${pname}.img] with [$pack_type] filesystem"
        python3 bin/fspatch.py build/portrom/images/${pname} build/portrom/images/config/${pname}_fs_config
        python3 bin/contextpatch.py build/portrom/images/${pname} build/portrom/images/config/${pname}_file_contexts
        #perl -pi -e 's/\\@/@/g' build/portrom/images/config/${pname}_file_contexts
        mkfs.erofs -zlz4hc,9 --mount-point ${pname} --fs-config-file build/portrom/images/config/${pname}_fs_config --file-contexts build/portrom/images/config/${pname}_file_contexts -T 1648635685 build/portrom/images/${pname}.img build/portrom/images/${pname}
        if [ -f "build/portrom/images/${pname}.img" ];then
            green "Successfully packed with [erofs]: [${pname}.img]" "Packing [${pname}.img] successfully with [erofs] format"
            #rm -rf build/portrom/images/${pname}
        else
            error "Failed to pack with [${pack_type}]: [${pname}]" "Faield to pack [${pname}]"
            exit 1
        fi
        unset fsType
        unset thisSize
    fi
done


rm fstype.txt

if [[ ${port_vendor_brand} == "realme" ]];then
    os_type="RealmeUI"
else
    os_type="ColorOS"
fi
rom_version=$(cat build/portrom/images/my_manifest/build.prop | grep "ro.build.display.id=" |  awk 'NR==1' | cut -d "=" -f2 | cut -d "(" -f1)
for img in $(find build/baserom/ -type f -name "vbmeta*.img");do
    blue "Disabling vbmeta verification: $img" "Disable vbmeta verify: $img"
    python3 bin/patch-vbmeta.py "$img" > /dev/null 2>&1
done
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
    let groupSize=superSize-1048576
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
            cp -rf build/baserom/firmware-update out/target/product/${base_product_device}/
        elif find build/baserom/ -type f \( -name "*.elf" -o -name "*.mdn" -o -name "*.bin" \) | grep -q .; then
            for firmware in $(find build/baserom/ -type f \( -name "*.elf" -o -name "*.mdn" -o -name "*.bin" \));do
                mv  -rfv $firmware out/target/product/${base_product_device}/firmware-update
            done
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
            cp -rf build/baserom/storage-fw out/target/product/${base_product_device}/
            cp -rf build/baserom/ffu_tool out/target/product/${base_product_device}/storage-fw
        else
            cp -rf build/baserom/ffu_tool out/target/product/${base_product_device}/
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
	   if [[ $is_ab_device == true ]]; then
	        # Pack super.img
        blue "Packing super.img for V-A/B terminal" "Packing super.img for V-AB device"
        lpargs="-F --virtual-ab --output build/portrom/images/super.img --metadata-size 65536 --super-name super --metadata-slots 3 --device super:$superSize --group=qti_dynamic_partitions_a:$superSize --group=qti_dynamic_partitions_b:$superSize"

        for pname in ${super_list};do
            if [ -f "build/portrom/images/${pname}.img" ];then
                subsize=$(du -sb build/portrom/images/${pname}.img |tr -cd 0-9)
                green "Super Sub-partition [$pname] Size [$subsize]" "Super sub-partition [$pname] size: [$subsize]"
                args="--partition ${pname}_a:none:${subsize}:qti_dynamic_partitions_a --image ${pname}_a=build/portrom/images/${pname}.img --partition ${pname}_b:none:0:qti_dynamic_partitions_b"
                lpargs="$lpargs $args"
                unset subsize
                unset args
            fi
        done
    else
        blue "Packing super.img for A-only terminal" "Packing super.img for A-only device"
        lpargs="-F --output build/portrom/images/super.img --metadata-size 65536 --super-name super --metadata-slots 2 --block-size 4096 --device super:$superSize --group=qti_dynamic_partitions:$superSize"
        for pname in ${super_list};do
            if [ -f "build/portrom/images/${pname}.img" ];then
                if [[ "$OSTYPE" == "darwin"* ]];then
                subsize=$(find build/portrom/images/${pname}.img | xargs stat -f%z | awk ' {s+=$1} END { print s }')
                else
                    subsize=$(du -sb build/portrom/images/${pname}.img |tr -cd 0-9)
                fi
                green "Super Sub-partition [$pname] Size [$subsize]" "Super sub-partition [$pname] size: [$subsize]"
                args="--partition ${pname}:none:${subsize}:qti_dynamic_partitions --image ${pname}=build/portrom/images/${pname}.img"
                lpargs="$lpargs $args"
                unset subsize
                unset args
            fi
        done
    fi
    lpmake $lpargs
    if [ -f "build/portrom/images/super.img" ];then
        green "super.img packing successful" "Pakcing super.img done."
    else
        error "Unable to pack super.img"  "Unable to pack super.img."
        exit 1
    fi
    #for pname in ${super_list};do
    #    rm -rf build/portrom/images/${pname}.img
    #done


    blue "Compressing super.img" "Comprising super.img"
    zstd build/portrom/images/super.img -o build/portrom/super.zst

    blue "Generating flash script" "Generating flashing script"

    mkdir -p out/${os_type}_${rom_version}/META-INF/com/google/android/   
    mkdir -p out/${os_type}_${rom_version}/firmware-update
    mkdir -p out/${os_type}_${rom_version}/bin/windows/
    cp -rf bin/flash/platform-tools-windows/* out/${os_type}_${rom_version}/bin/windows/
    cp -rf bin/flash/windows_flash_script.bat out/${os_type}_${rom_version}/
    cp -rf bin/flash/mac_linux_flash_script.sh out/${os_type}_${rom_version}/
    cp -rf bin/flash/zstd out/${os_type}_${rom_version}/META-INF/
    mv -f build/portrom/*.zst out/${os_type}_${rom_version}/
    if [[ -f devices/${base_product_device}/update-binary ]];then
        cp -rf devices/${base_product_device}/update-binary out/${os_type}_${rom_version}/META-INF/com/google/android/
    else
        cp -rf bin/flash/update-binary out/${os_type}_${rom_version}/META-INF/com/google/android/
    fi
    if [[ $is_ab_device = "false" ]];then
        mv -f build/baserom/firmware-update/*.img out/${os_type}_${rom_version}/firmware-update
        for fwimg in $(ls out/${os_type}_${rom_version}/firmware-update |cut -d "." -f 1 |grep -vE "super|cust|preloader");do
            if [[ $fwimg == *"xbl"* ]] || [[ $fwimg == *"dtbo"* ]] ;then
                # Warning: If wrong xbl img has been flashed, it will cause phone hard brick, so we just skip it with fastboot mode.
                continue

            elif [[ ${fwimg} == "BTFM" ]];then
                part="bluetooth"
            elif [[ ${fwimg} == "cdt_engineering" ]];then
                part="engineering_cdt"
            elif [[ ${fwimg} == "BTFM" ]];then
                part="bluetooth"
            elif [[ ${fwimg} == "dspso" ]];then
                part="dsp"
            elif [[ ${fwimg} == "keymaster64" ]];then
                part="keymaster"
            elif [[ ${fwimg} == "qupv3fw" ]];then
                part="qupfw"
            elif [[ ${fwimg} == "static_nvbk" ]];then
                part="static_nvbk"
            else
                part=${fwimg}                
            fi

            sed -i "/REM firmware/a \\\bin\\\windows\\\fastboot.exe flash "${part}" firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/windows_flash_script.bat
            sed -i "/# firmware/a fasatboot flash "${part}" firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
        done
        sed -i "/_b/d" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i "s/_a//g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i '/^REM SET_ACTION_SLOT_A_BEGIN/,/^REM SET_ACTION_SLOT_A_END/d' out/${os_type}_${rom_version}/windows_flash_script.bat
        sed -i '/# SET_ACTION_SLOT_A_BEGIN/,/# SET_ACTION_SLOT_A_END/d' out/${os_type}_${rom_version}/mac_linux_flash_script.sh
    else
        mv -f build/baserom/images/*.img out/${os_type}_${rom_version}/firmware-update
        for fwimg in $(ls out/${os_type}_${rom_version}/firmware-update |cut -d "." -f 1 |grep -vE "super|cust|preloader");do
            if [[ $fwimg == *"xbl"* ]] || [[ $fwimg == *"dtbo"* ]] || [[ $fwimg == *"reserve"* ]] || [[ $fwimg == *"boot"* ]];then
                rm -rfv out/${os_type}_${rom_version}/firmware-update/*reserve*
                # Warning: If wrong xbl img has been flashed, it will cause phone hard brick, so we just skip it with fastboot mode.
                continue
            elif [[ $fwimg == "mdm_oem_stanvbk" ]] || [[ $fwimg == "spunvm" ]] ;then
                sed -i "/REM firmware/a \\\bin\\\windows\\\fastboot.exe flash "${fwimg}" firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/windows_flash_script.bat
                sed -i "/\# firmware/a fastboot flash "${fwimg}" firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
            elif [ "$(echo ${fwimg} |grep vbmeta)" != "" ];then
                sed -i "/REM firmware/a \\\bin\\\windows\\\fastboot.exe --disable-verity --disable-verification flash "${fwimg}"_b firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/windows_flash_script.bat
                sed -i "/REM firmware/a \\\bin\\\windows\\\fastboot.exe --disable-verity --disable-verification flash "${fwimg}"_a firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/windows_flash_script.bat
                sed -i "/\# firmware/a fastboot --disable-verity --disable-verification flash "${fwimg}"_b firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
                sed -i "/\# firmware/a fastboot --disable-verity --disable-verification flash "${fwimg}"_a firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
            else
                sed -i "/REM firmware/a \\\bin\\\windows\\\fastboot.exe flash "${fwimg}"_b firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/windows_flash_script.bat
                sed -i "/REM firmware/a \\\bin\\\windows\\\fastboot.exe flash "${fwimg}"_a firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/windows_flash_script.bat
                sed -i "/\# firmware/a fastboot flash "${fwimg}"_b firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
                sed -i "/\# firmware/a fastboot flash "${fwimg}"_a firmware-update\/"${fwimg}".img" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
            fi
        done
    fi

    sed -i "s/device_code/${base_product_device}/g" out/${os_type}_${rom_version}/windows_flash_script.bat
    sed -i "s/REGIONMARK/${regionmark}/g" out/${os_type}_${rom_version}/windows_flash_script.bat
    sed -i "s/device_code/${base_product_device}/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
    sed -i "s/REGIONMARK/${regionmark}/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
    sed -i "s/device_code/${base_product_device}/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
    sed -i "s/REGIONMARK/${regionmark}/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
    sed -i "s/portversion/${port_rom_version}/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
    sed -i "s/baseversion/${base_rom_version}/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
    sed -i "s/andVersion/${port_android_version}/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
    sed -i "s/device_code/${base_product_device}/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary

    unix2dos out/${os_type}_${rom_version}/windows_flash_script.bat

    #disable vbmeta
    for img in $(find out/${os_type}_${rom_version}/ -type f -name "vbmeta*.img");do
        blue "Disabling vbmeta verification: $img" "Disable vbmeta verify: $img"
        python3 bin/patch-vbmeta.py ${img}
    done

    ksu_bootimg_file=$(find devices/$base_product_device/ -type f -name "*boot_ksu.img")
    nonksu_bootimg_file=$(find devices/$base_product_device/ -type f -name "*boot_noksu.img")
    custom_bootimg_file=$(find devices/$base_product_device/ -type f -name "*boot_custom.img")

    if [[ -f $nonksu_bootimg_file ]];then
        nonksubootimg=$(basename "$nonksu_bootimg_file")
        mv -f $nonksu_bootimg_file out/${os_type}_${rom_version}/
        mv -f  devices/$base_product_device/dtbo_noksu.img out/${os_type}_${rom_version}/firmware-update/dtbo_noksu.img
        sed -i "s/boot_official.img/$nonksubootimg/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i "s/boot_official.img/$nonksubootimg/g" out/${os_type}_${rom_version}/windows_flash_script.bat
        sed -i "s/boot_official.img/$nonksubootimg/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
        sed -i "s/dtbo.img/dtbo_noksu.img/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i "s/dtbo.img/dtbo_noksu.img/g" out/${os_type}_${rom_version}/windows_flash_script.bat
        sed -i "s/dtbo.img/dtbo_noksu.img/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
        sed -i '/^REM OFFICAL_BOOT_START/,/^REM OFFICAL_BOOT_END/d' out/${os_type}_${rom_version}/windows_flash_script.bat
    else
        bootimg=$(find build/baserom/ out/${os_type}_${rom_version} -name "boot.img")
        mv -f $bootimg out/${os_type}_${rom_version}/boot_official.img
    fi

    if [[ -f "$ksu_bootimg_file" ]];then
        ksubootimg=$(basename "$ksu_bootimg_file")
        mv -f $ksu_bootimg_file out/${os_type}_${rom_version}/
        mv -f  devices/$base_product_device/dtbo_ksu.img out/${os_type}_${rom_version}/firmware-update/dtbo_ksu.img
        sed -i "s/boot_tv.img/$ksubootimg/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i "s/boot_tv.img/$ksubootimg/g" out/${os_type}_${rom_version}/windows_flash_script.bat
        sed -i "s/boot_tv.img/$ksubootimg/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
        sed -i "s/dtbo_tv.img/dtbo_ksu.img/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i "s/dtbo_tv.img/dtbo_ksu.img/g" out/${os_type}_${rom_version}/windows_flash_script.bat
        sed -i "s/dtbo_tv.img/dtbo_ksu.img/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
        sed -i '/^REM OFFICAL_BOOT_START/,/^REM OFFICAL_BOOT_END/d' out/${os_type}_${rom_version}/windows_flash_script.bat
        
    elif [[ -f "$custom_bootimg_file" ]];then
        custombootimg=$(basename "$custom_bootimg_file")
        mv -f $custom_bootimg_file out/${os_type}_${rom_version}/
        if [[ -f devices/$base_product_device/dtbo_custom.img ]]; then
            mv -f devices/$base_product_device/dtbo_custom.img out/${os_type}_${rom_version}/firmware-update/dtbo_custom.img
        fi
        sed -i "s/boot_tv.img/$custombootimg/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i "s/boot_tv.img/$custombootimg/g" out/${os_type}_${rom_version}/windows_flash_script.bat
        sed -i "s/boot_tv.img/$custombootimg/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
        sed -i "s/dtbo_tv.img/dtbo_custom.img/g" out/${os_type}_${rom_version}/META-INF/com/google/android/update-binary
        sed -i "s/dtbo_tv.img/dtbo_custom.img/g" out/${os_type}_${rom_version}/windows_flash_script.bat
        sed -i "s/dtbo_tv.img/dtbo_custom.img/g" out/${os_type}_${rom_version}/mac_linux_flash_script.sh
        
    fi

    find out/${os_type}_${rom_version} |xargs touch
    pushd out/${os_type}_${rom_version}/ >/dev/null || exit
    zip -r ${os_type}_${rom_version}.zip ./*
    mv ${os_type}_${rom_version}.zip ../
    popd >/dev/null || exit
    pack_timestamp=$(date +"%m%d%H%M")
    hash=$(md5sum out/${os_type}_${rom_version}.zip |head -c 10)
    if [[ $pack_type == "EROFS" ]] && [[ -f out/${os_type}_${rom_version}/$ksubootimg ]];then
        pack_type="ROOT_"${pack_type}
    fi
    mv out/${os_type}_${rom_version}.zip out/${os_type}_${rom_version}_${hash}_${port_product_model}_${pack_timestamp}_${pack_type}.zip
    green "Porting complete" "Porting completed"    
    green "Output Path:" "Output: "
    green "$(pwd)/out/${os_type}_${rom_version}_${hash}_${port_product_model}_${pack_timestamp}_${pack_type}.zip"
fi
