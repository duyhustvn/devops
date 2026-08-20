# Cụm Data Warehouse 3 Node: ClickHouse Cluster (với ClickHouse Keeper) & Apache Superset

Hệ thống Data Warehouse phân tán 3 Node kết hợp Business Intelligence (BI) Dashboard:
- **ClickHouse Cluster (`clickhouse/clickhouse-server:26.4`)**: 3 Node phân tán hỗ trợ MPP (Massively Parallel Processing), sao chép dữ liệu (`ReplicatedMergeTree`) và phân tán bảng (`Distributed Engine`).
- **ClickHouse Keeper (Tích hợp trong ClickHouse)**: Thay thế hoàn toàn ZooKeeper cồng kềnh, chạy giao thức đồng thuận Raft (Quorum 3 Node) nhẹ và ổn định.
- **Apache Superset (`apache/superset:6.1.0`)**: Dashboard trực quan hóa và SQL Lab trên Node 1.
- **PostgreSQL 16 & Redis 8**: Metadata và Cache cho Superset trên Node 1.

---

## 1. Cấu trúc thư mục

```text
docker-images/datawarehouse/cluster-3nodes/
├── README.md
├── node1/                                # Triển khai trên Node 1 (192.168.56.111)
│   ├── docker-compose.yml                # ClickHouse + Keeper + Superset + Postgres + Redis
│   ├── config.d/
│   │   ├── keeper.xml                    # server_id = 1
│   │   └── cluster.xml                   # shard = 1, replica = node-01
│   └── secrets/
│       ├── clickhouse_password.txt
│       ├── postgres_password.txt
│       ├── superset_secret_key.txt
│       └── superset_admin_password.txt
├── node2/                                # Triển khai trên Node 2 (192.168.56.112)
│   ├── docker-compose.yml                # ClickHouse + Keeper
│   ├── config.d/
│   │   ├── keeper.xml                    # server_id = 2
│   │   └── cluster.xml                   # shard = 2, replica = node-02
│   └── secrets/
│       └── clickhouse_password.txt
└── node3/                                # Triển khai trên Node 3 (192.168.56.113)
    ├── docker-compose.yml                # ClickHouse + Keeper
    ├── config.d/
    │   ├── keeper.xml                    # server_id = 3
    │   └── cluster.xml                   # shard = 3, replica = node-03
    └── secrets/
        └── clickhouse_password.txt
```

---

## 2. Bảng phân bổ IP và Port

| Node | IP | Services | Port mở |
| :--- | :--- | :--- | :--- |
| **Node 1** | `192.168.56.111` | ClickHouse, Keeper 01, Superset, Postgres, Redis | `8123` (HTTP), `9000` (TCP), `9009` (Interserver), `9181` (Keeper), `9234` (Raft), `8088` (Superset) |
| **Node 2** | `192.168.56.112` | ClickHouse, Keeper 02 | `8123` (HTTP), `9000` (TCP), `9009` (Interserver), `9181` (Keeper), `9234` (Raft) |
| **Node 3** | `192.168.56.113` | ClickHouse, Keeper 03 | `8123` (HTTP), `9000` (TCP), `9009` (Interserver), `9181` (Keeper), `9234` (Raft) |

---

## 3. Hướng dẫn Triển khai Từng Node

### Bước 1: Khởi động trên Node 1 (Master)
Trên máy ảo Node 1 (`192.168.56.111`):
```bash
cd docker-images/datawarehouse/cluster-3nodes/node1
docker compose up -d --build
```

### Bước 2: Khởi động trên Node 2 (Worker 1)
Trên máy ảo Node 2 (`192.168.56.112`):
```bash
cd docker-images/datawarehouse/cluster-3nodes/node2
docker compose up -d
```

### Bước 3: Khởi động trên Node 3 (Worker 2)
Trên máy ảo Node 3 (`192.168.56.113`):
```bash
cd docker-images/datawarehouse/cluster-3nodes/node3
docker compose up -d
```

