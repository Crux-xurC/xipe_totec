# REPLアダプタ追加ガイド（新しい言語/REPLを足すとき用）

対象読者: Elixir以外の言語（spec §12.6の候補: Haskell/GHCi、OCaml/utop、Clojure、Racketなど）のREPLアダプタを新しく書く人（人間・AIのどちらも想定。このセッションの会話内容を知らない前提で書いてある）。

**2026-09-18時点でElixir向けの実装は完成し、実機の`iex`で全パイプライン(起動→完了検知→評価→compare判定→パース→離脱)を確認済み。** このガイドの各項目は、もう「設計だけ」ではなく`lib/repl/`配下に動くコード例がある。新しい言語を足すときは、まずそのコードを読むこと。`compare`判定・`Core.plan_recalc`/`Core.apply_results`との配線(`Repl.Evaluator`)・`xipe eval`/`xipe do`のCLIまで含めて動く(`Old.md` §11〜14)。

## 前提となる設計（変更しないこと）

Xipe Totecは対象プロジェクトのREPLへ人間が手で式を打ち込んで確認するのと同じ操作を自動化する（`Old.md` §10）。全体は「**言語/REPLごとの算出プログラム**（JSONデータやコード片を作るだけ、純粋関数）」と「**汎用の実行層**（それを読んで実行するだけ、言語知識ゼロ）」に分かれている。**新しい言語を足すときは、算出プログラム側だけを書けばよい。汎用の実行層(`lib/repl/sender.exs`/`lib/repl/sender_direct.exs`/`lib/repl/session.exs`/`lib/repl/eval/scan.exs`/`lib/repl/eval/field_drip.exs`/`lib/repl/eval/parser.exs`/`lib/repl/eval/result.exs`/`lib/repl/evaluator.exs`)には一切手を入れない。**

`XipeTotec.Repl.Evaluator`(`lib/repl/evaluator.exs`)は`Core.plan_recalc/3`のPlanを1セッションに流し込み`Core.apply_results/3`まで畳み込む、この汎用実行層の一番外側のオーケストレータ(2026-09-18)。`:launch_module`/`:eval_template_module`/`:scan_module`/`:field_drip_module`の4オプションで算出プログラム側の4モジュールを受け取る(既定はElixir実装)──「呼び出し元が具体的なモジュールを渡す、内部で言語判定しない」という`Parser.step/5`と同じ流儀。新しい言語を足しても`Evaluator`自体は無改造で、この4つを差し替えて渡すだけでよい(まだ「どのノードがどの言語のプロジェクトに属するか見て自動選択する」機構は無い ── 今のところ言語アダプタが1つしか無いため)。

## 多言語判定層（`tables/`/`info.json`）との関係（2026-09-24、実装途中）

このガイド本体（算出プログラムの書き方）とは別レイヤーで、**対象プロジェクトがどの言語/ビルドツールを使っているかを判定する層**が、`~/my_app/tezcatl`セッションでのco-designにより作られ始めている（`Old.md` §24〜§26）。新しい言語を足す作業は、最終的にこの層とも接続することになるので、現状を知っておくこと:

- **`XipeTotec.Repl.Language`（`lib/repl/language.exs`、2026-09-24、`Old.md` §34）**: 言語ごとの自己申告。`lib/repl/language/<name>.exs`に1言語1モジュールを置き、ファイル名が言語名になる（`elixir.exs`→`"elixir"`）。申告するのは`extensions/0`（拡張子の一覧）・`repl/0`（REPL の名前、surface table の`repl`列）・`build_tools/0`（ビルドツールの優先順位表 `[%{"name", "markers"}]`、2026-09-26）・`scanner/0`・`adapter/0`・`launch_opts/3`（`build_tool`の名前と、その言語のファイル一覧を受け取る）。**新しい言語を足すときは、4つの算出プログラムに加えてこのファイルも書く**
- **`XipeTotec.Info`（`lib/info.exs`）**: xipe_totec自身の`info.json`（対象プロジェクト側ではない）を読み書きする。`xipe refresh -l`が`lib/repl/language/*.exs`を読み込んで`extensions/0`・`repl/0`・`build_tools/0`を呼び、`languages`（言語名）・`extensions`（拡張子→申告した言語のリスト）・`language_repls`・`build_tools`を書く。**ファイルを置いただけでは効かず、`xipe refresh -l`を叩いて初めて登録される**（P4）
- **`XipeTotec.SurfaceTable`（`lib/surface_table.exs`）**: 対象プロジェクトのファイルツリーを走査し、`language`/`repl`/`build_tool`を判定するテーブル。`language`は`info.json`の`extensions`から引く。1言語だけが申告した拡張子はその言語、どの言語も申告していないか**2つ以上の言語が申告した拡張子は`nil`**（P9、判定できないものは判定できないと示す）。`repl`/`build_tool`は今のところElixir＋`mix`の分だけ（`mix.exs`の有無の直接チェック）
- **まだ申告に無いもの（計画のみ）**: `embody`の有無（§30）。実装されたら`Repl.Language`のcallbackとして足す。Nix の環境は言語ではなくプロジェクト単位の層（`ProjectEnv`）なので、申告には含めない。あわせて、起動完了の検出を固定の`XT_READY`マーカーへ移す計画もある（§25.3。`Launch`相当のモジュールの`ready_pattern`に関わる）。最新の実装状況は`README.md`の「いまどこまで動くか」、残作業は`課題.md`の「多言語対応」節を確認すること

