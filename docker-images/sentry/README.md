# Hướng Dẫn Toàn Diện Triển Khai Sentry Self-Hosted Trên VM

Hệ thống giám sát lỗi ứng dụng và hiệu năng mã nguồn mở (**Sentry Self-Hosted**) được chuẩn hóa để triển khai trên môi trường máy chủ ảo (VM / Dedicated Server) sử dụng Docker Engine & Docker Compose.

---

## 1. Sentry Là Gì?

**Sentry** là nền tảng **Error Tracking** (Theo dõi ngoại lệ & lỗi) và **Application Performance Monitoring (APM)** mã nguồn mở hàng đầu thế giới dành cho các đội ngũ phát triển phần mềm và DevOps. 

Thay vì phải đào bới các file log thủ công (`/var/log/...`, Kibana, Loki) sau khi sự cố đã xảy ra hàng giờ, Sentry tự động thu thập lỗi ngay khi chúng phát sinh trong mã nguồn của client hoặc backend, phân tích nguyên nhân gốc rễ và cảnh báo tức thời cho kỹ sư.

```mermaid
flowchart LR
    subgraph Clients [Ứng dụng & Nền tảng]
        FE["Frontend (React / Vue / Next.js)"]
        BE["Backend (Node.js / Python / Go / Java)"]
        MB["Mobile (Flutter / React Native / iOS / Android)"]
    end

    subgraph SentryStack [Sentry Self-Hosted Stack]
        RELAY["Sentry Relay\n(Ingestion & Throttling)"]
        KAFKA["Apache Kafka\n(Message Streaming)"]
        SNUBA["Snuba Service\n(Search & Query Engine)"]
        CH[("ClickHouse OLAP\n(Events & Tracing)")]
        PG[("PostgreSQL\n(Metadata & Configs)")]
        RD[("Redis\n(Queue & Caching)")]
        WORKERS["Celery Workers\n(Background Processing)"]
        SYM["Symbolicator\n(Stacktrace Demangling)"]
        WEB["Sentry Web UI\n(Dashboard & API)"]
    end

    FE -->|DSN HTTP Post| RELAY
    BE -->|DSN HTTP Post| RELAY
    MB -->|DSN HTTP Post| RELAY

    RELAY --> KAFKA
    KAFKA --> SNUBA
    SNUBA --> CH
    KAFKA --> WORKERS
    WORKERS --> PG
    WORKERS --> RD
    WORKERS --> SYM
    WEB --> PG
    WEB --> SNUBA
```

### Các Tính Năng Cốt Lõi Của Sentry:

1. **Error Tracking & Crash Reporting:**
   - Bắt trọn vẹn Call Stack (Stack Trace) chi tiết tới từng hàm, file, số dòng code bị crash.
   - Hiển thị giá trị các biến cục bộ (Local Variables), header HTTP, thông tin OS/Browser của người dùng lúc xảy ra lỗi.
   - Tự động gom nhóm các lần xảy ra lỗi cùng loại thành các **Issues** để tránh bị "bão thông báo" (Alert Fatigue).

2. **Breadcrumbs (Dấu vết hành động):**
   - Ghi lại chuỗi hành động của người dùng và hệ thống diễn ra *ngay trước khi lỗi xảy ra* (ví dụ: User click nút A -> Gửi request GET `/api/user` -> Bấm submit form -> Bị Exception 500).

3. **Performance Monitoring & Distributed Tracing:**
   - Đo lường độ trễ (Latency), P50/P75/P95/P99 của các API endpoint.
   - Bóc tách chi tiết từng Transaction và Span: Database queries (SQL chậm), HTTP external calls, tác vụ render giao diện.
   - Đo lường chỉ số Web Vitals của Frontend (LCP, FID/INP, CLS, FCP).

4. **Profiling (Flamegraphs):**
   - Phân tích hiệu năng CPU & Memory theo thời gian thực (hỗ trợ Python, Node.js, Android, iOS), chỉ ra chính xác đoạn code nào đang ngốn tài nguyên nhất.

