"""lab10 ops API —— 练习 10：CI/CD（GitHub Actions → Cloud Run）

和练习 9 是同一套代码（统一错误结构 + /health + /api/slow），
唯一区别：`LAB10_MODE=broken` 用作流水线破坏演练的靶子。
"""
import os
import time

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

MODE = os.environ.get("LAB10_MODE", "dev")
VERSION = "1.0.0"

app = FastAPI(title="lab10-ops-api", version=VERSION)

TASKS = {
    1: {"id": 1, "title": "练习 10 第一条任务", "done": False},
    2: {"id": 2, "title": "让流水线替我做部署", "done": True},
}


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


# 注意：不要用 /healthz！Cloud Run 的 *.run.app 前端保留该路径（及所有 z 结尾路径），
# 请求到不了容器。练习 9 已实测，见其 README 排错表第 9 条。
@app.get("/health")
def health():
    return {"status": "ok", "mode": MODE, "version": VERSION}


@app.get("/")
def info():
    return {"service": "lab10-api", "version": VERSION, "mode": MODE}


@app.get("/api/tasks")
def list_tasks():
    if MODE == "broken":
        raise HTTPException(500, "LAB10_MODE=broken：模拟配置错误（流水线应拦住它）")
    return {"count": len(TASKS), "tasks": list(TASKS.values())}


class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=64)


@app.post("/api/tasks", status_code=201)
def create_task(task: TaskIn):
    if MODE == "broken":
        raise HTTPException(500, "LAB10_MODE=broken：模拟配置错误（流水线应拦住它）")
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
    """可控睡眠端点：破坏演练用它打超时（上限 300s 防呆）"""
    time.sleep(min(seconds, 300))
    return {"slept": seconds, "note": "慢是有意的，别在生产里这么写"}