## ディレクトリ構成

```
lib/repl/
  launch.exs             (XipeTotec.Repl.Launch)              -- 算出: 起動系JSON
  sender.exs              (XipeTotec.Repl.Sender)               -- 汎用: 送信behaviour
  sender_direct.exs        (XipeTotec.Repl.Sender.Direct)        -- 実行: plain pipe実装
  session.exs              (XipeTotec.Repl.Session)              -- 汎用: 起動完了待ち・離脱
  language.exs             (XipeTotec.Repl.Language)             -- behaviour定義のみ（言語ごとの自己申告）
  language/
    elixir.exs               (XipeTotec.Repl.Language.Elixir)      -- 算出: Elixirの拡張子
  eval_template.exs        (XipeTotec.Repl.EvalTemplate)         -- 算出: Elixir用の呼び出し式組み立て
                                                                     + 安全装置 + repr/compare判定
                                                                     + マーカー印字(丸ごと)
  evaluator.exs             (XipeTotec.Repl.Evaluator)             -- 汎用: Plan全体を1セッションに
                                                                     流し込むオーケストレータ
  source_sanitize.exs        (XipeTotec.Repl.SourceSanitize)        -- Elixir固有(注参照): scripts-mode
                                                                     の`files`をdefmodule抽出のみの一時
                                                                     コピーに差し替える
  eval/
    scan.exs                (XipeTotec.Repl.Eval.Scan)            -- 汎用: マーカー検出
    field_drip.exs           (XipeTotec.Repl.Eval.FieldDrip)       -- behaviour定義のみ
    result.exs                (XipeTotec.Repl.Eval.Result)          -- 汎用: Evaluator.Result変換
    parser.exs                 (XipeTotec.Repl.Eval.Parser)          -- 汎用: 上記を1回で回す
    scan/
      direct/
        iex.exs                  (XipeTotec.Repl.Eval.Scan.Direct.Iex) -- 算出: iex+plain pipe用の前処理
      pty/
        (空。PTY対応Senderができたときの置き場所)
    field_drip/
      elixir.exs               (XipeTotec.Repl.Eval.FieldDrip.Elixir) -- 算出: Elixir用の本文パース
```

**`source_sanitize.exs`についての注**: これは4つの算出プログラム(`Launch`/`EvalTemplate`/`Scan`/`FieldDrip`)とは別枠 ── `Runner`(`lib/runner.exs`)がscripts-modeの`files`を自動推測するときだけ使う、CLI都合のElixir固有ヘルパー。`Code.string_to_quoted!`でASTを見てdefmodule部分だけの一時コピーを作る(`Scanner`のFix Fと同じ発想、2026-09-18の実バグ修正 ── 元のファイルをそのまま`-r`すると、そのファイルのトップレベルの副作用ごと実行されてしまう)。新しい言語を足すとき、この「scripts-modeでどのファイルを安全にロードするか」という問題は言語ごとに事情が違いうる(そもそもAST走査で安全にフィルタできるとは限らない)。素朴には「呼び出し元(将来のtezcatl連携等)が`:launch_opts`を明示的に渡し、`Runner`の自動推測を経由しない」道を使うのが安全。

新しい言語/REPLを足すときに書くのは、この構成でいう**「算出」**とマークされたファイルの、その言語版だけ。「汎用」「実行」とマークされたものは触らない。

**`Scan`が2軸(トランスポート×REPL)なのに対し、`Launch`/`EvalTemplate`/`FieldDrip`は言語軸だけな理由**: `Scan`が取り除く雑音(PTYのエコーバック・ANSI)は経験的にはトランスポート(PTY/plain pipe)の性質だが、将来的に特定REPL固有の出力の癖が見つかる可能性もあるため、両軸を明示的にディレクトリで持たせてある(`Old.md` §10.9)。他の3つは言語/REPLだけに依存する値なので1軸のままでよい。

## 変えてはいけないもの（全言語共通の固定ルール）

