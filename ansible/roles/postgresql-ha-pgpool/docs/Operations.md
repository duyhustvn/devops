# Runbook vận hành — PostgreSQL + Pgpool-II + PgBouncer

Tài liệu này dùng khi cụm đã được triển khai theo role `postgresql-ha-pgpool` với mô hình:

```text
client -> VIP:9999 -> Pgpool-II -> PgBouncer:6432 -> PostgreSQL:5432
```

Các lệnh PCP nên chạy trên Pgpool leader hoặc node đang giữ VIP. Thay password/IP theo inventory thực tế.

Trong tài liệu này, cụm từ "check replication" gồm ba nhóm lệnh:

- `pg_is_in_recovery()` để xác định primary/standby.
- `pg_stat_replication` và `pg_replication_slots` trên primary.
- `pg_stat_wal_receiver` trên standby.

## Port và user cần nhớ

| Thành phần | Port | User thường dùng | Ghi chú |
|------------|------|------------------|---------|
| Pgpool-II client | `9999` | app user, `pgpool`, `postgres` | Entry point của ứng dụng |
| Pgpool PCP | `9898` | `pgpool` | Quản trị node Pgpool |
| PgBouncer | `6432` | app user, `pgpool`, `postgres` | Backend port của Pgpool khi `pgbouncer_enabled: true` |
| PostgreSQL | `5432` | `postgres`, `repl`, app user | Dùng trực tiếp cho replication/admin |

## Kiểm tra nhanh toàn cụm

### 1. Kiểm tra service trên từng node

```bash
sudo systemctl status postgresql@16-main.service pgbouncer pgpool2 --no-pager
```

Log thường dùng:

```bash
sudo journalctl -u postgresql@16-main.service -n 100 --no-pager
sudo journalctl -u pgbouncer -n 100 --no-pager
sudo journalctl -u pgpool2 -n 100 --no-pager
sudo tail -n 100 /var/log/postgresql/pgbouncer.log
sudo tail -n 100 /var/log/pgpool.log
```

### 2. Kiểm tra readiness bằng pg_isready

`pg_isready` chỉ kiểm tra service có nhận connection hay không; nó không thay thế được kiểm tra role/replication. Exit code thường gặp: `0` accepting, `1` rejecting, `2` no response.

Kiểm tra entrypoint qua VIP/Pgpool:

```bash
pg_isready -h <vip> -p 9999 -U pgpool -d postgres
```

Kiểm tra từng PgBouncer backend mà Pgpool sẽ connect:

```bash
pg_isready -h <backend-ip> -p 6432 -U pgpool -d postgres
```

Kiểm tra PostgreSQL trực tiếp, bỏ qua Pgpool/PgBouncer:

```bash
pg_isready -h <backend-ip> -p 5432 -U postgres -d postgres
```

Nếu `pg_isready` pass nhưng query fail, kiểm tra authentication/password/function/log tương ứng.

### 3. Kiểm tra đường ứng dụng qua Pgpool

```bash
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c 'select 1'
```

Xem Pgpool đang thấy các node như thế nào:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_nodes"
```

Các lệnh `SHOW` hữu ích của Pgpool:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_version"
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_status"
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_nodes"
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_processes"
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_pools"
```

### 4. Kiểm tra trạng thái node qua PCP

```bash
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 0
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 1
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 2
```

Với Pgpool 4.6, các field quan trọng thường đọc như sau:

```text
<host> <port> <status_code> <weight> <pgpool_status> <actual_status> <pgpool_role> <actual_role> ...
```

Ví dụ:

```text
192.168.56.112 6432 3 0.333333 down up standby primary ...
```

Diễn giải:

- `pgpool_status = down`: Pgpool đang detach node này.
- `actual_status = up`: backend thật vẫn reachable.
- `pgpool_role = standby`: role Pgpool đang giữ trong memory/status.
- `actual_role = primary`: PostgreSQL thật đang là primary.

Nếu thấy `down up`, backend có thể đã khỏe nhưng Pgpool vẫn giữ trạng thái detach cũ.

PCP lệnh bổ sung:

```bash
pcp_node_count -h 127.0.0.1 -p 9898 -U pgpool
pcp_pool_status -h 127.0.0.1 -p 9898 -U pgpool
pcp_proc_count -h 127.0.0.1 -p 9898 -U pgpool
pcp_watchdog_info -h 127.0.0.1 -p 9898 -U pgpool
```

### 5. Kiểm tra Pgpool -> PgBouncer -> PostgreSQL

Chạy từ Pgpool node tới từng backend IP:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <backend-ip> -p 6432 -U pgpool -d postgres -c 'select 1'
```

Nếu lệnh này fail, Pgpool health check cũng sẽ fail. Khi đó xem log PgBouncer trên backend IP tương ứng.

### 6. Kiểm tra PostgreSQL role trực tiếp, bỏ qua Pgpool/PgBouncer

```bash
PGPASSWORD='<postgres_pass>' psql -h <backend-ip> -p 5432 -U postgres -d postgres -Atc \
"select inet_server_addr(), pg_is_in_recovery(), case when pg_is_in_recovery() then pg_last_wal_replay_lsn() else pg_current_wal_lsn() end, (pg_control_checkpoint()).timeline_id"
```

Kết quả mẫu:

```text
192.168.56.111|f|0/5F7BD28|1
192.168.56.113|t|0/5F7BD28|1
```

`pg_is_in_recovery() = f` là primary, `t` là standby. Trong trạng thái bình thường chỉ có một primary.

Kiểm tra nhanh cả 3 node:

```bash
for h in <node1-ip> <node2-ip> <node3-ip>; do
  PGPASSWORD='<postgres_pass>' psql -h "$h" -p 5432 -U postgres -d postgres -Atc \
  "select inet_server_addr(), pg_is_in_recovery(), case when pg_is_in_recovery() then pg_last_wal_replay_lsn() else pg_current_wal_lsn() end, (pg_control_checkpoint()).timeline_id"
done
```

### 7. Kiểm tra replication trên primary

Chạy trên primary thật, hoặc connect trực tiếp tới primary IP:

```bash
PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -x -c "
select
  application_name,
  client_addr,
  state,
  sync_state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  pg_wal_lsn_diff(sent_lsn, replay_lsn) as replay_lag_bytes,
  write_lag,
  flush_lag,
  replay_lag
from pg_stat_replication
order by application_name;"
```

Kỳ vọng:

- Mỗi standby đang stream có một dòng.
- `state = streaming`.
- `replay_lag_bytes` không tăng mãi.

Kiểm tra replication slot:

```bash
PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -x -c "
select
  slot_name,
  active,
  active_pid,
  restart_lsn,
  wal_status,
  safe_wal_size
from pg_replication_slots
order by slot_name;"
```

Slot inactive lâu ngày có thể giữ WAL và làm đầy disk.

### 8. Kiểm tra replication trên standby

Chạy trên từng standby:

```bash
PGPASSWORD='<postgres_pass>' psql -h <standby-ip> -p 5432 -U postgres -d postgres -x -c "
select
  pg_is_in_recovery() as is_standby,
  pg_last_wal_receive_lsn() as receive_lsn,
  pg_last_wal_replay_lsn() as replay_lsn,
  pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) as receive_replay_gap_bytes,
  pg_last_xact_replay_timestamp() as last_replay_ts,
  now() - pg_last_xact_replay_timestamp() as replay_delay;"
```

Kiểm tra WAL receiver:

```bash
PGPASSWORD='<postgres_pass>' psql -h <standby-ip> -p 5432 -U postgres -d postgres -x -c "
select
  status,
  receive_start_lsn,
  written_lsn,
  flushed_lsn,
  latest_end_lsn,
  latest_end_time,
  conninfo
