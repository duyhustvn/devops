# Pgpool hooks — failover, follow primary, escalation

Tài liệu này giải thích các script trong `templates/pgpool2/` mà Pgpool-II gọi tự động trong quá trình vận hành HA:

| Template | File sau khi deploy | Pgpool gọi bởi cấu hình | Khi nào chạy |
|----------|---------------------|--------------------------|--------------|
| `failover.sh.j2` | `/etc/pgpool2/failover.sh` | `failover_command` | Khi health check xác định một backend PostgreSQL bị down và Pgpool quyết định detach/failover node đó |
| `follow_primary.sh.j2` | `/etc/pgpool2/follow_primary.sh` | `follow_primary_command` | Sau khi failover xong, để các standby còn sống bám theo primary mới |
| `escalation.sh.j2` | `/etc/pgpool2/escalation.sh` | `wd_escalation_command` | Khi Pgpool watchdog đưa node hiện tại lên leader và cần đảm bảo VIP không còn nằm trên Pgpool node khác |

Các script này được Ansible render trong `tasks/pgpool2/config_pgpool.yml`, owner là `postgres`. `escalation.sh` chỉ được deploy khi `vip_manager: watchdog`; nếu dùng `vip_manager: keepalived`, Keepalived quản lý VIP nên script này không tham gia luồng chuyển VIP.

## Pgpool dùng script khi nào?

Pgpool có hai nhóm cơ chế độc lập nhưng phối hợp với nhau:

1. **Backend failover PostgreSQL**: Pgpool health check backend định kỳ. Khi backend lỗi đủ ngưỡng, Pgpool detach node và gọi `failover_command`. Nếu node lỗi là primary, script sẽ promote standby được chọn lên primary mới. Sau đó Pgpool gọi `follow_primary_command` để các standby còn lại đồng bộ theo primary mới.
2. **Watchdog leader/VIP failover**: Các tiến trình Pgpool trên nhiều node dùng watchdog heartbeat để bầu leader. Nếu `vip_manager: watchdog`, leader giữ VIP. Khi một Pgpool node trở thành leader mới, watchdog gọi `wd_escalation_command` trước khi add VIP trên node mới.

Vì vậy:

- PostgreSQL primary down → thường chạy `failover.sh`, sau đó `follow_primary.sh`.
- PostgreSQL standby down → chạy `failover.sh` nhưng chỉ drop replication slot của standby lỗi, không promote.
- Pgpool leader down nhưng PostgreSQL primary vẫn sống → chạy luồng watchdog/VIP; có thể chỉ cần `escalation.sh`, không nhất thiết chạy `failover.sh`.
- Node cũ quay lại sau failover primary → không dùng `follow_primary.sh` để rebuild node cũ. Dùng online recovery qua `pcp_recovery_node`, script `recovery_1st_stage` và `pgpool_remote_start`.

## Cấu hình liên quan trong `pgpool.conf`

Role render các hook chính như sau:

```ini
failover_command = '/etc/pgpool2/failover.sh %d %h %p %D %m %H %M %P %r %R %N %S'
follow_primary_command = '/etc/pgpool2/follow_primary.sh  %d %h %p %D %m %H %M %P %r %R'
wd_escalation_command = '/etc/pgpool2/escalation.sh'
```

Các tham số `%` là giá trị runtime do Pgpool truyền vào:

| Tham số | Ý nghĩa |
|---------|---------|
| `%d` | Node id của node bị lỗi hoặc node cần follow |
| `%h` | Hostname/IP của node đó |
| `%p` | Backend port mà Pgpool đang cấu hình cho node đó |
| `%D` | Data directory của node đó |
| `%m` | New main node id |
| `%H` | Hostname/IP của new main/new primary |
| `%M` | Old main node id |
| `%P` | Old primary node id |
| `%r` | Port của new main/new primary |
| `%R` | Data directory của new main/new primary |
| `%N` | Hostname/IP của old primary |
| `%S` | Port của old primary |

Trong role này, khi `pgbouncer_enabled: true`, `%p`, `%r`, `%S` có thể là port PgBouncer (`6432`) vì Pgpool backend trỏ qua PgBouncer. Các script vẫn luôn dùng `PG_PORT={{ pg_port }}` cho thao tác replication/admin trực tiếp PostgreSQL như `pg_ctl promote`, `pg_rewind`, `pg_basebackup`, tạo/drop replication slot và `primary_conninfo`. Đây là điểm quan trọng vì PgBouncer không hỗ trợ PostgreSQL streaming replication protocol.

