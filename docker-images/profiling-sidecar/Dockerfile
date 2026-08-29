ARG BASE_IMAGE=ubuntu:22.04

# ==========================================
# Stage 1: Builder (Tải & chuẩn bị công cụ)
# ==========================================
FROM ${BASE_IMAGE} AS builder

ARG http_proxy
ARG https_proxy
ARG no_proxy
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        python3-pip \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Cài py-spy để lấy binary
RUN pip3 install --no-cache-dir py-spy==0.4.2

# Clone FlameGraph và dọn dẹp .git để tối ưu dung lượng
RUN git clone --depth 1 https://github.com/brendangregg/FlameGraph /opt/FlameGraph \
    && rm -rf /opt/FlameGraph/.git

# ==========================================
# Stage 2: Final Runtime Image
# ==========================================
FROM ${BASE_IMAGE}

ARG http_proxy
ARG https_proxy
ARG no_proxy
ARG DEBIAN_FRONTEND=noninteractive

# Chỉ cài các runtime packages cần thiết
RUN apt-get update && apt-get install -y --no-install-recommends \
        busybox-static \
        linux-tools-generic \
        perl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy binaries và scripts từ stage builder
COPY --from=builder /usr/local/bin/py-spy /usr/local/bin/py-spy
COPY --from=builder /opt/FlameGraph /opt/FlameGraph

# Thêm FlameGraph vào PATH để tiện thực thi lệnh ở mọi nơi
ENV PATH="/opt/FlameGraph:${PATH}"
ENV HOME=/tmp