5. **Session Replay:**
   - Tái hiện lại bằng video mô phỏng thao tác cuộn chuột, nhấp phím của người dùng dẫn đến lỗi crash giao diện.

6. **Release Management & Source Maps:**
   - Tích hợp CI/CD để upload JavaScript Source Maps hoặc dSYM (iOS), ProGuard (Android), cho phép xem code nguyên bản thay vì code đã bị minify/obfuscate.
   - Đo lường chỉ số sức khỏe phiên bản: **Crash-Free Users %** và **Crash-Free Sessions %**.

---

## 2. Các Thuật Ngữ Quan Trọng Cần Biết

- **DSN (Data Source Name):** Là chuỗi định danh bí mật cấp cho từng Project (ví dụ: `https://abcd1234efgh@sentry.yourdomain.com/1`). Client SDK dùng DSN này để biết gửi telemetry data về đâu.
- **Event:** Là một lần duy nhất lỗi hoặc transaction được kích hoạt và gửi về Sentry.
- **Issue:** Là tập hợp nhóm các Events có cùng chữ ký lỗi (fingerprint). Khi 1 bug xuất hiện 10.000 lần, Sentry chỉ tạo 1 Issue chứa 10.000 Events liên quan.
- **Environment:** Môi trường phát sinh lỗi (`production`, `staging`, `development`).
- **Tag & Context:** Dữ liệu ngữ cảnh gắn kèm theo Event (User ID, Tenant ID, Request IP, Server Hostname,...).

---

## 3. Yêu Cầu Tài Nguyên Phần Cứng Trên VM

> [!CAUTION]
> **ĐẶC BIỆT LƯU Ý VỀ TÀI NGUYÊN:**
> Sentry Self-Hosted là một hệ thống phân tán microservices cực kỳ mạnh mẽ gồm gần **30 Docker containers** (Apache Kafka, ClickHouse, PostgreSQL, Redis, Snuba, Symbolicator, Relay, Memcached, Celery Workers, Web, Vroom,...).
> **Không thể triển khai Sentry trên các VM cấu hình thấp (1-2 CPU, 2-4GB RAM).** Container sẽ lập tức bị Linux OOM Killer tiêu diệt hoặc Kafka/ClickHouse sẽ crash liên tục.

| Thành phần | Cấu hình Tối thiểu (Minimum) | Cấu hình Khuyến nghị (Production) |
| :--- | :--- | :--- |
| **CPU** | 4 Cores | 8 Cores trở lên |
| **RAM** | 16 GB | 32 GB |
| **Swap** | 16 GB Swap (Bắt buộc nếu RAM 16GB) | 8-16 GB Swap |
| **Ổ đĩa (Disk)** | 20 GB SSD trống | 50 - 100 GB NVMe SSD |
| **Hệ điều hành** | Ubuntu 22.04 / 24.04 LTS hoặc Debian 12 | Ubuntu 24.04 LTS (Hạn chế dùng CentOS/Alpine) |
| **Docker** | Docker Engine >= 24.0 | Phiên bản Docker mới nhất |
| **Docker Compose** | Docker Compose v2 >= 2.23.2 | Docker Compose v2 mới nhất |

---

## 4. Cấu Trúc Thư Mục Triển Khai

```text
docker-images/sentry/
├── README.md                           # Tài liệu hướng dẫn toàn diện này
├── deploy.sh                           # Script tự động kiểm tra hệ thống và cài đặt
├── .env.custom.example                 # Biến môi trường tùy chỉnh (Port, Mail, Retention Days)
├── config.example.yml                  # Mẫu cấu hình config.yml (SMTP, URL prefix, Security)
├── docker-compose.override.yml.example # File override Docker Compose
└── nginx/
    └── sentry.conf                     # Cấu hình Nginx Reverse Proxy (SSL, WebSocket, Timeout)
```

