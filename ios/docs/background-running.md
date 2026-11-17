# Chạy nền thử nghiệm trên iOS

Mở game, chọn **☰ → Bật chạy nền (thử nghiệm)**, rồi chuyển sang app khác hoặc khóa màn hình. Chọn **Tắt chạy nền** để trở về chế độ cũ. Lựa chọn mặc định tắt và được lưu qua các lần mở app. Vuốt tắt hẳn app vẫn chấm dứt mọi game.

Khi có game và đã bật chạy nền, **iOS 16.1 trở lên** dùng Live Activity riêng trên màn hình khóa và Dynamic Island nếu máy có hỗ trợ. Thẻ gồm tên GaEmulator, trạng thái, ba mục RAM/CPU/Tab và thời điểm đo; không có nút phát nhạc. Ví dụ số liệu:

`RAM 120MB | CPU 8% | Tab 3`

RAM/CPU là của toàn bộ GaEmulator; Tab đếm các game chưa kết thúc. CPU có thể vượt 100% khi dùng nhiều lõi. Số liệu được gửi khoảng 15 giây/lần khi âm thanh nền còn hoạt động; không đo được thì hiện `--`. iOS có thể trì hoãn cập nhật. Trên iOS 16.2+, sau 60 giây không nhận mẫu mới, thẻ chuyển sang **“Chưa có số liệu mới”**. iOS 16.1 chỉ có thời điểm cập nhật để nhận biết dữ liệu cũ.

Chạm thẻ để mở app. Tắt chạy nền hoặc kết thúc game cuối cùng sẽ yêu cầu kết thúc/gỡ Live Activity. Mỗi Live Activity có giới hạn hoạt động 8 giờ. Người dùng xóa thẻ hoặc iOS kết thúc thẻ thì app không tạo lại liên tục; tắt rồi bật lại chạy nền để bắt đầu thẻ mới. Khi vuốt tắt app hoặc iOS kết thúc tiến trình, thẻ có thể còn hiển thị dữ liệu cũ. Live Activity không cấp quyền chạy game vô hạn và không chứng minh game/kết nối vẫn hoạt động.

**iOS 12–16.0**, hoặc Live Activity không khả dụng, dùng thông báo thường sau khi người dùng cho phép. Thông báo chỉ lấy một mẫu lúc chuyển ra nền hoặc khi trạng thái/số tab thay đổi, không đăng lại mỗi 15 giây. Nó có thể bị xóa, không ghim cố định; quay lại app/tắt chế độ/hết game sẽ gỡ thông báo. Nếu đã từ chối quyền, kiểm tra Cài đặt → Thông báo → GaEmulator. Khi người dùng chủ động xóa Live Activity, app không thay bằng thông báo để né lựa chọn đó.

Phần giữ tiến trình dùng phiên âm thanh có `MixWithOthers`, không đăng ký remote command hoặc đăng thông tin Now Playing. Nhạc từ app khác có thể tiếp tục; thông tin phát nhạc của bản cũ được dọn khi mở app.

Đây là cách thử giữ tiến trình bằng một đoạn âm thanh im lặng lặp lại, không phải quyền chạy game vô hạn của iOS. Chưa kiểm thử bằng IPA trên iPhone. Chạy nền có thể tốn pin, nóng máy, mất kết nối hoặc bị iOS đình chỉ. Đích build vẫn là iOS 12 trở lên, dùng được API trên iPhone 6; chưa có bằng chứng chạy nền ổn định trên mọi đời iOS.

## Cơ chế

- `BackgroundRunController` bật `AVAudioSessionCategoryPlayback` với `MixWithOthers`, khai báo `UIBackgroundModes=audio`, phát WAV PCM im lặng trong bộ nhớ (32.044 byte). Không cần mic hoặc tải file âm thanh. Khởi động âm thanh khi app còn ở phía trước và có game đang chạy; đóng game cuối cùng sẽ dừng âm thanh.
- `BackgroundStatusController` phụ trách hiển thị, tách khỏi vòng đời âm thanh. Host vẫn chỉ dùng Objective-C và giữ đích iOS 12. Framework `GaEmulatorLiveBridge` và widget `GaEmulatorStatus.appex` có đích iOS 16.1. Framework được nhúng nhưng không link vào host; chỉ nạp bằng `NSBundle` sau kiểm tra phiên bản. iOS cũ không nạp ActivityKit/Swift concurrency qua framework này.
- Bridge dùng ActivityKit nội bộ và không cần APNs/server/app group. Bắt đầu thẻ khi app đang active; nếu chuyển ra nền quá sớm thì tạm dùng thông báo và thử tạo thẻ khi quay lại. Các lệnh update/end được nối tiếp và cập nhật mong muốn mới nhất; yêu cầu dừng được xử lý trước mẫu tiếp theo. Thẻ tồn dư của tiến trình cũ được dọn khi mở app lại. Lỗi tạo thẻ được thử lại khi foreground; không thử lại liên tục mỗi mẫu.
- Khi app bị ẩn, dừng cập nhật UIKit và sao chép framebuffer. Timer 15 giây chỉ chạy khi đang có Live Activity và âm thanh nền hoạt động. Các tab chuyển sang sleep (bộ vẽ tối đa 4 FPS); vẫn thực hiện paint vì một số game đặt logic trong đó. Vòng lặp riêng của JAR vẫn do game điều khiển.
- Khi bộ phát đang hoạt động, chuyển app/khóa màn hình không gửi `pauseApp`; quay lại không gọi thêm `startApp`. Nếu âm thanh bị gián đoạn, game nhận pause một lần; khi khôi phục nhận resume một lần. Trạng thái sleep từng tab được phục hồi khi quay lại. Âm thanh đã bật nhưng lỗi có thể thử lại qua menu.
- Cuộc gọi, đổi đường âm thanh và mất/reset dịch vụ âm thanh được theo dõi. Quay lại app sẽ thử khởi động lại âm thanh. Nếu cả tiến trình đã bị đình chỉ, mã xử lý cũng chỉ tiếp tục khi iOS cho phép chạy.
- JAR đang mở và thư mục gốc RMS dùng bảo vệ file `CompleteUntilFirstUserAuthentication`: dữ liệu vẫn mã hóa, có thể đọc sau lần mở khóa đầu tiên dù màn hình khóa lại. Không đặt `NSFileProtectionNone` hoặc sửa đệ quy dữ liệu khác.

