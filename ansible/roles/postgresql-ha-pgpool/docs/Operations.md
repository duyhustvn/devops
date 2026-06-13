# Runbook vận hành — PostgreSQL + Pgpool-II

Tài liệu này dùng khi cụm đã được triển khai theo role `postgresql-ha-pgpool` với mô hình:

```text
client -> VIP:9999 -> Pgpool-II -> PostgreSQL:5432
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
| PostgreSQL | `5432` | `postgres`, `repl`, `pgpool`, app user | Backend của Pgpool và dùng trực tiếp cho replication/admin |

## Kiểm tra nhanh toàn cụm

### 1. Kiểm tra service trên từng node

```bash
sudo systemctl status postgresql@16-main.service pgpool2 --no-pager
```

Log thường dùng:

```bash
sudo journalctl -u postgresql@16-main.service -n 100 --no-pager
sudo journalctl -u pgpool2 -n 100 --no-pager
sudo tail -n 100 /var/log/pgpool.log
```

### 2. Kiểm tra readiness bằng pg_isready

`pg_isready` chỉ kiểm tra service có nhận connection hay không; nó không thay thế được kiểm tra role/replication. Exit code thường gặp: `0` accepting, `1` rejecting, `2` no response.

Kiểm tra entrypoint qua VIP/Pgpool:

```bash
pg_isready -h <vip> -p 9999 -U pgpool -d postgres
```

Kiểm tra từng PostgreSQL backend mà Pgpool sẽ connect:

```bash
pg_isready -h <backend-ip> -p 5432 -U pgpool -d postgres
```

Kiểm tra PostgreSQL trực tiếp bằng admin user:

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
192.168.56.112 5432 3 0.333333 down up standby primary ...
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

### 5. Kiểm tra Pgpool -> PostgreSQL

Chạy từ Pgpool node tới từng backend IP:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <backend-ip> -p 5432 -U pgpool -d postgres -c 'select 1'
```

Nếu lệnh này fail, Pgpool health check cũng sẽ fail. Khi đó xem PostgreSQL service, `pg_hba.conf`, password của user `pgpool` và log PostgreSQL trên backend IP tương ứng.

### 6. Kiểm tra PostgreSQL role trực tiếp, bỏ qua Pgpool

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

`pg_basebackup`, `pg_rewind`, `primary_conninfo` luôn đi thẳng PostgreSQL `:5432`, không qua Pgpool.

### 10. Kiểm tra watchdog/VIP

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

3. Từng PostgreSQL backend mà Pgpool dùng có pass không:

```bash
for h in <node1-ip> <node2-ip> <node3-ip>; do
  pg_isready -h "$h" -p 5432 -U pgpool -d postgres
  PGPASSWORD='<pgpool_pass>' psql -h "$h" -p 5432 -U pgpool -d postgres -c 'select 1'
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
| `:9999` fail nhưng PostgreSQL backend `:5432` pass | Pgpool status/PCP/backend detach |
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
sudo systemctl stop postgresql@16-main.service
```

### Đưa node trở lại

Start PostgreSQL:

```bash
sudo systemctl start postgresql@16-main.service
```

Kiểm tra trước khi attach:

```bash
pg_isready -h <node-ip> -p 5432 -U postgres -d postgres
pg_isready -h <node-ip> -p 5432 -U pgpool -d postgres
PGPASSWORD='<pgpool_pass>' psql -h <node-ip> -p 5432 -U pgpool -d postgres -c 'select 1'
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
2. Pgpool sau cùng nếu cần đổi config Pgpool.

Không restart đồng thời tất cả Pgpool node nếu đang phụ thuộc watchdog/keepalived để giữ VIP.

## Khi Pgpool báo all backend nodes are down

Dấu hiệu:

```text
FATAL: pgpool is not accepting any new connections
DETAIL: all backend nodes are down, pgpool requires at least one valid node
```

Tình huống này có hai khả năng khác nhau:

- PostgreSQL vẫn có một primary thật, nhưng Pgpool đang giữ trạng thái backend `down` cũ.
- Primary thật đã mất; các node còn sống đều là standby, cần chọn standby có dữ liệu mới nhất để promote.

Không attach node vội khi chưa biết role thật của PostgreSQL. Nếu node primary cũ có khả năng tự quay lại, phải stop/fence node đó trước khi promote node khác để tránh split-brain.

### 1. Kiểm tra backend và role thật

Kiểm tra từng PostgreSQL backend bằng user Pgpool dùng cho health check:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <backend-ip> -p 5432 -U pgpool -d postgres -c 'select 1'
```

Nếu PostgreSQL backend path pass, xem PCP:

