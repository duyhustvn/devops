# postgresql-ha-pgpool

Ansible role triển khai cụm PostgreSQL HA với Pgpool-II, watchdog/VIP và online recovery.

## Tài liệu

- [Architecture](docs/Architecture.md): kiến trúc Pgpool-II, PostgreSQL streaming replication, watchdog và VIP.
- [Pgpool Hooks](docs/Pgpool%20Hooks.md): giải thích chi tiết `failover.sh`, `follow_primary.sh`, `escalation.sh` và Pgpool gọi chúng khi nào.
- [Operations](docs/Operations.md): runbook kiểm tra, failover, recovery, xử lý sự cố và gỡ cài đặt (uninstall).
- [High Availability](docs/High%20Availability.md): hướng dẫn manual setup streaming replication.
- [Change Data Directory](docs/Change%20Data%20Directory.md): đổi data directory PostgreSQL.

## Ghi chú nhanh

Luồng client mặc định:

```text
client -> VIP:9999 -> Pgpool-II -> PostgreSQL:5432
```

Các thao tác replication/admin như `pg_basebackup`, `pg_rewind`, `primary_conninfo`, promote và replication slot kết nối trực tiếp PostgreSQL `:{{ pg_port }}`.

## Biến chính

Xem [defaults/main.yml](defaults/main.yml) và bảng biến trong [Architecture](docs/Architecture.md#biến-cấu-hình).

Các biến thường cần override:

- `vip`
- `device_interface`
- `pgpool_conf_trusted_servers`
- `wd_priority` theo từng host
- password trong vault: `postgres_pass`, `pgpool_pass`, `repl_pass`

## Tags hữu ích

```bash
ansible-playbook site.yml --tags preview_pgpool_conf
ansible-playbook site.yml --tags preview_postgresql_conf
ansible-playbook site.yml --tags recover_standby
```
