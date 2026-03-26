#!/bin/bash

# Colored log output
# Accepts 1 or 2 args; if 2 args, the second (English) is used
error() {
    if [ "$#" -eq 2 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$2"\033[0m"
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$1"\033[0m"
    fi
}

yellow() {
    if [ "$#" -eq 2 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$2"\033[0m"
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$1"\033[0m"
    fi
}

blue() {
    if [ "$#" -eq 2 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$2"\033[0m"
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$1"\033[0m"
    fi
}

green() {
    if [ "$#" -eq 2 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$2"\033[0m"
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$1"\033[0m"
    fi
}

# Check if a required command exists (abort if not)
exists() {
    command -v "$1" > /dev/null 2>&1
}

abort() {
    error "--> Missing command: $1 (please run ./setup.sh first; sudo is required on Linux)"
    exit 1
}

check() {
    for b in "$@"; do
        exists "$b" || abort "$b"
    done
}

shopt -s expand_aliases
if [[ "$OSTYPE" == "darwin"* ]]; then
    yellow "macOS detected, setting GNU command aliases"
    alias sed=gsed
    alias tr=gtr
    alias grep=ggrep
    alias du=gdu
    alias date=gdate
    alias stat=gstat
    alias find=gfind
fi

# Replace Smali code in an APK or JAR file, without supporting resource patches.
# $1: Target APK/JAR file
# $2: Target Smali file (supports relative paths for Smali files)
# $3: Value to be replaced
# $4: Replacement value
patch_smali() {
    if [[ $is_eu_rom == "true" ]]; then
       SMALI_COMMAND="java -jar bin/apktool/smali-3.0.5.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali-3.0.5.jar" 
    else
       SMALI_COMMAND="java -jar bin/apktool/smali.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali.jar"
    fi
    targetfilefullpath=$(find build/portrom/images -type f -name $1)
    if [ -f $targetfilefullpath ];then
        targetfilename=$(basename $targetfilefullpath)
        yellow "Modifying $targetfilename"
        foldername=${targetfilename%.*}
        rm -rf tmp/$foldername/
        mkdir -p tmp/$foldername/
        cp -rf $targetfilefullpath tmp/$foldername/
        7z x -y tmp/$foldername/$targetfilename *.dex -otmp/$foldername >/dev/null
        for dexfile in tmp/$foldername/*.dex;do
            smalifname=${dexfile%.*}
            smalifname=$(echo $smalifname | cut -d "/" -f 3)
            ${BAKSMALI_COMMAND} d --api ${port_android_sdk} ${dexfile} -o tmp/$foldername/$smalifname 2>&1 || error "Baksmaling failed"
        done
        if [[ $2 == *"/"* ]];then
            targetsmali=$(find tmp/$foldername/*/$(dirname $2) -type f -name $(basename $2))
        else
            targetsmali=$(find tmp/$foldername -type f -name $2)
        fi
        if [ -f $targetsmali ];then
            smalidir=$(echo $targetsmali |cut -d "/" -f 3)
            yellow "Target ${smalidir} found"
            search_pattern=$3
            replacement_pattern=$4
            if [[ $5 == 'regex' ]];then
                 sed -i "/${search_pattern}/c\\${replacement_pattern}" $targetsmali
            else
            sed -i "s/$search_pattern/$replacement_pattern/g" $targetsmali
            fi
            ${SMALI_COMMAND} a --api ${port_android_sdk} tmp/$foldername/${smalidir} -o tmp/$foldername/${smalidir}.dex > /dev/null 2>&1 || error "Smaling failed"
            pushd tmp/$foldername/ >/dev/null || exit
            7z a -y -mx0 -tzip $targetfilename ${smalidir}.dex  > /dev/null 2>&1 || error "Failed to modify $targetfilename"
            popd >/dev/null || exit
            yellow "Fix $targetfilename completed"
            if [[ $targetfilename == *.apk ]]; then
                yellow "APK file detected, initiating ZipAlign process..."
                rm -rf ${targetfilefullpath}

                # Align modified APKs to avoid error "Targeting R+ (version 30 and above) requires the resources.arsc of installed APKs to be stored uncompressed and aligned on a 4-byte boundary"
                zipalign -p -f -v 4 tmp/$foldername/$targetfilename ${targetfilefullpath} > /dev/null 2>&1 || error "zipalign error, please check for any issues"
                yellow "APK ZipAlign process completed."
                yellow "ApkSigner signing.."
                apksigner sign -v --key otatools/key/testkey.pk8 --cert otatools/key/testkey.x509.pem ${targetfilefullpath}
                apksigner verify -v ${targetfilefullpath}
                yellow "Copying APK to target ${targetfilefullpath}"
            else
                yellow "Copying file to target ${targetfilefullpath}"
                cp -rf tmp/$foldername/$targetfilename ${targetfilefullpath}
            fi
        fi
    else
        error "Failed to find $1, please check it manually."
    fi

}

# Check if a property exists in a file
is_property_exists () {
    if [ $(grep -c "$1" "$2") -ne 0 ]; then
        return 0
    else
        return 1
    fi
}

disable_avb_verify() {
    fstab=$1
    blue "Disabling avb_verify: $fstab"
    if [[ ! -f $fstab ]]; then
        yellow "$fstab not found, please check it manually"
    else
        sed -i "s/,avb_keys=.*avbpubkey//g" $fstab
        sed -i "s/,avb=vbmeta_system//g" $fstab
        sed -i "s/,avb=vbmeta_vendor//g" $fstab
        sed -i "s/,avb=vbmeta//g" $fstab
        sed -i "s/,avb//g" $fstab
    fi
}

extract_partition() {
    part_img=$1
    part_name=$(basename ${part_img})
    target_dir=$2
    if [[ -f ${part_img} ]];then 
        if [[ $($tools_dir/gettype -i ${part_img} ) == "ext" ]];then
            blue "[ext] Extracting ${part_name}"
            python3 bin/imgextractor/imgextractor.py ${part_img} ${target_dir}  || { error "Extracting ${part_name} failed."; exit 1; }
            green "[ext] ${part_name} extracted."
            rm -rf ${part_img}      
        elif [[ $($tools_dir/gettype -i ${part_img}) == "erofs" ]]; then
            blue "[erofs] Extracting ${part_name}"
            extract.erofs -x -i ${part_img}  -o $target_dir > /dev/null 2>&1 || { error "Extracting ${part_name} failed." ; exit 1; }
            green "[erofs] ${part_name} extracted."
            rm -rf ${part_img}
        else
            error "Unable to handle img, exit."
            exit 1
        fi
    fi    
}

disable_avb_verify() {
    fstab=$(find $1 -name "fstab*")
    if [[ $fstab == "" ]];then
        error "No fstab found!"
        sleep 5
    else
        blue "Disabling AVB verification..."
        for file in $fstab; do
            sed -i 's/,avb.*system//g' $file
            sed -i 's/,avb,/,/g' $file
            sed -i 's/,avb=.*a,/,/g' $file
            sed -i 's/,avb_keys.*key//g' $file
            if [[ "${pack_type}" == "EXT" ]];then
                sed -i "/erofs/d" $file
            fi
        done
        blue "AVB verification disabled successfully"
    fi
}

spoof_bootimg() {
    set +euo pipefail
    bootimg=$1
    mkdir -p ${work_dir}/tmp/boot_official
    cp $bootimg ${work_dir}/tmp/boot_official/boot.img
    pushd ${work_dir}/tmp/boot_official
    magiskboot unpack -h ${work_dir}/tmp/boot_official/boot.img > /dev/null 2>&1
    sed -i '/^cmdline=/ s/$/ androidboot.vbmeta.device_state=unlocked/' header
    magiskboot repack ${work_dir}/tmp/boot_official/boot.img  ${work_dir}/tmp/boot_official/new-boot.img
    popd
    cp ${work_dir}/tmp/boot_official/new-boot.img $bootimg
    set -euo pipefail
}


patch_kernel_to_bootimg() {
    set +euo pipefail
    kernel_file=$1
    dtb_file=$2
    bootimg_name=$3
    mkdir -p ${work_dir}/tmp/boot
    cd ${work_dir}/tmp/boot
    bootimg=$(find ${work_dir}/build/baserom/ -name boot.img)
    cp $bootimg ${work_dir}/tmp/boot/boot.img
    magiskboot unpack -h ${work_dir}/tmp/boot/boot.img > /dev/null 2>&1
    if [ -f ramdisk.cpio ]; then
    comp=$(magiskboot decompress ramdisk.cpio 2>/dev/null | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p') || comp=""
    if [ "$comp" ]; then
        mv -f ramdisk.cpio ramdisk.cpio.$comp
        magiskboot decompress ramdisk.cpio.$comp ramdisk.cpio > /dev/null 2>&1
        if [ $? != 0 ] && $comp --help; then
        $comp -dc ramdisk.cpio.$comp >ramdisk.cpio
        fi
    fi
    mkdir -p ramdisk
    chmod 755 ramdisk
    cd ramdisk
    EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F ../ramdisk.cpio -i
    disable_avb_verify ${work_dir}/tmp/boot/
    fi
    cp -f $kernel_file ${work_dir}/tmp/boot/kernel
    cp -f $dtb_file ${work_dir}/tmp/boot/dtb
    cd ${work_dir}/tmp/boot/ramdisk/
    find | sed 1d | cpio -H newc -R 0:0 -o -F ../ramdisk_new.cpio > /dev/null 2>&1
    cd ..
    if [ "$comp" ]; then
      magiskboot compress=$comp ramdisk_new.cpio
      if [ $? != 0 ] && $comp --help > /dev/null 2>&1; then
          $comp -9c ramdisk_new.cpio >ramdisk.cpio.$comp
      fi
    fi
    ramdisk=$(ls ramdisk_new.cpio* | tail -n1)
    if [ "$ramdisk" ]; then
      cp -f $ramdisk ramdisk.cpio
      case $comp in
      cpio) nocompflag="-n" ;;
      esac
      magiskboot repack $nocompflag ${work_dir}/tmp/boot/boot.img ${work_dir}/devices/$base_product_device/${bootimg_name} 
    fi
    rm -rf ${work_dir}/tmp/boot
    cd $work_dir
    set -euo pipefail
}

patch_kernel() {
    set +euo pipefail
    local _restore_opts="set -euo pipefail"

    kernel_file=$1
    dtb_file=$2
    bootimg_name=$3
    echo ">> Starting patch_kernel()..."

    local tmp_boot="${work_dir}/tmp/boot_patch"
    rm -rf "${tmp_boot}"
    mkdir -p "${tmp_boot}"
    cd "${tmp_boot}"

    blue "Searching boot.img under ${work_dir}/build/baserom/"
    local bootimg
    bootimg=$(find "${work_dir}/build/baserom/" -name boot.img | head -n 1)
    if [[ -z "$bootimg" ]]; then
        error "boot.img not found"
        cd "${work_dir}"
        return 1
    fi
    cp "$bootimg" boot.img

    blue "Unpacking boot.img (magiskboot unpack)"
    magiskboot unpack -h boot.img > /dev/null 2>&1 || true

    # Handle ramdisk if present
    if [ -f ramdisk.cpio ]; then
        local comp=""
        comp=$(magiskboot decompress ramdisk.cpio 2>/dev/null | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p') || comp=""
        if [ -n "$comp" ]; then
            mv -f ramdisk.cpio ramdisk.cpio.$comp
            magiskboot decompress ramdisk.cpio.$comp ramdisk.cpio > /dev/null 2>&1 || true
        fi
        mkdir -p ramdisk
        chmod 755 ramdisk
        cd ramdisk
        EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F ../ramdisk.cpio -i > /dev/null 2>&1 || true
        cd ..
    fi

    blue "Replacing kernel"
    cp -f "$kernel_file" kernel

    if [[ -f dtb ]] && [[ -n "$dtb_file" ]] && [[ -f "$dtb_file" ]]; then
        blue "Replacing dtb in boot.img"
        cp -f "$dtb_file" dtb
    fi

    # Repack ramdisk if it was extracted
    if [ -d ramdisk ]; then
        cd ramdisk
        find . | sed 1d | cpio -H newc -R 0:0 -o -F ../ramdisk_new.cpio > /dev/null 2>&1 || true
        cd ..
        if [ -n "$comp" ]; then
            magiskboot compress=$comp ramdisk_new.cpio > /dev/null 2>&1 || true
        fi
        local ramdisk_file
        ramdisk_file=$(ls ramdisk_new.cpio* 2>/dev/null | tail -n1)
        [ -n "$ramdisk_file" ] && cp -f "$ramdisk_file" ramdisk.cpio
    fi

    local nocompflag=""
    case $comp in
        cpio) nocompflag="-n" ;;
    esac

    blue "Repacking boot.img → ${bootimg_name}"
    magiskboot repack $nocompflag boot.img "${work_dir}/devices/${base_product_device}/${bootimg_name}" \
        || magiskboot repack boot.img "${work_dir}/devices/${base_product_device}/${bootimg_name}" \
        || { error "Failed to repack boot.img"; cd "${work_dir}"; return 1; }

    blue "patch_kernel() done"
    cd "${work_dir}"
    set -euo pipefail
}

add_feature() {
    feature=$1
    file=$2
    parent_node=$(xmlstarlet sel -t -m "/*" -v "name()" "$file")
    feature_node=$(xmlstarlet sel -t -m "/*/*" -v "name()" -n "$file" | head -n 1)
    found=0
    for xml in $(find build/portrom/images/my_product/etc/ -type f -name "*.xml");do
        if  grep -nq "$feature" $xml ; then
            blue "Feature $feature already exists, skipping..."
            found=1
        fi
    done
    if [[ $found == 0 ]] ; then
        blue "Adding feature $feature"
        sed -i "/<\/$parent_node>/i\\\\t\\<$feature_node name=\"$feature\"\/>" "$file"
    fi
}

add_feature_v2() {
    type=$1
    shift # Remove first arg (type), treat the rest as features

    case "$type" in
        oplus_feature)
            dir="build/portrom/images/my_product/etc/extension"
            base_file="com.oplus.oplus-feature"
            root_tag="oplus-config"
            node_tag="oplus-feature"
            attr_prefix='name='
            ;;
        app_feature)
            dir="build/portrom/images/my_product/etc/extension"
            base_file="com.oplus.app-features"
            root_tag="extend_features"
            node_tag="app_feature"
            attr_prefix='name='
            ;;
        permission_feature)
            dir="build/portrom/images/my_product/etc/permissions"
            base_file="com.oplus.android-features"
            root_tag="permissions"
            node_tag="feature"
            attr_prefix='name='
            ;;
        permission_oplus_feature)
            dir="build/portrom/images/my_product/etc/permissions"
            base_file="oplus.feature-android"
            root_tag="oplus-config"
            node_tag="oplus-feature"
            attr_prefix='name='
            ;;
        *)
            echo "Invalid type: $type"
            return 1
            ;;
    esac

    output_file="$dir/${base_file}-ext-bruce.xml"
    mkdir -p "$dir"

    # Create output file if it doesn't exist
    if [[ ! -f "$output_file" ]]; then
        echo "Creating: $output_file"
        cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<$root_tag>
