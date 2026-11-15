# Quản lý bộ nhớ bổ sung trên iOS

Mở **☰ → Quản lý bộ nhớ** trong màn hình chơi hoặc tổng quan tab; thư viện JAR cũng có nút ☰. Tùy chọn lưu bằng NSUserDefaults khi nhấn Lưu; Hủy giữ cấu hình cũ. Dọn ngay là một thao tác độc lập với việc lưu biểu mẫu.

## Tác dụng và mặc định

miniJVM pin hiện tại đã có GC theo áp lực heap và chu kỳ mặc định 10 giây (`GARBAGE_PERIOD_MS_DEFAULT`). Thêm một timer GC 60 giây thường không giúp nhiều. Tính năng mới là yêu cầu **bổ sung**, không thay thế hoặc tắt GC của runtime.

- Tự động dọn bổ sung: bật mặc định để phản ứng với cảnh báo thiếu bộ nhớ của iOS.
- Ngưỡng RAM app: mặc định 0 (tắt); cho phép 64–32768 MB. Đây là ngưỡng kích hoạt theo footprint của GaEmulator, không phải giới hạn cứng, tổng RAM hệ thống hoặc Java Xmx.
- Chu kỳ: mặc định 0 (tắt); cho phép 30–86400 giây.
- Các yêu cầu tự động cách nhau ít nhất 30 giây; thao tác thủ công cách nhau ít nhất 5 giây. Một yêu cầu đang chờ/chạy được gộp lại, không xếp hàng nhiều lượt GC.
- MB trong giao diện tương ứng 1048576 byte. Thiết bị cũ dùng resident size nếu không lấy được phys_footprint.

Phần frontend thu nhỏ ảnh xem trước của tab nền đang sleep, tối đa 240 pixel ở cạnh dài, và bỏ bản sao frame còn chờ của tab đó. Ảnh đang chơi giữ nguyên; chọn tab nền sẽ nhận lại khung hình đầy đủ khi runtime vẽ tiếp. Cache icon/metadata của thư viện được bỏ để có thể tải lại. Không xóa dữ liệu RMS, đóng socket hoặc giải phóng surface mà game còn dùng.

Đường yêu cầu GC chỉ trao đổi trạng thái/token giữa frontend và host. Host sử dụng giao thức yêu cầu bất đồng bộ của collector trong runtime đã pin; GC và finalizer chạy trên luồng collector. Không đưa con trỏ VM cho UIKit, không gọi GC đồng bộ trên luồng giao diện và không sửa ngân sách heap-limit đang chờ của allocator. Khi shutdown, API chuyển sang unavailable trước khi hủy VM. Sau 5 giây chưa có xác nhận, UI báo chưa xác nhận, không ép đóng game.

Kết quả hiển thị RAM app trước/sau, kể cả khi RAM không giảm hoặc tăng; log `[MEMORY]` có thêm số đo heap và thời gian tới xác nhận. Số đo RAM app còn chịu ảnh hưởng của game, UIKit và allocator; nó không phải phép đo riêng lượng rác GC thu hồi.

## Giới hạn

GC chỉ thu hồi đối tượng không còn được dùng. Ảnh đang sống, framebuffer, class, socket và dữ liệu game vẫn chiếm RAM. GC không sửa được leak do game giữ tham chiếu, không bảo đảm app tránh bị iOS kết thúc và có thể làm khựng hình. Collector cũng chỉ trim các block trống về OS khi thỏa điều kiện riêng (committed lớn hơn hai lần live, cooldown 30 giây); heap giảm không bảo đảm footprint giảm ngay.

Apple hướng dẫn giải phóng cache có thể dựng lại khi có [cảnh báo bộ nhớ](https://developer.apple.com/documentation/uikit/responding-to-memory-warnings). Có trường hợp cấp phát lớn gây kết thúc app trước khi nhận được cảnh báo; xem [Responding to low-memory warnings](https://developer.apple.com/documentation/xcode/responding-to-low-memory-warnings). Không nên coi timer hoặc ngưỡng RAM là cơ chế chống crash chắc chắn.

## Kiểm chứng trên host Windows

`memory-policy-test` kiểm tra cấu hình tắt/mặc định, biên ngưỡng, chu kỳ, cảnh báo liên tục, cooldown và đồng hồ lùi.

`run_cleanup_smoke.py` chạy interpreter thật: game giữ 8 MiB dữ liệu sống và tạo 24 MiB rác, rồi một luồng native độc lập gửi yêu cầu dọn. Một lượt đo: heap giảm từ 37503056 xuống 9029832 byte (27,15 MiB, gồm cả rác khởi động ngoài fixture). Toàn bộ 8 MiB dữ liệu sống vẫn đọc đúng. Hai yêu cầu đồng thời được gộp; luồng native tiếp tục gửi yêu cầu trong khi Stop/shutdown; sau hủy VM, API trả unavailable và registry phiên rỗng. Thời gian từ yêu cầu đến xác nhận trong lượt đó là 20 ms, **không phải thời gian dừng toàn bộ game hoặc cam kết frame time**.

```text
ctest --test-dir ios/build/session-host -C Release --output-on-failure
python ios/tools/run_cleanup_smoke.py --executable ios/build/session-host/Release/microemu-headless.exe
```

Phép thử tổng hợp kiểm chứng có thu hồi rác và không phá dữ liệu sống; chưa chứng minh mức giảm footprint trên iPhone, mức tăng FPS hoặc lợi ích khi GC tự động đã chạy đủ thường xuyên. Windows không build/chạy UIKit hoặc IPA. Cần kiểm tra trên thiết bị: Lưu/Hủy và mở lại app, ngưỡng/chu kỳ/tắt tự động, Dọn ngay khi không có game, nhiều tab và chọn lại thumbnail sau dọn, hộp nhập đang chờ khi mở/đóng settings, mở JAR từ Files trong lúc sửa cấu hình, và cảnh báo bộ nhớ bằng iOS Simulator/Instruments.
