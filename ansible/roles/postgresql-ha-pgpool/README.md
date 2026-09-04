# postgresql-ha-pgpool

Ansible role triển khai cụm PostgreSQL HA với Pgpool-II, watchdog/VIP và online recovery.

## Tài liệu

- [Architecture](docs/Architecture.md): kiến trúc Pgpool-II, PostgreSQL streaming replication, watchdog và VIP.
- [Pgpool Hooks](docs/Pgpool%20Hooks.md): giải thích chi tiết `failover.sh`, `follow_primary.sh`, `escalation.sh` và Pgpool gọi chúng khi nào.
- [Change Data Directory](docs/Change%20Data%20Directory.md): đổi data directory PostgreSQL.
- [Storage and Cleanup](docs/Storage%20and%20Cleanup.md): hướng dẫn kiểm tra dung lượng và dọn dẹp dữ liệu (vacuum, reclaim space, xử lý đầy pg_wal).

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
- password trong vault: `postgres_pass`, `pgpool_pass`, `repl_pass`, `{user}_pass`
- `pg_allowed_ips`: danh sách dải IP được phép kết nối
- `pg_allowed_user_db`: danh sách database, user và quyền truy cập

## Quản lý User & Database (Day-2)

Khi cần thêm database, user hoặc phân quyền mới:
1. Thêm cấu hình vào `group_vars/all/vars.yml` trong `pg_allowed_user_db`.
2. Khai báo mật khẩu `{user}_pass` trong `group_vars/all/vault.yml`.
3. Chạy playbook quản trị chuyên dụng (chạy nhanh, an toàn, không restart cụm):
   ```bash
   ansible-playbook -i inventory/postgresql/devlocal/hosts.yml playbooks/manage-postgresql-users.yml --vault-password-file=.vault_pass
   ```

## Tags hữu ích

```bash
ansible-playbook site.yml --tags preview_pgpool_conf
ansible-playbook site.yml --tags preview_postgresql_conf
ansible-playbook site.yml --tags manage_users
ansible-playbook site.yml --tags recover_standby
```
