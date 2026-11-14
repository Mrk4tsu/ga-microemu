# Triển khai roadmap tương thích iOS

Ngày: 2026-11-14. Giữ miniJVM pin `76f904ea4008a8058db5155bf5ee2cfe94d19e60`. Android ở nhánh riêng. Hai tài liệu đánh giá ban đầu không bị sửa.

## Phần đã đưa vào runtime

1. **Reflection:** chuẩn hóa `parameterTypes=null` cho bốn API lookup Method/Constructor bằng patch có guard trong bước chuẩn bị miniJVM. Kiểm thử đối chiếu với Java trên máy, gồm invoke không tham số, field, chữ ký sai và public/private. Không nới quyền truy cập private.
2. **Phiên:** luồng supervisor không chạy constructor, class initializer hoặc callback game, kể cả phương thức báo lỗi Throwable có thể bị override. Worker và luồng con có owner/generation native độc lập với ContextClassLoader. Stop có latch riêng ngoài FIFO, cờ hủy bền và đường unwind không qua Java exception; kiểm tra tại method entry/backward branch và các native wait đã hỗ trợ. Self-loop `goto 0` cũng phải đi qua GC safepoint. `System.exit()` của game yêu cầu dừng phiên đó. Chỉ đóng loader và báo hoàn tất khi worker cùng mọi thread đăng ký đã quiesce. Callback destroy có 150 ms để kết thúc bình thường trước khi hủy.
3. **MIDlet:** context riêng theo instance; callback bind/restore context. Display dispatcher giữ context của chủ sở hữu. MIDlet con tự thông báo kết thúc không làm dừng MIDlet gốc. Input đi tới Display đang hoạt động, với fallback về root khi context con đã bị xóa.
4. **Input:** Canvas text được phát theo lịch nhấn/thả, không ngủ trong dispatch từng ký tự; TextBox vẫn commit trực tiếp. FIFO tối đa 256 event, tối đa 16 KiB mỗi payload và 64 KiB text đang chờ. Khi quá tải, reset gesture/phím đã giao thay vì bỏ mất key-up hoặc tự đóng game. Motion liền kề và lifecycle liền kề được gộp; Stop không phụ thuộc các event này.
5. **Tài nguyên:** surface có owner/generation, số lượng và native bytes; release theo phiên và idempotent. Các thao tác raster/present được bảo vệ bằng cùng surface lock; UIKit sao chép pixel trước khi trả về. Finalizer ảnh là đường dự phòng. Registry TCP giữ native socket context sống cho tới khi close hoặc sau quiescence; Stop shutdown các socket đã connect để đánh thức I/O, rồi đóng trực tiếp. RMS handle được vô hiệu hóa sau khi thread đã ngừng; cơ chế snapshot/RMS suite identity được giữ. Quota hiện tại: 128 MiB surface mỗi phiên, 256 MiB toàn runtime; đây là giới hạn ban đầu, chưa phải kết quả tối ưu từ số đo iPhone.
6. **Phân tích/profile:** `JarAnalyzer` chỉ đọc archive và header class, không khởi tạo class game. SHA-256 dùng thư viện native đã có. Cache metadata khóa theo fingerprint, schema và runtime version; JAD ngoài JAR không dùng cache này. CLI `inspect_midlet.py` có schema version, candidates, densities và API references/reflection. `CompatibilityProfile` tách quyết định viewport khỏi loader; mặc định giữ kích thước frontend yêu cầu. Chưa thêm rule theo fingerprint khi chưa có phép thử chứng minh cần thiết.
7. **LCDUI adapters:** dùng model/layout/traversal của MicroEmulator cho Form/List/TextField/StringItem/ImageItem/ChoiceGroup/Gauge/DateField/CustomItem. TextField đang focus trong Form mở editor native bằng phím Fire; commit quay về dispatcher của Display. Sửa khôi phục focus của Form và select command khi chạm List. Không thêm runtime của emulator khác.

## Cấu hình từng game

UIKit có bộ chọn kích thước trước mỗi phiên mới, gồm preset/custom/Full screen, nhớ lựa chọn theo tên JAR. Lựa chọn này ưu tiên hơn profile file cũ. Full screen thử lại một lần ở vùng vẽ nhỏ hơn nếu lỗi ảnh trước khung hình đầu tiên; xem [screen-size-selection.md](screen-size-selection.md).

Đường chạy host cũ vẫn hỗ trợ file người dùng: `<rmsPath>/profiles/<sha256-JAR>.properties`. File có thể chứa:

```properties
viewport=requested
width=320
height=480
```

