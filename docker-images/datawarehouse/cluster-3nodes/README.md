# Cụm Data Warehouse 3 Node: ClickHouse Cluster (với Keeper) & Apache Superset (HAProxy + Keepalived HA)

Hệ thống Data Warehouse phân tán 3 Node kết hợp Business Intelligence (BI) Dashboard với kiến trúc High Availability (HA) & Load Balancing:
- **ClickHouse Cluster (`clickhouse/clickhouse-server:26.4`)**: 3 Node phân tán hỗ trợ MPP (Massively Parallel Processing), sao chép dữ liệu (`ReplicatedMergeTree`) và phân tán bảng (`Distributed Engine`).
- **ClickHouse Keeper (Tích hợp trong ClickHouse)**: Thay thế hoàn toàn ZooKeeper cồng kềnh, chạy giao thức đồng thuận Raft (Quorum 3 Node) nhẹ và ổn định.
- **HAProxy 2.8**: Cân bằng tải HTTP (port 8124 $\rightarrow$ 8123) và Native TCP (port 9001 $\rightarrow$ 9000), chủ động kiểm tra sức khỏe (`GET /ping`) trên cả 3 node ClickHouse.
- **Keepalived 2.0**: Quản lý địa chỉ IP ảo **VIP `192.168.56.110`** nổi trên 3 node, tự động failover tức thì khi có sự cố.
- **Apache Superset (`apache/superset:6.1.0`)**: Dashboard trực quan hóa và SQL Lab trên Node 1 kết nối qua VIP `192.168.56.110:8124`.
- **PostgreSQL 16 & Redis 8**: Metadata và Cache cho Superset trên Node 1.

> [!NOTE]
> Xem chi tiết tài liệu chuyên sâu: [So Sánh Kiến Trúc ClickHouse vs PostgreSQL & Chiến Lược Mô Hình Hóa Dữ Liệu](../CLICKHOUSE_VS_POSTGRESQL_AND_DATA_MODELING.md) để nắm rõ cơ chế Sharding, Replication, và cách tối ưu hóa bảng trong ClickHouse.

---

## 1. Cấu trúc thư mục

```text
docker-images/datawarehouse/cluster-3nodes/
├── README.md
├── node1/                                # Triển khai trên Node 1 (192.168.56.111)
│   ├── docker-compose.yml                # ClickHouse + Keeper + HAProxy + Keepalived + Superset Stack
│   ├── config.d/
│   │   ├── keeper.xml                    # server_id = 1
│   │   └── cluster.xml                   # shard = 1, replica = node-01
│   ├── haproxy/
│   │   └── haproxy.cfg                   # LB frontend :8124, :9001, :8404 -> Backend 3 node ClickHouse
│   ├── keepalived/
│   │   ├── Dockerfile
│   │   ├── check_haproxy.sh              # Script kiểm tra sức khỏe HAProxy
│   │   └── keepalived.conf               # VRRP MASTER (Priority 101, VIP 192.168.56.110)
│   ├── secrets/
│   │   ├── clickhouse_password.txt
│   │   ├── postgres_password.txt
│   │   ├── superset_secret_key.txt
│   │   └── superset_admin_password.txt
│   └── superset/                         # Độc lập - chứa Dockerfile, config, dependencies
│       ├── Dockerfile
│       ├── requirements-local.txt
│       └── superset_config.py
├── node2/                                # Triển khai trên Node 2 (192.168.56.112)
│   ├── docker-compose.yml                # ClickHouse + Keeper + HAProxy + Keepalived
│   ├── config.d/
│   │   ├── keeper.xml                    # server_id = 2
│   │   └── cluster.xml                   # shard = 2, replica = node-02
│   ├── haproxy/
│   │   └── haproxy.cfg                   # Cân bằng tải sang 3 node ClickHouse
│   ├── keepalived/
│   │   ├── Dockerfile
│   │   ├── check_haproxy.sh
│   │   └── keepalived.conf               # VRRP BACKUP (Priority 100)
│   └── secrets/
│       └── clickhouse_password.txt
└── node3/                                # Triển khai trên Node 3 (192.168.56.113)
    ├── docker-compose.yml                # ClickHouse + Keeper + HAProxy + Keepalived
    ├── config.d/
    │   ├── keeper.xml                    # server_id = 3
    │   └── cluster.xml                   # shard = 3, replica = node-03
    ├── haproxy/
    │   └── haproxy.cfg                   # Cân bằng tải sang 3 node ClickHouse
    ├── keepalived/
    │   ├── Dockerfile
    │   ├── check_haproxy.sh
    │   └── keepalived.conf               # VRRP BACKUP (Priority 99)
    └── secrets/
        └── clickhouse_password.txt
```

