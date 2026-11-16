"""lab09 ops API —— 练习 9：Cloud Run 无服务器 API

设计要点：
- 统一错误结构：所有非 2xx 都是 {"error": {"code", "message"}}，客户端不用猜格式
- 监听 $PORT（Cloud Run 注入，这是硬约定）
- LAB09_MODE=broken 时 /api/* 全部 500（破坏-修复第 1 轮的靶子）
- /api/slow 可控睡眠（破坏-修复第 2 轮超时靶子）
"""
import os
import time

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

MODE = os.environ.get("LAB09_MODE", "dev")
VERSION = "1.0.0"

app = FastAPI(title="lab09-ops-api", version=VERSION)

# 内存版任务表（重启即清零，练习用够了）
TASKS = {
    1: {"id": 1, "title": "练习 9 第一条任务", "done": False},
    2: {"id": 2, "title": "把错误结构统一掉", "done": True},
}


# ---------- 统一错误结构：所有异常出口都长一个样 ----------
@app.exception_handler(HTTPException)
async def http_error(_: Request, exc: HTTPException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": {"code": exc.status_code, "message": str(exc.detail)}},
    )


@app.exception_handler(RequestValidationError)
async def validation_error(_: Request, exc: RequestValidationError):
    first = exc.errors()[0] if exc.errors() else {}
    msg = f"参数校验失败: {first.get('msg', 'unknown')} (field: {first.get('loc', '?')})"
    return JSONResponse(
        status_code=400,
        content={"error": {"code": 400, "message": msg}},
    )


# ---------- 路由 ----------
@app.get("/healthz")
def healthz():
    return {"status": "ok", "mode": MODE, "version": VERSION}


@app.get("/")
def info():
    return {"service": "lab09-api", "version": VERSION, "mode": MODE}


@app.get("/api/tasks")
def list_tasks():
    if MODE == "broken":
        raise HTTPException(500, "LAB09_MODE=broken：模拟配置错误（改环境变量就 500）")
    return {"count": len(TASKS), "tasks": list(TASKS.values())}


class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=64)


@app.post("/api/tasks", status_code=201)
def create_task(task: TaskIn):
    if MODE == "broken":
        raise HTTPException(500, "LAB09_MODE=broken：模拟配置错误（改环境变量就 500）")
    new_id = max(TASKS) + 1 if TASKS else 1
    TASKS[new_id] = {"id": new_id, "title": task.title, "done": False}
    return {"created": TASKS[new_id]}


@app.get("/api/tasks/{task_id}")
def get_task(task_id: int):
    if task_id not in TASKS:
        raise HTTPException(404, f"任务 {task_id} 不存在")
    return TASKS[task_id]


@app.get("/api/slow")
def slow(seconds: float = 5):
    """可控睡眠端点：破坏-修复第 2 轮用它打超时（上限 300s 防呆）"""
    time.sleep(min(seconds, 300))
    return {"slept": seconds, "note": "慢是有意的，别在生产里这么写"}
