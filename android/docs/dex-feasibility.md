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

Ở runtime, `IOSClassLoader` nạp từng class khi cần, nhưng có bản sao bytecode qua `ByteArrayOutputStream`/`toByteArray`. Analyzer cũng đọc trọn mỗi class để phân tích header. miniJVM pin hiện tại có `ZipEntry.contents` giữ nội dung đã giải nén; loader giữ các entry trong bảng tra cứu. Đây là những chỗ nên đo lượng byte giữ lại và đỉnh bộ nhớ trước khi quyết định đổi engine. Chưa có phép đo khẳng định chúng gây lỗi với JAR lớn cụ thể của người dùng.

Ưu tiên hiện tại: đo và log riêng nhập file → kiểm tra ZIP → phân tích class → nạp class → giải mã tài nguyên; sau đó giảm sao chép/giữ dữ liệu và nghiên cứu đọc ZIP theo luồng. Cache phân tích đã có trong runtime. Chỉ thay đổi khi có JAR đối chứng và kiểm thử mức sử dụng bộ nhớ.

Nếu bổ sung DEX/ART, cần adapter Java ME, loader, quản lý phiên/tài nguyên và cơ chế Stop phù hợp riêng. Supervisor miniJVM hiện tại chỉ quản lý thread của miniJVM, không tự hủy được thread game trên ART. Nên đánh giá backend này độc lập qua cùng giao diện frontend; không ghép các runtime trong một phiên.
