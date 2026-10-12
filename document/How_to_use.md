# 使い方

**この文書が答える問い**: いまのコードで、Xipe Totec を実際にどう使うか。

コマンドの打ち方と、返ってくるものの読み方だけを書く。なぜその形なのかは
`Old.md`、内部で何がどの順に呼ばれるかは `動作原理.md`、未解決の点は `課題.md` を見ること。
出力例は `test/fixtures/calc_sample/calc.exs` を対象に実際に動かしたもの（id は実行ごとに変わる）。

---

## 1. 準備

```
cd ~/my_app/xipe_totec
nix develop
```

開発シェルに入ると `xipe` 関数が定義される（中身は `elixir $XIPE_TOTEC_DIR/main.exs "$@"`）。
`cd` はしないので、`xipe` はどのディレクトリからでも打てる。相対パスの引数は、打った場所から
解釈される。

開発シェルには次のものが入る。

| もの | 用途 |
|---|---|
| Elixir 1.18 / OTP 27 | xipe_totec 自身と、対象プロジェクトの `iex` |
| cowboy・gun・erlexec | WebSocket サーバー、tezcatl の `/lsp` への接続、REPL の起動 |
| elixir-ls | スキャンで使う言語サーバー（tezcatl が無くても自分で起動する） |

対応言語は `info.json` に登録されたものだけで、いまは Elixir（`.ex`/`.exs`）・OCaml（`.ml`）・Haskell（`.hs`）。
OCaml・Haskell を評価するには、対象の環境（flake、§4.3）か PATH に `ocaml`・`ghci` が要る。各言語の
`embody`（別リポジトリ `~/my_app/embody`）も要る（§9.1）。
`lib/repl/language/` に言語を足したときだけ `xipe refresh -l` を打つ（§9）。

---

## 2. 基本の流れ

例として、次の `calc.exs` だけがあるディレクトリ `~/work/calc` を対象にする。

```elixir
defmodule Calc do
  def add(a, b), do: a + b
  def mul(a, b), do: a * b
  def square(x), do: mul(x, x)
  def wide_list, do: Enum.to_list(1..100)
end
```

### 2.1 プロジェクトを選ぶ

```
$ xipe choice project ~/work/calc
xipe choice project: 001  /home/user/work/calc  (new)
```

初回は登録され、3桁の id（`001`）が振られる。以降、`<dir>` を省略したコマンドはすべて
このプロジェクトを対象にする。別のプロジェクトへ切り替えるときも同じコマンドを打つ。
Xipe Totec は対象プロジェクトのディレクトリには何も書かない（データの置き場所は §8）。

### 2.2 スキャンする

```
$ xipe scan
scan/run  ok  %{"link_failures" => [], "links" => 1, "nodes" => 6, "paths" => ["calc.exs"],
  "scanners" => %{"elixir" => %{"scanner" => "XipeTotec.Scanner.Lsp.Elixir", "skipped" => [], "via" => "stdio"}}, "sheets" => 1}
xipe: 1 command(s), 1 ok
```

関数1つが1枚の**カード**（node）になり、関数どうしの呼び出し関係が **link** になる。

- カードになるのは `def`・`defp`・`defdelegate` だけ。マクロは入らない。`defp` は
  `visibility: "private"` として参照一覧には出るが、計算行は作れない
- `mix.exs` と、`deps/`・`_build/` の下は読まない
- 読むファイルは、保存済みのファイル→言語の表（surface table、§8）に載っているものだけ。
  表に載っているファイルが disk から消えていれば、表を作り直して保存してから読む。
  **新しく足したファイルは、`xipe table generate` を打つまで読まれない**（評価も同じ表を使う）
- `scanners.elixir.via` は、どの経路で読んだかを示す。`relay` は tezcatl の `/lsp`、`stdio` は
  自分で起動した elixir-ls。どちらも使えなければ、自前の解析器（`Scanner.Elixir`）で読む
- エディタに未保存の変更があって言語サーバーと disk がずれているファイルは、自前の解析器で
  読み直され、`fallbacks` に出る。カードは常に disk の内容に合わせる

ソースを書き換えたら、もう一度 `xipe scan` を打つ。モジュール名・関数名・arity が同じ関数は
同じ id のまま残り、付けた副作用の分類（§2.4）も残る。関数名や arity を変えると別のカードになる。

### 2.3 中身を見る

```
$ xipe show
project 001  /home/user/work/calc
sheet 01M3D3Z0Z4Q895NNZVKHQF83GF  calc.exs
node  01M3D3Z10ZNS03HPV3Q9GGJZHT  Calc.add/2  effect=unknown
node  01M3D3Z10Z05FB7JYD4GH74Y9V  Calc.square/1  effect=unknown
...
link  01M3D3Z10Z05FB7JYD4GH74Y9V --to--> 01M3D3Z10ZPB9S7SKXVKSBA135
row   01M3D3ZDR9MW08P2VZ6Q73E2RE  Calc.add/2  args=["1", "2"]  3  compare=none
```

`row` は計算行（§2.5）で、id・関数・引数・いまの値（未評価なら `-`）・`compare` の順。
最後の評価が失敗した行は、値の代わりに失敗とその理由、前回の値を出す
（`(error: timeout)  previous=0  state=eval_error`。表に残っている値は前回の評価のもの）。関数がソースから消えた行は
`(node gone)` と出る。

以降のコマンドでは、ここに出る node の id を使う。id を写す代わりに、`node/resolve` で
関数の住所から id を引いて `$0.id` で渡すこともできる（§3.3）。

### 2.4 副作用を分類する

**分類していない関数は評価されない。** 評価する前に、関数ごとに一度だけ分類を付ける。

```
$ xipe do effect/set id=01M3D3Z10ZNS03HPV3Q9GGJZHT effect=pure
```

| effect | 意味 | 評価されるか |
|---|---|---|
| `pure` | 副作用なし | される |
| `reads` | 外部を読むだけ | される |
| `writes` | 外部に書く | `--include-writes` を付けたときだけ |
| `unknown` | 分からない（既定値） | `writes` と同じ扱い |

評価はサンドボックスの中で動くわけではない。`writes` の関数を評価すれば、書き込みは
実際に起こる。

**引数の既定値がある関数**（`def scale(x, k \\ 2)`）は、カードが定義の数（`scale/2`）だけになる。`scale(3)` の計算行を
作るには、呼べる引数の数を一度だけ決める（自動では決めない）:

```
$ xipe do arity/set id=<node> arities=[1,2]
```

決める前は、`row/add` が断るときに自前の解析の提案（「既定値の引数があり 1..2 で呼べます」）が出る。`scan` の結果の
`arity_misses` には、既定値に任せて呼んでいて link にならなかった呼び出しが出る（決めて再スキャンすれば link になる）。
表示は node が `scale/1..2`、計算行が呼ぶ数（`scale/1`）。戻すには `arities=[2]`（定義の数だけ）。

### 2.5 計算行を作って評価する

計算行は「関数への1回の呼び出し」で、引数を保存しておき、何度でも評価し直せる。

```
$ xipe do row/add node=01M3D3Z10ZNS03HPV3Q9GGJZHT args=1,2 -- eval 'call_ids=[$0.id]'
row/add  ok  %{"id" => "01M3D3ZDR9MW08P2VZ6Q73E2RE", "row" => %{...}}
  eval call 01M3D3ZDR9MW08P2VZ6Q73E2RE  ok       repr=exact  3  compare=none
xipe: 2 command(s), 2 ok
```

