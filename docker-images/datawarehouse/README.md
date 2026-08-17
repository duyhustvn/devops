# Data Warehouse Stack: ClickHouse & Apache Superset

Hệ thống Data Warehouse (DWH) & Business Intelligence (BI) Dashboard được triển khai hoàn chỉnh thông qua Docker Compose, tích hợp:
- **ClickHouse (OLAP Engine)**: Cơ sở dữ liệu phân tích dạng cột (Column-oriented DBMS) hiệu năng cao.
- **Apache Superset (BI Dashboard)**: Giao diện trực quan hóa dữ liệu, xây dựng dashboard và SQL Lab.
- **PostgreSQL**: Lưu trữ metadata của Superset.
- **Redis**: Caching kết quả truy vấn và Celery message broker.

---

## 1. Cấu trúc thư mục

```text
datawarehouse/
├── docker-compose.yml
├── README.md
└── superset/
    ├── Dockerfile
    ├── requirements-local.txt
    └── superset_config.py
```

---

## 2. Thông tin tài khoản mặc định

| Dịch vụ | Host / URL | Cổng | Username | Password | Database |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Apache Superset UI** | `http://localhost:8088` | `8088` | `admin` | `admin_password` | - |
| **ClickHouse HTTP** | `http://localhost:8123` | `8123` | `dwh_user` | `dwh_password` | `analytics` |
| **ClickHouse Native TCP** | `localhost:9000` | `9000` | `dwh_user` | `dwh_password` | `analytics` |
| **PostgreSQL (Metadata)**| `dwh-superset-db` | `5432` | `superset` | `superset_password`| `superset` |
| **Redis (Cache)** | `dwh-superset-redis` | `6379` | - | - | - |

---

## 3. Hướng dẫn Build và Khởi chạy

### Bước 1: Di chuyển vào thư mục
```bash
cd docker-images/datawarehouse
```

### Bước 2: Khởi chạy các dịch vụ
```bash
docker compose up -d --build
```

### Bước 3: Kiểm tra trạng thái
```bash
docker compose ps
```
> **Lưu ý:** Container `dwh-superset-init` sau khi chạy xong script khởi tạo database và tài khoản admin sẽ chuyển sang trạng thái `Exited (0)`. Đây là hành vi bình thường.

---

## 4. Hướng dẫn kết nối Superset vào ClickHouse

1. Mở trình duyệt và truy cập: **`http://localhost:8088`**.
2. Đăng nhập bằng tài khoản:
   - **Username**: `admin`
   - **Password**: `admin_password`
3. Điều hướng tới menu: **Settings** (góc trên bên phải) $\rightarrow$ chọn **Database Connections**.
4. Bấm nút **+ Database** (màu xanh ở góc trên bên phải).
5. Tại mục **SUPPORTED DATABASES**, chọn **ClickHouse Connect**.
6. Điền thông tin kết nối hoặc nhập chuỗi **SQLALCHEMY URI**:
   ```text
   clickhouse+connect://dwh_user:dwh_password@clickhouse:8123/analytics
   ```
   > **Giải thích:** Trong mạng nội bộ Docker (`dwh-network`), Superset gọi Clickhouse qua hostname là `clickhouse` và cổng HTTP là `8123`.
7. Bấm **Test Connection** để kiểm tra (kết quả hiển thị *Connection looks good!*).
8. Bấm **Connect** $\rightarrow$ **Finish**.

---

## 5. Thử nghiệm tạo dữ liệu mẫu và Dashboard

### Bước 1: Tạo bảng dữ liệu mẫu trong ClickHouse
Bạn có thể chạy lệnh qua CLI của ClickHouse bằng Docker:

```bash
docker exec -it dwh-clickhouse clickhouse-client -u dwh_user --password dwh_password -d analytics
```

Chạy lệnh SQL sau để tạo bảng đơn hàng và nạp dữ liệu mẫu:

```sql
CREATE TABLE IF NOT EXISTS analytics.orders (
    order_id UInt64,
    customer_id UInt32,
    order_date Date,
    product_category LowCardinality(String),
    amount Float64,
    country LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY (order_date, order_id);

INSERT INTO analytics.orders VALUES
    (1, 1001, '2026-08-01', 'Electronics', 550.00, 'VN'),
    (2, 1002, '2026-08-01', 'Fashion', 85.50, 'US'),
    (3, 1003, '2026-08-02', 'Home & Living', 120.00, 'VN'),
    (4, 1004, '2026-08-02', 'Electronics', 990.00, 'SG'),
    (5, 1005, '2026-08-03', 'Fashion', 45.00, 'VN'),
    (6, 1006, '2026-08-03', 'Books', 30.00, 'US'),
    (7, 1007, '2026-08-04', 'Electronics', 320.00, 'JP'),
    (8, 1008, '2026-08-04', 'Home & Living', 210.00, 'SG');
```

Gõ `exit` để thoát `clickhouse-client`.

### Bước 2: Tạo Dataset trên Superset
1. Trong Superset, chọn menu **Datasets** $\rightarrow$ bấm **+ Dataset**.
2. Chọn:
   - **DATABASE**: `ClickHouse` (tên bạn đã đặt khi connect)
   - **SCHEMA**: `analytics`
   - **TABLE**: `orders`
3. Bấm **Create Dataset and Create Chart**.

### Bước 3: Tạo Chart & Dashboard
1. Chọn loại biểu đồ mong muốn (ví dụ: **Bar Chart**, **Pie Chart**, **Time-series Line Chart**).
2. Kéo thả các trường:
   - **X-Axis / Dimensions**: `country` hoặc `product_category`
   - **Metrics**: `SUM(amount)` hoặc `COUNT(order_id)`
3. Bấm **Create Chart** $\rightarrow$ **Save** $\rightarrow$ Thêm vào **Dashboard mới**.

---

## 6. Các lệnh quản trị hữu ích

- **Xem log hệ thống:**
  ```bash
  docker compose logs -f superset
  docker compose logs -f clickhouse
  ```

- **Dừng hệ thống:**
  ```bash
  docker compose down
  ```

- **Dừng và xoá sạch volume (reset toàn bộ dữ liệu):**
  ```bash
  docker compose down -v
  ```
