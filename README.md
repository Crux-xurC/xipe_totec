# Xipe Totec

関数型言語のプロジェクトに、表計算ソフトの構造 ── 住所を持つセル、住所への参照、
参照を順にたどって評価し直せる仕組み ── を持ち込む、独立したローカルサーバー
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
計算行の引数には、別の計算行の出力への参照（`⟦id⟧`）を置ける ── 参照でつないだ
計算行を並べて評価すれば、上流の変化が下流にどう伝わるかを見られる。評価するのは
指定した計算行だけで、指定していない行を裏で評価して記録に加えることはしない
（Book は時系列の記録、`document/Old.md` §36）。

評価は、人が REPL の端末で行う操作をそのまま自動化する形で行う。対象プロジェクト
自身の REPL（Elixir なら `iex`）を起動し、標準入力へ呼び出し式を書き込み、
標準出力に印字された結果を読む。

もう一つの柱は**参照一覧**である。スキャンで得た静的な呼び出し関係（`:links`）から、
ある関数を誰が呼んでいるかを引ける。当初は、カード上の名前変更をソースへ書き戻す
**連動修正**（`edit/propose`/`edit/apply`）を柱にしていたが、2026-09-22 に撤回した。
実際の書き換えはエディタ側（LSP の rename など）に任せ、Xipe Totec は参照一覧を
出すところまでを受け持つ（`document/Old.md` §21）。

加えて、実行中のプログラムの関数呼び出しを動作順に1つの表として記録し
（**trace 表**）、計算行の入力候補として使えるようにする構想がある（凍結中）。

### 何ではないか

- IDE やエディタの置き換え。表の表示・セル移動・ハイライト・補完候補の表示は
  クライアント（[tezcatl](../tezcatl) など）の責務
- ソースの書き換えツール。リネーム等はエディタ／LSP に任せる
- LLM 向けのコード索引（読み取り専用の文脈供給）。既存の tree-sitter 系 MCP
  サーバー群の領域であり、Xipe Totec は「値」に独自性を置く
- 汎用の実行時ロガー・プロファイラ。実行時の記録は関数の入出力と呼び出し順に限る
- 判定式など、コードの中身そのものの編集
- マクロ・パイプ・複数文を計算行の評価対象にすること（計算行は常に
  `Module.function(args...)` の1呼び出し。多段処理は計算行を `⟦id⟧` で繋ぐ）
- 評価のサンドボックス化（副作用の判定を誤れば、書き込みは実際に起こる）

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

P1 の具体形: 副作用の分類（`pure`/`reads`/`writes`）は利用者が `effect/set` で
明示したものだけを信用し、未分類の関数は評価しない。`writes` は
`--include-writes` を付けたときだけ評価する。

### 動く場所の前提

§16.1: 「いずれもローカルホストのみで待ち受け、認証は設けず、外部ネットワークには
接続しない」。`xipe serve` は `127.0.0.1` にバインドするだけで、認証・権限分離は
一切ない。

---

## 構成

```
対象プロジェクトのソース
        │ scan（AST 抽出 + コンパイラトレーサーによる link 抽出）
   SurfaceTable（ファイル→言語/REPL/ビルドツール）→ Project / Scanner ── Identity
        │
       Core（純粋関数。参照グラフ・再計算計画 plan_recalc・結果の反映 apply_results）
        │
       Book（id => 最新行、6テーブル）⇄ Store（追記のみの JSON Lines = プロジェクトごとの book.jsonl）
        │
   コマンド列  Runner ─┬─ Dispatch（Book だけで完結する method の表引き）
                       ├─ Pipeline（REPL を挟む method。pipelines.json に登録）
                       └─ "eval" → Repl.Evaluator
                                     Launch → Sender.Direct(erlexec) → Session
                                     → EvalTemplate → iex → Eval.Parser → Core.apply_results
   対話        InOut / Dialogue（複数ターンの対話。例: Dialogue.Depends）
        │
   入口        CLI（main.exs）／ Serve.Project（GenServer）+ Serve.Socket（WebSocket）
        │ WebSocket（localhost）
   tezcatl の `/xipe`（中継・対話窓 `input`・表 `row/list`/`card/get` まで実装済み。「tezcatl 連携」）
```

