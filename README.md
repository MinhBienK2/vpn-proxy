# VPN Proxy (Gluetun + OpenVPN + Auto OTP)

Dự án chạy OpenVPN client trong Docker thông qua `qmcgaw/gluetun` và cung cấp HTTP proxy cục bộ (cổng `1111`), hỗ trợ chuyển đổi file `.ovpn` cũ và tự động sinh mã TOTP để làm mới kết nối trước khi hết phiên.

## Yêu cầu hệ thống

Trước khi cài đặt, hãy đảm bảo máy của bạn đã có sẵn các công cụ sau:

- **Docker** và **Docker Compose** (`docker compose`)
- **Python 3** (dùng để sinh mã TOTP từ `OTP_AUTH_URI`)
- **dig** (`dnsutils` / `bind-utils`, dùng trong `convert-ovpn.sh` để phân giải tên miền `remote` sang IPv4)
- Quyền truy cập `/dev/net/tun` trên máy host (Linux)

## Cấu trúc thư mục

Các file chính trong repository gồm cấu hình Docker, script chuyển đổi `.ovpn` và script khởi chạy kèm theo dõi kết nối:

| File | Mô tả |
| :--- | :--- |
| `docker-compose.yml` | Định nghĩa service `vpn-proxy` chạy `qmcgaw/gluetun` và mở cổng HTTP proxy `1111` |
| `convert-ovpn.sh` | Chuẩn hóa file `.ovpn` gốc sang `custom.ovpn` tương thích với Gluetun / OpenVPN 2.6+ |
| `start-vpn.sh` | Khởi chạy VPN, sinh OTP (tự động hoặc nhập tay) và tự động refresh kết nối |
| `.gitignore` | Loại trừ `.env` và `*.ovpn` để tránh lộ thông tin nhạy cảm lên Git |

## Hướng dẫn cấu hình

Bạn cần chuẩn bị file `.ovpn` đã chuẩn hóa và file `.env` chứa thông tin xác thực trước khi chạy container.

### 1. Chuyển đổi file `.ovpn`

Chạy script `convert-ovpn.sh` với file `.ovpn` gốc để tạo ra `custom.ovpn`:

```bash
chmod +x convert-ovpn.sh start-vpn.sh
./convert-ovpn.sh <duong-dan-file-goc.ovpn>
```

Mặc định script sẽ xuất ra `./custom.ovpn` (hoặc truyền thêm tham số thứ 2 để chỉ định đường dẫn đích) với quyền `600`. Script thực hiện các bước sau:

- Phân giải tên miền ở dòng `remote` sang địa chỉ IPv4 bằng `dig`.
- Chuẩn hóa dòng `auth-user-pass`.
- Chuyển directive `cipher` cũ sang `data-ciphers` và `data-ciphers-fallback` cho OpenVPN 2.6+/2.7+.
- Comment các directive không tương thích với Docker/Gluetun (`block-outside-dns`, `up`, `down`, `script-security`, `route-nopull`, `register-dns`, `persist-key`).

> [!NOTE]
> Nếu file `.ovpn` gốc tham chiếu chứng chỉ bằng file rời (`ca`, `cert`, `key`, `tls-auth`, `tls-crypt`), script sẽ in cảnh báo để bạn copy các file đó vào thư mục dự án và mount thêm vào `docker-compose.yml`.

### 2. Tạo file `.env`

Sao chép từ file mẫu `.env.example` và điền thông tin tài khoản của bạn:

```bash
cp .env.example .env
```

Nội dung mẫu trong `.env.example`:

```dotenv
VPN_SERVICE_PROVIDER=custom
VPN_TYPE=openvpn
OPENVPN_CUSTOM_CONFIG=/gluetun/custom.conf
HTTPPROXY=on

OPENVPN_USER=your_openvpn_username
OPENVPN_BASE_PASSWORD=your_openvpn_password_without_otp
OTP_AUTH_URI=
```

Chi tiết các biến trong `.env`:

| Biến | Bắt buộc | Mô tả |
| :--- | :--- | :--- |
| `VPN_SERVICE_PROVIDER` | Có | Đặt là `custom` để dùng cấu hình OpenVPN tùy chỉnh |
| `VPN_TYPE` | Có | Đặt là `openvpn` |
| `OPENVPN_CUSTOM_CONFIG` | Có | Đường dẫn file cấu hình bên trong container (`/gluetun/custom.conf`) |
| `HTTPPROXY` | Có | Đặt là `on` để bật HTTP proxy của Gluetun |
| `OPENVPN_USER` | Có | Tên đăng nhập OpenVPN |
| `OPENVPN_BASE_PASSWORD` | Có | Mật khẩu gốc (chưa ghép mã OTP) |
| `OTP_AUTH_URI` | Không | URI `otpauth://...` hoặc chuỗi secret Base32 để tự sinh TOTP; nếu bỏ trống, script sẽ hỏi nhập OTP thủ công |

> [!WARNING]
> Không commit `.env` hoặc `*.ovpn` lên Git vì chúng chứa mật khẩu, secret OTP, private key và chứng chỉ VPN.

### 3. Kiểm tra cổng trong `docker-compose.yml`

Mặc định `docker-compose.yml` bind HTTP proxy (cổng `8888` trong container) ra cổng `1111` trên máy host:

- `127.0.0.1:1111:8888/tcp` (truy cập cục bộ trên máy host)
- `192.168.15.248:1111:8888/tcp` (truy cập qua IP LAN)

Nếu IP LAN của máy bạn khác `192.168.15.248`, hãy sửa lại dòng tương ứng trong `docker-compose.yml` hoặc xóa dòng đó nếu chỉ cần dùng qua `127.0.0.1:1111`.

## Hướng dẫn chạy và sử dụng

Sau khi hoàn tất cấu hình, khởi chạy VPN bằng script `start-vpn.sh`:

```bash
./start-vpn.sh
```

Script sẽ ghép `OPENVPN_BASE_PASSWORD` với mã OTP hiện tại và chạy `docker compose up -d --force-recreate`:

- **Nếu có `OTP_AUTH_URI`:** Script chạy vòng lặp theo dõi mỗi 15 giây, chủ động sinh OTP mới và refresh kết nối sau mỗi 55 phút (`3300` giây, trước mốc timeout `3600` giây của OpenVPN), đồng thời tự kết nối lại nếu phát hiện container lỗi hoặc `AUTH_FAILED` (tối đa 3 lần liên tiếp trước khi dừng container để tránh khóa tài khoản).
- **Nếu không có `OTP_AUTH_URI`:** Script yêu cầu nhập OTP thủ công một lần và mở luồng log `docker logs -f vpn-proxy`.

### Sử dụng HTTP proxy

Khi container `vpn-proxy` ở trạng thái `healthy`, bạn có thể trỏ ứng dụng hoặc trình duyệt tới HTTP proxy:

- Localhost: `http://127.0.0.1:1111`
- LAN (nếu giữ cấu hình IP LAN): `http://<ip-lan-cua-may>:1111`

Kiểm tra nhanh qua `curl`:

```bash
curl -x http://127.0.0.1:1111 https://ifconfig.me
```

### Dừng VPN

Nhấn `Ctrl + C` trong terminal chạy `start-vpn.sh` chỉ dừng vòng lặp tự động refresh (container `vpn-proxy` vẫn tiếp tục chạy nền). Để tắt hẳn VPN, chạy:

```bash
docker compose stop
```
