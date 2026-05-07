# Copyright (C) 2019 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import hashlib
import common
import os

TARGET_DIR = os.getenv('OUT')

def FullOTA_Assertions(self):
   #self.script.AppendExtra('getprop("ro.separate.soft") == "20061" || abort("E3004: This package is for \"20061\" devices; this is a \"" + getprop("ro.separate.soft") + "\".");')
   self.script.AppendExtra(
    'getprop("ro.separate.soft") == "20061" || '
    'abort("E3004: This package is for \\"20061\\" devices; this is a \\"" + getprop("ro.separate.soft") + "\\".");'
)

def FullOTA_InstallBegin(self):
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/abl.img"), "firmware-update/abl.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/imagefv_ddr5.img"), "firmware-update/imagefv_ddr5.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/imagefv_ddr4.img"), "firmware-update/imagefv_ddr4.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/xbl_config_ddr5.img"), "firmware-update/xbl_config_ddr5.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/xbl_config_ddr4.img"), "firmware-update/xbl_config_ddr4.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/cmnlib.img"), "firmware-update/cmnlib.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/dspso.img"), "firmware-update/dspso.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/hyp.img"), "firmware-update/hyp.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/keymaster64.img"), "firmware-update/keymaster64.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/tz.img"), "firmware-update/tz.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/cdt_engineering.img"), "firmware-update/cdt_engineering.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/splash.img"), "firmware-update/splash.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/BTFM.img"), "firmware-update/BTFM.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/qupv3fw.img"), "firmware-update/qupv3fw.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/static_nvbk.img"), "firmware-update/static_nvbk.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/DRIVER.img"), "firmware-update/DRIVER.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/cmnlib64.img"), "firmware-update/cmnlib64.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/devcfg.img"), "firmware-update/devcfg.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/modem.img"), "firmware-update/modem.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/oppo_sec.img"), "firmware-update/oppo_sec.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/aop.img"), "firmware-update/aop.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/dpAP.img"), "firmware-update/dpAP.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/xbl_ddr5.img"), "firmware-update/xbl_ddr5.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/xbl_ddr4.img"), "firmware-update/xbl_ddr4.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "storage-fw/ffu_tool"), "ffu_tool")
  self.output_zip.write(os.path.join(TARGET_DIR, "storage-fw/SS_KLUEG8UHDB-C2D1_1900.fw"), "storage-fw/SS_KLUEG8UHDB-C2D1_1900.fw")
  self.output_zip.write(os.path.join(TARGET_DIR, "storage-fw/SS_KLUFG8RHDA-B2D1_0900.fw"), "storage-fw/SS_KLUFG8RHDA-B2D1_0900.fw")
  self.output_zip.write(os.path.join(TARGET_DIR, "storage-fw/SS_KLUDG4UHDB-B2D1_1900.fw"), "storage-fw/SS_KLUDG4UHDB-B2D1_1900.fw")  
