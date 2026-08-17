# Data Warehouse Stack: ClickHouse & Apache Superset

Hệ thống Data Warehouse (DWH) & Business Intelligence (BI) Dashboard được triển khai hoàn chỉnh thông qua Docker Compose, tích hợp các phiên bản (đã xác thực trên Docker Hub Registry):
- **ClickHouse (`clickhouse/clickhouse-server:26.4`)**: Cơ sở dữ liệu phân tích dạng cột (Column-oriented DBMS) hiệu năng cao (bản v26).
- **Apache Superset (`apache/superset:6.1.0`)**: Giao diện trực quan hóa dữ liệu, xây dựng dashboard và SQL Lab (bản v6).
- **PostgreSQL (`postgres:16`)**: Lưu trữ metadata của Superset (Debian standard, không dùng Alpine).
- **Redis (`redis:8`)**: Caching kết quả truy vấn và Celery message broker (Debian standard, không dùng Alpine).

---

## 1. Chi tiết chức năng từng Service và dữ liệu lưu trữ

Hệ thống được thiết kế theo mô hình tách biệt rõ ràng giữa **Lớp lưu trữ/tính toán phân tích (Analytics Storage & Compute)** và **Lớp quản lý trực quan hóa (BI & Metadata Layer)**:

```mermaid
flowchart TD
    subgraph ClientLayer [Client & User Layer]
        User([Người dùng / Data Analyst])
        ETL([ETL Pipeline / Ingestion Worker])
    end

    subgraph BILayer [Lớp BI & Visualization - Apache Superset 6.1.0]
        SS_APP["superset (Web App v6.1.0)\n- Render Charts / Dashboards\n- SQL Lab IDE\n- Quản lý phiên truy cập"]
        SS_INIT["superset-init (Bootstrap v6.1.0)\n- DB Schema Migration\n- Khởi tạo Admin User & Roles"]
        PG[("superset-db (PostgreSQL 16)\n- Lưu Metadata: Users, Roles\n- Danh sách Dashboards, Charts\n- Database Connections URI")]
        RD[("superset-redis (Redis 8)\n- Cache kết quả truy vấn\n- Cache Dashboard metadata\n- Message Queue / Sessions")]
    end

    subgraph DWHLayer [Lớp Data Warehouse - ClickHouse 26.4]
        CH[("clickhouse (ClickHouse Server 26.4)\n- Động cơ OLAP dạng cột\n- Nén & phân tích dữ liệu lớn\n- Xử lý câu truy vấn SQL siêu tốc")]
    end

    User <-->|HTTP :8088| SS_APP
    ETL -->|TCP :9000 / HTTP :8123| CH

    SS_APP <-->|SQLAlchemy / Metadata| PG
    SS_APP <-->|Cache / Queue| RD
    SS_APP -->|clickhouse-connect HTTP :8123| CH
    SS_INIT -->|Migrate Schema| PG
```

### 1.1. `clickhouse` (ClickHouse Server v26.4)
* **Dịch vụ làm gì (Chức năng):**
  * Là "trái tim" của hệ thống Data Warehouse, chịu trách nhiệm lưu trữ toàn bộ dữ liệu nghiệp vụ dạng cột (Columnar Storage).
  * Thực hiện tính toán và phân tích tổng hợp (Aggregation: `SUM`, `COUNT`, `AVG`, `GROUP BY`, `JOIN`, Window functions) trên hàng triệu đến hàng tỷ bản ghi với độ trễ chỉ tính bằng mili-giây.
  * Hỗ trợ tỉ lệ nén dữ liệu cực cao (gấp 3-5 lần cơ sở dữ liệu quan hệ thông thường) bằng các thuật toán LZ4 / ZSTD.