---

## 2. Yêu cầu Mạng & Chi tiết các Port cần mở (Network Requirements)

Để cụm 3 Node hoạt động ổn định và có tính sẵn sàng cao (High Availability), các port sau cần được mở trên Firewall (UFW / Firewalld / Security Group) giữa các node:

### 2.1. Bảng ma trận các Port cần mở

| Port | Giao thức | Dịch vụ | Chiều kết nối (Direction) | Mục đích sử dụng |
| :--- | :---: | :--- | :--- | :--- |
| **`112`** | VRRP | **Keepalived VRRP** | **Node $\leftrightarrow$ Node** | Giao thức VRRP đồng bộ và giữ Virtual IP (`192.168.56.110`) giữa 3 node |
| **`8124`** | TCP | **HAProxy ClickHouse HTTP** | Client / Superset $\rightarrow$ **VIP:8124** | **Cổng Gateway chính** cho Superset, Grafana, HTTP API (cân bằng tải 3 node) |
| **`9001`** | TCP | **HAProxy Native TCP** | Client $\rightarrow$ **VIP:9001** | **Cổng Gateway chính** cho `clickhouse-client` CLI, ETL pipelines |
| **`8404`** | TCP | **HAProxy Stats UI** | Browser $\rightarrow$ Node / VIP | Dashboard giám sát trạng thái UP/DOWN của 3 node ClickHouse theo thời gian thực |
| **`9234`** | TCP | **Keeper Raft** | **Node $\leftrightarrow$ Node** (3 node 2 chiều) | Trao đổi Heartbeat, bầu Leader và đồng thuận Raft giữa 3 Keeper |
| **`9181`** | TCP | **Keeper Client** | **Node $\leftrightarrow$ Node** | ClickHouse Server kết nối vào Keeper để lấy lock DDL, đồng bộ metadata |
| **`9009`** | TCP | **Interserver Sync** | **Node $\leftrightarrow$ Node** | Sao chép và đồng bộ các file dữ liệu bảng (`ReplicatedMergeTree`) giữa các node |
| **`9000`** | TCP | **ClickHouse Native TCP** | Backend nội bộ | Native port của từng instance ClickHouse (HAProxy forward vào đây) |
| **`8123`** | TCP | **ClickHouse HTTP** | Backend nội bộ | HTTP port của từng instance ClickHouse (HAProxy health check `/ping` và forward vào đây) |
| **`8088`** | TCP | **Superset Web UI** | Browser $\rightarrow$ Node 1 | Người dùng truy cập Dashboard và SQL Lab |

