# MicroEmu cho iPhone

GaEmulator — tác giả ứng dụng: **MrK4tsu**. Bản Android và hướng dẫn build APK nằm tại [android/README.md](../android/README.md).

Runtime dùng chung đã chuyển việc đọc tài nguyên và phân tích header sang ZIP theo luồng, giảm giữ buffer và sao chép bytecode. Phép đo, kiểm thử và giới hạn được ghi tại [archive-memory.md](docs/archive-memory.md).

Bản port iOS mới sử dụng API MIDP/CLDC của MicroEmulator, JVM thông dịch miniJVM và bộ vẽ C. App nhập JAR từ Files, chạy game trong máy, có cảm ứng, phím ảo, hộp nhập văn bản và RMS lưu riêng cho từng game. Không cần JIT hoặc jailbreak theo thiết kế này.

Đây là bản triển khai đầu tiên. **Chưa có kết quả build Xcode hoặc kiểm thử trên iPhone thật.** Bộ thông dịch, lớp Java ME và bộ vẽ đã được build/chạy thử trên Windows. GitHub Actions sẽ kiểm tra phần dùng chung trước khi build iOS.

## Build IPA bằng GitHub Actions

1. Đẩy các thay đổi này vào fork GitHub của bạn.
2. Mở **Actions → Build iPhone IPA → Run workflow**.
3. Khi workflow thành công, tải artifact **MicroEmu-unsigned-IPA**.
4. Giải nén artifact để lấy `MicroEmu-unsigned.ipa`, ký/cài bằng Sideloadly.
5. Mở MicroEmu trên iPhone, chọn biểu tượng **nhập JAR** (mũi tên xuống), chọn game rồi chạm tên game để chạy.

Workflow dùng runner `macos-15`, JDK 17 và Xcode. CI không cần certificate, provisioning profile hoặc Apple ID. App được build bằng SDK `iphoneos`, và bước đóng gói kiểm tra Mach-O ARM64 dành cho thiết bị để tránh đóng nhầm bản Simulator.

Đích triển khai: iOS 12 trở lên, iPhone/iPad. Lần đầu mở mỗi JAR, chọn preset, nhập kích thước (128–1920 pixel mỗi chiều), hoặc **Full screen**; các lần sau dùng thiết lập đã lưu và mở trực tiếp. Nhấn **ⓘ** cạnh JAR để sửa kích thước cho lần mở tiếp theo. Danh sách ưu tiên hiển thị tác giả từ manifest khi có, với thông tin vendor làm dự phòng. Full screen phủ vùng hiển thị; nếu lỗi ảnh trước khung hình đầu tiên, app thử một lần ở vùng vẽ nhỏ hơn rồi phóng lên. Chế độ kích thước cố định giữ tỷ lệ màn hình game. Có thể dùng Files → On My iPhone → MicroEmu để quản lý thư mục `Games`. **☰ → Chia sẻ log** xuất log của lần chạy hiện tại. Với game tự vẽ ô nhập trong Canvas, chạm ô nhập rồi dùng biểu tượng **bàn phím** để gửi chữ vào game; hộp nhập này che nội dung khi gõ.

Biểu tượng **hai ô chồng nhau** kèm số lượng tab mở màn hình tổng quan: hai cột thẻ trên iPhone và thêm cột khi có đủ chiều rộng. Mỗi thẻ có tên JAR, khung hình gần nhất và trạng thái; viền xanh đánh dấu tab đang chọn. Chạm thẻ hoặc biểu tượng mở rộng để quay lại game. **+** mở thêm tab, **×** dừng game và đóng tab đó. Nút **×** trên thanh công cụ đóng tab hiện tại. Runtime thu hồi phiên trước khi bỏ thẻ và cho phép dùng lại khe RMS; không có thao tác dừng để giữ lại thẻ. Biểu tượng tay cầm ẩn/hiện bộ phím; các icon có nhãn VoiceOver và có hình vẽ dự phòng cho iOS 12.

Tổng quan dùng chung `UIImage` đã có của từng tab, không chụp thêm bản sao framebuffer. Tab nền vẫn giữ cơ chế sleep hiện tại. Hộp nhập của game được giữ trong tab, không bật lên đè lưới; khi quay lại đúng tab thì được khôi phục. Cần kiểm tra bố cục và tương tác bằng bản IPA trên iPhone/iPad; máy Windows không chạy được UIKit.

**☰ → Quản lý bộ nhớ** có Dọn ngay, ngưỡng RAM app và chu kỳ tùy chọn, cùng số đo trước/sau. Mặc định phản ứng khi iOS cảnh báo thiếu bộ nhớ; ngưỡng và chu kỳ đều tắt vì miniJVM đã có GC tự động. Khi dọn, ảnh xem trước tab nền được thu nhỏ và yêu cầu GC chạy bất đồng bộ. Dữ liệu game đang dùng vẫn giữ nguyên; không bảo đảm RAM giảm hoặc tránh được mọi trường hợp thiếu bộ nhớ. Chi tiết và bằng chứng kiểm thử: [memory-management.md](docs/memory-management.md).

