#!/usr/bin/env bash
#
# install.sh — Claude Code 用 agentrace 非同期化アドオンのインストーラ
#
# 前提:
#   - macOS / bash 5 / Node.js / npx / jq
#   - `npx agentrace init --url <YOUR_AGENTRACE_URL>` が完了済み
#     （= ~/.agentrace/config.json に api_key が入っている）
#
# 使い方:
#   ./install.sh                          # allowlist 設定なし（全セッション enqueue）
#   ./install.sh --allowlist <prefix>     # 1 つの prefix で絞る（例: /Users/foo/src/github.com/your-org/）
#   ./install.sh --uninstall              # アンインストール
#   ./install.sh --help                   # この help を表示
#
set -euo pipefail

# bash 5 必須
if [[ "${BASH_VERSINFO[0]:-0}" -lt 5 ]]; then
  for alt in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$alt" ]]; then
      exec "$alt" "$0" "$@"
    fi
  done
  echo "ERROR: bash 5 以上が必要です。brew install bash で導入してください" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 引数パース ----------------------------------------------------------------

ALLOWLIST_PATH=""
DO_UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --allowlist)
      [[ $# -lt 2 ]] && { echo "ERROR: --allowlist にパスを指定してください" >&2; exit 1; }
      ALLOWLIST_PATH=$2; shift 2;;
    --uninstall) DO_UNINSTALL=1; shift;;
    -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

# --- uninstall -----------------------------------------------------------------

if [[ "$DO_UNINSTALL" = "1" ]]; then
  echo "==> Uninstalling..."
  launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.agentrace-daemon.plist" 2>/dev/null || true

  latest=$(ls -t "$HOME"/.claude/settings.json.bak.* 2>/dev/null | head -1 || true)
  if [[ -n "$latest" ]]; then
    cp "$latest" "$HOME/.claude/settings.json"
    echo "  restored $HOME/.claude/settings.json from $latest"
  else
    echo "  WARN: settings.json のバックアップが見つかりません。手動確認してください" >&2
  fi

  rm -f "$HOME/Library/LaunchAgents/local.agentrace-daemon.plist"
  rm -f "$HOME/.claude/hooks/agentrace-enqueue.sh"
  rm -f "$HOME/.local/bin/agentrace-daemon.mjs"
  rm -f "$HOME/.agentrace/path_allowlist"

  echo "==> Done"
  echo "  ~/.agentrace/{queue,cursors,dead_letter} と config.json は agentrace 本体と共有のため残しています"
  echo "  agentrace 自体も消したい場合は 'npx agentrace uninstall' を実行してください"
  exit 0
fi

# --- 前提チェック --------------------------------------------------------------

echo "==> 前提チェック"

for cmd in node npx jq plutil launchctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd が見つかりません" >&2
    [[ "$cmd" = "jq" ]] && echo "  brew install jq で入ります" >&2
    exit 1
  fi
done

NODE_PATH="$(command -v node)"
NODE_BIN_DIR="$(dirname "$NODE_PATH")"
echo "  node: $NODE_PATH ($(node --version))"

CONFIG="$HOME/.agentrace/config.json"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG が存在しません" >&2
  echo "  先に以下を実行してください:" >&2
  echo "    npx agentrace init --url <YOUR_AGENTRACE_URL>" >&2
  exit 1
fi
if ! jq -e '.api_key | type == "string" and length > 0' "$CONFIG" >/dev/null 2>&1; then
  echo "ERROR: $CONFIG に api_key が設定されていません" >&2
  echo "  'npx agentrace init --url <YOUR_AGENTRACE_URL>' で再取得してください" >&2
  exit 1
fi
echo "  config.json: OK"

# --- settings.json 解決 --------------------------------------------------------

SETTINGS="$HOME/.claude/settings.json"
if [[ -L "$SETTINGS" ]]; then
  SETTINGS="$(readlink -f "$SETTINGS")"
fi
if [[ ! -f "$SETTINGS" ]]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi
echo "  settings.json: $SETTINGS"

# --- ディレクトリ準備 ----------------------------------------------------------

echo "==> ディレクトリ準備"
mkdir -p "$HOME/.claude/hooks"
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.agentrace/queue" "$HOME/.agentrace/cursors" "$HOME/.agentrace/dead_letter"
mkdir -p "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"

# --- ファイル配置 --------------------------------------------------------------

echo "==> hook と daemon の配置"
install -m 0755 "$SCRIPT_DIR/agentrace-enqueue.sh" "$HOME/.claude/hooks/agentrace-enqueue.sh"
install -m 0755 "$SCRIPT_DIR/agentrace-daemon.mjs" "$HOME/.local/bin/agentrace-daemon.mjs"

# --- path_allowlist ------------------------------------------------------------

if [[ -n "$ALLOWLIST_PATH" ]]; then
  echo "==> path_allowlist 書き込み"
  ALLOW_FILE="$HOME/.agentrace/path_allowlist"
  if [[ -f "$ALLOW_FILE" ]]; then
    bak="$ALLOW_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$ALLOW_FILE" "$bak"
    echo "  既存をバックアップ: $bak"
  fi
  {
    printf '# 1行1 path prefix、# 始まりは無視\n'
    printf '%s\n' "$ALLOWLIST_PATH"
  } > "$ALLOW_FILE"
  echo "  wrote $ALLOW_FILE"
else
  echo "==> path_allowlist は未設定（全セッションを enqueue する）"
  echo "  後で絞りたい場合は ~/.agentrace/path_allowlist を作成してください（1 行 1 prefix）"
fi

# --- plist 生成 ----------------------------------------------------------------

echo "==> plist 生成"
PLIST="$HOME/Library/LaunchAgents/local.agentrace-daemon.plist"
DAEMON_PATH="$HOME/.local/bin/agentrace-daemon.mjs"
sed \
  -e "s|<NODE_PATH>|$NODE_PATH|g" \
  -e "s|<DAEMON_PATH>|$DAEMON_PATH|g" \
  -e "s|<HOME>|$HOME|g" \
  -e "s|<NODE_BIN_DIR>|$NODE_BIN_DIR|g" \
  "$SCRIPT_DIR/local.agentrace-daemon.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
echo "  $PLIST"

# --- settings.json hook 差し替え ----------------------------------------------

echo "==> settings.json の hook 差し替え"
BAK="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BAK"
echo "  backup: $BAK"

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

if jq . "$tmp" >/dev/null 2>&1; then
  mv "$tmp" "$SETTINGS"
else
  rm -f "$tmp"
  echo "ERROR: settings.json の編集に失敗。バックアップから復元します" >&2
  cp "$BAK" "$SETTINGS"
  exit 1
fi

# --- daemon 起動 ---------------------------------------------------------------

echo "==> daemon 起動"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

sleep 1
if [[ -f "$HOME/.agentrace/daemon.pid" ]]; then
  pid=$(cat "$HOME/.agentrace/daemon.pid")
  echo "  daemon pid=$pid"
else
  echo "  WARN: daemon.pid がまだ生成されていません（起動中の可能性）" >&2
  echo "  tail ~/Library/Logs/agentrace-daemon.err.log で確認してください" >&2
fi

# --- smoke test ---------------------------------------------------------------

echo "==> smoke test"
SMOKE_CWD="$HOME"
if [[ -f "$HOME/.agentrace/path_allowlist" ]]; then
  matched=$(awk '/^[[:space:]]*#/ { next } NF { print; exit }' "$HOME/.agentrace/path_allowlist" || true)
  [[ -n "$matched" ]] && SMOKE_CWD="$matched"
fi

before=$(ls "$HOME/.agentrace/queue" 2>/dev/null | grep -v '^\.tmp-' | wc -l | tr -d ' ')
printf '{"cwd":"%s","hook_event_name":"Stop"}' "$SMOKE_CWD" \
  | bash "$HOME/.claude/hooks/agentrace-enqueue.sh"
after_enq=$(ls "$HOME/.agentrace/queue" 2>/dev/null | grep -v '^\.tmp-' | wc -l | tr -d ' ')

if [[ "$after_enq" -le "$before" ]]; then
  echo "  WARN: queue にファイルが出現しませんでした（cwd=$SMOKE_CWD）" >&2
  echo "  allowlist の prefix と一致していない可能性があります" >&2
else
  echo "  queue: $before -> $after_enq, daemon の処理を待ちます..."
  sleep 3
  after_proc=$(ls "$HOME/.agentrace/queue" 2>/dev/null | grep -v '^\.tmp-' | wc -l | tr -d ' ')
  dead=$(ls "$HOME/.agentrace/dead_letter" 2>/dev/null | grep -v '\.meta\.json$' | wc -l | tr -d ' ')
  echo "  queue after 3s: $after_proc, dead_letter: $dead"
  if [[ "$after_proc" -ge "$after_enq" ]]; then
    echo "  WARN: queue が捌けていません。~/Library/Logs/agentrace-daemon.err.log を確認してください" >&2
  elif [[ "$dead" -gt 0 ]]; then
    echo "  WARN: dead_letter にファイルが入りました。~/.agentrace/dead_letter/*.meta.json を確認してください" >&2
  fi
fi

# --- 完了 ----------------------------------------------------------------------

echo ""
echo "==> 完了"
echo ""
echo "新しい Claude Code セッションから、各 hook イベントは enqueue され、daemon が非同期に送信します"
echo ""
echo "状態確認:"
echo "  ls ~/.agentrace/queue/                       # 滞留している envelope"
echo "  ls ~/.agentrace/dead_letter/                 # 恒久エラーになった envelope"
echo "  tail -f ~/Library/Logs/agentrace-daemon.err.log"
echo ""
echo "アンインストール:"
echo "  ./install.sh --uninstall"
