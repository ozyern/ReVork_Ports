#!/bin/bash

clear
if [ "$LANG" = "C.UTF-8" ];then
	echo
	echo 1.保留数据刷入
	echo
	echo 2.双清刷入
	echo
	read -p "请选择(默认选择1,回车执行):" input
elif [ "$LANG" = "zh_CN.UTF-8" ];then
	echo
	echo 1.保留数据刷入
	echo
	echo 2.双清刷入
	echo
	read -p "请选择(默认选择1,回车执行):" input
elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	echo
	echo 1.保留數據刷入
	echo
	echo 2.雙清刷入
	echo
	read -p "請選擇(默認選擇1,回車執行):" input
else
	echo
	echo 1.Reserved data flushing
	echo
	echo 2.Wipe data without formatting /data/media/
	echo
	read -p "Please select(1 is selected by default, and enter to execute):" input
fi
pdapt=$(type apt | grep "apt is")
if [ -n "$pdapt" ];then
	echo -n "]0;mac_linux_flash_script"
fi
pdfastboot=$(type fastboot | grep "fastboot is")
if [ ! -n "$pdfastboot" ];then
	if [ ! -n "$pdapt" ];then
		sudo brew install android-platform-tools
	else
		sudo apt install fastboot -y
	fi
else
	if [ "$LANG" = "C.UTF-8" ];then
	    echo fastboot已安装
	elif [ "$LANG" = "zh_CN.UTF-8" ];then
	    echo fastboot已安装
	elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	    echo fastboot已安裝
	else
	    echo fastboot already installed
  fi
fi

fastboot_path=$(which fastboot)
if [ -n "$fastboot_path" ]; then
  export ANDROID_PRODUCT_OUT=$(dirname "$fastboot_path")
fi

pdzstd=$(type zstd | grep "zstd is")
if [ ! -n "$pdzstd" ];then
	if [ ! -n "$pdapt" ];then
		sudo brew install zstd
	else
		sudo apt install zstd -y
	fi
else
	if [ "$LANG" = "C.UTF-8" ];then
	    echo zstd已安装
	elif [ "$LANG" = "zh_CN.UTF-8" ];then
	    echo zstd已安装
	elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	    echo zstd已安裝
	else
	    echo zstd already installed
	fi
fi
 
if [ -f "super.zst" ];then
	if [ "$LANG" = "C.UTF-8" ];then
	    echo 正在解压super镜像,耐心等待
	elif [ "$LANG" = "zh_CN.UTF-8" ];then
	    echo 正在解压super镜像,耐心等待
	elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	    echo 正在解壓super鏡像，耐心等待
	else
	    echo Extracting the super image, wait patiently
	fi
	zstd --rm -d super.zst -o super.img
	if [ $? -ne 0 ]; then
		if [ "$LANG" = "C.UTF-8" ];then
		    echo 转换失败,2s后退出程序
		elif [ "$LANG" = "zh_CN.UTF-8" ];then
		    echo 转换失败,2s后退出程序
		elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
		    echo 轉換失敗，2s後退出程式
		else
		    echo Conversion failed, exit the program after 2s
		fi
		ping 127.0.0.1 -c 2 1> /dev/null 2>&1
		exit 0
	fi
fi

if [ "$LANG" = "C.UTF-8" ];then
	echo "机型验证中...请确保您的设备代号为[device_code]，并已经进入bootloader模式。"
elif [ "$LANG" = "zh_CN.UTF-8" ];then
	echo "机型验证中...请确保您的设备代号为[device_code]，并已经进入bootloader模式。"
elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	echo "機型驗證中...請確保您的設備代號為[device_code]，並已進入bootloader模式。"
else
	echo "Validating device...please boot your device into bootloader and make sure your device code is [device_code]"
fi

fastboot $* getvar product 2>&1 | grep "^product: *device_code"
if [ $? -ne 0  ] ; then
	if [ "$LANG" = "C.UTF-8" ];then
		    echo 机型[device_code]校验失败，检查包是否匹配
		elif [ "$LANG" = "zh_CN.UTF-8" ];then
		    echo 机型device_code校验失败，检查包是否匹配
		elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
		    echo 機型device_code校驗失敗，檢查包是否匹配
		else
		    echo "Mismatching image and device [device_code]"
		fi
	exit 1 
fi

# firmware

fastboot erase super
fastboot reboot bootloader
ping 127.0.0.1 -c 5 1> /dev/null 2>&1

if [ -f "boot_tv.img" ]; then
	fastboot flash boot_ab boot_tv.img
	fastboot flash dtbo_ab firmware-update/dtbo_tv.img
else
	fastboot flash boot_ab boot_official.img
	fastboot flash dtbo_ab firmware-update/dtbo.img
fi
fastboot flash super super.img
if [ ! -n "$input" ];then
	echo
elif [ "$input" -eq "2" ];then
	if [ "$LANG" = "C.UTF-8" ];then
	    echo 正在双清系统,耐心等待
	elif [ "$LANG" = "zh_CN.UTF-8" ];then
	    echo 正在双清系统,耐心等待
	elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	    echo 正在雙清系統，耐心等待
	else
	    echo Wiping data without data/media/, please wait patiently
	fi
	fastboot erase userdata
	fastboot erase metadata
elif [ "$input" -eq "1" ];then
	echo
fi
# SET_ACTION_SLOT_A_BEGIN
if [ "$LANG" = "C.UTF-8" ];then
	echo 设置活动分区为 'a'。可能需要一些时间。请勿手动重新启动或拔掉数据线，否则可能导致设备变砖。
elif [ "$LANG" = "zh_CN.UTF-8" ];then
	echo 设置活动分区为 'a'。可能需要一些时间。请勿手动重新启动或拔掉数据线，否则可能导致设备变砖。
elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	echo 開始將活動分區設置為 'a'。這可能需要一些時間。請勿手動重新啟動或拔掉數據線，否則可能導致設備無法響應。
else
	echo Starting the process to set the active slot to 'a.' This may take some time. Please refrain from manually restarting or unplugging the data cable, as doing so could result in the device becoming unresponsive.
fi
fastboot set_active a
# SET_ACTION_SLOT_A_END

fastboot reboot

if [ "$LANG" = "C.UTF-8" ];then
	echo 刷机完成,若手机长时间未重启请手动重启,按任意键退出
elif [ "$LANG" = "zh_CN.UTF-8" ];then
	echo 刷机完成,若手机长时间未重启请手动重启,按任意键退出
elif [[ "$LANG" =~ ^zh_.*\.UTF-8$ ]]; then
	echo 刷機完成，若手機長時間未重啓請手動重啓，按任意鍵退出
else
	echo Flash completed. If the phone does not restart for an extended period, please manually restart. Press any key to exit.
fi
echo 若手机长时间未重启请手动重启
exit 0