* **Lưu trữ những gì (Dữ liệu lưu trữ):**
  * **Dữ liệu phân tích nghiệp vụ:** Các bảng Facts (giao dịch, đơn hàng, sự kiện clickstream, log hệ thống, telemetry...) và Dimensions (khách hàng, sản phẩm, địa điểm...).
  * **System Tables & Internal Logs:** Các bảng nội bộ của ClickHouse theo dõi lịch sử truy vấn (`system.query_log`), metric hiệu năng, trace log và thống kê part dữ liệu.
* **Volume lưu trữ:**
  * `dwh_clickhouse_data` (`/var/lib/clickhouse`): Chứa toàn bộ dữ liệu bảng và partition data.
  * `dwh_clickhouse_logs` (`/var/log/clickhouse-server`): Chứa file log hoạt động của server.

---

### 1.2. `superset` (Apache Superset v6.1.0 Web UI)
* **Dịch vụ làm gì (Chức năng):**
  * Cung cấp giao diện Web người dùng để trực quan hóa dữ liệu (BI Dashboard).
  * Cung cấp công cụ **SQL Lab** để người dùng viết truy vấn SQL trực tiếp vào ClickHouse và xem trước kết quả.
  * Xử lý xác thực người dùng, phân quyền truy cập Dashboard/Dataset theo nhóm (Role-Based Access Control - RBAC).
  * Đóng vai trò làm Client gửi query phân tích đến ClickHouse và render thành các Chart tương tác (Line, Bar, Heatmap, Geospatial...).
* **Lưu trữ những gì (Dữ liệu lưu trữ):**
  * Bản thân container Web không lưu dữ liệu vĩnh viễn trong container.
  * `dwh_superset_home` (`/app/superset_home`): Lưu trữ cấu hình runtime cục bộ, các file tải lên tạm thời (nếu có). Toàn bộ dữ liệu cấu hình chính đều được chuyển về PostgreSQL.

---

### 1.3. `superset-init` (Bộ khởi tạo hệ thống Superset)
* **Dịch vụ làm gì (Chức năng):**
  * Là container chạy một lần (One-shot task/Bootstrap) khi khởi động cụm dịch vụ.
  * Tự động chạy lệnh `superset db upgrade` để khởi tạo/cập nhật cấu trúc bảng trong PostgreSQL.
  * Tự động tạo tài khoản Admin đầu tiên thông qua lệnh `superset fab create-admin`.
  * Tự động nạp bộ quyền và role mặc định (Admin, Alpha, Gamma, Public) qua lệnh `superset init`.
* **Trạng thái vòng đời:** Sau khi hoàn tất quá trình khởi tạo, container sẽ tự động dừng với trạng thái `Exited (0)`.

---

### 1.4. `superset-db` (PostgreSQL 16 - Lưu trữ Metadata)
* **Dịch vụ làm gì (Chức năng):**
  * Đóng vai trò là Cơ sở dữ liệu cấu hình (Configuration & Metadata DB) cho Apache Superset.
  * Sử dụng image chính thức chuẩn Debian `postgres:16` mang lại độ ổn định cao và tương thích tối đa với thư viện `psycopg2`.
  * Phục vụ các giao dịch transactional (OLTP) của riêng ứng dụng Superset.
* **Lưu trữ những gì (Dữ liệu lưu trữ):**
  * **Tài khoản & Phân quyền:** Danh sách User, Hash mật khẩu, Role, Quyền hạn truy cập từng schema/table.
  * **Cấu hình kết nối:** Thông tin các Database kết nối vào Superset (chuỗi kết nối SQLAlchemy URI đến ClickHouse, thông tin mã hóa bảo mật).
  * **Datasets & Metrics:** Định nghĩa các Virtual Dataset, Calculated Columns, Custom SQL Metrics.
  * **Dashboards & Charts:** Layout sắp xếp biểu đồ, màu sắc, cấu hình bộ lọc (Dashboard Filters, Cross-filtering).
  * **SQL Lab History:** Lịch sử các câu lệnh SQL mà người dùng từng chạy trong SQL Lab, danh sách Query đã lưu (Saved Queries).
* **Volume lưu trữ:**
  * `dwh_superset_pgdata` (`/var/lib/postgresql/data`): Chứa toàn bộ dữ liệu PostgreSQL database.

