# Profiling Sidecar & Debug Container

Container image chuyên dụng để **profiling, troubleshooting và trích xuất FlameGraph** cho các ứng dụng chạy trên Linux / Kubernetes Pod.

## 🧰 Các công cụ tích hợp sẵn

* **`py-spy`** (0.4.2): Sampling profiler tốc độ cao cho Python (không cần sửa code hay restart tiến trình).
* **`perf`** (`linux-tools-generic`): Profiler hệ thống Linux chuẩn (CPU cycles, cache misses, kernel & native call stacks).
* **`FlameGraph`** (Brendan Gregg): Bộ công cụ chuyển stack trace thành biểu đồ `.svg` trực quan (sẵn trong `PATH`: `flamegraph.pl`, `stackcollapse-perf.pl`,...).
* **`busybox`**: Bộ tiện ích dòng lệnh hỗ trợ debug nhanh.

---

## 🚀 Hướng dẫn sử dụng trên Kubernetes

Để profile tiến trình của một container khác trong cùng Pod, container debug cần:
1. **Chia sẻ Process Namespace** (`shareProcessNamespace: true` hoặc dùng `kubectl debug --target`).
2. **Quyền PTRACE** (`SYS_PTRACE` hoặc `SYS_ADMIN`) để đọc stack trace và bộ nhớ của tiến trình mục tiêu.

---

### Cách 1: Debug trực tiếp Pod đang chạy với `kubectl debug` (Khuyên dùng)

> **Ưu điểm:** Không cần cấu hình trước hay khởi động lại Pod.

#### 1. Đính kèm Ephemeral Container vào Pod mục tiêu
```bash
# Tham số --target chỉ định container chứa ứng dụng cần profile
kubectl debug -it <POD_NAME> -n <NAMESPACE> \
  --image=docker.io/duyle95/profiling-sidecar:latest \
  --target=<CONTAINER_NAME> \
  --profile=sysadmin \
  -- bash
```

> ⚠️ **Lưu ý khi Cluster bật Pod Security Standards (PSA/PSS) hoặc Kyverno / Gatekeeper:**
> Nếu Namespace enforce mức `baseline` hoặc `restricted`, lệnh trên có thể bị chặn vì `--profile=sysadmin` yêu cầu quyền `privileged`/`hostPID`. Bạn có 2 cách giải quyết:
>
> **Cách A: Dùng file cấu hình quyền tùy chỉnh (`--custom` trên K8s 1.27+)**
> Tạo file `debug-security.json` hoặc `.yaml` chỉ cấp đúng quyền `SYS_PTRACE` tối thiểu:
> ```yaml
> # debug-security.yaml
> securityContext:
>   capabilities:
>     add:
>       - SYS_PTRACE
>   runAsUser: 0
>   runAsNonRoot: false
>   allowPrivilegeEscalation: true
> ```
> Chạy lệnh:
> ```bash
> kubectl debug -it <POD_NAME> -n <NAMESPACE> \
>   --image=docker.io/duyle95/profiling-sidecar:latest \
>   --target=<CONTAINER_NAME> \
>   --custom=debug-security.yaml \
>   -- bash
> ```
>
> **Cách B: Sao chép Pod sang Pod Debug độc lập (`--copy-to`)**
> ```bash
> kubectl debug <POD_NAME> -n <NAMESPACE> \
>   --copy-to=<POD_NAME>-debug \
>   --share-processes \
>   --image=docker.io/duyle95/profiling-sidecar:latest \
>   -it -- bash
> ```


---

### Cách 2: Triển khai sẵn dưới dạng Sidecar Container trong Deployment

