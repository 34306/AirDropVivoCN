# AirDropVivoCN

> NOTE: DO IT AT YOUR OWN RISK!

support Vivo X300 Ultra able to use QuickShare and AirDrop. There will be 2 versions: 1 is the .sh for macOS (which i enable over adb root shell) and other version is for on device.

#### The steps will be

#### On macOS:
- Download 2 root APK i listed in credits and then run to get root.
- Enable adb root
- Plug your device into your Mac
- `brew install android-platform-tools` (pls install homebrew if you dont have it)
- Clone this repo or download it as zip, then cd to macos/ folder
- Run ./airdrop.sh
- Enjoy!

#### On device:
- Download 2 root APK i listed in credits and then run to get root.
- Clone this repo and take the on-device thing.
- Load it by `ksud late-load`
- Enjoy?


I'm based iOS so this is my random time i do an Android project, it might f up something so please point me out. PR are welcome (?).
 

# Credits
For root, please install these 2 apk:
[DFRoot](https://github.com/diabl0w/DFRoot/releases/tag/v4.1)
[KernelSU](https://github.com/KernelSU-Next/KernelSU-Next/releases/tag/v3.4.0)


I based on this project:
[Mosey](https://github.com/thelok1s/mosey-extended)
