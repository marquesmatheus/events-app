import os
import json
import boto3
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

app = FastAPI(title="events-app")
sqs = boto3.client("sqs", region_name=os.environ["AWS_REGION"])
queue_url = os.environ["SQS_QUEUE_URL"]


class Event(BaseModel):
    type: str
    data: dict = {}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/events")
async def list_events():
    return {"message": "use POST /events to create events"}


@app.post("/events")
async def create_event(event: Event):
    sqs.send_message(QueueUrl=queue_url, MessageBody=event.model_dump_json())
    return {"status": "queued", "event": event}


# ── Frontend Dashboard ───────────────────────────────────────────────────

HTML_DASHBOARD = """
<!DOCTYPE html>
<html lang="pt-br">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>events-app &mdash; Dashboard</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
background:#0f172a;color:#e2e8f0;line-height:1.6;padding:20px}
h1{font-size:1.5rem;margin-bottom:4px;color:#f8fafc}
h2{font-size:1.1rem;color:#94a3b8;margin:24px 0 12px}
.card{background:#1e293b;border:1px solid #334155;border-radius:12px;padding:20px;margin-bottom:16px}
.card h3{font-size:.9rem;color:#64748b;text-transform:uppercase;letter-spacing:.05em;margin-bottom:8px}
.badge{display:inline-block;background:#1e293b;color:#94a3b8;padding:4px 12px;border-radius:999px;font-size:.8rem}
.flex{display:flex;gap:12px;flex-wrap:wrap;align-items:center}
.btn{background:#3b82f6;color:#fff;border:none;padding:8px 16px;border-radius:8px;cursor:pointer;font-size:.85rem}
.btn:hover{background:#2563eb}
.btn-sm{padding:4px 10px;font-size:.8rem}
input,textarea{background:#0f172a;border:1px solid #334155;color:#e2e8f0;padding:8px 12px;border-radius:8px;
width:100%;margin-bottom:8px;font-family:inherit;font-size:.85rem}
pre{background:#0f172a;border:1px solid #334155;border-radius:8px;padding:16px;
font-family:'SF Mono',Monaco,monospace;font-size:.8rem;overflow:auto;max-height:400px;margin-top:8px}
#result{color:#22c55e}
code{color:#f59e0b}
.status-ok{color:#22c55e}
.status-error{color:#ef4444}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.resource-table{width:100%;border-collapse:collapse;font-size:.85rem}
.resource-table th,.resource-table td{text-align:left;padding:8px 12px;border-bottom:1px solid #334155}
.resource-table th{color:#64748b;font-weight:500}
</style>
</head>
<body>
<h1>&#9889; events-app</h1>
<p style="color:#94a3b8;font-size:.9rem">
  <span class="badge" id="status-badge">checking...</span>
  <span class="badge" id="region-badge">{region}</span>
</p>

<h2>&#128640; API</h2>
<div class="card">
  <h3>POST /events</h3>
  <p style="font-size:.85rem;color:#94a3b8;margin-bottom:12px">
    Envia evento para fila SQS. Worker consome e grava no PostgreSQL.
  </p>
  <input type="text" id="event-type" value="user.signup" placeholder="event type">
  <textarea id="event-data" rows="3" placeholder='{"email":"test@test.com"}'>{"email":"test@example.com"}</textarea>
  <div class="flex">
    <button class="btn" onclick="sendEvent()">Enviar Evento</button>
    <button class="btn btn-sm" onclick="healthCheck()">Health Check</button>
  </div>
  <pre id="result"></pre>
</div>

<script>
const region = "{region}";

async function sendEvent() {
  const type = document.getElementById('event-type').value || 'test';
  let data = {};
  try { data = JSON.parse(document.getElementById('event-data').value || '{}'); } catch(e) {}
  document.getElementById('result').textContent = 'enviando...';
  try {
    const r = await fetch('/events', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({type, data})
    });
    const j = await r.json();
    document.getElementById('result').textContent = JSON.stringify(j, null, 2)+'\\n\\nOK - evento publicado na fila SQS';
  } catch(e) {
    document.getElementById('result').textContent = 'Erro: '+e;
  }
}

async function healthCheck() {
  try {
    const r = await fetch('/health');
    const j = await r.json();
    document.getElementById('result').textContent = JSON.stringify(j, null, 2);
    document.getElementById('status-badge').textContent = j.status;
    document.getElementById('status-badge').className = 'badge status-ok';
  } catch(e) {
    document.getElementById('result').textContent = 'Erro: '+e;
    document.getElementById('status-badge').textContent = 'offline';
    document.getElementById('status-badge').className = 'badge status-error';
  }
}

healthCheck();
</script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
async def dashboard():
    return HTML_DASHBOARD.replace("{region}", os.environ.get("AWS_REGION", "us-east-1"))
