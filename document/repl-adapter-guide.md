# REPLアダプタ追加ガイド（新しい言語/REPLを足すとき用）

対象読者: Elixir以外の言語（spec §12.6の候補: Haskell/GHCi、OCaml/utop、Clojure、Racketなど）のREPLアダプタを新しく書く人（人間・AIのどちらも想定。このセッションの会話内容を知らない前提で書いてある）。

**2026-09-18時点でElixir向けの実装は完成し、実機の`iex`で全パイプライン(起動→完了検知→評価→compare判定→パース→離脱)を確認済み。** このガイドの各項目は、もう「設計だけ」ではなく`lib/repl/`配下に動くコード例がある。新しい言語を足すときは、まずそのコードを読むこと。`compare`判定・`Core.plan_recalc`/`Core.apply_results`との配線(`Repl.Evaluator`)・`xipe eval`/`xipe do`のCLIまで含めて動く(`XipeTotec_prebuild.md` §11〜14)。

## 前提となる設計（変更しないこと）

Xipe Totecは対象プロジェクトのREPLへ人間が手で式を打ち込んで確認するのと同じ操作を自動化する（`XipeTotec_prebuild.md` §10）。全体は「**言語/REPLごとの算出プログラム**（JSONデータやコード片を作るだけ、純粋関数）」と「**汎用の実行層**（それを読んで実行するだけ、言語知識ゼロ）」に分かれている。**新しい言語を足すときは、算出プログラム側だけを書けばよい。汎用の実行層(`lib/repl/sender.exs`/`lib/repl/sender_direct.exs`/`lib/repl/session.exs`/`lib/repl/eval/scan.exs`/`lib/repl/eval/field_drip.exs`/`lib/repl/eval/parser.exs`/`lib/repl/eval/result.exs`/`lib/repl/evaluator.exs`)には一切手を入れない。**

`XipeTotec.Repl.Evaluator`(`lib/repl/evaluator.exs`)は`Core.plan_recalc/3`のPlanを1セッションに流し込み`Core.apply_results/3`まで畳み込む、この汎用実行層の一番外側のオーケストレータ(2026-09-18)。`:launch_module`/`:eval_template_module`/`:scan_module`/`:field_drip_module`の4オプションで算出プログラム側の4モジュールを受け取る(既定はElixir実装)──「呼び出し元が具体的なモジュールを渡す、内部で言語判定しない」という`Parser.step/5`と同じ流儀。新しい言語を足しても`Evaluator`自体は無改造で、この4つを差し替えて渡すだけでよい(まだ「どのノードがどの言語のプロジェクトに属するか見て自動選択する」機構は無い ── 今のところ言語アダプタが1つしか無いため)。

## ディレクトリ構成