- 引数は対象言語のソースとして書く（`1`、`"abc"`、`:ok` など）。引数の数が関数の arity と
  合わなければ、`row/add` の時点で拒否される
- `$0.id` は、同じコマンド列の0番目（`row/add`）の結果の `id`。**シェルが `$0` を展開して
  しまうので、必ず単引用符で囲む**（囲まないと `bash.id` になり、`unknown call id` で何も
  評価されない）
- 分類・行の追加・評価は1行にまとめられる（§3.3）

いまある計算行をまとめて評価し直すときは `xipe eval`、特定の行だけなら id を並べる。

```
$ xipe eval
$ xipe eval 01M3D3ZDR9MW08P2VZ6Q73E2RE
```

### 2.6 別の行の結果を参照する

引数に `⟦<計算行の id>⟧` と書くと、その行の結果が入る。表計算のセル参照と同じ。

```
$ xipe do row/add node=<square の id> 'args=[3]'                  # → 9（id を R1 とする）
$ xipe do row/add node=<square の id> 'args=[⟦R1⟧]'              # → square(9) = 81
```

**評価されるのは、指定した行だけ。** R1 を評価しても、R1 を参照している R2 は評価されない
（R2 の値は前回のまま残る）。依存の連鎖をたどって評価したいときは、行を並べて指定する。

```
$ xipe eval <R1> <R2>        # R1 を先に評価し、その結果で R2 を評価する
```

- 並べて指定した行は、参照の順（参照先が先）に評価され、どれも記録される
- 参照先を指定しなかった場合、参照先の値が表にあり、ソースとして書ける（`repr=exact`）なら、その値を使う
- 参照先の値が表から渡せない（まだ評価されていない、または `repr=binary`/`unsupported`）ときは、参照先も
  一緒に指定しないと評価できない。その行は `skipped` と理由が出て、表には何も記録されない。
  参照先を評価し直したくなければ、`xipe dialogue depends <その行の id>` で参照先の代わりの値を
  入れて評価できる（§5）。`binary` は「バイト列では保存できるが、ソースとしては書けない」値
  （例: `@derive {Inspect, only: …}` で欄を隠した構造体）で、その表示は読み戻せないので埋め込まない
- 参照先が副作用の分類で評価できない（未分類、`writes` で `--include-writes` なし）ときも同じ
- 参照が循環している行は評価されない

Book は時系列の記録で、そこに載るのはコマンドで指定した評価だけ。指定していない行を裏で評価
することはしない。

Xipe Totec は関数ごとの確認を基本とし、行を続けて評価することで依存の連鎖を見る。評価する関数が
参照透明なら、渡された値が再現できないもの（参照先の関数が pure でない）でも、その結果は記録として
有効とする。

同じ `xipe do` の中で作った行は、`⟦$<番号>.id⟧` で参照できる（§3.3）。

### 2.7 ソースを変えて、差分を見る

評価のたびに前回の値と比べ、`compare` 列に結果が残る。

```
（mul を a * b + 1 に書き換えて）
$ xipe scan
$ xipe eval
  eval call 01M3D3ZDR9MW08P2VZ6Q73E2RE  ok       repr=exact  3    compare=same
  eval call 01M3D3ZFCV7ZRHV9TSRVETQEE9  ok       repr=exact  10   compare=changed
  eval call 01M3D3ZXG3XMTYHP4WHCN736VZ  ok       repr=exact  101  compare=changed
```

`xipe scan` だけでは再評価は走らない。値を更新したいときは `xipe eval` を打つ。

---

## 3. コマンド

### 3.1 一覧

`<dir>` を省略すると、`xipe start` のセッションが動いていればそのプロジェクト、動いて
いなければ `xipe choice project` で選んだプロジェクトが対象になる。優先順は
「明示した `<dir>` ＞ セッション ＞ 選択中」。`<dir>` を渡す場合は、登録済みでなければならない。

| コマンド | 何をするか |
|---|---|
| `xipe choice project <path>` | プロジェクトを登録（初回）して選ぶ |
| `xipe table generate [<path>]` | ファイル→言語の表（surface table）を作り直す。ファイルを足したら打つ |
| `xipe scan [<dir>]` | ソースを読み、カードと link を更新する |
| `xipe show [<dir>]` | シート・カード・link・計算行の一覧を出す |
| `xipe eval [<dir>] [id...] [--mix] [--include-writes]` | 計算行を評価する（id 省略で全件） |
| `xipe do [--dir <dir>] <method> [key=value...] [-- <method> ...]` | method を並べて実行する（§3.2） |
| `xipe dialogue depends [<dir>] <call_id>` | 依存チェーンを対話で評価する（§5） |
| `xipe start [<dir>] [--port N] [--lsp <url>] [--fs-root <dir>]` | WebSocket サーバーとして常駐する（§6）。`xipe serve` は別名 |
| `xipe config [<dir>] [key=value...]` | プロジェクトごとの設定を見る・変える（§4.3） |
| `xipe refresh -l\|-r\|-a` | xipe_totec 自身の `info.json` を更新する（§9） |
| `xipe help [<command>]` / `xipe version` | `help` は1行1コマンド（`コマンド: 説明  引数`）の一覧。`<command>` を付けるとその説明 |

コマンド列の中に失敗したものが1つでもあると、終了コードは1になる。

### 3.2 `xipe do` で使える method

| method | params | 内容 |
|---|---|---|
| `scan/run` | なし | `xipe scan` と同じ |
| `row/add` | `node` `args` | 計算行を作る。結果の `id` が新しい行の id |
| `row/remove` | `id` | 計算行を消す |
| `effect/set` | `id`（node）`effect` | 副作用を分類する |
| `arity/set` | `id`（node）`arities` | 引数の既定値で呼べる引数の数を決める（§2.4） |
| `row/set-result` | `id` `result` | 評価せずに、結果の値を手で書き込む（対象言語のリテラルで） |
| `row/set-prev` | `id` `prev` | 評価せずに、前回の値（次の評価が比べる相手＝期待値）を手で書き込む。次の評価でまた置き換わる |
| `row/set-args` | `id` `args` | 計算行の引数だけを変える（`row/add` と同じ検査）。**評価しない** ── 値は前の引数のもののまま残るので、あとで `eval` する |
| `eval` | `call_ids`（省略で全件）`include_writes=true` | 評価する |
| `card/get` / `card/search` | 住所（下記） | カード（関数＋その計算行＋link）を取り出す |
| `cell/resolve` | `ref`（`⟦id⟧` の形） | その行の現在の値・repr・state |
| `row/depends` | `call_ids` | その行と、参照で辿れる上流の行を、深い順に並べる |
| `row/list` | `call_ids`（省略で全件） | 計算行の一覧（関数・引数・値・repr・state・compare）。`xipe show` の `row` 行と同じもの。各行の `linked` は、その行の関数がまだあるか（`false` は scan で関数が消えて切れた行。`state` は最後の評価のままなので、`ok` でも切れていることがある。作り直す） |
| `node/resolve` | 住所（下記） | 住所に当てはまる関数を1つに決め、その `id` を返す。0件は `not_found`、2件以上は `ambiguous`（候補付き） |
| `row/check` | `call_ids`（省略で全件）`on`（既定 `error`） | 行が `on` の状態なら失敗する（§3.4） |
| `row/update` | `id` `args` | 計算行の引数を変え（`row/add` と同じ検査）、**その行だけ**を評価する |
| `eval/run` | `call_ids`（省略で全件）`include_writes=true` | `eval` と同じ（仕様 §16 の名前） |
| `eval/status` | なし | いま評価中のパス: 言語・経過時間・対象の行の数と、いま評価している行・その段（下記）。サーバーでは順番待ちのパスも出る |
| `eval/cancel` | `pass_id`（走っているパスが1つなら省略可） | 走っているパスを止める（下記）。サーバーでは、順番待ちのパスを `pass_id` で外すこともできる |
| `config/set` | `key` `value` | 開いているプロジェクトの設定を1つ変える（§4.1。`dialogue update` が最後に実行するもの）。その `project.json` に書く |
| `roster` | なし | `search` が引ける表の一覧: 名前・ターンで書く印（`-s`・`-e`）・列・`dialogue rewrite` で書き換えられる列 |