- **マーカー規約**: `XT_BEGIN_<call_id>`（評価成功時、この直後に本文）、`XT_END_<call_id>`（成功の終端）、`XT_ERROR_<call_id> crash <reason>` / `XT_ERROR_<call_id> timeout` / `XT_ERROR_<call_id> max_heap`（失敗、成功の代わりに使う。`max_heap`はメモリ上限超過による強制終了で、通常のcrashと区別する ── Elixir版の判定方法は`Old.md` §11.3）、`XT_EXIT <status>`（プロセス終了、`Sender`実装が合成する。算出プログラム側は関与しない）。これらの文字列そのものは変更しない。`XT_HEARTBEAT`は2026-09-22（Old.md §23）にハートビート機構ごと撤去済み ── 生存確認は`Sender.interrupt/1`＋固定デッドラインに一本化された
- **本文のkey=valueフォーマット**: `XT_BEGIN`〜`XT_END`の間は`repr=<exact|binary|unsupported>`/`type=<型名>`/`compare=<none|skipped|changed|same>`/`display=<表示文字列>`/(`bin_base64=<base64>`、`repr=binary`のときのみ)を改行区切りで並べる。`FieldDrip.Elixir`(`lib/repl/eval/field_drip/elixir.exs`)を参照。**`display=`の値は必ず1行に収めること**（Elixirでは`inspect(..., width: :infinity)`で対応。対象言語の同等機構で改行を防ぐこと。これを怠ると行ベースのパーサーが壊れる ── `eval_template`実装時に見つかった実際のバグ、`Old.md` §10.5参照）
- **`XT_BEGIN`〜`XT_END`の本文は1回の書き込みで出すこと**（Elixir版は複数行を`Enum.join(..., "\n")`で1本の文字列に組み立ててから`IO.puts/1`を1回だけ呼ぶ ── 個別の`IO.puts`を本文の行ごとに複数回呼ぶと、その間に別プロセス(利用者コードが起こした非同期出力等)の印字が挟まり本文を壊しうる、2026-09-18の実バグ修正。この種の割り込みは対象言語側の「複数回に分けて印字しない」という規律でしか防げない）
- **JSON安全性**: 算出プログラムが`Repl.Launch`経由で返す値は文字列・数値・真偽値・null・それらのmap/listのみ。atomやtupleを混ぜない（`Repl.Launch`のmoduledocにある「B2のルール」と同じ）
- **push専用・単一メッセージ型**: 受信は常に`{handle, {:data, binary()}}`のみ（`lib/repl/sender.exs`のcontract参照）。算出プログラム側がこれに関与することは無い
- **`Repl.Sender`のbehaviour**（`send/1`/`write/2`/`kill/1`/`interrupt/1`）は言語非依存。新しい言語のために新しいcallbackを増やす必要が生じたら、それはこのガイドの前提が崩れているということなので、増やす前に立ち止まって検討すること（`interrupt/1`自体は2026-09-22にこの理由で追加済み ── プロセスグループへのSIGINT送信という、どの言語からも共通に必要になる汎用機能だったため）
- **評価は常に対象セッション自身の中で完結させる**: repr/compare判定は対象プロジェクト固有の型を含みうる値を扱うため、xipe_totec自身のプロセスではなく評価対象のREPLセッション自身の中で判定・印字まで完結させる（`EvalTemplate`参照）

## 算出プログラムが用意すべきJSON（フィールド一覧）

`Repl.Launch.build/1`（Elixir版、`lib/repl/launch.exs`）と同じ形の`%{String.t() => term()}`を返す関数を書く。フィールド:

| フィールド | 型 | 説明 | Elixirでの既定値 |
|---|---|---|---|
| `kind` | string | 常に`"repl/launch"` | `"repl/launch"` |
| `argv` | [string] | REPL起動コマンド（シェル文字列ではなくリスト） | `["iex", "-S", "mix"]` |
| `env` | map | 追加の環境変数 | `%{}` |
| `cwd` | string | 対象プロジェクトのルート | (呼び出し元が指定) |
| `files` | [string] | 個別にロードすべきソースファイル（下記「files使い分け」参照） | `[]` |
| `ready_pattern` | string \| null | 起動完了を示すバナーの部分文字列（バージョン非依存に）。バナーを出さないREPLは`null` | `"Interactive Elixir"` |
| `ready_probe` | string \| null | バナーの後にstdinへ送り、`XT_READY`を印字させる式（Old.md §35）。マーカーは式の中で分割して書く（入力をそのまま返す端末で誤検出しないため） | `"IO.puts(\"XT_\" <> \"READY\")\n"` |
| `exit_input` | string | 正常終了のためにstdinへ送るテキスト | `"System.halt()\n"` |
| `interruptible` | boolean | `Sender.interrupt/1`（プロセスグループへのSIGINT）がこのREPLで実際に効くか(下記「対象言語がSIGINTを扱えるか」参照) | `true`（実機確認済み、下記参照） |