```
lib/repl/
  launch.exs             (XipeTotec.Repl.Launch)              -- 算出: 起動系JSON
  sender.exs              (XipeTotec.Repl.Sender)               -- 汎用: 送信behaviour
  sender_direct.exs        (XipeTotec.Repl.Sender.Direct)        -- 実行: plain pipe実装
  session.exs              (XipeTotec.Repl.Session)              -- 汎用: 起動完了待ち・離脱
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

**`Scan`が2軸(トランスポート×REPL)なのに対し、`Launch`/`EvalTemplate`/`FieldDrip`は言語軸だけな理由**: `Scan`が取り除く雑音(PTYのエコーバック・ANSI)は経験的にはトランスポート(PTY/plain pipe)の性質だが、将来的に特定REPL固有の出力の癖が見つかる可能性もあるため、両軸を明示的にディレクトリで持たせてある(`XipeTotec_prebuild.md` §10.9)。他の3つは言語/REPLだけに依存する値なので1軸のままでよい。

## 変えてはいけないもの（全言語共通の固定ルール）

- **マーカー規約**: `XT_BEGIN_<call_id>`（評価成功時、この直後に本文）、`XT_END_<call_id>`（成功の終端）、`XT_ERROR_<call_id> crash <reason>` / `XT_ERROR_<call_id> timeout` / `XT_ERROR_<call_id> max_heap`（失敗、成功の代わりに使う。`max_heap`はメモリ上限超過による強制終了で、通常のcrashと区別する ── Elixir版の判定方法は`XipeTotec_prebuild.md` §11.3）、`XT_HEARTBEAT`（生存確認、定期的に印字）、`XT_EXIT <status>`（プロセス終了、`Sender`実装が合成する。算出プログラム側は関与しない）。これらの文字列そのものは変更しない
- **本文のkey=valueフォーマット**: `XT_BEGIN`〜`XT_END`の間は`repr=<exact|binary|unsupported>`/`type=<型名>`/`compare=<none|skipped|changed|same>`/`display=<表示文字列>`/(`bin_base64=<base64>`、`repr=binary`のときのみ)を改行区切りで並べる。`FieldDrip.Elixir`(`lib/repl/eval/field_drip/elixir.exs`)を参照。**`display=`の値は必ず1行に収めること**（Elixirでは`inspect(..., width: :infinity)`で対応。対象言語の同等機構で改行を防ぐこと。これを怠ると行ベースのパーサーが壊れる ── `eval_template`実装時に見つかった実際のバグ、`XipeTotec_prebuild.md` §10.5参照）
- **`XT_BEGIN`〜`XT_END`の本文は1回の書き込みで出すこと**（Elixir版は複数行を`Enum.join(..., "\n")`で1本の文字列に組み立ててから`IO.puts/1`を1回だけ呼ぶ ── 個別の`IO.puts`を本文の行ごとに複数回呼ぶと、その間に別プロセス(利用者コードが起こした非同期出力等)の印字が挟まり本文を壊しうる、2026-09-18の実バグ修正。`XT_HEARTBEAT`自体は`clean/1`がどこにあっても除去するので無害だが、それ以外の割り込みは対象言語側の「複数回に分けて印字しない」という規律でしか防げない）
- **JSON安全性**: 算出プログラムが`Repl.Launch`経由で返す値は文字列・数値・真偽値・null・それらのmap/listのみ。atomやtupleを混ぜない（`Repl.Launch`のmoduledocにある「B2のルール」と同じ）
- **push専用・単一メッセージ型**: 受信は常に`{handle, {:data, binary()}}`のみ（`lib/repl/sender.exs`のcontract参照）。算出プログラム側がこれに関与することは無い
- **`Repl.Sender`のbehaviour**（`send/1`/`write/2`/`kill/1`）は言語非依存。新しい言語のために新しいcallbackを増やす必要が生じたら、それはこのガイドの前提が崩れているということなので、増やす前に立ち止まって検討すること
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
| `ready_pattern` | string | 起動完了を示す部分文字列（バージョン非依存に） | `"Interactive Elixir"` |
| `exit_input` | string | 正常終了のためにstdinへ送るテキスト | `"System.halt()\n"` |
| `heartbeat_interval_ms` | integer | ハートビート間隔(ms)。`heartbeat_input`生成に使うだけで、message自体には残らない | `5000` |
| `heartbeat_input` | string | 定期的にハートビートマーカーを印字させるコード片(セッション起動直後に一度だけ送る) | `lib/repl/launch.exs`の`heartbeat_input/1`参照 |

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
7. **compare判定**: 実装済み(2026-09-18、`XipeTotec_prebuild.md` §11.2)。`Core.plan_recalc/3`が`entry.basis`として渡す`{:exact, 前回テキスト} | {:binary, 前回base64} | :none`を、**対象セッション自身の中で**再構築して今回の値と比較する(`:none`なら比較せず`compare=none`)。Elixir版の方針: `:exact`は`Code.eval_string/1`で、`:binary`は`Base.decode64!/1`+その言語の逆シリアライズで前回値を復元し、map/list/tuple/struct(structはただのmap)を再帰的に辿って比較、floatだけ相対/絶対誤差を許容(Elixir版は固定値`1.0e-9`、設定機構が無いため)。新しい今回の値自体が`unsupported`なら無条件で`compare=skipped`(片側でもunsupportedなら比較しない、仕様の規則)。**値は`none`/`skipped`/`changed`/`same`のいずれかの文字列**(atomではない ── Coreの他の箇所と同じ文字列規約、2026-09-18に実際に踏んだ不整合バグの教訓)。
8. **`bind_as`によらず常にセッション変数へ束縛する**: 評価したcallの結果を、`bind_as`の値によらず常に対象言語のトップレベル変数(Elixirなら`xt_<call_id>`)へ束縛すること。`in_plan`参照(同一pass内で後続callが先行callの結果を参照する)がこれを前提にしているため構造的に必要（詳細と、ここで実際に踏んだバグは`XipeTotec_prebuild.md` §10.5参照 ── 束縛用の変数とrepr判定・マーカー印字を同じトップレベル文の中で完結させないと、対象言語の変数スコープ次第で束縛が正しく残らないことがある）
9. **対象ノード側で実行する理由**: 判定対象の値は対象プロジェクト固有の型を含みうるので、xipe_totec自身のプロセスではなく**評価対象のREPLセッション自身の中で**判定・印字まで完結させること
10. **呼び出し式を送る前に、その場で構文検査する**: 閉じていない引数(例: `[1, 2`)をそのままREPLへ送ると、多くのREPLは「入力の続き待ち」状態になり、それ以降に送った文字列(この呼び出し自身の残り・次のentry全体)まで同じ壊れた式に吸い込まれ、マーカーが二度と出てこなくなる(2026-09-18の実バグ ── ハートビートは別プロセスなので生存確認には引っかからず、`Evaluator`側の絶対タイムアウトでしか最終的には検出できない)。Elixir版は`build/1`の入口で`Code.string_to_quoted/1`相当の構文検査を行い、失敗したら**呼び出し式を一切対象言語へ埋め込まず**、xipe_totec自身の側で組み立てた診断文字列だけを印字する最小限のテンプレート(`build_syntax_error/3`)を代わりに返す。対象言語に同様の「文字列が構文として完結しているか」を判定できる機構(パーサーAPI等)があれば同じ手を使うこと。無ければ最低限、呼び出し式の壊れた断片をテンプレートの他の部分に一切混ぜないという規律だけは守ること(壊れた断片を別の場所に埋め込んでも、その埋め込み先ごと壊れるだけで問題は解決しない)。

## `heartbeat_input`を書くために必要な知識

`lib/repl/launch.exs`の`heartbeat_input/1`がElixirの実例（`Repl.Launch.build/1`が生成し、`message["heartbeat_input"]`として返す）。セッション起動直後に1回だけ書き込む、バックグラウンドで一定間隔ごとに`XT_HEARTBEAT`を印字し続けるコード。Elixirでの方針は「軽量プロセスをspawnし、`Process.sleep`+印字の自己再帰ループを回す」（BEAMのプリエンプティブスケジューリングにより、他の重い計算中でも動き続けられることを実機で確認済み）。**対象言語に同種の軽量並行処理機構が無い場合**（OSスレッドしか無い、async/awaitが協調的でブロッキング計算中は動けない、など）、この設計の前提が崩れる可能性がある。その場合はこのガイドの生存監視の章（`XipeTotec_prebuild.md` §10の該当部分）まで遡って再検討すること。

## `field_drip`（相当のモジュール）を書くために必要な知識

`lib/repl/eval/field_drip/elixir.exs`(`XipeTotec.Repl.Eval.FieldDrip.Elixir`)がElixirの実例。`XipeTotec.Repl.Eval.FieldDrip`のbehaviour(`parse(body) :: map()`)を実装する。本文フォーマット(`repr=`/`type=`/`display=`/`bin_base64=`)自体はxipe_totec全体で固定の規約なので、実装は「改行分割→`=`で最初の1回だけ分割」という単純なものになるはず(Elixir版が実際そうなっている)。対象言語の`eval_template`がこのフォーマット通りに印字する限り、field_dripを言語ごとに変える必要はほぼ無いはず。言語判定はfield_drip自身が行わない（呼び出し元が`Repl.Eval.Parser.step/5`に具体的なモジュールを渡す）。

## `scan`（相当のモジュール）を書くために必要な知識

`lib/repl/eval/scan/direct/iex.exs`(`XipeTotec.Repl.Eval.Scan.Direct.Iex`)がElixir+plain pipeの実例。**トランスポート(PTY/plain pipe)とREPL(iex/ghci/...)の2軸で、`lib/repl/eval/scan/<transport>/<repl>.exs`という配置になる。** 新しいREPLをplain pipe経由で足すだけなら`lib/repl/eval/scan/direct/<repl>.exs`を追加、新しいトランスポート(PTY等)を足すなら対応する`Sender`実装と対にして`lib/repl/eval/scan/<transport>/`配下に追加する。今のところ`Direct`(plain pipe)は実機検証済みの通りエコーバック・ANSIノイズが一切無いため、`clean/1`は`XT_HEARTBEAT`/`XT_EXIT`の検出・除去のみで足りている。PTY対応を追加するときは、ここにエコーバック除去・ANSI除去の実装が要る。

## 新しい言語を足すときのチェックリスト

算出プログラムを書く前に、対象言語のREPLについて以下を調べて（またはAIに調べさせて）から着手する:

1. デフォルトの起動コマンドは何か。プロジェクト全体を自動ロードする起動モードはあるか
2. 個別ファイルをコマンドラインからロードする方法はあるか（`mix`が無い構成向け）
3. 起動完了時に印字される、バージョンに依存しない安定した文字列は何か
4. そのREPL自身の正規の終了コマンドは何か
5. 関数呼び出しの構文（完全修飾名＋引数列から式を組み立てる方法）
6. 標準出力への印字関数
7. 例外を捕捉して握りつぶさず「終端マーカーまでは必ず印字する」ための構文
8. 値→文字列表現→再構築という往復検査に相当する機構があるか。無ければrepr判定の設計をどう作り直すか
9. 浮動小数点比較の許容誤差をどう扱うか
10. 軽量な並行処理機構（重い計算中でもハートビートを印字し続けられるか）があるか
11. プレーンなpipe接続（PTY無し）でそのREPLが正常に動作するか、それとも本物のtty必須か（後者ならPTY対応が前提になる。`XipeTotec_prebuild.md` §10.1のエコーバック課題も合わせて考慮）

これらの答えが`argv`/`ready_pattern`/`exit_input`/`heartbeat_input`（`Launch`相当のモジュール）と、`eval_template`相当のモジュール・`field_drip`相当のモジュール・（PTYなら）`scan`相当のモジュールになる。答えられない項目があれば、それは「対象言語では今のXipe Totecの設計がそのまま使えない箇所」なので、実装を進める前にcruxへ相談すること。

## 実装の参考にする実機テスト

`test/live/repl_iex_test.exs`（`test/run.sh`には含まれない、`elixir test/live/repl_iex_test.exs`で個別実行）がElixir版の全パイプライン検証。新しい言語を足したら、同じ構成（起動→完了検知→評価の6パターン(成功/in_plan参照/unsupported/例外/タイムアウト/構文が閉じていない呼び出し)→compare(same/changed)→ハートビート→離脱）の実機テストを、対象言語の実行環境が用意できた段階で書くこと。`test/fixtures/calc_sample/calc.exs`のような、外部依存の無い小さいサンプルプロジェクトを対象言語でも用意しておくと検証しやすい。
