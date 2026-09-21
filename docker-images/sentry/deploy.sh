#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Sentry Self-Hosted Automated Setup & Verification Script
# Repository: https://github.com/getsentry/self-hosted
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}      Sentry Self-Hosted Automated Setup Script       ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 1. Check Root / Sudo privileges
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}[!] Khuyến nghị chạy bằng quyền root hoặc có sudo privileges.${NC}"
fi

# 2. Check Hardware Resources
echo -e "\n${BLUE}>>> 1. Kiểm tra tài nguyên hệ thống (VM Specs)...${NC}"
CPU_CORES=$(nproc)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
TOTAL_SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
TOTAL_SWAP_GB=$((TOTAL_SWAP_KB / 1024 / 1024))

echo " - CPU Cores: ${CPU_CORES}"
echo " - Physical RAM: ${TOTAL_RAM_GB} GB"
echo " - Swap: ${TOTAL_SWAP_GB} GB"

if [ "$CPU_CORES" -lt 4 ]; then
    echo -e "${RED}[WARNING] Sentry yêu cầu tối thiểu 4 CPU cores. Hiện tại máy bạn có ${CPU_CORES} cores.${NC}"
    echo -e "${RED}          Hệ thống có thể chạy rất chậm hoặc nghẽn Kafka/ClickHouse.${NC}"
fi

if [ "$TOTAL_RAM_GB" -lt 14 ]; then
    echo -e "${RED}[WARNING] RAM vật lý hiện tại (${TOTAL_RAM_GB} GB) thấp hơn mức khuyến nghị 16 GB.${NC}"
    echo -e "${YELLOW}[TIP] Cần đảm bảo có ít nhất 8-16 GB Swap để tránh OOM Killer tắt các container của Sentry!${NC}"
    
    if [ "$TOTAL_SWAP_GB" -lt 8 ]; then
        echo -e "${YELLOW}Bạn có muốn tự động tạo file Swap 8GB (/swapfile_sentry) không? (y/n)${NC}"
        read -r CREATE_SWAP
        if [ "$CREATE_SWAP" = "y" ] || [ "$CREATE_SWAP" = "Y" ]; then
            echo "Đang tạo swapfile 8GB..."
            fallocate -l 8G /swapfile_sentry || dd if=/dev/zero of=/swapfile_sentry bs=1G count=8
            chmod 600 /swapfile_sentry
            mkswap /swapfile_sentry
            swapon /swapfile_sentry
            echo '/swapfile_sentry none swap sw 0 0' >> /etc/fstab
            echo -e "${GREEN}[OK] Đã kích hoạt Swap 8GB thành công!${NC}"
        fi
    fi
else
    echo -e "${GREEN}[OK] Tài nguyên RAM/CPU đáp ứng yêu cầu cơ bản.${NC}"
fi

# 3. Check Docker & Docker Compose
echo -e "\n${BLUE}>>> 2. Kiểm tra Docker & Docker Compose...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERROR] Không tìm thấy Docker! Vui lòng cài đặt Docker Engine trước.${NC}"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo -e "${RED}[ERROR] Không tìm thấy Docker Compose v2 (docker compose)!${NC}"
    exit 1
fi

DOCKER_VER=$(docker --version)
COMPOSE_VER=$(docker compose version)
echo -e " - ${DOCKER_VER}"
echo -e " - ${COMPOSE_VER}"
echo -e "${GREEN}[OK] Docker & Docker Compose đã sẵn sàng.${NC}"

# 4. Target Directory & Release Tag Detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${SCRIPT_DIR}/self-hosted"

