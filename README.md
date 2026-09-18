# Xipe Totec

関数型言語のプロジェクトに、表計算ソフトの構造 ── 住所を持つセル、住所への参照、
上流を変えると下流が再計算される仕組み ── を持ち込む、独立したローカルサーバー
兼 CLI。

名称は、ソースという本体から関数ごとに皮（カード）を剥いでいく像に由来する。
再スキャンのたびに皮は新しくなる。

Elixir 実装。アプリ名 `:xipe_totec`、モジュール名 `XipeTotec`、CLI コマンド
`xipe`。ブラウザ側の開発環境 [tezcatl](../tezcatl) とは別リポジトリの姉妹プロジェクト
（下記「tezcatl 連携」参照）。

---

## 何のために作ったか

出発点は、REPL で関数を試すときの手間である。入力値を毎回手で打つ、ファイル
パスを指定する、といった操作を、**計算行**として保存し再利用できるようにする。
計算行の引数には、別の計算行の出力への参照を置ける ── 上流を変えれば下流が
再計算される、表計算ソフトと同じ仕組みが手に入る。

もう一つの柱は**連動修正**である。カード上で関数名やファイル名を変更すると、
その変更が対象プロジェクトのソース（定義側）に反映され、さらにそれを参照している
他のモジュールのソース（参照側）にも反映される。

加えて、実行中のプログラムの関数呼び出しを動作順に1つの表として記録し
（**trace 表**）、計算行の入力候補として使えるようにする。

### 何ではないか

- IDE やエディタの置き換え。表の表示・セル移動・ハイライト・補完候補の表示は
  クライアント（[tezcatl](../tezcatl) など）の責務
- LLM 向けのコード索引（読み取り専用の文脈供給）。既存の tree-sitter 系 MCP
  サーバー群の領域であり、Xipe Totec は「値」と「書き戻し」に独自性を置く
- 汎用の実行時ロガー・プロファイラ。実行時の記録は関数の入出力と呼び出し順に限る
- 判定式など、コードの中身そのものの編集
- マクロを計算行の評価対象にすること
- 評価のサンドボックス化（副作用の判定を誤れば、書き込みは実際に起こる）
- 汎用リファクタリングツールとしての網羅性

### 設計原則

| # | 原則 |
|---|---|
| P1 | 参照透明性を前提とする。副作用を持つ関数は明示的に区別する |
| P2 | 再現性を最優先する。内容ハッシュ・git コミット・提供元を記録する |
| P3 | ID と名前を分離する。ID は代理キー、名前は自然キー |
| P4 | 非対称な信頼。LLM・ヒューリスティクス・外部提供元は「提案」のみ、受け入れ検査を通ったものだけ採用 |
| P5 | 差分は追加部分に閉じ込める。基本構造は言語非依存、言語ごとの差は REPL アダプタに |
| P6 | 書き込みは必ず diff → apply の二段階 |
| P7 | 入力体験はクライアントの責務。サーバーは口だけ提供する |
| P8 | 単体で完結し、外部の提供（言語サーバー等）は上乗せとする |
| P9 | 判定しきれないものは表に出す。推定値と状態を列として示し、利用者の確認に委ねる |
| P10 | 対象プロジェクトの環境で動かす。評価・trace・構文解析は対象プロジェクトの REPL の中で行う |

### 動く場所の前提

§16.1: 「いずれもローカルホストのみで待ち受け、認証は設けず、外部ネットワークには
接続しない」。`xipe serve` は `127.0.0.1` にバインドするだけで、認証・権限分離は
一切ない。

---

## 構成

