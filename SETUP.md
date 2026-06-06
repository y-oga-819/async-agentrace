# SETUP.md — install.sh が落ちた時のトラブルシュートと手動セットアップ

通常は **`./install.sh`** で完結します。このファイルは:

- `install.sh` が落ちた / 自分の環境が特殊で心配な利用者が、Claude Code に依頼して手動でセットアップしてもらうための指示書
- 起動後の問題切り分けの参考資料

を兼ねています。Claude Code 向けの指示書として書いてあるので、Claude Code がこの SETUP.md を読みながら 1 ステップずつ進められる形式になっています。

---

## 基本原則（厳守）

1. **既存ファイルを破壊しない。** 特に `~/.claude/settings.json` は jq で操作。テキスト編集禁止。編集前に必ずバックアップ。
2. **`~/.agentrace/config.json` は読み取り専用扱い。**`api_key` の取得・更新は `npx agentrace init` の責務。このアドオンは触らない。
3. **質問は 1 つずつ。** 利用者の明示回答を待ってから次へ。
4. **失敗したら正直に報告し、ロールバックを提案する。**
5. **このリポジトリ内のソースファイルは変更しない。** 配置先（`~/...`）にコピーして加工する。

---

## Step 0. 作業ディレクトリ

`async-agentrace` リポジトリのルートにいる前提:

```bash
ls -la ./
# install.sh / agentrace-enqueue.sh / agentrace-daemon.mjs / local.agentrace-daemon.plist がある
```

無ければ「`async-agentrace` リポジトリのルートをカレントにしてください」と依頼。

---

## Step 1. 前提チェック

並列で実行し、結果をまとめて利用者に提示する:

```bash
sw_vers
ls -la /opt/homebrew/bin/bash /usr/local/bin/bash 2>&1
/opt/homebrew/bin/bash --version 2>/dev/null || /usr/local/bin/bash --version 2>/dev/null
command -v node && node --version
command -v npx
command -v jq
ls -la ~/.agentrace/config.json 2>&1
jq -e '.api_key | type == "string" and length > 0' ~/.agentrace/config.json 2>/dev/null \
  && echo "config OK" || echo "config NG"
ls -la ~/.claude/settings.json 2>&1
```

判定:

- **bash 5 が無い**: `brew install bash` を案内し、完了するまで先に進まない。
- **node / npx / jq が無い**: 利用者に確認。`jq` は `brew install jq`。
- **`~/.agentrace/config.json` 不在 or `api_key` 欠落**: **ここで停止**して利用者に案内:

  > `npx agentrace init --url <YOUR_AGENTRACE_URL>` を実行し、ブラウザ認可フローで credential を取得してください。完了したら再開します。

- **`~/.claude/settings.json` が無い**: `mkdir -p ~/.claude && echo '{}' > ~/.claude/settings.json` で空の JSON を作成。

---

## Step 2. （任意）path_allowlist の確認

`AskUserQuestion` で 1 件だけ聞く:

```
質問: 特定のディレクトリ配下だけを agentrace に送信したいですか？
（無指定なら全 Claude Code セッションが対象 — agentrace 公式 init と同じ挙動）
絞りたい場合は prefix を教えてください（例: /Users/foo/src/github.com/your-org/）。
不要なら「不要」と答えてください。
```

回答が「不要」または空: `~/.agentrace/path_allowlist` は作らない。
prefix が指定された: Step 3.3 で書き込む。

---

## Step 3. ファイル配置

順番に実行。

### 3.1 ディレクトリ準備

```bash
mkdir -p ~/.claude/hooks ~/.local/bin
mkdir -p ~/.agentrace/queue ~/.agentrace/cursors ~/.agentrace/dead_letter
mkdir -p ~/Library/Logs ~/Library/LaunchAgents
```

### 3.2 hook と daemon

```bash
install -m 0755 ./agentrace-enqueue.sh ~/.claude/hooks/agentrace-enqueue.sh
install -m 0755 ./agentrace-daemon.mjs ~/.local/bin/agentrace-daemon.mjs
```