## `failover.sh.j2`

`failover.sh` là hook xử lý khi Pgpool detach một backend.

Luồng chính:

1. Nhận thông tin failed node, new main node và old primary từ Pgpool.
2. Nếu không còn node nào có thể làm main (`NEW_MAIN_NODE_ID < 0`), script thoát thành công và không làm gì thêm.
3. Kiểm tra passwordless SSH từ user `postgres` tới `NEW_MAIN_NODE_HOST`.
4. Nếu node lỗi là standby, không promote. Script chỉ drop replication slot tương ứng trên old primary rồi thoát.
5. Nếu node lỗi là old primary, script SSH tới standby được chọn và chạy:

```bash
pg_ctl -D <new_main_pgdata> -w promote
```

Sau bước này, PostgreSQL trên standby được chọn trở thành primary mới.

### Khi nào `failover.sh` promote?

Script chỉ promote khi node lỗi chính là old primary:

```bash
if [ $OLD_PRIMARY_NODE_ID != "-1" -a $FAILED_NODE_ID != $OLD_PRIMARY_NODE_ID ]; then
    # standby down, skip promote
fi
```

Nếu standby down, primary hiện tại vẫn còn sống nên không cần failover primary. Việc drop replication slot giúp tránh slot inactive giữ WAL quá lâu trên primary.

### Điều kiện cần

- SSH key `{{ ssh_key_file }}` tồn tại dưới `{{ pg_home_dir }}/.ssh/` và user `postgres` SSH được giữa các node.
- User `postgres` trên node PostgreSQL có quyền chạy `pg_ctl`.
- Pgpool watchdog/quorum phải được cấu hình đúng để tránh nhiều Pgpool node cùng promote nhiều standby.

## `follow_primary.sh.j2`

`follow_primary.sh` chạy sau failover để đưa các standby còn sống bám theo primary mới.

Luồng chính:

1. Nhận thông tin standby cần follow và primary mới.
2. Kiểm tra standby có đang chạy không bằng `pg_isready` qua port PostgreSQL thật (`{{ pg_port }}`).
3. Kiểm tra SSH tới primary mới.
4. Xác định PostgreSQL major version để dùng `myrecovery.conf` + `standby.signal` với PostgreSQL >= 12, hoặc `recovery.conf` với bản cũ.
5. Chạy `checkpoint` trên primary mới.
6. Tạo physical replication slot cho standby trên primary mới.
7. SSH vào standby, stop PostgreSQL, chạy `pg_rewind` từ primary mới, xóa replication slot local cũ trong data directory, ghi lại `primary_conninfo`, `recovery_target_timeline = 'latest'`, `primary_slot_name`, rồi start PostgreSQL.
8. Nếu start thành công, gọi `pcp_attach_node` để attach standby lại vào Pgpool.
9. Nếu thất bại, drop replication slot vừa tạo trên primary mới để tránh giữ WAL.

`follow_primary.sh` dùng `pg_rewind`, không dùng `pg_basebackup`. Vì vậy node standby cần còn data directory hợp lệ và có timeline đủ để rewind. Nếu node bị hỏng nặng hoặc old primary quay lại sau khi đã nhận write trên timeline khác, dùng online recovery/rebuild thay vì attach vội.

## `escalation.sh.j2`

`escalation.sh` là hook của Pgpool watchdog, không phải hook PostgreSQL failover.

Nó chạy khi node Pgpool hiện tại được watchdog nâng lên leader trong chế độ `vip_manager: watchdog`. Mục tiêu là dọn VIP khỏi các Pgpool node khác trước khi leader mới add VIP cho chính nó bằng `if_up_cmd`.

Luồng chính:

1. Lấy danh sách IP Pgpool từ inventory `groups['all']`.
2. Xác định IP hiện tại bằng `hostname -I`.
3. Với từng Pgpool node khác, SSH sang node đó và kiểm tra `ip addr show dev <device>` có VIP không.
4. Nếu có, chạy:

```bash
sudo ip addr del <vip>/<cidr_prefix> dev <device_interface>
```

