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

## 2. Yêu cầu Mạng & Chi tiết các Port cần mở (Network Requirements)

Để cụm 3 Node hoạt động ổn định và đồng bộ dữ liệu song song, các port sau cần được mở trên Firewall (UFW / Firewalld / Security Group) giữa các node:

### 2.1. Bảng ma trận các Port cần mở

| Port | Giao thức | Dịch vụ | Chiều kết nối (Direction) | Mục đích sử dụng |
| :--- | :---: | :--- | :--- | :--- |
| **`9234`** | TCP | **Keeper Raft** | **Node $\leftrightarrow$ Node** (3 node 2 chiều) | Trao đổi Heartbeat, bầu Leader và đồng thuận Raft giữa 3 Keeper |
| **`9181`** | TCP | **Keeper Client** | **Node $\leftrightarrow$ Node** | ClickHouse Server kết nối vào Keeper để lấy lock DDL, đồng bộ metadata |
| **`9009`** | TCP | **Interserver Sync** | **Node $\leftrightarrow$ Node** | Sao chép và đồng bộ các file dữ liệu bảng (`ReplicatedMergeTree`) giữa các node |
| **`9000`** | TCP | **ClickHouse Native TCP** | **Node $\leftrightarrow$ Node** & Client $\rightarrow$ Node | Chạy truy vấn phân tán (`Distributed Query`) giữa các node, `clickhouse-client` CLI |
| **`8123`** | TCP | **ClickHouse HTTP** | Client / Superset $\rightarrow$ Node | Superset, Grafana, Web Client kết nối truy vấn qua HTTP API |
| **`8088`** | TCP | **Superset Web UI** | Browser $\rightarrow$ Node 1 | Người dùng truy cập Dashboard và SQL Lab |

```mermaid
flowchart LR
    subgraph External [Client & BI]
        Browser["Trình duyệt User"]
    end

    subgraph N1 ["Node 1 (192.168.56.111)"]
        CH1["ClickHouse :8123, :9000"]
        KP1["Keeper :9181, :9234"]
        SS["Superset :8088"]
    end

    subgraph N2 ["Node 2 (192.168.56.112)"]
        CH2["ClickHouse :8123, :9000"]
        KP2["Keeper :9181, :9234"]
    end

    subgraph N3 ["Node 3 (192.168.56.113)"]
        CH3["ClickHouse :8123, :9000"]
        KP3["Keeper :9181, :9234"]
    end

    Browser -->|TCP 8088| SS
    SS -->|TCP 8123| CH1

    %% Inter-node
    CH1 <-->|TCP 9000 (Distributed Query)\nTCP 9009 (Data Sync)| CH2
    CH2 <-->|TCP 9000 (Distributed Query)\nTCP 9009 (Data Sync)| CH3
    CH3 <-->|TCP 9000 (Distributed Query)\nTCP 9009 (Data Sync)| CH1

    KP1 <-->|TCP 9234 (Raft Quorum)\nTCP 9181 (Coordination)| KP2
    KP2 <-->|TCP 9234 (Raft Quorum)\nTCP 9181 (Coordination)| KP3
    KP3 <-->|TCP 9234 (Raft Quorum)\nTCP 9181 (Coordination)| KP1
```

---

### 2.2. Lệnh cấu hình Firewall mẫu

#### Cho Ubuntu / Debian (UFW):
```bash
# 1. Cho phép kết nối nội bộ giữa 3 node (Khuyên dùng: mở toàn bộ dải IP private mạng nội bộ)
sudo ufw allow from 192.168.56.0/24 to any port 9234 proto tcp comment 'ClickHouse Keeper Raft'
sudo ufw allow from 192.168.56.0/24 to any port 9181 proto tcp comment 'ClickHouse Keeper Client'
sudo ufw allow from 192.168.56.0/24 to any port 9009 proto tcp comment 'ClickHouse Data Replication'
sudo ufw allow from 192.168.56.0/24 to any port 9000 proto tcp comment 'ClickHouse Native TCP'
sudo ufw allow from 192.168.56.0/24 to any port 8123 proto tcp comment 'ClickHouse HTTP'

# 2. Mở cổng Superset cho người dùng bên ngoài (chỉ cần chạy trên Node 1)
sudo ufw allow 8088/tcp comment 'Apache Superset Web UI'

# 3. Reload UFW
sudo ufw reload
```

#### Cho RHEL / Rocky Linux / CentOS (Firewalld):
```bash
# 1. Mở các port giao tiếp cụm nội bộ
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.56.0/24" port port="9234" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.56.0/24" port port="9181" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.56.0/24" port port="9009" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.56.0/24" port port="9000" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.56.0/24" port port="8123" protocol="tcp" accept'

# 2. Mở port Superset trên Node 1
sudo firewall-cmd --permanent --add-port=8088/tcp

# 3. Reload Firewalld
sudo firewall-cmd --reload
```

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
