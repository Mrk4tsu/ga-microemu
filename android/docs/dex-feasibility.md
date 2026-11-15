# Chia class để chuyển DEX và GaEmulator

Đánh giá ngày 2026-11-15. Chưa triển khai backend DEX.

## Kết luận

Chia class thành từng đợt có ích với engine chuyển Java bytecode sang DEX khi bước chuyển đổi thiếu RAM. Đây là hướng khả thi cho một backend Android riêng. Nó không phải tùy chọn có thể gắn ngay vào luồng nhập hiện tại: GaEmulator dùng miniJVM để chạy bytecode `.class`, không chạy game bằng DEX/ART.

Không đồng nhất kích thước JAR với độ khó chuyển đổi. JAR lớn vì ảnh/âm thanh không nhất thiết có nhiều mã. Chỉ giới hạn 50 class mỗi đợt cũng không giới hạn được lượng byte hoặc số tham chiếu phương thức của một class lớn.

## Cơ chế tham khảo

- [D8 của Android](https://developer.android.com/tools/d8) nhận `.class`/JAR/ZIP và tạo DEX, hỗ trợ đầu ra trung gian và theo class.
- [Bản backport J2ME-Loader](https://github.com/revgato/J2ME-Loader-backport-android-2.3#recommended-game-conversion-workflow) mô tả chuyển theo lô và chia tiếp lô bị thiếu bộ nhớ, rồi nạp nhiều phần DEX. Đây là một triển khai tham khảo, không khẳng định ứng dụng trong ảnh là bản đó.
- [Multidex](https://developer.android.com/build/multidex) xử lý giới hạn tham chiếu của một DEX. Việc chia đợt để giảm RAM là một mục đích khác; không nên dùng số class để suy ra giới hạn phương thức.

Chuyển đổi vẫn cần bytecode đọc được. Làm rối tên class không giống mã hóa nội dung class. Ảnh/tài nguyên mã hóa vẫn cần logic giải mã của game hoặc adapter đúng định dạng; chia DEX không tự cung cấp logic đó. Class hoặc ZIP thực sự mã hóa phải được đọc/giải mã hợp lệ trước bước chuyển đổi.

## Những điểm cần đo trong miniJVM hiện tại

Importer Android (`GameStore.importJar`) đã sao chép theo khối 64 KiB và tính SHA-256 trong cùng lượt; giới hạn JAR hiện là 256 MiB. Không nạp toàn bộ JAR vào một `byte[]` ở bước sao chép.

Trước tối ưu, `IOSClassLoader` giữ entry cùng nội dung giải nén và sao chép bytecode qua `ByteArrayOutputStream`/`toByteArray`; analyzer đọc trọn mỗi class để lấy header. Các đường đọc này nay dùng `ArchiveIO`: ZIP theo luồng, chỉ mục tên, đọc riêng header và buffer bytecode thuộc riêng loader. Số đo đối chứng và giới hạn tại [archive-memory.md](../../ios/docs/archive-memory.md). Thay đổi đi qua adapter chung, không cần đổi miniJVM sang DEX.

Với các JAR còn lỗi, tiếp tục phân biệt nhập file → kiểm tra ZIP → phân tích class → nạp class → giải mã tài nguyên; không suy ra nguyên nhân từ kích thước JAR. Phép thử tổng hợp chứng minh mức giảm buffer, chưa chứng minh mọi game sẽ giảm RAM cùng tỷ lệ hoặc giải quyết mọi dạng mã hóa.

Nếu bổ sung DEX/ART, cần adapter Java ME, loader, quản lý phiên/tài nguyên và cơ chế Stop phù hợp riêng. Supervisor miniJVM hiện tại chỉ quản lý thread của miniJVM, không tự hủy được thread game trên ART. Nên đánh giá backend này độc lập qua cùng giao diện frontend; không ghép các runtime trong một phiên.