# Write Firmware updater-script
  self.script.AppendExtra('')
  self.script.AppendExtra('# ---- radio update tasks ----')
  self.script.AppendExtra('')
  self.script.AppendExtra('ui_print("Patching firmware images...");')
  self.script.AppendExtra('package_extract_file("firmware-update/abl.img", "/dev/block/bootdevice/by-name/abl");')
  self.script.AppendExtra('ifelse(get_xblddr_type() == "ddr5",package_extract_file("firmware-update/imagefv_ddr5.img", "/dev/block/bootdevice/by-name/imagefv");ui_print("update ddr5 imagefv!"),package_extract_file("firmware-update/imagefv_ddr4.img", "/dev/block/bootdevice/by-name/imagefv"));')
  self.script.AppendExtra('ifelse(get_xblddr_type() == "ddr5",package_extract_file("firmware-update/xbl_config_ddr5.img", "/dev/block/bootdevice/by-name/xbl_config");ui_print("update ddr5 xbl_config!"),package_extract_file("firmware-update/xbl_config_ddr4.img", "/dev/block/bootdevice/by-name/xbl_config"));')
  self.script.AppendExtra('package_extract_file("firmware-update/cmnlib.img", "/dev/block/bootdevice/by-name/cmnlib");')
  self.script.AppendExtra('package_extract_file("firmware-update/dspso.img", "/dev/block/bootdevice/by-name/dsp");')
  self.script.AppendExtra('package_extract_file("firmware-update/hyp.img", "/dev/block/bootdevice/by-name/hyp");')
  self.script.AppendExtra('package_extract_file("firmware-update/keymaster64.img", "/dev/block/bootdevice/by-name/keymaster");')
  self.script.AppendExtra('package_extract_file("firmware-update/tz.img", "/dev/block/bootdevice/by-name/tz");')
  self.script.AppendExtra('package_extract_file("firmware-update/cdt_engineering.img", "/dev/block/bootdevice/by-name/engineering_cdt");')
  self.script.AppendExtra('package_extract_file("firmware-update/splash.img", "/dev/block/bootdevice/by-name/splash");') 
  self.script.AppendExtra('package_extract_file("firmware-update/BTFM.img", "/dev/block/bootdevice/by-name/bluetooth");')
  self.script.AppendExtra('package_extract_file("firmware-update/qupv3fw.img", "/dev/block/bootdevice/by-name/qupfw");') 
  self.script.AppendExtra('package_extract_file("firmware-update/static_nvbk.img", "/dev/block/bootdevice/by-name/oppostanvbk");')
  self.script.AppendExtra('package_extract_file("firmware-update/DRIVER.img", "/dev/block/bootdevice/by-name/DRIVER");')
  self.script.AppendExtra('package_extract_file("firmware-update/cmnlib64.img", "/dev/block/bootdevice/by-name/cmnlib64");')
  self.script.AppendExtra('package_extract_file("firmware-update/devcfg.img", "/dev/block/bootdevice/by-name/devcfg");')
  self.script.AppendExtra('package_extract_file("firmware-update/modem.img", "/dev/block/bootdevice/by-name/modem");')
  self.script.AppendExtra('package_extract_file("firmware-update/oppo_sec.img", "/dev/block/bootdevice/by-name/oppo_sec");')
  self.script.AppendExtra('package_extract_file("firmware-update/aop.img", "/dev/block/bootdevice/by-name/aop");')
  self.script.AppendExtra('package_extract_file("firmware-update/dpAP.img", "/dev/block/bootdevice/by-name/apdp");')
  self.script.AppendExtra('ifelse(get_xblddr_type() == "ddr5",package_extract_file("firmware-update/xbl_ddr5.img", "/dev/block/bootdevice/by-name/xbl");ui_print("update ddr5 xbl!"),package_extract_file("firmware-update/xbl_ddr4.img", "/dev/block/bootdevice/by-name/xbl"));')
  self.script.AppendExtra('package_extract_file("storage-fw/SS_KLUEG8UHDB-C2D1_1900.fw", "/tmp/firmware/SS_KLUEG8UHDB-C2D1_1900.fw");')
  self.script.AppendExtra('set_metadata("/tmp/firmware/SS_KLUEG8UHDB-C2D1_1900.fw", "uid", 0, "gid", 2000, "mode", 0666);')
  self.script.AppendExtra('package_extract_file("storage-fw/SS_KLUFG8RHDA-B2D1_0900.fw", "/tmp/firmware/SS_KLUFG8RHDA-B2D1_0900.fw");')
  self.script.AppendExtra('set_metadata("/tmp/firmware/SS_KLUFG8RHDA-B2D1_0900.fw", "uid", 0, "gid", 2000, "mode", 0666);')
  self.script.AppendExtra('package_extract_file("storage-fw/SS_KLUDG4UHDB-B2D1_1900.fw", "/tmp/firmware/SS_KLUDG4UHDB-B2D1_1900.fw");')
  self.script.AppendExtra('set_metadata("/tmp/firmware/SS_KLUDG4UHDB-B2D1_1900.fw", "uid", 0, "gid", 2000, "mode", 0666);')
  self.script.AppendExtra('package_extract_file("ffu_tool", "/tmp/ffu_tool");set_metadata("/tmp/ffu_tool", "uid", 0, "gid", 2000, "mode", 0755, "capabilities", 0x0, "selabel", "u:object_r:bootanim_exec:s0");')
# Firmware - sagit
def FullOTA_InstallEnd(self):
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/dtbo.img"), "firmware-update/dtbo.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/vbmeta.img"), "firmware-update/vbmeta.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/vbmeta_system.img"), "firmware-update/vbmeta_system.img")
  self.output_zip.write(os.path.join(TARGET_DIR, "firmware-update/vbmeta_vendor.img"), "firmware-update/vbmeta_vendor.img")
# Write Firmware updater-script
  self.script.AppendExtra('')
  self.script.AppendExtra('# ---- radio update tasks 2 ---')
  self.script.AppendExtra('')
  self.script.AppendExtra('ui_print("Patching vbmeta dtbo binimages...");')
  self.script.AppendExtra('package_extract_file("firmware-update/dtbo.img", "/dev/block/bootdevice/by-name/dtbo");')
  self.script.AppendExtra('package_extract_file("firmware-update/vbmeta.img", "/dev/block/bootdevice/by-name/vbmeta");')
  self.script.AppendExtra('package_extract_file("firmware-update/vbmeta_system.img", "/dev/block/bootdevice/by-name/vbmeta_system");')
  self.script.AppendExtra('package_extract_file("firmware-update/vbmeta_vendor.img", "/dev/block/bootdevice/by-name/vbmeta_vendor");')
