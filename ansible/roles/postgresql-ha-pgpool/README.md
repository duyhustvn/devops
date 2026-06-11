# postgresql-ha-pgpool

Ansible role triển khai cụm PostgreSQL HA với Pgpool-II, PgBouncer, watchdog/VIP và online recovery.

## Tài liệu

- [Architecture](docs/Architecture.md): kiến trúc Pgpool-II, PgBouncer, PostgreSQL streaming replication, watchdog và VIP.
- [Pgpool Hooks](docs/Pgpool%20Hooks.md): giải thích chi tiết `failover.sh`, `follow_primary.sh`, `escalation.sh` và Pgpool gọi chúng khi nào.
- [Operations](docs/Operations.md): runbook kiểm tra, failover, recovery và xử lý sự cố.
- [High Availability](docs/High%20Availability.md): hướng dẫn manual setup streaming replication.
- [Change Data Directory](docs/Change%20Data%20Directory.md): đổi data directory PostgreSQL.

## Ghi chú nhanh

Luồng client mặc định:

```text
client -> VIP:9999 -> Pgpool-II -> PgBouncer:6432 -> PostgreSQL:5432
```

Các thao tác replication/admin như `pg_basebackup`, `pg_rewind`, `primary_conninfo`, promote và replication slot luôn đi thẳng PostgreSQL `:{{ pg_port }}`, không đi qua PgBouncer.

## Biến chính

Xem [defaults/main.yml](defaults/main.yml) và bảng biến trong [Architecture](docs/Architecture.md#biến-cấu-hình).

Các biến thường cần override:

- `vip`
- `device_interface`
- `pgpool_conf_trusted_servers`
- `wd_priority` theo từng host
- `pgbouncer_pool_mode`
- `pgbouncer_default_pool_size`
- password trong vault: `postgres_pass`, `pgpool_pass`, `repl_pass`, `pgbouncer_pass`

## Tags hữu ích

```bash
ansible-playbook site.yml --tags preview_pgpool_conf
ansible-playbook site.yml --tags preview_postgresql_conf
ansible-playbook site.yml --tags recover_standby
```