---

## 5. Hướng Dẫn Cài Đặt Chi Tiết

### Cách 1: Sử dụng Script Tự Động (Khuyến nghị)

Script [deploy.sh](file:///home/vbox/projects/devops/docker-images/sentry/deploy.sh) đã được cấu hình sẵn để:
1. Tự động kiểm tra số lượng CPU, dung lượng RAM vật lý và Swap.
2. Hỗ trợ tạo file Swap 8-16 GB nếu RAM của máy còn hạn chế.
3. Kiểm tra tính tương thích của Docker Engine & Docker Compose v2.
4. Clone mã nguồn `getsentry/self-hosted` từ GitHub và khởi động trình cài đặt chính thức.

Chạy lệnh sau tại terminal của VM:

```bash
cd /home/vbox/projects/devops/docker-images/sentry
./deploy.sh
```

---

### Cách 2: Các Bước Triển Khai Thủ Công Theo Chuẩn Sentry

Nếu bạn muốn tự kiểm soát từng bước:

#### Bước 1: Chuẩn bị Swap (Nếu RAM < 32GB)
```bash
# Tạo file swap 16GB nếu chưa có đủ swap
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

#### Bước 2: Clone repository `getsentry/self-hosted`
```bash
cd /home/vbox/projects/devops/docker-images/sentry
git clone https://github.com/getsentry/self-hosted.git
cd self-hosted
```

*(Tùy chọn: Checkout phiên bản tag ổn định cụ thể, ví dụ `git checkout 24.1.0`)*.

#### Bước 3: Cấu hình biến môi trường và thiết lập
Tạo file cấu hình tùy chỉnh để kiểm soát thời gian lưu trữ dữ liệu và cổng truy cập:

```bash
# Giới hạn thời gian lưu dữ liệu 30 ngày (mặc định 90 ngày dễ đầy ổ cứng)
echo "SENTRY_EVENT_RETENTION_DAYS=30" >> .env
echo "SENTRY_BIND=0.0.0.0:9000" >> .env
```

Nếu muốn cấu hình gửi mail SMTP, mở file `sentry/config.yml` và thêm:
```yaml
system.url-prefix: 'https://sentry.yourdomain.com'
mail.backend: 'smtp'
mail.host: 'smtp.gmail.com'
mail.port: 587
mail.username: 'your-account@gmail.com'
mail.password: 'your-app-password'
mail.use-tls: true
mail.from: 'sentry-alerts@yourdomain.com'
```

#### Bước 4: Chạy script khởi tạo (install.sh)
```bash
./install.sh
```

> [!NOTE]
> Quá trình `./install.sh` sẽ thực hiện:
> - Sinh ngẫu nhiên `system.secret-key` bảo mật và các Relay credentials.
> - Kéo toàn bộ Docker images của Sentry, Kafka, ClickHouse, Snuba, Redis, Postgres.
> - Chạy migration cơ sở dữ liệu trên PostgreSQL và ClickHouse.
> - Nhắc bạn tạo tài khoản **Superuser (Admin Account)**: Nhập Email và Mật khẩu quản trị viên.

#### Bước 5: Khởi động hệ thống
```bash
docker compose up -d
```

Sau khoảng 1 - 2 phút để các container hoàn tất khởi động và healthcheck, truy cập giao diện Sentry tại:
`http://<IP_CUA_VM>:9000`

---

## 6. Cấu Hình Nginx Reverse Proxy & SSL (HTTPS)

Để đảm bảo an toàn dữ liệu telemetry gửi từ client và cho phép tích hợp Webhook/SSO, bạn nên trỏ tên miền và kích hoạt HTTPS thông qua Nginx Reverse Proxy.

File cấu hình mẫu đã được chuẩn bị tại: [nginx/sentry.conf](file:///home/vbox/projects/devops/docker-images/sentry/nginx/sentry.conf).

### Các bước cài đặt Nginx & SSL Let's Encrypt trên Ubuntu/Debian:

1. **Cài đặt Nginx và Certbot:**
   ```bash
   sudo apt-get update
   sudo apt-get install -y nginx certbot python3-certbot-nginx
   ```

2. **Cấp chứng chỉ SSL Let's Encrypt:**
   ```bash
   sudo certbot certonly --standalone -d sentry.yourdomain.com
   ```

3. **Sao chép cấu hình Nginx:**
   ```bash
   sudo cp /home/vbox/projects/devops/docker-images/sentry/nginx/sentry.conf /etc/nginx/sites-available/sentry.conf
   sudo sed -i 's/sentry.yourdomain.com/ten-mien-that-cua-ban.com/g' /etc/nginx/sites-available/sentry.conf
   sudo ln -sf /etc/nginx/sites-available/sentry.conf /etc/nginx/sites-enabled/
   sudo nginx -t && sudo systemctl reload nginx
   ```

---

## 7. Vận Hành, Bảo Trì & Dọn Dẹp Dữ Liệu

### Quản lý vòng đời dịch vụ:
```bash
cd /home/vbox/projects/devops/docker-images/sentry/self-hosted

# Xem trạng thái tất cả các container
docker compose ps

# Xem log thời gian thực
docker compose logs -f

# Tắt hệ thống
docker compose down

# Khởi động lại hệ thống
docker compose restart
```

### Tạo thêm tài khoản Quản trị viên (Superuser):
```bash
docker compose run --rm web createuser
```

### Dọn dẹp dữ liệu cũ định kỳ (Tránh tràn ổ đĩa):
Mặc dù Sentry có container `sentry-cleanup` chạy định kỳ, bạn có thể chủ động kích hoạt dọn dẹp các sự kiện cũ hơn 30 ngày:
```bash
docker compose run --rm web cleanup --days 30
```

Bạn có thể thiết lập Cronjob trên VM (`crontab -e`) để tự động dọn dẹp vào mỗi đêm:
```cron
0 3 * * * cd /home/vbox/projects/devops/docker-images/sentry/self-hosted && docker compose run --rm web cleanup --days 30 >> /var/log/sentry-cleanup.log 2>&1
```

---

## 8. Hướng Dẫn Tích Hợp Thử Nghiệm Với Ứng Dụng

Sau khi đăng nhập vào Web UI Sentry, tạo một Project mới (chọn nền tảng mong muốn, ví dụ Python hoặc Node.js) và lấy chuỗi **DSN**.

### Ví dụ 1: Tích hợp trong Python
```bash
pip install sentry-sdk
```

```python
import sentry_sdk

sentry_sdk.init(
    dsn="https://your-public-key@sentry.yourdomain.com/1",
    traces_sample_rate=1.0, # Đo lường 100% transaction performance
    profiles_sample_rate=1.0, # Bật profiling
    environment="production",
)

try:
    division_by_zero = 1 / 0
except Exception as e:
    sentry_sdk.capture_exception(e)
    print("Đã gửi lỗi đến Sentry thành công!")
```

### Ví dụ 2: Tích hợp trong Node.js / Express
```bash
npm install @sentry/node
```

```javascript
const express = require("express");
const Sentry = require("@sentry/node");

const app = express();

Sentry.init({
  dsn: "https://your-public-key@sentry.yourdomain.com/1",
  tracesSampleRate: 1.0,
  environment: "production",
});

// RequestHandler tạo transaction cho mỗi request
app.use(Sentry.Handlers.requestHandler());
app.use(Sentry.Handlers.tracingHandler());

app.get("/debug-sentry", function mainHandler(req, res) {
  throw new Error("Lỗi kiểm tra tích hợp Sentry từ Node.js!");
});

// ErrorHandler phải đặt trước bất kỳ error middleware tùy chỉnh nào
app.use(Sentry.Handlers.errorHandler());

app.listen(3000, () => console.log("Server running on port 3000"));
```