スキャンと評価は言語で選ばれる。surface table が示す言語（`info.json` に登録済みの
もの）の `Repl.Language` モジュールが、ファイルを読む Scanner（`scanner/0`、
`XipeTotec.Scanner` の実装）、`Repl.Evaluator` に渡す4モジュール（`launch`/
`eval_template`/`Eval.Scan`/`field_drip`）、REPL の起動方法（`launch_opts/2`）を申告し、
`Project`（スキャン）と `Runner`（評価）がそれを使う。REPL は言語ごとに1つに決め打ち
（Elixir なら `iex`）で、ビルドツールは起動方法だけを変える。申告があるのは Elixir と
OCaml（2026-09-27、素の `ocaml` トップレベル＋`embody.ml`、`Old.md` §42）と Haskell（同日、GHCi＋`embody.hs`、§46）。
`embody` は別リポジトリ（`~/my_app/embody`、git@github.com:Crux-xurC/embody.git）。Elixir の Scanner は elixir-ls（`Scanner.Lsp.Elixir`）を優先する。言語サーバーへは
tezcatl の `/lsp` を先に試し、つながらなければ elixir-ls を自分で起動する（CLI 単体でも
使える）。どちらも駄目なら自前の `Scanner.Elixir` を使う（仕様 §11.3）。どれで読んだか
（`via` が `relay`/`stdio`）は `scan/run` の結果の `scanners` に出る。カードは disk のファイル
（評価で REPL が読むもの）に合わせる。言語サーバーがエディタの未保存の内容を持っていて位置が
disk とずれるファイルは、そのファイルだけ次の Scanner（Elixir なら `Scanner.Elixir`）で読み直し、
`scanners.<言語>.fallbacks` に出す。カードになるのは関数だけ（Elixir なら `def`/`defp`/
`defdelegate`）で、マクロ・ガードは入らない。`XIPE_TOTEC_LSP=off` で言語サーバー経由を止められる
（テストはこれで走る）。`Scanner`（ソースから定義を抽出）と `Eval.Scan`
（REPL 出力からマーカーを検出）は名前が似ているが別物。

| 層 | モジュール | 役割 |
|---|---|---|
| 土台 | `Book` / `Store` / `Core` / `Id` / `Identity` | 現在状態・追記型永続化・純粋な参照グラフと再計算計画・再スキャン時の ID 継続 |
| スキャン | `Scanner`（behaviour）/ `Scanner.Lsp`（+ `Scanner.Lsp.Elixir`）/ `Scanner.Elixir` / `Lsp.Transport`（+ `.Relay`・`.Stdio`）/ `Project` / `SurfaceTable` | ファイルからカードと link を作る口と共通の帳簿付け、言語サーバー経由の実装（`documentSymbol`・`callHierarchy`、言語ごとの差は薄い dialect）、Elixir の自前の実装（AST 抽出、`defmodule` のみコンパイル。言語サーバーが無いときの予備）、言語サーバーへのつなぎ方（tezcatl の `/lsp`、無ければ自分で起動）、ディレクトリ横断の2パス走査（言語ごとに Scanner を優先順に試し、どれを使ったかを記録）、ファイルごとの言語判定 |
| コマンド | `Runner` / `Dispatch` / `Pipeline` / `Address` / `GraphQuery` | コマンド列の実行（`$<n>.<path>` で前の結果を参照）、method の表、住所の解決、呼び出しグラフの BFS と書き出し |
| 評価 | `Repl.Evaluator` / `Launch` / `Sender(.Direct)` / `Session` / `EvalTemplate` / `SourceSanitize` / `Eval.{Scan,FieldDrip,Parser,Result}` | REPL の起動・完了待ち・式の送信・マーカー受信・ハング時の SIGINT→SIGKILL |
| 対話 | `InOut` / `Dialogue` / `Dialogue.Depends` / `Dialogue.Search` / `EvalTable` | 複数ターンの構造化対話（一覧は `InOut.programs/0`、CLI とサーバーで共通）、依存チェーン交渉、検索と、その `-e` が引く `eval_table`（計算行に関数と path を横付けした読み取り用の表） |
| 人向けの入出力 | `Input` / `Help` / `OutcomeText` / `Show` / `Serve.Input` | 1行の読み方（CLI と同じ書き方）、`help` の表、結果・`show` の行（CLI と対話窓で共通）、`input` method |
| サーバー | `Protocol` / `Serve.Project` / `Serve.Socket` | §16.3 の wire 形、1プロジェクト1GenServer、WebSocket の入口 |
| プロジェクト | `Workspace` / `ProjectRegistry` / `ProjectConfig` / `ProjectEnv` / `Info` / `Repl.Language` | どのプロジェクトを対象にするかの解決、3桁 ID の登録、プロジェクトごとの設定（`project.json`、`xipe config`）、対象のツールを走らせる環境（対象の flake の devShell など）、xipe_totec 自身の `info.json`（言語と拡張子、アダプタ一覧）と、このマシンで選択中のプロジェクト（`tables/selection.json`）、言語ごとの自己申告 |
| 評価の周り | `Passes` / `GitCtx` / `CommandLine` | いま評価中のパス（`passes/` のファイル。`eval/status`、評価中の行を変えさせない、§51）、評価した行に記録する git の出どころ、`xipe do` の引数をコマンド列に読む |