**☰ → Bật chạy nền (thử nghiệm)** thử giữ game chạy khi chuyển app hoặc khóa màn hình bằng âm thanh nền không nghe thấy. Mặc định tắt; lựa chọn được lưu cho lần mở sau. iOS vẫn có thể ngắt tiến trình; cần thử IPA trên máy thật. Xem [background-running.md](docs/background-running.md).

## Phạm vi hỗ trợ hiện tại

| Thành phần | Trạng thái |
|---|---|
| Nạp class và tài nguyên từ JAR sau khi cài app | Có; classloader đọc trực tiếp archive |
| MIDlet, Canvas, GameCanvas, Image, Graphics, Font | Có; bộ vẽ raster C, CoreText cho chữ trên iOS |
| Cảm ứng, phím bấm, lặp phím, soft key | Có |
| TextBox, Command, Alert | Có; nhập liệu qua giao diện iOS |
| RMS | Có; snapshot có phục hồi và giữ thứ tự ID, tách dữ liệu theo vendor/tên game |
| TCP, HTTP | Sử dụng GCF/networking gốc của miniJVM; đã kiểm thử luồng dữ liệu thật trên loopback |
| HTTPS | Có trong runtime; chưa kiểm thử trong bản port này |
| Form, List, ChoiceGroup, CustomItem, DateField, Gauge, TextField/Item | Chưa có giao diện iOS; trả lỗi rõ khi game yêu cầu |
| Âm thanh MMAPI, JSR-75, Bluetooth, SMS | Chưa tích hợp |
| Chạy game dưới nền/khóa màn hình | Có chế độ thử nghiệm bằng âm thanh nền; chưa xác nhận trên iPhone, không bảo đảm liên tục |

Không phải mọi file `.jar` đều là MIDlet hoặc dùng các API đã hỗ trợ. Đạt kiểm thử nạp game không đồng nghĩa đã chơi online, đăng nhập hoặc vào map thành công.

## Kết quả với GaMod.jar

File thử: GaMod 2.5.0, MIDlet `vn.gamod.client.GameMidlet`, CLDC 1.1 / MIDP 2.0; 214 class, classfile version 45. File JAR của người dùng không được đưa vào repo hoặc IPA.

- Khởi động bằng cùng bộ thông dịch và bộ vẽ của bản port: **đạt**.
- Hiển thị logo và màn hình **Tải dữ liệu**: **đạt**; lần thử 18 giây vẽ 333 khung hình, thoát bình thường.
- Lần thử có thao tác tải dữ liệu: log native xác nhận kết nối TCP tới server game `112.213.94.23:14445` thành công, gửi/nhận dữ liệu hai chiều, gồm các lần đọc buffer 130, 1468, 820 byte và nhiều gói khác. Một lần thử trước đó kết nối thất bại; chưa xác nhận độ ổn định kết nối.
- Hoàn thành tải tài nguyên và hiện menu chính với nền núi, các nút Chơi mới/Đổi tài khoản/Máy chủ/Cấu hình: **đạt**. Dữ liệu RMS sau tải khoảng 788 KB; mở lại game dùng được dữ liệu đã lưu.
- Mở màn hình đăng nhập và nhập tài khoản qua phím ký tự/Keyboard: **đạt**.
- Dùng tài khoản kiểm thử người dùng cung cấp để đăng nhập **Vũ trụ 1**, nhận thông tin map, hiển thị nhân vật/người chơi khác/hiệu ứng và di chuyển làm camera cuộn: **đạt trên host Windows với JVM thông dịch**. Chưa kiểm thử riêng mọi loại quái hoặc toàn bộ chức năng game.
- Client báo `TASK_GET ... IndexOutOfBoundsException: EOF at 402, need 1` khi đọc dữ liệu nhiệm vụ. Lỗi không ngăn lần thử vào map; chưa kết luận nguyên nhân từ JAR, runtime hay phiên bản giao thức server. Chưa sửa file JAR nguồn.
- Xcode build, ký/cài bằng Sideloadly và chạy trên iPhone thật: **chưa kiểm thử**.

Ảnh và log kiểm thử cục bộ nằm trong `ios/build/`, không được commit.

## Kiểm thử phần dùng chung