**パスを止める（`eval/cancel`）。** 走っているパスの REPL をプロセスグループごと止め、そのパスの結果は**何も記録しない**
（先に終わっていた行の分も）。参照透明な関数なら、評価し直せば同じ値が出る。`writes` に分類して `--include-writes` で
評価していたものだけは、書き込みが途中まで残りうる。止まるまでは一瞬（0.2 秒ごとに確かめる）で、REPL の起動中でも止まる。

```
$ xipe do eval/cancel
eval/cancel  ok  pass 01M4R8F0… is being stopped (nothing of it is recorded)
```

- 止められた側は `eval  error  cancelled: …` で終わる（サーバーでは `notify/passCompleted` の `error.code` が `cancelled`）
- `pass_id` は `eval/status` に出る。走っているパスが1つなら書かなくてよい。2つ以上なら書く
- サーバーの順番待ちのパスは `eval/cancel pass_id=<id>` で列から外れる（`status` は `dequeued`）。走っているものは `cancelling`
- 端末が別でも止められる（止める依頼も `passes/` のファイル）。何も走っていなければ `no_pass`
- スキャンは止められない（`範囲.md`）

**評価中の行は変えられない。** パスが走っている間、その対象の行への `row/update`・`row/set-result`・
`row/remove` は `row_in_pass` で断られる（終わってからやり直す）。評価した値が、計算に使っていない
引数の行に書かれるのを防ぐため。端末が別でも、CLI とサーバーのどちらから評価していても同じ
（評価中のパスは `tables/project/<id>_<名前>/passes/` のファイルに残り、両方がそれを見る）。

```
$ xipe do eval/status
eval/status  ok
  running  pass 01M48MJ7ARMHHTZYCYFVSQR9SP  elixir  2s  2 row(s) (not changeable until it ends)
    now  01M48MHW725HG4ERTCN0YY1R3S  S.slow/1  calling  2s
```

段は `calling`（呼び出しを送った）と `classifying`（呼び出しは戻り、値の判定 ── repr・compare ── をしている）。
締め切りで止められた行は、`classifying` のあとなら `session_hung (the call returned; …)` と記録される
（呼び出し自体は終わっていた）。いまの段が分かるのは Elixir だけで、OCaml・Haskell は `calling` のまま

住所は列の組み合わせで絞り込む。使える列は `file`（相対パス）・`module`・`name`・
`arity`（`anykey` でも可）・`row`（計算行の id）。

```
$ xipe do card/get module=Calc name=square arity=1
$ xipe do card/get row=01M3D3ZFCV7ZRHV9TSRVETQEE9      # 計算行が属するカード
```

`graph/neighbors`・`graph/export`（呼び出し関係を辿る、mermaid/dot/json/doctest で書き出す）は、
`address` にオブジェクトを渡す必要があるので `xipe do` からは使えない。WebSocket から使う（§6）。
`cell/complete`・`trace/*`・`provider/recheck` は未実装で、`not_implemented` を返す。

### 3.3 `xipe do` の書き方

コマンドは `--` で区切って並べる。先頭から順に実行され、後ろのコマンドは前のコマンドの
結果を `$<番号>.<キー>` で参照できる（番号は0から）。

```
$ xipe do effect/set id=<node> effect=pure \
       -- row/add node=<node> args=2,3 \
       -- eval 'call_ids=[$1.id]'
```

`<キー>` は `.` でつないで中へ辿れる。数字はリストの位置（`$0.matches.0.id`）。無いキーは
空（`nil`）になる。住所から id を引いて使う例:

```
$ xipe do node/resolve module=Calc name=square arity=1 \
       -- effect/set 'id=$0.id' effect=pure \
       -- row/add 'node=$0.id' 'args=[3]' \
       -- row/add 'node=$0.id' 'args=[⟦$2.id⟧]' \
       -- eval 'call_ids=[$2.id,$3.id]'
```

値の書き方:

| 書き方 | 渡るもの |
|---|---|
| `[]` | 空のリスト（引数なしの関数の `args`） |
| `[10]` | 1要素のリスト |
| `[1,2]` または `1,2` | 2要素のリスト |
| それ以外 | 文字列1つ |

注意:

- `$<番号>.<キー>` が置き換わるのは、値全体がそれだけのときと、`⟦$<番号>.<キー>⟧` の形で
  書いたとき（`⟦<id>⟧` になる）だけ。`'args=[$0.id + 1]'` のような書き方は置き換わらない
- リストの要素はカンマで分けるだけなので、`[1,2,3]` のようなリストを**1つの引数として**渡す
  手段がない（`Enum.sum/1` のような関数の計算行は、いまは CLI から作れない）
- `$`・`⟦⟧`・`[]` を含む値は単引用符で囲む

### 3.4 `row/check` で変化を検出する

`row/check` は、行が `on` に挙げた状態のどれかにあると失敗する。コマンド列の中に失敗が
あると終了コードは1になるので、評価の後ろに付ければ、変化や失敗をスクリプトから検出できる。

| `on` | 失敗する行 |
|---|---|
| `error`（既定） | `state` が `ok` でない（crash・timeout・max_heap） |
| `changed` | `compare=changed` |
| `unevaluated` | 一度も評価されていない |

```
$ xipe do eval -- row/check on=error,changed
row/check  error  check_failed: 2 of 11 row(s): 01M3D6ZW... Calc.square/1 changed; ...
```

見るのは行のいまの値なので、そのコマンド列で評価されなかった行（未分類で `not run` になった
行など）は、前回の評価の状態で判定される。

---

## 4. 評価の中身と、結果の読み方

### 4.1 評価のしかた

評価1回（pass）ごとに、対象プロジェクトの `iex` を新しく起動し、計算行を1つずつ流し込んで、
最後に閉じる。起動のしかたは、surface table に記録されたビルドツール（`build_tool` 列）で決まる。

| `build_tool` | 起動 |
|---|---|
| `mix`（直下に `mix.exs` がある） | `iex -S mix`（依存・設定ごと読み込む） |
| なし | table に載った `.ex`/`.exs` から `defmodule` の部分だけを抜き出した一時ファイルを `iex -r` で読む（トップレベルの処理は実行しない） |

ビルドツールは `xipe table generate`（と初回の `xipe choice project`）のときに1回だけ判定して
table に記録する。後から `mix.exs` を置いたら `xipe table generate` を打つ。判定の優先順位は
言語ごとの申告で決まる（§9）。

