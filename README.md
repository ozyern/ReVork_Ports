<div align="center">


# Project ReVork



</div>

## Intro
- Project ReVork

## Supported Devices

- OnePlus 8 OnePlus 8Pro OnePlus 8T OnePlus 9R(CN)
- OnePlus 9 OnePlus 9Pro OnePlus 9RT
- Oppo Find X3 Oppo Find X3 Pro

## Tested devices and portroms
- Test Base ROM:  OnePlus 9 Pro (OxygenOS_14.0.0.1902)
- Test Port ROM: OnePlus 15 (OxygenOS 16.0.5.700)
## Working
- Face unlock
- Fringerprint
- Camera
- Automatic Brightness
- NFC
- etc


## BUG

- Poweroff charging is not working
- WiredEarphone is not working

## How to use
- On WSL、ubuntu、deepin and other Linux
```shell
    sudo apt update
    sudo apt upgrade
    sudo apt install git -y
    # Clone project
    git clone https://github.com/ozyern/coloros_port.git
    cd coloros_port_keb
    # Install dependencies
    sudo ./setup.sh
    # Start porting
    sudo ./port.sh <baserom> <portrom>
```
- baserom and portrom can be a direct download link. you can get the ota download link  from third-party websites.