`eval_template`は`Launch`の外、`XipeTotec.Repl.EvalTemplate`(`lib/repl/eval_template.exs`)が`Plan.Entry`(呼び出し対象のcall_id/module/name/args)から動的に生成するので、`Launch`が返すJSONには含まれない。新しい言語ではこれに相当する別モジュールを作ることになる(下記参照)。

### `files`の使い分け

対象言語に「プロジェクト全体を自動でロードして起動する」手段（Elixirの`-S mix`に相当）があるなら、それを`argv`の既定値に使い、`files`は空でよい。そういう手段が無い構成（Elixirで言う`project_kind: scripts`、crux自身の実プロジェクトが該当）では、`files`に対象ファイル一覧を積み、`Sender`実装側（`Sender.Direct.with_files/2`は`-r <file>`を挿入する）がそれを実際の起動引数へどう反映するかを決める。**算出プログラム側は「反映のされ方」を知らなくてよい** ── `files`はただのデータとして渡すだけ。

## `eval_template`（相当のモジュール）を書くために必要な知識

`lib/repl/eval_template.exs`(`XipeTotec.Repl.EvalTemplate`)がElixirの実例。`build/1`が`Plan.Entry`から、対象言語のREPLセッション自身の中で実行されるコードをテキストとして組み立てる。必要な要素（実装済みのElixir版を参照しながら書くこと）:

1. **呼び出し式の組み立て方**: 完全修飾された関数名（module/name相当）と、既に文字列化された引数の並びから、その言語の呼び出し構文を作る方法（`EvalTemplate.call_expression/1`）
2. **標準出力への印字方法**: マーカー文字列を印字する関数（Elixirなら`IO.puts/1`）
3. **例外処理の構文**: 評価中に例外が起きても**必ず`XT_ERROR_<call_id> crash <reason>`まで印字してから終わる**ようにする。Elixir版は`spawn_monitor`+`receive`で、例外による`:DOWN`メッセージを捕捉する形（対象言語にプロセス分離/例外捕捉の機構が無ければ、素直なtry/catch相当で代替）。これが無いと、タイムアウトと評価失敗の区別がつかなくなる
4. **タイムアウト・メモリ上限の安全装置**: Elixir版は`spawn_monitor`+`Process.flag(:max_heap_size, ...)`+`receive...after`。対象言語の並行処理機構に合わせて作り直すこと
5. **repr判定の戦略**: Elixirでの方針は a) pid/port/reference/fun相当の値を再帰的に検出したら`unsupported` b) それ以外は`inspect`相当の文字列化→再パース→元の値と比較する往復検査で一致すれば`exact` c) それ以外はその言語のシリアライズ機構で`binary`(`bin_base64=`に載せる)。**対象言語に同種の機構（値→文字列表現→文字列から値への再構築）が無い場合、この3分類そのものを見直す必要がある** ── 単純にElixirの分類をコピーしない
6. **`type=`の判定**: 値の型名を文字列で返す判定カスケード（Elixir版は`is_integer`等の連鎖、structなら`inspect(v.__struct__)`）
7. **compare判定**: 実装済み(2026-09-18、`Old.md` §11.2)。`Core.plan_recalc/3`が`entry.basis`として渡す`{:exact, 前回テキスト} | {:binary, 前回base64} | :none`を、**対象セッション自身の中で**再構築して今回の値と比較する(`:none`なら比較せず`compare=none`)。Elixir版の方針: `:exact`は`Code.eval_string/1`で、`:binary`は`Base.decode64!/1`+その言語の逆シリアライズで前回値を復元し、map/list/tuple/struct(structはただのmap)を再帰的に辿って比較、floatだけ相対/絶対誤差を許容(Elixir版は固定値`1.0e-9`、設定機構が無いため)。新しい今回の値自体が`unsupported`なら無条件で`compare=skipped`(片側でもunsupportedなら比較しない、仕様の規則)。**値は`none`/`skipped`/`changed`/`same`のいずれかの文字列**(atomではない ── Coreの他の箇所と同じ文字列規約、2026-09-18に実際に踏んだ不整合バグの教訓)。
8. **常にセッション変数へ束縛する**: 評価したcallの結果を、常に対象言語のトップレベル変数(Elixirなら`xt_<call_id>`)へ束縛すること。セッションは1回の評価の間だけなので、束縛もその評価の中だけで使われる（Old.md §35）。`in_plan`参照(同一pass内で後続callが先行callの結果を参照する)がこれを前提にしているため構造的に必要（詳細と、ここで実際に踏んだバグは`Old.md` §10.5参照 ── 束縛用の変数とrepr判定・マーカー印字を同じトップレベル文の中で完結させないと、対象言語の変数スコープ次第で束縛が正しく残らないことがある）
9. **対象セッション側で実行する理由**: 判定対象の値は対象プロジェクト固有の型を含みうるので、xipe_totec自身のプロセスではなく**評価対象のREPLセッション自身の中で**判定・印字まで完結させること
10. **呼び出し式を送る前に、その場で構文検査する**: 閉じていない引数(例: `[1, 2`)をそのままREPLへ送ると、多くのREPLは「入力の続き待ち」状態になり、それ以降に送った文字列(この呼び出し自身の残り・次のentry全体)まで同じ壊れた式に吸い込まれ、マーカーが二度と出てこなくなる(2026-09-18の実バグ ── `Evaluator`側の絶対タイムアウトでしか最終的には検出できない)。Elixir版は`build/1`の入口で`Code.string_to_quoted/1`相当の構文検査を行い、失敗したら**呼び出し式を一切対象言語へ埋め込まず**、xipe_totec自身の側で組み立てた診断文字列だけを印字する最小限のテンプレート(`build_syntax_error/3`)を代わりに返す。対象言語に同様の「文字列が構文として完結しているか」を判定できる機構(パーサーAPI等)があれば同じ手を使うこと。無ければ最低限、呼び出し式の壊れた断片をテンプレートの他の部分に一切混ぜないという規律だけは守ること(壊れた断片を別の場所に埋め込んでも、その埋め込み先ごと壊れるだけで問題は解決しない)。

