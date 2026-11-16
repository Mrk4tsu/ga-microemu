# Chạy nền thử nghiệm trên iOS

Mở game, chọn **☰ → Bật chạy nền (thử nghiệm)**, rồi chuyển sang app khác hoặc khóa màn hình. Chọn **Tắt chạy nền** để trở về chế độ cũ. Lựa chọn mặc định tắt và được lưu qua các lần mở app. Vuốt tắt hẳn app vẫn chấm dứt mọi game.

Khi có game và đã bật chạy nền, app cung cấp thẻ **Now Playing** của iOS, cùng loại với thẻ phát nhạc Spotify. Thẻ hiển thị tên **“GaEmulator đang chạy nền”**, biểu tượng app và dòng số liệu, ví dụ:

`RAM 120MB | CPU 8% | Tab 3`

RAM/CPU là của toàn bộ GaEmulator; Tab đếm các game chưa kết thúc. CPU giữ cách tính trên màn hình game, có thể vượt 100% khi dùng nhiều lõi. Số liệu được lấy lại mỗi 5 giây khi âm thanh nền đang hoạt động; không đo được thì hiện `--`. Thẻ có sẵn cả khi app đang mở để có thể kéo xuống xem điều khiển hệ thống, không cần rời app trước. Vị trí, bố cục, nút và việc giữ/gỡ thẻ do iOS quyết định.

Nút **tạm dừng** tạm ngừng chạy nền; **phát** thử tiếp tục. Nút **dừng** (nếu giao diện hệ thống cung cấp) tắt chế độ chạy nền. Tạm dừng không xóa game hoặc đóng tab. Khi bị gián đoạn, tiêu đề đổi trạng thái và ngừng đo định kỳ. App gỡ metadata, timer và điều khiển khi tắt chạy nền hoặc game cuối cùng kết thúc. Khi iOS gửi sự kiện kết thúc app, app cũng thực hiện dọn; vuốt tắt hoặc bị hệ thống kết thúc không bảo đảm mã dọn sẽ được gọi, và iOS có thể giữ thông tin phát gần đây.

Không cần quyền thông báo hoặc máy chủ push. Thông báo thường của bản trước được dọn khi mở app. Để dùng thẻ này, phiên âm thanh chuyển sang không trộn với app khác: **bật chạy nền có thể tạm dừng nhạc từ Spotify/YouTube hoặc app khác**. Khi app khác giành quyền phát, thẻ GaEmulator có thể được thay thế và chạy nền có thể bị gián đoạn.

Đây là cách thử giữ tiến trình bằng một đoạn âm thanh im lặng lặp lại, không phải quyền chạy game vô hạn của iOS. Chưa kiểm thử bằng IPA trên iPhone. Chạy nền có thể tốn pin, nóng máy, mất kết nối hoặc bị iOS đình chỉ. Đích build vẫn là iOS 12 trở lên, dùng được API trên iPhone 6; chưa có bằng chứng chạy nền ổn định trên mọi đời iOS.

## Cơ chế

- `BackgroundRunController` bật `AVAudioSessionCategoryPlayback` với `options=0`, khai báo `UIBackgroundModes=audio`, phát WAV PCM im lặng trong bộ nhớ (32.044 byte). Không cần mic hoặc tải file âm thanh. Khởi động âm thanh khi app còn ở phía trước và có game đang chạy; đóng game cuối cùng sẽ dừng âm thanh.
- `BackgroundNowPlayingController` đăng ký Play/Pause/Stop với `MPRemoteCommandCenter` trước khi phát và cung cấp metadata qua `MPNowPlayingInfoCenter`. Nội dung không có thời lượng cố định, không cung cấp tua hoặc chuyển bài. Không dùng thuộc tính `playbackState` dành cho macOS để điều khiển trạng thái iOS; dùng tốc độ phát trong metadata.
- Khi app bị ẩn, dừng cập nhật UIKit và sao chép framebuffer. Đo số liệu trên giao diện mỗi giây được thay bằng timer riêng 5 giây cho thẻ. Các tab chuyển sang sleep (bộ vẽ tối đa 4 FPS); vẫn thực hiện paint vì một số game đặt logic trong đó. Vòng lặp riêng của JAR vẫn do game điều khiển.
- Khi bộ phát đang hoạt động, chuyển app/khóa màn hình không gửi `pauseApp`; quay lại không gọi thêm `startApp`. Nếu âm thanh bị gián đoạn, game nhận pause một lần; khi khôi phục nhận resume một lần. Trạng thái sleep từng tab được phục hồi khi quay lại. Âm thanh đã bật nhưng lỗi có thể thử lại qua menu.
- Cuộc gọi, đổi đường âm thanh và mất/reset dịch vụ âm thanh được theo dõi. Quay lại app sẽ thử khởi động lại âm thanh. Nếu cả tiến trình đã bị đình chỉ, mã xử lý cũng chỉ tiếp tục khi iOS cho phép chạy.
- JAR đang mở và thư mục gốc RMS dùng bảo vệ file `CompleteUntilFirstUserAuthentication`: dữ liệu vẫn mã hóa, có thể đọc sau lần mở khóa đầu tiên dù màn hình khóa lại. Không đặt `NSFileProtectionNone` hoặc sửa đệ quy dữ liệu khác.