`--mix` を付けると、`build_tool` にかかわらず `iex -S mix` で起動する。

REPL（`iex`）は1回の評価（pass）の間だけ保持し、評価が終われば閉じる。評価をまたいで状態や
変数を持ち越すことはない。起動の完了は、`iex` のバナーが出た後に `IO.puts("XT_" <> "READY")` を
送り、`XT_READY` が返ってくることで確かめる。

計算行は1つずつ、別プロセスの中で timeout（既定 5秒）と max_heap 付きで実行される。`iex` の
起動（`XT_READY` が返るまで）を既定で15秒待っても完了しなければ、その pass は `boot_failed` になる。
2つの時間はプロジェクトごとに変えられる（`eval.timeout`・`eval.boot_timeout`、§4.3・§5.4）。評価の出力の
`eval: limit …` の行が、そのパスの上限と、値の出どころのファイルを示す。
起動の途中で `iex` が終了したとき（対象のコードがコンパイルできないなど）も `boot_failed` で、
そのときは `iex` が最後に出した30行（コンパイルエラーのファイル名・行番号を含む）がエラーの文に付く。

### 4.2 出力の読み方

```
  eval call <id>  ok       repr=exact  81  compare=same
  eval call <id>  crash    {:badarith, [...]}  compare=skipped
  eval call <id>  not run  effect not classified -- `effect/set id=... effect=pure` (or reads) to evaluate
```

| 表示 | 意味 |
|---|---|
| `ok` | 評価できた |
| `crash` | 例外で落ちた（理由付き） |
| `timeout` / `max_heap` | 安全装置で止めた |
| `skipped` | 参照先の値を渡せないので評価しなかった（参照先も一緒に指定する）。表には記録しない |
| `aborted` | 同じ pass の中でセッションが固まり、打ち切られた |
| `not run <理由>` | 計画の段階で外された（未分類・`writes`・循環参照・カードが消えた、など） |

`repr` は、値をどう保存したかを表す。

| repr | 意味 |
|---|---|
| `exact` | 表示文字列を評価し直すと同じ値に戻る（数値・文字列・リストなど）。そのまま下流に埋め込める |
| `binary` | 表示では戻らないので、バイナリ（`:erlang.term_to_binary`）でも保存した |
| `unsupported` | pid・関数・参照などを含み、保存できない。表示用の文字列だけ残る |

`compare` は前回の値との比較（`same`/`changed`、初回は `none`、比べられなければ `skipped`）。
浮動小数点は許容誤差込みで比べる。前回値は、評価のたびに `prev` 列へ退避される。

計算行には、評価したときの git の commit・日時・未コミットの変更の有無（`dirty`）も記録される。

---

### 4.3 対象プロジェクトの環境（flake.nix）

対象プロジェクトの直下に `flake.nix` があると、その開発環境の中で `iex` と、自分で起動する
言語サーバー（elixir-ls）を動かす。`nix develop` は毎回起動せず、`nix print-dev-env --json`
で環境変数を1回だけ取り出して `tables/project/<id>_<名前>/env.json` に保存し、以降はそれを使う。
tezcatl の中継経由の言語サーバーは tezcatl の環境で動くので、対象外。

- 取り出すのは `xipe choice project`（初回）と `xipe table generate` のとき。`flake.nix`・`flake.lock`
  の内容が変わったかどうかはハッシュで判定する
- flake の `shellHook` は実行されない。`shellHook` の中で `export` している変数は入らない
- `flake.nix` が無い対象（`shell.nix` だけの対象を含む）は、xipe 自身の環境のまま動く
- スキャン・評価の結果の `env`（`xipe scan` の出力）に、`cached`（保存済みを使った）・`resolved`
  （取り直した）・`stale`・`error` のどれかが出る。`stale`・`error` は評価のときにも警告が出る

設定はプロジェクトごと（`project.json`）で、`xipe config` か `xipe dialogue update`（§5.4。対話窓からも）で見る・変える。
決めていないキーは既定値（xipe_totec の `defaults.json`）になる。一覧の括弧は、取りうる値と、今の値の出どころのファイル。

```
$ xipe config
project 002  /home/user/work/fcalc
env.path=prepend  (prepend|replace, /…/xipe_totec/defaults.json)
env.refresh=auto  (auto|manual, /…/xipe_totec/defaults.json)
eval.boot_timeout=15000  (1000..1800000 ms, /…/xipe_totec/defaults.json)
eval.timeout=5000  (100..600000 ms, /…/xipe_totec/defaults.json)
$ xipe config env.refresh=manual eval.timeout=20000
```

| 設定 | 値 | 意味 |
|---|---|---|
| `env.path` | `prepend`（既定） | flake の `PATH` を xipe の `PATH` の前に足す。対象のツールが優先され、`git` などの周辺コマンドも使える |
| | `replace` | flake の `PATH` だけを使う。flake に無いコマンドは使えない（elixir-ls は初回に `git` を使うので、flake に `git` が無いと起動しない） |
| `env.refresh` | `auto`（既定） | flake が変わっていれば、次のスキャン・評価のときに取り直す（その回は数秒遅くなる） |
| | `manual` | `xipe table generate` のときだけ取り直す。それまでは古い環境のまま動き、警告を出す |
| `eval.timeout` | ms（既定 5000、100〜600000） | 計算行1件が走ってよい時間。超えた行は `timeout`。変えると次のパスから効く |
| `eval.boot_timeout` | ms（既定 15000、1000〜1800000） | パスが REPL の準備（ビルド込み）を待つ時間。超えると `boot_failed` |

新しい環境で elixir-ls を初めて起動すると、elixir-ls が自分自身をコンパイルするので時間がかかる。
そのスキャンは待ちきれずに自前の解析器（`Scanner.Elixir`）へ切り替わることがあるが、2回目からは
elixir-ls で読む。

## 5. 依存チェーン交渉（`xipe dialogue depends`）

参照でつながった行のうち、上流のどこかに値を手で入れて、そこから下流だけを評価したいときに使う。
上流が重い・副作用がある・まだ書けていない、といった場合に向く。

```
$ xipe dialogue depends 01M3D3ZXG3XMTYHP4WHCN736VZ
;; w1 Calc.square/1
01M3D3ZFCV7ZRHV9TSRVETQEE9 に値を入れて評価しますか？(y/n)
> y 4
01M3D3ZFCV7ZRHV9TSRVETQEE9 (Calc.square/1) に値を注入し、そこから指定した行までを評価します。
row/set-result  ok  %{"id" => "01M3D3ZFCV7ZRHV9TSRVETQEE9", "result" => "4"}
  eval call 01M3D3ZXG3XMTYHP4WHCN736VZ  ok       repr=exact  17  compare=changed
```

- 深い段から順に聞かれる。`y <値>`（対象言語のリテラル）で、その段に値を入れ、そこから
  指定した行までを評価して終わる。`n` なら1段浅い方へ進む
- 全部 `n` で答えると何も実行しない
- 評価される段は `writes` も含む（ただし分類済みであること）
- tezcatl の対話窓からは `dialogue depends <call_id>` で始め、次の行で `y <値>` / `n` と答える
- `quit dialogue` で途中でやめられる

### 5.1 検索（`xipe search`）

表を順に絞り込む対話。1つのプロセスの中でリスト（と `x`）を持ち続けるので、`xipe search` で
プロンプト（`search>`）に入り、ターンを打つ。最初のターンは `xipe search` の後ろに書いてもよい。
tezcatl の対話窓では `search` で始め、1行が1ターン。

