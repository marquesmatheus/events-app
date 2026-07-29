#!/bin/sh
set -e

cd /app

# FastAPI (API + Dashboard)
python -m uvicorn api:app --host 0.0.0.0 --port 8000 &

# Worker (SQS consumer)
exec python worker.py