echo -e "\n${BLUE}>>> 3. Xác định phiên bản phát hành (Release Tag) của Sentry...${NC}"
echo "Đang kiểm tra thông tin phiên bản phát hành từ GitHub..."
RELEASE_JSON=$(curl -s https://api.github.com/repos/getsentry/self-hosted/releases/latest || true)
LATEST_TAG=$(echo "$RELEASE_JSON" | grep '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
PUBLISHED_AT=$(echo "$RELEASE_JSON" | grep '"published_at":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG=$(git -c 'versionsort.suffix=-' ls-remote --tags --refs https://github.com/getsentry/self-hosted.git | awk -F/ '{print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
fi

# Fallback nếu không kết nối được
if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG="26.9.0"
fi

echo -e " - Phiên bản release ổn định mới nhất : ${GREEN}${LATEST_TAG}${NC}"

if [ -n "$PUBLISHED_AT" ]; then
    PUBLISHED_DATE=$(date -d "$PUBLISHED_AT" +"%d/%m/%Y %H:%M:%S UTC" 2>/dev/null || echo "$PUBLISHED_AT")
    PUBLISHED_SEC=$(date -d "$PUBLISHED_AT" +%s 2>/dev/null || echo 0)
    NOW_SEC=$(date +%s)
    if [ "$PUBLISHED_SEC" -gt 0 ]; then
        DIFF_SEC=$((NOW_SEC - PUBLISHED_SEC))
        DAYS_AGO=$((DIFF_SEC / 86400))
        echo -e " - Ngày phát hành (Release Date)       : ${GREEN}${PUBLISHED_DATE}${NC}"
        echo -e " - Thời gian đã trôi qua               : ${YELLOW}${DAYS_AGO} ngày trước${NC}"
    fi
fi

echo -e "\nNhập phiên bản bạn muốn cài đặt [Nhấn Enter để dùng ${LATEST_TAG}]:"
read -r INPUT_TAG
SENTRY_TAG="${INPUT_TAG:-$LATEST_TAG}"
echo -e "Sẽ sử dụng release tag: ${GREEN}${SENTRY_TAG}${NC}"

if [ -d "$TARGET_DIR" ]; then
    echo -e "${YELLOW}Thư mục ${TARGET_DIR} đã tồn tại.${NC}"
    echo "Bạn có muốn chuyển sang release ${SENTRY_TAG} trong thư mục này không? (y/n)"
    read -r REUSE_DIR
    if [ "$REUSE_DIR" = "y" ] || [ "$REUSE_DIR" = "Y" ]; then
        cd "$TARGET_DIR"
        git fetch --tags
        git checkout "$SENTRY_TAG"
    else
        echo "Đã hủy cài đặt."
        exit 0
    fi
else
    echo "Cloning https://github.com/getsentry/self-hosted.git (tag: ${SENTRY_TAG}) vào ${TARGET_DIR}..."
    git clone --branch "$SENTRY_TAG" --depth 1 https://github.com/getsentry/self-hosted.git "$TARGET_DIR"
    cd "$TARGET_DIR"
fi

# 5. Kiểm tra & Tự động xử lý môi trường Proxy / SSL Inspection
echo -e "\n${BLUE}>>> 4. Kiểm tra cấu hình Proxy & Chứng chỉ SSL mạng nội bộ...${NC}"
IS_BEHIND_PROXY=0
DETECTED_PROXY="${https_proxy:-${http_proxy:-${HTTPS_PROXY:-${HTTP_PROXY:-}}}}"

if [ -n "$DETECTED_PROXY" ]; then
    IS_BEHIND_PROXY=1
    echo -e " - Phát hiện Proxy trong biến môi trường shell: ${GREEN}${DETECTED_PROXY}${NC}"
fi

if [ -f ~/.docker/config.json ]; then
    if grep -Ei "httpProxy|httpsProxy" ~/.docker/config.json 2>/dev/null; then
        IS_BEHIND_PROXY=1
        echo -e " - Phát hiện cấu hình Proxy trong: ${GREEN}~/.docker/config.json${NC}"
    fi
fi

if [ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
    IS_BEHIND_PROXY=1
    echo -e " - Phát hiện cấu hình Proxy trong: ${GREEN}/etc/systemd/system/docker.service.d/http-proxy.conf${NC}"
fi

if [ "$IS_BEHIND_PROXY" -eq 0 ]; then
    echo -e " - Không phát hiện biến môi trường Proxy tự động."
    echo -e "Máy chủ này có đang chạy sau HTTP/HTTPS Proxy của công ty không? (y/n) [Mặc định: n]:"
    read -r PROXY_CONFIRM
    if [ "$PROXY_CONFIRM" = "y" ] || [ "$PROXY_CONFIRM" = "Y" ]; then
        IS_BEHIND_PROXY=1
    fi
fi

if [ "$IS_BEHIND_PROXY" -eq 1 ]; then
    echo -e "${YELLOW}[!] Máy chủ đang hoạt động sau Proxy. Đang tự động xử lý cấu hình tránh lỗi SSL...${NC}"

    # 1. Tự động chèn --trusted-host vào sentry/Dockerfile nếu chưa có
    if [ -f "${TARGET_DIR}/sentry/Dockerfile" ]; then
        if ! grep -q "trusted-host" "${TARGET_DIR}/sentry/Dockerfile"; then
            echo " - Đang tự động chèn cờ --trusted-host vào ${TARGET_DIR}/sentry/Dockerfile..."
            sed -i 's|pip install https://github.com|pip install --trusted-host github.com --trusted-host codeload.github.com --trusted-host pypi.org --trusted-host files.pythonhosted.org https://github.com|g' "${TARGET_DIR}/sentry/Dockerfile"
            echo -e "   ${GREEN}[OK] Đã cấu hình pip trusted-host cho sentry/Dockerfile.${NC}"
        else
            echo -e "   ${GREEN}[OK] sentry/Dockerfile đã có cấu hình trusted-host.${NC}"
        fi
    fi

    # 2. Tự động đồng bộ chứng chỉ Root CA nội bộ từ host (nếu có)
    if compgen -G "/usr/local/share/ca-certificates/*.crt" > /dev/null; then
        echo " - Phát hiện chứng chỉ CA tại /usr/local/share/ca-certificates/, đang đồng bộ vào Sentry..."
        mkdir -p "${TARGET_DIR}/certificates"
        cp /usr/local/share/ca-certificates/*.crt "${TARGET_DIR}/certificates/" 2>/dev/null || true
        
        # Bật SETUP_CUSTOM_CA_CERTIFICATE=1 trong .env
        if grep -q "SETUP_CUSTOM_CA_CERTIFICATE" "${TARGET_DIR}/.env"; then
            sed -i 's/# SETUP_CUSTOM_CA_CERTIFICATE=1/SETUP_CUSTOM_CA_CERTIFICATE=1/g' "${TARGET_DIR}/.env"
        else
            echo "SETUP_CUSTOM_CA_CERTIFICATE=1" >> "${TARGET_DIR}/.env"
        fi
        echo -e "   ${GREEN}[OK] Đã kích hoạt SETUP_CUSTOM_CA_CERTIFICATE=1.${NC}"
    fi

    # 3. Kiểm tra cảnh báo noProxy trong ~/.docker/config.json
    if [ -f ~/.docker/config.json ]; then
        if ! grep -qi "kafka" ~/.docker/config.json 2>/dev/null; then
            echo -e "${RED}[CẢNH BÁO] ~/.docker/config.json có proxy nhưng thiếu tên container Sentry trong noProxy!${NC}"
            echo -e "${YELLOW}           Vui lòng thêm: sentry,postgres,redis,clickhouse,kafka,zookeeper,snuba,relay,symbolicator,web vào noProxy để tránh lỗi sập hệ thống.${NC}"
        fi
    fi
else
    echo -e "${GREEN}[OK] Bỏ qua các bước can thiệp SSL/Proxy.${NC}"
fi

# 6. Optional custom environment configuration
echo -e "\n${BLUE}>>> 5. Cấu hình biến môi trường tùy chỉnh...${NC}"
if [ -f "${SCRIPT_DIR}/.env.custom" ]; then
    echo "Đang nạp cấu hình từ ${SCRIPT_DIR}/.env.custom vào self-hosted/.env..."
    cat "${SCRIPT_DIR}/.env.custom" >> "${TARGET_DIR}/.env"
    echo -e "${GREEN}[OK] Đã nạp cấu hình tùy chỉnh.${NC}"
else
    echo "Chưa có file .env.custom. Sử dụng cấu hình mặc định."
    echo -e "${YELLOW}(Bạn có thể chỉnh sửa file self-hosted/sentry/config.yml và self-hosted/.env sau)${NC}"
fi

# 7. Run install.sh
echo -e "\n${BLUE}>>> 6. Bắt đầu quá trình khởi tạo (install.sh)...${NC}"
echo -e "${YELLOW}Quá trình này sẽ kéo các image, migrate database PostgreSQL, ClickHouse, Snuba, Kafka...${NC}"
echo -e "${YELLOW}Thời gian thực hiện có thể mất từ 10 - 25 phút tùy tốc độ mạng và phần cứng.${NC}"
echo -e "${YELLOW}Bạn có muốn chạy ./install.sh ngay bây giờ? (y/n)${NC}"
read -r PROCEED

if [ "$PROCEED" = "y" ] || [ "$PROCEED" = "Y" ]; then
    ./install.sh
    echo -e "\n${GREEN}======================================================${NC}"
    echo -e "${GREEN}      CÀI ĐẶT HOÀN TẤT THÀNH CÔNG!                     ${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo -e "Để khởi động dịch vụ Sentry:"
    echo -e "  cd ${TARGET_DIR}"
    echo -e "  docker compose up -d"
    echo -e "\nTruy cập Web UI tại: ${BLUE}http://<IP_CUA_VM>:9000${NC}"
else
    echo -e "${YELLOW}Đã tải mã nguồn về ${TARGET_DIR}.${NC}"
    echo -e "Khi nào bạn sẵn sàng cài đặt, hãy chạy:"
    echo -e "  cd ${TARGET_DIR}"
    echo -e "  ./install.sh"
    echo -e "  docker compose up -d"
fi
