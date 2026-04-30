# Kiến trúc High Availability — PostgreSQL + pgpool-II

## Tổng quan

Cụm bao gồm 3 node chạy song song PostgreSQL và pgpool-II trên cùng máy. pgpool-II đóng vai trò proxy và load balancer, đồng thời điều phối tự động failover khi node PostgreSQL primary bị sự cố.

```
                        ┌─────────────────┐
         Ứng dụng  ───► │   Virtual IP    │
                        │  (VIP / VRRP)   │
                        └────────┬────────┘
                                 │
                    pgpool leader nhận request
                                 │
          ┌──────────────────────┼──────────────────────┐
          │                      │                      │
 ┌────────▼────────┐   ┌────────▼────────┐   ┌────────▼────────┐
 │    node-db-01   │   │    node-db-02   │   │    node-db-03   │
 │                 │   │                 │   │                 │
 │  pgpool-II      │   │  pgpool-II      │   │  pgpool-II      │
 │  (watchdog)     │◄──►  (watchdog)     │◄──►  (watchdog)     │
 │                 │   │                 │   │                 │
 │  PostgreSQL     │   │  PostgreSQL     │   │  PostgreSQL     │
 │  PRIMARY        │──►│  STANDBY        │──►│  STANDBY        │
 └─────────────────┘   └─────────────────┘   └─────────────────┘
   streaming replication ────────────────────────────────────►
```

---

## Thành phần

### PostgreSQL Streaming Replication

- **Primary**: nhận tất cả write từ ứng dụng thông qua pgpool.
- **Standby**: nhận WAL liên tục từ primary qua replication slot, sẵn sàng phục vụ read và tiếp nhận quyền primary khi cần.
- Khi primary down, `failover.sh` do pgpool gọi sẽ chạy `pg_ctl promote` trên standby được chọn.
- Sau failover, `follow_primary.sh` được gọi để các standby còn lại đồng bộ theo primary mới.

### pgpool-II

Mỗi node chạy một tiến trình pgpool-II độc lập với các chức năng:

| Chức năng | Mô tả |
|-----------|-------|
| Connection pooling | Giảm overhead tạo kết nối đến PostgreSQL |
| Load balancing | Phân phối query SELECT sang các standby |
| Health check | Kiểm tra định kỳ PostgreSQL còn sống không |
| Failover | Trigger `failover.sh` khi phát hiện primary down |
| Online recovery | Tự động khôi phục standby bằng `recovery_1st_stage` |

### pgpool Watchdog

Watchdog là cơ chế cluster giữa các node pgpool-II. Nó phụ trách:

1. **Bầu leader**: Dùng heartbeat UDP giữa các node để bầu ra một node làm leader.
2. **Phối hợp failover**: Khi một pgpool phát hiện PostgreSQL primary down, nó hỏi các node khác trước khi chạy `failover.sh`. Điều này đảm bảo chỉ một lệnh promote duy nhất được thực thi, tránh tình trạng nhiều standby cùng được promote.
3. **Quorum**: Failover chỉ xảy ra khi đa số node đồng ý (`failover_require_consensus = on`).

> Watchdog không thể bị thay thế hoàn toàn bởi keepalived vì keepalived không có cơ chế phối hợp failover PostgreSQL.

---

## Hai chế độ quản lý VIP

Ansible role này hỗ trợ hai cách quản lý VIP, kiểm soát bởi biến `vip_manager`.

---

### Chế độ 1: Watchdog quản lý VIP (`vip_manager: watchdog`)

**Mặc định.** Toàn bộ do pgpool-II watchdog xử lý: bầu leader, giữ VIP, và phối hợp failover.

```
┌─────────────────────────────────────────────────┐
│              pgpool-II Watchdog                 │
│                                                 │
│  ┌──────────────────────────────────────────┐   │
│  │  Heartbeat (UDP :9694) giữa 3 node       │   │
│  │  Leader election → node thắng giữ VIP    │   │
│  │  Khi leader mới elected:                 │   │
│  │    1. escalation.sh xóa VIP khỏi node cũ │   │
│  │    2. ip addr add VIP trên node mới       │   │
│  │    3. arping cập nhật ARP cache           │   │
│  └──────────────────────────────────────────┘   │
│                                                 │
│  + Phối hợp failover PostgreSQL (consensus)     │
└─────────────────────────────────────────────────┘
```

