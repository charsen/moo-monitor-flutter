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
import json, os, sys, shutil, atexit, hashlib, tempfile, zipfile, subprocess
import urllib.request, urllib.error

# 七牛区域 -> 直传域名：z0 无后缀，其余带区域后缀。未知区域直接报错，不拼错误域名。
QINIU_UPLOAD_HOSTS = {
    "z0": "https://upload.qiniup.com",
    "z1": "https://upload-z1.qiniup.com",
    "z2": "https://upload-z2.qiniup.com",
    "na0": "https://upload-na0.qiniup.com",
    "as0": "https://upload-as0.qiniup.com",
}

# 错误回显时需脱敏的字段名（避免把票据/上传 token 打到日志）。
SENSITIVE_KEYS = ("token", "authorization", "secret", "password")

def fail(msg):
    # 运行期失败（网络/服务端/IO）：exit 1
    print(msg, file=sys.stderr); sys.exit(1)

def usage_fail(msg):
    # 用法/缺参类错误：exit 2（与 Android 上传器约定一致）
    print(msg, file=sys.stderr); sys.exit(2)

def redact(obj):
    """递归把响应里的 token 类字段替换为 ***，供错误信息打印使用。"""
    if isinstance(obj, dict):
        return {k: ("***" if any(s in str(k).lower() for s in SENSITIVE_KEYS) else redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    return obj

def sha256_file(path, chunk=1 << 20):
    """分块计算 sha256，避免把整包读进内存（符号 zip 可能数十 MB）。"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()

if len(sys.argv) < 4:
    usage_fail("用法: MONITOR_TOKEN=<token> tools/upload-symbols.sh <symbols 目录> <release> <build> [endpoint]")
symbols_dir, release, build = sys.argv[1], sys.argv[2], sys.argv[3]
endpoint = (sys.argv[4] if len(sys.argv) > 4 else "https://c.mooeen.com").rstrip("/")
token = os.environ.get("MONITOR_TOKEN", "")
if not token: usage_fail("缺少 MONITOR_TOKEN")
if not os.path.isdir(symbols_dir): usage_fail("找不到符号目录: " + symbols_dir)
# release/build 是云端定位符号的键（release+build，与 context.symbol_id=<version+build> 对齐），必填。
if not release: usage_fail("缺少 release（营销版本号，如 0.0.3）")
if not build: usage_fail("缺少 build（构建号，如 14）")

# 依赖预检：缺命令以可读信息失败，而不是抛 traceback。
for bin in ("curl",):
    if shutil.which(bin) is None: fail("缺少命令: " + bin)

def post_json(url, body_obj, extra_headers=None):
    """POST JSON 并返回解析后的对象。区分网络错误与 HTTP 非 2xx，非 2xx 附带（脱敏后的）响应体。"""
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json", "Accept": "application/json"}
    if extra_headers: headers.update(extra_headers)
    req = urllib.request.Request(url, data=json.dumps(body_obj).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        # 服务端拒绝：把状态码和响应体带出来，便于定位（token 权限/business 不匹配等）。
        body = ""
        try:
            raw = e.read().decode()
            try: body = json.dumps(redact(json.loads(raw)), ensure_ascii=False)
            except ValueError: body = raw
        except Exception: pass
        fail("HTTP %s %s: %s" % (e.code, url, body))
    except Exception as e:
        fail("request failed: %s %s" % (url, e))

# 先 enumerate 文件，空目录直接失败（避免把 22 字节空 zip 上传污染符号库）。
files_to_zip = []
for root, _, files in os.walk(symbols_dir):
    for name in files:
        files_to_zip.append(os.path.join(root, name))
if not files_to_zip:
    fail("符号目录为空，无可上传文件: " + symbols_dir)

tmp = tempfile.mkdtemp(prefix="moo-symbols-")
atexit.register(shutil.rmtree, tmp, True)  # 无论成功/失败都清理 temp zip，避免发布机残留
zip_path = os.path.join(tmp, "flutter-symbols.zip")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    for full in files_to_zip:
        z.write(full, os.path.relpath(full, symbols_dir))
size = os.path.getsize(zip_path)
sha = sha256_file(zip_path)
print("package size=%d sha256=%s files=%d" % (size, sha, len(files_to_zip)))

# 1) 签票据：cloud 登记元信息并签发七牛上传 token，不接收文件字节。
ticket = post_json(endpoint + "/api/v1/uploads/tickets", {
    "business": "app_symbols", "platform": "ios", "release": release, "build": build,
    "kind": "flutter", "original_name": "flutter-symbols.zip", "file_size": size, "sha256": sha,
    "uuids": [],  # Flutter AOT 符号无 LC_UUID；显式空数组与 iOS/Android 上传器保持一致
})
if not ticket.get("ok"): fail("ticket not ok: %s" % json.dumps(redact(ticket), ensure_ascii=False))
upload_id, key, region, qtoken = ticket.get("upload_id"), ticket.get("key"), ticket.get("region"), ticket.get("token")
if not all([upload_id, key, region, qtoken]): fail("ticket missing fields: %s" % json.dumps(redact(ticket), ensure_ascii=False))
host = QINIU_UPLOAD_HOSTS.get(region)
if not host: fail("未知七牛区域: %s（可用: %s）" % (region, ", ".join(QINIU_UPLOAD_HOSTS)))
print("ticket upload_id=%s region=%s host=%s" % (upload_id, region, host))

# 2) 直传七牛：multipart，文件字节只经过本机 -> 七牛，不经过 cloud。显式检查 HTTP 状态。
# --connect-timeout / --max-time 防止上传卡死把发布机挂住（符号包大，max-time 留足）。
proc = subprocess.run(["curl", "-sS", "--connect-timeout", "30", "--max-time", "600", "-w", "\n%{http_code}", "-X", "POST", host,
    "-F", "token=" + qtoken, "-F", "key=" + key, "-F", "file=@" + zip_path + ";type=application/zip"],
    capture_output=True, text=True)
if proc.returncode != 0: fail("qiniu upload failed (network): " + proc.stderr)
# 最后一行是 -w 输出的 HTTP 状态码，前面是响应体。
out = proc.stdout.rsplit("\n", 1)
qbody, qhttp = (out[0], out[1].strip()) if len(out) == 2 else (proc.stdout, "")
if qhttp != "200": fail("qiniu HTTP %s: %s" % (qhttp or "?", qbody))
try:
    qres = json.loads(qbody or "{}")
except ValueError:
    fail("qiniu non-JSON response: %s" % qbody)
if qres.get("error") or not qres.get("key"): fail("qiniu rejected upload: %s" % json.dumps(redact(qres), ensure_ascii=False))
print("qiniu upload ok")

# 3) 确认：云端核验对象大小/SHA-256 后登记符号；Flutter AOT 符号无 LC_UUID，uuids 可空。
confirm = post_json(endpoint + "/api/v1/uploads/" + str(upload_id) + "/confirm", {"uuids": []})
if not confirm.get("ok"): fail("confirm rejected: %s" % json.dumps(redact(confirm), ensure_ascii=False))
print("done: Flutter symbols uploaded and confirmed (upload_id=%s)" % upload_id)