```bash
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

Sau đó bỏ qua Pgpool và hỏi trực tiếp PostgreSQL từng node:

```bash
for h in <node1-ip> <node2-ip> <node3-ip>; do
  echo "== $h =="
  PGPASSWORD='<postgres_pass>' psql -h "$h" -p 5432 -U postgres -d postgres -Atc \
  "select
     inet_server_addr(),
     pg_is_in_recovery(),
     case
       when pg_is_in_recovery() then pg_last_wal_replay_lsn()
       else pg_current_wal_lsn()
     end as applied_lsn,
     (pg_control_checkpoint()).timeline_id,
     pg_last_wal_receive_lsn(),
     pg_last_wal_replay_lsn(),
     pg_last_xact_replay_timestamp()"
done
```

Nếu cả PostgreSQL service cũng đang stopped, trước hết chặn app/VIP để không có write mới, rồi start từng node đủ để kiểm tra role/LSN trực tiếp. Standby có thể start khi primary cũ không reachable và vẫn cho query read-only; node nào start lên primary phải được kiểm tra split-brain trước khi cho app ghi.

Thứ tự cột:

```text
ip|is_standby|applied_lsn|timeline_id|receive_lsn|replay_lsn|last_replay_ts
```

`pg_is_in_recovery() = f` là primary. `pg_is_in_recovery() = t` là standby. Với standby, dữ liệu đã apply là `pg_last_wal_replay_lsn()`. `pg_last_wal_receive_lsn()` có thể cao hơn nhưng phần đó chưa chắc đã replay xong.

### 2. Chọn node có dữ liệu mới nhất

Nếu có đúng một primary thật (`pg_is_in_recovery() = f`) và không có dấu hiệu split-brain, dùng node đó làm primary chuẩn.

Nếu tất cả node còn sống đều là standby, chọn node để promote theo thứ tự:

1. Chọn `timeline_id` cao nhất.
2. Nếu cùng `timeline_id`, chọn `applied_lsn` cao nhất.
3. Nếu có nhiều primary trên timeline khác nhau hoặc nghi có write trên nhiều timeline, dừng lại để audit dữ liệu; không thể quyết định chỉ bằng LSN.

So sánh LSN bằng PostgreSQL thay vì so chuỗi thủ công:

```sql
select pg_wal_lsn_diff('<candidate_lsn>'::pg_lsn, '<other_lsn>'::pg_lsn);
```

Kết quả dương nghĩa là `<candidate_lsn>` mới hơn. Có thể nhập nhiều candidate để sort:

```sql
with candidates(node_name, timeline_id, applied_lsn) as (
  values
    ('node1', 5, '16/E84DE6F0'::pg_lsn),
    ('node3', 5, '16/E99DFBC8'::pg_lsn)
)
select node_name, timeline_id, applied_lsn
from candidates
order by timeline_id desc, applied_lsn desc;
```

Ví dụ trên chọn `node3` vì cùng timeline `5` nhưng `16/E99DFBC8` lớn hơn `16/E84DE6F0`.

Nếu `receive_lsn` đang lớn hơn `replay_lsn` trên standby được chọn, chờ replay bắt kịp trước khi promote nếu còn có thể:

```bash
PGPASSWORD='<postgres_pass>' psql -h <candidate-ip> -p 5432 -U postgres -d postgres -c \
"select
   pg_last_wal_receive_lsn() as receive_lsn,
   pg_last_wal_replay_lsn() as replay_lsn,
   pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) as receive_replay_gap_bytes"
```

### 3. Khôi phục qua Pgpool

Dùng nhánh này khi vẫn vận hành cụm qua Pgpool/PCP.

Nếu chỉ là Pgpool giữ trạng thái `down` cũ và cluster đã có một actual primary, attach primary trước:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <primary_node_id>
```

Nếu chưa có primary vì tất cả node còn sống đều là standby, promote node đã chọn bằng PostgreSQL trực tiếp:

```bash
PGPASSWORD='<postgres_pass>' psql -h <candidate-ip> -p 5432 -U postgres -d postgres -c \
"select pg_promote(true, 60);"

PGPASSWORD='<postgres_pass>' psql -h <candidate-ip> -p 5432 -U postgres -d postgres -Atc \
"select pg_is_in_recovery(), pg_current_wal_lsn(), (pg_control_checkpoint()).timeline_id"
```

Kỳ vọng `pg_is_in_recovery() = f`. Sau đó attach primary mới vào Pgpool:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <new_primary_node_id>
```

Với các node còn lại, nếu đã xác nhận standby đang follow đúng primary mới thì attach:

```bash
PGPASSWORD='<postgres_pass>' psql -h <standby-ip> -p 5432 -U postgres -d postgres \
  -c "select status, conninfo, latest_end_lsn from pg_stat_wal_receiver"

pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n <standby_node_id>
```

Nếu standby không follow đúng primary mới, hoặc là old primary quay lại sau failover, rebuild bằng online recovery:

```bash
pcp_recovery_node -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

