# Claude Code 用 agentrace 非同期化アドオン

> **Unofficial addon.** This is a community addon for
> [agentrace](https://github.com/satetsu888/agentrace) (MIT) and is **not
> affiliated with** the upstream project. Set up agentrace itself first
> (see the upstream repository), then use this addon to make its hooks
> asynchronous.

`npx agentrace init` でセットアップした agentrace の hook は同期実行のため、Claude Code 側で Stop / SubagentStop / UserPromptSubmit / PostToolUse のたびに `npx agentrace send` の起動を待つ。

このディレクトリは、その hook を **queue + 常駐 daemon** 経由の非同期実行に置き換えるためのアドオン一式。Claude Code の体感応答性が落ちている人向けの **オプション導入**。

## 仕組み

```
Claude Code hook
  └─ agentrace-enqueue.sh
       …  stdin を ~/.agentrace/queue/ にアトミック投入して即 exit 0
          （bash builtin のみ、外部コマンドは mv 1 回）

agentrace-daemon.mjs (launchd 常駐)
  └─ queue を直列処理し `npx agentrace send` を spawn
     失敗時は指数バックオフで retry、上限超過は dead_letter へ
```

Claude Code 側は enqueue.sh の戻りを待つだけ（ミリ秒オーダ）になり、ネットワーク往復が体感応答時間から消える。

## 前提

このアドオンは公式セットアップを上書きするのではなく、後段で hook command だけ差し替える方式。先に通常の agentrace セットアップを済ませて、動作していることを確認しておくこと。

- macOS
- bash 5（`brew install bash` で `/opt/homebrew/bin/bash` が入る）
- Node.js / `npx` が PATH 上で利用可能
- `jq`（`brew install jq`）
- **`npx agentrace init --url <YOUR_AGENTRACE_URL>` 実行済み** で、`~/.agentrace/config.json` に `api_key` が入っていること

## セットアップ

### A. 普通にインストール（推奨）

```bash
./install.sh
```

これだけ。前提を確認 → ファイル配置 → `~/.claude/settings.json` の `npx agentrace send` を `~/.claude/hooks/agentrace-enqueue.sh` に差し替え → daemon 起動 → smoke test、まで自動。

オプション:

```bash
# 対象を絞りたい場合（無指定なら全セッションを enqueue）
./install.sh --allowlist /Users/foo/src/github.com/your-org/

# アンインストール（settings.json をバックアップから復元 + 配置ファイル削除）
./install.sh --uninstall
```

### B. install.sh が落ちた / 自分の環境が特殊で心配

Claude Code セッションで以下を貼ると、`SETUP.md` を読んで手作業で進めてくれる（途中で必要なら質問してくる）。

```
./SETUP.md を厳密に読み、書かれた手順通りに私のマシンに
agentrace 非同期化アドオンをセットアップしてください。
```

## 動作確認（smoke test）

`install.sh` の末尾でも自動実行されるが、後から手動で確認したい場合:

```bash
echo '{"cwd":"'"$HOME"'","hook_event_name":"Stop"}' \
  | bash ~/.claude/hooks/agentrace-enqueue.sh

ls ~/.agentrace/queue/        # ファイルが出現
sleep 3
ls ~/.agentrace/queue/        # 空 = daemon が捌いた
ls ~/.agentrace/dead_letter/  # 空であること
tail ~/Library/Logs/agentrace-daemon.err.log  # 新規エラーが無いこと
```

`queue/` が空にならない、または `dead_letter/` にファイルがある場合は `~/Library/Logs/agentrace-daemon.err.log` を確認する。

## 対象を絞りたい場合（path_allowlist）

デフォルトでは **全 Claude Code セッション** が enqueue される（agentrace 公式 init と同じ挙動）。プライベートリポジトリや他案件のセッションを送信したくない場合は `~/.agentrace/path_allowlist` を作る:

```
# 1行1 path prefix、# 始まりは無視
/Users/foo/src/github.com/your-org/
/Users/foo/work/
```

- ファイルが**無い、または有効エントリが無い**: 全許可
- ファイルがあり**いずれかの prefix にマッチ**: 投入
- ファイルがあり**どの prefix にもマッチしない**: ブロック

判定は enqueue.sh が hook 内で実行する。CLI 側（`npx agentrace send`）からは参照されないので、このアドオン専用の概念。

## 構成

```
async-agentrace/
├── README.md                       # 本ファイル
├── SETUP.md                        # Claude Code 向け手順書（install.sh が落ちた時用）
├── install.sh                      # 主インストーラ
├── agentrace-enqueue.sh            # hook 本体（stdin を queue/ に投入）
├── agentrace-daemon.mjs            # queue を npx agentrace send で送信する常駐
└── local.agentrace-daemon.plist    # launchd 定義（テンプレ、<PLACEHOLDER> 入り）
```

`install.sh` 実行後の配置:

| ソース | 配置先 |
| --- | --- |
| `agentrace-enqueue.sh` | `~/.claude/hooks/agentrace-enqueue.sh` |
| `agentrace-daemon.mjs` | `~/.local/bin/agentrace-daemon.mjs` |
| `local.agentrace-daemon.plist` | `~/Library/LaunchAgents/local.agentrace-daemon.plist` |
| — | `~/.agentrace/{queue,cursors,dead_letter}/` |
| — | `~/.agentrace/path_allowlist`（`--allowlist` 指定時のみ） |

`~/.agentrace/config.json`（api_key 含む）はこのアドオンでは触らない。`npx agentrace init` の管理。
