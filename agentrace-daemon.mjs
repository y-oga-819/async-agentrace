#!/usr/bin/env node
//
// agentrace-daemon.mjs — agentrace-enqueue.sh が投入した queue ファイルを
// 読み、`npx agentrace send` を spawn して送信する常駐プロセス。
//
// 責務:
//   - PID ロックによる単一起動保証
//   - queue を nanos 昇順に直列処理
//   - 失敗時は指数バックオフで retry、上限を超えたら dead_letter へ移動
//   - fs.watch + 定期 readdir の二段構えで取りこぼし救済
//   - SIGTERM/SIGINT でグレースフル停止
//   - ログの 10MB ローテーション
//
// 運用:
//   launchd (~/Library/LaunchAgents/local.agentrace-daemon.plist) 経由で起動。
//   手動: `node ~/.local/bin/agentrace-daemon.mjs`
//
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

export const DEFAULTS = Object.freeze({
  agentraceHome: () => process.env.AGENTRACE_HOME || path.join(os.homedir(), ".agentrace"),
  logOutPath: () => path.join(os.homedir(), "Library", "Logs", "agentrace-daemon.out.log"),
  logErrPath: () => path.join(os.homedir(), "Library", "Logs", "agentrace-daemon.err.log"),
  agentraceCmd: ["npx", "agentrace", "send"],
  maxRetry: 5,
  backoffMs: [1_000, 5_000, 15_000, 60_000, 300_000],
  readdirIntervalMs: 5_000,
  logRotateCheckMs: 60 * 60 * 1_000,
  logRotateMaxBytes: 10 * 1024 * 1024,
});

// ---- PID lock -------------------------------------------------------------

export function acquirePidLock(pidFile) {
  // O_EXCL で排他作成。既存なら持ち主の生存確認。
  try {
    const fd = fs.openSync(pidFile, "wx");
    fs.writeSync(fd, `${process.pid}\n`);
    fs.closeSync(fd);
    return { acquired: true };
  } catch (e) {
    if (e.code !== "EEXIST") throw e;
  }

  let oldPid;
  try {
    oldPid = parseInt(fs.readFileSync(pidFile, "utf8").trim(), 10);
  } catch {
    // 読めない → 壊れているので上書き
    fs.writeFileSync(pidFile, `${process.pid}\n`);
    return { acquired: true, overwrote: true };
  }

  if (!Number.isFinite(oldPid) || oldPid <= 0) {
    fs.writeFileSync(pidFile, `${process.pid}\n`);
    return { acquired: true, overwrote: true };
  }

  if (oldPid === process.pid) {
    // 自分自身 → 再入。既に所有。
    return { acquired: true };
  }

  try {
    process.kill(oldPid, 0); // signal 0: 生存確認のみ
    return { acquired: false, heldBy: oldPid };
  } catch (killErr) {
    if (killErr.code === "ESRCH") {
      // 持ち主は死んでいる → 上書き
      fs.writeFileSync(pidFile, `${process.pid}\n`);
      return { acquired: true, overwrote: true };
    }
    // EPERM など: 他ユーザのプロセスが居る可能性。安全側で諦める。
    return { acquired: false, heldBy: oldPid };
  }
}

export function releasePidLock(pidFile) {
  try {
    const content = fs.readFileSync(pidFile, "utf8").trim();
    const pid = parseInt(content, 10);
    if (pid === process.pid) {
      fs.unlinkSync(pidFile);
      return true;
    }
  } catch {
    // ignore
  }
  return false;
}

// ---- Queue helpers --------------------------------------------------------

export function readQueueFiles(queueDir) {
  let names;
  try {
    names = fs.readdirSync(queueDir);
  } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
  return names
    .filter((n) => n.endsWith(".json") && !n.startsWith(".tmp-"))
    .sort()
    .map((n) => path.join(queueDir, n));
}

// ---- Queue payload --------------------------------------------------------

export function readQueuePayload(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  return JSON.parse(raw);
}

// ---- processOne -----------------------------------------------------------

/**
 * queue ファイルを 1 件処理する。
 * 成功時: ファイルを unlink して { ok: true }
 * 失敗時: { ok: false, exitCode, stderr } （呼び出し側が retry / dead_letter を判断）
 */