```mermaid
flowchart TD
    subgraph Clients ["Clients & BI"]
        Browser["Trình duyệt User"]
        SupersetApp["Superset App (Node 1)"]
        CLI["clickhouse-client / ETL"]
    end

    subgraph VIP_Layer ["High Availability & Gateway Layer (Keepalived VIP: 192.168.56.110)"]
        VIP["Virtual IP (192.168.56.110)<br/>:8124 (HTTP) | :9001 (TCP) | :8404 (Stats)"]
    end

    subgraph N1 ["Node 1 (192.168.56.111) - Master (Priority 101)"]
        HAP1["HAProxy :8124, :9001"]
        KP_V1["Keepalived"]
        CH1["ClickHouse :8123, :9000"]
        KEEPER1["Keeper :9181, :9234"]
        SS["Superset Web :8088"]
    end

    subgraph N2 ["Node 2 (192.168.56.112) - Backup (Priority 100)"]
        HAP2["HAProxy :8124, :9001"]
        KP_V2["Keepalived"]
        CH2["ClickHouse :8123, :9000"]
        KEEPER2["Keeper :9181, :9234"]
    end

    subgraph N3 ["Node 3 (192.168.56.113) - Backup (Priority 99)"]
        HAP3["HAProxy :8124, :9001"]
        KP_V3["Keepalived"]
        CH3["ClickHouse :8123, :9000"]
        KEEPER3["Keeper :9181, :9234"]
    end

    Browser -->|"HTTP 8088"| SS
    SupersetApp -->|"HTTP 8124"| VIP
    CLI -->|"TCP 9001"| VIP

    VIP -.->|"Chuyển tiếp đến Node giữ VIP"| HAP1
    VIP -.->|"Failover khi Node 1 sập"| HAP2
    VIP -.->|"Failover khi Node 2 sập"| HAP3

    HAP1 -->|"Load Balancing / Health Check"| CH1
    HAP1 -->|"Load Balancing / Health Check"| CH2
    HAP1 -->|"Load Balancing / Health Check"| CH3

    %% Raft & Data Sync
    CH1 <-->|"Data Sync :9009 / Query :9000"| CH2
    CH2 <-->|"Data Sync :9009 / Query :9000"| CH3
    CH3 <-->|"Data Sync :9009 / Query :9000"| CH1

    KEEPER1 <-->|"Raft Quorum :9234 / Coordination :9181"| KEEPER2
    KEEPER2 <-->|"Raft Quorum :9234 / Coordination :9181"| KEEPER3
    KEEPER3 <-->|"Raft Quorum :9234 / Coordination :9181"| KEEPER1
```

---

### 2.2. Lệnh cấu hình Firewall mẫu

#### Cho Ubuntu / Debian (UFW):
```bash
# 1. Cho phép VRRP cho Keepalived
sudo ufw allow proto vrrp comment 'Keepalived VRRP'

# 2. Cho phép kết nối nội bộ giữa 3 node
sudo ufw allow from 192.168.56.0/24 to any port 8124 proto tcp comment 'HAProxy ClickHouse HTTP LB'
sudo ufw allow from 192.168.56.0/24 to any port 9001 proto tcp comment 'HAProxy ClickHouse TCP LB'
sudo ufw allow from 192.168.56.0/24 to any port 8404 proto tcp comment 'HAProxy Stats UI'
sudo ufw allow from 192.168.56.0/24 to any port 9234 proto tcp comment 'ClickHouse Keeper Raft'
sudo ufw allow from 192.168.56.0/24 to any port 9181 proto tcp comment 'ClickHouse Keeper Client'
sudo ufw allow from 192.168.56.0/24 to any port 9009 proto tcp comment 'ClickHouse Data Replication'
sudo ufw allow from 192.168.56.0/24 to any port 9000 proto tcp comment 'ClickHouse Native TCP'
sudo ufw allow from 192.168.56.0/24 to any port 8123 proto tcp comment 'ClickHouse HTTP'

# 3. Mở cổng Superset Web UI (trên Node 1)
sudo ufw allow 8088/tcp comment 'Apache Superset Web UI'

# 4. Reload UFW
sudo ufw reload
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
docker compose up -d --build
```

### Bước 3: Khởi động trên Node 3 (Worker 2)
Trên máy ảo Node 3 (`192.168.56.113`):
```bash
cd docker-images/datawarehouse/cluster-3nodes/node3
docker compose up -d --build
```

---

## 4. Kiểm tra Trạng thái Cụm & Tầng High Availability

