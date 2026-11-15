# GaEmulator cho Android

Tác giả ứng dụng: **MrK4tsu**, lưu trong metadata manifest (`com.gamod.gaemulator.AUTHOR`), mô tả ứng dụng (`android:description`) và notice đi kèm. Không thêm dòng tác giả trên vùng chơi hoặc thư viện. Metadata tùy chỉnh không tự tạo mục tác giả trong màn hình Thông tin ứng dụng của Android; việc hiển thị phụ thuộc hệ thống hoặc công cụ đọc thông tin APK. Tác giả của từng JAR vẫn lấy từ metadata của game.

Ứng dụng Android dùng chung miniJVM, MIDP/CLDC, bộ vẽ raster, RMS và TCP/HTTP với bản iOS. JAR được chạy trực tiếp trong interpreter; không chuyển từng game thành DEX hoặc APK. Module Android Ant cũ vẫn được giữ nguyên.

Đánh giá tùy chọn chia class khi chuyển DEX và hướng xử lý JAR lớn: [dex-feasibility.md](docs/dex-feasibility.md).

## Cài bản APK

Trong GitHub Actions, chạy workflow **Build Android APK**, rồi tải artifact **GaEmulator-Android-APK**. Cài tệp **GaEmulator-debug.apk** trên điện thoại Android 8.0 trở lên. APK chung hỗ trợ **arm64-v8a, armeabi-v7a và x86_64**.

- Chọn **Mở JAR** để thêm game từ trình quản lý tệp; hoặc chọn **Mở bằng/Chia sẻ → GaEmulator** khi tải JAR.
- App sao chép JAR vào thư viện riêng. Hai tệp trùng tên nhưng khác nội dung được giữ riêng; mở lại cùng nội dung sẽ chuyển đến game đang chạy.
- **Tab** chuyển giữa tối đa 8 game hoặc quay về thư viện. Game ở tab khác được giảm nhịp vẽ.
- Chạm trực tiếp vào màn game, dùng phím điều hướng/số, hoặc **Bàn phím** cho game tự vẽ ô nhập. TextBox mở hộp nhập Android, gồm ô mật khẩu và ràng buộc độ dài.
- **Dừng** đóng phiên hiện tại. RMS được giữ khi mở lại cùng JAR; xóa dữ liệu ứng dụng trong Android sẽ xóa cả thư viện và RMS.
- **Log** xem hoặc chủ động chia sẻ log. Không gửi tự động.
- Lần đầu mở mỗi JAR, chọn preset, kích thước tùy chỉnh **128–1920 pixel mỗi chiều**, hoặc **Full màn hình**. Các lần sau mở trực tiếp với thiết lập đã lưu theo SHA-256 của JAR. Nhấn **ⓘ** cạnh game để sửa cho lần chạy tiếp theo.
- Dòng mô tả game ưu tiên `MIDlet-Author`, `Author`, rồi `MIDlet-Vendor`; thiếu thì hiện Java ME. Việc đọc metadata không chạy class game.

Kích thước cố định giữ tỷ lệ framebuffer và dùng cùng phép đổi tọa độ cho cảm ứng. Full màn hình tính vùng vẽ từ vùng chơi hiện tại (theo dp), phóng đầy vùng hiển thị và đổi tọa độ chạm riêng theo hai chiều. Với lỗi ảnh trước frame đầu tiên, runtime chung dọn phiên rồi thử lại một lần với vùng vẽ nhỏ hơn; ví dụ 428×541 → 348×440, sau đó Android phóng ảnh lên. Lỗi, kích thước và đường dẫn tài nguyên được ghi trong Log. Sau frame thành công không tự khởi động lại game. Stop dùng supervisor/cancellation và registry tài nguyên chung của bản iOS đã sửa.

APK Actions là bản debug ký bằng **khóa phát triển công khai** android/debug.keystore (mật khẩu android). Giữ cùng khóa giúp cài cập nhật các lần build liên tiếp. Đây là khóa dành cho bản phát triển/sideload; bản phân phối chính thức cần khóa phát hành riêng. Version code lấy từ GITHUB_RUN_NUMBER, hoặc tham số Gradle -PgaVersionCode=N.

