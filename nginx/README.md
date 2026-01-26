# Nginx Reverse Proxy Configuration

Cấu hình Nginx để proxy request từ domain đến các service chạy trên localhost.

## Mô tả

- `https://exam.oceanedu.com` → `localhost:3001` (Frontend)
- `https://exam-api.oceanedu.com` → `localhost:3000` (Backend API)

## Cài đặt

### 1. Tạo Self-Signed SSL Certificate

Chạy lệnh sau để tạo SSL certificate cho môi trường development:

```bash
# Tạo thư mục ssl nếu chưa có
mkdir -p nginx/ssl

# Tạo self-signed certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout nginx/ssl/key.pem \
  -out nginx/ssl/cert.pem \
  -subj "/C=VN/ST=HCM/L=HoChiMinh/O=OceanEdu/CN=*.oceanedu.com"
```

**Lưu ý:** Self-signed certificate sẽ hiển thị cảnh báo "Not Secure" trên trình duyệt. Đây là bình thường cho môi trường development.

### 2. Cấu hình Hosts File

Thêm các domain vào file hosts để trỏ về localhost:

**Windows:** Mở file `C:\Windows\System32\drivers\etc\hosts` với quyền Administrator và thêm:

```
127.0.0.1 exam.oceanedu.com
127.0.0.1 exam-api.oceanedu.com
```

**Linux/Mac:** Chỉnh sửa file `/etc/hosts`:

```bash
sudo nano /etc/hosts
```

Thêm vào cuối file:

```
127.0.0.1 exam.oceanedu.com
127.0.0.1 exam-api.oceanedu.com
```

### 3. Khởi động các Service

Đảm bảo các service đang chạy trên đúng port:

- **Frontend**: Chạy trên `localhost:3001`
- **Backend API**: Chạy trên `localhost:3000`

### 4. Khởi động Nginx Container

```bash
# Khởi động tất cả services
docker-compose up -d

# Hoặc chỉ khởi động Nginx
docker-compose up -d nginx

# Xem logs
docker-compose logs -f nginx
```

### 5. Kiểm tra

Truy cập các URL sau trên trình duyệt:

- Frontend: `https://exam.oceanedu.com`
- Backend API: `https://exam-api.oceanedu.com`

**Lưu ý:** Trình duyệt sẽ cảnh báo về certificate không tin cậy. Bấm "Advanced" → "Proceed to exam.oceanedu.com" để tiếp tục.

## Cấu trúc thư mục

```
nginx/
├── nginx.conf          # Cấu hình Nginx
├── ssl/                # Thư mục chứa SSL certificates
│   ├── cert.pem       # SSL certificate
│   └── key.pem        # Private key
└── README.md          # File hướng dẫn này
```

## Troubleshooting

### 1. Không kết nối được đến backend/frontend

Kiểm tra các service đang chạy:

```bash
# Kiểm tra port 3000 (Backend)
curl http://localhost:3000

# Kiểm tra port 3001 (Frontend)
curl http://localhost:3001
```

### 2. Nginx container không khởi động

Xem logs để kiểm tra lỗi:

```bash
docker-compose logs nginx
```

### 3. SSL Certificate Error

Đảm bảo file certificate đã được tạo đúng:

```bash
ls -la nginx/ssl/
```

Phải có 2 file: `cert.pem` và `key.pem`

### 4. Không thể chỉnh sửa hosts file trên Windows

- Đóng tất cả ứng dụng đang chạy
- Tắt phần mềm antivirus tạm thời
- Mở Notepad với quyền Administrator
- Mở file: `C:\Windows\System32\drivers\etc\hosts`
- Thêm các domain
- Lưu file

## Production Setup

Để sử dụng trong môi trường production, bạn cần:

1. Sử dụng SSL certificate từ nhà cung cấp tin cậy (Let's Encrypt, Cloudflare, etc.)
2. Cập nhật DNS records trỏ domain về server IP
3. Cấu hình firewall cho phép traffic trên port 80 và 443
4. Sử dụng reverse proxy đúng cách với các service backend

## Các lệnh hữu ích

```bash
# Khởi động lại Nginx
docker-compose restart nginx

# Dừng Nginx
docker-compose stop nginx

# Xem logs real-time
docker-compose logs -f nginx

# Kiểm tra cấu hình Nginx
docker-compose exec nginx nginx -t

# Reload cấu hình Nginx (không cần restart)
docker-compose exec nginx nginx -s reload
```
