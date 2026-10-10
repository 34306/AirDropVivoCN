# AirDrop cho vivo X300 Ultra bản Trung Quốc

Gói này bật AirDrop cho vivo X300 Ultra bản CN qua Quick Share của Google, bằng các thành phần lấy từ firmware quốc tế của vivo. Đã thử thành công: Quick Share trên máy CN thấy hai MacBook và gửi được tệp sang Mac qua AirDrop.

## Điều kiện

- vivo X300 Ultra bản CN, model V2547A, ROM `PD2547E_A_16.0.21.11.W10` với kernel `6.12.58-android16-6-g650e74cc80ec-abogki503021821-4k`. Script tự kiểm tra và dừng nếu máy khác.
- `adb shell` đã chạy với quyền root qua KernelSU Next. Gói này không cấp root.
- Máy đã có Google Play services và dùng được Quick Share.
- Máy tính macOS hoặc Linux có `adb` và `python3`.

## Cách dùng

```sh
./airdrop.sh          # bật mọi thứ và bật tự khởi động
./airdrop.sh status   # xem trạng thái
./airdrop.sh down     # gỡ ra, trả lại driver Wi-Fi gốc và tắt tự khởi động
```

Chỉ cần chạy `./airdrop.sh` từ máy tính một lần. Script cài module KernelSU `vivo_airdrop`. Sau mỗi lần khởi động lại máy, bạn nạp lại root như thường lệ, và module tự bật AirDrop ngay trên điện thoại sau khoảng 30 giây; log nằm ở `/data/local/tmp/airdrop/autostart.log`. Bật hay tắt Quick Share không cần chạy lại gì.

Nếu nối nhiều điện thoại, chạy `SERIAL=<serial> ./airdrop.sh`.

Trên Mac hoặc iPhone, đặt AirDrop thành **Mọi người trong 10 phút**. Trên điện thoại, chia sẻ một tệp, chọn Quick Share rồi chọn Mac hoặc iPhone. Để nhận, mở Quick Share, chọn Nhận và giữ màn hình sáng.

## Script làm gì

1. Cài Mosey nếu máy chưa có. Đưa Mosey thành ứng dụng priv-app bằng overlay chỉ đọc trên `/product`, rồi chạy `ksud soft-reboot` để khởi động lại phần Android. Kernel vẫn giữ nguyên.
2. Bind chỉ đọc bộ firmware Wi-Fi global `WLAN.GNG.2.0-01536` lên `/vendor/firmware_mnt/image/peach`. Firmware CN bị assert khi bật chế độ Passthru, và vivo sẽ khởi động lại máy sau đó.
3. Nạp `wonder_shim.ko`, một module tự viết có mã nguồn trong `shim/`. Thay driver Wi-Fi bằng bản global 5.2.1.144V, rồi nạp `wonder.ko`. Wi-Fi tắt vài giây trong lúc thay.
4. Overlay chỉ đọc thư viện daemon và khai báo VINTF vào `/system_ext`, thêm rule SELinux qua KernelSU, rồi chạy `mosey_server`.
5. Cấp `NETWORK_FACTORY` cho Mosey (đây là quyền role, root cấp được) và khởi động Mosey.
6. Thêm tile Quick Share vào trung tâm điều khiển. Bấm tile sẽ mở màn hình nhận. Tile được lưu trong cài đặt nên vẫn còn sau khi reboot.
7. Chạy một tiến trình giám sát giữ `mosey_server` và Mosey luôn sống. Google Play services không tự mở Mosey, nên khi Android dọn tiến trình Mosey, tiến trình giám sát mở lại nó sau vài giây. Sau 30 phút không dùng, Android còn đóng băng Mosey, làm Quick Share không thấy thiết bị Apple. Tiến trình giám sát đánh thức Mosey ngay khi Android hạ nó xuống nền.
8. Cài module KernelSU `vivo_airdrop`. Mỗi khi root được nạp lại sau reboot, script `late-load.sh` của module lặp lại các bước trên ngay trên điện thoại, không cần máy tính.

Mọi thứ nằm trong RAM. Script không ghi phân vùng và không remount đọc/ghi, nên khởi động lại máy là về nguyên trạng.

## Lưu ý

- iPhone tự chuyển AirDrop về **Chỉ danh bạ** sau 10 phút. Khi đó điện thoại không thấy iPhone nữa; bật lại **Mọi người trong 10 phút** trên iPhone.
- Khi tìm thiết bị, Mosey ngắt Wi-Fi nếu mạng đang nối dùng cùng băng 5 GHz với kênh 149, rồi tự nối lại.
- Không tự khởi động lại `servicemanager`. Các dịch vụ lõi sẽ không đăng ký lại, framework treo và máy tự reboot.
- Không flash firmware global lên máy CN.
- Gói có tệp nhị phân của vivo, Qualcomm và Google, trích từ firmware chính thức `PD2547F_EX_A_16.0.6.19`. Chỉ chia sẻ riêng cho người dùng cùng máy, đừng đăng công khai.

## Mã nguồn

- `shim/wonder_shim.c`: GPL-2.0, build với kernel `android16-6.12`.
- `wonder.ko`: GPL, [AOSP kernel/common-modules/wonder](https://android.googlesource.com/kernel/common-modules/wonder/).
- `qca_cld3_peach_v2.ko`: qcacld-3.0, [CodeLinaro](https://git.codelinaro.org/clo/la/platform/vendor/qcom-opensource/wlan/qcacld-3.0).
