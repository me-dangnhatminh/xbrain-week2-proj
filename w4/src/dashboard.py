"""
Observability Dashboard for GeekBrain AI System (Bonus A).

Runs on port 8002. Provides:
- GET /                 → Dashboard web UI
- GET /api/queries      → List all processed queries
- GET /api/query/{id}   → Get detailed events for a query
- WS  /ws               → WebSocket for real-time event streaming

Usage:
    cd w4/src
    python dashboard.py
    # Open http://localhost:8002 in browser
"""

import os
import sys
import asyncio
import json
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware

# Add src to path
sys.path.insert(0, str(Path(__file__).parent))

from event_logger import event_logger

app = FastAPI(title="GeekBrain AI — Observability Dashboard")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── REST API Endpoints ─────────────────────────────────────────────


@app.get("/api/queries")
async def list_queries():
    """List all processed queries (most recent first)."""
    query_ids = event_logger.get_all_query_ids()
    summaries = []
    for qid in query_ids[:50]:
        summary = event_logger.get_query_summary(qid)
        if summary:
            summaries.append(summary)
    return {"queries": summaries}


@app.get("/api/query/{query_id}")
async def get_query_details(query_id: str):
    """Get all events for a specific query."""
    events = event_logger.get_events(query_id)
    return {
        "query_id": query_id,
        "events": [e.to_dict() for e in events],
    }


# ── WebSocket for real-time streaming ──────────────────────────────


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """Stream events for a query_id in real-time."""
    await websocket.accept()
    try:
        data = await websocket.receive_text()
        msg = json.loads(data)
        query_id = msg.get("query_id", "")

        if not query_id:
            await websocket.send_json({"error": "query_id required"})
            await websocket.close()
            return

        # Poll and stream events until response_generated
        last_count = 0
        max_polls = 60  # max 30 seconds
        for _ in range(max_polls):
            events = event_logger.get_events(query_id)
            if len(events) > last_count:
                await websocket.send_json({
                    "query_id": query_id,
                    "events": [e.to_dict() for e in events],
                })
                last_count = len(events)

                # Check if done
                if events[-1].event_type == "response_generated":
                    break

            await asyncio.sleep(0.5)

    except WebSocketDisconnect:
        pass
    except Exception:
        pass


# ── Dashboard HTML ─────────────────────────────────────────────────


DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GeekBrain AI — Observability Dashboard</title>
    <style>
        :root {
            --bg: #0f1117;
            --surface: #1a1d27;
            --surface2: #22262f;
            --border: #2d3240;
            --text: #e4e6eb;
            --muted: #8b8fa3;
            --accent: #6c63ff;
            --green: #22c55e;
            --orange: #f59e0b;
            --purple: #a855f7;
            --red: #ef4444;
            --blue: #3b82f6;
            --cyan: #06b6d4;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg);
            color: var(--text);
            line-height: 1.6;
        }

        /* ── Header ─────────────────────────────── */
        header {
            background: linear-gradient(135deg, #1a1d27 0%, #0f1117 100%);
            border-bottom: 1px solid var(--border);
            padding: 20px 32px;
            display: flex;
            align-items: center;
            gap: 16px;
        }
        header h1 {
            font-size: 1.3em;
            font-weight: 600;
            background: linear-gradient(135deg, var(--accent), var(--cyan));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        header .badge {
            background: var(--surface2);
            border: 1px solid var(--border);
            padding: 4px 12px;
            border-radius: 999px;
            font-size: 0.75em;
            color: var(--muted);
        }
        .status-dot {
            display: inline-block;
            width: 8px; height: 8px;
            border-radius: 50%;
            background: var(--green);
            margin-right: 6px;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.4; }
        }

        /* ── Layout ─────────────────────────────── */
        .container {
            display: grid;
            grid-template-columns: 340px 1fr;
            height: calc(100vh - 69px);
        }

        /* ── Sidebar ────────────────────────────── */
        .sidebar {
            background: var(--surface);
            border-right: 1px solid var(--border);
            overflow-y: auto;
            padding: 16px;
        }
        .sidebar h2 {
            font-size: 0.85em;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: var(--muted);
            margin-bottom: 12px;
        }
        .query-card {
            background: var(--surface2);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 12px;
            margin-bottom: 8px;
            cursor: pointer;
            transition: all 0.2s;
        }
        .query-card:hover { border-color: var(--accent); transform: translateX(2px); }
        .query-card.active { border-color: var(--accent); background: rgba(108, 99, 255, 0.08); }
        .query-card .q-text {
            font-size: 0.85em;
            font-weight: 500;
            margin-bottom: 6px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .query-card .q-meta {
            display: flex;
            gap: 8px;
            font-size: 0.7em;
            color: var(--muted);
        }
        .q-meta .level-badge {
            padding: 2px 6px;
            border-radius: 4px;
            font-weight: 600;
            font-size: 0.9em;
        }
        .level-badge.L1 { background: rgba(34,197,94,0.15); color: var(--green); }
        .level-badge.L2 { background: rgba(59,130,246,0.15); color: var(--blue); }
        .level-badge.L3 { background: rgba(245,158,11,0.15); color: var(--orange); }
        .level-badge.L4 { background: rgba(168,85,247,0.15); color: var(--purple); }

        /* ── Main Panel ─────────────────────────── */
        .main {
            overflow-y: auto;
            padding: 24px 32px;
        }
        .main h2 { font-size: 1.1em; margin-bottom: 20px; }
        .empty-state {
            text-align: center;
            padding: 80px 20px;
            color: var(--muted);
        }
        .empty-state .icon { font-size: 3em; margin-bottom: 12px; }

        /* ── Event Timeline ─────────────────────── */
        .timeline { position: relative; padding-left: 32px; }
        .timeline::before {
            content: '';
            position: absolute;
            left: 11px;
            top: 0;
            bottom: 0;
            width: 2px;
            background: var(--border);
        }
        .event {
            position: relative;
            margin-bottom: 16px;
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 16px;
            transition: all 0.3s;
            animation: fadeIn 0.4s ease-out;
        }
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(8px); }
            to   { opacity: 1; transform: translateY(0); }
        }
        .event::before {
            content: '';
            position: absolute;
            left: -27px;
            top: 20px;
            width: 12px;
            height: 12px;
            border-radius: 50%;
            border: 2px solid var(--border);
            background: var(--bg);
        }

        /* Event type colors */
        .event.query_received    { border-left: 3px solid var(--blue); }
        .event.query_received::before    { border-color: var(--blue); background: var(--blue); }
        .event.retrieval_completed { border-left: 3px solid var(--green); }
        .event.retrieval_completed::before { border-color: var(--green); background: var(--green); }
        .event.tool_executed     { border-left: 3px solid var(--orange); }
        .event.tool_executed::before     { border-color: var(--orange); background: var(--orange); }
        .event.llm_invoked       { border-left: 3px solid var(--purple); }
        .event.llm_invoked::before       { border-color: var(--purple); background: var(--purple); }
        .event.memory_loaded     { border-left: 3px solid var(--cyan); }
        .event.memory_loaded::before     { border-color: var(--cyan); background: var(--cyan); }
        .event.response_generated { border-left: 3px solid var(--red); }
        .event.response_generated::before { border-color: var(--red); background: var(--red); }

        .event .ev-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 8px;
        }
        .event .ev-type {
            font-weight: 600;
            font-size: 0.85em;
            text-transform: uppercase;
            letter-spacing: 0.04em;
        }
        .event .ev-time { font-size: 0.7em; color: var(--muted); }
        .event .ev-body { font-size: 0.85em; }
        .event .ev-body pre {
            background: var(--bg);
            padding: 10px;
            border-radius: 6px;
            overflow-x: auto;
            font-size: 0.9em;
            margin-top: 6px;
            color: var(--cyan);
        }

        .chunk-card {
            background: var(--bg);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 10px;
            margin: 6px 0;
            font-size: 0.82em;
        }
        .chunk-card .source { color: var(--green); font-weight: 600; }
        .chunk-card .score { color: var(--muted); float: right; }

        .tool-badge {
            display: inline-block;
            background: rgba(245,158,11,0.15);
            color: var(--orange);
            padding: 2px 8px;
            border-radius: 4px;
            font-weight: 600;
            font-size: 0.85em;
        }
        .proc-time {
            display: inline-block;
            background: rgba(239,68,68,0.12);
            color: var(--red);
            padding: 4px 12px;
            border-radius: 6px;
            font-weight: 700;
            font-size: 1.1em;
        }

        /* ── Refresh button ─────────────────────── */
        .refresh-btn {
            background: var(--accent);
            color: white;
            border: none;
            padding: 8px 16px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.8em;
            float: right;
            transition: background 0.2s;
        }
        .refresh-btn:hover { background: #5b54e0; }
    </style>
</head>
<body>
    <header>
        <h1>🧠 GeekBrain AI — Observability</h1>
        <span class="badge"><span class="status-dot"></span>Live</span>
    </header>

    <div class="container">
        <div class="sidebar">
            <h2>Recent Queries</h2>
            <div id="query-list">
                <div class="empty-state" style="padding:40px 10px;">
                    <div class="icon">📭</div>
                    <p>No queries yet.<br>Send a query to the API to see events.</p>
                </div>
            </div>
        </div>
        <div class="main" id="main-panel">
            <div class="empty-state">
                <div class="icon">🔍</div>
                <p>Select a query from the sidebar to view its processing pipeline.</p>
            </div>
        </div>
    </div>

    <script>
        const API = window.location.origin;
        let activeQueryId = null;
        let refreshInterval = null;

        // ── Fetch and render query list ─────────
        async function loadQueries() {
            try {
                const res = await fetch(`${API}/api/queries`);
                const data = await res.json();
                const list = document.getElementById('query-list');

                if (!data.queries || data.queries.length === 0) {
                    list.innerHTML = '<div class="empty-state" style="padding:40px 10px;"><div class="icon">📭</div><p>No queries yet.</p></div>';
                    return;
                }

                list.innerHTML = data.queries.map(q => `
                    <div class="query-card ${q.query_id === activeQueryId ? 'active' : ''}"
                         onclick="selectQuery('${q.query_id}')">
                        <div class="q-text">${escapeHtml(q.query)}</div>
                        <div class="q-meta">
                            <span class="level-badge ${q.level}">${q.level}</span>
                            <span>${q.processing_time_ms ? q.processing_time_ms.toFixed(0) + 'ms' : '...'}</span>
                            <span>${q.tools_used.length > 0 ? '🔧' + q.tools_used.length : ''}</span>
                        </div>
                    </div>
                `).join('');
            } catch (e) {
                console.error('Failed to load queries:', e);
            }
        }

        // ── Load & render events for a query ────
        async function selectQuery(queryId) {
            activeQueryId = queryId;
            loadQueries();  // update active state

            try {
                const res = await fetch(`${API}/api/query/${queryId}`);
                const data = await res.json();
                renderEvents(data.query_id, data.events);
            } catch (e) {
                console.error('Failed to load query details:', e);
            }
        }

        function renderEvents(queryId, events) {
            const panel = document.getElementById('main-panel');

            if (!events || events.length === 0) {
                panel.innerHTML = '<div class="empty-state"><div class="icon">⏳</div><p>No events yet for this query.</p></div>';
                return;
            }

            let html = `<h2>Pipeline: ${queryId} <button class="refresh-btn" onclick="selectQuery('${queryId}')">↻ Refresh</button></h2>`;
            html += '<div class="timeline">';

            events.forEach(e => {
                html += `<div class="event ${e.event_type}">`;
                html += `<div class="ev-header">
                    <span class="ev-type">${formatType(e.event_type)}</span>
                    <span class="ev-time">${new Date(e.timestamp).toLocaleTimeString()}</span>
                </div>`;
                html += `<div class="ev-body">${renderEventBody(e)}</div>`;
                html += '</div>';
            });

            html += '</div>';
            panel.innerHTML = html;
        }

        function renderEventBody(e) {
            const d = e.data;
            switch (e.event_type) {
                case 'query_received':
                    return `<strong>Query:</strong> "${escapeHtml(d.query)}"<br>
                            <strong>Level:</strong> <span class="level-badge ${d.level}">${d.level}</span>
                            ${d.session_id ? '<br><strong>Session:</strong> ' + d.session_id : ''}`;

                case 'retrieval_completed':
                    let chunks = `<strong>Retrieved ${d.num_chunks} chunks:</strong>`;
                    (d.chunks || []).forEach(c => {
                        chunks += `<div class="chunk-card">
                            <span class="source">📄 ${escapeHtml(c.source)}</span>
                            <span class="score">score: ${c.score}</span>
                            <br>${escapeHtml(c.text)}
                        </div>`;
                    });
                    return chunks;

                case 'tool_executed':
                    return `<span class="tool-badge">🔧 ${escapeHtml(d.tool_name)}</span>
                            <pre>${escapeHtml(JSON.stringify(d.parameters, null, 2))}</pre>
                            <strong>${d.success ? '✅' : '❌'} Result:</strong>
                            <pre>${escapeHtml(d.result)}</pre>`;

                case 'llm_invoked':
                    return `<strong>Model:</strong> ${escapeHtml(d.model_id || 'Claude')}<br>
                            <strong>Prompt length:</strong> ${d.prompt_length} chars<br>
                            ${d.response_preview ? '<strong>Preview:</strong> ' + escapeHtml(d.response_preview) : ''}`;

                case 'memory_loaded':
                    return `<strong>Session:</strong> ${escapeHtml(d.session_id)}<br>
                            <strong>History turns loaded:</strong> ${d.num_turns}`;

                case 'response_generated':
                    return `<strong>Final Answer:</strong><br>${escapeHtml(d.response)}<br><br>
                            <span class="proc-time">⏱ ${d.processing_time_ms.toFixed(0)}ms</span>
                            ${d.tools_used.length > 0 ? '<br><strong>Tools:</strong> ' + d.tools_used.map(t => '<span class="tool-badge">' + t + '</span>').join(' ') : ''}`;

                default:
                    return `<pre>${escapeHtml(JSON.stringify(d, null, 2))}</pre>`;
            }
        }

        function formatType(t) {
            const icons = {
                query_received: '📥 Query Received',
                retrieval_completed: '📚 Retrieval Completed',
                tool_executed: '🔧 Tool Executed',
                llm_invoked: '🧠 LLM Invoked',
                memory_loaded: '💾 Memory Loaded',
                response_generated: '✅ Response Generated'
            };
            return icons[t] || t;
        }

        function escapeHtml(str) {
            if (!str) return '';
            return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }

        // ── Auto-refresh ────────────────────────
        loadQueries();
        refreshInterval = setInterval(() => {
            loadQueries();
            if (activeQueryId) selectQuery(activeQueryId);
        }, 3000);
    </script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
async def get_dashboard():
    """Serve the observability dashboard UI."""
    return DASHBOARD_HTML


if __name__ == "__main__":
    port = int(os.getenv("DASHBOARD_PORT", "8002"))
    print(f"🔍 Observability Dashboard starting on http://localhost:{port}")
    print(f"   Main API events source: event_logger singleton")
    uvicorn.run(app, host="0.0.0.0", port=port)
