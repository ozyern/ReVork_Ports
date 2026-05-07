#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
from difflib import SequenceMatcher
from typing import Generator, Any
from re import escape, match

fix_permission = {
    "/vendor/bin/hw/android.hardware.wifi@1.0": "u:object_r:hal_wifi_default_exec:s0",
    "/system/system/app/*": "u:object_r:system_file:s0",
    "/system/system/priv-app/*": "u:object_r:system_file:s0",
    "/system/system/lib*": "u:object_r:system_lib_file:s0",
    "/system/system/bin/init": "u:object_r:init_exec:s0",
    "/system_ext/lib*": "u:object_r:system_lib_file:s0",
    "/product/lib*": "u:object_r:system_lib_file:s0",
    "/system/system/bin/app_process32": "u:object_r:zygote_exec:s0",
    "/system/system/bin/bootstrap/linker": "u:object_r:system_linker_exec:s0",
    "/system/system/bin/boringssl_self_test32": "u:object_r:boringssl_self_test_exec:s0",
    "/system/system/bin/drmserver": "u:object_r:drmserver_exec:s0",
    "/system/system/bin/linker": "u:object_r:system_linker_exec:s0",
    "/system/system/bin/mediaserver": "u:object_r:mediaserver_exec:s0",
    "/system_ext/bin/sigma_miracasthalservice": "u:object_r:vendor_sigmahal_qti_exec:s0",
    "/system_ext/bin/wfdservice": "u:object_r:vendor_wfdservice_exec:s0",
    "/my_product/vendor/etc/*.xml":"u:object_r:vendor_configs_file:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.charger-V3-service":"u:object_r:hal_charger_oplus_exec:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.charger-V6-service":"u:object_r:hal_charger_oplus_exec:s0",
    r"/odm/bin/hw/android\.hardware\.power\.stats-impl\.oplus":"u:object_r:hal_power_stats_default_exec:s0",
    r"/vendor/etc/permissions/android\.hardware\.hardware_keystore\.xml":"u:object_r:vendor_configs_file:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.nfc_aidl-service":"u:object_r:hal_oplus_nfc_default_exec:s0",
    "/odm/bin/commcenterd":"u:object_r:commcenterd_exec:s0",
    "/odm/bin/hw/mdm_feature":"u:object_r:mdm_feature_exec:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.wifi-aidl-service":"u:object_r:oplus_wifi_aidl_service_exec:s0",
    r"/odm/bin/hw/vendor-oplus-hardware-touch-V2-service":"u:object_r:hal_oplus_touch_aidl_default_exec:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.eid@1\.0-service":"u:object_r:hal_eid_oplus_exec:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.riskdetect-V1-service":"u:object_r:hal_riskdetect_oplus_exec:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.urcc-service":"u:object_r:hal_urcc_default_exec:s0",
    "/odm/bin/hw/virtualcameraprovider":"u:object_r:hal_virtualdevice_camera_exec:s0",
    "/odm/bin/hw/vendor-oplus-hardware-touch-V2-service":"u:object_r:hal_oplus_touch_aidl_default_exec:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.displaypanelfeature-service":"u:object_r:oplus_hal_displaypanelfeature_exec:s0",
    r"/odm/bin/hw/vendor\.oplus\.hardware\.engcamera@1\.0-service":"u:object_r:engcamera_hidl_exec:s0",
    r"/odm/bin/init\.oplus\.storage\.io_metrics\.sh":"u:object_r:oplus_storage_io_metrics_exec:s0",
   "/system_ext/xbin/xeu_toolbox":"u:object_r:xeu_toolbox_exec:s0",
   "*/etc/init/hw/*.rc":"u:object_r:vendor_configs_file:s0",
    r"/odm/lib/libmsnativefilter\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/libmsnativefilter\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib/libextendfile\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/libextendfile\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/android\.hardware\.graphics\.common-V5-ndk\.so":"u:object_r:same_process_hal_file:s0", 
    r"/vendor/lib64/android\.hardware\.common-V2-ndk\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/android\.hardware\.graphics\.common@1\.0\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/android\.hardware\.graphics\.allocator-V2-ndk\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/vendor\.qti\.hardware\.camera\.offlinecamera-V2-ndk\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/android\.hardware\.camera\.device-V2-ndk\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/libAlgoInterface\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/libAlgoProcess\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/android\.hardware\.common\.fmq-V1-ndk\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/android\.hardware\.camera\.metadata-V2-ndk\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/vendor\.oplus\.hardware\.osense\.client-V1-ndk\.so":"u:object_r:same_process_hal_file:s0",
    r"/vendor/lib64/libc\+\+\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib/libNamaWrapper\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib/vendor\.oplus\.hardware\.sendextcamcmd-V1-service-impl\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib/libOplusSecurity\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/libNamaWrapper\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/vendor\.oplus\.hardware\.sendextcamcmd-V1-service-impl\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/libOplusSecurity\.so":"u:object_r:same_process_hal_file:s0",
     r"/odm/lib/libFilterWrapper\.so":"u:object_r:same_process_hal_file:s0",
    r"/odm/lib64/libFilterWrapper\.so":"u:object_r:same_process_hal_file:s0",
    "/odm/lib64/libaiboost*.so":"u:object_r:same_process_hal_file:s0",
    "/odm/lib64/aiframe/*.so":"u:object_r:same_process_hal_file:s0",
    "/odm/lib64/aiframe/cdsp/*signed/*.so":"u:object_r:same_process_hal_file:s0",
    "/system/system/bin/pif-updater":"u:object_r:pif_updater_exec:s0",
    }