Apple mô tả âm thanh nền/khóa màn hình cho ứng dụng phát âm thanh ở [Playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback), xử lý [gián đoạn âm thanh](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html) và [bảo vệ file sau lần mở khóa đầu](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication). Các tài liệu này không bảo đảm vòng âm thanh im lặng giữ một emulator chạy liên tục hay được chấp nhận khi phát hành App Store. Chế độ này cần đánh giá thực tế trên bản IPA cài thử.

Apple mô tả [Now Playing trên màn hình khóa và Control Center](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) và [các điều kiện chọn ứng dụng phát, gồm remote command và phiên âm thanh không trộn](https://developer.apple.com/videos/play/wwdc2022/110338/). Các API dùng ở đây có trên iOS 12; không cần widget extension hoặc Live Activities. Cách gắn chỉ số emulator vào metadata của vòng âm thanh im lặng là giải pháp thử nghiệm của bản port, không phải lời bảo đảm của Apple.

## Kiểm chứng

`background-policy-test` kiểm tra chuyển trạng thái, khôi phục sleep, trạng thái thẻ, chuỗi RAM/CPU/Tab, số đo lỗi, CPU nhiều lõi, giới hạn buffer và dữ liệu WAV. Kiểm thử project xác nhận có nguồn Now Playing và framework MediaPlayer, vẫn giữ đích iOS 12. `run_background_smoke.py` chạy MIDlet trên miniJVM thật, dùng cùng chính sách với frontend: xác nhận paint và TCP tiếp tục khi sleep, số lần pause/start đúng khi gián đoạn/quay lại, rồi Stop thu hồi surface/socket/ZIP/hàng đợi. Các kiểm thử chạy trước bước build IPA trong CI.

Host Windows không build/kiểm tra được AVAudioSession, MediaPlayer, UIKit hoặc màn hình khóa iOS. Việc bản cũ không có MediaPlayer và chỉ gửi thông báo sau `DidEnterBackground` giải thích khoảng trống triển khai so với thẻ Spotify; chưa có log để kết luận riêng tại sao thông báo thường không xuất hiện trên máy người dùng. Chưa xác nhận thẻ mới trên iPhone. Log `[NOW_PLAYING]` ghi trạng thái và số liệu đã gửi; `[BACKGROUND] audio_active=1` chỉ cho biết bộ phát đang hoạt động. Dòng `host heartbeat` mỗi 30 giây chỉ chứng minh vòng host chạy. Thẻ hoặc log này không chứng minh game/kết nối còn tiến triển; phải đối chiếu nhân vật/kết nối phía server.

Trên iPhone 6/iOS 12 và một máy iOS mới, cần thử:

1. Bật chế độ, chuyển app rồi khóa màn hình lần lượt 5, 15 và 30 phút; đối chiếu tiến trình game/kết nối phía server và log.
2. Quay lại vài lần: không thêm luồng game, tốc độ và tab hiện tại phục hồi; tab khác vẫn sleep.
3. Nhận cuộc gọi, phát nhạc app khác, đổi tai nghe và thử khôi phục. Tắt tùy chọn để so sánh với pause/resume mặc định.
4. Khóa máy khi game còn tải tài nguyên hoặc ghi RMS; mở lại kiểm tra dữ liệu. Đóng mọi tab để kiểm tra âm thanh nền dừng; mở app lại kiểm tra lựa chọn đã lưu.
5. Không cấp quyền thông báo: thẻ vẫn phải được cung cấp khi bật chạy nền. Kéo xuống Control Center/khóa máy; kiểm tra tên, biểu tượng, RAM/CPU/Tab thay đổi sau khoảng 5 giây và số tab khi mở/đóng game. Thử Pause/Play trên thẻ, khóa rồi mở máy, đóng game cuối cùng và vuốt tắt app. Phát Spotify để kiểm tra việc chuyển quyền phát và trạng thái bị gián đoạn. Khi thiếu thẻ, đối chiếu `[NOW_PLAYING]` với `[BACKGROUND]` và giữ log của cùng phiên.
