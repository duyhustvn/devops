# Hướng Dẫn Vận Hành: Kiểm Tra Dung Lượng & Dọn Dẹp Dữ Liệu PostgreSQL

Tài liệu này cung cấp hướng dẫn chi tiết dành cho Sysadmin / DevOps / DBA trong việc giám sát dung lượng đĩa, phát hiện các đối tượng chiếm nhiều dung lượng (bloat), và các phương pháp dọn dẹp dữ liệu (vacuum, reindex, cleanup WAL) an toàn trên cụm PostgreSQL HA.

---

## 1. Kiểm Tra Dung Lượng (Storage Monitoring)

### 1.1. Tầng Hệ Điều Hành (OS Level)

Kiểm tra phân vùng đĩa và dung lượng thực tế của PostgreSQL Data Directory (mặc định tại `/u01/data/postgresql/16/main` hoặc `/var/lib/postgresql/16/main`):

```bash
# 1. Kiểm tra dung lượng phân vùng chứa database
df -hT /u01

# 2. Kiểm tra tổng dung lượng thư mục PGDATA
sudo du -sh /u01/data/postgresql/16/main

# 3. Phân tích chi tiết dung lượng các thư mục con quan trọng trong PGDATA
sudo du -h --max-depth=1 /u01/data/postgresql/16/main | sort -hr
```

**Các thư mục cần đặc biệt chú ý:**
- `base/`: Chứa dữ liệu của các database, bảng (tables) và chỉ mục (indexes). Chiếm phần lớn dung lượng.
- `pg_wal/`: Chứa các file Write-Ahead Log (WAL). Nếu thư mục này phình to bất thường (vài chục GB đến đầy đĩa), thường do replication slot bị treo hoặc archive bị lỗi.
- `pgsql_tmp/`: Chứa các file tạm được sinh ra khi thực thi các câu query lớn vượt quá `work_mem` (sort, hash table). Các file này sẽ tự xóa khi query kết thúc, nhưng nếu query bị treo, thư mục này có thể tăng đột biến.
- `global/`: Chứa các bảng catalog dùng chung toàn cluster (như `pg_database`, `pg_authid`).

---

### 1.2. Tầng Cơ Sở Dữ Liệu (PostgreSQL SQL Level)

Đăng nhập vào PostgreSQL (`sudo -u postgres psql`):

#### A. Kiểm tra dung lượng từng Database
```sql
SELECT 
    datname AS database_name,
    pg_size_pretty(pg_database_size(datname)) AS total_size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
```

#### B. Kiểm tra Top 15 Bảng lớn nhất (kèm Index và TOAST)
```sql
-- Kết nối vào database cần kiểm tra: \c <dbname>
SELECT 
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    pg_size_pretty(pg_indexes_size(relid)) AS index_size,
    pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid) - pg_indexes_size(relid)) AS toast_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;
```

#### C. Kiểm tra dung lượng các Index lớn nhất
```sql
SELECT 
    schemaname || '.' || relname AS table_name,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 15;
```

#### D. Kiểm tra rác (Dead Tuples / Bloat) trên các bảng
Trong cơ chế MVCC của PostgreSQL, khi thực hiện `UPDATE` hoặc `DELETE`, row cũ không bị xóa ngay mà trở thành **dead tuple**:

```sql
SELECT 
    schemaname || '.' || relname AS table_name,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    ROUND(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_ratio_percent,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;
```
> [!NOTE]
> Nếu `dead_ratio_percent` cao (> 20-30%) và `n_dead_tup` lớn, bảng đang bị bloat nhiều, cần thực hiện vacuum hoặc tinh chỉnh autovacuum.

---

## 2. Các Phương Pháp Dọn Dẹp Dữ Liệu (Data Cleanup & Space Reclamation)

### 2.1. Sử dụng `VACUUM` thường (Online Cleanup)

- **Mục đích:** Quét qua bảng, đánh dấu các dead tuples để tái sử dụng không gian cho các row `INSERT`/`UPDATE` mới.
- **Tác động:** Không khóa bảng (SELECT, INSERT, UPDATE, DELETE vẫn chạy bình thường).
- **Thu hồi đĩa về OS:** **KHÔNG** trả lại dung lượng về OS (trừ khi các page ở cuối file hoàn toàn trống).

```sql
-- Chạy vacuum trên một bảng cụ thể kèm phân tích thống kê:
VACUUM (VERBOSE, ANALYZE) schema_name.table_name;

-- Chạy vacuum trên toàn bộ database hiện tại:
VACUUM VERBOSE ANALYZE;
```

---

### 2.2. Sử dụng `VACUUM FULL` (Thu hồi đĩa về OS)

- **Mục đích:** Tạo lại toàn bộ bảng sang một file mới, loại bỏ hoàn toàn bloat và trả lại 100% dung lượng trống về cho hệ điều hành.
- **Tác động:** Chiếm khóa **`ACCESS EXCLUSIVE`** trên bảng. Mọi truy vấn đọc/ghi (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) đều bị chặn cho đến khi hoàn tất.