`width`/`height` phải có cùng nhau, từ 128 tới 1920. Bỏ hai khóa để dùng kích thước frontend. `viewport=legacy-x1-budget` là lựa chọn rõ ràng để dùng ngân sách pixel cũ, không phụ thuộc tên thư mục tài nguyên. Log ghi fingerprint, schema/runtime, nguồn cấu hình và kích thước cuối. Cache trong `<rmsPath>/analysis/`; profile/cache không đổi namespace hoặc xóa RMS.

## Kiểm chứng

Chạy trên Windows x64, MSVC và JVM thông dịch thật:

- Tám kiểm thử Python về đóng gói/project/JAR metadata và bài C raster.
- Smoke cũ: private-call bytecode, density/alpha/transform, RMS persistence, TCP/HTTP loopback, manifest thiếu, một/nhiều tab và runtime mã hóa.
- Lifecycle cũ: render lock, idle TCP reader, nhập text khi GC chạy, TextBox commit và Stop khi editor đang mở.
- Session fixtures: reflection đối chiếu; block constructor/class initializer/start/destroy; CPU loop kể cả self-loop khi GC, Object.wait và luồng con bắt Throwable/đổi CCL; text dài, FIFO quá tải, wrapper tạo hai MIDlet con và nhận input đúng Display/context, System.exit và 30 phiên liên tiếp. Bộ đếm surface/native image bytes/TCP/queue được đọc độc lập từ bridge sau mỗi phiên.
- Hai tab: Stop tab A khi TCP chưa có dữ liệu; tab B vẫn vẽ và trao đổi TCP, sau đó cả hai phiên đều thu hồi tài nguyên.
- Profile: tài nguyên x1 với viewport mặc định 600×800; override 320×480; legacy budget 339×452; cache hit khi mở lại.
- UI: Form/Items, ChoiceGroup/Gauge/DateField, CustomItem paint, TextField native commit/item-state listener, List traversal và command.
- Patch áp dụng lên source miniJVM pin nguyên bản và chạy lại cho kết quả byte-for-byte giống nhau.

Năm JAR tại `Downloads/TestJar` đều đã có frame và `TAB_FINISHED result=0`: GENZ, KnightOnline v403, DragonBoy252, Hải Tặc Tí Hon 124, Dragonboy250 v6.0. V6 chưa có frame trong lượt đầu giới hạn 8 s; lượt chạy 20 s có cache đã lên màn hình tải dữ liệu và Stop thành công. Không nhập tài khoản hoặc thực hiện đăng nhập trong lần thử này. Các ảnh/log/JAR thật ở `ios/build/roadmap-implementation/`, không đưa vào commit/CI.

## Giới hạn và phần còn lại

- Chưa build Xcode/IPA hoặc chạy iPhone trong môi trường Windows này; cần kiểm tra năm JAR, nhập liệu, nhiều tab và số đo latency/frame time/RAM trên thiết bị.
- Registry I/O hiện theo dõi TCP. DNS, connect còn đang thực thi và TLS/native call tùy ý chưa có cam kết thời gian hủy; supervisor giữ STOPPING và không free tài nguyên đang được thread sử dụng. Không gọi reset toàn JVM như hành vi mặc định của Stop tab.
- Đây không phải chứng nhận đầy đủ MIDP/Java SE 8. Model Form vẫn có giới hạn xử lý pointer của MicroEmulator; fixture xác minh traversal bằng phím và editor native. DateField/CustomItem và các JSR cần corpus/kiểm thử thiết bị rộng hơn.
- UIKit có bộ chọn kích thước, chưa có editor cho mọi khóa profile; chưa có rule tự kích hoạt workaround theo fingerprint. Chỉ thêm rule khi có đối chứng tái hiện.
- Native image bytes được kiểm chứng riêng; kết quả không khẳng định toàn bộ Java heap/RSS không tăng, hoặc mọi native API đã được cô lập.

## Nguồn tham khảo kiến trúc

Tham khảo ý tưởng, không sao chép runtime hoặc thêm dependency:

- [J2ME-Loader ProfileModel](https://github.com/nikita36078/J2ME-Loader/blob/master/app/src/main/java/ru/playsoftware/j2meloader/config/ProfileModel.java): cấu hình theo ứng dụng; chuyển thành `CompatibilityProfile` độc lập với Android.
- [FreeJ2ME-Plus](https://github.com/TASEmulators/freej2me-plus): ranh giới frontend; giữ frame/input/modal qua bridge hiện có, quyết định lifecycle/profile nằm trong lớp runtime.
- [WIE](https://github.com/dlunch/wie/blob/main/CONTRIBUTING.md): tham khảo cách chia các thành phần emulator; giữ adapter nền tảng riêng và runtime miniJVM hiện có.