Không attach node có `actual_role = primary` nếu đã có primary khác.

### 4. Khôi phục chỉ bằng PostgreSQL

Dùng nhánh này khi không dùng Pgpool, hoặc muốn biết cách phục hồi bằng PostgreSQL thuần.

Trước tiên đảm bảo app không còn ghi vào node cũ và old primary đã bị stop/fence. Promote node đã chọn:

```bash
PGPASSWORD='<postgres_pass>' psql -h <candidate-ip> -p 5432 -U postgres -d postgres -c \
"select pg_promote(true, 60);"
```

Nếu không connect SQL được nhưng service còn chạy trên candidate, có thể promote local trên chính node đó:

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /u01/data/postgresql/16/main -w promote
```

Kiểm tra primary mới:

```bash
PGPASSWORD='<postgres_pass>' psql -h <new-primary-ip> -p 5432 -U postgres -d postgres -Atc \
"select pg_is_in_recovery(), pg_current_wal_lsn(), (pg_control_checkpoint()).timeline_id"
```

Kỳ vọng dòng đầu là `f|...|...`.

Rebuild từng node còn lại thành standby từ primary mới. Mỗi standby cần một physical replication slot riêng trên primary mới. Slot này là chỗ primary giữ WAL cho đúng standby đó; nếu dùng nhầm slot của node khác hoặc drop slot đang active, standby khỏe có thể bị ảnh hưởng.

`<slot_name>` là tên slot dành cho standby đang được rebuild, không phải tên/IP của primary mới. Quy ước trong role này: slot name lấy theo host/IP của standby cần rebuild, đổi chữ hoa thành chữ thường, đổi dấu chấm và gạch ngang thành gạch dưới. Ví dụ:

| Standby cần rebuild | Slot name |
|---------------------|-----------|
| `192.168.56.112` | `192_168_56_112` |
| `node-db-03` | `node_db_03` |

Có thể tự tính nhanh:

```bash
standby_host='<standby-ip-or-hostname>'
slot_name=$(printf '%s' "$standby_host" | tr '[:upper:]' '[:lower:]' | tr '.-' '__')
echo "$slot_name"
```

Trước khi chạy `pg_basebackup`, kiểm tra slot trên primary mới:

```bash
PGPASSWORD='<postgres_pass>' psql -h <new-primary-ip> -p 5432 -U postgres -d postgres -x -c "
select
  s.slot_name,
  s.slot_type,
  s.active,
  s.active_pid,
  r.client_addr,
  r.application_name,
  s.restart_lsn,
  s.wal_status
from pg_replication_slots s
left join pg_stat_replication r on r.pid = s.active_pid
where s.slot_type = 'physical'
order by s.slot_name;"
```

Xử lý theo kết quả:

- Không có `<slot_name>`: dùng `pg_basebackup -C -S <slot_name>` để tạo slot mới.
- Có `<slot_name>` và `active = f`: nếu đây là slot stale của chính standby đang rebuild, drop rồi tạo lại sạch bằng `pg_basebackup -C -S <slot_name>`.
- Có `<slot_name>` và `active = t`: không drop. Dừng standby đang dùng slot đó trước, hoặc kiểm tra lại vì có thể bạn đang chọn nhầm slot của node khác.

Drop slot stale chỉ sau khi đã chắc chắn standby cũ không còn dùng slot đó:

```bash
PGPASSWORD='<postgres_pass>' psql -h <new-primary-ip> -p 5432 -U postgres -d postgres -c \
"select pg_drop_replication_slot('<slot_name>');"
```

Sau đó giữ lại data directory cũ bằng `mv`, rồi chạy `pg_basebackup` mới:

```bash
sudo systemctl stop postgresql@16-main.service

sudo -u postgres mv /u01/data/postgresql/16/main /u01/data/postgresql/16/main.bak.$(date +%Y%m%d%H%M%S)

sudo -u postgres env PGPASSWORD='<repl_pass>' /usr/lib/postgresql/16/bin/pg_basebackup \
  -h <new-primary-ip> \
  -p 5432 \
  -U repl \
  -D /u01/data/postgresql/16/main \
  -X stream \
  -R \
  -C \
  -S <slot_name>

sudo systemctl start postgresql@16-main.service
```

Nếu muốn giữ lại slot inactive đang có thay vì drop/recreate, bỏ `-C` và dùng `-S <slot_name>`. Với rebuild full sau sự cố, drop slot stale rồi tạo lại thường dễ kiểm soát hơn.

Kiểm tra standby:

```bash
PGPASSWORD='<postgres_pass>' psql -h <standby-ip> -p 5432 -U postgres -d postgres -Atc \
"select pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()"

