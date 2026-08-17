import os

ROW_LIMIT = 50000
SUPERSET_WEBSERVER_PORT = 8088

# Secret key phục vụ mã hóa phiên và cookie
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "CHANGE_ME_TO_A_COMPLEX_RANDOM_SECRET_KEY_12345")

# Kết nối Metadata Database (PostgreSQL)
SQLALCHEMY_DATABASE_URI = os.environ.get(
    "SUPERSET_DATABASE_URI",
    "postgresql+psycopg2://superset:superset_password@superset-db:5432/superset"
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