---

## いまどこまで動くか

2026-10-08 時点。`./test/run.sh` の全46ファイル・468件がすべて通る。これとは別に、
実機の REPL を起動するテスト（`test/live/`、`iex` 12件・`ocaml` 6件・`ghci` 7件。OCaml・Haskell 版は
PATH に処理系が無ければ飛ばす）がある。

**CLI からは、Elixir プロジェクトに対してスキャン → 計算行の作成 → 実評価 → 結果の
永続化まで、一通り動く。** OCaml（`.ml`）も同じ流れで動く（`Old.md` §42）。dune のプロジェクトでは依存するライブラリを
`dune ocaml top` から読み込む（§43）。Haskell（`.hs`）も同じ（§46）。cabal・stack のプロジェクトでは GHCi を `cabal exec`・`stack exec` の下で
起動して依存パッケージを見えるようにする（§47）。 mix 構成（`iex -S mix`）とスクリプト構成の両方に対応している。
スクリプト構成では、各ファイルの `defmodule` 部分だけを、元のファイルのパスと行番号の
ままコンパイルする（`Repl.SourceSanitize` の読み込み用スクリプト。トップレベルの副作用は
走らせない。エラーの位置と `__DIR__` は元のファイルを指す）。

- 評価結果は `repr`（`exact`/`binary`/`unsupported`）、表示用文字列、前回値との
  `compare`（浮動小数点は許容誤差込み）を持つ
- 1件ごとに timeout と max_heap の安全装置を付けて評価する。セッションが固まれば
  SIGINT、効かなければプロセスグループごと SIGKILL で落とし、残りは `aborted` にする
- 構文として閉じていない引数は REPL へ送らずにエラーにする。参照を解決できない
  計算行は評価せず `skipped` にする
- `xipe dialogue depends` で、上流の依存チェーンの深い段から順に「ここに値を手で
  入れて、そこから上を評価するか」を対話で決められる
- `xipe search` で、surface table と `eval_table` を対話のターンを重ねて絞り込める
  （`Old.md` §41）。どちらの対話も tezcatl の対話窓から使える

`xipe serve`（WebSocket）経由でも評価できる。`eval`／`eval/run`／`row/update` はすぐに `pass_id` を
返し、評価は別プロセスで走る（評価中もほかの要求に応答する）。終わると
`notify/rowChanged` と `notify/passCompleted`（独自追加）が届く。評価回は1プロジェクトに
つき1つずつ、来た順に実行する。

§16.3 の method の状態:

| 区分 | method | 状態 |
|---|---|---|
| Tier 1 | `scan/run`・`row/add`・`row/remove`・`effect/set`・`card/get`・`card/search`・`graph/neighbors`・`graph/export`・`cell/resolve` | 実装済み |
| 独自追加 | `row/depends`（上流依存チェーン）・`row/set-result`（値の手入力）・`row/list`（計算行の一覧）・`row/check`（条件に当たる行があれば失敗）・`node/resolve`（住所から node の id）・`notify/passCompleted`（評価回の完了通知） | 実装済み（仕様 v0.4 には無い） |
| 独自追加 | `input`（1行をそのまま受け、CLI と同じ書き方で読む。tezcatl の対話窓用） | 実装済み（2026-09-27、`Old.md` §40） |
| 独自追加 | `eval/status`（いま評価中のパス。評価中の行は変えられない） | 実装済み（2026-10-06、`Old.md` §51） |
| 評価 | `eval`・`eval/run` | 実装済み。CLI（`xipe eval`／`xipe do ... eval`）は同期実行、`xipe serve` では非同期（`pass_id` を返す）。`eval/run` は `Pipeline`（`["eval"]`）経由 |
| Pipeline 経由 | `row/update` | 実装済み。`["edit", "eval"]`：引数を変えてその行だけを評価する（Old.md §37） |
| Tier 3 | `cell/complete` | 未実装 |
| — | `edit/propose`・`edit/apply` | 撤回（参照一覧＋エディタ委譲へ方針転換）。`row/update` の `"edit"` 段とは別物 |
| Tier 4〜5 | `provider/recheck`・`trace/*` | 未実装（trace は凍結） |

未実装の method は例外を投げず、`not_implemented` エラーを返す。

複数のプロジェクトを扱える。`xipe choice project` で対象を選ぶと、以降のコマンドは
そのプロジェクトの Book（`tables/project/<id>_<name>/book.jsonl`）を読み書きする。

**進行中なのは多言語対応。** 言語・REPL・ビルドツールの判定テーブル
（`SurfaceTable`）はできていて、Elixir（＋mix）・OCaml（＋dune）・Haskell（＋stack・cabal）が入っている。残りは
[`document/課題.md`](document/課題.md) を見ること。

---

## 動かし方

```
nix develop

xipe choice project <path> # 対象プロジェクトを登録（初回）して選ぶ。以降の <dir> 省略時の対象になる
xipe table generate [<path>]
                           # ファイル→言語/REPL/ビルドツールの表を作り直して保存
xipe scan [<dir>]          # .ex/.exs を走査し、Book を更新
xipe show [<dir>]          # Book の要約を表示（ノード id もここで分かる）
xipe eval [<dir>] [id...] [--mix] [--include-writes]
                           # 計算行を実評価（id 省略時は全件）
xipe do [--dir <dir>] <method> [key=value...] [-- <method> ...]
                           # method を並べたコマンド列を実行。後ろのコマンドは
                           # "$<番号>.<path>" で前の結果を参照できる。例:
                           #   xipe do row/add node=n1 args=1,2 \
                           #        -- effect/set id=n1 effect=pure \
                           #        -- eval call_ids=$0.id
xipe dialogue depends [<dir>] <call_id>
                           # 依存チェーン交渉（"y <値>" か "n" で答える）
xipe search [<turn>]       # 表（surface table / eval_table）を対話で絞り込む（-h で使い方）
xipe start [<dir>] [--port N] [--lsp <url>] [--fs-root <dir>]
                           # §16.1 WebSocket の入口として常駐し、セッションとして記録する
                           # （既定ポート 4200、$XIPE_TOTEC_PORT でも可）。xipe serve は別名
                           # 未登録の <dir> は登録する（選択中のプロジェクトは変えない）
                           # --lsp/--fs-root は tezcatl の /lsp 中継とファイルルート。省略時は
                           # tezcatl から引き継いだ TEZCATL_RELAY_PORT/TEZCATL_FS_ROOT から決める
                           # tezcatl は <dir> を渡さずに起動する（対象は選択中のプロジェクト。
                           # 決めるのは xipe_totec で、tezcatl は窓）。--port・--lsp・--fs-root は渡す
xipe refresh -l|-r|-a      # xipe_totec 自身の info.json（言語と拡張子・REPL アダプタ一覧）を更新
xipe help [<command>]      # 1行1コマンド（`コマンド: 説明  引数`）の一覧。<command> でその説明

./test/run.sh                         # ExUnit 全件（何も起動せず単体で走る）
elixir test/live/repl_iex_test.exs    # 実機 iex を使うテスト
```

