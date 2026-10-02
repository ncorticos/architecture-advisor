#!/usr/bin/env python3
"""Stand-in for the HTTP services the engine talks to.

  GET  /hotspot                 Apple's connectivity check ("Success" when online)
  POST /v1/messages             Claude API
  POST /zen/v1/responses        OpenCode Zen (Responses API, SSE): Muse Spark
  POST /zen/v1/chat/completions OpenCode Zen (chat completions, SSE): LongCat — 429 unless set
  GET  /api/v1/models           LM Studio model list      (503 while STATE/lms_down exists)
  POST /api/v1/chat             LM Studio native chat
  POST /v1/chat/completions     LM Studio OpenAI-compatible chat

Answers come from STATE/scenario.json, read on every request. A value may be a list: the
n-th request to that endpoint gets the n-th item (the last one repeats). Every request is
appended to STATE/requests.jsonl. The chosen port is written to STATE/port.
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = sys.argv[1]
os.makedirs(STATE, exist_ok=True)
LOCK = threading.Lock()


def scenario():
    try:
        with open(os.path.join(STATE, "scenario.json")) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def requests_to(path):
    try:
        with open(os.path.join(STATE, "requests.jsonl")) as f:
            return sum(1 for line in f if json.loads(line)["path"] == path)
    except FileNotFoundError:
        return 0


def pick(key, path, default):
    value = scenario().get(key, default)
    if isinstance(value, list):
        index = min(requests_to(path) - 1, len(value) - 1)
        value = value[max(index, 0)]
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def record(self, body):
        with LOCK, open(os.path.join(STATE, "requests.jsonl"), "a") as f:
            headers = {k.lower(): v for k, v in self.headers.items()}
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "headers": headers, "body": body}) + "\n")

    def reply(self, status, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.record(None)
        online = scenario().get("online", True)
        if self.path == "/hotspot":
            if online:
                return self.reply(200, "<HTML><BODY>Success</BODY></HTML>", "text/html")
            return self.reply(503, "offline", "text/plain")
        if self.path == "/" and not online:
            self.close_connection = True   # no answer at all, like a dead network
            return
        if self.path in ("/api/v1/models", "/v1/models"):
            if os.path.exists(os.path.join(STATE, "lms_down")):
                return self.reply(503, {"error": "server not running"})
            models = scenario().get("lms_models", {"models": []})
            if self.path == "/v1/models":
                models = {"data": [{"id": m["key"]} for m in models.get("models", [])]}
            return self.reply(200, models)
        return self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = raw
        self.record(body)
        if self.path == "/v1/messages":
            r = pick("anthropic", self.path, {"status": 500, "body": {}})
        elif self.path == "/zen/v1/responses":
            r = pick("zen", self.path, {"status": 500, "body": {}})
            if "sse" in r and r.get("status", 200) == 200:
                events = "".join("event: %s\ndata: %s\n\n" % (e.get("type", "message"), json.dumps(e))
                                 for e in r["sse"])
                return self.reply(200, events + "data: [DONE]\n\n", "text/event-stream")
        elif self.path == "/zen/v1/chat/completions":
            r = pick("zen_chat", self.path,
                     {"status": 429, "body": {"error": {"message": "Rate limit exceeded for free models"}}})
            if "sse" in r and r.get("status", 200) == 200:
                chunks = "".join("data: %s\n\n" % json.dumps(c) for c in r["sse"])
                return self.reply(200, chunks + "data: [DONE]\n\n", "text/event-stream")
        elif self.path == "/api/v1/chat":
            r = pick("lms_chat", self.path, {"status": 500, "body": {}})
        elif self.path == "/v1/chat/completions":
            r = pick("lms_openai", self.path, {"status": 404, "body": {}})
        else:
            r = {"status": 404, "body": {"error": {"message": "not found"}}}
        return self.reply(r.get("status", 200), r.get("body", {}))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(STATE, "port.tmp"), os.path.join(STATE, "port"))
server.serve_forever()