Apple mô tả âm thanh nền/khóa màn hình cho ứng dụng phát âm thanh ở [Playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback), xử lý [gián đoạn âm thanh](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html) và [bảo vệ file sau lần mở khóa đầu](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication). Các tài liệu này không bảo đảm vòng âm thanh im lặng giữ một emulator chạy liên tục hay được chấp nhận khi phát hành App Store. Chế độ này cần đánh giá thực tế trên bản IPA cài thử.

Tham khảo [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [isStale từ iOS 16.2](https://developer.apple.com/documentation/widgetkit/activityviewcontext/isstale) và [nhúng framework với kiểm tra phiên bản](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html). Khi ký bằng Sideloadly, giữ `GaEmulatorStatus.appex` trong PlugIns và framework đi kèm: [Sideloadly có tùy chọn xóa các app extension](https://sideloadly.io/), bật tùy chọn đó sẽ làm mất phần hiển thị Live Activity.

## Kiểm chứng

`background-policy-test` kiểm tra chuyển trạng thái, khôi phục sleep, chuỗi RAM/CPU/Tab, số đo lỗi, CPU nhiều lõi, giới hạn buffer và dữ liệu WAV. Kiểm thử project xác nhận host iOS 12 không link framework mới, còn widget/framework đúng đích iOS 16.1 và cùng phiên bản app. Kiểm thử đóng gói xác nhận giữ executable bit của app/appex/framework/Swift dylib, từ chối component Simulator hoặc thiếu thành phần, và phát hiện host vô tình link trực tiếp ActivityKit/bridge/concurrency. `run_background_smoke.py` kiểm tra paint/TCP và Stop trên miniJVM thật. Các kiểm thử chạy trước bước build IPA trong CI.

Host Windows không có Xcode/SDK iOS, nên chưa biên dịch/typecheck phần Swift với ActivityKit/SwiftUI, kiểm tra giao diện, load framework trên iOS 12, hoặc xác nhận ký/cài extension bằng Sideloadly. Kiểm thử cấu hình/fixture không thay thế các bước này. Log `[LIVE_ACTIVITY]` ghi lỗi tạo/nạp thẻ; `[BACKGROUND_NOTIFICATION]` ghi lỗi thông báo dự phòng. `[BACKGROUND] audio_active=1` và `host heartbeat` không chứng minh game/kết nối còn tiến triển; phải đối chiếu nhân vật/kết nối phía server.

Trên iPhone 6/iOS 12 và một máy iOS mới, cần thử:

1. Bật chế độ, chuyển app rồi khóa màn hình lần lượt 5, 15 và 30 phút; đối chiếu tiến trình game/kết nối phía server và log.
2. Quay lại vài lần: không thêm luồng game, tốc độ và tab hiện tại phục hồi; tab khác vẫn sleep.
3. Nhận cuộc gọi, phát nhạc app khác, đổi tai nghe và thử khôi phục. Tắt tùy chọn để so sánh với pause/resume mặc định.
4. Khóa máy khi game còn tải tài nguyên hoặc ghi RMS; mở lại kiểm tra dữ liệu. Đóng mọi tab để kiểm tra âm thanh nền dừng; mở app lại kiểm tra lựa chọn đã lưu.
5. Trên iOS 16.1/16.2+: giữ extension khi ký IPA; thử khóa máy, số đo/thời điểm cập nhật, Dynamic Island, đóng tab, bật/tắt nhanh và xóa thẻ thủ công. Để app ngừng cập nhật để kiểm tra dấu số liệu cũ trên 16.2+. Thử khởi động lại sau force quit và khi hết giới hạn thẻ. Phát Spotify để xác nhận thẻ của game không chiếm giao diện phát nhạc. Trên iOS 12, kiểm tra app vẫn mở/chạy game, quyền thông báo, lấy mẫu khi ra nền và không gửi lặp liên tục.
