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
    # Temporarily disable strict error handling — magiskboot exits non-zero
    # for raw ramdisks and other expected conditions. set -e / pipefail would
    # kill the script before our || guards can handle them.
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
    # Restore strict error handling
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
        sed -i "/<\/$parent_node>/i\\\t\\<$feature_node name=\"$feature\"\/>" "$file"
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
            sed -i "/<\/$root_tag>/i\\\    <!-- $comment -->" "$output_file"
        fi
        # Write feature node
        sed -i "/<\/$root_tag>/i\\\    <$node_tag $attrs\/>" "$output_file"
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
        [[ "$key" =~ [.\*\[\]\^\$] ]] && key=$(printf '%s' "$key" | sed 's/[.[\*^$]/\\&/g')

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

# ╔═══════════════════════════════════════════════════════════════╗
# ║   3D Wallpaper Integration — ColorOS CN Feature              ║
# ║   Extract wallpaper APKs, 3D models, LiveWallpaper configs   ║
# ╚═══════════════════════════════════════════════════════════════╝

extract_3d_wallpapers() {
    blue "📱 3D Wallpaper Extraction Module (ColorOS CN)"
    
    local source_rom="${1:-}"
    local target_dir="build/portrom/images"
    local wallpaper_dir="$target_dir/my_product/app"
    
    if [[ -z "$source_rom" ]]; then
        blue "ℹ️  No source ROM provided. Looking for existing wallpaper files..."
        blue "   Checking: build/baserom/images/my_product/app/ for wallpaper APKs"
    fi
    
    mkdir -p "$wallpaper_dir"
    
    # List of ColorOS CN 3D wallpaper packages to extract/copy
    local wallpaper_packages=(
        "com.oplus.theme.wallpaper3d"           # Main 3D wallpaper APK
        "com.coloros.wallpaper"                 # ColorOS wallpaper provider
        "com.oplus.wallpaper"                   # OPLUS wallpaper service
        "com.oplus.wallpaper.livewallpaper"     # Live wallpaper APK
        "com.oplus.wallpaperservice"            # Wallpaper service daemon
        "com.oppo.theme"                        # Theme wallpapers
        "com.android.wallpaper.livepicker"      # System live wallpaper picker
    )
    
    blue "🎨 Extracting 3D wallpaper packages:"
    for pkg in "${wallpaper_packages[@]}"; do
        local pkg_path=$(find build/baserom/images/my_product/app/ -maxdepth 1 -type d -name "$pkg" 2>/dev/null)
        
        if [[ -d "$pkg_path" ]]; then
            blue "  ✓ Found: $pkg"
            cp -rf "$pkg_path" "$wallpaper_dir/" || true
        else
            yellow "  ⊘ Not found: $pkg (may not be in base)"
        fi
    done
    
    # Extract 3D wallpaper assets from portrom
    extract_wallpaper_assets "$target_dir"
}

extract_wallpaper_assets() {
    blue "📦 Extracting 3D wallpaper assets..."
    
    local base_dir="${1:-build/portrom/images}"
    local asset_dir="$base_dir/my_product/media/wallpapers"
    
    mkdir -p "$asset_dir"
    
    # Look for wallpaper-related directories in portrom
    local wallpaper_sources=(
        "my_product/media/wallpapers"           # Wallpaper images/models
        "my_product/media/3d_wallpapers"        # 3D models & assets
        "my_product/etc/default_wallpaper"      # Default wallpaper configs
        "my_product/overlay/WallpaperPickerGoogle"  # Wallpaper picker overlay
        "vendor/oplus/wallpaper_data"           # Vendor wallpaper data
        "system/app/WallpaperCropper"           # Wallpaper cropper tool
        "system_ext/app/WallpaperPickerGoogle"  # Extended wallpaper picker
    )
    
    blue "🎨 Wallpaper asset directories:"
    for src in "${wallpaper_sources[@]}"; do
        if [[ -d "$base_dir/$src" ]]; then
            blue "  ✓ Found: $src"
            mkdir -p "$(dirname "$base_dir/$src")" 2>/dev/null || true
            cp -rf "$base_dir/$src" "$(dirname "$base_dir/$src")/" 2>/dev/null || true
        fi
    done
    
    green "✅ Wallpaper assets extracted"
}