```
対象プロジェクトのソース
        │ scan（AST 抽出 + コンパイラトレーサーによる link 抽出）
   Project / Scanner ── Identity（再スキャン時の ID 継続規則）
        │
       Core（純粋関数。Book への イベント適用・参照グラフ・再計算計画）
        │
       Book（id => 最新行、テーブルごと）⇄ Store（追記のみの JSON Lines 永続化）
        │
   §16 サーバーインターフェース
     Dispatch（method 名 → ハンドラ表）
       ├─ Address（§6.1 住所オブジェクトの列フィルタ解決）
       ├─ GraphQuery（:links 上の呼び出しグラフ BFS、mermaid/dot/json/doctest 整形）
       └─ Core / Project への委譲（row/add・row/remove・effect/set・scan/run）
     Serve.Project（GenServer。1プロジェクト1インスタンス。Book の差分を Store へ
                    永続化し、notify/* を全 attach 中セッションへブロードキャスト）
     Serve.Socket（:cowboy_websocket。§16.1 の WebSocket エントリ。1接続=1インスタンス）
        │ WebSocket（localhost）
   tezcatl の `/xipe`（設計済み・未実装 ── 下記参照）
```

| モジュール | 役割 | 状態 |
|---|---|---|
| `Book` | in-memory の現在状態（`id => 最新行`、テーブルごと） | 実装済み |
| `Store` | 追記のみの JSON Lines 永続化。fold/load・tombstone・`compact`・`persist_diff` | 実装済み |
| `Core` | 純粋関数。イベント適用・参照グラフ・循環検出・affected 集合・topo sort・`plan_recalc`/`apply_results` | 実装済み |
| `Identity` | §7.3 最小限の再スキャン ID 継続規則 | 実装済み |
| `Scanner` | AST 抽出＋コンパイラトレーサーによる link 抽出。`defmodule` のみコンパイル | 実装済み |
| `Project` | ディレクトリ横断の2パス走査＋差分書き込み | 実装済み |
| `Address` | §6.1 住所オブジェクト（列の組による部分一致フィルタ）の解決 | 実装済み |
| `Protocol` | §16.3 wire 形のエンコード・デコード | 実装済み |
| `Dispatch` | §16.3 method 名 → ハンドラ表 | Tier1 実装済み、Tier3 以降は明示エラー |
| `GraphQuery` | `graph/neighbors`・`graph/export`（mermaid/dot/json/doctest） | 実装済み（doctest はテーブルからの即席生成のみ） |
| `Serve.Project` | 1プロジェクト1GenServer。永続化＋notify ブロードキャスト | 実装済み |
| `Serve.Socket` | §16.1 WebSocket エントリ | 実装済み |
| `Evaluator` / REPL アダプタ | 対象プロジェクトの `iex` への分散 Erlang 接続、実評価 | **未着手** |

---

## いまどこまで動くか

`Book`/`Store`/`Core`/`Identity`/`Scanner`/`Project` と §16 サーバーインター
フェース一式（`Address`/`Protocol`/`Dispatch`/`GraphQuery`/`Serve.Project`/
`Serve.Socket`）まで実装・テスト済み（104 ExUnit tests, all green）。

- `xipe scan <dir>` → `xipe show` の実機動作を2ファイル構成のサンプルで確認済み
  （クロスファイル参照の解決、変更なし再スキャンで追記ゼロ、を含む）
- `xipe serve <dir> --port <p>` を実際に起動し、生 WebSocket クライアントで
  `initialize`（未初期化リクエストの拒否込み）→`scan/run`→`notify/nodeChanged`
  受信までの実機ラウンドトリップを確認済み

§16.3 の method は次の状態:

| Tier | method | 状態 |
|---|---|---|
| 1 | `scan/run`・`row/add`・`row/remove`・`effect/set`・`card/get`・`card/search`・`graph/neighbors`・`graph/export`・`cell/resolve` | 実装済み |
| 2 | `row/update` | 編集自体（`Core.edit_args`/`set_prev`）は実装済みだが、仕様が約束する再計算結果を返せないため method 全体は未実装 |
| 3 | `eval/run`・`cell/complete`（値ベース部分） | **Evaluator 待ち** |
| 4 | `edit/propose`・`edit/apply`・`provider/recheck` | REPL アダプタの書き換え規則・受け入れ検査待ち |
| 5 | `trace/start`・`trace/stop`・`trace/get`・`trace/import` | ストレージ方式が v0.5 で再検討予定のため凍結 |