```
$ xipe search -s path lib/calc.ex path
1 hit(s). (path: [lib/calc.ex])
search> -e path list id
2 hit(s). (id: [01M3…, 01M3…])
search> get id -2
took the id of element 2 of the result: 01M3… (write x for it from now on)
search> eval x
  eval call 01M3…  ok       repr=exact  9  compare=none
search> -e view id id name args result
…
End the search? y/n
search> y
```

| ターン | 動き |
|---|---|
| `-s\|-e <列> <値> [<取り出す列>]` | `<列>` が `<値>` の行の `<取り出す列>`（既定 `id`）をリストにして保持する |
| `-s\|-e <列> list <取り出す列>` | 保持中のリストの値ごとに `<列>` を探す（リストを置き換える） |
| `-s\|-e view <列> [<表示する列>...]` | リストの値に合う行を表示し、終えるかを聞く（`y` で終了、`n` で続ける） |
| `get id [-n]` | リストの n 番目（1から）を `x` として保持する。無ければ `No match data` |
| `quit dialogue` | 終える |
| それ以外 | 普通のコマンドとして実行する（対話は続く）。`x`（`id=x`・`call_ids=[x]`・`⟦x⟧` も）は保持した id に置き換える |

- `-s` は surface table（列: `id path depth language repl build_tool`）、`-e` は `eval_table`
  （計算行に関数と `path` を横付けした表。列は `-h` で出る）。引ける表と列の一覧は `xipe do roster` でも出る
- 値は完全一致。`~<値>` で部分一致（`-e args ~⟦<id>⟧ id` でその行を参照している行）、`-` で空の
  セル（`-e module -` で関数が消えた行）。数値は文字として比べる。10件を超えると先頭10件と件数
- 検索そのものは何も書き換えない。書き換えるのは、検索の中で打った普通のコマンドだけ

### 5.2 尋ねてもらって実行する（`xipe dialogue do`）

`xipe do <method> …` を、引数を1つずつ尋ねてもらって組み立てる対話。1行では書けない値（カンマを含むリスト・空白や
引用符を含む文字列・タプル）を、**打ったとおり**に渡せる。関数の id を写す必要も無い。

```
$ xipe dialogue do row/add
node? (a function: its id, or its name as Calc.add/2)
do> Calc.average/1
args? (a list of 1: { alone to open, one per line, } alone to close)
do> {
args: open -- one per line, } alone to close
do> [1, 2, 3]
  1: [1, 2, 3]
do> }
row/add
  args = {
    [1, 2, 3]
  }
  node = 01M4R8BV…  (Calc.average/1)
Run it? (y/n)
do> y
Running row/add.
row/add  ok  …
```

- 尋ねるのは、その method に**必ず要る引数のうち、行に書かなかったもの**だけ。書いた分は尋ねない
  （`xipe dialogue do effect/set id=Calc.add/2` なら `effect` だけ）。省ける引数は尋ねないので、要るなら始める行に書く
- 答えは行をそのまま受け取る（語に割らない・引用符を外さない・カンマを読まない）
- **関数**は id か、表示されている名前で答える: `Calc.add/2`、引数の数を持たない言語は `Module.name`。同じ名前の関数が
  2つ以上あれば、候補を並べて尋ね直す。始める行に `node=Calc.add/2` と書いてもよい
- **リスト**は、`{` だけの行で開き、1行に1要素、`}` だけの行で閉じる。行全体が `{`・`}` のときだけ開閉するので、要素が
  `{1, 2}` や `%{a: 1}` でも構わない。`{` のすぐ次に `}` で空のリスト。計算行の `args` は閉じたときに数を確かめ、合わなければ
  尋ね直す
- 選択肢・数は、合わない答えなら同じことをもう一度尋ねる
- 全部揃うと、呼び出しを「引数 = 値」で見せる。**Book を書く method は `y`（実行）か `n`（やめる）を待つ**。読むだけのものは
  そのまま実行する
- `quit dialogue` で、何も実行せずにやめる
- tezcatl の対話窓では `dialogue do <method> …` で始め、1行が1つの答え

### 5.3 表の値を手で書き換える（`xipe dialogue rewrite`）

表の値を1つ、**評価せずに**書き換える対話。表 → 行 → 列 → 値の順に尋ねる。期待値を置く（`prev`）、値を手で入れる
（`result`）、引数だけ変える（`args`）、関数の分類を変える（`effect`）に使う。

```
$ xipe dialogue rewrite
row? (its id in the eval_table)
rewrite> 01M4R9XA…
id=01M4R9XA…  node=01M4R8BV…  module=Calc  name=average  …  args=[1, 2, 3]  result=2.0  …
column? (args | effect | prev | result)
rewrite> prev
prev? (the line is taken as it is)
rewrite> 3.0
row/set-prev
  id = 01M4R9XA…  (Calc.average/1)
  prev = 3.0
Run it? (y/n)
rewrite> y
Running row/set-prev.
row/set-prev  ok  …
$ xipe eval 01M4R9XA…
  eval call 01M4R9XA…  ok  repr=exact  2.0  compare=changed
```

- 表・行・列は始める行に書いてもよい（`xipe dialogue rewrite -e <行の id> prev`）。書いた分は尋ねない。**値は必ず尋ねる**
  （行に書くと語に割られるので、1行まるごとで受け取る）
- 表は `search` と同じ印（`-e`）か名前（`eval`）。書き換えられる列がある表が1つだけの間は尋ねない
- 行を答えると、その行を全部の列で見せる（何を変えようとしているかを確かめるため）
- 書き換えられるのは `xipe do roster` に `rewritable` と出る列だけ: `args`・`result`・`prev`・`effect`。それ以外
  （`compare`・`repr` など）は評価やスキャンが決める値なので断る
- 列ごとに、今ある method を1つ実行する: `args` → `row/set-args`、`result` → `row/set-result`、`prev` → `row/set-prev`、
  `effect` → `effect/set`。実行の前に呼び出しを見せて `y/n` を待つ。method の検査（引数の数、評価中の行は変えられない）は
  そのまま効く
- **評価はしない。** `args` を変えても値は前の引数のもののまま残る。あとで `eval` する（変えて評価まで一度にするなら
  `row/update`）
- `effect` はその行のものではなく関数のもの。その関数の行すべてに効く、と値を尋ねる前に言う
- 値の入れ方は `dialogue do`（§5.2）と同じ: 行をそのまま、リスト（`args`）は `{` と `}` の行で囲む
- surface table（`-s`）にはまだ書き換えられる列が無い（言語を手で決める `surface/set` は案）
- `quit dialogue` で、何も変えずにやめる

### 5.4 設定を変える（`xipe dialogue update`）

開いているプロジェクトの設定を1つ変える対話。ファイル → キー → 値の順に尋ねる。計算行の時間の上限（`eval.timeout`）と
REPL の起動を待つ時間（`eval.boot_timeout`）はここで変える。

評価すると、そのパスの上限と、その値がどのファイルから来たかが1行出る。