Khai báo trực tiếp `profiling-sidecar` trong manifest Pod hoặc Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      # BẮT BUỘC: Cho phép các container trong Pod thấy tiến trình của nhau
      shareProcessNamespace: true

      containers:
        # Container ứng dụng chính
        - name: app
          image: python:3.10-slim
          command: ["python", "-c", "import time; [time.sleep(1) for _ in iter(int, 1)]"]

        # Profiling Sidecar Container
        - name: profiling-sidecar
          image: docker.io/duyle95/profiling-sidecar:latest
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "sleep infinity"]
          securityContext:
            capabilities:
              add:
                - SYS_PTRACE # Bắt buộc để inspect process
                - SYS_ADMIN  # Cần thiết nếu dùng Linux perf kernel events
```

Truy cập vào sidecar:
```bash
kubectl exec -it <POD_NAME> -c profiling-sidecar -n <NAMESPACE> -- bash
```

---

## 🔍 Các kịch bản Profiling & Xuất FlameGraph mẫu

Sau khi đã truy cập shell bên trong container debug:

### 1. Tìm PID của ứng dụng mục tiêu
```bash
ps aux
# Hoặc lọc theo tên:
pgrep -fl python
```

---

### 2. Profile ứng dụng Python với `py-spy`

* **Xem Live Top CPU (tương tự `top` nhưng theo từng dòng code Python):**
  ```bash
  py-spy top --pid <PID>
  ```

* **In Call Stack hiện tại của tiến trình (Dump):**
  ```bash
  py-spy dump --pid <PID>
  ```

* **Ghi nhận và xuất FlameGraph SVG:**
  ```bash
  # Thu thập mẫu trong 30 giây và xuất ra file SVG
  py-spy record --pid <PID> --duration 30 --output /tmp/python-flamegraph.svg
  ```

---

### 3. Profile toàn hệ thống / Native C/C++ / Go / Rust bằng Linux `perf`

#### 📌 Bước 1: Thu thập dữ liệu Profiling (`perf record`)

Chạy lệnh ghi mẫu bên trong shell của container debug:
```bash
perf record -F 99 -p <PID> -g -o /tmp/perf.data -- sleep 30
```

**Giải thích các tùy chọn (Options) cơ bản:**
* **`-F 99`** (`--freq=99`): Tần số lấy mẫu (Sampling frequency) là 99 lần/giây trên mỗi CPU core. Chọn **99Hz** thay vì 100Hz để tránh lỗi *lockstep sampling* (lấy mẫu trùng nhịp với ngắt đồng hồ hệ thống định kỳ như 100Hz/1000Hz).
* **`-p <PID>`** (`--pid`): Chỉ định chính xác Process ID của tiến trình ứng dụng cần profile.
* **`-g`** (`--call-graph`): Kích hoạt thu thập Call Stack Trace (bắt buộc để dựng cây gọi hàm và vẽ FlameGraph).
* **`-o /tmp/perf.data`**: Đường dẫn file lưu trữ dữ liệu thô nhị phân.
* **`-- sleep 30`**: Lệnh thực thi đi kèm để ấn định khoảng thời gian profile đúng 30 giây. Khi `sleep` kết thúc, `perf` sẽ tự động dừng và lưu file.

**Các tùy chọn nâng cao (nếu muốn phân tích chi tiết hơn):**
* **`-g dwarf`** (thay cho `-g`): Dùng DWARF debug info để giải mã stack trace. Cần thiết khi ứng dụng (Go, Rust, C++) được biên dịch ở chế độ tối ưu hóa hoặc không có Frame Pointer (`-fomit-frame-pointer`). *Lưu ý: File `perf.data` sẽ có dung lượng lớn hơn nhiều.*
* **`-g fp`**: Dùng Frame Pointer (nhẹ và nhanh, là chế độ mặc định của `-g`, yêu cầu binary build với cờ `-fno-omit-frame-pointer`).
* **`-a`** (`--all-cpus`, thay cho `-p <PID>`): Profile toàn bộ hệ thống (tất cả các tiến trình chạy trên mọi CPU core của worker node).
* **`-e <event>`**: Lọc theo loại sự kiện phần cứng/hệ thống cụ thể (mặc định là `cycles`). Các event phổ biến khác: `-e cpu-clock`, `-e instructions`, `-e cache-misses`, `-e page-faults`.

---

#### 📌 Bước 2: Xử lý dữ liệu & Xuất kết quả (Chọn 1 trong 2 cách)

Sau khi có file `/tmp/perf.data`, chọn 1 trong 2 cách xuất kết quả dưới đây:

##### 🌟 Cách A: Render trực tiếp file `.svg` trong Pod rồi copy về máy (Khuyên dùng)
> *Ưu điểm:* Container có sẵn Symbol Tables của tiến trình nên phân giải tên hàm chính xác nhất; file `.svg` sinh ra rất nhẹ (< 1MB), dễ copy và xem ngay trên mọi trình duyệt.

1. **Chuyển đổi dữ liệu và vẽ FlameGraph ngay trong Pod:**
   ```bash
   perf script -i /tmp/perf.data | stackcollapse-perf.pl | flamegraph.pl --title="CPU FlameGraph" > /tmp/perf-flamegraph.svg
   ```
   * **`perf script`**: Giải mã file nhị phân `perf.data` thành danh sách stack trace dạng văn bản (text).
   * **`stackcollapse-perf.pl`**: Gom nhóm (aggregate) các call stack trùng lặp thành định dạng 1 dòng (`func_a;func_b 120`).
   * **`flamegraph.pl`**: Đọc dữ liệu đã gom nhóm và sinh biểu đồ tương tác SVG.

2. **Copy file `.svg` về máy tính cá nhân (chạy từ terminal máy local):**
   ```bash
   # Nếu dùng Ephemeral Debug Container (kubectl debug):
   kubectl cp <NAMESPACE>/<POD_NAME>:/tmp/perf-flamegraph.svg ./perf-flamegraph.svg -c <DEBUGGER_CONTAINER_NAME>

   # Nếu dùng Sidecar Container:
   kubectl cp <NAMESPACE>/<POD_NAME>:/tmp/perf-flamegraph.svg ./perf-flamegraph.svg -c profiling-sidecar
   ```

3. **Mở xem biểu đồ:** Click đúp mở file `perf-flamegraph.svg` bằng trình duyệt web (Google Chrome, Firefox, Edge).

---

##### 💻 Cách B: Copy file thô `perf.data` về máy tính để phân tích chuyên sâu
> *Ưu điểm:* Giúp xem trực tiếp giao diện tương tác dòng lệnh `perf report` (TUI) trên máy cá nhân hoặc mở rộng phân tích bằng các công cụ local.

1. **Copy file `perf.data` về máy tính cá nhân (chạy từ terminal máy local):**
   ```bash
   kubectl cp <NAMESPACE>/<POD_NAME>:/tmp/perf.data ./perf.data -c <CONTAINER_NAME>
   ```

2. **Phân tích trên máy cá nhân (yêu cầu máy local có cài `perf`):**
   ```bash
   # Xem báo cáo tương tác TUI (dùng phím mũi tên duyệt hàm):
   perf report -i ./perf.data

   # Hoặc tự render FlameGraph trên máy local:
   perf script -i ./perf.data | stackcollapse-perf.pl | flamegraph.pl > local-flamegraph.svg
   ```

---

## 📥 Mẹo thao tác và tương tác với file FlameGraph `.svg`

Sau khi tải file SVG về máy tính và mở bằng trình duyệt:
* **Click vào một hàm:** Phóng to (zoom) sâu vào call stack của nhánh hàm đó.
* **Click `Reset Zoom` (góc trên bên trái):** Quay trở lại toàn bộ biểu đồ ban đầu.
* **Click `Search` (góc trên bên phải):** Nhập tên function/module/thư viện để highlight màu tím nổi bật trên biểu đồ.
* **Độ rộng của thanh:** Tương ứng với tỉ lệ thời gian chiếm dụng CPU (thanh càng rộng $\rightarrow$ hàm tiêu tốn càng nhiều tài nguyên).