`<dir>` を省略すると、`xipe start` のセッションが動いていればそのプロジェクト、動いて
いなければ選択中のプロジェクトが対象になる（明示した `<dir>` ＞ セッション ＞ 選択中）。
セッションの記録は `tables/session.json` で、正常終了（SIGTERM）で消える。プロセスが
いなくなった記録は無視する。セッション中にそのプロジェクトを CLI で書き換えると、
サーバーの Book とずれるので警告が出る（CLI の書き込みをサーバー経由にするのは未実装）。`<dir>` を渡す場合も、
そのディレクトリは `xipe choice project` で登録済みである必要がある（暗黙には登録しない）。

基本の使い方:

```
xipe choice project ~/work/calc      # 1. プロジェクトを決める（表も作られる）
xipe scan                            # 2. 関数をカードにする
xipe show                            # 3. ノード id を確かめる
xipe do row/add node=<id> args=[2,3] -- effect/set id=<id> effect=pure -- eval call_ids=[$0.id]
                                     # 4. 計算行を作り、副作用を分類し、REPL で評価する
xipe do card/get module=Calc name=add arity=2
                                     # 5. カードを取り出す
```

Mix プロジェクトではない（`mix.exs` なし）。tezcatl と同じ規約で、`main.exs` が
`Code.require_file` で `lib/*.exs` を読み込む素の `elixir` スクリプト。外部の Hex
パッケージ（cowboy・erlexec など）は `nix/relay-packages.nix` から入れる。

プロジェクトごとのデータは `tables/project/<id>_<name>/` に置かれる（`project.json`・
`table`・`book.jsonl`）。対象プロジェクトのディレクトリには何も書かない。`tables/` は
マシンごとのデータなので git 管理外。

`xipe do` の値は、`[...]` で囲むと常にリストになる（`[]` は空、`[10]` は1要素、
`[1,2]` は2要素）。囲まずにカンマを含む値（`args=1,2`）もリストになり、それ以外は
文字列のまま渡る。`row/add` は、ノードが存在し、引数の数がノードの arity（`anykey` が整数のとき）と合うときだけ
行を作る。

---

## 用語

| 用語 | 定義 |
|---|---|
| ブック（Book） | 対象プロジェクト全体。テーブル群（`sheets`/`nodes`/`calls`/`links`/`runs`/`providers`）の集合 |
| シート | 対象プロジェクトのファイル1つ |
| カード | 1関数分の行のまとまり。スキャンで自動的に作られ、関数がソースにある限り存在する |
| 行 | カードを構成する単位。計算行とリンク行の2種 |
| 計算行 | 関数への1回の呼び出し。引数・結果・前回などの列を持つ |
| リンク行 | 関数の接続関係を表す行。受信元・判定式・送信先のセルを持つ |
| 参照 | セル内に `⟦ ⟧` で書かれる、他の計算行の結果への参照 |
| 住所 | 対象を指定する列の組（区切り文字を使わない部分一致フィルタ） |
| pass | 1回の再計算。1つの REPL セッションを起動し、計画された計算行を順に評価して閉じる |
| マーカー | REPL の出力から結果を切り出すための固定文字列（`XT_BEGIN_<id>`/`XT_END_<id>`/`XT_ERROR_<id>`/`XT_EXIT`） |
| trace 表 | 実行時の関数呼び出しを動作順に記録した表 |
| run | trace 表への1回の記録単位 |
| REPL アダプタ | 対象プロジェクトの環境にある REPL を Xipe Totec の共通操作に合わせる、言語ごとの部品（4モジュール） |
| 境界規則 | 言語の境界をまたぐ関数の対応を扱う部品（例: Elixir と Rust をつなぐ Rustler） |
| 提供元 | 構文解析・名前解決の結果を供給するもの（言語サーバー／基本動作） |
| セッション | REPL アダプタが起動した REPL の1回の実行。世代番号を持つ |
| 墓標 | 消失した対象を即削除せず保持する状態 |
| anykey | ノードの照合キー（モジュール・関数名・anykey）の3つ目。同じモジュールの同名の関数を区別するために、言語の Scanner が入れる値。Elixir では arity（`add/2` と `add/3` は別の関数）。名前だけで一意な言語では空でよい。整数なら引数の数としても使われる（`row/add` の確認、`Calc.add/2` の表示）。住所では `arity` も別名として使える |
| visibility | ノードの列。`public` は REPL から呼べる関数、`private` は呼べない関数（Elixir の `defp`）。`private` のノードも参照一覧には出るが、`row/add` で計算行は作れない |
| surface_table | 対象プロジェクトのファイルツリーを、パス・深さ・言語・REPL・ビルドツールの行にした表 |
| エラー値 | 評価できなかったセルが持つ値。参照を通じて下流に伝わる |

