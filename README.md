# copilot-tools

GitHub Copilot CLI をより安全・効率的に使うためのユーティリティ集。  
エイリアスによるツール実行制御、フックによるログ保存、tmux 連携スクリプト、Copilot 向けにチューニングされたスキルをまとめています。

## 前提条件

- [GitHub Copilot CLI](https://github.com/github/gh-copilot)
- tmux

## インストール

シェルの設定ファイル（`~/.bashrc` / `~/.zshrc`）に以下を追記する。

```sh
source /path/to/copilot-tools/scripts/ghc.sh
```

---

## ghc — ツール実行の Allow / Deny 制御

`scripts/ghc.sh` を読み込むと `ghc` エイリアスが有効になる。
`--allow-tool` / `--deny-tool` オプションで **実行を許可・拒否するツールをあらかじめ設定**した状態で Copilot CLI を起動できる。

```sh
ghc "テストを実行して結果を教えて"
```

デフォルト設定では読み取り・検索・一般的なビルドコマンドを許可し、`sudo`・`rm -rf`・`terraform apply` などの危険なコマンドを拒否している。  
`ghc.sh` を編集することでプロジェクトに合わせた許可・拒否リストをカスタマイズできる。

---

## Hooks — セッションログの自動保存

`.github/hooks/hooks.json` に Copilot CLI のフック設定が含まれている。  
`sessionEnd` フックにより、セッション終了時に会話ログが Markdown 形式で自動保存される。

```sh
# フックスクリプトをインストール
cp .github/hooks/save-session-log.sh ~/.copilot/hooks/

# ログ保存先の変更（デフォルト: /tmp/copilot-logs）
export COPILOT_LOG_DIR="$HOME/logs/copilot"
```

フック設定は `~/.copilot/hooks.json` として配置することで有効になる。

---

## Scripts — tmux 経由での Copilot 操作

tmux 上で動作する複数の Copilot CLI セッションを監視・管理するツール群。

### copilot-ps

tmux 内の Copilot CLI セッションを一覧表示・監視する。

```sh
copilot-ps               # セッション一覧を表示
copilot-ps -w            # 1秒間隔のウォッチモード
copilot-ps -w 5 --notify # 5秒間隔・完了時に通知
```

### copilot-await

入力待ち状態（`waiting_for_input`）のペインとその選択 UI を表示する。

```sh
copilot-await          # 入力待ちペインを表示
copilot-await -w       # ウォッチモード
```

### copilot-send

指定した tmux ペインの Copilot セッションにメッセージを送信する。

```sh
copilot-send <id> "メッセージ"      # メッセージを送信
make test 2>&1 | copilot-send <id>  # 標準入力から送信
```

---

## Skills — Copilot 向けにチューニングされたスキル集

`.github/skills/` 以下に Copilot CLI 用の Agent Skills を収録している。  
各スキルは Copilot のコンテキスト制限・ツール体系・ワークフローに合わせてチューニングされており、`skill` ツールから呼び出すことで動作する。

| スキル | 概要 |
|--------|------|
| `skill-creator` | Copilot 用カスタムスキルの新規作成・改修を行う Agent Skill |