export function processOne(filePath, opts = {}) {
  const {
    spawnFn = spawn,
    agentraceCmd = DEFAULTS.agentraceCmd,
    stderrLimit = 4_000,
    timeoutMs = 60_000,
  } = opts;

  return new Promise((resolve) => {
    let payload;
    try {
      payload = readQueuePayload(filePath);
    } catch (e) {
      resolve({ ok: false, exitCode: null, stderr: `parse error: ${e.message}`, fatal: true });
      return;
    }

    const hookInput = payload?.hook_input;
    const projectDir = payload?.claude_project_dir;
    if (!hookInput || !projectDir) {
      resolve({ ok: false, exitCode: null, stderr: "missing hook_input or claude_project_dir", fatal: true });
      return;
    }

    const [cmd, ...args] = agentraceCmd;
    const child = spawnFn(cmd, args, {
      env: { ...process.env, CLAUDE_PROJECT_DIR: projectDir },
      stdio: ["pipe", "ignore", "pipe"],
    });

    let stderrBuf = "";
    child.stderr.on("data", (chunk) => {
      if (stderrBuf.length < stderrLimit) {
        stderrBuf += chunk.toString("utf8").slice(0, stderrLimit - stderrBuf.length);
      }
    });

    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill("SIGTERM"); } catch {}
    }, timeoutMs);

    let settled = false;
    const settle = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };

    child.on("error", (err) => {
      settle({ ok: false, exitCode: null, stderr: `spawn error: ${err.message}` });
    });

    child.on("close", (code, signal) => {
      if (code === 0) {
        try { fs.unlinkSync(filePath); } catch {}
        settle({ ok: true });
      } else {
        const msg = timedOut ? `timeout ${timeoutMs}ms` : (signal ? `signal ${signal}` : `exit ${code}`);
        settle({ ok: false, exitCode: code, stderr: stderrBuf ? `${msg}: ${stderrBuf}` : msg });
      }
    });

    try {
      child.stdin.end(JSON.stringify(hookInput));
    } catch (e) {
      settle({ ok: false, exitCode: null, stderr: `stdin write failed: ${e.message}` });
    }
  });
}

// ---- Dead letter ----------------------------------------------------------

