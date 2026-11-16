# Chạy nền thử nghiệm trên iOS

Mở game, chọn **☰ → Bật chạy nền (thử nghiệm)**, rồi chuyển sang app khác hoặc khóa màn hình. Chọn **Tắt chạy nền** để trở về chế độ cũ. Lựa chọn mặc định tắt và được lưu qua các lần mở app. Vuốt tắt hẳn app vẫn chấm dứt mọi game.

Đây là cách thử giữ tiến trình bằng một đoạn âm thanh im lặng lặp lại, không phải quyền chạy game vô hạn của iOS. Chưa kiểm thử bằng IPA trên iPhone. Chạy nền có thể tốn pin, nóng máy, mất kết nối hoặc bị iOS đình chỉ. Đích build vẫn là iOS 12 trở lên, dùng được API trên iPhone 6; chưa có bằng chứng chạy nền ổn định trên mọi đời iOS.

## Cơ chế

- `BackgroundRunController` bật `AVAudioSessionCategoryPlayback` với `MixWithOthers`, khai báo `UIBackgroundModes=audio`, phát WAV PCM im lặng trong bộ nhớ (32.044 byte). Không cần mic hoặc tải file âm thanh. Khởi động âm thanh khi app còn ở phía trước và có game đang chạy; đóng game cuối cùng sẽ dừng âm thanh.
- Khi app bị ẩn, dừng cập nhật UIKit, lấy số đo CPU/RAM và sao chép framebuffer. Các tab chuyển sang sleep (bộ vẽ tối đa 4 FPS); vẫn thực hiện paint vì một số game đặt logic trong đó. Vòng lặp riêng của JAR vẫn do game điều khiển.
- Khi bộ phát đang hoạt động, chuyển app/khóa màn hình không gửi `pauseApp`; quay lại không gọi thêm `startApp`. Nếu âm thanh bị gián đoạn, game nhận pause một lần; khi khôi phục nhận resume một lần. Trạng thái sleep từng tab được phục hồi khi quay lại. Âm thanh đã bật nhưng lỗi có thể thử lại qua menu.
- Cuộc gọi, đổi đường âm thanh và mất/reset dịch vụ âm thanh được theo dõi. Quay lại app sẽ thử khởi động lại âm thanh. Nếu cả tiến trình đã bị đình chỉ, mã xử lý cũng chỉ tiếp tục khi iOS cho phép chạy.
- JAR đang mở và thư mục gốc RMS dùng bảo vệ file `CompleteUntilFirstUserAuthentication`: dữ liệu vẫn mã hóa, có thể đọc sau lần mở khóa đầu tiên dù màn hình khóa lại. Không đặt `NSFileProtectionNone` hoặc sửa đệ quy dữ liệu khác.

Apple mô tả âm thanh nền/khóa màn hình cho ứng dụng phát âm thanh ở [Playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback), xử lý [gián đoạn âm thanh](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html) và [bảo vệ file sau lần mở khóa đầu](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication). Các tài liệu này không bảo đảm vòng âm thanh im lặng giữ một emulator chạy liên tục hay được chấp nhận khi phát hành App Store. Chế độ này cần đánh giá thực tế trên bản IPA cài thử.

## Kiểm chứng

`background-policy-test` kiểm tra chuyển trạng thái, khôi phục sleep và dữ liệu WAV. `run_background_smoke.py` chạy MIDlet trên miniJVM thật, dùng cùng chính sách với frontend: xác nhận paint và TCP tiếp tục khi sleep, số lần pause/start đúng khi gián đoạn/quay lại, rồi Stop thu hồi surface/socket/ZIP/hàng đợi. Các kiểm thử chạy trước bước build IPA trong CI.

Host Windows không kiểm tra được AVAudioSession, UIKit, quyền chạy nền thực tế, khóa màn hình hoặc quyền đọc file trên iPhone. Log `[BACKGROUND] audio_active=1` chỉ cho biết bộ phát đang hoạt động. Dòng `host heartbeat` mỗi 30 giây chỉ chứng minh vòng host chạy; phải kiểm tra nhân vật/kết nối phía server để xác nhận game đang hoạt động.

Trên iPhone 6/iOS 12 và một máy iOS mới, cần thử:

1. Bật chế độ, chuyển app rồi khóa màn hình lần lượt 5, 15 và 30 phút; đối chiếu tiến trình game/kết nối phía server và log.
2. Quay lại vài lần: không thêm luồng game, tốc độ và tab hiện tại phục hồi; tab khác vẫn sleep.
3. Nhận cuộc gọi, phát nhạc app khác, đổi tai nghe và thử khôi phục. Tắt tùy chọn để so sánh với pause/resume mặc định.
4. Khóa máy khi game còn tải tài nguyên hoặc ghi RMS; mở lại kiểm tra dữ liệu. Đóng mọi tab để kiểm tra âm thanh nền dừng; mở app lại kiểm tra lựa chọn đã lưu.