5. Nếu xóa VIP fail, script log lỗi nhưng vẫn `exit 0`.

`exit 0` ở cuối giúp watchdog tiếp tục quá trình escalation. Nếu script trả lỗi cứng trong lúc node cũ đã chết hoặc SSH timeout, leader mới có thể không lấy được VIP dù bản thân nó là node hợp lệ.

### Khi nào không dùng `escalation.sh`?

Khi `vip_manager: keepalived`, Pgpool watchdog vẫn chạy để bầu leader và phối hợp PostgreSQL failover, nhưng `delegate_ip = ''`; VIP do Keepalived/VRRP quản lý. Khi đó Ansible không deploy `escalation.sh` và không cần sudo rule cho `ip`/`arping` của Pgpool.

## Luồng sự cố thường gặp

### Primary PostgreSQL down

```text
Pgpool health check fail
→ watchdog consensus
→ failover.sh promote standby được chọn
→ Pgpool cập nhật primary mới
→ follow_primary.sh chạy cho standby còn lại
→ standby còn lại pg_rewind và attach lại Pgpool
```

Nếu old primary quay lại sau đó, phải rebuild nó bằng:

```bash
pcp_recovery_node -h 127.0.0.1 -p 9898 -U pgpool -n <old_primary_node_id>
```

### Standby PostgreSQL down

```text
Pgpool health check fail
→ failover.sh nhận failed node là standby
→ drop replication slot của standby đó trên primary
→ không promote
→ node vẫn detached trong Pgpool cho tới khi recovery/auto failback phù hợp
```

### Pgpool leader down

Với `vip_manager: watchdog`:

```text
watchdog heartbeat mất leader
→ bầu leader mới
→ leader mới chạy escalation.sh để gỡ VIP khỏi peer nếu cần
→ Pgpool chạy if_up_cmd add VIP
→ arping cập nhật ARP cache
```

Với `vip_manager: keepalived`:

```text
watchdog bầu leader mới
→ keepalived health check thấy node mới là leader
→ VRRP chuyển VIP sang node đó
```

## Kiểm tra và debug

Các log hook thường nằm trong log Pgpool vì script được Pgpool gọi:

```bash
sudo journalctl -u pgpool2 -n 200 --no-pager
sudo tail -n 200 /var/log/pgpool.log
```

Kiểm tra trạng thái backend:

```bash
PGPASSWORD='<pgpool_pass>' psql -h <vip> -p 9999 -U pgpool -d postgres -c "show pool_nodes"
pcp_node_info -h 127.0.0.1 -p 9898 -U pgpool -n <node_id>
```

Kiểm tra watchdog leader:

```bash
pcp_watchdog_info -h 127.0.0.1 -p 9898 -U pgpool
```

Kiểm tra replication trực tiếp PostgreSQL, bỏ qua Pgpool/PgBouncer:

```bash
PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -c "select application_name, client_addr, state from pg_stat_replication"
PGPASSWORD='<postgres_pass>' psql -h <primary-ip> -p 5432 -U postgres -d postgres -c "select slot_name, active, wal_status from pg_replication_slots"
```

Các lỗi hay gặp:

| Triệu chứng | Nguyên nhân thường gặp | Hướng kiểm tra |
|-------------|------------------------|----------------|
| `passwordless SSH ... failed` | Thiếu key hoặc permission sai dưới home user `postgres` | Kiểm tra `{{ pg_home_dir }}/.ssh/{{ ssh_key_file }}` và thử SSH bằng user `postgres` |
| `pg_rewind` fail | Standby không có WAL/timeline phù hợp, hoặc old primary diverged quá xa | Rebuild bằng online recovery thay vì attach |
| Replication slot inactive giữ WAL | Node standby down lâu hoặc script drop slot fail | Xem `pg_replication_slots`, drop slot thừa sau khi chắc chắn node không còn dùng |
| VIP không chuyển trong watchdog mode | `trusted_servers`, sudo `ip`/`arping`, interface hoặc SSH escalation lỗi | Xem `pcp_watchdog_info`, `ip addr`, `/var/log/pgpool.log` |
| Hook dùng nhầm port PgBouncer | Script tự sửa không dùng `PG_PORT={{ pg_port }}` | Replication/admin phải luôn đi thẳng PostgreSQL `:5432` |

