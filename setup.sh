#!/bin/bash
# port requirements


if [ "$(uname -m)" == "x86_64" ] && [  "$(uname)" == "Linux" ] && [ -f "/bin/apt" ];then
    if [ "$(id -u)" != "0" ] && [ "$(uname -m)" == "x86_64" ]  && [  "$(uname)" == "Linux" ];then
        echo "Restarting script as root"
        exec sudo /bin/bash "$0" "$@"
        exit $?
    fi
    echo "Device arch: Linux x86_64 (Debian based distro)"
    apt update -y
    apt upgrade -y
    apt install -y aria2 python3 busybox zip unzip p7zip-full openjdk-21-jre zstd bc android-sdk-libsparse-utils xmlstarlet
    if [ $? -ne 0 ];then
        echo "安装可能出错，请手动执行：apt install -y aria2 python3 busybox zip unzip p7zip-full openjdk-21-jre zstd bc xmlstarlet"
    fi
fi

if [ "$(uname -m)" == "x86_64" ] && [  "$(uname)" == "Linux" ] && [ -f "/bin/pacman" ];then
    echo "Device arch: Linux x86_64 (Arch based distro)"
    if [ ! -f "/bin/yay" ];then
        echo "Installing: yay. Manual intervention may be required."
        sudo pacman -Sy --needed --noconfirm base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si
        exit
    fi
    yay -Sy --noconfirm --cleanafter --norebuild aria2 python3 busybox zip unzip 7zip jdk21-openjdk zstd bc android-sdk-build-tools xmlstarlet
fi

if [ "$(uname -m)" == "aarch64" ];then
    echo "Device arch: aarch64"
    if [ "$(id -u)" != "0" ] && [ "$(uname)" == "Linux" ];then
        echo "Restarting script as root"
        exec sudo /bin/bash "$0" "$@"
        exit $?
    fi
    apt update -y
    apt upgrade -y
    apt install -y python busybox zip unzip p7zip openjdk-21 zipalign zstd xmlstarlet
fi

if [ "$(uname)" == "Darwin" ] && [ "$(uname -m)" == "x86_64" ];then
    echo "Device arch: macOS x86_64"
    pip3 install busybox
    brew install aria2 openjdk zstd coreutils gdu gnu-sed gnu-getopt grep xmlstarlet
fi