## `interruptible`（`message["interruptible"]`）を決めるために必要な知識

2026-09-22（Old.md §23）、ハートビート機構は撤去された。生存確認は「`Sender.interrupt/1`でこのREPLのプロセスグループ全体へSIGINTを送り、短い猶予の後で`XT_EXIT`が出なければ`Sender.kill/1`（SIGKILL、同じくグループ全体へ）で強制終了する」という、**対象言語側に一切コードを書かせない**汎用実行層だけの仕組みに一本化された（`Evaluator`の`end_hung_session/4`）。算出プログラム側がここで決めるべきことは1つだけ ── **SIGINTがこのREPLに実際に届いたとき、評価だけ中断してプロンプトへ戻れるか、それとも(ハンドラが無く)ただちに終了するだけか**。前者なら`interruptible: true`、後者（または不明）なら`false`。`false`にしても壊れることはない ── `Evaluator`は`interrupt/1`を試さず直接`kill/1`するだけで、ハング検知自体は変わらず機能する。単に「対象プロセスへもう少し丁寧に終了する機会を与えられない」というだけの差。

Elixir版は`interruptible: true`が既定（`lib/repl/launch.exs`の`@default_interruptible`）。**実機確認済み**(2026-09-22): `erlexec`で`{group, 0}`付きで起動した`iex`（plain pipe、PTY無し）に対し`:exec.kill(ospid, 2)`（SIGINT、正のospidを渡すとerlexec自身がグループ全体へ配送する）を送ったところ、BEAM自身のSIGINTハンドラが反応し、実際の端末でCtrl-Cを押したときと同じ`"BREAK: (a)bort (A)bort with dump (c)ontinue ..."`メニューが出力に現れた。PTYは不要。

## `field_drip`（相当のモジュール）を書くために必要な知識

`lib/repl/eval/field_drip/elixir.exs`(`XipeTotec.Repl.Eval.FieldDrip.Elixir`)がElixirの実例。`XipeTotec.Repl.Eval.FieldDrip`のbehaviour(`parse(body) :: map()`)を実装する。本文フォーマット(`repr=`/`type=`/`compare=`/`display=`/`bin_base64=`)自体はxipe_totec全体で固定の規約なので、実装は「改行分割→`=`で最初の1回だけ分割」という単純なものになるはず(Elixir版が実際そうなっている)。対象言語の`eval_template`がこのフォーマット通りに印字する限り、field_dripを言語ごとに変える必要はほぼ無いはず。言語判定はfield_drip自身が行わない（呼び出し元が`Repl.Eval.Parser.step/5`に具体的なモジュールを渡す）。

## `scan`（相当のモジュール）を書くために必要な知識

`lib/repl/eval/scan/direct/iex.exs`(`XipeTotec.Repl.Eval.Scan.Direct.Iex`)がElixir+plain pipeの実例。**トランスポート(PTY/plain pipe)とREPL(iex/ghci/...)の2軸で、`lib/repl/eval/scan/<transport>/<repl>.exs`という配置になる。** 新しいREPLをplain pipe経由で足すだけなら`lib/repl/eval/scan/direct/<repl>.exs`を追加、新しいトランスポート(PTY等)を足すなら対応する`Sender`実装と対にして`lib/repl/eval/scan/<transport>/`配下に追加する。今のところ`Direct`(plain pipe)は実機検証済みの通りエコーバック・ANSIノイズが一切無いため、`clean/1`は`XT_EXIT`の検出・除去のみで足りている。PTY対応を追加するときは、ここにエコーバック除去・ANSI除去の実装が要る。

