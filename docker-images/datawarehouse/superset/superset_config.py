import os

def read_secret(secret_name, default=""):
    """Đọc giá trị từ Docker secret file (/run/secrets/<secret_name>) nếu tồn tại, ngược lại lấy từ environment variable."""
    secret_path = f"/run/secrets/{secret_name}"
    if os.path.exists(secret_path):
        try:
            with open(secret_path, "r") as f:
                return f.read().strip()
        except Exception:
            pass
    return os.environ.get(secret_name.upper(), default)

ROW_LIMIT = 50000
SUPERSET_WEBSERVER_PORT = 8088

# Secret key phục vụ mã hóa phiên và cookie (ưu tiên đọc từ Docker secret)
SECRET_KEY = read_secret("superset_secret_key", os.environ.get("SUPERSET_SECRET_KEY", "CHANGE_ME_TO_A_COMPLEX_RANDOM_SECRET_KEY_12345"))

# Kết nối Metadata Database (PostgreSQL)
POSTGRES_USER = os.environ.get("POSTGRES_USER", "superset")
POSTGRES_PASSWORD = read_secret("postgres_password", os.environ.get("POSTGRES_PASSWORD", "superset_password"))
POSTGRES_DB = os.environ.get("POSTGRES_DB", "superset")
POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "superset-db")
POSTGRES_PORT = os.environ.get("POSTGRES_PORT", "5432")

SQLALCHEMY_DATABASE_URI = os.environ.get(
    "SUPERSET_DATABASE_URI",
    f"postgresql+psycopg2://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_HOST}:{POSTGRES_PORT}/{POSTGRES_DB}"
)

# Cấu hình Redis Caching
REDIS_HOST = os.environ.get("REDIS_HOST", "superset-redis")
REDIS_PORT = os.environ.get("REDIS_PORT", "6379")

CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
    "CACHE_KEY_PREFIX": "superset_",
    "CACHE_REDIS_HOST": REDIS_HOST,
    "CACHE_REDIS_PORT": REDIS_PORT,
}
DATA_CACHE_CONFIG = CACHE_CONFIG

# Cho phép xử lý Jinja template trong SQL Lab
FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
}
