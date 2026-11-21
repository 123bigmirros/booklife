#!/usr/bin/env python3
"""Loopback Chat Completions bridge to the signed-in Codex CLI (GPT-6-Luna).

For a physical iPhone or iPad, expose the loopback endpoint through an HTTPS
reverse proxy and set BOOKSLIDE_LUNA_BRIDGE_TOKEN before starting this script.
"""
import argparse
import hmac
import json
import os
import re
import shutil
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    fixture_only = False
    fixture_answers = set()
    token = ""
    def log_message(self, *_):
        pass  # Source passages and credentials must never enter HTTP logs.

    @staticmethod
    def failure_status(transcript):
        for line in reversed(transcript.splitlines()):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "turn.failed":
                message = event.get("error", {}).get("message", "")
            elif event.get("type") == "error":
                message = event.get("message", "")
            else:
                continue
            message = message.lower()
            status = re.search(r"\bstatus ([45]\d\d)", message)
            if status:
                return int(status[1])
            if "usage limit" in message or "rate limit" in message:
                return 429
            if any(pattern in message for pattern in (
                "disconnected", "connection", "timed out", "error sending request", "not logged in", "login required"
            )):
                return 502
            return 422
        return 502

    def do_POST(self):
        if self.path != "/chat/completions":
            self.send_error(404)
            return
        if self.token and not hmac.compare_digest(
            self.headers.get("Authorization", "").encode(), f"Bearer {self.token}".encode()
        ):
            self.send_error(401)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 256_000:
                raise ValueError("Invalid request size")
            body = json.loads(self.rfile.read(size))
            messages = body["messages"]
            if (not isinstance(messages, list) or not messages
                or not all(isinstance(m, dict) and isinstance(m.get("content"), str)
                           and m.get("role") in {"system", "user", "assistant"} for m in messages)):
                raise ValueError("Invalid messages")
            if self.fixture_only:
                # Only fixed, original test data is ever forwarded in this mode.
                # Neither caller-supplied system instructions nor book materials
                # reach Codex. Follow-up answers must originate in this process.
                questions = ["请只用一句话，解释选文中信息与判断的关系，并标明依据。",
                             "基于刚才的解释，给一个日常生活中的小例子，用一句话。"]
                history = messages[2:]
                if not history or history[-1].get("content") not in questions:
                    raise ValueError("Only fixed test questions are accepted")
                safe_history = []
                for message in history:
                    text = message["content"]
                    if message.get("role") == "user" and text in questions:
                        safe_history.append({"role":"user", "content":questions[questions.index(text)]})
                    elif message.get("role") == "assistant" and text in self.fixture_answers:
                        safe_history.append({"role":"assistant", "content":text})
                    else:
                        raise ValueError("Only fixed test history is accepted")
                messages = [{"role":"system", "content":"你是阅读伙伴，用中文简明回答。引用原文标记 [原文]，引用附近正文标记 [附近正文]。区分推断与原文。"},
                            {"role":"user", "content":"以下均为 BookSlide 原创测试材料。书名：判断与信息。作者：测试。[原文] 更多信息未必带来更好的判断。[附近正文] 信息需要经过思考才能用于决策。[我的笔记] 要为判断留出空间。"}] + safe_history
            prompt = ("You are a book-reading and translation assistant. Use no tools. Follow the system message "
                      "and answer the final user message in this JSON conversation:\n" + json.dumps(messages, ensure_ascii=False))
            executable = shutil.which("codex")
            if not executable:
                raise RuntimeError("Codex CLI is unavailable")
            with tempfile.TemporaryDirectory(prefix="bookslide-codex-") as folder:
                output = Path(folder) / "answer"
                result = subprocess.run([executable, "exec", "--model", "gpt-6-luna", "--ephemeral", "--ignore-user-config",
                                         "--skip-git-repo-check", "--sandbox", "read-only",
                                         "-c", "features.shell_tool=false", "-c", "features.multi_agent=false",
                                         "-c", 'web_search="disabled"', "-c", "apps._default.enabled=false",
                                         "-c", "project_doc_max_bytes=0",
                                         "--json", "--output-last-message", str(output), "--cd", folder, "-"],
                                        input=prompt, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=50)
                if result.returncode:
                    self.send_error(self.failure_status(result.stdout), "Codex Luna could not answer")
                    return
                answer = output.read_text(encoding="utf-8") if output.exists() else ""
            if not answer.strip():
                self.send_error(422, "Codex Luna returned an empty answer")
                return
            if self.fixture_only:
                self.fixture_answers.add(answer)
        except (ValueError, KeyError, TypeError):
            self.send_error(400, "Invalid chat request")
            return
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            self.send_error(502, "Local Codex failed or timed out")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for offset in range(0, len(answer), 24):
                self.event({"choices": [{"delta": {"content": answer[offset:offset + 24]}, "finish_reason": None}]})
            self.event({"choices": [{"delta": {}, "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value, ensure_ascii=False) + "\n\n").encode())
        self.wfile.flush()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--fixture-only", action="store_true", help="Forward only hardcoded original fixtures; reject arbitrary questions/history")
    args = parser.parse_args()
    Handler.fixture_only = args.fixture_only
    Handler.token = os.environ.pop("BOOKSLIDE_LUNA_BRIDGE_TOKEN", "")
    print(f"Codex Luna bridge: http://127.0.0.1:{args.port}/chat/completions", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