from pg_stat_wal_receiver;"
```

Kỳ vọng:

- `pg_is_in_recovery() = true`.
- `pg_stat_wal_receiver.status = streaming`.
- `conninfo` trỏ về primary chuẩn.

### 9. Kiểm tra quyền replication và đường replication

Kiểm tra role `repl` trên primary:

```bash
PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -c "
select rolname, rolreplication, rolcanlogin from pg_roles where rolname = 'repl';"
```

Kiểm tra login user `repl` từ standby hoặc Pgpool node:

```bash
PGPASSWORD='<repl_pass>' psql -h <primary-ip> -p 5432 -U repl -d postgres -c 'select 1'
```

Kiểm tra `.pgpass` của user `postgres` trên từng node:

```bash
sudo -u postgres ls -l /var/lib/postgresql/.pgpass
sudo -u postgres test -r /var/lib/postgresql/.pgpass && echo ok
```

`pg_basebackup`, `pg_rewind`, `primary_conninfo` luôn đi thẳng PostgreSQL `:5432`, không qua PgBouncer.

### 10. Kiểm tra PgBouncer admin/stats

Admin console:

```bash
PGPASSWORD='<postgres_pass>' psql -h <backend-ip> -p 6432 -U postgres -d pgbouncer -c 'show databases'
PGPASSWORD='<postgres_pass>' psql -h <backend-ip> -p 6432 -U postgres -d pgbouncer -c 'show pools'
PGPASSWORD='<postgres_pass>' psql -h <backend-ip> -p 6432 -U postgres -d pgbouncer -c 'show clients'
PGPASSWORD='<postgres_pass>' psql -h <backend-ip> -p 6432 -U postgres -d pgbouncer -c 'show servers'
PGPASSWORD='<postgres_pass>' psql -h <backend-ip> -p 6432 -U postgres -d pgbouncer -c 'show stats'
```

Điểm cần nhìn:

- `show pools`: `cl_waiting` cao nghĩa là client đang chờ pool.
- `show servers`: server connection có đang active/idle không.
- `show databases`: database mapping có đúng `host=127.0.0.1 port=5432` không.

### 11. Kiểm tra watchdog/VIP

Trạng thái watchdog:

```bash
pcp_watchdog_info -h 127.0.0.1 -p 9898 -U pgpool
```

Kiểm tra VIP đang nằm ở node nào:

```bash
ip addr show <device_interface> | grep '<vip>'
```

Nếu dùng keepalived:

```bash
sudo systemctl status keepalived --no-pager
sudo journalctl -u keepalived -n 100 --no-pager
```

Nếu dùng watchdog quản lý VIP, xem log Pgpool quanh thời điểm election/escalation.

## Audit 5 phút khi có cảnh báo

Chạy theo thứ tự này để nhanh chóng biết lỗi nằm ở lớp nào.

1. VIP/Pgpool có nhận connection không:

```bash
pg_isready -h <vip> -p 9999 -U pgpool -d postgres
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c 'select 1'
```

2. Pgpool đang nhìn node ra sao:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_nodes"
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 0
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 1
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 2
```

3. Từng PgBouncer backend có pass không:

```bash
for h in <node1-ip> <node2-ip> <node3-ip>; do
  pg_isready -h "$h" -p 6432 -U pgpool -d postgres
  PGPASSWORD='<pgpool_pass>' psql -h "$h" -p 6432 -U pgpool -d postgres -c 'select 1'
done
```

4. Từng PostgreSQL node là primary hay standby:

```bash
for h in <node1-ip> <node2-ip> <node3-ip>; do
  PGPASSWORD='<postgres_pass>' psql -h "$h" -p 5432 -U postgres -d postgres -Atc \
  "select inet_server_addr(), pg_is_in_recovery(), case when pg_is_in_recovery() then pg_last_wal_replay_lsn() else pg_current_wal_lsn() end, (pg_control_checkpoint()).timeline_id"
done
```

5. Nếu có đúng một primary, kiểm tra stream/slot trên primary:

```bash
PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -c \
"select application_name, client_addr, state, sync_state, sent_lsn, replay_lsn, pg_wal_lsn_diff(sent_lsn, replay_lsn) as lag_bytes from pg_stat_replication"

PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -c \
"select slot_name, active, restart_lsn, wal_status from pg_replication_slots"
```

6. Trên standby bị nghi ngờ, kiểm tra receiver:

```bash
PGPASSWORD='<postgres_pass>' psql -h <standby-ip> -p 5432 -U postgres -d postgres -x -c \
"select status, latest_end_lsn, latest_end_time, conninfo from pg_stat_wal_receiver"
```

Kết luận nhanh:

| Dấu hiệu | Lớp lỗi thường gặp |
|----------|--------------------|
| `pg_isready :9999` fail | Pgpool/VIP/watchdog/keepalived |
| `:9999` fail nhưng `:6432` pass | Pgpool status/PCP/backend detach |
| `:6432` fail nhưng `:5432` pass | PgBouncer config/auth/service |
| `:5432` fail | PostgreSQL/service/network/pg_hba |
| Có hơn một `pg_is_in_recovery() = f` | Split-brain, không attach vội |
| Standby `pg_stat_wal_receiver` rỗng | Standby không stream từ primary |
| Slot inactive lâu | Standby down hoặc đang follow slot khác |

## Bảo trì chủ động một node

### Detach node trước khi bảo trì

Chỉ detach standby cho bảo trì thường lệ. Nếu detach primary, phải có kế hoạch failover rõ ràng.

```bash
pcp_detach_node -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

Sau khi node đã `down` trong Pgpool, dừng service trên node đó:

```bash
sudo systemctl stop pgbouncer
sudo systemctl stop postgresql@16-main.service
```

### Đưa node trở lại

Start theo thứ tự PostgreSQL trước, PgBouncer sau:

```bash
sudo systemctl start postgresql@16-main.service
sudo systemctl start pgbouncer
```

Kiểm tra trước khi attach:

```bash
pg_isready -h <node-ip> -p 5432 -U postgres -d postgres
pg_isready -h <node-ip> -p 6432 -U pgpool -d postgres
PGPASSWORD='<pgpool_pass>' psql -h <node-ip> -p 6432 -U pgpool -d postgres -c 'select 1'
```

Nếu node là standby, kiểm tra nó đang stream:

```bash
PGPASSWORD='<postgres_pass>' psql -h <node-ip> -p 5432 -U postgres -d postgres -x -c \
"select pg_is_in_recovery() as is_standby"

PGPASSWORD='<postgres_pass>' psql -h <node-ip> -p 5432 -U postgres -d postgres -x -c \
"select status, conninfo, latest_end_lsn from pg_stat_wal_receiver"
```

Attach lại:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

### Restart toàn cụm có kiểm soát

Ưu tiên restart từng lớp theo thứ tự:

1. PostgreSQL standby từng node.
2. PgBouncer trên node đó.
3. Pgpool sau cùng nếu cần đổi config Pgpool.

Không restart đồng thời tất cả Pgpool node nếu đang phụ thuộc watchdog/keepalived để giữ VIP.

## Khi Pgpool báo all backend nodes are down

Dấu hiệu:

```text
FATAL: pgpool is not accepting any new connections
DETAIL: all backend nodes are down, pgpool requires at least one valid node
```

Quy trình:

1. Kiểm tra từng backend qua PgBouncer:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <backend-ip> -p 6432 -U pgpool -d postgres -c 'select 1'
```

2. Nếu PgBouncer path pass, xem PCP:

```bash
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

3. Nếu chỉ là Pgpool giữ trạng thái `down` cũ và cluster chỉ có một actual primary, attach primary trước:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <primary_node_id>
```

4. Attach standby sau khi xác nhận standby đang follow đúng primary:

```bash
PGPASSWORD='<postgres_pass>' psql -h <standby-ip> -p 5432 -U postgres -d postgres \
  -c "select status, conninfo, latest_end_lsn from pg_stat_wal_receiver"

pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <standby_node_id>
```

Không attach node có `actual_role = primary` nếu đã có primary khác.

## Attach node thủ công

Chỉ attach khi đã kiểm tra:

- Backend path `psql -p 6432 -U pgpool -d postgres -c 'select 1'` pass.
- Không có split-brain.
- Standby đang follow đúng primary.

Lệnh:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n 0
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n 1
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n 2
```

Sau khi attach:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_nodes"
```