### 3.3 path_allowlist（Step 2 で prefix が指定されたときのみ）

```bash
# 既存があればバックアップ
[ -f ~/.agentrace/path_allowlist ] && \
  cp ~/.agentrace/path_allowlist ~/.agentrace/path_allowlist.bak.$(date +%Y%m%d-%H%M%S)
```

Write ツールで `~/.agentrace/path_allowlist` を以下の内容で作成:

```
# 1行1 path prefix、# 始まりは無視
<利用者が指定した prefix>
```

### 3.4 plist 生成

```bash
NODE_PATH="$(command -v node)"
NODE_BIN_DIR="$(dirname "$NODE_PATH")"
DAEMON_PATH="$HOME/.local/bin/agentrace-daemon.mjs"

sed \
  -e "s|<NODE_PATH>|$NODE_PATH|g" \
  -e "s|<DAEMON_PATH>|$DAEMON_PATH|g" \
  -e "s|<HOME>|$HOME|g" \
  -e "s|<NODE_BIN_DIR>|$NODE_BIN_DIR|g" \
  ./local.agentrace-daemon.plist \
  > ~/Library/LaunchAgents/local.agentrace-daemon.plist

plutil -lint ~/Library/LaunchAgents/local.agentrace-daemon.plist
```

`plutil -lint` が失敗したら原因を提示してロールバック。

---

## Step 4. `~/.claude/settings.json` の hook 差し替え（最重要）

### 4.0 対象解決

```bash
SETTINGS="$HOME/.claude/settings.json"
if [ -L "$SETTINGS" ]; then
  SETTINGS="$(readlink -f "$SETTINGS")"
fi
echo "$SETTINGS"
```

### 4.1 バックアップ

```bash
BAK="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BAK"
echo "backup: $BAK"
```

利用者にパスを明示。ロールバック時に使う。

### 4.2 jq による差し替え（冪等）

戦略:

- `Stop` / `SubagentStop` / `UserPromptSubmit` / `PostToolUse` の 4 イベントを走査
- 各 matcher の `hooks[].command` が文字列 `"agentrace send"` を含むものを、`~/.claude/hooks/agentrace-enqueue.sh` に書き換える
- 既に書き換わっているもの（再実行）はそのまま
- 該当 command がどの matcher にも無いイベントには、新規 matcher を 1 つ append（fallback）

```bash
HOOK_CMD="$HOME/.claude/hooks/agentrace-enqueue.sh"

tmp="$(mktemp)"
jq --arg cmd "$HOOK_CMD" '
  def swap_event($event):
    . as $root
    | ($root.hooks // {}) as $h
    | ($h[$event] // []) as $arr
    | ($arr | map(
        .hooks //= []
        | .hooks |= map(
            if ((.command // "") | contains("agentrace send"))
            then .command = $cmd
            else .
            end
          )
      )) as $swapped
    | (any($swapped[]?; (.hooks // [])[]?.command == $cmd)) as $hasOurs
    | if $hasOurs
      then $root | .hooks = ($h + { ($event): $swapped })
      else $root | .hooks = ($h + { ($event): ($swapped + [{
             hooks: [{ type: "command", command: $cmd }]
           }]) })
      end;
  swap_event("Stop")
  | swap_event("SubagentStop")
  | swap_event("UserPromptSubmit")
  | swap_event("PostToolUse")
' "$SETTINGS" > "$tmp"

if jq . "$tmp" > /dev/null 2>&1; then
  mv "$tmp" "$SETTINGS"
else
  rm -f "$tmp"
  echo "ERROR: settings.json の編集失敗。バックアップから復元する" >&2
  cp "$BAK" "$SETTINGS"
  exit 1
fi
```

実行後、`jq '.hooks' "$SETTINGS"` を表示して利用者に確認させる:

- 4 イベントすべてに `command: <HOME>/.claude/hooks/agentrace-enqueue.sh` が含まれていること
- `command` が `"npx agentrace send"` のままのエントリが**残っていない**こと（二重発火防止）