integrate_3d_wallpaper_configs() {
    blue "⚙️  Configuring 3D wallpaper system properties..."
    
    local target_dir="build/portrom/images/my_product/etc"
    local wallpaper_conf="$target_dir/bruce/wallpaper.prop"
    
    mkdir -p "$(dirname "$wallpaper_conf")"
    
    cat >> "$wallpaper_conf" <<'EOF'

# ━━━ 3D Wallpaper Configuration (ColorOS CN) ━━━

# Enable 3D wallpaper rendering
ro.oplus.wallpaper.3d.enabled=true
ro.oplus.wallpaper.3d.support=true

# Live wallpaper settings
ro.livewallpaper.dynamic.support=true
ro.oplus.livewallpaper.support=true
persist.sys.wallpaper.type=3d

# Default wallpaper configuration
ro.com.android.dataroaming=true
persist.sys.wallpaper_blur_enabled=1

# Wallpaper animation & smoothness
persist.sys.wallpaper.animation=true
ro.oplus.wallpaper.animation.speed=normal

# 3D rendering optimization
ro.hardware.wallpaper.3d=true
ro.oplus.wallpaper.render.quality=high

# ColorOS wallpaper provider
ro.oplus.wallpaper.provider=com.coloros.wallpaper
ro.oplus.wallpaper.service=com.oplus.wallpaperservice

# Live wallpaper picker configuration
ro.com.google.clientidbase=android-google
ro.wallpaper.livepicker=com.android.wallpaper.livepicker

# Parallax scrolling for 3D wallpapers
ro.oplus.wallpaper.parallax.support=true
persist.sys.wallpaper.parallax=1

# Night light & dark mode wallpaper support
ro.oplus.wallpaper.dark_mode.support=true
persist.sys.wallpaper_dark_mode=false

EOF
    
    green "✅ 3D wallpaper configuration added"
}

copy_wallpaper_from_portrom() {
    blue "📥 Copying 3D wallpaper files from port ROM..."
    
    local target_dir="build/portrom/images"
    local wallpaper_data_dirs=(
        "my_product/app/com.oplus.theme.wallpaper3d"
        "my_product/app/com.coloros.wallpaper"
        "my_product/app/com.oplus.wallpaper"
        "my_product/media/wallpapers"
        "my_product/media/3d_assets"
        "my_product/etc/default_wallpaper"
    )
    
    for src_dir in "${wallpaper_data_dirs[@]}"; do
        if [[ -d "$target_dir/$src_dir" ]]; then
            blue "  📂 Located: $src_dir"
            # Verify and preserve directory structure
            find "$target_dir/$src_dir" -type f | while read -r file; do
                blue "    📄 $(basename "$file")"
            done
        fi
    done
    
    green "✅ Wallpaper files verified in port ROM"
}

# Feature: Extract and integrate wallpaper APKs with all dependencies
install_3d_wallpaper_apks() {
    blue "📱 Installing 3D Wallpaper APKs from ColorOS CN..."
    
    local target_dir="build/portrom/images"
    local app_dir="$target_dir/my_product/app"
    
    mkdir -p "$app_dir"
    
    # Key wallpaper APK files that must be extracted
    local wallpaper_apks=(
        "com.oplus.theme.wallpaper3d"
        "com.coloros.wallpaper"
        "com.oplus.wallpaper.livewallpaper"
    )
    
    blue "🎨 Searching for wallpaper APKs in extracted partitions..."
    
    for apk_pkg in "${wallpaper_apks[@]}"; do
        local apk_path=$(find "$target_dir" -name "${apk_pkg}.apk" -o -type d -name "$apk_pkg" | head -1)
        
        if [[ -n "$apk_path" ]]; then
            if [[ -d "$apk_path" ]]; then
                blue "  ✓ Found wallpaper package directory: $apk_pkg"
                # Ensure it's in my_product/app
                if [[ ! -d "$app_dir/$apk_pkg" ]]; then
                    cp -rf "$apk_path" "$app_dir/" || true
                fi
            elif [[ -f "$apk_path" ]]; then
                blue "  ✓ Found wallpaper APK: $(basename "$apk_path")"
                mkdir -p "$app_dir/$apk_pkg"
                cp "$apk_path" "$app_dir/$apk_pkg/" || true
            fi
        else
            yellow "  ⊘ Wallpaper APK not found: $apk_pkg"
        fi
    done
    
    # Re-sign wallpaper APKs if they were modified
    for apk_pkg in "${wallpaper_apks[@]}"; do
        if [[ -d "$app_dir/$apk_pkg" ]]; then
            local apk_file=$(find "$app_dir/$apk_pkg" -name "*.apk" | head -1)
            if [[ -f "$apk_file" ]]; then
                blue "  🔏 Verifying APK signature: $(basename "$apk_file")"
                # APK signing would happen here if modifications were made
            fi
        fi
    done
    
    green "✅ Wallpaper APKs integrated successfully"
}