### 4.1. Kiểm tra Virtual IP (Keepalived VIP)
Trên Node 1, kiểm tra xem card mạng `enp0s8` đã nhận VIP `192.168.56.110` chưa:
```bash
ip addr show enp0s8
# Kết quả hiển thị: inet 192.168.56.110/24 scope global secondary enp0s8
```

### 4.2. Kiểm tra HAProxy Stats Dashboard
Mở trình duyệt truy cập: **`http://192.168.56.110:8404/stats`** (hoặc `http://192.168.56.111:8404/stats`).
- Bảng Dashboard hiển thị cả 3 backend node (`node-db-01`, `node-db-02`, `node-db-03`) đều có trạng thái màu xanh lá cây (**UP**).

### 4.3. Kiểm tra ClickHouse Cluster qua VIP Gateway
Chạy lệnh `clickhouse-client` kết nối qua cổng Load Balancer Native TCP (`9001`):
```bash
docker run --rm -it --network host clickhouse/clickhouse-server:26.4 \
    clickhouse-client --host 192.168.56.110 --port 9001 -u dwh_user --password dwh_password \
    --query "SELECT cluster, shard_num, replica_num, host_name, port, is_local FROM system.clusters WHERE cluster = 'dwh_cluster_3node';"
```

---

## 5. Hướng dẫn Tạo Bảng Phân Tán (Distributed Table)

> [!TIP]
> Nhờ tính năng **DDL Distributed (`ON CLUSTER dwh_cluster_3node`)** kết hợp với ClickHouse Keeper, bạn **chỉ cần thực thi các câu lệnh SQL trên duy nhất 1 node (ví dụ: Node 1)**, ClickHouse sẽ tự động phân phối và tạo Database/Bảng đồng bộ trên toàn bộ 3 node.

### 5.1. Cách truy cập vào ClickHouse CLI

Bạn có thể chọn 1 trong các cách sau để thực thi câu lệnh SQL:

#### Cách 1: Truy cập CLI tương tác bên trong container Node 1 (Khuyên dùng)
Đăng nhập SSH vào máy ảo Node 1 (`192.168.56.111`), sau đó chạy:
```bash
docker exec -it dwh-clickhouse-node1 clickhouse-client -u dwh_user --password dwh_password --multiline
```
*(Tham số `--multiline` cho phép bạn viết câu lệnh SQL trên nhiều dòng và kết thúc bằng dấu chấm phẩy `;`)*

#### Cách 2: Chạy trực tiếp toàn bộ kịch bản SQL (One-liner / Script)
Trên máy ảo Node 1, thực thi toàn bộ script trong 1 lệnh duy nhất:
```bash
docker exec -i dwh-clickhouse-node1 clickhouse-client -u dwh_user --password dwh_password --multiquery << 'EOF'
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
EOF
```

#### Cách 3: Kết nối từ máy Host/Client qua HAProxy VIP
```bash
docker run --rm -it --network host clickhouse/clickhouse-server:26.4 \
    clickhouse-client --host 192.168.56.110 --port 9001 -u dwh_user --password dwh_password --multiline
```

---

### 5.2. Chi tiết các câu lệnh SQL và Cơ chế hoạt động

Trong ClickHouse Cluster, mô hình chuẩn gồm **Bảng Cục Bộ (`_local`)** lưu dữ liệu thực tế và **Bảng Phân Tán (`Distributed`)** làm Router nhận truy vấn:

```sql
-- 1. Tạo Database trên toàn bộ 3 Node
CREATE DATABASE IF NOT EXISTS analytics ON CLUSTER dwh_cluster_3node;

-- 2. Tạo Bảng Cục Bộ trên toàn bộ 3 Node (ReplicatedMergeTree kết hợp ClickHouse Keeper)
CREATE TABLE IF NOT EXISTS analytics.orders_local ON CLUSTER dwh_cluster_3node (
    order_id UInt64,
    customer_id UInt32,
    order_date Date,
    product_category LowCardinality(String),
    amount Float64,
    country LowCardinality(String)
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/orders', '{replica}')
ORDER BY (order_date, order_id);

-- 3. Tạo Bảng Phân Tán trên toàn bộ 3 Node (Router điều hướng truy vấn)
CREATE TABLE IF NOT EXISTS analytics.orders ON CLUSTER dwh_cluster_3node
AS analytics.orders_local
ENGINE = Distributed(dwh_cluster_3node, analytics, orders_local, rand());

-- 4. Chèn dữ liệu mẫu vào Bảng Phân Tán (ClickHouse tự băm và phân phối đều xuống 3 Node)
INSERT INTO analytics.orders (order_id, customer_id, order_date, product_category, amount, country) VALUES
    (1, 1001, '2026-08-01', 'Electronics', 550.00, 'VN'),
    (2, 1002, '2026-08-01', 'Fashion', 85.50, 'US'),
    (3, 1003, '2026-08-02', 'Home & Living', 120.00, 'VN'),
    (4, 1004, '2026-08-02', 'Electronics', 990.00, 'SG'),
    (5, 1005, '2026-08-03', 'Fashion', 45.00, 'VN'),
    (6, 1006, '2026-08-03', 'Books', 30.00, 'US'),
    (7, 1007, '2026-08-04', 'Electronics', 320.00, 'JP'),
    (8, 1008, '2026-08-04', 'Home & Living', 210.00, 'SG');

-- 5. Kiểm tra dữ liệu được phân tán thực tế trên từng Node
SELECT hostName(), count() FROM analytics.orders_local GROUP BY hostName();

-- 6. Truy vấn tổng hợp trên Bảng Phân Tán (Tự động gom dữ liệu từ 3 node)
SELECT count() AS total_orders, sum(amount) AS total_amount FROM analytics.orders;
```

---

## 6. Kết nối Superset vào ClickHouse Cluster (Qua VIP Gateway)

Để đảm bảo Superset **không bao giờ bị mất kết nối** kể cả khi có node ClickHouse bị sự cố:

1. Mở trình duyệt truy cập: **`http://192.168.56.111:8088`** (hoặc `http://localhost:8088`).
2. Đăng nhập: `admin` / `admin_password`.
3. Vào **Settings** $\rightarrow$ **Database Connections** $\rightarrow$ **+ Database**.
4. Chọn **ClickHouse Connect** và nhập chuỗi SQLAlchemy URI trỏ tới **VIP:8124**:
   ```text
   clickhousedb://dwh_user:dwh_password@192.168.56.110:8124/analytics
   ```
   *(Hoặc format `clickhouse+connect://dwh_user:dwh_password@192.168.56.110:8124/analytics`)*
5. Bấm **Test Connection** $\rightarrow$ **Connect**.
6. Khi tạo Dataset trên Superset, chọn bảng **`orders`** (Bảng phân tán `Distributed`).

---

## 7. Thử nghiệm Cơ chế Failover & High Availability

1. **Thử nghiệm 1 Node ClickHouse bị chết**:
   - Dừng container ClickHouse trên Node 1:
     ```bash
     docker stop dwh-clickhouse-node1
     ```
   - Quan sát trên Dashboard HAProxy (`http://192.168.56.110:8404/stats`): `node-db-01` chuyển sang trạng thái **DOWN** sau 2 giây.
   - Quay lại Superset và refresh Dashboard hoặc chạy SQL query: **Truy vấn vẫn thành công 100%** do HAProxy đã tự động điều hướng sang `node-db-02` và `node-db-03`.

2. **Thử nghiệm Node 1 (Master) bị sập hoàn toàn**:
   - Dừng toàn bộ stack trên Node 1 hoặc tắt card mạng Node 1.
   - Keepalived trên Node 2 tự động tiếp quản VIP `192.168.56.110`.
   - Mọi kết nối từ các client khác đến `192.168.56.110:8124` vẫn thông suốt.