---

## 4. Kiểm tra Trạng thái Cụm ClickHouse Cluster

Truy cập vào ClickHouse CLI trên Node 1:
```bash
docker exec -it dwh-clickhouse-node1 clickhouse-client -u dwh_user --password dwh_password
```

Chạy các lệnh kiểm tra:

```sql
-- 1. Kiểm tra danh sách các Node trong cụm
SELECT cluster, shard_num, replica_num, host_name, port, is_local 
FROM system.clusters 
WHERE cluster = 'dwh_cluster_3node';

-- 2. Kiểm tra trạng thái đồng bộ ClickHouse Keeper
SELECT * FROM system.zookeeper WHERE path = '/';
```

---

## 5. Hướng dẫn Tạo Bảng Phân Tán (Distributed Table)

Trong ClickHouse Cluster, mô hình chuẩn gồm **Bảng Cục Bộ (`_local`)** lưu dữ liệu thực tế và **Bảng Phân Tán (`Distributed`)** làm Router nhận truy vấn:

```sql
-- 1. Tạo Database trên toàn bộ 3 Node
CREATE DATABASE IF NOT EXISTS analytics ON CLUSTER dwh_cluster_3node;

-- 2. Tạo Bảng Cục Bộ trên toàn bộ 3 Node
CREATE TABLE IF NOT EXISTS analytics.orders_local ON CLUSTER dwh_cluster_3node (
    order_id UInt64,
    customer_id UInt32,
    order_date Date,
    product_category LowCardinality(String),
    amount Float64,
    country LowCardinality(String)
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/orders', '{replica}')
ORDER BY (order_date, order_id);

-- 3. Tạo Bảng Phân Tán trên toàn bộ 3 Node
CREATE TABLE IF NOT EXISTS analytics.orders ON CLUSTER dwh_cluster_3node
AS analytics.orders_local
ENGINE = Distributed(dwh_cluster_3node, analytics, orders_local, rand());

-- 4. Chèn dữ liệu mẫu vào Bảng Phân Tán (ClickHouse tự chia đều xuống 3 Node)
INSERT INTO analytics.orders (order_id, customer_id, order_date, product_category, amount, country) VALUES
    (1, 1001, '2026-08-01', 'Electronics', 550.00, 'VN'),
    (2, 1002, '2026-08-01', 'Fashion', 85.50, 'US'),
    (3, 1003, '2026-08-02', 'Home & Living', 120.00, 'VN'),
    (4, 1004, '2026-08-02', 'Electronics', 990.00, 'SG'),
    (5, 1005, '2026-08-03', 'Fashion', 45.00, 'VN'),
    (6, 1006, '2026-08-03', 'Books', 30.00, 'US'),
    (7, 1007, '2026-08-04', 'Electronics', 320.00, 'JP'),
    (8, 1008, '2026-08-04', 'Home & Living', 210.00, 'SG');

-- 5. Kiểm tra dữ liệu phân tán trên từng Node
SELECT hostName(), count() FROM analytics.orders_local GROUP BY hostName();
```

---

## 6. Kết nối Superset vào ClickHouse Cluster

1. Mở trình duyệt truy cập: **`http://192.168.56.111:8088`** (hoặc `http://localhost:8088`).
2. Đăng nhập: `admin` / `admin_password`.
3. Vào **Settings** $\rightarrow$ **Database Connections** $\rightarrow$ **+ Database**.
4. Chọn **ClickHouse Connect** và nhập chuỗi SQLAlchemy URI:
   ```text
   clickhouse+connect://dwh_user:dwh_password@clickhouse:8123/analytics
   ```
5. Bấm **Test Connection** $\rightarrow$ **Connect**.
6. Khi tạo Dataset trên Superset, chọn bảng **`orders`** (Bảng phân tán `Distributed`), Superset sẽ tự động tận dụng sức mạnh tính toán song song của toàn bộ 3 Node ClickHouse!