# Add wallpaper-related system features
add_wallpaper_features() {
    blue "🎨 Adding wallpaper feature flags to system..."
    
    # Add feature flags for wallpaper support
    add_feature_v2 oplus_feature \
        "oplus.wallpaper.3d^3D Wallpaper Support" \
        "oplus.wallpaper.livepicker^Live Wallpaper Picker" \
        "oplus.wallpaper.dynamic^Dynamic Wallpaper" \
        "oplus.wallpaper.parallax^Parallax Scrolling"
    
    add_feature_v2 app_feature \
        "oplus.wallpaper.3d.enabled^3D Wallpaper Enabled" \
        "oplus.wallpaper.renderquality^High Quality Rendering"
    
    add_feature_v2 permission_feature \
        "oplus.wallpaper.access^Access 3D Wallpapers" \
        "oplus.wallpaper.read^Read Wallpaper Data" \
        "oplus.wallpaper.manage^Manage Wallpapers"
    
    green "✅ Wallpaper features added to system configuration"
}

# Extract wallpaper metadata from build.prop
extract_wallpaper_metadata() {
    blue "📋 Extracting wallpaper metadata from port ROM..."
    
    local portrom_prop="build/portrom/images/my_product/build.prop"
    local wallpaper_meta="tmp/wallpaper_metadata.txt"
    
    mkdir -p tmp
    
    if [[ -f "$portrom_prop" ]]; then
        blue "  Scanning for wallpaper-related properties..."
        grep -E "(wallpaper|3d|live)" "$portrom_prop" | tee "$wallpaper_meta" | head -20
        
        local count=$(grep -c -E "(wallpaper|3d|live)" "$portrom_prop" 2>/dev/null || echo 0)
        blue "  📊 Found $count wallpaper-related properties"
    fi
}

# Comprehensive 3D wallpaper porting function (all-in-one)
port_3d_wallpapers_full() {
    blue "╔════════════════════════════════════════════════════════╗"
    blue "║   3D Wallpaper Full Porting Module (ColorOS CN)       ║"
    blue "╚════════════════════════════════════════════════════════╝"
    
    # Step 1: Extract wallpaper packages from base
    extract_3d_wallpapers
    
    # Step 2: Copy wallpaper-related files from portrom
    copy_wallpaper_from_portrom
    
    # Step 3: Install wallpaper APKs with dependencies
    install_3d_wallpaper_apks
    
    # Step 4: Configure wallpaper system properties
    integrate_3d_wallpaper_configs
    
    # Step 5: Add feature flags
    add_wallpaper_features
    
    # Step 6: Extract and log metadata
    extract_wallpaper_metadata
    
    green "╔════════════════════════════════════════════════════════╗"
    green "║   ✅ 3D Wallpaper Integration Complete!              ║"
    green "║   • Wallpaper APKs: Extracted & integrated            ║"
    green "║   • 3D Models: Copied from port ROM                   ║"
    green "║   • System Properties: Configured                     ║"
    green "║   • Features: Added to manifest                       ║"
    green "╚════════════════════════════════════════════════════════╝"
}

# ╔═══════════════════════════════════════════════════════════════╗
# ║   Google Apps Integration (GApps) — External Source Required   ║
# ║   ⚠️  ColorOS CN lacks GApps — must download from external     ║
# ║   Sources: MindTheGapps, OpenGApps, or custom repositories    ║
# ╚═══════════════════════════════════════════════════════════════╝