```
$ xipe eval
  eval: limit 5s per row (eval.timeout, /…/xipe_totec/defaults.json), 15s to boot (eval.boot_timeout, /…/xipe_totec/defaults.json)
  eval call 01M4R8BX…  timeout  compare=skipped
$ xipe dialogue update
  1  /…/xipe_totec/defaults.json  (the defaults)
  2  /…/tables/project/001_calc/project.json  (this project's settings)
file? (1-2)
update> 1
/…/defaults.json holds the defaults, which are every project's: the change is written to /…/001_calc/project.json
  env.path = prepend  (prepend|replace)  default
  env.refresh = auto  (auto|manual)  default
  eval.boot_timeout = 15000  (1000..1800000 ms)  default
  eval.timeout = 5000  (100..600000 ms)  default
key?
update> eval.timeout
eval.timeout? (100..600000 ms)
update> 20000
to be written to /…/001_calc/project.json
config/set
  key = eval.timeout
  value = 20000
Run it? (y/n)
update> y
config/set  ok  eval.timeout=20000 (eval.timeout, /…/001_calc/project.json)
```

- **ファイル**は、xipe が最近出した行に出てきた設定のファイルを、新しい順に別々のものを5つまで、番号を付けて見せる。
  `1`〜`5`（またはパス）で答える。開いているプロジェクトの `project.json` は必ずその中にある。1つしか無ければ尋ねない
- 選んで意味があるのは2つ: このプロジェクトの `project.json` と、既定値の `defaults.json`。**既定値を選んでも既定値の
  ファイルは書き換えない**（全部のプロジェクトのものなので）── 値はこのプロジェクトの `project.json` に書く、と言ってから進む。
  ほかのプロジェクトのファイルは断る（`xipe choice project` で開いてから）
- **キー**を尋ねるとき、全部の設定を「今の値・取りうる値・このプロジェクトが決めたものか既定値か」で見せる
- **値**は打った時点で確かめ、合わなければ理由を言って尋ね直す。時間は ms の整数（`eval.timeout` は 100〜600000、
  `eval.boot_timeout` は 1000〜1800000）
- 書く前に呼び出しを見せて `y/n` を待つ。**変えた上限は次のパスから効く**（走っているパスには効かない。止めるなら `eval/cancel`）
- ファイルとキーは始める行に書いてもよい（`xipe dialogue update 2 eval.timeout`）。値は必ず尋ねる
- 出した行の記録は `tables/logging_buffer.txt`（100行まで。全プロジェクト共通、CLI とサーバーで同じファイル）。対話窓の返事も入る
- `xipe config [key=value]` は今までどおり使える（1行で書けるのでスクリプト向き）。一覧は、取りうる値と値の出どころのファイルつき

---

## 6. 常駐サーバー（`xipe start`）

```
$ xipe start --port 4200
xipe start: ws://127.0.0.1:4200/  root=/home/user/work/calc  store=.../tables/project/001_calc/book.jsonl
xipe start: lsp relay ws://127.0.0.1:4100/lsp  fs_root=-
```

- `127.0.0.1` だけで待ち受け、認証はない
- ポートは `--port`、`$XIPE_TOTEC_PORT`、既定 4200 の順に決まる
- 動いている間は `tables/session.json` に記録が残り、ほかの CLI コマンドはこのプロジェクトを
  対象にする。二重起動は拒否される。SIGTERM で終了すると記録は消える（`kill -9` や Ctrl-C で
  残った記録は無視される）
- セッション中に CLI で書き込んだ変更は、サーバーが次の要求のときに取り込む（`book.jsonl` への書き込みは
  ロックで順番になる）。CLI が出す警告の「サーバーを再起動するまで見えない」は古い文言

### 6.1 プロトコル

WebSocket（パス `/`）に JSON-RPC 2.0 のテキストを1フレーム1メッセージで送る。最初に
`initialize` を送る。それより前の要求は `not_initialized` で拒否される。

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"project":{"id":"001","root":"/home/user/work/calc"}}}

→ {"jsonrpc":"2.0","id":2,"method":"row/add","params":{"node":"01M3...","args":["20","22"]}}
← {"jsonrpc":"2.0","id":2,"result":{"id":"01M3...","row":{...}},"from":null,"dialogue":{"hold":false,"via_repl":false,"text":null}}
← {"jsonrpc":"2.0","method":"notify/rowChanged","params":{"id":"01M3...","columns":[...],"row":{...}}}
```

- method と params は §3.2 と同じ。ここでは `graph/neighbors`・`graph/export` も使える
  （`{"address":{"module":"Calc","name":"square"},"depth":1,"direction":"both"}`、
  `graph/export` は `"format":"mermaid"` など）
- `eval`・`eval/run`・`row/update` はすぐに `{"pass_id":...,"status":"started"}`（先に実行中の
  ものがあれば `"queued"`）を返し、裏で評価する。終わると、変わった行ごとに `notify/rowChanged`、
  最後に `notify/passCompleted`（結果の一覧付き）が、接続中の全クライアントに届く。`row/update`
  の引数の変更はその場で反映され（応答の `row` と `notify/rowChanged`）、評価だけが裏で走る
- `scan/run` は完了してから応答する。その間もほかの要求には応える
- 行やカードが変わるたびに `notify/rowChanged`・`notify/nodeChanged` が届く
- 応答には JSON-RPC の通常の欄に加えて、`from`（常に `null`）と `dialogue` が付く

### 6.2 `input` ── 1行をそのまま送る（tezcatl の対話窓）

`{"method":"input","params":{"text":"<打った1行>"}}`。行の意味は Xipe Totec が決める。
tezcatl の対話窓はすべての行をこの形で送り、中身を解釈しない。

- 行の書き方は端末で `xipe` に続けて打つものと同じ（先頭の `xipe` はあってもよい）。
  `help [<command>]`・`version`・`show`・`scan`・`eval [id...] [--include-writes]`・
  `do <method> ... [-- <method> ...]`。method 名から始めた行は `do` を省いたものとして読む。
  引用符（`'id=$0.id'`）はシェルと同じく外す
- **文字列の引数は引用符ごと包む**: 上のとおり `"` も外れるので、`args=["hi"]` は `args=[hi]`
  （変数 `hi`）になり、評価すると `undefined variable "hi"` で crash する。`'args=["hi"]'` と書く
  （端末でシェルに打つときと同じ書き方）
- **1行が1回の `input`**。複数の行を続けて送ると、行どうしは同時に走る（行ごとに別のプロセス）。
  前の行の結果（`scan` で増えた関数、`row/add` した行、評価した値）を次の行で使うなら、返事を
  待ってから送るか、`--` でつないで1行にする
- 端末が要るコマンド（`choice project`・`table generate`・`start`・`config`・`refresh`）は `input_error` で断る
  （`dialogue depends`・`dialogue do`・`dialogue rewrite`・`dialogue update`・`search` は窓からも使える。設定は窓からは
  `dialogue update` か `config/set` で）
- 返事の `dialogue.text` に、CLI が出すのと同じ行が入る。コマンドなら `result.outcomes` に
  コマンドごとの `method`・`ok`・`result`・`error` も入る。読めない行は `input_error`
- 評価（`eval`・`eval/run`・`row/update`）を含む行は、その評価が終わるのを待ってから次の
  コマンドへ進み、全部終わってから1回だけ返事をする（`... -- eval ... -- row/check` が CLI と
  同じ意味になる）。待っている間も、その接続のほかの要求には応える
- 対話（例: 依存チェーン交渉）を保持している間は、次の行がその答えになる

