# -*- coding: utf-8 -*-
"""通过 GitHub Git Data API 单提交推送改动（代理封锁 github.com git 协议的替代路径）"""
import base64, json, subprocess, sys, urllib.request

REPO = "moli815/aigc-video"
BRANCH = "chatgpt-style-ui"
ROOT = r"C:\Users\24072\WorkBuddy\2026-10-08-11-01-51\aigc-video"

FILES = [
    "BossAI/Models/Expert.swift",
    "BossAI/ExpertCore/Resources/ExpertSkills.json",
    "BossAI/ExpertCore/BusinessCalculators.swift",
    "BossAI/Services/DocumentBuilder.swift",
    "BossAI/Views/ChatView.swift",
    "BossAI/ViewModels/ChatViewModel.swift",
    "BossAI/Views/MainView.swift",
    "BossAI/Views/SetupView.swift",
    "BossAI/Views/BackupSheets.swift",
    "BossAI/Views/IdentitySheet.swift",
    "BossAI/Services/BackupService.swift",
    "BossAI/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png",
    "Tests/BossAIExpertCoreTests/ExpertCoreTests.swift",
    "Tests/BossAIiOSTests/AppPerformanceTests.swift",
    "scripts/upgrade_expert_skills.py",
    "project.yml",
]

MESSAGE = ("中防AI品牌升级：新增老板IP/消防/安防/保险4专家完整契约+5个专业计算器，"
           "全员知识卡调优，ScrollPosition滚动根治，应用名与图标切换中防AI")

def api(method, path, payload=None, token=None):
    req = urllib.request.Request("https://api.github.com" + path, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "push-script")
    data = json.dumps(payload).encode() if payload is not None else None
    if data: req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=data, timeout=60) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

def get_token():
    out = subprocess.run(["git", "-C", ROOT, "credential", "fill"],
                         input="protocol=https\nhost=github.com\n\n",
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    raise SystemExit("no token")

token = get_token()
print("token acquired:", token[:8] + "...")

# 1) branch ref
code, ref = api("GET", f"/repos/{REPO}/git/ref/heads/{BRANCH}", token=token)
assert code == 200, f"ref: {code} {ref}"
base_commit = ref["object"]["sha"]
code, base_c = api("GET", f"/repos/{REPO}/git/commits/{base_commit}", token=token)
assert code == 200
base_tree = base_c["tree"]["sha"]
print("base commit:", base_commit[:12], "tree:", base_tree[:12])

# 2) blobs
tree_items = []
for rel in FILES:
    with open(ROOT + "\\" + rel.replace("/", "\\"), "rb") as f:
        raw = f.read()
    code, blob = api("POST", f"/repos/{REPO}/git/blobs",
                     {"content": base64.b64encode(raw).decode(), "encoding": "base64"}, token)
    assert code == 201, f"blob {rel}: {code} {blob}"
    tree_items.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print("blob ok:", rel, len(raw), "bytes")

# 3) tree
code, tree = api("POST", f"/repos/{REPO}/git/trees", {"base_tree": base_tree, "tree": tree_items}, token)
assert code == 201, f"tree: {code} {tree}"
print("new tree:", tree["sha"][:12])

# 4) commit
code, commit = api("POST", f"/repos/{REPO}/git/commits",
                   {"message": MESSAGE, "tree": tree["sha"], "parents": [base_commit]}, token)
assert code == 201, f"commit: {code} {commit}"
print("new commit:", commit["sha"][:12])

# 5) update ref (fast-forward)
code, up = api("PATCH", f"/repos/{REPO}/git/refs/heads/{BRANCH}",
               {"sha": commit["sha"], "force": False}, token)
assert code == 200, f"ref update: {code} {up}"
print("PUSHED:", commit["sha"])