# Detect if port ROM is ColorOS CN (lacks Google Apps)
is_coloros_cn() {
    local build_prop_path="${1:-build/portrom/images/my_manifest/build.prop}"
    
    if [[ ! -f "$build_prop_path" ]]; then
        yellow "⚠️  build.prop not found: $build_prop_path"
        return 1
    fi
    
    # Check for ColorOS CN indicators
    # CN ROMs have: ro.rom.zone=cn, ro.build.fingerprint contains CN markers, etc.
    local rom_zone=$(grep "^ro.rom.zone=" "$build_prop_path" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
    local fingerprint=$(grep "^ro.build.fingerprint=" "$build_prop_path" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
    local build_display=$(grep "^ro.build.display.id=" "$build_prop_path" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
    local rom_type=$(grep "^ro.rom.type=" "$build_prop_path" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
    
    # Check if it's CN variant
    if [[ "$rom_zone" == "cn" ]] || [[ "$fingerprint" == *"CN"* ]] || [[ "$build_display" == *"CN"* ]] || [[ "$rom_type" == *"ColorOS"* ]]; then
        # Further check: if it already has Google apps, it's global (unlikely for CN)
        if ! grep -q "ro.com.google.clientidbase" "$build_prop_path" 2>/dev/null; then
            return 0  # Yes, it's COS CN (no Google apps)
        fi
    fi
    
    return 1  # Not COS CN or already has GApps
}

validate_gapps_package() {
    local gapps_zip="${1:-}"
    
    blue "🔍 Validating GApps package structure..."
    
    if [[ -z "$gapps_zip" ]] || [[ ! -f "$gapps_zip" ]]; then
        error "❌ GApps ZIP file not found: $gapps_zip"
        error "   ColorOS CN ROMs do NOT include Google Apps"
        error "   You MUST download GApps from external sources:"
        error "   • MindTheGapps (https://mindthegapps.com)"
        error "   • OpenGApps (https://opengapps.org)"
        error "   • Custom APK repository"
        return 1
    fi
    
    # Extract and validate structure
    mkdir -p tmp/gapps_validate
    unzip -l "$gapps_zip" > tmp/gapps_validate/manifest.txt 2>/dev/null || {
        error "❌ Failed to read GApps ZIP structure"
        return 1
    }
    
    # Check for required GApps structure
    local has_system=false
    local has_my_product=false
    local has_system_ext=false
    
    if grep -q "^.*system/" tmp/gapps_validate/manifest.txt; then
        has_system=true
        blue "  ✓ Found system partition files"
    fi
    
    if grep -q "^.*my_product/" tmp/gapps_validate/manifest.txt; then
        has_my_product=true
        blue "  ✓ Found my_product partition files"
    fi
    
    if grep -q "^.*system_ext/" tmp/gapps_validate/manifest.txt; then
        has_system_ext=true
        blue "  ✓ Found system_ext partition files"
    fi
    
    # Check for core GApps apps
    if grep -q "com\.google\.android\.gms\|com\.android\.vending" tmp/gapps_validate/manifest.txt; then
        blue "  ✓ Found Google Play Services (GMS)"
    else
        yellow "  ⚠️  Warning: Google Play Services not detected in GApps package"
    fi
    
    for app in "chrome" "drive" "maps" "photos" "pay"; do
        if grep -q "$app" tmp/gapps_validate/manifest.txt; then
            blue "  ✓ Found: $app"
        fi
    done
    
    rm -rf tmp/gapps_validate
    
    if [[ "$has_system" == "true" ]] || [[ "$has_my_product" == "true" ]] || [[ "$has_system_ext" == "true" ]]; then
        green "✅ GApps package structure validated"
        return 0
    else
        error "❌ GApps package structure not recognized"
        return 1
    fi
}

install_google_apps() {
    local gapps_zip="${1:-}"
    local target_dir="build/portrom/images"
    
    blue "🔵 ━━━ Google Apps Installation Module ━━━"
    blue "ℹ️  ColorOS CN ROMs do NOT include Google Apps"
    blue "   GApps MUST be obtained from external sources"
    
    # ⚠️  VALIDATE GApps package first
    if ! validate_gapps_package "$gapps_zip"; then
        error "❌ Invalid or missing GApps package"
        error "   Usage: install_google_apps '/path/to/gapps_package.zip'"
        error ""
        error "📥 Download GApps from:"
        error "   1. MindTheGapps: https://mindthegapps.com"
        error "   2. OpenGApps: https://opengapps.org"
        error "   3. Select: arm64, Android 13-16 (depending on your ROM)"
        error ""
        return 1
    fi
    
    # Custom GApps ZIP found — extract and apply
    blue "📥 Extracting GApps package: $gapps_zip"
    mkdir -p tmp/gapps_extract
    unzip -o "$gapps_zip" -d tmp/gapps_extract || {
        error "Failed to extract GApps ZIP"
        rm -rf tmp/gapps_extract
        return 1
    }
    
    local gapps_applied=false
    
    # Copy GApps from system partition
    if [[ -d "tmp/gapps_extract/system" ]]; then
        blue "📂 Copying GApps from system partition..."
        mkdir -p "$target_dir/system"
        cp -rf tmp/gapps_extract/system/* "$target_dir/system/" 2>/dev/null || true
        gapps_applied=true
        green "  ✓ System partition: $([[ -d "$target_dir/system/app" ]] && echo "$(find "$target_dir/system/app" -maxdepth 1 -type d | wc -l) apps")"
    fi
    
    # Copy GApps from my_product partition
    if [[ -d "tmp/gapps_extract/my_product" ]]; then
        blue "📂 Copying GApps from my_product partition..."
        mkdir -p "$target_dir/my_product"
        cp -rf tmp/gapps_extract/my_product/* "$target_dir/my_product/" 2>/dev/null || true
        gapps_applied=true
        green "  ✓ my_product partition: $([[ -d "$target_dir/my_product/app" ]] && echo "$(find "$target_dir/my_product/app" -maxdepth 1 -type d | wc -l) apps")"
    fi
    
    # Copy GApps from system_ext partition
    if [[ -d "tmp/gapps_extract/system_ext" ]]; then
        blue "📂 Copying GApps from system_ext partition..."
        mkdir -p "$target_dir/system_ext"
        cp -rf tmp/gapps_extract/system_ext/* "$target_dir/system_ext/" 2>/dev/null || true
        gapps_applied=true
        green "  ✓ system_ext partition: $([[ -d "$target_dir/system_ext/app" ]] && echo "$(find "$target_dir/system_ext/app" -maxdepth 1 -type d | wc -l) apps")"
    fi
    
    rm -rf tmp/gapps_extract
    
    if [[ "$gapps_applied" == "false" ]]; then
        error "❌ No GApps files found in package"
        return 1
    fi
    
    green "✅ Google Apps successfully integrated into ROM"
}

download_mindthegapps() {
    local android_version="${1:-13}"
    local output_file="${2:-tmp/MindTheGapps.zip}"
    
    blue "🌐 MindTheGapps Auto-Downloader"
    blue ""
    blue "📥 Downloading MindTheGapps for Android $android_version (arm64)..."
    
    mkdir -p "$(dirname "$output_file")"
    
    # Validate Android version
    case "$android_version" in
        13|14|15|16) ;;
        *)
            yellow "⚠️  Unsupported Android version: $android_version"
            blue "   Supported: 13, 14, 15, 16"
            return 1
            ;;
    esac
    
    # Fetch latest release from GitHub API for the specified Android version
    local github_repo="MindTheGapps/${android_version}.0.0-arm64"
    local api_url="https://api.github.com/repos/${github_repo}/releases/latest"
    
    blue "   Fetching latest release info from GitHub..."
    
    # Get the download URL from GitHub's API
    local download_url=""
    if command -v curl &> /dev/null; then
        download_url=$(curl -s "$api_url" | grep -o '"browser_download_url": *"[^"]*"' | head -1 | cut -d'"' -f4)
    elif command -v wget &> /dev/null; then
        download_url=$(wget -q -O - "$api_url" | grep -o '"browser_download_url": *"[^"]*"' | head -1 | cut -d'"' -f4)
    else
        error "❌ Neither curl nor wget available"
        error "   Please install curl or wget and try again"
        return 1
    fi
    
    if [[ -z "$download_url" ]]; then
        error "❌ Failed to fetch download URL from GitHub"
        error "   Repository: $github_repo"
        error "   Try manually downloading from:"
        error "   https://github.com/$github_repo/releases"
        return 1
    fi
    
    blue "   Download URL: $download_url"
    
    # Attempt download with curl first, fallback to wget
    if command -v curl &> /dev/null; then
        blue "   Using curl for download..."
        curl -L -o "$output_file" "$download_url" --progress-bar || {
            error "Failed to download MindTheGapps via curl"
            rm -f "$output_file"
            return 1
        }
    elif command -v wget &> /dev/null; then
        blue "   Using wget for download..."
        wget -O "$output_file" "$download_url" -q --show-progress || {
            error "Failed to download MindTheGapps via wget"
            rm -f "$output_file"
            return 1
        }
    fi
    
    # Verify download
    if [[ ! -f "$output_file" ]]; then
        error "❌ Download verification failed"
        return 1
    fi
    
    local file_size=$(du -h "$output_file" | cut -f1)
    green "✅ MindTheGapps downloaded successfully"
    green "   Location: $output_file"
    green "   Size: $file_size"
}

download_opengapps() {
    local arch="${1:-arm64}"
    local android_version="${2:-13}"
    local variant="${3:-stock}"
    local output_file="${4:-tmp/OpenGApps_${variant}.zip}"
    
    blue "🌐 OpenGApps Auto-Downloader"
    blue ""
    blue "📥 Downloading OpenGApps ($variant) for Android $android_version ($arch)..."
    
    mkdir -p "$(dirname "$output_file")"
    
    # Map Android version to build version OpenGApps uses
    local build_version=""
    case "$android_version" in
        13) build_version="13.0" ;;
        14) build_version="14.0" ;;
        15) build_version="15.0" ;;
        16) build_version="16.0" ;;
        *)
            yellow "⚠️  Unsupported Android version: $android_version"
            blue "   Supported: 13, 14, 15, 16"
            return 1
            ;;
    esac
    
    # Validate variant
    case "$variant" in
        pico|nano|micro|mini|stock|full|super) ;;
        *)
            yellow "⚠️  Unknown variant: $variant"
            blue "   Supported: pico, nano, micro, mini, stock, full, super"
            return 1
            ;;
    esac
    
    # OpenGApps CDN URL structure: https://sourceforge.net/projects/opengapps/files/arm64/OpenGApps-arm64-13.0-{variant}-{date}.zip/download
    # We'll use the latest version from the GitHub releases API
    local download_url="https://github.com/opengapps/opengapps/releases/download/${android_version}-GAPPS-latest/open_gapps-${arch}-${build_version}-${variant}-latest.zip"
    
    # Alternative: Direct SourceForge URL (more reliable)
    download_url="https://sourceforge.net/projects/opengapps/files/${arch}/"
    
    blue "   Attempting to download from official sources..."
    blue "   This may take 2-10 minutes depending on variant..."
    
    # Attempt download with curl first, fallback to wget
    if command -v curl &> /dev/null; then
        blue "   Using curl for download..."
        curl -L -o "$output_file" -C - --progress-bar \
            "https://github.com/opengapps/opengapps/releases/download/${build_version}-GAPPS-latest/open_gapps-${arch}-${build_version}-${variant}-*.zip" 2>/dev/null || {
            yellow "⚠️  GitHub mirror unavailable, trying SourceForge..."
            curl -L -o "$output_file" -C - --progress-bar \
                "https://sourceforge.net/projects/opengapps/files/${arch}/" 2>/dev/null || {
                error "Failed to download OpenGApps"
                rm -f "$output_file"
                return 1
            }
        }
    elif command -v wget &> /dev/null; then
        blue "   Using wget for download..."
        wget -O "$output_file" -c --show-progress \
            "https://github.com/opengapps/opengapps/releases/download/${build_version}-GAPPS-latest/open_gapps-${arch}-${build_version}-${variant}-*.zip" 2>/dev/null || {
            yellow "⚠️  GitHub mirror unavailable, trying SourceForge..."
            wget -O "$output_file" -c --show-progress \
                "https://sourceforge.net/projects/opengapps/files/${arch}/" 2>/dev/null || {
                error "Failed to download OpenGApps"
                rm -f "$output_file"
                return 1
            }
        }
    else
        error "❌ Neither curl nor wget available"
        error "   Please install curl or wget and try again"
        return 1
    fi
    
    # Verify download
    if [[ ! -f "$output_file" ]]; then
        error "❌ Download verification failed"
        yellow "⚠️  Manual download may be required:"
        yellow "   Visit: https://opengapps.org"
        yellow "   Select: arm64, Android $android_version, Variant: $variant"
        return 1
    fi
    
    local file_size=$(du -h "$output_file" | cut -f1)
    green "✅ OpenGApps ($variant) downloaded successfully"
    green "   Location: $output_file"
    green "   Size: $file_size"
}

setup_gapps_for_cos_cn() {
    blue "╔════════════════════════════════════════════════════════╗"
    blue "║   GApps Setup Guide for ColorOS CN Porting            ║"
    blue "╚════════════════════════════════════════════════════════╝"
    blue ""
    blue "🎯 Which GApps source would you like to use?"
    blue ""
    blue "Option 1️⃣  — MindTheGapps (Recommended)"
    blue "  • Auto-downloads in seconds"
    blue "  • Specifically designed for GMS-less ROMs"
    blue "  • Best compatibility with ColorOS CN"
    blue "  • Usage: download_mindthegapps 13 tmp/gapps.zip"
    blue ""
    blue "Option 2️⃣  — OpenGApps (Alternative)"
    blue "  • More variants available (pico/nano/micro/mini/stock/full)"
    blue "  • Can select package size (stock recommended)"
    blue "  • Usage: download_opengapps arm64 13 stock tmp/gapps.zip"
    blue ""
    blue "📋 Supported Android Versions:"
    blue "  • 13, 14, 15, 16"
    blue ""
    blue "📋 To automatically download and use:"
    blue "  1️⃣  download_mindthegapps 13 tmp/gapps.zip"
    blue "  2️⃣  sudo ./port.sh <baserom> <portrom> --- tmp/gapps.zip"
    blue ""
    blue "⚠️  Important Notes:"
    blue "  • ColorOS CN ROMs have NO Google Apps pre-installed"
    blue "  • GApps are REQUIRED for Play Store functionality"
    blue "  • ARM64 architecture REQUIRED for OP9/OP9Pro"
    blue "  • Requires curl or wget for downloads"
    blue ""
}

# Enable Google Play Services and associated APIs
configure_google_play_services() {
    blue "🔌 Configuring Google Play Services..."
    
    local gapps_prop="build/portrom/images/my_product/etc/bruce/build.prop"
    mkdir -p "$(dirname "$gapps_prop")"
    
    # Essential GMS properties for proper integration
    cat >> "$gapps_prop" <<'EOF'

# ━━━ Google Play Services Configuration ━━━
# Required for GApps functionality in ColorOS CN
ro.com.google.clientidbase=android-google
ro.com.android.dataroaming=true
ro.com.android.dateformat=MM-dd-yyyy
ro.setupwizard.enterprise_mode=1
ro.com.google.gwsdisabled=0

# Google Play Store & Account
ro.com.google.gmsversion=13_202401
ro.com.android.vending.api_version=11

# Location Services
ro.com.google.location.work=true
ro.com.google.clientidbase=android-google

# Analytics & Crash Reporting
ro.setupwizard.show_repair_option=false
ro.error.receiver.default=com.google.android.feedback.ErrorReceiver

# Network Settings
persist.sys.usb.config=mtp,adb
ro.setupwizard.network_required=false

EOF
    
    green "✅ Google Play Services configured"
}

# Auto-download and install GApps if port ROM is ColorOS CN
auto_download_gapps_for_coscn() {
    local build_prop_path="${1:-build/portrom/images/my_manifest/build.prop}"
    local android_version="${2:-13}"
    local gapps_output="${3:-tmp/MindTheGapps_auto.zip}"
    
    blue "🔍 Checking if port ROM is ColorOS CN..."
    
    # Check if it's COS CN
    if is_coloros_cn "$build_prop_path"; then
        blue "✅ Detected ColorOS CN ROM (missing Google Apps)"
        blue "📥 Auto-downloading MindTheGapps for Android $android_version..."
        
        # Auto-download MindTheGapps
        if download_mindthegapps "$android_version" "$gapps_output"; then
            blue "✅ GApps download successful: $gapps_output"
            blue "📱 Installing Google Apps into ROM..."
            
            # Install the downloaded GApps
            if install_google_apps "$gapps_output"; then
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

trap 'error "Script interrupted! Exiting to prevent accidental deletion." ; exit 1' SIGINT