export function moveToDeadLetter(filePath, deadLetterDir, errorHistory) {
  fs.mkdirSync(deadLetterDir, { recursive: true });
  const base = path.basename(filePath);
  const dest = path.join(deadLetterDir, base);
  const metaPath = dest + ".meta.json";
  try {
    fs.renameSync(filePath, dest);
  } catch (e) {
    return { ok: false, error: e.message };
  }
  const meta = {
    moved_at: new Date().toISOString(),
    attempts: errorHistory.length,
    errors: errorHistory,
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  return { ok: true, dest, metaPath };
}

// ---- Log rotation ---------------------------------------------------------

export function rotateLogIfNeeded(logPath, maxBytes) {
  let st;
  try {
    st = fs.statSync(logPath);
  } catch (e) {
    if (e.code === "ENOENT") return false;
    throw e;
  }
  if (st.size < maxBytes) return false;
  const rotated = logPath + ".1";
  try { fs.unlinkSync(rotated); } catch {}
  fs.renameSync(logPath, rotated);
  // launchd が StandardOutPath で open しているが、再オープンは launchd が担う。
  // ここでは空ファイルを作り直しておく。
  fs.closeSync(fs.openSync(logPath, "a"));
  return true;
}

// ---- Main -----------------------------------------------------------------

export async function main(overrides = {}) {
  const agentraceHome = overrides.agentraceHome ?? DEFAULTS.agentraceHome();
  const queueDir = overrides.queueDir ?? path.join(agentraceHome, "queue");
  const deadLetterDir = overrides.deadLetterDir ?? path.join(agentraceHome, "dead_letter");
  const pidFile = overrides.pidFile ?? path.join(agentraceHome, "daemon.pid");
  const logOutPath = overrides.logOutPath ?? DEFAULTS.logOutPath();
  const logErrPath = overrides.logErrPath ?? DEFAULTS.logErrPath();
  const agentraceCmd = overrides.agentraceCmd
    ?? (process.env.AGENTRACE_CMD ? process.env.AGENTRACE_CMD.split(" ") : DEFAULTS.agentraceCmd);
  const maxRetry = overrides.maxRetry ?? DEFAULTS.maxRetry;
  const backoffMs = overrides.backoffMs ?? DEFAULTS.backoffMs;
  const readdirIntervalMs = overrides.readdirIntervalMs ?? DEFAULTS.readdirIntervalMs;
  const logRotateCheckMs = overrides.logRotateCheckMs ?? DEFAULTS.logRotateCheckMs;
  const logRotateMaxBytes = overrides.logRotateMaxBytes ?? DEFAULTS.logRotateMaxBytes;
  const spawnFn = overrides.spawnFn ?? spawn;

  fs.mkdirSync(queueDir, { recursive: true });
  fs.mkdirSync(deadLetterDir, { recursive: true });

  const lock = acquirePidLock(pidFile);
  if (!lock.acquired) {
    console.error(`[agentrace-daemon] Another instance is running (pid=${lock.heldBy}). Exit.`);
    process.exit(0);
  }

  let shuttingDown = false;
  const cleanup = () => {
    releasePidLock(pidFile);
  };
  process.on("exit", cleanup);
  const onSignal = (sig) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`[agentrace-daemon] received ${sig}, graceful shutdown`);
  };
  process.on("SIGTERM", () => onSignal("SIGTERM"));
  process.on("SIGINT", () => onSignal("SIGINT"));

  // 起動時の readdir で in-memory queue を構築
  const pending = new Set(readQueueFiles(queueDir));
  const retryCounts = new Map();
  const errorHistory = new Map();

  // fs.watch で新規ファイル検知
  let watcher = null;
  try {
    watcher = fs.watch(queueDir, (eventType, filename) => {
      if (!filename) return;
      if (filename.startsWith(".tmp-")) return;
      if (!filename.endsWith(".json")) return;
      pending.add(path.join(queueDir, filename));
    });
  } catch (e) {
    console.error(`[agentrace-daemon] fs.watch failed: ${e.message}`);
  }

  // 定期 readdir: watch 取りこぼしの safety net
  const readdirTimer = setInterval(() => {
    for (const f of readQueueFiles(queueDir)) pending.add(f);
  }, readdirIntervalMs);

  // ログローテーション
  const logTimer = setInterval(() => {
    try { rotateLogIfNeeded(logOutPath, logRotateMaxBytes); } catch {}
    try { rotateLogIfNeeded(logErrPath, logRotateMaxBytes); } catch {}
  }, logRotateCheckMs);
  try { rotateLogIfNeeded(logOutPath, logRotateMaxBytes); } catch {}
  try { rotateLogIfNeeded(logErrPath, logRotateMaxBytes); } catch {}

  // 直列処理ループ
  const pickNext = () => {
    if (pending.size === 0) return null;
    // ソートして最古を返す
    const [first] = [...pending].sort();
    pending.delete(first);
    return first;
  };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  console.log(`[agentrace-daemon] started pid=${process.pid} home=${agentraceHome}`);

  while (!shuttingDown) {
    const filePath = pickNext();
    if (!filePath) {
      await sleep(500);
      continue;
    }

    // 実ファイルが消えていたらスキップ（手動掃除や誤爆対策）
    if (!fs.existsSync(filePath)) continue;

    const result = await processOne(filePath, { spawnFn, agentraceCmd });
    if (result.ok) {
      retryCounts.delete(filePath);
      errorHistory.delete(filePath);
      continue;
    }

    // fatal（parse error など）は即 dead_letter
    if (result.fatal) {
      const history = errorHistory.get(filePath) ?? [];
      history.push({ at: new Date().toISOString(), error: result.stderr, fatal: true });
      moveToDeadLetter(filePath, deadLetterDir, history);
      retryCounts.delete(filePath);
      errorHistory.delete(filePath);
      continue;
    }

    const n = (retryCounts.get(filePath) ?? 0) + 1;
    const history = errorHistory.get(filePath) ?? [];
    history.push({ at: new Date().toISOString(), attempt: n, error: result.stderr });
    errorHistory.set(filePath, history);

    if (n >= maxRetry) {
      moveToDeadLetter(filePath, deadLetterDir, history);
      retryCounts.delete(filePath);
      errorHistory.delete(filePath);
      console.error(`[agentrace-daemon] moved to dead_letter after ${n} attempts: ${path.basename(filePath)}`);
      continue;
    }

    retryCounts.set(filePath, n);
    const wait = backoffMs[Math.min(n - 1, backoffMs.length - 1)];
    console.error(`[agentrace-daemon] retry ${n}/${maxRetry} in ${wait}ms: ${path.basename(filePath)} (${result.stderr})`);
    await sleep(wait);
    pending.add(filePath); // 再投入
  }

  console.log("[agentrace-daemon] shutting down, waiting for in-flight work...");
  clearInterval(readdirTimer);
  clearInterval(logTimer);
  if (watcher) watcher.close();
  releasePidLock(pidFile);
  console.log("[agentrace-daemon] exit");
  process.exit(0);
}

// CLI entry
const isDirectRun = process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (isDirectRun) {
  main().catch((err) => {
    console.error(`[agentrace-daemon] fatal: ${err.stack || err.message}`);
    process.exit(1);
  });
}