```
→ {"jsonrpc":"2.0","id":3,"method":"input","params":{"text":"help"}}
← {"jsonrpc":"2.0","id":3,"result":{},"from":null,
   "dialogue":{"hold":false,"via_repl":false,"text":"help: list the commands (…)  [<command>]\n…\nrow/add: make a calc row  node=<node id> args=[...]\n…"}}
```

`help` の1行は「最初の `:` の前がコマンド、後ろが説明と引数」。tezcatl ではこの行をヤンクして
辞書パネルで `p` を押すと、コマンドが補完の候補になる。

### 6.3 tezcatl から使う

基本は tezcatl の開発シェルの `t` が、Emacs と同じく `xipe start` を `<dir>` なしで :4200 に
別のプロセスとして起動する（ログは `/tmp/tezcatl-xipe.log`）。`t` は前面で動き、Ctrl+C で
Xipe Totec も止める（:4200 が使用中なら何も起動せずに断る）。`t -d` は :4200 が空いているときだけ
背景で起動して戻り、止めるときは `tables/session.json` の pid に SIGTERM を送る。
tezcatl の中継はそこへつなぐだけなので、窓を閉じても止まらない。対象は選択中のプロジェクトで、選ばれていなければ
すぐ終わる（ログに出る）。対象を決めるのは Xipe Totec 側で、tezcatl は窓にすぎない。先に
`xipe choice project` で選んでおくこと。

`t` や tezcatl の中継（`xipe.json` が `mode: "spawn"` のとき）が起動するときは `--port`・`--lsp`（tezcatl の `/lsp` 中継の URL）・`--fs-root`
（tezcatl のファイルのルート）を渡す。これでスキャンは tezcatl の言語サーバーを共用する。
手で起動するときに同じことをしたければ、これらを自分で渡すか、環境変数で指定する（§10）。
tezcatl がいなくても、elixir-ls を自分で起動して読むので動作は変わらない。

---

## 7. 対話で使うときの流れ（まとめ）

```
xipe choice project ~/work/calc          # 1度だけ
xipe scan                                # ソースを変えるたびに
xipe show                                # node の id と計算行の値を見る
xipe do effect/set id=<node> effect=pure # 関数ごとに1度だけ
xipe do row/add node=<node> args=1,2     # 試したい呼び出しを保存
xipe eval                                # 何度でも。compare で変化を確かめる
```

---

## 8. データの置き場所

すべて xipe_totec のディレクトリの中にあり、対象プロジェクトには書かない。
`tables/` はマシンごとのデータなので git 管理外。

| ファイル | 中身 |
|---|---|
| `info.json` | 登録済みの言語と拡張子、言語ごとの REPL とビルドツールの優先順位、REPL アダプタ |
| `pipelines.json` | Pipeline 経由の method の登録（通常は触らない） |
| `tables/project/<id>_<名前>/project.json` | 対象プロジェクトの絶対パス（照合キー）と、プロジェクトごとの設定（§4.3） |
| `tables/project/<id>_<名前>/env.json` | flake.nix から取り出した環境変数とハッシュ（§4.3） |
| `tables/project/<id>_<名前>/table` | ファイル→言語の表（言語・REPL・ビルドツール）。スキャン・評価はこれを読む |
| `tables/project/<id>_<名前>/book.jsonl` | Book。追記のみの JSON Lines で、同じ id の最後の行が現在の値 |
| `tables/selection.json` | 選択中のプロジェクト（`xipe choice project` が書く） |
| `tables/logging_buffer.txt` | xipe が出した行の記録（100行まで。全プロジェクト共通。`dialogue update` がファイルを選ぶのに読む） |
| `defaults.json`（xipe_totec の直下、git 管理） | 設定の既定値。プロジェクトが決めていないキーはここから |
| `tables/session.json` | 動いている `xipe start` の記録 |
| `tables/project/<id>_<名前>/passes/` | いま評価中のパス（言語ごとに1ファイル。終われば消える。`eval/status`、評価中の行を変えさせない） |

`book.jsonl` は追記だけで、書き換えない。壊れた行（書き込み途中で落ちたなど）は読み込み時に
無視される。

ただし elixir-ls は、Mix プロジェクトのディレクトリに `.elixir_ls/` を作る。

---

## 9. 言語を足したとき（`xipe refresh`）

```
xipe refresh -l     # lib/repl/language/*.exs を読み、言語名・拡張子・REPL・ビルドツールを info.json に書く
xipe refresh -r     # lib/repl/eval/scan/<transport>/*.exs を読み、REPL アダプタを書く
xipe refresh -a     # 両方
```

自動では走らない。モジュールを足したり消したり、申告（ビルドツールの優先順位など）を変えたり
したら、自分で打つ。そのあと、対象プロジェクトで `xipe table generate` を打つと table に反映される。書き方は
`repl-adapter-guide.md` を見ること。1つのプロジェクトに登録済みの言語が2つ以上ある場合、行は
それぞれの関数の言語（surface table の `language`）ごとに分けられ、言語ごとの REPL で並行して
評価される。言語の違う行を `⟦id⟧` で参照している行は評価されず、`not run` と理由が出る（値の
書き方が言語ごとに違い、まだ変換しないため）。

### 9.1 OCaml（2026-09-27）

- 評価は素の `ocaml` トップレベルで行う。`embody.ml`（別リポジトリ `~/my_app/embody/`。xipe_totec の隣が
  既定で、`XIPE_TOTEC_EMBODY_DIR` で変えられる。無いと各行が `Unbound module Embody` の crash になる）を読み込み、
  各行の呼び出しを必ずこれで包む。対象の `.ml` は1ファイル1モジュール（`geometry.ml` は
  `Geometry`）として読み込む。トップレベルの式と `let ()`/`let _` は実行しない。ファイル間の
  依存の順は、失敗したものを後で読み直して決める
- 計算行の引数は OCaml のソースで書く（`args=[Geometry.Circle 2.]`）。呼び出しは
  `M.f (a) (b)`（引数ごとに括弧）。引数なしは値そのもの（`M.origin`）。`unit` を取る関数は
  `args=[()]`
- `repr`: 表示された値をもう一度評価して `=` で等しければ `exact`。関数（`<fun>`）、循環
  （`<cycle>`）、インラインレコードなど読み戻せないものは `unsupported`。`binary` は無い。
  `type` は OCaml の型そのもの（`Geometry.shape list`）
- 結果の例: 例外は `crash  Exception: Failure "hd".`、型エラーは OCaml の文言そのまま、
  時間切れは `timeout`（1件ずつ SIGALRM）。メモリの上限は無く、固まればトップレベルごと落とす
- スキャン（`Scanner.Ocaml`）はテキストから読む: 行頭のトップレベルの `let`/`let rec`/`and` が
  関数（`anykey` は空、同名は後ろのもの）。入れ子のモジュールの中はまだ読まない。呼び出し関係は
  `Mod.name` と同じファイルの名前の出現から推定する
- **dune のプロジェクト**（根に `dune-project`、Old.md §43）: 依存するライブラリ（`str` や、`OCAMLPATH` で
  見える外部パッケージ）は `dune ocaml top` から読み込む。プロジェクト自身のコードはソースから（副作用なし）。
  ライブラリの外からの書き方（`Mylib.Words.count`）も使える（`dune` ファイルの `(library (name mylib))` から
  別名を作る）。評価のたびに dune がプロジェクトをビルドする（対象に `_build/` ができる）。dune と依存は
  対象の環境（flake）に要る
