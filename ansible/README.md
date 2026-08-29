# DevOps Ansible Automation

Hệ thống Ansible Playbooks & Roles phục vụ tự động hóa triển khai hạ tầng Data Warehouse, Database Clusters và Monitoring Stack.

---

## 1. Quản lý Ansible Vault (Secrets Encryption)

- Mã hóa thông tin bảo mật:
```bash
ansible-vault encrypt --vault-password-file=.ansible-vault-secret-devlocal inventory/clickhouse/devlocal/group_vars/all/vault.yml
```

- Xem nội dung đã mã hóa:
```bash
ansible-vault view --vault-password-file=.ansible-vault-secret-devlocal inventory/clickhouse/devlocal/group_vars/all/vault.yml
```

- Giải mã khi cần chỉnh sửa:
```bash
ansible-vault decrypt --vault-password-file=.ansible-vault-secret-devlocal inventory/clickhouse/devlocal/group_vars/all/vault.yml
```

---

## 2. Hướng dẫn Chạy Playbooks

> [!NOTE]
> Xem chi tiết tài liệu về Ansible Tags tại: [Ansible Tags Guide](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_tags.html).

### 2.1. Cụm ClickHouse Cluster 3 Node (với Keeper, HAProxy & Keepalived VIP)
Triển khai toàn bộ cụm ClickHouse phân tán kèm cân bằng tải và Virtual IP (`192.168.56.110`):
```bash
ansible-playbook -i inventory/clickhouse/devlocal/hosts.yml playbooks/install-clickhouse-cluster.yml --vault-password-file=.ansible-vault-secret-devlocal
```
- Chỉ cập nhật cấu hình: `--tags config`
- Chỉ khởi động / cập nhật container: `--tags deploy`

---

### 2.2. Apache Superset Stack (Web UI, PostgreSQL Metadata, Redis)
Triển khai giao diện phân tích dữ liệu Superset trên Node 1:
```bash
ansible-playbook -i inventory/superset/devlocal/hosts.yml playbooks/install-superset.yml --vault-password-file=.ansible-vault-secret-devlocal
```

---

### 2.3. Cụm PostgreSQL Cluster (với Pgpool-II HA)
Triển khai cụm cơ sở dữ liệu PostgreSQL kèm Pgpool:
```bash
ansible-playbook -i inventory/postgresql/devlocal/ubuntu/hosts.yml playbooks/install-postgresql-cluster.yml --vault-password-file=.ansible-vault-secret-devlocal
```
- Chạy tags cụ thể: `--tags config_psql,config_pgpool`