</$root_tag>
EOF
    fi

    for entry in "$@"; do
    IFS='^' read -r feature comment extra <<< "$entry"
    
    [[ "$feature" == "$comment" ]] && comment=""
    
    [[ -z "$extra" ]] && extra=""

found=0
for xml in $(find build/portrom/images/my_product/etc/ -type f -name "*.xml"); do
	if grep -n "$feature" "$xml" | grep -vq "<!--"; then
           blue "Feature $feature already exists, skipping..."
           found=1
           break
    fi
done

    if [[ $found == 0 ]]; then
        blue "Adding feature: $feature"

        if [[ "$type" == "app_feature" ]]; then
            attrs="name=\"$feature\""
            [[ -n "$extra" ]] && attrs="$attrs $extra"
        else
            attrs="name=\"$feature\""
            [[ -n "$extra" ]] && attrs="$attrs $extra"
        fi

        # Write comment/label if provided
        if [[ -n "$comment" ]]; then
            sed -i "/<\/$root_tag>/i\\    <!-- $comment -->" "$output_file"
        fi
        # Write feature node
        sed -i "/<\/$root_tag>/i\\    <$node_tag $attrs\/>" "$output_file"
    fi
done
}

remove_feature() {
    feature=$1
    force=${2:-}  # Pass "force" as second arg to force delete regardless of base ROM

    if [[ "$force" == "force" ]]; then
        blue "Force delete mode: removing $feature regardless of base ROM"
    else
        # Non-force: check if the feature exists in base ROM
        for file in $(find build/baserom/images/my_product/etc/ -type f -name "*.xml"); do
            if grep -nq "<!--.*$feature.*-->" "$file"; then
                blue "Feature $feature is commented out in base ROM, continuing with delete..."
            elif grep -nq "$feature" "$file"; then
                blue "Feature $feature exists in base ROM, skipping delete..."
                return
            fi
        done
    fi

    # Delete from portrom
    for file in $(find build/portrom/images/my_product/etc/ -type f -name "*.xml"); do
        if grep -nq "$feature" "$file"; then
            sed -i "/$feature/d" "$file"
            blue "Deleted: $feature from $(basename $file)"
        fi
    done
}