```sh
python3 ios/tools/prepare_runtime.py
python3 ios/tools/build_java.py
cmake -S ios -B ios/build/host -DCMAKE_BUILD_TYPE=Release
cmake --build ios/build/host --parallel 3
ctest --test-dir ios/build/host --output-on-failure
python3 ios/tools/run_smoke.py --executable ios/build/host/microemu-headless
python3 ios/tools/run_lifecycle_smoke.py --executable ios/build/host/microemu-headless
python3 ios/tools/run_background_smoke.py --executable ios/build/host/microemu-headless
python3 ios/tools/run_session_smoke.py --executable ios/build/host/microemu-headless
python3 ios/tools/run_compatibility_smoke.py --executable ios/build/host/microemu-headless
python3 ios/tools/run_ui_smoke.py --executable ios/build/host/microemu-headless
```

Trên Windows dùng executable trong `ios/build/host/Release/microemu-headless.exe`. Có thể truyền `--runtime PATH` cho hai script đầu để dùng checkout miniJVM có sẵn, nhưng revision phải khớp pin.

Các bài kiểm thử chạy Java trên JVM thông dịch thật, không giả lập lời gọi native: cắt vùng/translation, cả 8 phép transform MIDP, alpha, RMS đóng/mở lại và ID đã xóa, nhiều handle RMS, TCP chứa byte 0/127/128/255 và HTTP từ server thử nghiệm cục bộ. Mỗi lần smoke test khởi động/dừng JVM hai lần trong cùng tiến trình để kiểm tra việc mở lại game. Kiểm thử đóng gói riêng xác nhận loại binary Simulator và giữ quyền thực thi. Test fail sẽ chặn build IPA.

Để phân tích và chạy JAR riêng:

```sh
python3 ios/tools/inspect_midlet.py /path/to/game.jar
ios/build/host/microemu-headless \
  /absolute/path/ios/Runtime/minijvm_rt.jar \
  /absolute/path/ios/Runtime/microemu-ios.jar \
  /absolute/path/game.jar /absolute/path/rms 20 /absolute/path/frame.png
```

Tham số tùy chọn tiếp theo là file sự kiện; mỗi dòng `milliseconds type a b`. Type: 1/2/3 = nhấn/thả/lặp phím, 4/5/6 = chạm/kéo/thả cảm ứng, 8/9 = pause/resume, 10 = dừng. Tham số cuối là đường dẫn font TTF cho bộ vẽ chữ headless. Khi không cung cấp font, glyph bitmap của game vẫn được vẽ, chữ dùng font hệ thống trong bản headless có thể không xuất hiện.

## Build iOS trên Mac hoặc CI

Sau khi build Java và kiểm thử host:

```sh
brew install xcodegen
python3 ios/tools/generate_project.py
xcodebuild -project ios/MicroEmu.xcodeproj -scheme MicroEmu \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath ios/build/xcode CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
python3 ios/tools/package_ipa.py \
  ios/build/xcode/Build/Products/Release-iphoneos/MicroEmu.app \
  ios/build/MicroEmu-unsigned.ipa
```

Không build module `microemu-iphone` cũ. Bản port mới không dùng shell launcher, JamVM hệ thống, JocStrap, SDK WeChat hoặc các SDK thương mại trong ứng dụng mobile mẫu của miniJVM.

## Phụ thuộc và thay đổi tương thích

miniJVM được pin tại `76f904ea4008a8058db5155bf5ee2cfe94d19e60`. `prepare_runtime.py` kiểm tra revision, buộc tắt JIT, loại khả năng tạo subprocess trên iOS, bổ sung cleanup monitor sau `Thread.exit()` và log kết quả TCP connect. SLJIT không được đưa vào binary. Script có kiểm tra cấu trúc trước khi áp dụng và có thể chạy lại.

`build_java.py` giữ bản CLDC networking của miniJVM, tránh đóng gói trùng `javax.microedition.io`; một overlay nguồn thay bốn phép `Calendar.add(DAY_OF_MONTH, …)` trong DateField bằng `set/get` vì bootstrap Calendar chỉ có API CLDC. Các module desktop của MicroEmulator giữ nguyên.

MicroEmulator giữ nguyên thông tin tác giả và giấy phép có trong repo. Bootstrap Java của miniJVM gồm MIT và GPLv2 với Classpath exception; thư viện native có các giấy phép kèm nguồn. Bản build sao chép notice vào `Runtime/ThirdParty` trong app. Các thay đổi mới trong `ios/` được cung cấp theo Apache-2.0.


## Tương thích JAR và mở từ ứng dụng khác

Bản sửa tương thích bổ sung:

- Chuẩn hóa lời gọi `invokevirtual` tới phương thức private của chính class, thường gặp trong JAR đã làm rối mã. Chỉ sửa bytecode trong bộ nhớ; không nới kiểm tra truy cập của JVM hay ghi lại JAR.
- Tìm MIDlet qua chuỗi kế thừa khi JAR thiếu manifest, bỏ qua class abstract/interface.
- Giữ vùng vẽ nội bộ độc lập với game override `getWidth()/getHeight()`.
- Lựa chọn kích thước trước khi chạy được ưu tiên hơn profile cũ. **Full screen** có thể thử lại với ngân sách 153.600 pixel khi lỗi ảnh làm hỏng lần khởi động, rồi phóng lên vùng hiển thị; log ghi cả hai kích thước. Xem [screen-size-selection.md](docs/screen-size-selection.md).
- Mặc định giữ kích thước vùng vẽ được frontend yêu cầu. Lựa chọn `legacy-x1-budget` giới hạn 153.600 pixel chỉ được áp dụng khi cấu hình riêng của game yêu cầu; tên thư mục `x1/` không tự kích hoạt nó. UIKit dùng kích thước framebuffer thực tế để đổi tọa độ chạm.
- Khi một ảnh chuẩn ở `x2/`, `x3/` hoặc `x4/` bị thiếu nhưng có bản ở mật độ khác, có thể đổi tỉ lệ bằng nearest-neighbor, giữ alpha.

Đã kiểm tra khởi động trên host Windows với `HaiTacTiHon_124.jar`, `Dragonboy250 v6.0.jar`, `DragonBoy252.jar`, gồm đường chạy tab dùng trên iOS. Hai bản Dragonboy đã tải tài nguyên từ server, mở hộp nhập tài khoản và mật khẩu, nhận nội dung thử rồi vẽ tiếp; Stop trả `TAB_FINISHED result=0` và host thoát thành công. Chưa thực hiện đăng nhập/chơi đầy đủ hoặc chạy bản sửa trên iPhone.

Sau khi cài cập nhật IPA, có thể chọn JAR trong Files hoặc dùng **Share/Open in → GaEmulator** từ trình duyệt. App sao chép file vào thư viện rồi mở game; nếu đang chơi thì mở tab mới, hoặc chuyển về tab đang chạy cùng file. File đã có cùng nội dung được dùng lại; file trùng tên nhưng khác nội dung được lưu riêng. Luồng này xử lý cả khi app chưa chạy và khi đang mở.

Kiểm tra trên iPhone sau build:

1. Mở một JAR từ Files khi GaEmulator đã đóng.
2. Mở JAR khác khi một game đang chạy; game hiện tại vẫn còn trong tab cũ.
3. Mở lại cùng file, rồi thử một file khác nội dung nhưng trùng tên.
4. Thử JAR trong iCloud Drive và một file rỗng/không đọc được; phải báo lỗi thay vì mở một game rỗng.

Smoke test hiện có fixture cho lời gọi private, tableswitch/lookupswitch, Canvas override kích thước, ảnh đổi mật độ có alpha, MIDlet kế thừa không manifest, cùng các bài RMS/TCP/HTTP. Các trường hợp chạy một tab, nhiều tab và runtime mã hóa đều được kiểm tra.

## Treo khi chọn input hoặc Stop

`TextBox` của MIDP tạo `TextField` nội bộ. Backend iOS cung cấp adapter `TextFieldUI` để khởi tạo được model, giữ kiểm tra độ dài/ràng buộc của MIDP và mở trình nhập UIKit qua `TextBoxUI`. Trước đó `createTextFieldUI` ném `UnsupportedOperationException`, làm chết vòng lặp game khi chọn ô tài khoản/mật khẩu.

Không giữ monitor của thiết bị khi gọi `MIDlet.paint`; cấp phát Java String từ hàng đợi input diễn ra sau khi nhả mutex native. Khi JVM hủy các luồng, vòng đọc socket kiểm tra cả `is_stop` để không chờ vô hạn ở server đang im lặng. Hai luồng stdout/stderr đều ghi nối tiếp vào Log để lỗi Java không bị ghi đè.

`run_lifecycle_smoke.py` chạy trên interpreter thật: khóa giữa paint và luồng nạp ảnh, Stop khi TCP chưa có dữ liệu, nhập chữ trên hai tab trong lúc GC chạy, mở/nhận kết quả hai TextBox rồi vẽ tiếp, và Stop khi TextBox còn mở. Các kiểm thử này chạy trong GitHub Actions trước khi build IPA.

Các thay đổi theo roadmap ngày 2026-11-14 và giới hạn kiểm chứng được ghi tại [implementation-status.md](docs/implementation-status.md). `run_session_smoke.py` thêm các callback bị chặn, vòng CPU/wait, context MIDlet con, input quá tải và 30 lần mở/dừng. `run_compatibility_smoke.py` kiểm tra profile/cache và dừng một tab trong khi tab khác tiếp tục dùng TCP. `run_ui_smoke.py` kiểm tra adapter LCDUI trên bộ vẽ chung.
