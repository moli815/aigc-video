// GitHub Git Data transport for this repository's restricted network. Publishes
// committed bytes only, verifies the complete tree/SHA and never force-pushes.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
const git = (...args) => execFileSync("git", args, { maxBuffer: 40 * 1024 * 1024 });
const line = (...args) => git(...args).toString("utf8").trim();
const repo = "moli815/aigc-video";
const branch = process.argv[2];
const runner = process.argv[3] || "macos-15";
if (!["macos-15", "macos-15-intel"].includes(runner)) throw new Error("Unsupported hosted runner");
if (!branch?.startsWith("codex/")) throw new Error("Only explicit codex/ branches are accepted");
if (line("status", "--porcelain")) throw new Error("Commit all intended changes first");
if (!line("remote", "get-url", "origin").includes(repo)) throw new Error("Unexpected repository");
const keyFile = path.join(process.env.USERPROFILE, ".workbuddy", "gh-pat-aigc-video.txt");
const token = fs.readFileSync(keyFile, "utf8").trim();
async function api(endpoint, body, method = body ? "POST" : "GET") {
  const response = await fetch(`https://api.github.com/repos/${repo}/${endpoint}`, {
    method, headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "Content-Type": "application/json" },
    ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(45000),
  });
  if (!response.ok) throw new Error(`GitHub ${response.status} for ${endpoint}`);
  return response.status === 204 ? {} : response.json();
}
const head = line("rev-parse", "HEAD"), parent = line("rev-parse", "HEAD^");
const remoteParent = await api(`git/commits/${parent}`);
if (remoteParent.tree.sha !== line("rev-parse", `${parent}^{tree}`)) throw new Error("Parent tree mismatch");
const changes = git("diff", "--name-status", "--no-renames", "-z", parent, head).toString("utf8").split("\0");
const tree = [];
for (let i = 0; i < changes.length - 1; i += 2) {
  const status = changes[i], file = changes[i + 1];
  if (status === "D") { tree.push({ path: file, mode: "100644", type: "blob", sha: null }); continue; }
  const mode = line("ls-tree", head, "--", file).split(" ")[0];
  const blob = await api("git/blobs", { content: git("cat-file", "blob", `${head}:${file}`).toString("base64"), encoding: "base64" });
  if (blob.sha !== line("rev-parse", `${head}:${file}`)) throw new Error(`Blob mismatch: ${file}`);
  tree.push({ path: file, mode, type: "blob", sha: blob.sha });
}
const remoteTree = await api("git/trees", { base_tree: remoteParent.tree.sha, tree });
if (remoteTree.sha !== line("rev-parse", `${head}^{tree}`)) throw new Error("Final tree mismatch");
const raw = git("cat-file", "commit", head).toString("utf8"), split = raw.indexOf("\n\n");
function identity(name) {
  const match = raw.slice(0, split).match(new RegExp(`^${name} (.*) <([^>]+)> (\\d+) ([+-]\\d{4})$`, "m"));
  if (!match || match[4] !== "+0000") throw new Error("Transport requires a UTC-dated commit");
  return { name: match[1], email: match[2], date: new Date(Number(match[3]) * 1000).toISOString() };
}
const remoteCommit = await api("git/commits", { message: raw.slice(split + 2), tree: remoteTree.sha,
  parents: [parent], author: identity("author"), committer: identity("committer") });
if (remoteCommit.sha !== head) throw new Error("Commit SHA mismatch");
let existing;
try { existing = await api(`git/ref/heads/${branch}`); } catch (error) {
  if (!error.message.startsWith("GitHub 404")) throw error;
}
if (existing) {
  if (existing.object.sha !== parent && existing.object.sha !== head) throw new Error("Remote branch moved; refusing overwrite");
  if (existing.object.sha !== head) await api(`git/refs/heads/${branch}`, { sha: head, force: false }, "PATCH");
} else { await api("git/refs", { ref: `refs/heads/${branch}`, sha: head }); }
git("update-ref", `refs/remotes/origin/${branch}`, head);
await api("actions/workflows/build-ipa.yml/dispatches", { ref: branch, inputs: { macos_runner: runner } });
process.stdout.write(JSON.stringify({ branch, head, tree: remoteTree.sha, runner, dispatched: true }) + "\n");