update_prop_from_base() {

    source_build_prop="build/baserom/images/my_product/build.prop"
    target_build_prop="build/portrom/images/my_product/build.prop"

    cp "$target_build_prop" tmp/$(basename $target_build_prop).port

    while IFS= read -r line; do
        if [[ -z "$line" || "$line" =~ ^# || "$line" =~ oplusrom || "$line" =~ date ]]; then
            continue
        fi
        key=$(echo "$line" | cut -d'=' -f1)
        value=$(echo "$line" | cut -d'=' -f2-)

        if grep -q "^$key=" "$target_build_prop"; then
            sed -i "s|^$key=.*|$key=$value|" "$target_build_prop"
        else
            echo "$key=$value" >> "$target_build_prop"
        fi
    done < "$source_build_prop"

}

add_prop(){
    prop=$1
    value=${2:-}
    if ! grep -q "${prop}" build/portrom/images/my_product/build.prop;then
        blue "Adding prop: $prop=$value"
        echo "$prop=$value" >> build/portrom/images/my_product/build.prop
    elif grep -q "${prop}" build/portrom/images/my_product/build.prop;then
        blue "Editing prop: $prop=$value"
        sed -i "s/${prop}=.*/${prop}=${value}/g" build/portrom/images/my_product/build.prop
    fi
}

remove_prop(){
    prop=$1
    if ! grep -q "${prop}" build/baserom/images/my_product/build.prop;then
        blue "Removing prop: $prop"
        sed -i "/${prop}/d" build/portrom/images/my_product/build.prop
    fi
}

add_prop_v2(){
    prop=$1
    value=${2:-}
    bruce_prop="build/portrom/images/my_product/etc/bruce/build.prop"
    portrom_prop="build/portrom/images/my_product/build.prop"

    # If not in either file, add to bruce_prop
    if ! grep -q "^${prop}=" "$bruce_prop" && ! grep -q "^${prop}=" "$portrom_prop"; then
        blue "Adding prop: $prop=$value"
        echo "$prop=$value" >> "$bruce_prop"
        return
    fi

    if grep -q "^${prop}=" "$bruce_prop"; then
        blue "Editing prop (bruce): $prop=$value"
        sed -i "s|^${prop}=.*|${prop}=${value}|" "$bruce_prop"
    fi

    if grep -q "^${prop}=" "$portrom_prop"; then
        blue "Editing prop (portrom): $prop=$value"
        sed -i "s|^${prop}=.*|${prop}=${value}|" "$portrom_prop"
    fi
}

remove_prop_v2() {
    prop="${1}"
    force="${2:-}"
    escaped_prop=$(echo "${prop}" | sed 's/\./\\./g')
    
    if [[ -n ${force} ]]; then
        blue "Force remove prop: ${prop}"
        sed -i -E "/^(${escaped_prop}=|${escaped_prop}\.)/s/^/#/" build/portrom/images/my_product/etc/bruce/build.prop
        sed -i -E "/^(${escaped_prop}=|${escaped_prop}\.)/s/^/#/" build/portrom/images/my_product/build.prop
    else
        # Check if the same prop (or prefix) exists in base ROM
        if ! grep -q -E "^(${escaped_prop}=|${escaped_prop}\.)" build/baserom/images/my_product/build.prop; then
            blue "Remove prop: ${prop}"
            sed -i -E "/^(${escaped_prop}=|${escaped_prop}\.)/s/^/#/" build/portrom/images/my_product/etc/bruce/build.prop
        else
            blue "Keep prop (exists in base): ${prop}"
        fi
    fi
}

prepare_base_prop() {
    source_build_prop="build/baserom/images/my_product/build.prop"
    target_build_prop="build/portrom/images/my_product/build.prop"
    bruce_prop="build/portrom/images/my_product/etc/bruce/build.prop"

    mkdir -p "$(dirname "$target_build_prop")"
    mkdir -p "$(dirname "$bruce_prop")"

    [[ ! -d tmp ]] && mkdir tmp

    # Back up current portrom build.prop
    cp -f "$target_build_prop" tmp/build.prop.portrom.bak

    # Back up existing bruce/build.prop if present (to selectively carry over later)
    if [[ -f "$bruce_prop" ]]; then
        cp -f "$bruce_prop" tmp/build.prop.portrom.bruce.bak
    else
        rm -f tmp/build.prop.portrom.bruce.bak 2>/dev/null
    fi

    # Overwrite portrom build.prop with baserom content
    cp -f "$source_build_prop" "$target_build_prop"

    # Initialize bruce.build.prop
    echo "# Props added during port" > "$bruce_prop"

    # Add import line (prevent duplicates)
    if ! grep -q "^import /mnt/vendor/my_product/etc/bruce/build.prop" "$target_build_prop"; then
        echo "" >> "$target_build_prop"
        echo "import /mnt/vendor/my_product/etc/bruce/build.prop" >> "$target_build_prop"
    fi
}

merge_portrom_bruce_props() {
    old_bruce_prop="tmp/build.prop.portrom.bruce.bak"
    [[ -f "$old_bruce_prop" ]] || return

    # Only carry over camera/camerax-related props from the old bruce/build.prop
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        [[ -z "$value" ]] && continue
        # Skip keys with special regex characters that would break grep/sed
        [[ "$key" =~ [.\*\[\]\^\$] ]] && key=$(printf '%s' "$key" | sed 's/[.[\\*^$]/\\&/g')

        key_lc=$(echo "$key" | tr '[:upper:]' '[:lower:]')
        if [[ "$key_lc" == *"camera"* ]] || [[ "$key_lc" == ro.camerax.* ]]; then
            add_prop_v2 "$key" "$value" || true
        fi
    done < "$old_bruce_prop"
}

add_prop_from_port() {
    base_build_prop="build/baserom/images/my_product/build.prop"
    old_portrom_prop="tmp/build.prop.portrom.bak"
    bruce_prop="build/portrom/images/my_product/etc/bruce/build.prop"

    # Props that are always carried over from the old portrom
    force_keys=(
        ro.build.version.oplusrom
        ro.build.version.oplusrom.display
        ro.build.version.oplusrom.confidential
        ro.build.version.realmeui
    )

    declare -A base_props
    # Load baserom props — guard against missing file
    if [[ -f "$base_build_prop" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            [[ "$key" == import* ]] && continue
            base_props["$key"]="$value"
        done < "$base_build_prop"
    fi

    # Build diff in a temp file
    temp_file=$(mktemp)

    # Extract props not present in base ROM (skip force keys, handled separately)
    if [[ -f "$old_portrom_prop" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            [[ "$key" == import* ]] && continue

            if [[ " ${force_keys[*]} " == *" $key "* ]]; then
                continue
            fi

            if [[ ! -v base_props["$key"] ]]; then
                echo "$key=$value" >> "$temp_file"
                blue "Added: $key=$value"
            fi
        done < "$old_portrom_prop"
    fi

    # Add forced keys — use safe pattern to avoid pipefail from grep exit 1
    for key in "${force_keys[@]}"; do
        local raw_line value=""
        raw_line=$(grep -m1 "^${key}=" "$old_portrom_prop" 2>/dev/null) || raw_line=""
        [[ -n "$raw_line" ]] && value="${raw_line#*=}"
        value=$(echo "$value" | tr -d "\r")

        if [[ -n "$value" ]]; then
            sed -i "/^${key}=/d" "$temp_file" 2>/dev/null || true
            echo "$key=$value" >> "$temp_file"
            blue "Force update: $key=$value"
        fi
    done

    # Write to final file
    mkdir -p "$(dirname "$bruce_prop")"
    cat "$temp_file" >> "$bruce_prop"
    rm -f "$temp_file"

    # Carry over camera/camerax props from old portrom bruce/build.prop
    merge_portrom_bruce_props || true
}

smali_wrapper() {
    source_dr=$(realpath $1)
    source_apk=$(realpath $2)
    if [[ $is_eu_rom == "true" ]]; then
       SMALI_COMMAND="java -jar bin/apktool/smali-3.0.5.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali-3.0.5.jar" 
    else
       SMALI_COMMAND="java -jar bin/apktool/smali.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali.jar"
    fi

    for classes_folder in $(find $source_dr -maxdepth 1 -type d -name "classes*");do
        classes=$(basename $classes_folder)
        ${SMALI_COMMAND} a --api ${port_android_sdk} $source_dr/${classes} -o $source_dr/${classes}.dex || error "Smaling failed"
    done

    pushd $source_dr >/dev/null || exit
    for classes_dex in $(find . -type f -name "*.dex"); do
        7z a -y -mx0 -tzip $(realpath $source_apk) $classes_dex >/dev/null || error "Failed to modify $source_apk"
    done
    popd >/dev/null || exit
    
    yellow "Fix $source_apk completed"
}

baksmali_wrapper() {
    if [[ $is_eu_rom == "true" ]]; then
       SMALI_COMMAND="java -jar bin/apktool/smali-3.0.5.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali-3.0.5.jar" 
    else
       SMALI_COMMAND="java -jar bin/apktool/smali.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali.jar"
    fi
    targetfilefullpath=$1
    if [ -f $targetfilefullpath ];then
        targetfilename=$(basename $targetfilefullpath)
        yellow "Modifying $targetfilename"
        foldername=${targetfilename%.*}
        rm -rf tmp/$foldername/
        mkdir -p tmp/$foldername/
        cp -rf $targetfilefullpath tmp/$foldername/
        cp tmp/$foldername/$foldername.apk tmp/$foldername/${foldername}_org.apk
        7z x -y tmp/$foldername/$targetfilename *.dex -otmp/$foldername >/dev/null
        for dexfile in tmp/$foldername/*.dex;do
            smalifname=${dexfile%.*}
            smalifname=$(echo $smalifname | cut -d "/" -f 3)
            ${BAKSMALI_COMMAND} d --api ${port_android_sdk} ${dexfile} -o tmp/$foldername/$smalifname 2>&1 || error "Baksmaling failed"
        done
    fi
}

fix_oldfaceunlock() {
    if [ ! -d tmp ]; then
        mkdir tmp
    fi
    blue "Fix FaceUnlock"
    SettingsAPK=$(find build/portrom/images/ -type f -name "Settings.apk" )
    baksmali_wrapper "$SettingsAPK"

    FaceUtilSmali=$(find tmp/Settings/ -type f -name "FaceUtils.smali")
    blue "Patching $FaceUtilSmali"
    sed -i '/^.method public static useOldFaceUnlock(Landroid\/content\/Context;)Z/,/^.end method/c\
    .method public static useOldFaceUnlock(Landroid\/content\/Context;)Z\
        .locals 1\
    \
        const-string v0, "com.oneplus.faceunlock"\
    \
        invoke-static {p0, v0}, Lcom\/oplus\/settings\/utils\/packages\/SettingsPackageUtils;->isPackageInstalled(Landroid\/content\/Context;Ljava\/lang\/String;)Z\
    \
        move-result p0\
    \
        return p0\
    .end method' "$FaceUtilSmali"

    CustomPkgConstantsSmali=$(find tmp/Settings/ -type f -name "CustomPkgConstants.smali")
    blue "Patching $CustomPkgConstantsSmali"
    sed -i 's/\.field public static final PACKAGE_FACEUNLOCK:Ljava\/lang\/String; = "unknown_pkg"/\.field public static final PACKAGE_FACEUNLOCK:Ljava\/lang\/String; = "com.oneplus.faceunlock"/' $CustomPkgConstantsSmali 
 
    for smali in $(find tmp/Settings/ -name "FaceSettings\$FaceSettingsFragment.smali" -o -name "OldFaceSettingsClient.smali" -o -name "OldFacePreferenceController.smali"); do
    blue "Patching $smali"
    sed -i "s/unknown_pkg/com\.oneplus\.faceunlock/g" "$smali" 
    done

    smali_wrapper "tmp/Settings" tmp/Settings/Settings.apk
    zipalign -p -f -v 4 tmp/Settings/Settings.apk $SettingsAPK  > /dev/null 2>&1

    SystemUIAPK=$(find build/portrom/images/ -type f -name "SystemUI.apk" )
    baksmali_wrapper $SystemUIAPK
    OpUtilsSmali=$(find tmp/SystemUI -type f -name "OpUtils.smali")
    python3 bin/patchmethod.py $OpUtilsSmali "isUseOpFacelock"

    MiniCapsuleManagerImplSmali=$(find tmp/SystemUI -type f -name "MiniCapsuleManagerImpl.smali")

    findCode='invoke-static {}, Lcom/oplus/systemui/minicapsule/utils/MiniCapsuleUtils;->getPinholeFrontCameraPosition()Ljava/lang/String;'

    # Get line number of findCode
    lineNum=$(grep -n "$findCode" "$MiniCapsuleManagerImplSmali" | cut -d ':' -f 1)

    # Find the first move-result-object after lineNum
    lineContent=$(tail -n +"$lineNum" "$MiniCapsuleManagerImplSmali" | grep -m 1 -n "move-result-object")
    lineNumEnd=$(echo "$lineContent" | cut -d ':' -f 1)
    register=$(echo "$lineContent" | awk '{print $3}')

    # Convert to absolute line number
    lineNumEnd=$((lineNum + lineNumEnd - 1))

    if [ -n "$lineNumEnd" ]; then
        replace="    const-string $register, \"484,36:654,101\""
        sed -i "${lineNum},${lineNumEnd}d" "$MiniCapsuleManagerImplSmali"
        sed -i "${lineNum}i\\${replace}" "$MiniCapsuleManagerImplSmali"
        echo "Patched $file successfully"
    else
        echo "No 'move-result-object' found after $findCode in $MiniCapsuleManagerImplSmali"
    fi

    smali_wrapper tmp/SystemUI tmp/SystemUI/SystemUI.apk
    zipalign -p -f -v 4 tmp/SystemUI/SystemUI.apk $SystemUIAPK  > /dev/null 2>&1
    apksigner sign -v --key otatools/key/testkey.pk8 --cert otatools/key/testkey.x509.pem  $SystemUIAPK
    apksigner verify -v  $SystemUIAPK
} 

patch_smartsidecar() {
    blue "Patching SmartSidebar APK"
    SmartSideBarAPK=$(find build/portrom/images/ -type f -name "SmartSideBar.apk" )
    baksmali_wrapper $SmartSideBarAPK
    RealmeUtilsSmali=$(find tmp/SmartSideBar -type f -name "RealmeUtils.smali")
    python3 bin/patchmethod.py $RealmeUtilsSmali "isRealmeBrand"
    smali_wrapper tmp/SmartSideBar tmp/SmartSideBar/SmartSideBar.apk
    zipalign -p -f -v 4 tmp/SmartSideBar/SmartSideBar.apk $SmartSideBarAPK > /dev/null 2>&1
    apksigner sign -v --key otatools/key/testkey.pk8 --cert otatools/key/testkey.x509.pem $SmartSideBarAPK
    apksigner verify -v $SmartSideBarAPK
}

convert_version_to_number() {
    local version="$1"
    IFS='.' read -ra parts <<< "$version"
    
    local major=${parts[0]:-0}
    local minor=${parts[1]:-0}
    local patch=${parts[2]:-0}
    
    # Numeric representation: major*10000 + minor*100 + patch
    echo $((major * 10000 + minor * 100 + patch))
}

get_oplusrom_version() {
    local max_version=""
    local max_version_number=0
    
    local prop_files=(
        "build/portrom/images/my_manifest/build.prop"
        "build/portrom/images/my_product/build.prop" 
    )
    
    # Scan candidates and return the highest version
    for prop_file in "${prop_files[@]}"; do
        if [[ -f "$prop_file" ]]; then
            local version_value=$(grep -E "^ro\.build\.version\.oplusrom\.display=" "$prop_file" 2>/dev/null | cut -d'=' -f2)
            if [[ -n "$version_value" ]]; then
                local clean_version=$(echo "$version_value" | sed 's/[^0-9.]//g')
                IFS='.' read -ra parts <<< "$clean_version"
                local version_number=$((${parts[0]:-0} * 10000 + ${parts[1]:-0} * 100 + ${parts[2]:-0}))
                
                if [[ $version_number -gt $max_version_number ]]; then
                    max_version_number=$version_number
                    max_version="$clean_version"
                fi
            fi
        fi
    done
    
    echo "$max_version"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  ColorOS CN Detection — Rapchick Engine                                  ║
# ║  Consolidated, fast, and reliable CN variant check                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# is_coloros_cn [build_prop_path]
# Returns 0 (true) only when:
#   • ro.rom.zone=cn  OR  fingerprint/display_id contains "CN"
#   • AND ro.com.google.clientidbase is NOT already present (no GApps yet)
is_coloros_cn() {
    local build_prop_path="${1:-build/portrom/images/my_manifest/build.prop}"

    if [[ ! -f "$build_prop_path" ]]; then
        yellow "⚠️  build.prop not found: $build_prop_path"
        return 1
    fi

    local rom_zone fingerprint build_display
    rom_zone=$(grep "^ro.rom.zone=" "$build_prop_path" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
    fingerprint=$(grep "^ro.build.fingerprint=" "$build_prop_path" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
    build_display=$(grep "^ro.build.display.id=" "$build_prop_path" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')

    local is_cn=false
    if [[ "$rom_zone" == "cn" ]] || [[ "$fingerprint" == *"CN"* ]] || [[ "$build_display" == *"CN"* ]]; then
        is_cn=true
    fi

    if [[ "$is_cn" == true ]]; then
        # Already has GApps → skip
        if ! grep -q "ro.com.google.clientidbase" "$build_prop_path" 2>/dev/null; then
            return 0  # Confirmed CN with no GApps
        fi
    fi
    return 1
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  GApps Validation                                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

validate_gapps_package() {
    local gapps_zip="${1:-}"

    blue "🔍 Validating GApps package structure..."

    if [[ -z "$gapps_zip" ]] || [[ ! -f "$gapps_zip" ]]; then
        error "❌ GApps ZIP file not found: $gapps_zip"
        error "   ColorOS CN ROMs do NOT include Google Apps"
        error "   Download GApps from: https://mindthegapps.com  OR  https://opengapps.org"
        return 1
    fi

    mkdir -p tmp/gapps_validate
    unzip -l "$gapps_zip" > tmp/gapps_validate/manifest.txt 2>/dev/null || {
        error "❌ Failed to read GApps ZIP structure"
        return 1
    }

    local has_partition=false
    for part in system my_product product system_ext; do
        if grep -q "^.*${part}/" tmp/gapps_validate/manifest.txt; then
            has_partition=true
            blue "  ✓ Found ${part} partition files"
        fi
    done

    if grep -q "com\.google\.android\.gms\|com\.android\.vending" tmp/gapps_validate/manifest.txt; then
        blue "  ✓ Found Google Play Services (GMS)"
    else
        yellow "  ⚠️  Warning: Google Play Services not detected in GApps package"
    fi

    rm -rf tmp/gapps_validate

    if [[ "$has_partition" == true ]]; then
        green "✅ GApps package structure validated"
        return 0
    else
        error "❌ GApps package structure not recognized"
        return 1
    fi
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  GApps Installation — multi-partition aware                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

install_google_apps() {
    local gapps_zip="${1:-}"
    local target_dir="build/portrom/images"
    # Resolve actual system root (handles system/ vs system/system layouts)
    local system_root="$target_dir/system"
    if [[ -d "$target_dir/system/system" ]] || [[ -f "$target_dir/system/system/build.prop" ]]; then
        system_root="$target_dir/system/system"
    fi

    blue "🔵 ━━━ Google Apps Installation Module ━━━"
    blue "ℹ️  ColorOS CN ROMs do NOT include Google Apps"

    if ! validate_gapps_package "$gapps_zip"; then
        error "❌ Invalid or missing GApps package"
        error "   Usage: install_google_apps '/path/to/gapps_package.zip'"
        error ""
        error "📥 Download GApps from:"
        error "   1. MindTheGapps: https://mindthegapps.com"
        error "   2. OpenGApps: https://opengapps.org"
        error "   3. Select: arm64, Android 13-16 (depending on your ROM)"
        return 1
    fi

    blue "📥 Extracting GApps package: $gapps_zip"
    mkdir -p tmp/gapps_extract
    unzip -o "$gapps_zip" -d tmp/gapps_extract || {
        error "Failed to extract GApps ZIP"
        rm -rf tmp/gapps_extract
        return 1
    }

    local gapps_applied=false
    local gapps_root="tmp/gapps_extract"
    local mtg_root=""

    # MindTheGapps layout keeps all partitions under system/ (e.g. system/product, system/system_ext).
    if [[ -d "$gapps_root/system/product" ]] || [[ -d "$gapps_root/system/system_ext" ]] || [[ -d "$gapps_root/system/my_product" ]]; then
        mtg_root="$gapps_root/system"
    fi

    _apply_gapps_partition() {
        local part_name="$1"
        local src_path="$2"
        local dst_path="$3"

        [[ -d "$src_path" ]] || return 1

        blue "📂 Copying GApps from ${part_name} partition..."
        mkdir -p "$dst_path"
        cp -rf "$src_path"/. "$dst_path"/ 2>/dev/null || true
        gapps_applied=true
        green "  ✓ ${part_name} partition applied"
        return 0
    }

    local system_applied=false

    if [[ -n "$mtg_root" ]]; then
        # Handle nested system payload if present: system/system -> real system partition.
        if _apply_gapps_partition "system" "$mtg_root/system" "$system_root"; then
            system_applied=true
        else
            # Some packages place system files directly in system/; exclude nested partition dirs.
            local copied_any=false
            blue "📂 Copying GApps from system partition..."
            mkdir -p "$system_root"
            shopt -s nullglob dotglob
            for entry in "$mtg_root"/*; do
                local entry_name
                entry_name=$(basename "$entry")
                case "$entry_name" in
                    product|system_ext|my_product|vendor|odm)
                        continue
                        ;;
                esac
                cp -rf "$entry" "$system_root"/ 2>/dev/null || true
                copied_any=true
            done
            shopt -u nullglob dotglob

            if [[ "$copied_any" == true ]]; then
                gapps_applied=true
                system_applied=true
                green "  ✓ system partition applied"
            fi
        fi

        _apply_gapps_partition "product" "$mtg_root/product" "$target_dir/product" || true
        _apply_gapps_partition "system_ext" "$mtg_root/system_ext" "$target_dir/system_ext" || true
        _apply_gapps_partition "my_product" "$mtg_root/my_product" "$target_dir/my_product" || true
    fi

    for part in system my_product product system_ext; do
        local src_dir=""
        # Fallback for traditional multi-partition layouts.
        case "$part" in
            system)
                [[ "$system_applied" == true ]] && continue
                if [[ -d "$gapps_root/system/system" ]]; then
                    src_dir="$gapps_root/system/system"
                elif [[ -d "$gapps_root/system" ]] && [[ -z "$mtg_root" ]]; then
                    src_dir="$gapps_root/system"
                elif [[ -d "$gapps_root/system" ]]; then
                    src_dir="$gapps_root/system"
                fi
                ;;
            *)
                if [[ -d "$gapps_root/$part" ]]; then
                    src_dir="$gapps_root/$part"
                fi
                ;;
        esac

        if [[ -n "$src_dir" ]]; then
            local dst_dir="$target_dir/$part"
            [[ "$part" == "system" ]] && dst_dir="$system_root"
            _apply_gapps_partition "$part" "$src_dir" "$dst_dir" || true
        fi
    done

    unset -f _apply_gapps_partition 2>/dev/null || true

    rm -rf tmp/gapps_extract

    if [[ "$gapps_applied" == false ]]; then
        error "❌ No GApps files found in package"
        return 1
    fi

    green "✅ Google Apps successfully integrated into ROM"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  MindTheGapps Auto-Downloader — per-version repo layout                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

download_mindthegapps() {
    local android_version="${1:-13}"
    local output_file="${2:-tmp/MindTheGapps.zip}"

    blue "🌐 MindTheGapps Auto-Downloader"
    blue "📥 Downloading MindTheGapps for Android $android_version (arm64)..."

    mkdir -p "$(dirname "$output_file")"

    case "$android_version" in
        13|14|15|16) ;;
        *)
            yellow "⚠️  Unsupported Android version: $android_version"
            blue "   Supported: 13, 14, 15, 16"
            return 1
            ;;
    esac

    local github_repo="MindTheGapps/${android_version}.0.0-arm64"
    local api_url="https://api.github.com/repos/${github_repo}/releases/latest"

    blue "   Fetching latest release info: ${api_url}"

    local download_url="" api_response=""
    if command -v curl &>/dev/null; then
        api_response=$(curl -fsSL --retry 3 "$api_url" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        api_response=$(wget -q -O - "$api_url" 2>/dev/null)
    else
        error "❌ Neither curl nor wget found — cannot download MindTheGapps"
        return 1
    fi

    if [[ -z "$api_response" ]]; then
        error "❌ GitHub API returned empty response for ${github_repo}"
        error "   Check network access or try: https://github.com/${github_repo}/releases"
        return 1
    fi

    download_url=$(printf '%s' "$api_response" \
        | grep -o '"browser_download_url": *"[^"]*\.zip"' \
        | head -1 \
        | grep -o 'https://[^"]*')

    if [[ -z "$download_url" ]]; then
        error "❌ Could not parse download URL from GitHub API response"
        error "   Repo: https://github.com/${github_repo}/releases"
        error "   Place the zip manually at: $output_file"
        return 1
    fi

    blue "   URL: $download_url"

    if command -v curl &>/dev/null; then
        curl -L --retry 3 --retry-delay 3 --connect-timeout 20 \
             -o "$output_file" "$download_url" --progress-bar || {
            error "❌ curl download failed"
            rm -f "$output_file"
            return 1
        }
    else
        wget -O "$output_file" -c --show-progress "$download_url" || {
            error "❌ wget download failed"
            rm -f "$output_file"
            return 1
        }
    fi

    # Verify: file must exist, be non-empty, and pass zip integrity check
    if [[ ! -s "$output_file" ]]; then
        error "❌ Downloaded file is empty or missing: $output_file"
        rm -f "$output_file"
        return 1
    fi
    if ! unzip -t "$output_file" &>/dev/null; then
        error "❌ Downloaded file failed zip integrity check — likely a partial download"
        rm -f "$output_file"
        return 1
    fi

    local file_size
    file_size=$(du -h "$output_file" | cut -f1)
    green "✅ MindTheGapps downloaded and verified: $output_file ($file_size)"
    return 0
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Google Play Services Configuration                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

configure_google_play_services() {
    local android_version="${1:-13}"
    blue "🔌 Configuring Google Play Services (Android ${android_version})..."

    local gapps_prop="build/portrom/images/my_product/etc/bruce/build.prop"
    mkdir -p "$(dirname "$gapps_prop")"

    local gms_ver="${android_version}_$(date +%Y%m)"

    cat >> "$gapps_prop" << EOF

# ━━━ Google Play Services Configuration ━━━
# Required for GApps functionality in ColorOS CN — Rapchick Engine
ro.com.google.clientidbase=android-oppo
ro.com.android.dataroaming=true
ro.com.android.dateformat=MM-dd-yyyy
ro.setupwizard.enterprise_mode=1
ro.com.google.gwsdisabled=0

# Google Play Store & Account
ro.com.google.gmsversion=${gms_ver}
ro.com.android.vending.api_version=11

# Location Services
ro.com.google.location.work=true

# Crash Reporting
ro.setupwizard.show_repair_option=false
ro.error.receiver.default=com.google.android.feedback.ErrorReceiver

# USB & Setup
persist.sys.usb.config=mtp,adb
ro.setupwizard.network_required=false

EOF

    green "✅ Google Play Services configured (gmsversion=${gms_ver})"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  GApps Presence Verification                                              ║
# ║  Returns 0 if both GmsCore and Phonesky are present in the image         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

verify_gapps_presence() {
    local has_core=false has_store=false

    # GmsCore search paths — MindTheGapps, OpenGApps, and custom layouts all use different dirs
    for d in \
        "build/portrom/images/system/system/priv-app/GmsCore" \
        "build/portrom/images/system/system/priv-app/PrebuiltGmsCore" \
        "build/portrom/images/product/priv-app/GmsCore" \
        "build/portrom/images/my_product/priv-app/GmsCore"; do
        [[ -d "$d" ]] && { has_core=true; break; }
    done

    # Phonesky (Play Store) search paths
    for d in \
        "build/portrom/images/system/system/priv-app/Phonesky" \
        "build/portrom/images/system/system/app/Phonesky" \
        "build/portrom/images/product/priv-app/Phonesky" \
        "build/portrom/images/product/app/Phonesky" \
        "build/portrom/images/my_product/priv-app/Phonesky"; do
        [[ -d "$d" ]] && { has_store=true; break; }
    done

    [[ "$has_core" == true && "$has_store" == true ]]
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Auto-Download + Install GApps for ColorOS CN                            ║
# ║  Retries once on failure, hard-exits on second failure                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

auto_download_gapps_for_coscn() {
    local build_prop_path="${1:-build/portrom/images/my_manifest/build.prop}"
    local android_version="${2:-13}"
    local gapps_output="${3:-tmp/MindTheGapps_auto.zip}"

    blue "🔍 Checking if port ROM is ColorOS CN..."

    if is_coloros_cn "$build_prop_path"; then
        blue "✅ Detected ColorOS CN ROM (missing Google Apps)"
        blue "📥 Auto-downloading MindTheGapps for Android $android_version..."

        if download_mindthegapps "$android_version" "$gapps_output"; then
            blue "✅ GApps download successful: $gapps_output"
            blue "📱 Installing Google Apps into ROM..."

            if install_google_apps "$gapps_output"; then
                # Configure Play Services props
                configure_google_play_services "$android_version"
                green "✅ Google Apps automatically integrated for ColorOS CN"
                return 0
            else
                error "❌ Failed to install GApps"
                return 1
            fi
        else
            error "❌ Failed to auto-download GApps"
            return 1
        fi
    else
        blue "ℹ️  Port ROM appears to be global variant (already has Google Apps)"
        blue "   Skipping GApps installation"
        return 0
    fi
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  3D Wallpaper Integration — ColorOS CN Feature                           ║
# ║  FIXED: stash wallpaper overlays BEFORE res wipe, not after              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Call this BEFORE "rm -rf build/portrom/images/my_product/res/*" in port.sh
# to preserve 3D/live wallpaper overlay APKs that would otherwise be lost.
stash_portrom_wallpaper_overlays() {
    [[ "${baseIsColorOSCN}" != true ]] && return 0

    blue "💾 3D wallpaper: stashing portrom overlays before res wipe..."

    rm -rf tmp/portrom_wallpaper_res_backup
    mkdir -p tmp/portrom_wallpaper_res_backup

    # Save every overlay APK whose name contains 'wallpaper' (case-insensitive)
    local stashed=0
    while IFS= read -r f; do
        cp -rf "${f}" tmp/portrom_wallpaper_res_backup/
        ((stashed++)) || true
    done < <(find build/portrom/images/my_product/res/ -maxdepth 1 \
        \( -iname "*wallpaper*" -o -iname "*Wallpapers*" -o -iname "*WallpaperStyle*" \) 2>/dev/null)

    # Stash 3D media asset directories
    rm -rf tmp/portrom_wallpaper_media_backup
    mkdir -p tmp/portrom_wallpaper_media_backup
    for media_dir in \
        "build/portrom/images/my_product/media/wallpaper3d" \
        "build/portrom/images/my_product/media/wallpaper_3d" \
        "build/portrom/images/my_product/media/live_wallpaper_res" \
        "build/portrom/images/my_product/media/livewallpaper" \
        "build/portrom/images/my_product/media/wallpapers"; do
        if [[ -d "${media_dir}" ]]; then
            cp -rf "${media_dir}" tmp/portrom_wallpaper_media_backup/
        fi
    done

    # Stash WallpaperPicker / WallpaperStyle APKs from app/priv-app dirs
    rm -rf tmp/portrom_wallpaper_apk_backup
    mkdir -p tmp/portrom_wallpaper_apk_backup
    while IFS= read -r apk_dir; do
        local pkg_name
        pkg_name=$(basename "$apk_dir")
        cp -rf "$apk_dir" tmp/portrom_wallpaper_apk_backup/
    done < <(find build/portrom/images/my_product/ -maxdepth 3 -type d \
        \( -iname "*WallpaperPicker*" -o -iname "*WallpaperStyle*" \
           -o -iname "*com.oplus.wallpapers*" -o -iname "*com.coloros.wallpaper*" \
           -o -iname "*com.oplus.theme.wallpaper3d*" \) 2>/dev/null | head -20)

    green "3D wallpaper: stashed ${stashed} overlay APK(s) + media dirs + wallpaper packages"
}

# Call this AFTER "cp -rf build/baserom/images/my_product/res/* ..." in port.sh
# to restore 3D/live wallpaper overlays over the CN base res.
restore_portrom_wallpaper_overlays() {
    [[ "${baseIsColorOSCN}" != true ]] && return 0

    blue "♻️  3D wallpaper: restoring portrom overlays over CN res..."

    # Restore overlay APKs into res/
    if [[ -d tmp/portrom_wallpaper_res_backup ]] && \
       [[ -n "$(ls -A tmp/portrom_wallpaper_res_backup 2>/dev/null)" ]]; then
        cp -rf tmp/portrom_wallpaper_res_backup/* \
            build/portrom/images/my_product/res/
        local cnt
        cnt=$(ls tmp/portrom_wallpaper_res_backup | wc -l)
        green "3D wallpaper: restored ${cnt} overlay APK(s) into res/"
    fi

    # Restore media asset dirs
    if [[ -d tmp/portrom_wallpaper_media_backup ]] && \
       [[ -n "$(ls -A tmp/portrom_wallpaper_media_backup 2>/dev/null)" ]]; then
        cp -rf tmp/portrom_wallpaper_media_backup/* \
            build/portrom/images/my_product/media/
        green "3D wallpaper: restored media asset dirs"
    fi

    # Restore wallpaper APK packages
    if [[ -d tmp/portrom_wallpaper_apk_backup ]] && \
       [[ -n "$(ls -A tmp/portrom_wallpaper_apk_backup 2>/dev/null)" ]]; then
        cp -rf tmp/portrom_wallpaper_apk_backup/* \
            build/portrom/images/my_product/app/ 2>/dev/null || true
        green "3D wallpaper: restored wallpaper packages"
    fi

    # ── Ensure wallpaper feature flags are set for CN base ports ─────────────
    # Single-quoted strings prevent shell expansion of inner quotes
    add_feature_v2 app_feature \
        'com.oplus.wallpapers.support_3d_wallpaper^^args="boolean:true"' \
        'com.oplus.wallpapers.download_3d_wallpaper^^args="boolean:true"' \
        'com.oplus.wallpapers.3d_wallpaper_support^^args="boolean:true"' \
        'com.oplus.wallpapers.support_live_wallpaper^^args="boolean:true"' \
        'com.oplus.wallpapers.live_wallpaper_download^^args="boolean:true"' \
        'os.personalization.wallpaper.live.ripple.enable^^args="boolean:true"' \
        'com.android.wallpaper.picker.live_wallpaper_support^^args="boolean:true"' \
        'com.oplus.theme.wallpaper_style_enable^^args="boolean:true"' \
        'com.oplus.wallpapers.wallpaper_style_support^^args="boolean:true"' \
        'com.oplus.wallpapers.ai_camera_movement^^args="boolean:true"' \
        'com.oplus.wallpapers.livephoto_wallpaper^^args="boolean:true"' \
        'com.oplus.wallpapers.livephoto_wallpaper_support_hdr^^args="boolean:true"' \
        'com.oplus.wallpapers.livephoto_wallpaper_support_4k^^args="boolean:true"'

    add_feature_v2 oplus_feature \
        "oplus.software.wallpaper.3d_wallpaper_support" \
        "oplus.software.wallpaper.live_wallpaper_support" \
        "oplus.software.wallpaper.wallpaper_style_support"

    # ── System props for wallpaper rendering ─────────────────────────────────
    local wp_prop="build/portrom/images/my_product/etc/bruce/build.prop"
    mkdir -p "$(dirname "$wp_prop")"
    {
        echo ""
        echo "# ━━━ 3D Wallpaper / Wallpapers & Style (ColorOS CN port) ━━━"
        echo "ro.oplus.wallpaper.3d.enabled=true"
        echo "ro.oplus.wallpaper.3d.support=true"
        echo "ro.livewallpaper.dynamic.support=true"
        echo "ro.oplus.livewallpaper.support=true"
        echo "ro.oplus.wallpaper.parallax.support=true"
        echo "ro.oplus.wallpaper.dark_mode.support=true"
        echo "ro.oplus.wallpaper.provider=com.coloros.wallpaper"
        echo "ro.oplus.wallpaper.render.quality=high"
        echo "persist.sys.wallpaper.parallax=1"
    } >> "$wp_prop"

    green "✅ 3D wallpaper integration complete (overlays + media + flags + props)"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Full 3D Wallpaper Port (legacy all-in-one, kept for compatibility)      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

port_3d_wallpapers_full() {
    blue "╔════════════════════════════════════════════════════════╗"
    blue "║   3D Wallpaper Full Porting Module (ColorOS CN)       ║"
    blue "╚════════════════════════════════════════════════════════╝"

    local target_dir="build/portrom/images"
    local app_dir="$target_dir/my_product/app"
    local base_wallpaper_dir="build/baserom/images/my_product/app"
    mkdir -p "$app_dir"

    # Copy wallpaper packages from base if missing from port
    local wallpaper_packages=(
        "com.oplus.theme.wallpaper3d"
        "com.coloros.wallpaper"
        "com.oplus.wallpaper"
        "com.oplus.wallpaper.livewallpaper"
        "com.oplus.wallpaperservice"
        "com.oppo.theme"
        "com.android.wallpaper.livepicker"
    )

    blue "🎨 Verifying 3D wallpaper packages..."
    for pkg in "${wallpaper_packages[@]}"; do
        local port_pkg base_pkg
        port_pkg=$(find "$app_dir" -maxdepth 1 -type d -name "$pkg" 2>/dev/null | head -1)
        base_pkg=$(find "$base_wallpaper_dir" -maxdepth 1 -type d -name "$pkg" 2>/dev/null | head -1)

        if [[ -d "$port_pkg" ]]; then
            blue "  ✓ Present in port ROM: $pkg"
        elif [[ -d "$base_pkg" ]]; then
            blue "  ↺ Copying fallback from base: $pkg"
            cp -rf "$base_pkg" "$app_dir/" || true
        else
            yellow "  ⊘ Not found: $pkg"
        fi
    done

    # Now call restore to set feature flags and props
    restore_portrom_wallpaper_overlays

    green "╔════════════════════════════════════════════════════════╗"
    green "║   ✅ 3D Wallpaper Integration Complete!              ║"
    green "╚════════════════════════════════════════════════════════╝"
}

trap 'error "Script interrupted! Exiting to prevent accidental deletion." ; exit 1' SIGINT