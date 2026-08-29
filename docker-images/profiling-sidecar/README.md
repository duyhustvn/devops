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

### 3. Profile toàn hệ thống / Native C/C++ bằng Linux `perf`

* **Ghi nhận CPU profile bằng `perf` trong 30 giây:**
  ```bash
  perf record -F 99 -p <PID> -g -- sleep 30
  ```

* **Render dữ liệu `perf` thành biểu đồ FlameGraph:**
  ```bash
  perf script | stackcollapse-perf.pl | flamegraph.pl > /tmp/perf-flamegraph.svg
  ```

---

## 📥 Tải file FlameGraph `.svg` về máy tính

Từ máy cá nhân (local terminal), chạy lệnh copy file SVG từ pod về để mở trên trình duyệt (Chrome, Firefox):

```bash
# Đối với Ephemeral Debug Container
kubectl cp <NAMESPACE>/<POD_NAME>:/tmp/python-flamegraph.svg ./python-flamegraph.svg -c debugger-xxxxx

# Đối với Sidecar Container
kubectl cp <NAMESPACE>/<POD_NAME>:/tmp/python-flamegraph.svg ./python-flamegraph.svg -c profiling-sidecar
```
