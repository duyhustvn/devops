# PostgreSQL Docker Setup

Cấu hình triển khai PostgreSQL 18 và Prometheus PostgreSQL Exporter sử dụng Docker Compose.

## 1. Cấu trúc thư mục

```text
postgresql/
├── docker-compose.yml      # File cấu hình Docker Compose (PostgreSQL + postgres_exporter)
├── postgres_secret         # File chứa mật khẩu root (POSTGRES_PASSWORD)
└── README.md
```

## 2. Thông tin dịch vụ

| Service | Image | Cổng (Host:Container) | Mô tả |
| :--- | :--- | :--- | :--- |
| **postgresql** | `postgres:18` | `5432:5432` | PostgreSQL Database Server |
| **postgres_exporter** | `prometheuscommunity/postgres-exporter:v0.16.0` | `9187:9187` | Prometheus Exporter cho PostgreSQL |

## 3. Cấu hình bảo mật (Secrets)

- Mật khẩu của tài khoản `postgres` được đọc an toàn qua Docker Secrets từ file `postgres_secret` (thay vì đặt plain-text trong biến môi trường).
- Mặc định file `postgres_secret` chứa chuỗi `changeme`. Hãy thay đổi mật khẩu này trước khi sử dụng trong môi trường thực tế.

## 4. Hướng dẫn sử dụng

### Khởi chạy dịch vụ

```bash
cd docker-images/postgresql
docker compose up -d
```

### Kiểm tra trạng thái dịch vụ

```bash
docker compose ps
```

### Xem log

```bash
docker compose logs -f postgresql
```

### Dừng dịch vụ

```bash
docker compose down
```

Nếu muốn xóa toàn bộ volume dữ liệu:

```bash
docker compose down -v
```