## 新しい言語を足すときのチェックリスト

算出プログラムを書く前に、対象言語のREPLについて以下を調べて（またはAIに調べさせて）から着手する:

1. デフォルトの起動コマンドは何か。プロジェクト全体を自動ロードする起動モードはあるか
2. 個別ファイルをコマンドラインからロードする方法はあるか（`mix`が無い構成向け）
3. 起動完了時に印字される、バージョンに依存しない安定した文字列は何か
   （注: 2026-09-26から、バナー待ちの後に`ready_probe`で`XT_READY`を印字させて確かめる2段になった〈Old.md §35〉。バナーが不安定・無いREPLは`ready_pattern`を`null`にしてよく、その場合この項目は「`XT_READY`を印字させる式は何か」に置き換わる）
4. そのREPL自身の正規の終了コマンドは何か
5. 関数呼び出しの構文（完全修飾名＋引数列から式を組み立てる方法）
6. 標準出力への印字関数
7. 例外を捕捉して握りつぶさず「終端マーカーまでは必ず印字する」ための構文
8. 値→文字列表現→再構築という往復検査に相当する機構があるか。無ければrepr判定の設計をどう作り直すか
9. 浮動小数点比較の許容誤差をどう扱うか
10. SIGINTを受けたとき、評価だけ中断してプロンプトへ戻れるか、それともプロセスごと終了するか（`interruptible`の値を決める。分からなければ`false`にしておけば安全）
11. プレーンなpipe接続（PTY無し）でそのREPLが正常に動作するか、それとも本物のtty必須か（後者ならPTY対応が前提になる。`Old.md` §10.1のエコーバック課題も合わせて考慮）

これらの答えが`argv`/`ready_pattern`/`exit_input`/`interruptible`（`Launch`相当のモジュール）と、`eval_template`相当のモジュール・`field_drip`相当のモジュール・（PTYなら）`scan`相当のモジュールになる。答えられない項目があれば、それは「対象言語では今のXipe Totecの設計がそのまま使えない箇所」なので、実装を進める前にcruxへ相談すること。

## 候補言語ごとのチェックリスト回答（下書き、2026-09-22、未検証）

`~/my_app/tezcatl`セッションでの`crux`とのco-design。上記「新しい言語を足すときのチェックリスト」を、冒頭で候補として挙げている4言語（OCaml/utop、Haskell/GHCi、Clojure、Racket）について知識ベースで埋めた下書き。**この環境にはいずれの処理系も無く（`ocaml`/`utop`/`ghci`/`clojure`/`racket`いずれも未インストール）、実機での検証は一切していない。** 「答えられない項目があれば実装前にcruxへ相談」というこのガイド自身のルール通り、着手前に実機で裏取りすること。

### OCaml / utop

1. **デフォルト起動コマンド**: `utop`（プロジェクト全体の自動ロードは`dune utop <dir>` ── dune管理下なら`.ml`/`.mli`一式をライブラリとしてロード済みの状態で起動できる。Elixirの`-S mix`に相当）
2. **個別ファイルのロード**: `utop`起動後に`#use "file.ml";;`または起動時`-init <file>`。dune無しの構成では`ocamlfind`/`#require`でライブラリを読み、`#use`でファイルを読む形になりそう
3. **起動完了の安定文字列**: 標準の`utop`バナーはバージョン文字列を含むため不安定。プロンプト文字列`utop #`は比較的安定だが、`ready_pattern`としては微妙（要検証）
4. **正規の終了コマンド**: `#quit;;`（またはEOF/Ctrl-D）
5. **呼び出し構文**: OCamlは`f x y`（空白区切り、括弧はデフォルトの評価順を変えるときのみ）。完全修飾は`Module.f x y`
6. **標準出力への印字**: `print_string`/`Printf.printf`
7. **例外捕捉**: `try ... with e -> ...`
8. **往復検査（値↔文字列）**: OCaml標準に汎用`inspect`相当は無い。`Format`モジュールの`%a`/`Printexc`はあるが、任意の値を汎用的に文字列化→再パースする機構は無い（型ごとに`to_string`/`of_string`がバラバラ）── ここが一番、Elixir版の設計をそのまま持ち込めない箇所
9. **浮動小数点誤差**: `abs_float (a -. b) < epsilon`相当を自前で書く必要あり
10. **SIGINTで中断・復帰できるか（`interruptible`）**: OCamlには`Sys.catch_break`（有効化するとCtrl-Cが`Sys.Break`例外として捕捉可能になる）があるが、`utop`がこれを既定で有効にしているかは未確認。要検証（不明なら`false`にしておくのが安全）
11. **plain pipe対応**: `utop`はreadline的な行編集をするため、素のpipe接続でも動作するかは要検証（`ocaml`本体の素のトップレベルならpipeで安定するはずだが、`utop`固有の機能が絡むと未知数）