**未着手なのは Evaluator / REPL アダプタ**（対象プロジェクトの `iex` への分散
Erlang 接続・実評価・セッション束縛管理）。ライブな2ノード構成での検証が要る
ため、crux 自身のトレース・修正パスに委ねている。上記 Tier 2〜4 の多くはこれ
待ち。

---

## 動かし方

```
nix develop

xipe scan [<dir>]        # <dir> 以下の .ex を走査、./book.jsonl を更新（既定 .）
xipe show                 # 現在の book の要約を表示
xipe serve [<dir>] [--port N]
                           # §16.1 WebSocket エントリ（既定ポート 4200、
                           # $XIPE_TOTEC_PORT でも変更可）

./test/run.sh              # ExUnit 全件（104 件、何も起動せず単体で走る）
```

Mix プロジェクトではない（`mix.exs` なし）。tezcatl と同じ規約で、`main.exs` が
`Code.require_file` で `lib/*.exs` を読み込む素の `elixir` スクリプト。

---

## 用語

| 用語 | 定義 |
|---|---|
| ブック（Book） | 対象プロジェクト全体。テーブル群の集合 |
| シート | 対象プロジェクトのファイル1つ |
| カード | 1関数分の行のまとまり。スキャンで自動的に作られ、関数がソースにある限り存在する |
| 行 | カードを構成する単位。計算行とリンク行の2種 |
| 計算行 | 関数への1回の呼び出し。引数・結果・前回などの列を持つ |
| リンク行 | 関数の接続関係を表す行。受信元・判定式・送信先のセルを持つ |
| 参照 | セル内に `⟦ ⟧` で書かれる、他の計算行の結果への参照 |
| 住所 | 対象を指定する列の組（区切り文字を使わない部分一致フィルタ） |
| trace 表 | 実行時の関数呼び出しを動作順に記録した表 |
| run | trace 表への1回の記録単位 |
| REPL アダプタ | 対象プロジェクトの環境にある REPL を Xipe Totec の共通操作に合わせる、言語ごとの部品 |
| 境界規則 | 言語の境界をまたぐ関数の対応を扱う部品（例: Elixir と Rust をつなぐ Rustler） |
| 提供元 | 構文解析・名前解決の結果を供給するもの（言語サーバー／基本動作） |
| セッション | REPL アダプタが起動した REPL の1回の実行。世代番号を持つ |
| 墓標 | 消失した対象を即削除せず保持する状態 |
| 修正リスト | ソースファイルへのテキスト編集の集合。LSP の WorkspaceEdit に相当 |
| エラー値 | 評価できなかったセルが持つ値。参照を通じて下流に伝わる |

---

## tezcatl 連携

[tezcatl](../tezcatl) 側の UI から Xipe Totec を使うための接続モデルは設計済み
（tezcatl 側 `forAI/progress.md` 2026-09-17 分）── tezcatl の relay が `/xipe`
を新設し、既に立っている Xipe Totec サーバーへ接続（connect）するか、
`xipe serve` を自分で起動してから接続（spawn）するかをプロジェクトごとの設定
で選べるようにする。§16.2 の「中継は状態を持たない」規定に従い、`/xipe` は
`/lsp` のような id 書き換え型の多重化はせず、状態を持たないブロードキャスト
中継にする。tezcatl 側のコードはまだ無い。

---

## 文書

| 文書 | 答える問い |
|---|---|
| この README | 何のために作られ、何ではなく、いまどこまで動くか |
| `document/xipe_totec_spec_v0.4.html` | 仕様のたたき台（v0.4）。§6.6/§9 の call_hash 周りは下記 prebuild の決定と食い違うテキストが残っているので、そちらを優先すること |
| `document/XipeTotec_prebuild.md` | 実装前確認書 rev.2 ＋ §9 実装ノート（2026-09-17〜）。仕様との差分・決定事項・進捗が日付順に追える |
