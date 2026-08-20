FROM apache/superset:6.1.0

USER root
# Cài đặt driver kết nối ClickHouse, PostgreSQL và Redis vào virtualenv của Superset
COPY requirements-local.txt /app/docker/requirements-local.txt
RUN uv pip install --no-cache --python /app/.venv -r /app/docker/requirements-local.txt

# Copy file cấu hình Superset tùy biến
COPY superset_config.py /app/pythonpath/superset_config.py

USER superset