**Luồng khi leader down:**

```
node-db-01 (leader, giữ VIP) ── bị down

→ node-db-02 và node-db-03 không nhận heartbeat từ node-01 trong wd_heartbeat_deadtime giây
→ Watchdog bầu lại: node-db-02 thắng (wd_priority cao hơn)
→ node-db-02 chạy escalation.sh: SSH sang node-01 xóa VIP (nếu node-01 vẫn sống)
→ node-db-02 chạy: ip addr add <VIP> dev eth0
→ node-db-02 chạy: arping -U <VIP>   (cập nhật ARP trên switch/router)
→ Traffic chuyển sang node-db-02
```

**Cấu hình inventory:**

```yaml
# group_vars/all.yml
vip_manager: watchdog
vip: 192.168.1.100
device_interface: eth0
cidr_prefix: 24
trusted_servers: '192.168.1.1'   # gateway — bắt buộc, tránh mất VIP do false positive

# Đặt wd_priority per-host để chỉ định node ưu tiên làm leader
# host_vars/node-db-01.yml
wd_priority: 2

# host_vars/node-db-02.yml
wd_priority: 1

# host_vars/node-db-03.yml
wd_priority: 0
```

**Ưu điểm:**
- Đơn giản, một công cụ quản lý tất cả.
- Theo đúng hướng dẫn chính thức của pgpool-II.

**Nhược điểm:**
- Dễ mất VIP nếu không cấu hình `trusted_servers` và `wd_escalation_command`.
- VIP chuyển chậm hơn (~`wd_heartbeat_deadtime` giây, mặc định 30s).

---

### Chế độ 2: Keepalived quản lý VIP (`vip_manager: keepalived`)

Watchdog vẫn bật hoàn toàn để phối hợp failover PostgreSQL, nhưng **không giữ VIP** (`delegate_ip = ''`). Keepalived đảm nhận VIP qua VRRP và hỏi watchdog để biết node nào đang là leader.

```
┌───────────────────────────────────────────────────────────────┐
│                      Keepalived (VRRP)                        │
│                                                               │
│  Mỗi node chạy health check mỗi 2 giây:                      │
│    pcp_watchdog_info → "leader" hay không?                    │
│                                                               │
│  Node là watchdog leader → priority 100 → giữ VIP            │
│  Node không phải leader  → priority  50 → nhường VIP         │
│                                                               │
│  VRRP unicast giữa 3 node (không cần multicast)              │
└───────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────┐
│                   pgpool-II Watchdog                          │
│                                                               │
│  Vẫn chạy đầy đủ: heartbeat, leader election, quorum         │
│  Phối hợp failover PostgreSQL như bình thường                 │
│  KHÔNG quản lý VIP (delegate_ip = '')                        │
└───────────────────────────────────────────────────────────────┘
```

**Luồng khi leader down:**

```
node-db-01 (watchdog leader, keepalived giữ VIP) ── bị down

─── pgpool watchdog ───────────────────────────────────────────
→ node-db-02 và node-db-03 mất heartbeat từ node-01
→ Bầu lại: node-db-02 thành watchdog leader mới

─── keepalived ────────────────────────────────────────────────
→ node-db-02: health check → pcp_watchdog_info trả về "leader"
   priority: 100 (base) + 0 (weight) = 100
→ node-db-03: health check → pcp_watchdog_info trả về "standby"
   priority: 100 - 50 (weight) = 50
→ VRRP: node-db-02 thắng → lấy VIP
→ arping gửi gratuitous ARP cập nhật switch/router

─── Thời gian chuyển VIP: ~4 giây (2 lần check × interval 2s)
```

**Cấu hình inventory:**

```yaml
# group_vars/all.yml
vip_manager: keepalived
vip: 192.168.1.100
device_interface: eth0
cidr_prefix: 24

keepalived_virtual_router_id: 51      # phải unique trong subnet
keepalived_auth_pass: your_secret     # đổi thành password thực
keepalived_priority: 100              # base priority như nhau cho tất cả node
keepalived_check_interval: 2          # giây

# trusted_servers vẫn nên đặt để watchdog hoạt động ổn định
trusted_servers: '192.168.1.1'
```

**Ưu điểm:**
- VIP chuyển nhanh hơn (~4s so với ~30s của watchdog thuần).
- VRRP là giao thức chuẩn, ổn định, không phụ thuộc vào cơ chế arping tự xây dựng.
- Không cần `escalation.sh` — tránh các lỗi SSH timeout gây mất VIP.