## Build cục bộ

Cần JDK 17, Android SDK 35, Build Tools 35.0.0, NDK 28.2.13676358 và CMake 3.22.1. Gradle Wrapper được pin 8.9, Android Gradle Plugin 8.7.3.

Các phiên bản được pin theo [ma trận AGP 8.7](https://developer.android.com/build/releases/agp-8-7-0-release-notes). Bước kiểm tra APK xác minh ELF và ZIP alignment theo [hướng dẫn 16 KB của Android](https://developer.android.com/guide/practices/page-sizes).

Từ thư mục repo:

    python3 android/tools/prepare_assets.py
    python3 android/tools/run_host_tests.py
    cd android
    ./gradlew :app:assembleDebug :app:assembleAndroidTest :app:lintDebug

Trên Windows dùng python và gradlew.bat. Cấu hình SDK bằng ANDROID_HOME hoặc android/local.properties. APK nằm ở android/app/build/outputs/apk/debug/app-debug.apk.

prepare_assets.py lấy đúng revision miniJVM đã pin bởi bản iOS, áp dụng cùng các bản sửa, biên dịch Java ME bằng bootclasspath của miniJVM, mã hóa runtime assets và sao chép license notices. Chạy script này sau khi thay đổi mã Java ME. Các JAR runtime là assets; chỉ mã giao diện Android đi qua D8.

## Kiểm thử

Workflow có hai job:

1. Build đủ ba ABI, chạy lint và xác nhận hai runtime assets, ELF/ZIP 16 KB alignment.
2. Cài APK trên Android Emulator và chạy instrumentation bằng JNI thật: font hệ thống/chiều chữ, framebuffer, cảm ứng mở TextBox và nhận kết quả, GC trong lúc vẽ, TCP nhị phân, HTTP, RMS qua hai lần chạy, Stop và hủy JVM với socket đang chờ. Thêm kiểm tra thiết lập lần đầu/lần sau, ưu tiên tác giả, Full màn hình với ảnh x1 mã hóa, thu hồi registry và Stop khi startApp bị chặn trong khi tab bên cạnh vẫn hoạt động.

Có thể chạy instrumentation trên thiết bị/emulator đã kết nối:

    adb install -r android/app/build/outputs/apk/debug/app-debug.apk
    adb install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
    adb shell am instrument -w com.gamod.gaemulator.test/com.gamod.gaemulator.SmokeInstrumentation

Kết quả thành công có marker GA_ANDROID_INSTRUMENTATION_PASS. Instrumentation dùng JAR thử nghiệm tự biên dịch từ nguồn trong repo và server loopback; không chứa game/tài khoản người dùng, không truy cập server game thật. APK test là artifact riêng, không cần cài để sử dụng GaEmulator.

Kiểm chứng cục bộ ngày 2026-11-15 trên Windows: build APK/app test đủ ba ABI, lint không có lỗi, kiểm tra cấu trúc APK và alignment 16 KB đều đạt; tám bài Python về project/đóng gói/metadata, bộ đọc metadata Android với ZIP thật và các bộ compatibility/session trên host cũng đạt. Android Emulator trên máy thiếu tăng tốc, thử chạy phần mềm chưa boot được; vì vậy chưa chạy instrumentation hoặc chơi game thật trên Android trong môi trường này. Không coi việc biên dịch APK test là kết quả instrumentation đã đạt. Cần kiểm tra trên điện thoại hoặc runner Android trước khi xác nhận đăng nhập, cảm ứng/IME, xoay màn hình và hiệu năng thiết bị.

## Mã dùng chung và giấy phép

Android chỉ thêm adapter JNI/UI. Tên package nội bộ org.microemu.ios được giữ để chia sẻ những bản sửa tương thích JAR, không làm thay đổi tên ứng dụng Android. Game nhận microedition.platform=MicroEmu-Android; iOS giữ giá trị cũ.

MiniJVM và các thành phần đi kèm giữ giấy phép gốc. Notices được đóng gói tại assets/ThirdParty; nguồn phụ thuộc được pin trong ios/tools/prepare_runtime.py. Các file mới trong android/ theo Apache-2.0.