> [!CAUTION]
> 1. **Dung lượng đĩa dự phòng:** `VACUUM FULL` cần dung lượng đĩa trống tối thiểu bằng kích thước hiện tại của bảng (vì nó ghi file mới song song trước khi xóa file cũ). Nếu phân vùng đĩa đã đầy 100%, `VACUUM FULL` sẽ thất bại!
> 2. **Thời gian dừng truy vấn:** Không bao giờ chạy `VACUUM FULL` trên bảng lớn trong giờ cao điểm sản xuất vì sẽ gây treo ứng dụng.

```sql
-- Cú pháp chạy trên 1 bảng:
VACUUM (FULL, VERBOSE, ANALYZE) schema_name.table_name;
```

> [!TIP]
> **Giải pháp thay thế không khóa bảng (Zero-downtime):**  
> Trong môi trường Production 24/7, khuyến nghị cài đặt extension **`pg_repack`**. `pg_repack` cho phép compact và thu hồi đĩa về OS mà không cần khóa ghi bảng:
> ```bash
> # Cài đặt qua apt:
> sudo apt-get install -y postgresql-16-repack
> 
> # Chạy repack:
> pg_repack -h 127.0.0.1 -p 5432 -U postgres -d <dbname> --table <schema.table>
> ```

---

### 2.3. Dọn dẹp và Thu hồi dung lượng Index (Reindex)

Sau thời gian dài ghi/sửa dữ liệu, B-Tree index cũng bị bloat tương tự như bảng. Bạn có thể rebuild lại index mà **không làm khóa truy vấn ghi**:

```sql
-- Rebuild toàn bộ index của bảng mà không khóa ghi:
REINDEX TABLE CONCURRENTLY schema_name.table_name;

-- Hoặc rebuild một index cụ thể:
REINDEX INDEX CONCURRENTLY schema_name.index_name;
```

---

### 2.4. Xóa dữ liệu lớn bằng `TRUNCATE` và Xóa theo lô (`Batch DELETE`)

#### Khi cần xóa toàn bộ bảng dữ liệu log / temp:
Dùng `TRUNCATE` thay vì `DELETE`:
```sql
TRUNCATE TABLE schema_name.log_table RESTART IDENTITY;
```
*Đặc điểm:* Nhanh tức thì, giải phóng đĩa về OS ngay lập tức.

#### Khi cần xóa dữ liệu cũ (Data Retention / Purge data định kỳ):
> [!WARNING]
> Tuyệt đối tránh chạy: `DELETE FROM large_table WHERE created_at < NOW() - INTERVAL '90 days';` nếu số lượng dòng cần xóa lên tới hàng triệu dòng.  
> Việc này sẽ:
> - Giữ long-running transaction và table lock.
> - Tạo ra bão WAL khổng lồ, khiến các Standby replica bị replication lag nghiêm trọng.
> - Làm phình dead tuples khiến bảng chạy chậm ngay sau đó.

**Giải pháp:** Xóa theo từng lô nhỏ (Batch Delete) và commit từng lần:

```sql
DO $$
DECLARE
    rows_deleted INT;
    batch_size INT := 5000; -- Số lượng dòng mỗi đợt
BEGIN
    LOOP
        -- Xóa theo lô thông qua ctid
        WITH deleted AS (
            SELECT ctid FROM schema_name.large_table
            WHERE created_at < NOW() - INTERVAL '90 days'
            LIMIT batch_size
        )
        DELETE FROM schema_name.large_table
        WHERE ctid IN (SELECT ctid FROM deleted);
        
        GET DIAGNOSTICS rows_deleted = ROW_COUNT;
        
        -- Thoát vòng lặp khi không còn dòng nào thỏa mãn điều kiện
        IF rows_deleted = 0 THEN
            EXIT;
        END IF;

        COMMIT; -- Commit từng batch để giải phóng WAL và lock
        PERFORM pg_sleep(0.1); -- Nghỉ 100ms để replica kịp sync
    END LOOP;
END $$;
```

Sau khi xóa xong, chạy `VACUUM ANALYZE` để đánh dấu tái sử dụng không gian:
```sql
VACUUM ANALYZE schema_name.large_table;
```

---

## 3. Xử Lý Sự Cố Khi Phân Vùng Đĩa Bị Đầy Do `pg_wal/`

Khi thư mục `/u01/data/postgresql/16/main/pg_wal/` tăng đột biến chiếm hết ổ cứng:

> [!CAUTION]
> **TUYỆT ĐỐI KHÔNG ĐƯỢC DÙNG LỆNH `rm -f pg_wal/*` Ở TẦNG BASH!**  
> Xóa thủ công file WAL sẽ làm hỏng dữ liệu (Database Corruption), crash PostgreSQL và khiến instance không thể khởi động lại được.

### Các nguyên nhân chính và cách xử lý:

#### Nguyên nhân 1: Replication Slot bị treo (Unused / Inactive Replication Slot)
Khi một Standby node bị tắt máy hoặc ngắt kết nối trong thời gian dài, Primary node sẽ giữ lại toàn bộ file WAL kể từ thời điểm Standby đó ngắt kết nối để chờ Standby quay lại:

```sql
-- 1. Kiểm tra dung lượng WAL đang bị giữ bởi từng replication slot:
SELECT 
    slot_name,
    plugin,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal_size
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;

-- 2. Nếu phát hiện slot không còn dùng (active = f) và đang giữ hàng chục GB:
-- Xóa slot đó đi để Primary giải phóng WAL:
SELECT pg_drop_replication_slot('node_db_02_slot');
```

#### Nguyên nhân 2: Giao dịch treo mở quá lâu (Long-running / Idle Transactions)
Giao dịch mở quá lâu ngăn cản cơ chế Checkpoint và WAL recycle:

```sql
-- 1. Tìm các session treo > 30 phút:
SELECT 
    pid, 
    usename, 
    client_addr, 
    state, 
    now() - xact_start AS duration, 
    query
FROM pg_stat_activity
WHERE state != 'idle' AND xact_start < now() - INTERVAL '30 minutes'
ORDER BY duration DESC;

-- 2. Terminate session gây treo:
SELECT pg_terminate_backend(<PID>);
```

#### Nguyên nhân 3: WAL Archiving bị lỗi
Nếu bật `archive_mode = on` nhưng `archive_command` trả về lỗi (ví dụ: đích đến NFS/S3 đầy hoặc sai quyền), PostgreSQL sẽ giữ toàn bộ WAL lại trong `pg_wal`:

```sql
-- Kiểm tra trạng thái archiving:
SELECT * FROM pg_stat_archiver;
```
*Khắc phục:* Sửa script `archive_command` hoặc fix lỗi ổ đĩa backup, WAL sẽ tự động được archive và giải phóng.

#### Bước cuối: Kích hoạt Checkpoint thủ công
Sau khi đã xử lý các nguyên nhân trên, thực hiện lệnh sau để PostgreSQL dọn dẹp các WAL cũ ngay lập tức:

```sql
CHECKPOINT;
```

---

## 4. Tối Ưu Hóa Cấu Hình Tự Động Dọn Rác (`autovacuum`)

Để hệ thống tự động dọn rác đều đặn, không để dead tuples tích tụ thành khối lượng khổng lồ:

Kiểm tra cấu hình autovacuum hiện tại trong `postgresql.conf`:
```sql
SELECT name, setting, unit FROM pg_settings WHERE name LIKE 'autovacuum%';
```

**Khuyến nghị tinh chỉnh cho hệ thống Production:**

```ini
# Bật autovacuum (mặc định đã bật)
autovacuum = on

# Số lượng worker chạy đồng thời (mặc định là 3, có thể tăng lên 4-6 nếu server nhiều CPU và nhiều bảng)
autovacuum_max_workers = 4

# Thời gian sleep giữa các vòng quét (giảm xuống để autovacuum chạy tích cực hơn)
autovacuum_naptime = 30s

# Ngưỡng tỷ lệ dead tuples để kích hoạt autovacuum (mặc định 0.2 tức 20%, nên giảm còn 10% hoặc 5% cho bảng lớn)
autovacuum_vacuum_scale_factor = 0.1
autovacuum_vacuum_threshold = 50

# Nâng giới hạn chi phí I/O để autovacuum dọn dẹp nhanh hơn, không bị bóp nghẽn:
autovacuum_vacuum_cost_limit = 1000
autovacuum_vacuum_cost_delay = 2ms
```

Kiểm tra tiến trình autovacuum đang chạy thời gian thực:
```sql
SELECT 
    pid, 
    datname, 
    relid::regclass AS table_name, 
    phase, 
    heap_blks_total, 
    heap_blks_scanned, 
    heap_blks_vacuumed
FROM pg_stat_progress_vacuum;
```

---

## 5. Tóm Tắt Quy Trình Dọn Dẹp Khuyến Nghị (Runbook Checklist)

| Tình huống | Hành động khuyến nghị | Mức độ rủi ro / Khóa bảng |
| :--- | :--- | :--- |
| **Bảng có nhiều dead tuples (bloat nhẹ)** | `VACUUM (VERBOSE, ANALYZE) <table>;` | Không khóa, an toàn chạy online |
| **Index phình to sau nhiều UPDATE/DELETE** | `REINDEX TABLE CONCURRENTLY <table>;` | Không khóa, tốn I/O |
| **Bảng phình to, cần trả đĩa về OS gấp** | Dùng `pg_repack` (hoặc `VACUUM FULL` ngoài giờ) | `pg_repack`: An toàn<br>`VACUUM FULL`: **Lock toàn bộ bảng** |
| **Xóa dữ liệu cũ theo lịch (Retention)** | Viết function Batch `DELETE` 5000 rows/commit | An toàn, tránh bão WAL |
| **Xóa sạch bảng tạm/staging** | `TRUNCATE TABLE <table>;` | Nhanh, khóa bảng trong tích tắc |
| **Thư mục `pg_wal` đầy khẩn cấp** | Drop inactive replication slots -> Kill transaction treo -> `CHECKPOINT;` | Tuyệt đối **KHÔNG** dùng `rm` xóa file WAL |