**Nhược điểm:**
- Phức tạp hơn: cần cài thêm keepalived trên 3 node.
- Cần đảm bảo `pcp_watchdog_info` phản hồi kịp thời để health check hoạt động chính xác.

---

## So sánh hai chế độ

| Tiêu chí | `watchdog` | `keepalived` |
|----------|------------|--------------|
| Số công cụ cần quản lý | 1 (pgpool) | 2 (pgpool + keepalived) |
| Thời gian chuyển VIP | ~30s (wd_heartbeat_deadtime) | ~4s |
| Độ phức tạp cấu hình | Thấp | Trung bình |
| Giao thức VIP | ip + arping (tự xây) | VRRP chuẩn |
| Phối hợp failover PostgreSQL | pgpool watchdog | pgpool watchdog |
| Yêu cầu `trusted_servers` | Bắt buộc để ổn định | Khuyến nghị |
| Yêu cầu `escalation.sh` | Bắt buộc | Không cần |
| Phù hợp khi | Muốn đơn giản, theo hướng dẫn pgpool | Cần VIP chuyển nhanh và ổn định hơn |

---

## Biến cấu hình

### Biến chung (cả hai chế độ)

| Biến | Mặc định | Mô tả |
|------|----------|-------|
| `vip_manager` | `watchdog` | Chế độ quản lý VIP: `watchdog` hoặc `keepalived` |
| `vip` | — | Virtual IP address (bắt buộc) |
| `device_interface` | — | Network interface (vd: `eth0`, `ens3`) |
| `cidr_prefix` | `24` | Prefix length của VIP |
| `trusted_servers` | `''` | Upstream server để watchdog xác nhận mạng còn thông (gateway hoặc DNS). Để trống dễ gây mất VIP |
| `wd_priority` | `1` | Priority trong bầu chọn watchdog leader. Override per-host để chỉ định node ưu tiên |

### Biến riêng cho `vip_manager: watchdog`

| Biến | Mặc định | Mô tả |
|------|----------|-------|
| `ssh_timeout` | `15` | Timeout SSH trong `escalation.sh` khi xóa VIP node cũ |
| `arping_path` | `/usr/bin` | Đường dẫn đến `arping` |
| `if_cmd_path` | `/sbin` | Đường dẫn đến `ip` command |

### Biến riêng cho `vip_manager: keepalived`

| Biến | Mặc định | Mô tả |
|------|----------|-------|
| `keepalived_virtual_router_id` | `51` | VRRP router ID, phải unique trong subnet |
| `keepalived_auth_pass` | `pgpool_ha` | Password xác thực VRRP giữa các node |
| `keepalived_priority` | `100` | Base priority. Health check weight -50 sẽ hạ non-leader xuống |
| `keepalived_check_interval` | `2` | Tần suất (giây) keepalived gọi health check script |
| `keepalived_advert_int` | `1` | Tần suất (giây) gửi VRRP advertisement |
| `keepalived_check_script_path` | `/etc/keepalived/check_pgpool_leader.sh` | Đường dẫn health check script |
| `pgpool_pcp_port` | `9898` | PCP port để health check query watchdog status |
| `pgpool_pcp_user` | `pgpool` | PCP user |

---

## Lưu ý vận hành

### Kiểm tra trạng thái watchdog

```bash
# Xem node nào đang là leader và trạng thái cluster
pcp_watchdog_info -h 127.0.0.1 -p 9898 -U pgpool

# Xem trạng thái tất cả backend PostgreSQL
psql -h <VIP> -p 9999 -U pgpool -c "SHOW pool_nodes"
```

### Kiểm tra trạng thái keepalived (chế độ keepalived)

```bash
# Xem node nào đang giữ VIP
ip addr show dev eth0 | grep <VIP>

# Xem log keepalived
journalctl -u keepalived -f
```

### Sau khi node phục hồi

Khi một node down rồi phục hồi, pgpool sẽ không tự động đưa PostgreSQL của node đó vào cluster. Cần chạy online recovery:

```bash
# Từ node-db-01 (hoặc node đang là pgpool leader)
pcp_recovery_node -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

Hoặc chạy lại Ansible tag `recover_standby`:

```bash
ansible-playbook site.yml --tags recover_standby
```
