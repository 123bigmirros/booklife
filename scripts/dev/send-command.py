#!/usr/bin/env python3
"""Manual receiver test; prompts for the pairing secret, never retries page turns."""
import argparse
import base64
import getpass
import hashlib
import hmac
import ipaddress
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

parser = argparse.ArgumentParser(description="测试 BookSlide Mac 接收端。请先打开 Books 阅读窗口。")
parser.add_argument("address", help="开发诊断用局域网地址，例如 http://my-mac.local:8765")
parser.add_argument("action", choices=["status", "next", "previous"])
parser.add_argument("--delay", type=float, default=0, help="发送前等待秒数，留出切回 Books 的时间")
args = parser.parse_args()
url = urllib.parse.urlsplit(args.address)
try:
    local = ipaddress.ip_address(url.hostname).is_private
except ValueError:
    local = (url.hostname or "").endswith(".local")
if url.scheme != "http" or not local or not url.port or url.username or url.password or url.query or url.fragment:
    parser.error("请输入接收端的局域网 HTTP 地址和端口")
token = getpass.getpass("开发诊断密钥（不是六位核对数字，输入不回显）: ").strip()
if args.delay:
    print(f"请切回 Apple Books，将在 {args.delay:g} 秒后发送。", flush=True)
    time.sleep(max(0, args.delay))
body = None if args.action == "status" else json.dumps({
    "id": str(uuid.uuid4()), "direction": args.action, "sentAt": time.time()
}).encode()
path = "/v1/status" if body is None else "/v1/turn"
method = "GET" if body is None else "POST"
timestamp = str(int(time.time()))
nonce = str(uuid.uuid4())
digest = base64.b64encode(hashlib.sha256(body or b"").digest()).decode()
canonical = f"BookSlide/v2\n{method}\n{path}\n{timestamp}\n{nonce}\n{digest}".encode()
signature = base64.b64encode(hmac.digest(token.encode(), canonical, "sha256")).decode()
request = urllib.request.Request(args.address.rstrip("/") + path, data=body, headers={
    "Content-Type": "application/json", "X-BookSlide-Time": timestamp,
    "X-BookSlide-Nonce": nonce, "X-BookSlide-Signature": signature})

def read_verified(response):
    payload = response.read()
    canonical = f"BookSlide/response/v2\n{response.code}\n{nonce}\n".encode() + payload
    expected = base64.b64encode(hmac.digest(token.encode(), canonical, "sha256")).decode()
    if not hmac.compare_digest(expected, response.headers.get("X-BookSlide-Signature", "")):
        raise SystemExit("无法验证 Mac 响应，请检查配对信息和设备时间。")
    return json.loads(payload)["message"]
try:
    with urllib.request.urlopen(request, timeout=4) as response:
        print(read_verified(response))
except urllib.error.HTTPError as error:
    print(f"HTTP {error.code}: {read_verified(error)}")
    raise SystemExit(1)
except urllib.error.URLError:
    print("未收到确认，请检查书页和接收端状态；不会自动重试。")
    raise SystemExit(1)
