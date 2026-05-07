<div align="center">

# ColorOS Porting Project

</div>

## Supported Devices

- Snapdragon 865/870 devices: OnePlus 8 Series, OnePlus 9R (CN), OPPO Find X3
- Snapdragon 888 devices: OnePlus 9 series (regularly tested on the OnePlus 9 Pro), OPPO Find X3 Pro

## Tested devices and port ROMs
- Tested bases:  OnePlus 8T (KB2000_14.0.0.600), OnePlus 8 (IN2010_13.1.190), OnePlus 8 Pro (IN2020_13.1.0.190), OnePlus 9 Pro (LE2123_14.0.0.1902)
- Test Port ROM: OnePlus 12 (ColorOS 14.0.0.800), OnePlus ACE3V(ColorOS 14.0.1.621), OnePlus 13T (ColorOS 16.0.2.400), OnePlus 10 Pro (OxygenOS 16.0.3.500), OnePlus 11 (OxygenOS 16.0.2.400), OnePlus 15 (ColorOS 16.0.5.702)
- Tested mixed parts: OnePlus 15 (OxygenOS_16.0.3.501), OnePlus 12 (16.0.5.700)

## Working features
- Face unlock
- Fingerprint
- Camera
- Automatic Brightness
- NFC
- etc


## Bugs
### General
- AOD is too dim (SM8250)
- Voice trigger is not working
- Poweroff charging is not working
- WiredEarphone is not working
### OS based issues
- Apps cannot be pinned as a live alert (16.0.5+)
- Video recording is broken (8 Series/9R)

## How to use
- On Debian based distros:
```shell
    sudo apt update
    sudo apt upgrade
    sudo apt install git -y
    # Clone project
    git clone https://github.com/blahajcoding/coloros_port.git
    cd coloros_port
    # Install dependencies
    ./setup.sh
    # Start porting
    sudo ./port.sh <baserom> <portrom>
```
WSL may work, but it is advised to use Linux on bare metal to maximise performance.
- On Arch Linux based distros:
```shell
    sudo pacman -Syu git # Always keep your computer up to date!
    # yay will automatically install if it's not on your system
    # Clone project
    git clone https://github.com/blahajcoding/coloros_port.git
    cd coloros_port
    # Install dependencies
    sudo ./setup.sh
    # Start porting
    sudo ./port.sh <baserom> <portrom> <portrom2>
```
- On other Linux based distros:
```shell
    # Install Distrobox. This can be done with your default package manager. If it doesn't work, install it with the following command:curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sudo sh
    # Start porting. All dependencies will be installed, and the script can be ran with root with this command.
    ./port_containerised.sh <baserom> <portrom> <portrom2>
``` 

- baserom, portrom and portrom2 can be a direct download link. OTAs can be acquired from sources like [Daniel Springer's OTA downloader.](https://roms.danielspringer.at/index.php?view=ota). If needed, downloadCheck links can be resolved for both portrom and portrom2.

## Credits
> In this project, some or all of the content is derived from the following open-source projects. Special thanks to the developers of these projects.

- [「BypassSignCheck」by Weverses](https://github.com/Weverses/BypassSignCheck)
- [「contextpatch」 by ColdWindScholar](https://github.com/ColdWindScholar/TIK)
- [「fspatch」by affggh](https://github.com/affggh/fspatch)
- [「gettype」by affggh](https://github.com/affggh/gettype)
- [「lpunpack」by unix3dgforce](https://github.com/unix3dgforce/lpunpack)
- [「miui_port」by ljc-fight](https://github.com/ljc-fight/miui_port)
- [「Link-Resolver」by CodeSenseiX](https://github.com/CodeSenseiX/Link-Resolver/)
- [「All-day fullscreen + 1Hz LTPO AOD」by TenSei](https://t.me/TenseiMods)
