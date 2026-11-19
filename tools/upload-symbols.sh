#!/usr/bin/env python3
# 上传 Flutter iOS AOT 符号目录到 Moo Cloud 符号库（三步直传，cloud 只签票据，不中转）。
# 属于 moo-monitor 体系的符号上传能力：与本仓 SDK 配套，对所有接入本 SDK 的 Flutter 宿主通用。
# 契约见 moo-scaffold-cloud/docs/QINIU-DIRECT-UPLOAD.md（business=app_symbols, kind=flutter）。
#
# 用法: MONITOR_TOKEN=<token> tools/upload-symbols.sh <symbols 目录> <release> <build> [endpoint]
#   MONITOR_TOKEN  必填，具备 app_errors 或 app_symbols 能力的项目 token（Authorization: Bearer），脚本不打印。
#   <symbols 目录> flutter build ipa --split-debug-info 产出的符号目录。
#   流程: 1) POST /api/v1/uploads/tickets 取 upload_id/key/region/token
#         2) multipart 直传七牛（文件本体不经 cloud）
#         3) POST /api/v1/uploads/{upload_id}/confirm 核验落盘
import json, os, sys, hashlib, tempfile, zipfile, subprocess, urllib.request

def fail(msg):
    print(msg, file=sys.stderr); sys.exit(1)

if len(sys.argv) < 4:
    fail("用法: MONITOR_TOKEN=<token> tools/upload-symbols.sh <symbols 目录> <release> <build> [endpoint]")
symbols_dir, release, build = sys.argv[1], sys.argv[2], sys.argv[3]
endpoint = (sys.argv[4] if len(sys.argv) > 4 else "https://c.mooeen.com").rstrip("/")
token = os.environ.get("MONITOR_TOKEN", "")
if not token: fail("缺少 MONITOR_TOKEN")
if not os.path.isdir(symbols_dir): fail("找不到符号目录: " + symbols_dir)

def post_json(url, body_obj, extra_headers=None):
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json", "Accept": "application/json"}
    if extra_headers: headers.update(extra_headers)
    req = urllib.request.Request(url, data=json.dumps(body_obj).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        fail("request failed: %s %s" % (url, e))

tmp = tempfile.mkdtemp(prefix="moo-symbols-")
zip_path = os.path.join(tmp, "flutter-symbols.zip")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(symbols_dir):
        for name in files:
            full = os.path.join(root, name)
            z.write(full, os.path.relpath(full, symbols_dir))
size = os.path.getsize(zip_path)
sha = hashlib.sha256(open(zip_path, "rb").read()).hexdigest()
print("package size=%d sha256=%s" % (size, sha))

ticket = post_json(endpoint + "/api/v1/uploads/tickets", {
    "business": "app_symbols", "platform": "ios", "release": release, "build": build,
    "kind": "flutter", "original_name": "flutter-symbols.zip", "file_size": size, "sha256": sha,
})
if not ticket.get("ok"): fail("ticket not ok: %r" % ticket)
upload_id, key, region, qtoken = ticket.get("upload_id"), ticket.get("key"), ticket.get("region"), ticket.get("token")
if not all([upload_id, key, region, qtoken]): fail("ticket missing fields: %r" % ticket)
host = "https://upload.qiniup.com" if region == "z0" else "https://upload-%s.qiniup.com" % region
proc = subprocess.run(["curl", "-sS", "-X", "POST", host,
    "-F", "token=" + qtoken, "-F", "key=" + key, "-F", "file=@" + zip_path + ";type=application/zip"],
    capture_output=True, text=True)
if proc.returncode != 0: fail("qiniu upload failed: " + proc.stderr)
qres = json.loads(proc.stdout or "{}")
if qres.get("error") or not qres.get("key"): fail("qiniu error: %r" % qres)
confirm = post_json(endpoint + "/api/v1/uploads/" + str(upload_id) + "/confirm", {})
if not confirm.get("ok"): fail("confirm rejected: %r" % confirm)
print("done: Flutter symbols uploaded and confirmed (upload_id=%s)" % upload_id)