**設計見直しが要りそうな箇所**: 8（往復検査の機構が無い）。10（`interruptible`）は不明なら`false`にすればよいだけなので、他言語ほどのブロッカーではない（新設計ではSIGINT対応は`kill/1`への単なる上乗せで、必須要件ではない）。

### Haskell / GHCi

1. **デフォルト起動コマンド**: `ghci`。プロジェクト全体の自動ロードは`cabal repl`または`stack ghci`（cabal/stack管理下ならモジュール一式をロード済みの状態で起動）。Elixirの`-S mix`に相当
2. **個別ファイルのロード**: 起動後`:load file.hs`（`:l`）、または起動時`ghci file.hs`で直接指定。複数ファイルは`ghci file1.hs file2.hs`
3. **起動完了の安定文字列**: デフォルトプロンプトはGHC/設定次第で`ghci>`/`Prelude>`/ロードしたモジュール名を反映したプロンプト（`*Main>`等）と変化するため不安定。`:set prompt "..."`（`.ghci`設定ファイルや`-ghci-script`で起動時に注入可能）で固定文字列に上書きするのが確実
4. **正規の終了コマンド**: `:quit`（`:q`）
5. **呼び出し構文**: `f x y`（空白区切り、カリー化前提）。完全修飾は`import qualified Module as M`しておいて`M.f x y`
6. **標準出力への印字**: `putStrLn`/`print`
7. **例外捕捉**: `Control.Exception`の`catch`/`try`。**注意**: Haskellは遅延評価のため、例外が実際に飛ぶタイミングは値の評価タイミングに依存する。`evaluate`でWHNFまで強制してから捕捉しないと、単純な`try`だけでは意図したタイミングで例外を拾えない可能性がある
8. **往復検査**: `deriving (Show, Read)`があれば`show`/`read`で型ごとに文字列化・再構築ができるが、これは各型が明示的に`Read`インスタンスを持つ場合限定（関数や多くの抽象データ型は`Read`を持たない）。OCamlと同様、汎用的な往復検査機構としては使えない
9. **浮動小数点誤差**: 自前で`abs (a - b) < epsilon`相当が必要
10. **SIGINTで中断・復帰できるか（`interruptible`）**: GHCiはCtrl-Cで現在の評価だけ中断してプロンプトへ戻る、というのが広く知られた対話的挙動（`System.Posix.Signals`経由でGHC自身がSIGINTハンドラを持つ）。4言語の中では最もElixirに近い挙動が期待できるが、実機未確認
11. **plain pipe対応**: 素のstdin/stdoutパイプでも動作するはず（対話シェルとしての行編集はreadline系ライブラリ依存だが、パイプ接続時は影響しないはず、要検証）

**設計見直しが要りそうな箇所**: 8（`Read`を持たない型は往復検査できない）。7（遅延評価と例外タイミングの相性）は実装時に特に注意。

### Clojure

1. **デフォルト起動コマンド**: `clojure`（`clj`）または`lein repl`（Leiningen管理下）。`deps.edn`/`project.clj`経由でクラスパス一式ロード済みの状態で起動可能
2. **個別ファイルのロード**: 起動後`(load-file "file.clj")`または`(require 'namespace :reload)`
3. **起動完了の安定文字列**: `user=>`がデフォルトプロンプト（名前空間により変化しうるが初期プロンプトとしては比較的安定）。JVM起動時のログ出力が先行するため、それらと混同しない安定部分文字列の選定が要る
4. **正規の終了コマンド**: `(System/exit 0)`またはEOF/Ctrl-D
5. **呼び出し構文**: 前置記法`(f x y)`（Lisp系）。完全修飾は`(namespace/f x y)`
6. **標準出力への印字**: `println`/`print`
7. **例外捕捉**: `(try ... (catch Exception e ...))`
8. **往復検査**: `pr-str`/`read-string`（EDN形式）── Clojureのデータ構造（コレクション・リテラル値）は標準で文字列化・再構築でき、Elixirの`inspect`/`Code.eval_string`に近い往復検査が可能。ただしレコード以外の任意のJavaオブジェクトはEDN化できない点はElixir同様`unsupported`扱いが必要
9. **浮動小数点誤差**: 自前で許容誤差比較が必要
10. **SIGINTで中断・復帰できるか（`interruptible`）**: JVMへの素のSIGINTは既定でシャットダウンフック経由のプロセス終了を招くのが一般的で、「現在の評価だけ中断してREPLへ戻る」挙動をClojure REPL自身が持つかは未確認。4言語の中では最も`false`寄りの可能性がある。要検証
11. **plain pipe対応**: 素のstdin/stdoutで動作するはず。JVM起動が重く起動待ち時間（`ready_pattern`検出までの時間）が他言語より長くなる点に注意

