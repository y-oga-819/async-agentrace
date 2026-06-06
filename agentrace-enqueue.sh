#!/usr/bin/env bash
#
# agentrace-enqueue.sh — Claude Code hook から呼ばれ、stdin を
# $AGENTRACE_HOME/queue/ にアトミックに投入する最速のラッパー。
#
# 実際の agentrace への送信は agentrace-daemon.mjs が非同期で担当する。
# 対象: $AGENTRACE_HOME/path_allowlist の prefix に一致する
# CLAUDE_PROJECT_DIR（または stdin の cwd）のみ。
#
# エラーは全て exit 0 で握りつぶし、Claude Code を絶対に止めない。
#
# 高速化のため bash 5 ビルトイン（$EPOCHREALTIME / printf %()T / read -d ""）
# に依存し、外部コマンドは `mv` のみ。bash 4 以下では起動時に /opt/homebrew/bin/bash
# へ re-exec する（設計書に対する実装詳細レベルの逸脱）。
#
set -uo pipefail

# 旧 bash(3.2) 上で起動された場合は新しい bash へ再実行（再入を防ぐ）
if [[ "${BASH_VERSINFO[0]:-0}" -lt 5 && -z "${AGENTRACE_ENQUEUE_REEXEC:-}" ]]; then
  export AGENTRACE_ENQUEUE_REEXEC=1
  for alt in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$alt" ] && exec "$alt" "$0" "$@"
  done
  # bash 5 が見つからなければ続行（%()T と EPOCHREALTIME が失敗するので exit 0）
  exit 0
fi

AGENTRACE_HOME="${AGENTRACE_HOME:-$HOME/.agentrace}"
QUEUE_DIR="$AGENTRACE_HOME/queue"
ALLOWLIST="$AGENTRACE_HOME/path_allowlist"

# 早期棄却（queue dir は必須。allowlist は無くても良い＝全許可）
[ ! -d "$QUEUE_DIR" ] && exit 0

# stdin を一気に変数へ（read builtin、fork なし）
input=""
IFS= read -rd '' input || true
[ -z "$input" ] && exit 0

# CLAUDE_PROJECT_DIR：env 優先、なければ stdin の "cwd" フィールドから抽出
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  # bash の正規表現で "cwd":"..." を抽出
  if [[ "$input" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    project_dir="${BASH_REMATCH[1]}"
  fi
fi
[ -z "$project_dir" ] && exit 0

# path_allowlist の prefix 一致判定
# allowlist が無い、または有効エントリ（非コメント・非空行）が無ければ全許可。
# 1 行でも有効エントリがあり、それらに一致しなかった場合のみブロック。
if [ -r "$ALLOWLIST" ]; then
  has_entries=0
  match=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    has_entries=1
    if [[ "$project_dir" == "$line"* ]]; then
      match=1
      break
    fi
  done < "$ALLOWLIST"
  [ "$has_entries" = "1" ] && [ "$match" = "0" ] && exit 0
fi

# 時刻・乱数（全てビルトイン、fork なし）
# $EPOCHREALTIME 例: "1776062539.660646"（秒.マイクロ秒）
t=$EPOCHREALTIME
sec="${t%.*}"
micro="${t#*.}"
# マイクロ→ナノ（末尾に000付加）で19桁整数
nanos="${sec}${micro}000"
ms="${micro:0:3}"

# ISO8601 UTC with ms（ビルトイン。TZ=UTC は printf 呼び出しのみ反映）
TZ=UTC printf -v iso '%(%Y-%m-%dT%H:%M:%S)T.%sZ' "$sec" "$ms"

# 32bit 乱数を16進8桁へ
printf -v rand '%04x%04x' "$((RANDOM & 0xffff))" "$((RANDOM & 0xffff))"

base="${nanos}-$$-${rand}"
tmp_queue="$QUEUE_DIR/.tmp-${base}"
final_queue="$QUEUE_DIR/${base}.json"

# JSON 用に project_dir をエスケープ（パスに " や \ が現れるのは稀だが一応）
project_esc="${project_dir//\\/\\\\}"
project_esc="${project_esc//\"/\\\"}"

# JSON 書き込み。hook_input は stdin が既に有効な JSON である前提でそのまま埋め込む
{
  printf '{"version":1,"enqueued_at_nanos":"%s","enqueued_at_iso":"%s","claude_project_dir":"%s","hook_input":' \
    "$nanos" "$iso" "$project_esc"
  printf '%s' "$input"
  printf '}'
} > "$tmp_queue" 2>/dev/null || { rm -f "$tmp_queue"; exit 0; }

# atomic rename で完成（fail しても握りつぶす）
mv "$tmp_queue" "$final_queue" 2>/dev/null || rm -f "$tmp_queue"

exit 0