`"npx agentrace send"` が残っていたら想定外の構造。元の settings.json を見せて判断を仰ぐ。

---

## Step 5. daemon 起動

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/local.agentrace-daemon.plist 2>/dev/null
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.agentrace-daemon.plist

sleep 1
ls -la ~/.agentrace/daemon.pid
ps -p "$(cat ~/.agentrace/daemon.pid 2>/dev/null)" -o pid,command 2>&1
tail -n 20 ~/Library/Logs/agentrace-daemon.err.log 2>&1
```

`daemon.pid` 不在 / `ps` で見えない / err.log にスタックトレースが出ている場合は原因を利用者に提示。

---

## Step 6. smoke test

```bash
# Step 2 で allowlist を設定したならその先頭、未設定なら $HOME を使う
if [ -f ~/.agentrace/path_allowlist ]; then
  SMOKE_CWD=$(awk '/^[[:space:]]*#/{next} NF{print; exit}' ~/.agentrace/path_allowlist)
fi
SMOKE_CWD="${SMOKE_CWD:-$HOME}"

echo "{\"cwd\":\"$SMOKE_CWD\",\"hook_event_name\":\"Stop\"}" \
  | bash ~/.claude/hooks/agentrace-enqueue.sh

ls ~/.agentrace/queue/
sleep 3
ls ~/.agentrace/queue/
ls ~/.agentrace/dead_letter/
tail -n 20 ~/Library/Logs/agentrace-daemon.err.log
```

判定:

- queue 出現 → 3 秒後に消える → dead_letter 空 → err.log にエラー無し: **成功**
- queue 出現せず: 入力 JSON の `cwd` が allowlist の prefix に一致していない可能性。`~/.agentrace/path_allowlist` と `$SMOKE_CWD` を見比べる
- queue 消えない: daemon が動いていない。`launchctl print` と err.log を確認
- dead_letter に入った: `~/.agentrace/dead_letter/*.meta.json` の `errors` を読む。`npx agentrace doctor` で config の妥当性を確認するのが早い

---

## Step 7. ロールバック（失敗時 & 参照用）

```bash
# 1. daemon を外す
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/local.agentrace-daemon.plist 2>/dev/null

# 2. settings.json をバックアップから復元
cp "$BAK" ~/.claude/settings.json

# 3. 配置ファイル削除（利用者に確認してから）
rm -f ~/Library/LaunchAgents/local.agentrace-daemon.plist
rm -f ~/.claude/hooks/agentrace-enqueue.sh
rm -f ~/.local/bin/agentrace-daemon.mjs
rm -f ~/.agentrace/path_allowlist
# ~/.agentrace の queue / dead_letter / cursors は agentrace 本体と共用なので、
# rm -rf する前に必ず利用者に確認。
```

`./install.sh --uninstall` でも同じことができる（最新の settings.json.bak.* を自動で見つけて復元する）。

---

## 完了報告テンプレート

```
agentrace 非同期化アドオンのセットアップが完了しました。

配置:
- hook: ~/.claude/hooks/agentrace-enqueue.sh
- daemon: ~/.local/bin/agentrace-daemon.mjs
- launchd: ~/Library/LaunchAgents/local.agentrace-daemon.plist (loaded, pid=XXXX)
- path_allowlist: (設定済 / 未設定 = 全許可)

settings.json:
- backup: ~/.claude/settings.json.bak.YYYYMMDD-HHMMSS
- 4 イベントの command を `npx agentrace send` → `~/.claude/hooks/agentrace-enqueue.sh` に差し替え

smoke test: queue → 消化 → dead_letter 空、err.log 新規エラーなし

新しい Claude Code セッションから非同期送信が有効になります。
アンインストールは `./install.sh --uninstall` か Step 7 の手順で。
```

失敗時は、どの Step まで進んだか / 残置ファイル / 推奨ロールバック範囲 を明示。
