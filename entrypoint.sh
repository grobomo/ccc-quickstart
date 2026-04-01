#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Worker Entrypoint
# =============================================================================
# Runs a simple HTTP API that accepts tasks and dispatches them to Claude Code.
# =============================================================================

WORKER_ID="${WORKER_ID:-$(hostname)}"
FLEET_NAME="${FLEET_NAME:-ccc-fleet}"
PORT="${PORT:-8080}"
TASK_DIR="/home/worker/tasks"
LOG_DIR="/home/worker/logs"

mkdir -p "$TASK_DIR" "$LOG_DIR"

# Validate API key
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "[ERROR] ANTHROPIC_API_KEY not set"
  exit 1
fi

# Clone repo if configured
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPO:-}" ]]; then
  if [[ ! -d "/home/worker/repo" ]]; then
    echo "[INFO] Cloning $GITHUB_REPO..."
    git clone "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git" /home/worker/repo
  fi
fi

# Simple HTTP server using node
cat > /home/worker/server.js << 'SERVERJS'
const http = require('http');
const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 8080;
const WORKER_ID = process.env.WORKER_ID || require('os').hostname();
const TASK_DIR = '/home/worker/tasks';
const LOG_DIR = '/home/worker/logs';

let tasksCompleted = 0;
let tasksRunning = 0;
let taskQueue = [];
const startTime = Date.now();

function uptime() {
  const secs = Math.floor((Date.now() - startTime) / 1000);
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  return `${h}h ${m}m`;
}

function runTask(task) {
  const taskId = `task-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const taskFile = path.join(TASK_DIR, `${taskId}.json`);
  const logFile = path.join(LOG_DIR, `${taskId}.log`);

  fs.writeFileSync(taskFile, JSON.stringify({ ...task, id: taskId, status: 'running', startedAt: new Date().toISOString() }));
  tasksRunning++;

  const cwd = task.repo ? '/home/worker/repo' : '/home/worker';
  const proc = spawn('claude', ['-p', task.prompt, '--output-format', 'json'], {
    cwd,
    env: { ...process.env, ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stdout = '', stderr = '';
  proc.stdout.on('data', d => { stdout += d; });
  proc.stderr.on('data', d => { stderr += d; });

  proc.on('close', code => {
    tasksRunning--;
    tasksCompleted++;
    const result = { ...task, id: taskId, status: code === 0 ? 'completed' : 'failed', exitCode: code,
                     stdout, stderr, completedAt: new Date().toISOString() };
    fs.writeFileSync(taskFile, JSON.stringify(result, null, 2));
    fs.writeFileSync(logFile, `STDOUT:\n${stdout}\n\nSTDERR:\n${stderr}`);
  });

  return taskId;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  res.setHeader('Content-Type', 'application/json');

  // Health check
  if (url.pathname === '/health' || url.pathname === '/api/health') {
    res.end(JSON.stringify({
      status: 'healthy',
      worker_id: WORKER_ID,
      tasks_completed: tasksCompleted,
      tasks_running: tasksRunning,
      tasks_queued: taskQueue.length,
      uptime: uptime(),
      workers: [{ id: WORKER_ID, status: 'healthy', tasks_completed: tasksCompleted, uptime: uptime() }],
    }));
    return;
  }

  // Submit task
  if ((url.pathname === '/submit' || url.pathname === '/api/submit') && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const task = JSON.parse(body);
        if (!task.prompt) {
          res.statusCode = 400;
          res.end(JSON.stringify({ error: 'Missing "prompt" field' }));
          return;
        }
        const taskId = runTask(task);
        res.end(JSON.stringify({ task_id: taskId, status: 'submitted' }));
      } catch (e) {
        res.statusCode = 400;
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  // Task status
  if (url.pathname.startsWith('/api/status/') || url.pathname.startsWith('/status/')) {
    const taskId = url.pathname.split('/').pop();
    const taskFile = path.join(TASK_DIR, `${taskId}.json`);
    if (fs.existsSync(taskFile)) {
      res.end(fs.readFileSync(taskFile, 'utf-8'));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'Task not found' }));
    }
    return;
  }

  // List tasks
  if (url.pathname === '/api/status' || url.pathname === '/status') {
    const tasks = fs.readdirSync(TASK_DIR).filter(f => f.endsWith('.json')).map(f => {
      return JSON.parse(fs.readFileSync(path.join(TASK_DIR, f), 'utf-8'));
    });
    res.end(JSON.stringify({ tasks }));
    return;
  }

  res.statusCode = 404;
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, () => {
  console.log(`[CCC Worker ${WORKER_ID}] listening on port ${PORT}`);
});
SERVERJS

echo "[INFO] Starting CCC worker $WORKER_ID on port $PORT"
exec node /home/worker/server.js