## Online recovery node

Dùng khi một node cần rebuild thành standby từ primary đang hoạt động.

Điều kiện trước khi chạy:

- Pgpool đã có ít nhất một primary hợp lệ ở trạng thái `up`.
- Node cần recover không còn là primary hợp lệ.
- SSH passwordless từ user `postgres` trên primary/Pgpool sang node recover hoạt động.
- `.pgpass` trên các node có password cho user `repl` và `postgres`.
- Nếu `pgbouncer_enabled: true`, PgBouncer trên node recover phải được start/restart sau PostgreSQL.

Lệnh:

```bash
pcp_recovery_node -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

Nếu bị timeout:

```text
ERROR: recovery is checking if postmaster is started
DETAIL: postmaster on hostname:"<host>" database:"template1" user:"postgres" failed to start in 90 second
```

Kiểm tra trên node recover:

```bash
sudo systemctl status postgresql@16-main.service pgbouncer --no-pager
sudo journalctl -u postgresql@16-main.service -n 100 --no-pager
sudo journalctl -u pgbouncer -n 100 --no-pager
```

Nếu PostgreSQL đã `active` nhưng PgBouncer stopped:

```bash
sudo systemctl start pgbouncer
PGPASSWORD='<pgpool_pass>' psql -h <recover-node-ip> -p 6432 -U pgpool -d postgres -c 'select 1'
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

## Split-brain

Dấu hiệu trong `pcp_node_info`:

```text
node 0: ... actual_role primary
node 1: ... actual_role primary
```

Dấu hiệu qua PostgreSQL trực tiếp:

```text
192.168.56.111|f|...|1
192.168.56.112|f|...|2
192.168.56.113|t|...|1
```

Quy trình xử lý:

1. Dừng ngay false primary để tránh ghi tiếp vào timeline sai:

```bash
sudo systemctl stop pgpool2
sudo systemctl stop pgbouncer
sudo systemctl stop postgresql@16-main.service
```

2. Chọn primary chuẩn dựa trên timeline/LSN và standby đang follow nó.

3. Attach primary chuẩn:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <primary_node_id>
```

4. Attach standby đang follow đúng primary:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <standby_node_id>
```

5. Rebuild false primary bằng online recovery:

```bash
pcp_recovery_node -h 127.0.0.1 -p 9898 -U pgpool -n <false_primary_node_id>
```

Không attach cả hai primary. Nếu false primary đã nhận write thật, phải audit dữ liệu trước khi rebuild vì recovery sẽ discard timeline đó.

## Kiểm tra PgBouncer auth

Admin console:

```bash
PGPASSWORD='<postgres_pass>' psql -h <backend-ip> -p 6432 -U postgres -d pgbouncer -c 'show pools'
```

Đường Pgpool health check:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <backend-ip> -p 6432 -U pgpool -d postgres -c 'select 1'
```

Kiểm tra `auth_user` trực tiếp vào PostgreSQL:

```bash
PGPASSWORD='<pgbouncer_pass>' psql -h <backend-ip> -p 5432 -U pgbouncer -d postgres \
  -c "select * from public.pgbouncer_get_auth('pgpool')"
```

Nếu gặp lỗi:

```text
cannot use the reserved "pgbouncer" database as an auth_dbname
```

Kiểm tra `/etc/pgbouncer/pgbouncer.ini` phải có:

```ini
auth_user = pgbouncer
auth_dbname = postgres
auth_query = SELECT usename, passwd FROM public.pgbouncer_get_auth($1)
```

`/etc/pgbouncer/userlist.txt` chỉ cần chứa auth user nội bộ:

```text
"pgbouncer" "<pgbouncer_pass>"
```

## Checklist sau khi sửa sự cố

```bash
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 0
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 1
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 2

PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_nodes"

PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c 'select 1'
```

Trạng thái kỳ vọng:

- Chỉ một node có `actual_role = primary`.
- Các standby có `pg_is_in_recovery() = t`.
- Pgpool status của các node khỏe là `up`.
- PgBouncer path `:6432` pass trên từng backend.
