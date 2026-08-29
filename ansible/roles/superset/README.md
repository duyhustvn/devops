# Ansible Role: Apache Superset (với PostgreSQL & Redis Stack)

Ansible Role tự động triển khai **Apache Superset 6.1.0** kèm hệ thống phụ trợ Metadata Database (PostgreSQL 16) và Caching/Message Broker (Redis 8), tự động cài đặt driver kết nối ClickHouse (`clickhouse-connect`) và khởi tạo tài khoản Admin.

---

## 1. Yêu cầu Hệ thống (Requirements)

- Hệ điều hành: Ubuntu 22.04 LTS (Jammy) / Debian 11/12.
- Docker & Docker Compose plugin đã được cài đặt (Role `docker` đi kèm).
- Quyền root (`become: true`).

---

## 2. Các biến Cấu hình (Role Variables)

### Biến mặc định (`defaults/main.yml`):

| Tên biến | Giá trị mặc định | Mô tả |
| :--- | :--- | :--- |
| `superset_deploy_dir` | `/u01/superset` | Thư mục triển khai trên máy chủ đích |
| `superset_image_base` | `apache/superset:6.1.0` | Base image chính thức của Apache Superset |
| `superset_postgres_image` | `postgres:16` | Image PostgreSQL lưu trữ Metadata |
| `superset_redis_image` | `redis:8` | Image Redis lưu trữ Cache & Celery broker |
| `superset_port` | `8088` | Cổng truy cập Web UI của Superset |
| `superset_postgres_user` | `superset` | Tài khoản kết nối PostgreSQL metadata |
| `superset_postgres_db` | `superset` | Tên database metadata |
| `superset_admin_username` | `admin` | Tên đăng nhập tài khoản quản trị viên |
| `superset_admin_firstname`| `Admin` | Tên người dùng quản trị |
| `superset_admin_lastname` | `User` | Họ người dùng quản trị |
| `superset_admin_email` | `admin@example.com` | Email quản trị viên |
| `superset_row_limit` | `50000` | Giới hạn số dòng tối đa khi chạy SQL Lab |

---

## 3. Cấu trúc Tags trong Playbook

| Tag | Chức năng |
| :--- | :--- |
| `config` | Tạo thư mục, phân quyền `superset_home` (UID 1000), render `superset_config.py`, secrets, `Dockerfile` và `docker-compose.yml` |
| `deploy` | Build custom image Superset (tích hợp `clickhouse-connect`) và khởi động toàn bộ stack |
| `install_docker` | Cài đặt Docker Engine trên máy chủ |

---

## 4. Hướng dẫn Chạy Playbook

### Chạy toàn bộ quá trình Bootstrap Superset:
```bash
cd ansible
ansible-playbook -i inventory/superset/devlocal/hosts.yml playbooks/install-superset.yml --vault-password-file=.ansible-vault-secret-devlocal
```

### Chỉ cập nhật cấu hình `superset_config.py` và secrets:
```bash
ansible-playbook -i inventory/superset/devlocal/hosts.yml playbooks/install-superset.yml --tags config --vault-password-file=.ansible-vault-secret-devlocal
```

---

## 5. Kết nối Superset vào cụm ClickHouse (Qua Keepalived VIP)

1. Mở trình duyệt: `http://192.168.56.111:8088` (hoặc `http://<IP>:8088`).
2. Đăng nhập: `admin` / `admin_password` (theo secret file).
3. Vào **Settings** $\rightarrow$ **Database Connections** $\rightarrow$ **+ Database**.
4. Chọn **ClickHouse Connect** và nhập chuỗi kết nối trỏ tới **VIP:8124**:
   ```text
   clickhousedb://dwh_user:dwh_password@192.168.56.110:8124/analytics
   ```
5. Bấm **Test Connection** $\rightarrow$ **Connect**.
