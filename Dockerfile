# syntax=docker/dockerfile:1.6
#
# Mia 云中继生产镜像
# ----------------------------------------------------------------------------
# 构建：docker build -t mia-relay:local cloud/
# 运行：docker run --rm -p 8000:8000 -e MIA_AUTH_TOKENS=demo mia-relay:local
#
# 说明：
#   * 以 python:3.11-slim 为基础镜像，体积小、兼容 uvicorn[standard]。
#   * 使用两阶段式依赖安装（先拷 pyproject，再拷源码），便于 Docker 构建缓存命中。
#   * 以非 root 用户 mia 运行，降低逃逸风险。
#   * 不在镜像里烘焙任何 token 或域名，所有配置通过环境变量 / .env 提供。
# ----------------------------------------------------------------------------

FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# 先复制依赖声明，单独安装依赖，利用层缓存。
COPY pyproject.toml README.md ./
# 创建一个最小 src 以便 pip install . 能识别包（真正的源码随后覆盖）。
RUN mkdir -p src/mia_relay && echo "" > src/mia_relay/__init__.py
RUN pip install .

# 复制完整源码后再次 pip install，确保 entry_points/包数据正确。
COPY src ./src
RUN pip install --no-deps .

# 以非 root 用户运行
RUN useradd --system --create-home --uid 10001 mia \
 && chown -R mia:mia /app
USER mia

EXPOSE 8000

# MIA_AUTH_TOKENS 等配置通过 docker-compose 从 .env 注入。
CMD ["uvicorn", "mia_relay.main:app", "--host", "0.0.0.0", "--port", "8000"]
