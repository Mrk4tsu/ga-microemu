# Chọn màn hình trước khi chạy JAR

Lần đầu mở mỗi JAR, kể cả từ Files hoặc thêm tab, app yêu cầu chọn màn hình trước khi chạy mã game. Sau khi nhấn **Start**, app nhớ lựa chọn theo tên file; những lần mở sau chạy trực tiếp. Thiết lập đã lưu từ bản trước cũng được dùng lại. Cancel không lưu thiết lập mới. Khi chưa có thiết lập hợp lệ, mặc định là 240×320. Có preset, nhập chiều rộng/cao và **Full screen**. Mở lại file đang chạy chỉ chuyển về tab đó.

Để đổi kích thước, nhấn **ⓘ** cạnh JAR trong thư viện hoặc danh sách chọn tab mới, chỉnh rồi nhấn **Save**. Thay đổi áp dụng từ lần mở tiếp theo, không khởi động lại tab đang chạy. Xóa JAR trong thư viện cũng xóa lựa chọn màn hình của file đó. Cấu hình ngoài giới hạn hoặc sai định dạng sẽ yêu cầu chọn lại.

Dòng mô tả trong cả hai danh sách ưu tiên tác giả: `MIDlet-Author`, rồi `Author`, rồi `MIDlet-Vendor`; bỏ qua giá trị trống và không phân biệt hoa/thường của tên trường. Nếu thiếu tất cả các trường này, giữ dòng mô tả cũ (tên suite/Java ME hoặc Open in new tab). Tên file vẫn hiển thị ở dòng chính. Metadata được đọc từ manifest hoặc JAD theo cơ chế hiện có.

Giới hạn là **128–1920 pixel cho mỗi chiều**, được kiểm tra ở cả giao diện và runtime. Lựa chọn thủ công được dùng đúng kích thước, ưu tiên hơn profile cũ; không tự giảm dựa trên thư mục `x1/`. Chế độ thủ công giữ tỷ lệ khi hiển thị.

## Full screen

Full screen lấy kích thước vùng hiển thị game lúc khởi chạy, trong giới hạn trên, rồi kéo hình đầy vùng hiển thị. Lựa chọn Full screen đã lưu tự tính lại theo vùng hiển thị mỗi lần mở, thay vì giữ kích thước của lần đầu. Trong trình sửa ở thư viện, lựa chọn này ghi **Full screen · Auto**. Khi xoay thiết bị hoặc ẩn bàn phím điều khiển, ảnh tiếp tục phủ vùng mới; kích thước logic của game không đổi giữa phiên. Tọa độ chạm đổi riêng theo hai chiều và theo framebuffer thực tế.

Ảnh chuẩn bị thiếu ở `x2/`, `x3/`, `x4/` vẫn dùng adapter đổi mật độ hiện có. Với tài nguyên mã hóa riêng, chỉ game biết cách giải mã; không đưa byte chưa giải mã vào bộ scale. Nếu có lỗi ảnh dẫn đến lỗi khởi động hoặc lỗi paint trước khung hình đầu tiên, Full screen:

1. Hủy và chờ toàn bộ thread phiên cũ dừng, thu hồi surface/socket rồi đóng loader.
2. Tạo phiên và loader mới, giữ nguyên RMS, thử một lần với ngân sách 153.600 pixel và tỷ lệ ban đầu; mỗi chiều vẫn tối thiểu 128.
3. Phóng framebuffer đó lên toàn vùng hiển thị. Ví dụ 428×541 thử lại ở 348×440.

Stop của người dùng hủy cả việc thử lại. Không thử lặp vô hạn; nếu ảnh vẫn thiếu/hỏng hoặc game vẫn lỗi thì báo thất bại. Không tự khởi động lại sau khi đã có khung hình thành công, tránh làm mất trạng thái chơi. Lỗi paint sau khung hình đầu tiên tiếp tục được ghi log và bỏ khung hình lỗi.

## Log

- `[LAUNCH]`: tên JAR, kích thước yêu cầu và nguồn lựa chọn.
- `[PROFILE]`: fingerprint, nguồn cấu hình và kích thước runtime.
- `[IMAGE_ERROR]`: tab, viewport, đường dẫn game yêu cầu và tài nguyên thực tế khi lỗi giải mã/cấp phát. Giới hạn riêng 64 thông báo mỗi phiên, không dùng chung hạn mức 32 thông báo đổi mật độ. Luôn giữ lỗi ảnh gần nhất để báo lỗi khởi động.
- `[LAUNCH_FAILED]`: loại lỗi, viewport và lỗi ảnh gần nhất nếu có; stack trace vẫn được ghi.
- `[FULLSCREEN]`: kích thước ban đầu, kích thước render thử lại và đích phóng ảnh.

Không ghi nội dung người dùng nhập vào các thông báo này. Nếu chọn kích thước cố định không phù hợp, người dùng thấy lỗi và có thể mở lại với kích thước nhỏ hơn hoặc Full screen.

## Kiểm chứng và giới hạn

DragonBoy252 SHA-256 `09561fc9114b98f8aebede8d62e825d7646a4875ed5eeceea24e93abf3ab17b3` chỉ có một số ảnh `x1` mã hóa, nhưng chọn `x2` ở 428×541. Trên host Windows: kích thước cố định 428×541 tái hiện NullPointerException; 240×320 có frame; Full screen 428×541 thu hồi phiên lỗi, chạy lại 348×440 có frame và Stop trả kết quả 0. Đây là kiểm tra khởi động, chưa xác minh đăng nhập/chơi online.

Fixture trong `run_compatibility_smoke.py` kiểm tra ảnh mã hóa thiếu mật độ khi tải trong `startApp` và trong lần paint đầu tiên, lỗi paint sau frame tốt, giới hạn một lần thử lại, Stop ngay tại ranh giới thử lại, ưu tiên lựa chọn người dùng, giới hạn kích thước và thu hồi cả hai phiên. `viewport_test.c` kiểm tra biên và giá trị tràn. Các bộ smoke khác kiểm tra lifecycle, Stop, nhiều tab và LCDUI.

Môi trường Windows chưa build UIKit/IPA hoặc kiểm tra trên iPhone. Cần thử trên thiết bị: lần đầu chọn/lần sau mở trực tiếp (kể cả sau khi thoát app), sửa bằng ⓘ rồi Save/Cancel, Full screen tính lại sau khi đổi hướng, tác giả có/không có và thứ tự ưu tiên trường, preset/custom, mở nhiều file liên tiếp từ Files, khôi phục hộp nhập của tab cũ, chạm sau phóng ảnh và Stop trong lúc thử lại.
