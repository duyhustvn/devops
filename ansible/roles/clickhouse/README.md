# Ansible Role: ClickHouse Cluster (với Keeper, HAProxy & Keepalived HA)

Ansible Role tự động triển khai cụm **ClickHouse Cluster phân tán 3 Node** đạt chuẩn High Availability (HA) và Load Balancing:
- **ClickHouse Server (`clickhouse/clickhouse-server:26.4`)**: Lưu trữ và xử lý truy vấn phân tán MPP.
- **ClickHouse Keeper (Tích hợp)**: Chạy giao thức đồng thuận Raft (Quorum 3 Node) thay thế ZooKeeper.
- **HAProxy 2.8**: Cân bằng tải HTTP (Port `8124` $\rightarrow$ `8123`), Native TCP (Port `9001` $\rightarrow$ `9000`) và Dashboard Stats (`:8404/stats`).
- **Keepalived 2.0**: Quản lý Virtual IP **VIP `192.168.56.110`**, tự động failover giữa các node.

---

## 1. Yêu cầu Hệ thống (Requirements)

- Hệ điều hành: Ubuntu 22.04 LTS (Jammy) / Debian 11/12 / Rocky Linux 9.
- Docker & Docker Compose plugin đã được cài đặt (Role `docker` đi kèm).
- Quyền root (`become: true`).

---

## 2. Các biến Cấu hình (Role Variables)

### Biến mặc định (`defaults/main.yml`):

| Tên biến | Giá trị mặc định | Mô tả |
| :--- | :--- | :--- |
| `clickhouse_deploy_dir` | `/u01/clickhouse` | Thư mục triển khai trên máy chủ đích |
| `clickhouse_image` | `clickhouse/clickhouse-server:26.4` | Docker image ClickHouse Server |
| `clickhouse_cluster_name` | `dwh_cluster_3node` | Tên cluster định nghĩa trong `cluster.xml` |
| `clickhouse_db` | `analytics` | Database mặc định được khởi tạo |
| `clickhouse_user` | `dwh_user` | Tài khoản ClickHouse người dùng |
| `clickhouse_http_port` | `8123` | Cổng HTTP nội bộ của ClickHouse |
| `clickhouse_tcp_port` | `9000` | Cổng Native TCP nội bộ của ClickHouse |
| `clickhouse_interserver_port`| `9009` | Cổng sao chép dữ liệu giữa các node |
| `clickhouse_keeper_port` | `9181` | Cổng Client kết nối vào Keeper (DCS) |
| `clickhouse_keeper_raft_port`| `9234` | Cổng giao tiếp đồng thuận Raft giữa các Keeper |
| `haproxy_image` | `haproxy:2.8-alpine` | Docker image HAProxy Load Balancer |
| `haproxy_http_port` | `8124` | Cổng frontend HTTP của HAProxy |
| `haproxy_tcp_port` | `9001` | Cổng frontend Native TCP của HAProxy |
| `haproxy_stats_port` | `8404` | Cổng Web UI thống kê trạng thái của HAProxy |
| `keepalived_vip` | `192.168.56.110` | Địa chỉ Virtual IP nổi trên cụm 3 node |
| `keepalived_interface` | `enp0s8` | Tên card mạng gắn Virtual IP |
| `keepalived_router_id` | `56` | Virtual Router ID cho giao thức VRRP |
| `keepalived_auth_pass` | `ChKeeP@110` | Mật khẩu xác thực VRRP giữa các node |

### Biến Host trong Inventory (`inventory/clickhouse/devlocal/hosts.yml`):

```yaml
node-db-01:
  ansible_host: 192.168.56.111
  node_ip: 192.168.56.111
  clickhouse_node_id: 1
  clickhouse_shard_id: 1
  clickhouse_replica_name: node-db-01
  keepalived_state: MASTER
  keepalived_priority: 101
```

---

## 3. Cấu trúc Tags trong Playbook

| Tag | Chức năng |
| :--- | :--- |
| `config` | Chỉ tạo các thư mục và render file cấu hình (`keeper.xml`, `cluster.xml`, `haproxy.cfg`, `keepalived.conf`, secrets) |
| `deploy` | Thực thi `docker compose up -d --build --force-recreate` để khởi động/cập nhật container |
| `install_docker` | Cài đặt Docker Engine trên các máy chủ |

---

## 4. Hướng dẫn Chạy Playbook

### Chạy toàn bộ quá trình Bootstrap Cụm:
```bash
cd ansible
ansible-playbook -i inventory/clickhouse/devlocal/hosts.yml playbooks/install-clickhouse-cluster.yml --vault-password-file=.ansible-vault-secret-devlocal
```

### Chỉ cập nhật cấu hình mà không khởi động lại:
```bash
ansible-playbook -i inventory/clickhouse/devlocal/hosts.yml playbooks/install-clickhouse-cluster.yml --tags config --vault-password-file=.ansible-vault-secret-devlocal
```

### Kiểm tra kết nối sau khi triển khai:
- Kiểm tra HAProxy Stats: `http://192.168.56.110:8404/stats`
- Kiểm tra ClickHouse qua VIP Native TCP:
  ```bash
  docker run --rm -it --network host clickhouse/clickhouse-server:26.4 \
      clickhouse-client --host 192.168.56.110 --port 9001 -u dwh_user --password dwh_password \
      --query "SELECT cluster, shard_num, replica_num, host_name, port FROM system.clusters;"
  ```