---

### 1.5. `superset-redis` (Redis 8 - Bộ nhớ Cache & Message Broker)
* **Dịch vụ làm gì (Chức năng):**
  * Cung cấp lớp lưu trữ In-memory tốc độ cực cao làm bộ nhớ đệm (Caching Layer) cho Superset.
  * Sử dụng image chuẩn `redis:8` (Debian base) với hiệu năng tối ưu và hỗ trợ đầy đủ các module core.
  * Giảm tải cho ClickHouse khi có nhiều người dùng cùng xem chung một Dashboard hoặc một biểu đồ không thay đổi dữ liệu liên tục.
  * Đóng vai trò làm hàng đợi thông điệp (Message Broker / Result Backend cho Celery) khi mở rộng xử lý tác vụ bất đồng bộ (Async Query Execution, Email Reports).
* **Lưu trữ những gì (Dữ liệu lưu trữ):**
  * **Query Results Cache:** Kết quả của các câu query dữ liệu từ ClickHouse (hạn chế việc phải query lại ClickHouse liên tục trong thời gian cache timeout).
  * **Dashboard / Form-data Cache:** Trạng thái cấu hình của biểu đồ và dashboard khi người dùng tương tác.
  * **Session Data:** Phiên đăng nhập của người dùng.
* **Volume lưu trữ:**
  * `dwh_redis_data` (`/data`): Lưu trữ file snapshot RDB định kỳ của Redis.

---

## 2. Bảng tổng hợp Volumes và Mức độ quan trọng

| Tên Docker Volume | Mount Path trong Container | Dữ liệu lưu trữ | Tầm quan trọng khi Backup |
| :--- | :--- | :--- | :--- |
| **`dwh_clickhouse_data`** | `/var/lib/clickhouse` | Toàn bộ dữ liệu Data Warehouse (bảng, partitions) | 🔴 **Tối quan trọng** (Mất là mất dữ liệu DWH) |
| **`dwh_clickhouse_logs`** | `/var/log/clickhouse-server` | Log hoạt động của ClickHouse | ⚪ Thấp (Có thể tự sinh mới) |
| **`dwh_superset_pgdata`** | `/var/lib/postgresql/data` | Toàn bộ Dashboard, User, Quyền, Kết nối DB | 🔴 **Tối quan trọng** (Mất là mất công sức vẽ dashboard) |
| **`dwh_superset_home`** | `/app/superset_home` | File cấu hình local, cache file upload | 🟡 Trung bình |
| **`dwh_redis_data`** | `/data` | Dữ liệu In-memory cache & sessions | 🟢 Thấp (Tự tái tạo khi có query mới) |

---

## 3. Cấu trúc thư mục

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

## 4. Thông tin tài khoản mặc định

| Dịch vụ | Docker Image Tag | Host / URL | Cổng | Username | Password | Database |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Apache Superset UI** | `apache/superset:6.1.0` | `http://localhost:8088` | `8088` | `admin` | `admin_password` | - |
| **ClickHouse HTTP** | `clickhouse/clickhouse-server:26.4` | `http://localhost:8123` | `8123` | `dwh_user` | `dwh_password` | `analytics` |
| **ClickHouse Native TCP** | `clickhouse/clickhouse-server:26.4` | `localhost:9000` | `9000` | `dwh_user` | `dwh_password` | `analytics` |
| **PostgreSQL (Metadata)**| `postgres:16` | `dwh-superset-db` | `5432` | `superset` | `superset_password`| `superset` |
| **Redis (Cache)** | `redis:8` | `dwh-superset-redis` | `6379` | - | - | - |

---

## 5. Hướng dẫn Build và Khởi chạy

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

## 6. Hướng dẫn kết nối Superset vào ClickHouse

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

## 7. Thử nghiệm tạo dữ liệu mẫu và Dashboard

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

## 8. Các lệnh quản trị hữu ích

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
