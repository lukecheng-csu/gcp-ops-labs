FROM python:3.12-slim
WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

# Cloud Run 硬约定：容器必须监听 $PORT（部署时注入，默认 8080）
# 用 shell 形式的 CMD 才能让 $PORT 在启动时展开
ENV PORT=8080
CMD uvicorn main:app --host 0.0.0.0 --port $PORT