PGPASSWORD='<postgres_pass>' psql -h <standby-ip> -p 5432 -U postgres -d postgres -x -c \
"select status, conninfo, latest_end_lsn from pg_stat_wal_receiver"
```

Kiểm tra trên primary mới:

```bash
PGPASSWORD='<postgres_pass>' psql -h <new-primary-ip> -p 5432 -U postgres -d postgres -c \
"select application_name, client_addr, state, sent_lsn, replay_lsn from pg_stat_replication"
```

Nếu vẫn có Pgpool sau khi promote bằng PostgreSQL, phải đồng bộ lại trạng thái Pgpool. `show pool_nodes` và `pcp_node_info` có hai lớp thông tin:

- `pgpool_status`/`status`: trạng thái Pgpool đang giữ trong memory/status file.
- `actual_status` và `actual_role`/`pg_role`: trạng thái thật Pgpool kiểm tra được từ PostgreSQL.

Vì vậy sau khi promote/rebuild thủ công bằng PostgreSQL, có thể PostgreSQL đã đúng nhưng Pgpool vẫn để node `down`. Trường hợp mong muốn với node 2 là primary mới:

```text
node 2: pgpool_status up, actual_status up, pgpool_role primary, actual_role primary
node 0: pgpool_status up, actual_status up, pgpool_role standby, actual_role standby
node 1: pgpool_status up, actual_status up, pgpool_role standby, actual_role standby
```

Trước khi attach vào Pgpool, kiểm tra trực tiếp từ Pgpool node tới từng backend:

```bash
for h in <node0-ip> <node1-ip> <node2-ip>; do
  echo "== $h =="
  PGPASSWORD='<pgpool_pass>' psql -h "$h" -p 5432 -U pgpool -d postgres -c 'select 1'
  PGPASSWORD='<postgres_pass>' psql -h "$h" -p 5432 -U postgres -d postgres -Atc \
  "select inet_server_addr(), pg_is_in_recovery(), case when pg_is_in_recovery() then pg_last_wal_replay_lsn() else pg_current_wal_lsn() end"
done
```

Trên node 0 và node 1, xác nhận chúng đang stream từ node 2:

```bash
PGPASSWORD='<postgres_pass>' psql -h <node0-ip> -p 5432 -U postgres -d postgres -x -c \
"select status, conninfo, latest_end_lsn from pg_stat_wal_receiver"

PGPASSWORD='<postgres_pass>' psql -h <node1-ip> -p 5432 -U postgres -d postgres -x -c \
"select status, conninfo, latest_end_lsn from pg_stat_wal_receiver"
```

Sau đó attach theo thứ tự primary mới trước, standby sau:

```bash
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n 2
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n 0
pcp_attach_node -h 127.0.0.1 -p 9898 -U pgpool -n 1
```

Kiểm tra lại:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_nodes"

pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 0
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 1
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n 2
```

Nếu `pcp_node_info` vẫn báo `actual_status = down` hoặc `unknown`, không attach được bằng PCP. Khi đó sửa lỗi kết nối/auth trước: PostgreSQL service, network, `pg_hba.conf`, password user `pgpool`, hoặc log Pgpool/PostgreSQL. Nếu `actual_status = up` nhưng `pgpool_status = down`, `pcp_attach_node` là thao tác đúng.

Nếu muốn dùng `pg_rewind` thay vì `pg_basebackup`, chỉ làm khi data directory còn nguyên, server target đã stop sạch, và chắc chắn timeline có thể rewind. Với sự cố nặng hoặc không chắc lịch sử WAL, `pg_basebackup` an toàn hơn.

## Attach node thủ công

Chỉ attach khi đã kiểm tra:

- Backend path `psql -p 5432 -U pgpool -d postgres -c 'select 1'` pass.
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
sudo systemctl status postgresql@16-main.service --no-pager
sudo journalctl -u postgresql@16-main.service -n 100 --no-pager
```

Nếu PostgreSQL đã `active` nhưng Pgpool chưa attach node:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <recover-node-ip> -p 5432 -U pgpool -d postgres -c 'select 1'
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
sudo systemctl stop postgresql@16-main.service
```

2. Chọn primary chuẩn dựa trên timeline/LSN và standby đang follow nó. Dùng cùng quy tắc ở mục "Chọn node có dữ liệu mới nhất".

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

## Nếu service báo `too many open files`

Kiểm tra giới hạn file descriptor thực tế mà systemd đang áp cho từng service:

```bash
sudo systemctl show pgpool2 -p LimitNOFILE
sudo systemctl show postgresql@16-main.service -p LimitNOFILE
```

Kiểm tra số connection thực tế trên PostgreSQL:

```bash
PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -c \
"select count(*) as total_connections from pg_stat_activity"

PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -c \
"show max_connections"
```

Nếu tăng `pg_conf_max_connection` hoặc service limit, chạy lại:

```bash
ansible-playbook <playbook.yml> --tags config_psql,config_pgpool
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
- PostgreSQL backend path `:5432` pass trên từng backend.