---

## tezcatl 連携

[tezcatl](../tezcatl) の relay の `/xipe` が、ブラウザ側のパネル（`panels/matrix.html` など）と
Xipe Totec のサーバーをつなぐ。対象プロジェクトを決めるのは Xipe Totec（`xipe choice project`）で、
tezcatl はその窓に過ぎない。基本は tezcatl の `t` が Emacs と同じく `xipe start` を `<dir>` なしで
:4200 に別のプロセスとして起動し（`t -d` なら背景で）、中継はそこへ WebSocket でつなぐだけ（`xipe.json` の
`mode: "connect"`、2026-09-28）。窓を閉じても止まらない。中継に起動させる `mode: "spawn"` もある
（最後の窓が離れて45秒で止まる）。`xipe.json` のキー（`"."` など）はつなぐ先の名前で、パスではない。
どのプロジェクトが開いているかは `initialize` の結果の `project`（`id`・`root`）で分かる。
§16.2 の「中継は状態を持たない」規定に従い、`/xipe` は `/lsp` のような id 書き換え型の
多重化はせず、状態を持たないブロードキャスト中継にしている（tezcatl 側 `lib/relay/xipe_*.exs`）。

WebSocket の応答には、JSON-RPC の通常の `result`/`error` に加えて `from`（予約、
常に `null`）と `dialogue`（`hold`/`via_repl`/`text`）が付く（`Old.md` §17.2）。

tezcatl の対話窓（`panels/skins/xipe.html`）は、打った1行を解釈せずに `input` `{"text": "<行>"}` で
送る。行の意味は Xipe Totec が決め（書き方は CLI と同じ、`XipeTotec.Input`）、返事の
`dialogue.text` に CLI と同じ行を入れる（`Serve.Input`、`Old.md` §40）。`help` は1行1コマンドの
「`コマンド: 説明`」で、tezcatl の利用者はこれをヤンクして辞書に登録し、補完に使う。

---

## 文書

| 文書 | 答える問い |
|---|---|
| この README | 何のために作られ、何ではなく、いまどこまで動くか |
| [`document/How_to_use.md`](document/How_to_use.md) | いまのコードで、実際にどう使うか |
| [`document/動作原理.md`](document/動作原理.md) | 使う場面ごとに、何がどの順で呼ばれ、どのプログラムが担っているか |
| [`document/拡張の手引き.md`](document/拡張の手引き.md) | 言語やコマンドを足したい人（と、その人の AI）は、何を参考に、どういう動作を満たすように作ればよいか |
| [`document/repl-adapter-guide.md`](document/repl-adapter-guide.md) | 新しい言語・REPL のアダプタをどう書くか（Elixir 実装時点の詳しい参照資料。入口は拡張の手引き） |
| [`document/課題.md`](document/課題.md) | いま何が未解決で、次に何をするか |
| [`document/Old.md`](document/Old.md) | いまの設計が、いつ・なぜそうなったか（決定歴。旧 `XipeTotec_prebuild.md` と旧 `課題.mkd`）。コード中の「Old.md §N」はここの節 |
| `document/xipe_totec_spec_v0.4.html` | 仕様のたたき台（v0.4）。実装との差分がいくつも残っている（`課題.md` の「文書」節）。食い違うときは `Old.md` の決定を優先すること |
