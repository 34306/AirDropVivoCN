# AirDropVivoCN

> NOTE: DO IT AT YOUR OWN RISK! ALSO YOU NEED TO REDO THIS ONCE REBOOT BECAUSE THIS IS A TEMP ROOT, NOT PERSIST!

support Vivo X300 Ultra running OriginOS 6 (PD2547E_A_16.0.22.11.W10.V000L1 and older, for the root) able to use QuickShare and AirDrop. There will be 2 versions: 1 is the .sh for macOS (which i enable over adb root shell) and other version is for on device.

#### The steps will be

#### On macOS:
- Download 2 root APK i listed in credits and then run to get root
- Enable adb root in KernelSU settings
- Plug your device into your Mac
- `brew install android-platform-tools` (pls install homebrew if you dont have it)
- Clone this repo or download it as zip, then cd to `macos/` folder
- Run `./airdrop.sh`
- Enjoy!

#### On device:
- Download 2 root APK i listed in credits and then run to get root
- Clone this repo and take the on-device thing
- Load it by `ksud late-load`
- Enjoy?


I'm based iOS so this is my random time i do an Android project, it might f up something so please point me out. PR are welcome (?).
 
# Credits
For root, please install these 2 apk:
[DFRoot](https://github.com/diabl0w/DFRoot/releases/tag/v4.1)
[KernelSU](https://github.com/KernelSU-Next/KernelSU-Next/releases/tag/v3.4.0)


I based on this project:
[Mosey](https://github.com/thelok1s/mosey-extended)

# Disclaimer
This is an independent hobby project by an ordinary user who likes to tinker with and mod their devices. It is **not affiliated with, endorsed by, or supported by Google, vivo, Apple, or any other company**. All product names, logos, and brands mentioned are property of their respective owners and are used for identification purposes only.

This project is provided "as is", without warranty of any kind. Use it at your own risk. The author is not responsible for any damage to your device, data loss, or any other issues that may arise from using it.

# License
This project is licensed under the [GNU General Public License v3.0](LICENSE).