def scan_context(file) -> dict:  # 读取context文件返回一个字典
    context = {}
    with open(file, "r", encoding="utf-8") as file_:
        for i in file_.readlines():
            filepath, *other = i.strip().split()
            filepath = filepath.replace(r"\@", "@")
            context[filepath] = other
            if len(other) > 1:
                print(f"[Warn] {i[0]} has too much data.Skip.")
                del context[filepath]
    return context


def scan_dir(folder) -> Generator[Any, Any, Any]:  # 读取解包的目录，返回一个生成器
    part_name = os.path.basename(folder)
    allfiles = [
        "/",
        "/lost+found",
        f"/{part_name}",
        f"/{part_name}/",
        f"/{part_name}/lost+found",
    ]
    for root, dirs, files in os.walk(folder, topdown=True):
        dirs[:] = [d for d in dirs if d not in (".git", ".repo", ".svn", "__pycache__")]
        for dir_ in dirs:
            yield os.path.join(root, dir_).replace(folder, "/" + part_name).replace(
                "\\", "/"
            )
        for file in files:
            yield os.path.join(root, file).replace(folder, "/" + part_name).replace(
                "\\", "/"
            )
        for rv in allfiles:
            yield rv


def str_to_selinux(string: str):
    return escape(string).replace("\\-", "-")


def context_patch(fs_file, dir_path) -> tuple:  # 接收两个字典对比
    new_fs = {}
    # 定义已修补过的 避免重复修补
    r_new_fs = {}
    add_new = 0
    print("ContextPatcher: Load origin %d" % (len(fs_file.keys())) + " entries")
    # 定义默认 SeLinux 标签
    if dir_path.endswith("system_dlkm"):
        permission_d = ["u:object_r:system_dlkm_file:s0"]
    elif dir_path.endswith(("odm", "vendor", "vendor_dlkm")):
        permission_d = ["u:object_r:vendor_file:s0"]
    else:
        permission_d = ["u:object_r:system_file:s0"]
    for i in scan_dir(os.path.abspath(dir_path)):
        # 把不可打印字符替换为 *
        if not i.isprintable():
            tmp = ""
            for c in i:
                tmp += c if c.isprintable() else "*"
            i = tmp
        if " " in i:
            i = i.replace(" ", "*")
        i = str_to_selinux(i)

        # 🚫 跳过含中文或非 ASCII 的路径（防止 mkfs.erofs 报 Non-ASCII 错）
        if any(ord(ch) > 127 for ch in i):
        # print(f"[Skip] {i} contains non-ASCII characters, skipped.")
           continue

        if fs_file.get(i):
            # 如果已经存在, 直接使用原来的
            new_fs[i] = fs_file[i]
        else:
            permission = None
            # 确认 i 不为空
            if r_new_fs.get(i):
                continue
            if i:
                # 如果路径符合已定义的内容, 直接将 permission 赋值为对应的值
                for f in fix_permission.keys():
                    pattern = f.replace("*", ".*")
                    #print(f"Checking {i} against pattern {pattern}")  # 打印当前检查的路径与模式
                    if i == pattern:
                        permission = [fix_permission[f]]
                        break
                    if match(pattern, i):
                        permission = [fix_permission[f]]
                        break
                # 如果路径不符合已定义的内容, 尝试从 fs_file 中查找相似的路径
                if not permission:
                    for e in fs_file.keys():
                        if (
                            SequenceMatcher(
                                None, (path := os.path.dirname(i)), e
                            ).quick_ratio()
                            >= 0.8
                        ):
                            if e == path:
                                continue
                            permission = fs_file[e]
                            break
                        else:
                            permission = permission_d
            if " " in permission:
                permission = permission.replace(" ", "")
            print(f"Add {i} {permission}")
            add_new += 1
            r_new_fs[i] = permission
            new_fs[i] = permission
    return new_fs, add_new


def main(dir_path, fs_config) -> None:
    new_fs, add_new = context_patch(scan_context(os.path.abspath(fs_config)), dir_path)
    with open(fs_config, "w+", encoding="utf-8", newline="\n") as f:
        f.writelines(
            [i + " " + " ".join(new_fs[i]) + "\n" for i in sorted(new_fs.keys())]
        )
    print("ContextPatcher: Add %d" % add_new + " entries")


def Usage():
    print("Usage:")
    print("%s <folder> <fs_config>" % (sys.argv[0]))
    print("    This script will auto patch file_context")


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        Usage()
        sys.exit()
    if os.path.isdir(sys.argv[1]) or os.path.isfile(sys.argv[2]):
        main(sys.argv[1], sys.argv[2])
        print("Done!")
    else:
        print(
            "The path or filetype you have given may wrong, please check it wether correct."
        )
        Usage()
