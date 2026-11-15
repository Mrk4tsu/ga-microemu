# Giảm bộ nhớ khi nạp JAR bằng miniJVM

Ngày kiểm chứng: 2026-11-15. Áp dụng cho cả iOS và Android, giữ miniJVM pin hiện tại. Không thêm bước chuyển DEX.

## Các thay đổi

- `IOSClassLoader` chỉ lập chỉ mục tên entry, không giữ `ZipEntry.contents` đã giải nén.
- `ArchiveIO` dùng reader ZIP native theo luồng, với buffer Java 8 KiB. Mỗi lần đọc native tối đa 16 KiB; các bộ đệm giải nén và central directory của miniz vẫn có chi phí riêng.
- Analyzer chỉ đọc magic/version, constant pool và thông tin kế thừa/access flags, rồi đóng luồng; không nạp phần thân class chỉ để thống kê. Cache metadata vẫn khóa theo SHA-256, schema và runtime version; runtime version tăng thành `minijvm-76f904ea-microemu-2`.
- Nạp class cấp phát một mảng đúng kích thước, đọc trực tiếp vào mảng đó. Adapter sửa private-call bytecode nhận buffer thuộc riêng loader và sửa tại chỗ; không sửa JAR hoặc dữ liệu cache chung.
- Reader có owner/generation bất biến. Close trực tiếp và finalizer đều idempotent; Stop thu hồi reader bị bỏ quên sau khi các thread của phiên đã quiesce. `EmResourceStats.zip_count` và log headless xác minh số handle còn sống.
- Giữ mark/reset bằng cách phát lại entry với buffer cố định, không giữ toàn bộ dữ liệu kể từ mark. Giữ `available()` và hành vi đọc đầy buffer của resource stream cũ: một số game cấp phát `available()` byte rồi chỉ gọi `read()` một lần. Vòng đọc vẫn có điểm hủy giữa các khối native.
- CRC được xác minh khi đọc hết entry. Đóng sớm sau khi đọc header không giải nén nốt cả entry để kiểm CRC; bước nạp class thực tế đọc toàn bộ và xác minh CRC.

## Phép đo kiểm soát trên Windows x64

Fixture có 24 entry, mỗi entry giải nén thành 1 MiB, và tám class phụ có attribute 4 MiB để kiểm tra analyzer không đọc phần thân. Chạy interpreter thật, cùng executable và bootstrap. Bản đối chứng dùng `IOSClassLoader`, `IOSHost` và `JarAnalyzer` từ commit `c47c5df`, biên dịch vào JAR riêng trong thư mục build; không hoàn tác mã trong workspace.

| Chỉ số | Trước tối ưu | Sau tối ưu |
| --- | ---: | ---: |
| Bộ nhớ allocator giữ thêm sau đọc/đóng 24 MiB resource và chờ GC | 25.174.152 byte, khoảng 24 MiB | 4.248 byte, khoảng 4,15 KiB |
| Đỉnh working set của tiến trình Windows | 108.888.064 byte, khoảng 103,84 MiB | 24.317.952 byte, khoảng 23,19 MiB |
| Delta allocator khi mở hai stream 1 MiB, chưa đọc hết | — | 19.840 byte |

Các số trên là một phép thử tổng hợp, không phải mức RAM của game thật. Delta dùng `Runtime.totalMemory() - freeMemory()` của miniJVM; đỉnh working set lấy từ tiến trình con Windows. Chúng không phải cùng một chỉ số. Kết quả có thể dao động giữa các lượt và thiết bị. Log/JSON cục bộ nằm trong `ios/build/memory-optimization/`, không đưa game hoặc build artifact vào Git.

## Kiểm chứng

`run_memory_smoke.py` khóa lỗi giữ buffer bằng ngân sách 4 MiB cho bộ resource 24 MiB. Các ca khác kiểm tra mở stream không cấp phát toàn payload, hai vị trí đọc độc lập, mark/reset vượt buffer, một lần read cho toàn resource, skip, entry rỗng/STORED, CRC sai, close/read sau close, Stop thu hồi tám reader game cố ý bỏ quên và hủy luồng đọc/reset liên tục sau khi đổi CCL và GC. Phép thử chạy trong workflow iOS; Android instrumentation có ngân sách resource và kiểm tra thu hồi reader.

Ví dụ chạy:

```text
python ios/tools/run_memory_smoke.py --executable ios/build/session-host/Release/microemu-headless.exe --report ios/build/memory-check.json
```

Các bộ smoke, compatibility, session, lifecycle và LCDUI tiếp tục kiểm tra runtime thật. Trong kiểm tra game đã phát hiện một race khi Stop giữa hai lần lấy DisplayAccess; bộ vẽ và đoạn clean nay giữ một tham chiếu cục bộ. Fixture `paint-stop` mở/vẽ/dừng 30 phiên để kiểm tra việc này.

Cả năm JAR Dragonboy250 v6.0, DragonBoy252, HAI TAC GENZ, Hải Tặc Tí Hon 124 và KnightOnline v403 đều lên frame rồi Stop thành công trên host. DragonBoy252 dùng retry viewport 348×440. Đây là kiểm tra khởi động/dừng, chưa xác nhận đăng nhập hoặc chơi online đầy đủ.

## Giới hạn

Class được thực thi vẫn cần một mảng bytecode đầy đủ để `defineClass`; metadata/index và các class đã nạp vẫn dùng bộ nhớ. Native inflater, ảnh đã giải mã, framebuffer, thread và dữ liệu game cũng tiếp tục dùng RAM. Game tự sao chép toàn tài nguyên vào mảng riêng vẫn phải trả chi phí đó. Adapter không tự giải mã định dạng bảo vệ của game và không hạ heap limit hay ép GC trong luồng chạy bình thường.

Mở lại resource hoặc reset về vị trí cũ có thể cần giải nén lại. Chưa có số đo frame time hoặc pin trên thiết bị để kết luận về đánh đổi CPU; chỉ mục ZIP vẫn tăng theo số entry/tên file, không phải bộ nhớ hằng số cho mọi JAR.

Đã có số đo và kiểm thử trên host Windows. APK Android được cross-build; chưa đo RAM hoặc chạy instrumentation của thay đổi này trên điện thoại/Android Emulator, và chưa build UIKit/IPA trên máy Windows này.
