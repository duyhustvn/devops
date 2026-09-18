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

# 4. Target Directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${SCRIPT_DIR}/self-hosted"

echo -e "\n${BLUE}>>> 3. Chuẩn bị mã nguồn getsentry/self-hosted...${NC}"
if [ -d "$TARGET_DIR" ]; then
    echo -e "${YELLOW}Thư mục ${TARGET_DIR} đã tồn tại.${NC}"
    echo "Bạn có muốn tiếp tục sử dụng thư mục này không? (y/n)"
    read -r REUSE_DIR
    if [ "$REUSE_DIR" != "y" ] && [ "$REUSE_DIR" != "Y" ]; then
        echo "Đã hủy cài đặt."
        exit 0
    fi
else
    echo "Cloning https://github.com/getsentry/self-hosted.git vào ${TARGET_DIR}..."
    git clone https://github.com/getsentry/self-hosted.git "$TARGET_DIR"
fi

cd "$TARGET_DIR"

# 5. Optional custom environment configuration
echo -e "\n${BLUE}>>> 4. Cấu hình biến môi trường tùy chỉnh...${NC}"
if [ -f "${SCRIPT_DIR}/.env.custom" ]; then
    echo "Đang nạp cấu hình từ ${SCRIPT_DIR}/.env.custom vào self-hosted/.env..."
    cat "${SCRIPT_DIR}/.env.custom" >> "${TARGET_DIR}/.env"
    echo -e "${GREEN}[OK] Đã nạp cấu hình tùy chỉnh.${NC}"
else
    echo "Chưa có file .env.custom. Sử dụng cấu hình mặc định."
    echo -e "${YELLOW}(Bạn có thể chỉnh sửa file self-hosted/sentry/config.yml và self-hosted/.env sau)${NC}"
fi

# 6. Run install.sh
echo -e "\n${BLUE}>>> 5. Bắt đầu quá trình khởi tạo (install.sh)...${NC}"
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