**設計見直しが要りそうな箇所**: 4言語の中では最もElixir版に近い（8の往復検査機構が標準で存在する）。10（`interruptible`）はJVMの既定挙動次第で`false`になりそう。

### Racket

1. **デフォルト起動コマンド**: `racket -i`（対話モード）。プロジェクト全体の自動ロードに相当する標準的な仕組みは薄い（`raco`はビルド/パッケージ管理寄り）
2. **個別ファイルのロード**: `racket -i -t file.rkt`（起動時ロード）、または起動後`(enter! (file "file.rkt"))`（`racket/enter`使用時）
3. **起動完了の安定文字列**: デフォルトプロンプトは`>`のみで非常に短く、他の出力との衝突リスクが高い（要検証・調整。バナー抑制`-q`や独自プロンプト設定を検討すべき）
4. **正規の終了コマンド**: `(exit)`またはEOF/Ctrl-D
5. **呼び出し構文**: 前置記法`(f x y)`（Lisp系）。完全修飾はモジュールの`require`ベースで、Clojureの`ns/name`のような単純な文字列結合とは形が異なる点に注意
6. **標準出力への印字**: `display`/`printf`
7. **例外捕捉**: `(with-handlers ([exn:fail? (lambda (e) ...)]) ...)`
8. **往復検査**: `~s`（write形式）での文字列化と`read`での再構築が標準サポートされており、Clojureに近い形で往復検査が可能（S式ベースのデータ構造なら比較的素直）
9. **浮動小数点誤差**: 自前実装が必要
10. **SIGINTで中断・復帰できるか（`interruptible`）**: Racketは`break-enabled?`/`exn:break`という、SIGINT相当を捕捉可能な例外に変換する仕組みを標準で持つ。理論上はGHCiに近い挙動が期待できるが、`racket -i`が既定でbreakを有効にしているかは未確認
11. **plain pipe対応**: 要検証。`racket -i`は対話向けだが、パイプ経由でも基本動作するはず（readline的な行編集は既定では付いていないことが多く、むしろpipeとの相性は良い可能性がある）

**設計見直しが要りそうな箇所**: 3（プロンプトが`>`だけで衝突しやすい）。それ以外はClojureに近く、4言語の中では実装コストが低そうに見える。

### 4言語を通して見える傾向

- **8（往復検査）はOCaml/Haskellで構造的な壁、Clojure/Racketでは標準機構がある** ── S式系（Lisp系）データ構造は元々「書いたものがそのまま読み戻せる」設計なので、Elixirの`inspect`→`Code.eval_string`往復検査パターンと相性が良い。ML系（OCaml/Haskell）は型ごとにバラバラな`to_string`しか無く、ここが一番の設計変更ポイントになる
- **10（`interruptible`）はもうブロッカーではない**（2026-09-22の設計変更後）: ハートビート機構が撤去され生存確認が汎用実行層側（`Sender.interrupt/1`＋固定デッドライン＋`kill/1`）に一本化されたため、対象言語がSIGINTを扱えるかどうかは「より丁寧に終了できるかどうか」の差でしかない。`false`にしておけば安全に動く。4言語ともElixir版と違って**軽量並行機構の有無を気にする必要が無くなった**
- 全項目、**この環境で実機検証していない下書きの域を出ない**（`interruptible`の値を除く ── こちらはElixir分のみ2026-09-22に実機確認済み）。実装に進む前に対象処理系が使える環境（対象プロジェクト自身の`nix develop`等、crux環境）で1項目ずつ裏取りすること

## 実装の参考にする実機テスト

`test/live/repl_iex_test.exs`（`test/run.sh`には含まれない、`elixir test/live/repl_iex_test.exs`で個別実行）がElixir版の全パイプライン検証。新しい言語を足したら、同じ構成（起動→完了検知→評価の6パターン(成功/in_plan参照/unsupported/例外/タイムアウト/構文が閉じていない呼び出し)→compare(same/changed)→離脱）の実機テストを、対象言語の実行環境が用意できた段階で書くこと。`test/fixtures/calc_sample/calc.exs`のような、外部依存の無い小さいサンプルプロジェクトを対象言語でも用意しておくと検証しやすい。
