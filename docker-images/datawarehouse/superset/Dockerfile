FROM apache/superset:3.1.0

USER root
# Cài đặt driver kết nối ClickHouse
COPY requirements-local.txt /app/docker/requirements-local.txt
RUN pip install --no-cache-dir -r /app/docker/requirements-local.txt

# Copy file cấu hình Superset tùy biến
COPY superset_config.py /app/pythonpath/superset_config.py

USER superset