- 未対応: ppx を使うファイル（ソースをそのまま読むため）、同じ名前のファイルが2つある構成、
  1つの `dune` ファイルに複数のライブラリ（別名を作らない）。言語サーバー（ocamllsp）は使わない
  （`callHierarchy` が無い、Old.md §42.4）

### 9.2 Haskell（2026-09-27）

- 評価は GHCi（`ghci -v0 -fdefer-type-errors …`）で行う。`embody.hs`（`~/my_app/embody/`）と対象の `.hs` を
  `:load` し、各モジュールを `*M` でスコープに入れる。export されていない関数も `M.f` で呼べる。`main` は走らない
- モジュールは各ファイルの `module X` の行から（無ければ `Main`）。`src/Geo/Shape.hs` の `Geo.Shape` なら `src` を
  探索パスに入れる。`Main` のファイルが2つ以上あると一緒に読めないので、そのときは `Main` を読まない
- 計算行の引数は Haskell のソースで書く（`args=["x"]`、`args=[[] :: [Int]]`）。呼び出しは `M.f (a) (b)`、
  引数なしは値そのもの
- `repr`: `Read`・`Show`・`Eq` があり `show` が読み戻せて等しければ `exact`（`Map` も）。`Show` だけなら `show` を
  2000文字で切った `unsupported`（無限リストも返る）。`Show` が無ければ型を表示にした `unsupported`
  （関数 `Int -> Int`、`IO [Char]` は実行しない）。`type` は値の型（`[Shape]`、`Map [Char] Int`）
- 失敗: 例外・型エラーは GHC の文言の `crash`。呼び出しの構文エラーは `crash … Variable not in scope: xt_<id>`
  （本来の構文エラーの文言は REPL の出力に出る）。時間切れは `timeout`
- スキャン（`Scanner.Haskell`）はテキストから: 行頭のトップレベルの定義（複数の節は1つ、型シグネチャ・演算子・
  宣言は除く）。呼び出し関係は `M.f`（`import … as N` の別名も）、同じモジュールの名前、修飾なしの import の名前から
- **cabal・stack のプロジェクト**（根に `*.cabal`/`cabal.project`、`stack.yaml`、Old.md §47）: GHCi を
  `cabal exec --offline --`（その前に `cabal build --offline all`）・`stack exec --` の下で起動し、依存パッケージを
  見えるようにする。プロジェクト自身のモジュールは、ライブラリも実行ファイルもテストもソースから読む。依存パッケージは
  あらかじめ使える状態であること（nix の `ghcWithPackages`、事前のビルドなど。`--offline` なので評価中に取りに
  行かない）。対象に `dist-newstyle/`・`.stack-work/` ができる
- 未対応: `IO` を返す関数の実行

---

## 10. 環境変数

| 変数 | 意味 |
|---|---|
| `XIPE_TOTEC_PORT` | `xipe start` の既定ポート |
| `XIPE_TOTEC_LSP=off` | 言語サーバーを使わず、自前の解析器でスキャンする（テストはこれで走る） |
| `XIPE_TOTEC_LSP_RELAY` | tezcatl の `/lsp` 中継の URL（`--lsp` と同じ） |
| `XIPE_TOTEC_LSP_FS_ROOT` | tezcatl のファイルのルート（`--fs-root` と同じ） |
| `TEZCATL_RELAY_PORT` / `TEZCATL_FS_ROOT` | tezcatl から起動されたときに引き継ぐ値。上の2つが無ければこれから決める |

---

## 11. つまずきやすいところ

| 症状 | 原因と対処 |
|---|---|
| `no project selected` | `xipe choice project <path>` を先に打つ |
| `<dir> is not a registered project` | `<dir>` を渡すなら、先に `xipe choice project <dir>` で登録する |
| `not run  effect not classified` | `effect/set` で分類していない。§2.4 |
| `not run  effect=writes -- pass --include-writes` | `xipe eval --include-writes`（`xipe do` なら `eval include_writes=true`） |
| `eval call bash.id  not run  unknown call id` | `$0.id` を引用符で囲んでいない。§3.3 |
| `crash ... undefined variable "hi"`（文字列を渡したつもり） | `"` が語の解釈で外れた。`'args=["hi"]'` と引用符ごと包む（端末でも対話窓でも同じ。§3.3・§6.2）。`dialogue do row/add` なら打ったとおりに渡る（§5.2） |
| リストを1つの引数にしたいのに、カンマで割れる（`args=[1,2,3]` が3つの引数になる） | 1行の書き方では書けない。`xipe dialogue do row/add`（§5.2）で、`{` と `}` の行で囲んで1行に1要素 |
| 評価が終わらない・待ちたくない | `xipe do eval/cancel`（§3.2）。別の端末からでも、対話窓からでも |
| `timeout`（重い関数） | 1件あたりの上限（既定 5秒、§4.1）。`xipe dialogue update` で `eval.timeout` を伸ばす（§5.4） |
| 対話窓で、前の行で足したはずの関数・計算行が「無い」と言われる | 前の行がまだ終わっていない（行どうしは同時に走る）。返事を待つか `--` で1行にする（§6.2） |
| `row/add: ... takes 1 arg(s), got 3` | 引数の数が合わない。リストを1引数で渡せない制限にも注意（§3.3） |
| `row/add: ... is private` | `defp` の関数は計算行にできない |
| `skipped  upstream ... has no value that can be written into the call` | 参照先の値が表に無い（未評価）か、ソースとして書けない（`binary`・`unsupported`）か、参照先が評価できない。参照先の id も並べて指定するか、`dialogue depends` で値を入れる（§2.6） |
| `row_in_pass: row ... is being evaluated` | その行はいま評価中。終わってから変える。何が走っているかは `xipe do eval/status`（§3.2） |
| `crash` のスタックトレースの行番号がずれる | `mix.exs` のない対象では、抜き出した一時ファイル上の行番号になる |
| `boot_failed: the REPL exited before it was ready` | 起動中に `iex` が終了した。たいていは対象のコードがコンパイルできない。続く出力にファイル名と行番号が出る |
| `boot_failed`（`:timeout`） | REPL が時間内（既定 15秒）に起動しなかった。`eval.boot_timeout` を伸ばす（§5.4）か、Mix プロジェクトなら一度 `mix compile` を済ませておく |
| `xipe start: a session is already running` | 既に動いている。止めるなら記録にある pid に SIGTERM を送る |
| サーバーの表に CLI の変更が出ない | サーバーは次の要求で取り込むが、tezcatl の表は自動では変わらない。`matrix update` で取り直す |
| スキャンが遅い | 初回は elixir-ls の起動を待つ。急ぐなら `XIPE_TOTEC_LSP=off` |
| `env stale (flake.nix)` | `env.refresh=manual` で、flake が変わった。`xipe table generate` で取り直す（§4.3） |
| `env error (flake.nix)` | `nix print-dev-env` が失敗した（flake の評価エラー、git 管理下で `flake.nix` が未追跡、など）。xipe 自身の環境か、前回の環境で動く |
| mix プロジェクトなのに scripts-mode で起動する | ビルドツールは table を作ったときの判定。`xipe table generate` を打つ |
| `stdio: language server exited (status 1)`（`env.path=replace`） | flake の `PATH` に elixir-ls が必要とするコマンド（`git` など）が無い。flake に足すか `prepend` にする |
