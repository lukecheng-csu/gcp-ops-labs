FROM python:3.12-slim

WORKDIR /app

# 先只拷依赖清单：依赖不变时这一层走缓存，改代码不会重装依赖
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

# Cloud Run 会注入 PORT；本地跑要自己给
ENV PORT=8080
CMD uvicorn main:app --host 0.0.0.0 --port $PORT
