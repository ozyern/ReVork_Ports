#!/bin/bash

# Define color output function
error() {
    if [ "$#" -eq 2 ]; then
        
        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$1"\033[0m"
    else
        echo "Usage: error <Chinese> <English>"
    fi
}

yellow() {
    if [ "$#" -eq 2 ]; then
        
        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$1"\033[0m"
    else
        echo "Usage: yellow <Chinese> <English>"
    fi
}

blue() {
    if [ "$#" -eq 2 ]; then
        
        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$1"\033[0m"
    else
        echo "Usage: blue <Chinese> <English>"
    fi
}

green() {
    if [ "$#" -eq 2 ]; then
        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$1"\033[0m"
    else
        echo "Usage: green <Chinese> <English>"
    fi
}

#Check for the existence of the requirements command, proceed if it exists, or abort otherwise.
exists() {
    command -v "$1" > /dev/null 2>&1
}

abort() {
    error "--> Missing $1 abort! please run ./setup.sh first (sudo is required on Linux system)"
    exit 1
}

check() {
    for b in "$@"; do
        exists "$b" || abort "$b"
    done
}

shopt -s expand_aliases
if [[ "$OSTYPE" == "darwin"* ]]; then
    yellow "macOS detected,setting alias"
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
        done
        if [[ $2 == *"/"* ]];then
            targetsmali=$(find tmp/$foldername/*/$(dirname $2) -type f -name $(basename $2))
        else
            targetsmali=$(find tmp/$foldername -type f -name $2)
        fi
        if [ -f $targetsmali ];then
            smalidir=$(echo $targetsmali |cut -d "/" -f 3)
            yellow "Target ${smalidir} Found"
            search_pattern=$3
            repalcement_pattern=$4
            if [[ $5 == 'regex' ]];then
                 sed -i "/${search_pattern}/c\\${repalcement_pattern}" $targetsmali
            else
            sed -i "s/$search_pattern/$repalcement_pattern/g" $targetsmali
            fi
            pushd tmp/$foldername/ >/dev/null || exit
            popd >/dev/null || exit
            yellow "Fix $targetfilename completed"
            if [[ $targetfilename == *.apk ]]; then
                yellow "APK file detected, initiating ZipAlign process..."
                rm -rf ${targetfilefullpath}

                # Align moddified APKs, to avoid error "Targeting R+ (version 30 and above) requires the resources.arsc of installed APKs to be stored uncompressed and aligned on a 4-byte boundary" 
                yellow "APK ZipAlign process completed."
                yellow "ApkSinger signing.."
                apksigner sign -v --key otatools/key/testkey.pk8 --cert otatools/key/testkey.x509.pem ${targetfilefullpath}
                apksigner verify -v ${targetfilefullpath}
                yellow "Copying APK to target ${targetfilefullpath}"
            else
                yellow "Copying file to target ${targetfilefullpath}"
                cp -rf tmp/$foldername/$targetfilename ${targetfilefullpath}
            fi
        fi
    else
        error "Failed to find $1,please check it manually".
    fi

}

#check if a prperty is avaialble
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
            blue "[ext] Extracing ${part_name} "
            green "[ext] ${part_name} extracted."
            rm -rf ${part_img}      
        elif [[ $($tools_dir/gettype -i ${part_img}) == "erofs" ]]; then
            blue "[erofs] Extracing ${part_name} "
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
        blue "Disabling AVB verfication...."
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
    bootimg=$1
    mkdir -p ${work_dir}/tmp/boot_official
    cp $bootimg ${work_dir}/tmp/boot_official/boot.img
    pushd ${work_dir}/tmp/boot_official
    magiskboot unpack -h ${work_dir}/tmp/boot_official/boot.img > /dev/null 2>&1
    sed -i '/^cmdline=/ s/$/ androidboot.vbmeta.device_state=unlocked/' header
    magiskboot repack ${work_dir}/tmp/boot_official/boot.img  ${work_dir}/tmp/boot_official/new-boot.img
    popd
    cp ${work_dir}/tmp/boot_official/new-boot.img $bootimg
}


patch_kernel_to_bootimg() {
    kernel_file=$1
    dtb_file=$2
    bootimg_name=$3
    mkdir -p ${work_dir}/tmp/boot
    cd ${work_dir}/tmp/boot
    bootimg=$(find ${work_dir}/build/baserom/ -name boot.img)
    cp $bootimg ${work_dir}/tmp/boot/boot.img
    magiskboot unpack -h ${work_dir}/tmp/boot/boot.img > /dev/null 2>&1
    if [ -f ramdisk.cpio ]; then
    comp=$(magiskboot decompress ramdisk.cpio | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p')
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
    # if [[ ${pack_type} == "EROFS" ]];then
    #     if ! grep -q "erofs" ${work_dir}/tmp/boot/ramdisk/fstab.qcom ; then
    #             for pname in ${super_list}; do
    #                 sed -i "/\/${pname}[[:space:]]\+ext4/{p;s/ext4/erofs/;s/ro,barrier=1,discard/ro/;}" ${work_dir}/tmp/boot/ramdisk/fstab.qcom
    #                 added_line=$(sed -n "/\/${pname}[[:space:]]\+erofs/p" ${work_dir}/tmp/boot/ramdisk/fstab.qcom)
    
    #                 if [ -n "$added_line" ]; then
    #                 else
    #                     exit 1 
    #                 fi
    #             done
    #       fi
    #   fi
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
}

patch_kernel() {
    kernel_file=$1
    dtb_file=$2
    bootimg_name=$3
    local tmp_dir="${work_dir}/tmp/patch"

    blue "在 ${work_dir}/build/baserom/ 中查找"
    local bootimg
    bootimg=$(find "${work_dir}/build/baserom/" -name boot.img | head -n 1)
    if [[ -z "$bootimg" ]]; then
        exit 1
    fi
    cp "$bootimg" boot.img

    blue "调用 magiskboot unpack"
    magiskboot unpack -h boot.img > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        exit 1
    fi

    if [ -f ramdisk.cpio ]; then
        local comp
        comp=$(magiskboot decompress ramdisk.cpio | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p')
        if [ -n "$comp" ]; then
            mv -f ramdisk.cpio ramdisk.cpio."$comp"
            magiskboot decompress ramdisk.cpio."$comp" ramdisk.cpio > /dev/null 2>&1
            if [ $? -ne 0 ] && $comp --help > /dev/null 2>&1; then
                $comp -dc ramdisk.cpio."$comp" > ramdisk.cpio
            fi
        fi
        mkdir -p ramdisk
        chmod 755 ramdisk
        EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F ../ramdisk.cpio -i > /dev/null 2>&1
        cd ..
    fi

    disable_avb_verify "${tmp_dir}/"

    blue "复制新内核文件到临时目录"
    cp -f "$kernel_file" "${tmp_dir}/kernel"

    if [[ -f dtb ]] && [[ -n $dtb_file ]]; then
        blue "替换 boot.img 中的 dtb 文件"
        cp -fv "$dtb_file" "${tmp_dir}/dtb"
    fi

    if [ -d ramdisk ]; then
        for f in fstab.qcom fstab.default fstab.emmc; do
            if [ -f "ramdisk/${f}" ]; then
                yellow "${tmp_dir}/ramdisk/${f} 存在，无需额外处理"
                if [[ $convert_to_aonly == true ]];then
                    sed -i "/,slotselect/d" ramdisk/${f}
                fi
            fi
        done
    fi

    if [ -d ramdisk ]; then
        find . | sed 1d | cpio -H newc -R 0:0 -o -F ../ramdisk_new.cpio > /dev/null 2>&1
        cd ..
        if [ -n "$comp" ]; then
            magiskboot compress=$comp ramdisk_new.cpio
            if [ $? -ne 0 ] && $comp --help > /dev/null 2>&1; then
                $comp -9c ramdisk_new.cpio > ramdisk.cpio."$comp"
            fi
        fi
        local ramdisk_file
        ramdisk_file=$(ls ramdisk_new.cpio* | tail -n1)
        [ -n "$ramdisk_file" ] && cp -f "$ramdisk_file" ramdisk.cpio
    fi

    local nocompflag=""
    case $comp in
        cpio) nocompflag="-n" ;;
    esac

    blue "生成新 boot 镜像"
    magiskboot repack $nocompflag boot.img "${work_dir}/devices/${base_product_device}/${bootimg_name}"
    if [ $? -ne 0 ]; then
        exit 1
    fi

    local vendor_boot
    vendor_boot=$(find "${work_dir}/build/baserom/" -name vendor_boot.img | head -n 1)
    if [ -n "$vendor_boot" ]; then
        blue "vendor_boot detected, patching..."
        vendor_boot_tmp=$tmp_dir/vendor_boot_tmp
        cp "$vendor_boot" $vendor_boot_tmp/vendor_boot.img
        cd $vendor_boot_tmp
        magiskboot unpack -h vendor_boot.img > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            exit 1
        fi

        if [ -f ramdisk.cpio ]; then
            local vcomp
            vcomp=$(magiskboot decompress ramdisk.cpio | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p')
            if [ -n "$vcomp" ]; then
                mv -f ramdisk.cpio ramdisk.cpio."$vcomp"
                magiskboot decompress ramdisk.cpio."$vcomp" ramdisk.cpio > /dev/null 2>&1
                if [ $? -ne 0 ] && $vcomp --help > /dev/null 2>&1; then
                    $vcomp -dc ramdisk.cpio."$vcomp" > ramdisk.cpio
                fi
            fi
            mkdir -p ramdisk
            chmod 755 ramdisk
            EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F ../ramdisk.cpio -i > /dev/null 2>&1
            cd ..
        fi

        if [ -f dtb ]; then
            blue "Replacing dtb"
            cp -fv "$dtb_file" "${vendor_boot_tmp}/dtb"
        fi

        if [ -d ramdisk ]; then
            for f in fstab.qcom fstab.default fstab.emmc; do
                if [ -f "ramdisk/${f}" ]; then
                    yellow "${vendor_boot_tmp}/ramdisk/${f} 存在，无需额外处理"
                fi
            done
        fi

        if [ -d ramdisk ]; then
            find . | sed 1d | cpio -H newc -R 0:0 -o -F ../ramdisk_new.cpio > /dev/null 2>&1
            cd ..
            if [ -n "$vcomp" ]; then
                magiskboot compress=$vcomp ramdisk_new.cpio
                if [ $? -ne 0 ] && $vcomp --help > /dev/null 2>&1; then
                    $vcomp -9c ramdisk_new.cpio > ramdisk.cpio."$vcomp"
                fi
            fi
            local vramdisk
            vramdisk=$(ls ramdisk_new.cpio* | tail -n1)
            [ -n "$vramdisk" ] && cp -f "$vramdisk" ramdisk.cpio
        fi

        local v_nocompflag=""
        case $vcomp in
            cpio) v_nocompflag="-n" ;;
        esac
        blue "Repacking vendor_boot.img"
        magiskboot repack $v_nocompflag vendor_boot.img "${work_dir}/devices/${base_product_device}/vendor_boot.img"
        if [ $? -ne 0 ]; then
            exit 1
        fi

        #rm -rf vendor_tmp
    else
    fi

    cd "${work_dir}" || exit 1
    #rm -rf "${tmp_dir}"
    blue "patching done"
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
    shift # 移除第一个参数，剩下都是 feature 项

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
            attr_prefix='name=' # 后面拼上 args
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
            return 1
            ;;
    esac

    output_file="$dir/${base_file}-ext-bruce.xml"
    mkdir -p "$dir"

    if [[ ! -f "$output_file" ]]; then
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
        blue "✅ feature: $feature Added."

        if [[ "$type" == "app_feature" ]]; then
            attrs="name=\"$feature\""
            [[ -n "$extra" ]] && attrs="$attrs $extra"
        else
            attrs="name=\"$feature\""
            [[ -n "$extra" ]] && attrs="$attrs $extra"
        fi

        if [[ -n "$comment" ]]; then
            sed -i "/<\/$root_tag>/i\\\    <!-- $comment -->" "$output_file"
        fi
        sed -i "/<\/$root_tag>/i\\\    <$node_tag $attrs\/>" "$output_file"
    fi
done
}

remove_feature() {
    feature=$1
    force=$2  # 第二个参数，可为 "force"

    if [[ "$force" == "force" ]]; then
    else
        for file in $(find build/baserom/images/my_product/etc/ -type f -name "*.xml"); do
            if grep -nq "<!--.*$feature.*-->" "$file"; then
                blue "Deleting $feature from $(basename $file) as it is commented out..."
            elif grep -nq "$feature" "$file"; then
                blue "Skip deleting $feature from $(basename $file)..."
                return
            fi
        done 
    fi

    for file in $(find build/portrom/images/my_product/etc/ -type f -name "*.xml"); do
        if grep -nq "$feature" "$file"; then
            sed -i "/$feature/d" "$file"
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
    value=$2
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
    blue "Remove prop: $prop"
    sed -i "/${prop}/d" build/portrom/images/my_product/build.prop
    fi
}

add_prop_v2(){
    prop=$1
    value=$2
    bruce_prop="build/portrom/images/my_product/etc/bruce/build.prop"
    portrom_prop="build/portrom/images/my_product/build.prop"

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
    force="${2}"
    escaped_prop=$(echo "${prop}" | sed 's/\./\\./g')
    
    if [[ -n ${force} ]]; then
        blue "Force remove prop: ${prop}"
        sed -i -E "/^(${escaped_prop}=|${escaped_prop}\.)/s/^/#/" build/portrom/images/my_product/etc/bruce/build.prop
        sed -i -E "/^(${escaped_prop}=|${escaped_prop}\.)/s/^/#/" build/portrom/images/my_product/build.prop
    else
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

    cp -f "$target_build_prop" tmp/build.prop.portrom.bak

    cp -f "$source_build_prop" "$target_build_prop"


    if ! grep -q "^import /mnt/vendor/my_product/etc/bruce/build.prop" "$target_build_prop"; then
        echo "" >> "$target_build_prop"
        echo "import /mnt/vendor/my_product/etc/bruce/build.prop" >> "$target_build_prop"
    fi
}

add_prop_from_port() {
    base_build_prop="build/baserom/images/my_product/build.prop"
    old_portrom_prop="tmp/build.prop.portrom.bak"
    bruce_prop="build/portrom/images/my_product/etc/bruce/build.prop"
    
    force_keys=(
        ro.build.version.oplusrom
        ro.build.version.oplusrom.display
        ro.build.version.oplusrom.confidential
        ro.build.version.realmeui
    )

    declare -A base_props
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        base_props["$key"]="$value"
    done < "$base_build_prop"

    temp_file=$(mktemp)
    
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        
        if [[ " ${force_keys[*]} " == *" $key "* ]]; then
            continue
        fi

        if [[ ! -v base_props["$key"] ]]; then
            echo "$key=$value" >> "$temp_file"
            blue "Added: $key=$value"
        fi
    done < "$old_portrom_prop"

    for key in "${force_keys[@]}"; do
        value=$(grep -m1 "^${key}=" "$old_portrom_prop" | awk -F'=' '{print $2}' | tr -d '\n\r')
        
        if [[ -n "$value" ]]; then
            sed -i "/^${key}=/d" "$temp_file" 2>/dev/null
            echo "$key=$value" >> "$temp_file"
            blue "Force update: $key=$value"
        fi
    done

    cat "$temp_file" >> "$bruce_prop"
    rm -f "$temp_file"
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
    done

    pushd $source_dr >/dev/null || exit
    for classes_dex in $(find . -type f -name "*.dex"); do
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
    #java -jar bin/apktool/APKEditor.jar b -f -i tmp/Settings -o tmp/Settings.apk >/dev/null 2>&1
    smali_wrapper "tmp/Settings" tmp/Settings/Settings.apk
    zipalign -p -f -v 4 tmp/Settings/Settings.apk $SettingsAPK  > /dev/null 2>&1

    SystemUIAPK=$(find build/portrom/images/ -type f -name "SystemUI.apk" )
    #java -jar bin/apktool/APKEditor.jar d -i $SystemUIAPK -o tmp/SystemUI >/dev/null 2>&1
    baksmali_wrapper $SystemUIAPK
    OpUtilsSmali=$(find tmp/SystemUI -type f -name "OpUtils.smali")
    python3 bin/patchmethod.py $OpUtilsSmali "isUseOpFacelock"

    MiniCapsuleManagerImplSmali=$(find tmp/SystemUI -type f -name "MiniCapsuleManagerImpl.smali")

    findCode='invoke-static {}, Lcom/oplus/systemui/minicapsule/utils/MiniCapsuleUtils;->getPinholeFrontCameraPosition()Ljava/lang/String;'

    lineNum=$(grep -n "$findCode" "$MiniCapsuleManagerImplSmali" | cut -d ':' -f 1)

    lineContent=$(tail -n +"$lineNum" "$MiniCapsuleManagerImplSmali" | grep -m 1 -n "move-result-object")
    lineNumEnd=$(echo "$lineContent" | cut -d ':' -f 1)
    register=$(echo "$lineContent" | awk '{print $3}')

    lineNumEnd=$((lineNum + lineNumEnd - 1))

    if [ -n "$lineNumEnd" ]; then
        replace="    const-string $register, \"484,36:654,101\""
        sed -i "${lineNum},${lineNumEnd}d" "$MiniCapsuleManagerImplSmali"
        sed -i "${lineNum}i\\${replace}" "$MiniCapsuleManagerImplSmali"
        echo "Patched $file successfully"
    else
        echo "No 'move-result-object' found after $findCode in $MiniCapsuleManagerImplSmali"
    fi

    # white_list_xml=$(find tmp/systemui -name "app_music_capsule_white_list.xml")
    # if [[ -f $white_list_xml ]];then
    #     blue "Unlock mini capsule feature "
    #     music_apps=("com.tencent.qqmusic" "com.netease.cloudmusic" "com.heytap.music" "com.kugou.android" "com.tencent.karaoke" "cn.kuwo.player" "com.luna.music" "cmccwm.mobilemusic" "cn.missevan" "com.kugou.android.lite" "cn.wenyu.bodian" "com.duoduo.opera" "com.kugou.viper" "com.tencent.qqmusicpad" "com.aichang.yage" "com.blueocean.musicplayer" "com.tencent.blackkey" "com.e5837972.kgt" "com.android.mediacenter" "com.kugou.dj" "fm.xiami.main" "com.tencent.qqmusiclite" "com.blueocean.huoledj" "com.ting.mp3.android" "com.kk.xx.music" "ht.nct" "com.ximalaya.ting.android" "com.kuaiyin.player" "com.changba" "fm.qingting.qtradio" "com.yibasan.lizhifm" "com.shinyv.cnr" "app.podcast.cosmos" "com.tencent.radio" "com.kuaiyuhudong.djshow" "com.yusi.chongchong" "bubei.tingshu" "io.dushu.fandengreader" "com.tencent.weread" "com.soundcloud.android" "com.dywx.larkplayer" "com.shazam.android" "com.smule.singandroid" "com.andromo.dev445584.app545102" "com.anghami" "com.recorder.music.mp3.musicplayer" "com.atpc" "com.bandlab.bandlab" "com.gaana" "com.karaoke.offline.download.free.karaoke.music" "com.shaiban.audioplayer.mplayer" "com.jamendoandoutly.mainpakage" "com.spotify.music" "com.ezen.ehshig" "com.hiby.music" "com.tan8" "org.videolan.vlc" "video.player.videoplayer" "com.ted.android")
    #     for package in "${music_apps[@]}"; do
    #         if ! xmlstarlet sel -t -v "//packageInfo[@packageName='$package']" "$white_list_xml" | grep -q .; then
    #         xmlstarlet ed -L -s "/filter-conf" -t elem -n "packageInfo" -v "" -i "/filter-conf/packageInfo[not(@packageName)]" -t attr -n "packageName" -v "com.netease.music" $white_list_xml
    #         fi
    #     done
    # fi
    #java -jar bin/apktool/APKEditor.jar b -f -i tmp/SystemUI -o tmp/SystemUI.apk >/dev/null 2>&1
    smali_wrapper tmp/SystemUI tmp/SystemUI/SystemUI.apk
    zipalign -p -f -v 4 tmp/SystemUI/SystemUI.apk $SystemUIAPK  > /dev/null 2>&1
    apksigner sign -v --key otatools/key/testkey.pk8 --cert otatools/key/testkey.x509.pem  $SystemUIAPK
    apksigner verify -v  $SystemUIAPK
} 

patch_smartsidecar() {
    blue "Pathing SmarSidecar APK"
    SmartSideBarAPK=$(find build/portrom/images/ -type f -name "SmartSideBar.apk" )
    #java -jar bin/apktool/APKEditor.jar d -i $SmartSideBarAPK -o tmp/SmartSideBar >/dev/null 2>&1
    baksmali_wrapper $SmartSideBarAPK
    RealmeUtilsSmali=$(find tmp/SmartSideBar -type f -name "RealmeUtils.smali")
    python3 bin/patchmethod.py $RealmeUtilsSmali "isRealmeBrand"
    #java -jar bin/apktool/APKEditor.jar b -f -i tmp/SmartSideBar -o tmp/SmartSideBar.apk >/dev/null 2>&1
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
    
    echo $((major * 10000 + minor * 100 + patch))
}

get_oplusrom_version() {
    local max_version=""
    local max_version_number=0
    
    local prop_files=(
        "build/portrom/images/my_manifest/build.prop"
        "build/portorm/images/my_product/build.prop" 
    )
    
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


# Configuration for downloading resources from GitHub Release  
export REPO_OWNER="${REPO_OWNER:-toraidl}"
export REPO_NAME="${REPO_NAME:-coloros_port}"
export RELEASE_TAG="${RELEASE_TAG:-assets}"
# =========================================

# Check if GitHub CLI is installed
check_gh_cli() {
    if ! command -v gh &> /dev/null; then
        error "GitHub CLI (gh) not found."
        return 1
    fi
    return 0
}

# Generate asset name for GitHub Release (based on upload_assets.sh logic)
generate_asset_name() {
    local file_path="$1"
    local dir_path=$(dirname "$file_path")
    local filename=$(basename "$file_path")
    local asset_name=""

    # Match the naming logic in upload_assets.sh
    if [[ "$dir_path" == *"devices/"* ]]; then
        # Extract first level directory name under devices/ as prefix
        local prefix=$(echo "$dir_path" | sed 's/.*devices\///' | cut -d'/' -f1)
        asset_name="${prefix}_${filename}"
    elif [[ "$dir_path" == *"assets"* ]]; then
        asset_name="assets_${filename}"
    else
        asset_name="$filename"
    fi
    
    echo "$asset_name"
}

# Download specified asset from GitHub Release
download_from_release() {
    local file_path="$1"
    
    if [[ ! -f "$file_path" ]]; then
        local asset_name=$(generate_asset_name "$file_path")
        local download_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}/${asset_name}"
        
        blue "Attempting download from GitHub Release: $file_path"
        blue "     GitHub Asset Name: $asset_name" "GitHub Asset Name: $asset_name"
        blue "     Download URL: $download_url" "Download URL: $download_url"
        
        # Try using GitHub CLI first
        if check_gh_cli; then
            mkdir -p "$(dirname "$file_path")"
            if gh release download "$RELEASE_TAG" --repo "$REPO_OWNER/$REPO_NAME" --pattern "$asset_name" --dir "$(dirname "$file_path")" 2>/dev/null; then
                local downloaded_file=$(find "$(dirname "$file_path")" -name "$asset_name" -type f)
                if [[ -n "$downloaded_file" && "$downloaded_file" != "$file_path" ]]; then
                    mv "$downloaded_file" "$file_path"
                fi
                if [[ -f "$file_path" ]]; then
                    blue "Successfully downloaded via GitHub CLI: $file_path"
                    return 0
                fi
            fi
            yellow "GitHub CLI download failed, trying direct download..."
        fi
        
        # If GitHub CLI unavailable or fails, use curl for direct download
        mkdir -p "$(dirname "$file_path")"
        if curl -L --fail -o "$file_path.tmp" "$download_url"; then
            mv "$file_path.tmp" "$file_path"
            blue "Direct download successful: $file_path"
            return 0
        else
            rm -f "$file_path.tmp"
            error "Download failed: $file_path (URL: $download_url)"
            return 1
        fi
    else
        green "File already exists, skipping download: $file_path"
    fi
}

# Quick check function to download file if it's missing from GitHub Release (only when not exists locally)
ensure_resource_available() {
    local resource_path="$1"
    
    if [[ ! -f "$resource_path" ]]; then
        yellow "Resource missing locally: $resource_path, attempting download..."
        # Try downloading from GitHub Release 
        if download_from_release "$resource_path"; then
            return 0  # Download successful
        else
            error "Error: Could not acquire required resource $resource_path"
            error "Please place file manually or upload to GitHub Release"
            return 1
        fi
    else
        green "Resource exists: $resource_path"
        return 0  # Already exists
    fi
}