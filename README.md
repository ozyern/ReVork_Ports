<div align="center">

# ColorOS Port Project


<p align="center">
  <b>A powerful tool to port ColorOS and OxygenOS effortlessly.</b><br>
  <i>Now optimized for OnePlus 9/9 Pro and Snapdragon 865/888 devices!</i>
</p>

</div>

---

## 📖 Introduction
A one-click tool designed to automatically port, modify, unpack, and repack ColorOS / OxygenOS ROMs.
It enables you to bring newer ColorOS firmware (e.g., from Android 14/15/16) to older capable devices like the OnePlus 8, 9, and Find X3 series.

## 📱 Supported Devices

### ✅ Officially Supported
- **OnePlus 8 Series**: OnePlus 8, OnePlus 8 Pro, OnePlus 8T, OnePlus 9R
- **OnePlus 9 Series**: OnePlus 9, OnePlus 9RT, OnePlus 9 Pro
- **OPPO Find X3 Series**: Find X3, Find X3 Pro

### 🧪 Tested Firmwares
- **Base ROM**: OnePlus 8T (ColorOS 14.0.0.600), OnePlus 8/8 Pro (13.1), OnePlus 9 Pro (OxygenOS 14.0.0.1920)
- **Port Source ROM**: OnePlus 15 (16.0.5.700), OPPO Find X9 Pro (16.0.5.701), OnePlus 13 (CN) (16.0.5.703)

---

## ✨ What's Working
- ✅ Face Unlock
- ✅ Camera Cutouts (Punch hole display)
- ✅ Screen Fingerprint Scanner (FOD)
- ✅ Camera Features (Hasselblad Master Mode enabled)
- ✅ NFC
- ✅ Auto Brightness
- ✅ 120Hz Smart Refresh Rate
- ✅ 50W AIRVOOC & 65W SuperVOOC Charging enabled 

## 🐛 Known Bugs
- ❌ **Breeno Voice Assistant:** Voice wake-up is currently not working.
- ❌ **Off-Mode Charging:** When the device is off and plugged in, it will auto-reboot.
- ❌ **Type-C Earphones:** Some wired headsets might not be recognized properly.

*(Feel free to submit PRs or place fix zips under your `devices/` directory!)*

---

## 🚀 How To Use
It's highly recommended to perform this in a modern Linux environment such as **Ubuntu 20.04/22.04, WSL2, or Deepin**:

```bash
# 1. Update system and install required apt packages
sudo apt update && sudo apt upgrade -y
sudo apt install git curl unzip -y

# 2. Clone the repository
git clone https://github.com/ozyern/coloros_port.git
cd coloros_port_kebab

# 3. Setup and install core packaging tools/dependencies
sudo ./setup.sh

# 4. Start porting!
# Usage: sudo ./port.sh <Path-to-BaseROM> <Path-to-PortROM>
sudo ./port.sh /path/to/baserom.zip /path/to/portrom.zip
```

### 📦 OnePlus 9 Pro Specific Enhancements
Significant optimizations have been engineered specifically for the OnePlus 9 Pro:
- Restores **Hasselblad Master Mode** configs for newer camera framework implementations.
- Included logic to detect and flash any custom kernels (like SukiSU or Rapchick) via AnyKernel directly from `devices/OnePlus9Pro/`.
- Automated `camera5.0/camera6.0` framework injections for full functionality on Android 15 and 16.
- Integrated `os.charge.settings.wirelesscharging.power` attributes specifically granting 50W wireless capabilities in the Settings app for the device.
- Full Live Photo configuration injection and NFC APEX replacements for A16 compatibility.

---

- Massive thanks to every contributor moving the ColorOS custom community forward!

<p align="center">
  Made with ❤️ by Ozyern & Community
</p>