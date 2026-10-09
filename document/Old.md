# Xipe Totec 決定歴（Old.md）

**この文書が答える問い**: いまの設計が、いつ・なぜ・どういう代替案を退けてそうなったか。

旧`XipeTotec_prebuild.md`（実装前確認書 rev.2 ＋ 2026-09-17〜23 の実装ノート）に、旧`課題.mkd`（Evaluator着手前の懸念A〜Hと回答、§28）を合わせた**記録用の文書**。2026-09-23に整理した。

- **節番号は旧`XipeTotec_prebuild.md`のまま**。コード・テスト・他文書のコメントにある「Old.md §N」はここを指す
- 本文は当時の記述のまま残しており、途中の「実装状況」「未コミット」「未着手」等は**書かれた時点のもの**。いまの状態は`README.md`、動作の道筋は`動作原理.md`を見ること
- **まだ解決していない事項は`課題.md`へ移した**。本書の§8・§8.1・§27は棚卸しした時点の記録として残してある
- 新しい決定はこの末尾に節を足して記録する（§29〜）

---

## 0. 旧題: Xipe Totec 実装前確認書 (rev.2)

`~/my_app/xipe_totec_spec_v0.4.html`（v0.4仕様書）をベースにした設計打ち合わせの結果。rev.1に対するレビューで見つかった6件の着手前修正（A〜F）と、進めながら直す点・細かい点をすべて反映済み。仕様書本体（§6.6, §9）にはまだ反映していない差分がある（8章参照）。

**実装状況（2026-09-16、最新状況は次段落）**: `~/my_app/xipe_totec/` に着手済み（git stage済み、未commit）。Book/Store/Core（イベント適用・参照グラフ・循環検出・affected集合・effectフィルタ・topo_sort・plan_recalc・apply_results）/Identity/Scanner（AST抽出＋コンパイラトレーサーによるlink抽出、fix F込み）/Project（ディレクトリ横断の2パス走査＋差分書き込み）まで実装・テスト済み（46 ExUnit tests, all green）。`xipe scan <dir>` → `xipe show` の実機動作を2ファイル構成のサンプルで確認済み。REPLアダプタの接続方式は2026-09-18に分散Erlang接続からテキスト入出力方式へ転換した（10章参照）。

**実装状況（2026-09-18 更新）**: REPL評価パイプラインの中核が実機`iex`で確認済みになった。`Repl.Launch`/`Sender`/`Session`（起動・完了検知・離脱、10.1〜10.2節）、`EvalTemplate`（呼び出し式組み立て・安全装置・repr判定・マーカー印字、10.5節）、`Eval.Scan`/`Scan.Direct.Iex`/`Eval.FieldDrip`/`FieldDrip.Elixir`/`Eval.Result`/`Eval.Parser`（受信パーサー一式、10.6〜10.9節）、`heartbeat_input`（生存監視、10.10節）まで実装・実機テスト済み（`test/live/repl_iex_test.exs`、9テスト）。`lib/repl_*.exs`はディレクトリ構成へ整理済み（10.7節）。

**実装状況（2026-09-18 続報、`xipe eval`まで到達）**: 前段落末尾の「まだ無いもの」を全て実装・実機確認済み(11.1〜11.6節)。`compare`判定（対象ノード側での項比較、浮動小数点許容誤差込み）、`:max_heap`と通常crashの区別、`Parser`出力→`Core.apply_results`→`Store`の配線(`Repl.Evaluator`新設)、ハング判定(セッション全体の無応答をkill+abort)、CLIの`xipe eval`コマンド。加えてレビューで見つかった実バグ4件（`:DOWN`メッセージリーク、crash reasonの`inspect`オプション漏れ、`repr`のatom/string不一致、`basis`が`prev`ではなく`result`を見るべきだった設計ミス）を修正。`Project.find_sheets/1`は`.exs`も拾うよう拡張(11.5節)。全体テスト168件+実機テスト11件、全green（`serve_project_test.exs`の既知の間欠フレークを除く）。**まだ無いのは**: §16サーバー側の非同期`eval/run`(Tier3のまま、意図的に`Dispatch`未着手)、`cell/complete`の値ベース半分、`edit/propose`/`edit/apply`、`trace/*`。

**実装状況（2026-09-22最新、外部レビュー2026-09-22で「この段落が09-18で止まっている」と指摘されたため更新）**: 上記「まだ無いもの」のうち`edit/propose`/`edit/apply`は§21でcruxの方針転換により**実質不要と決定**（連動修正の書き戻しはxipe_totecの守備範囲外とし、エディタ/LSP側に委ねる。xipe_totec側は静的カード生成の再実行＋既存の`:links`/`graph/neighbors`クエリで「参照一覧」を提供するに留める）。`trace/*`はTier5のまま凍結継続。§16以降で実装された主なもの: `row/depends`・`row/set-result`（§18/§19）、`xipe dialogue depends`の依存チェーン交渉（§19、§16.4の4ステップ全実装）、`card/get`の住所種別によらないカード合成統一（§20）、`plan_recalc/3`の`drop_unresolvable/2`による`session_hung`の根本原因修正（§22）、ハートビート撤去＋`erlexec`移行＋`Sender.interrupt/1`（§23）。全体テスト241件、全green（同じく`serve_project_test.exs`の既知フレーク除く）。詳細は各節・§18以降を参照。

**実装状況（2026-09-23最新）**: §21で構想した多言語プロジェクト対応（REPL/LSP仕分けプロトコル）が、`~/my_app/tezcatl`セッションでのco-designで具体化・一部実装された（§24〜§26）。設計は当初案（Book内新規`:files`テーブル）からxipe_totec自身が持つ中央レジストリ（`tables/`ディレクトリ）方式へ転換。実装済み: `xipe reflesh -l|-r|-a`＋`info.json`（`Info`、§24.4）、`surface_table`生成ロジック（`SurfaceTable`、§24.5〜§26.1 ── `repl`/`build_tool`は`language=="elixir"`の行にのみ実データ、mix.exsの有無まで検出）、プロジェクトID解決（`ProjectRegistry`、§24.6）、そして`Project.find_sheets/1`/`Runner.launch_opts_for/2`のハードコード解消（§26.2 ── 既存の拡張子リテラル・`mix.exs`直接チェックを`SurfaceTable`参照に置き換え、実機確認済み）。**まだ無いのは**: `SurfaceTable`/`ProjectRegistry`/`Info`を繋ぐCLIコマンド本体（`xipe table generate`/`xipe choice project`）、Elixir+mix以外の言語/ビルドツールの実判定ロジック（§25で設計のみ）、`Evaluator`/`Repl.Launch`側での実際の起動argv合成（nixラップ等）、`book.jsonl`自体の`tables/`配下への移設（§24.1で構想済みだが未着手、§27参照）。全体テスト265件、全green（同じく`serve_project_test.exs`の既知フレーク除く）。詳細は§24〜§26参照。**残タスクの一覧は§27（5項目・依存関係付き、crux確認済み）を見ること** ── 次にこのプロジェクトを再開するときは、まずここから読むこと。

---

## 1. 対象範囲（このビルドで作るもの）

変更なし。Core / Store / Scanner / REPLアダプタ / CLI / サーバーインターフェース。tezcatl側の対応は別ビルド（7章）。

## 2. データモデル

テーブル一覧・追記のみ・キー付きmapの方針はrev.1のまま。**追記のみのStoreに関して、以下4点を追加で決めておく**:

- **`row/remove`と墓標**: 削除は「削除を表す行」を追記して表現する（物理削除しない）
- **`clean`と肥大化**: 評価のたびに全列を伴う行が積み上がるので、明示的な圧縮コマンドを用意する（新しいファイルに現在状態だけを書き出してから置き換える）。これを「書き換えしない」方針の**唯一の例外**として明記する
- **途中で切れた最終行**: プロセス強制終了等でJSON Linesの最終行が壊れている場合、読み込み時に無視する
- **書き込み手の一本化**: サーバーが動いている間はCLIもサーバー経由で書き込み、ファイルへの同時書き込みを避ける

## 3. Coreの内部表現

- `Book`というイミュータブルなElixir map/struct。テーブルごとに`id => 最新行`のmap。ETSは使わない
- 1プロジェクト1GenServerが`Book`をstateとして保持する。GenServerは**Coreが作った計画(Plan)を実行し、結果をCoreに適用させるだけ**で、評価そのもの・値の正規化・git参照はしない（4章のA参照）
- 自然キー索引・階層コードの桁あふれ処理は保留のまま（後述、大きな問題にはならない想定）
- `trace`/`run`のストレージ方式はv0.5で再検討

## 4. 参照解決・再計算

### 4.1 affected集合の決定（Bの修正）

明示ターゲット = 「**dep_hashが変わった**nodeを使うcall」（body_hashではない。呼び出し先だけが変わったケースを拾うため）∪ 参照グラフ（`⟦id⟧`の正規表現抽出）を辿った全下流。ここにcall_hash比較は関与しない（純粋なグラフ到達可能性のみ）。

### 4.2 effectフィルタとunknownの扱い（Dの修正）

`pure`/`reads`のみを対象にする。`unknown`は`writes`と同じ扱いにし、`--include-writes`相当を渡さない限り評価対象にしない。**さらに今回のビルドでは、`effect/set`で明示指定されていないnode（＝`effect_source`が無い）は`--all`の対象に入れない**（安全側に倒す。8.2節の自動判定は範囲外のため）。

### 4.3 effect除外行の下流（Cの決定）

除外した行の下流は**保存済みの値をそのまま読んで評価する**（affected集合外への参照と同じ扱い）。下流ごと除外はしない。writesの計算行の「その時点の記録」を後から参照して使うのは正当なユースケース（6.4節の前回列運用と同じ思想）で、鮮度は`result_at`/`commit_at`で確認できるため新しいtaint列は追加しない。

### 4.4 3段構成（Aの修正版・確定）

Coreは評価を実行しない。計画を作る（純粋）→ Evaluatorが実行する（副作用あり）→ 結果を適用する（純粋）、の3段に分ける。**計画内部の参照（同じ計画内で先に評価される計算行への参照）は、計画作成時点では値が存在しないためテキスト埋め込みができない** ── プレースホルダ＋セッション変数束縛（`in_plan`）で渡す。計画外部の参照のうち、保存済みのexact/binary値を持つものだけがCoreによる文字列置換でそのまま埋め込める。unsupported＋pureな計画外参照は、値の埋め込みではなく呼び出し式そのものの再埋め込みが必要（§6.3）── これは言語構文の組み立てなのでCoreの仕事ではなく、Coreはmodule/name/argsを`inline_call`として渡すだけで、実際の式組み立てはEvaluator（REPLアダプタ）が行う（§28 B回答）。それ以外（unsupported＋非pure、または未知の参照）はセッション変数束縛（`binding`）にフォールバックする。

```elixir
Core.plan_recalc(book, targets, opts) :: {:ok, Plan.t()} | {:error, term()}

%Plan{
  pass_id: id,                      # 連鎖の安全装置(5章)の数え上げに使う
  restart_session: boolean(),       # 境界規則からの再起動指示
  entries: [Plan.Entry.t()]         # トポロジカル順
}

%Plan.Entry{
  call_id: id,
  node_id: id,
  module: String.t(),               # nodeのmodule/name/arityをそのまま転記（Coreは言語構文を知らない）
  name: String.t(),                 # 呼び出し式の組み立てはEvaluator（REPLアダプタ、言語依存）の仕事
  arity: non_neg_integer(),
  args: [String.t()],               # 埋め込み可能な参照は置換済み、それ以外はプレースホルダ
  inputs: [
    {:inline_call, %{placeholder: String.t(), module: String.t(), name: String.t(), args: [String.t()]}}
    # unsupported + pure（計画外）。Coreはmodule/name/argsを渡すだけ。argsは同じ規則で再帰的に
    # 解決済み（＝さらにinline_call/binding/in_planを含みうる）。呼び出し式の組み立てはREPLアダプタの仕事
    | {:binding, %{placeholder: String.t(), var: atom(), gen: non_neg_integer() | nil}}
    # unsupported + 非pure（または未知の参照）。セッション変数束縛を使う
    | {:in_plan, %{placeholder: String.t(), ref: id, var: atom()}}
    # 同一計画内の参照。計画作成時点では値が存在しないためプレースホルダ＋束縛のみ
  ],
  bind_as: atom() | nil,            # nodeがpureでない場合にCoreが指定。変数名はcall_idから決定的に生成
                                     # （inputsのvarと自然に一致する）
  basis: {:exact, String.t()} | {:binary, String.t()} | :none,
  limits: %{timeout: pos_integer(), max_heap_words: pos_integer()}
}

Evaluator.run(plan, session) :: [Evaluator.Result.t()]
# Evaluatorはbookを知らない。正規化・repr判定・比較（許容誤差込み）はここ（REPLアダプタ)の仕事

%Evaluator.Result{
  call_id: id,
  outcome:
    {:ok, %{repr: String.t(),  # "exact" | "binary" | "unsupported"
            display: String.t(), type: String.t(), bin: String.t() | nil}}
    | {:error, reason} | :timeout | :max_heap
    | {:skipped, upstream_id} | {:lost, ref} | :aborted,
  compare: String.t(),                # "none" | "same" | "changed" | "skipped"
  evaluated_at: String.t(),         # ISO8601文字列。Store.appendがそのままJSON.encode!するため%DateTime{}は不可
  session_gen: non_neg_integer()
}

Core.apply_results(book, ctx, results) :: Book.t()
# ctx = %{pass_id, commit, commit_at, dirty} ── git読み取りはGenServer側で行い、ここに渡すだけ
```

**訂正（2026-09-22、外部レビューで指摘・実装との食い違いを修正）**: 上のコードブロックは当初`basis`が`{:text, String.t()} | {:bin, binary()} | :none`、`repr`/`compare`がatom、`bin`が`binary()`だったが、これは実装（§11.1〜§11.3）と食い違っていた。`repr`/`compare`はCore内の他の箇所（`resolve_ref/4`の`repr in ["exact","binary"]`判定等）と同じ文字列規約で統一されており、atomは一切使わない。`bin`はbase64文字列（`Base.encode64/1`済み）で、生の`binary()`のままBookやStoreへ渡ることはない（JSON化できないため）。上のブロックは実装に合わせて修正済み。

補足:
- `eval_count`は`:ok`/`:error`/`:timeout`/`:max_heap`でのみ増やす。`:skipped`/`:lost`/`:aborted`では増やさない
- `:aborted`はセッションが実行途中で落ちた場合、残りのエントリに返す
- **`bind_as`の指定によらず、実際には常に束縛を残す**（訂正、2026-09-22）: 当初案は「結果が`unsupported`のときだけ」だったが、実装（§10.5、`document/repl-adapter-guide.md`の`eval_template`項目8）では`bind_as`の値によらず常にセッション変数へ束縛する。`in_plan`参照（同一pass内で後続callが先行callの結果を参照する）がこれを構造的に前提にしているため
- call_hash・コミット/ロックファイル差分は**評価後にのみ**計算し、`state`/表示情報に反映するだけ（実行の要否には使わない。9.2節・9.3節）

### 4.5 ID照合の最小規則（Eの修正）

7.3節の完全な照合（body_hash・needs_review判定）は範囲外だが、**`(path, module, name, arity)`が完全一致すれば既存IDを引き継ぐ**という最小規則は今回のビルドに入れる。これが無いと再スキャンのたびに全nodeへ新しいIDが振られ、既存の計算行がすべてref_errorになり実用にならないため。

### 4.6 stale判定のタイミング（整理）

評価した直後の行は定義上staleにならない（今の環境で今評価したものだから）。staleが意味を持つのは、評価されずに残った行に対して、再スキャン時（14.1節）に付く判定である。

## 5. 安全装置

- `eval.timeout`/`eval.max_heap`/`eval.max_per_pass`はconfigパラメータとして可変にする
- **`eval.max_per_pass`が守るのは静的な循環ではない**（循環は4.1節のグラフ到達可能性の手前、循環検出で`state:cycle`として既に除外済み）。守るのは「連動修正→ファイル監視→再スキャン→再計算」のような**連鎖**が止まらないケース。`Plan.pass_id`を連鎖を通じて引き継ぎ、累積の評価回数をこのpass_idに対してカウントする

## 6. 実装言語・REPLアダプタ

- Xipe Totec本体はElixirで確定（rev.1のまま）
- REPLアダプタは2パターン（個人利用=Nix非mix / 配布向け=mixベース）。config側は`repl.elixir.project_kind = mix | scripts`のような項目で切り替える（起動コマンド文字列だけでは切り替えられない。受信元取得の**戦略自体**が変わるため）。`scripts`側は`mix.lock`が無いのでロックファイルは`flake.lock`のみになる
- **受信元の取得（非mix）**: コンパイラトレーサーのイベントには送信先（`remote_function`等）と呼び出し元（`env.function`）が両方含まれるため、送信先を収集してその逆引きで受信元が得られる。`mix xref`非依存でも実装できる見通しが立った（旧・未解決項目、解決）
- **`.exs`スキャンの実行問題（Fの修正）**: `.exs`をそのままコンパイラトレーサーにかけるとトップレベルのコードが実行されてしまう（tezcatlの`main.exs`のようにサーバーを起動するスクリプトだとスキャンのたびにサーバーが立つ）。加えて稼働中のアプリのVMに接続してコンパイルすると稼働中のコードが差し替わる。
  - **対応**: 評価用のBEAMは対象アプリとは別に起動する。スキャンは`Code.string_to_quoted`でASTだけを読み、`defmodule`の部分だけを`Code.compile_quoted`にかける（トップレベルの他の式は実行しない）
- ~~**Erlang分散ノード接続**（`--sname`/cookie/epmdループバック限定）~~ **2026-09-18に撤回・10章のテキスト入出力方式に置き換え**（旧記述は§28 Dに残るが、参照する場合は10章の決定が優先）

## 7. tezcatl連携（方針のみ。ビルド対象外）

rev.1の方針（`/xipe`をLSPソケットと同型で新設、既存`/lsp`をprovider経由で共有）は変更なし。追加で:

- **9.3節の範囲の明確化**: 確認書ではNIF境界の話として書いていたが、仕様上は依存ライブラリ全般・Elixir/OTPの版・Nixの入力すべてが対象。実装担当に狭く伝わらないよう明記しておく
- **複数タブからの応答**: 1本の接続を複数ブラウザタブで共有する構成では、Xipe Totecが送った`provider/*`要求に複数タブが応答しうる。**同じ要求IDへの最初の応答だけを採用する**とXipe Totec側で決めておけば、中継（tezcatl relay）は中身を見ないままで済む

## 8. 未決定・要検討事項 / フォローアップ

> 2026-09-23: ここと§8.1のうち未解決のものは`課題.md`へ移した。以下は当時の記録。

- 自然キー索引の具体的なデータ構造（保留、大きな問題にはならない想定）
- 階層コードの桁あふれ時の区切り文字は**不要と判明**（既に`.`区切りのため、ある階層だけ`103`のように桁が増えても読み取りに支障なし。保留事項から解消）
- `trace`/`run`テーブルのストレージ方式（ETS併用にするか）はv0.5で再検討
- **仕様書本体への反映が必要**: call_hashによる評価省略をやめた点（旧§6.6・§9の記述）は、v0.4仕様書のテキスト自体にまだ反映されていない。実装が固まった後で仕様書側も更新する
  - **追記（2026-09-22、外部レビューで指摘: この1件だけでは足りない）**: 反映すべき差分は他にも積み上がっている。`row/depends`（§18、`Core.upstream_chain/2`）・`row/set-result`（§19、`Core.set_result/3`）── どちらもv0.4仕様§16.3のメソッド表に無い新設メソッド。`calls`テーブルの`result_source`列（§19、新設）。応答封筒の`from`/`dialogue`フィールド（§17.2、`Serve.Socket`の`initialize`以降の全応答に付く）。README「もう一つの柱」だった連動修正（`edit/propose`/`edit/apply`）の撤回（§21、代わりに参照一覧＋エディタ側委譲の方針）。仕様書自体は依然v0.4のまま未更新

## 8.1 散らばっている未決事項の集約（2026-09-22、外部レビューで指摘・本来§8に置くべきだった項目の棚卸し）

本書の中で「未決定」「先送り」「記録のみ」として個別に触れられているが、この§8に集約されていなかった項目。各項目の現状も併記する。

- **`defp`のnode化（§16.1）**: `Scanner.extract_def_clauses/2`が`defp`もnode化してしまい、REPLから呼べず必ずcrashする。**未修正のまま**（優先度低として記録のみ、対応時期未定）
- **`session_hung`の原因（§18）**: 当初「未解明」として記録されていたが、**§22で根本原因を特定・修正済み**（`plan_recalc`の`drop_unresolvable/2`）。もうここには残らない
- **`--sname`/cookie関連コードの削除（§10.8で「未実施、次のステップ」と記録）**: 実コード（`lib/repl/launch.exs`等）を確認したところ、**該当コードは既に存在しない**（`launch.exs`の該当箇所は「撤回した」という趣旨のコメントのみが残る）。いつ削除されたかの個別記録は無いが、完了はしている
- **`xipe do`で単一要素リストを表現できない件（§18）**: `args=10`のような単一要素は`coerce_value/1`がカンマの有無でしか判定できないため文字列のままになり、`row/add`等の`is_list(args)`ガードに落ちる。**未解決のまま** ── 今回のセッション（2026-09-22、`session_hung`再現テストの際）でも実際にこの制約に当たり、`Core.add_call`を直接叩くフィクスチャ作成スクリプトで回避した。CLIパーサー側の改修（例: 明示的な配列記法、または`args[]=`のような複数指定）が必要
- **`notify/*`への出自付与（§17.1で先送り）**: どのセッションの操作が引き金だったかを`notify/*`に含めるかどうか。**未着手のまま**
- **WS側の`run_to_completion`（§17.3で言及）**: `InOut.run_to_completion/7`は現状CLI側（`xipe dialogue depends`）でのみ使われており、`Serve.Socket`側での複数ターン駆動ループへの配線は**未着手のまま**（§17末尾の「まだ無いもの」と同じ）
- **§2「サーバー稼働中はCLIもサーバー経由で書く」**: 決定は記録されているが、**実装を確認したところ全く配線されていない** ── `main.exs`のCLIコマンド（`run_commands/3`）は`xipe serve`が起動中かどうかを一切見ず、常に`Store.load`/`Store.persist_diff`で直接book.jsonlを読み書きする。これは`serve_project_test.exs`の既知の間欠フレーク（複数箇所で「CLI直接操作とServe.Project経由の同時書き込み」として言及されている）の実際の原因である可能性が高い。ロック機構またはCLI→サーバー経由への切り替えが未実装のまま残っている
- **§5の`eval.max_per_pass`のconfig化**: §11.2で「設定機構がこのコードベースに存在しない」ため見送られたのと同じ理由で、**未着手のまま**（§28 Cの誤差パラメータ化と同じ事情、`§28`追記2026-09-22参照）
- **doctestの鮮度基準（§9）**: 「既存の有効なdoctestファイルがあればそれを優先し、無ければテーブルから即席生成する」の判定基準が**未決のまま**
- **`XT_EXIT`を予期せず受けたときの専用処理が無い（外部レビュー2026-09-22で指摘・実装確認済み）**: `Scan.Direct.Iex.clean/1`は`exit_status`を検出するが、`Evaluator.wait_result/6`はそれを一度も読まない。entry完了前にセッションが予期せず終了しても専用の検出は起きず、単に何も届かなくなり固定デッドライン（§23）まで待ってから`session_hung`として処理される。ラベルは不正確（実際はexitであってhangではない）だが、無限待ちにはならず安全側に倒れる。実害が出るまでは優先度低として記録のみ

## 9. §16 サーバーインターフェース実装ノート（2026-09-17、tezcatl連携の設計作業から）

tezcatl側の `/xipe` 接続モデル検討（`~/my_app/tezcatl/forAI/progress.md` 2026-09-17分）と対になる、xipe_totec側の実装設計。

**実装状況（2026-09-17 更新）**: `Address`・`Protocol`・`Dispatch`・`Serve.Project`・`Serve.Socket`・`GraphQuery`・`main.exs`の`xipe serve`サブコマンドまで実装・テスト済み（104 ExUnit tests, all green。`Store.persist_diff/4`を新設し`Project.persist_scan/3`もそちらへ委譲するリファクタ込み）。`xipe serve <dir> --port <p>`を実際に起動し、Node.jsの生WebSocketクライアントで `initialize`（未初期化リクエストの拒否込み）→`scan/run`→`notify/nodeChanged`受信までの実機ラウンドトリップを確認済み。

`GraphQuery`（`graph/neighbors`・`graph/export`）は `:links` テーブルの静的呼び出しグラフ（`role:"to"`のみ格納、"from"は逆引きで作る）上の深さ制限BFS。`graph/export`は `mermaid`/`dot`/`json`/`doctest` の4形式（§15 CLI通り）。**`doctest`形式は今回の「カード＝仕様通り、個別テストの固定は`doctest`エクスポートの一形式」という決定の実体で、今回実装したのはテーブルからの即席生成（フォールバック）のみ。REPL再評価してから書き出す高鮮度側はEvaluator待ちで未実装、両者の優先順位も未決のまま。** `graph/neighbors`/`graph/export`のパラメータ形（`{"address":..,"depth":..,"direction":..}`）は仕様に明記が無いため今回の実装で決めた（`card/get`のようなフラットな住所直渡しではなく`address`キーへネスト）。

**残っているのはTier3以降のみ**（`row/update`・`eval/run`・`cell/complete`・`edit/propose`・`edit/apply`・`trace/*`・`provider/recheck`）── `Dispatch`内で明示的な`not_implemented`エラーとして応答する。§16 サーバーインターフェースのTier1相当は実質完了。

GitHubリポジトリ: `git@github.com:Crux-xurC/xipe_totec.git`（2026-09-17作成、まだpushしていない ── ローカルはgit stageのみ、未commit。cruxの計画: GraphQuery完了→文書化→commit/push の順）。

- **Tier 0（着手済み）**: `nix/relay-packages.nix` を新設し `cowlib`/`ranch`/`cowboy`（2.13.0/2.1.0/2.12.0）を追加、`flake.nix` の `buildInputs` に配線。tezcatl の `nix/relay-packages.nix`・`~/my_app/nix/exla-packages.nix` と同一バージョン・同一 `sha256`（`fetchHex` はハッシュが内容アドレスなのでコピペで安全、ハッシュ調査不要）。`gun`（WSクライアント）・`erlexec`（子プロセス起動）はxipe_totec側には不要（xipe_totecは接続される側のサーバーなので）。`nix flake check` 通過・`nix develop` 内で cowboy ビルド確認済み、テスト（17件）green。まだ git stage のみ、未commit。
- **住所オブジェクトの形は仕様通り（§6.1）に確定**: `{table,id}`直指定ではなく、`{"file":.., "name":.., "arity":..}` のような**列の組による部分一致フィルタ**（`--file`/`--module`/`--name`/`--arity`/`--type`/`--hier`/`--row` の組み合わせ、一意なら対象を、複数該当なら候補を返す）。`card/get`・`card/search`・`graph/export`の範囲選択（`--depth`込み）が同じ解決ロジックを共有できる見込み ── 新規 `XipeTotec.Address` モジュールとして切り出し、3メソッドから使う。
- **「カード」は仕様の定義のまま**（用語集: 「1関数分の行のまとまり。スキャンで自動的に作られ、関数がソースにある限り存在する」／§4.1「カードや表計算風の表示は、これらのテーブルに対する見え方の一つ」）。**crux案の「個別テストで固定した1ファイルのカード」は新しい保存機構ではなく、`graph/export --format doctest`（§15 CLIに既出）の凍結スナップショットとして位置づける**（決定・2026-09-17）:
  - `doctest`エクスポートは2経路を持つ。優先度が高いのは「対象の計算行を他の計算行の値に頼らず単独でREPLに通し直してから書き出す」（鮮度が高いが**Evaluator待ち＝Tier3**）。フォールバックは「今のテーブルの値をそのまま書き出す」（Evaluator不要、今すぐ作れる）
  - 既存の有効なdoctestファイルがあればそれを優先し、無ければテーブルから即席生成する、という判定を挟む（判定の具体的な鮮度基準はまだ未決）
- **モジュール構成案**（`XipeTotec.*`、既存の `lib/*.exs` と同じ平たいレイアウト）:
  - `lib/protocol.exs`（`XipeTotec.Protocol`）── §16.3のwire形（request/response/notify/provider要求）のエンコード・デコードのみ。純粋、Core同様サーバー抜きでテスト可能
  - `lib/dispatch.exs`（`XipeTotec.Dispatch`）── method名→ハンドラの表。Tier1は既存`Core`/`Project`へ委譲、Tier3〜5は「未実装」を明示するエラー応答を返す固定ハンドラを今から置く（クラッシュさせない）
  - `lib/address.exs`（`XipeTotec.Address`、新規）── §6.1の列フィルタ解決。`card/get`・`card/search`・`graph/export`の範囲選択が共有
  - `lib/graph_query.exs`（`XipeTotec.GraphQuery`、新規）── `graph/neighbors`（`Core.reference_graph/1`に深さ制限）、`graph/export`（mermaid/dot/doctest/json 各フォーマッタ。doctestは上記の2経路＋判定を持つ）
  - `lib/serve_project.exs`（`XipeTotec.Serve.Project`、GenServer、新規）── §3「1プロジェクト1GenServer」の実体。state=`%{book,root,store_file,sessions}`。`Dispatch`実行→Book差分を`Store.append`→応答。変更があれば`notify/rowChanged`等をattach中の全セッションへブロードキャスト（**id書き換えは無し** ── `LspServer`と違い外部の単一プロセスへ中継しているわけではなく、Xipe Totec自身がid空間の持ち主なので不要と判断）
  - `lib/serve_socket.exs`（`XipeTotec.Serve.Socket`、`:cowboy_websocket`、新規）── 1接続=1インスタンスの薄いトランスポート層。**`initialize`のセッション状態（`initialized?`・宣言された解析能力）はSocket側のローカルstateに置く**（Project GenServerを経由させない。決定理由：xipe_totecは独立ツールとして使われるのが基本で、stdio/WS/LSPモード/MCPの各エントリが各々別セッションを持つのが自然なため）
  - `main.exs` に `xipe serve <dir> [--port N]` サブコマンドを追加（新規ファイルは作らず既存パターンを拡張。tezcatlの`main.exs`の`cowboy_router`配線とほぼ同型でコピーできる）
  - provider/*（サーバー発リクエストの応答待ち・相関）は保留。tezcatl側のproviderプロキシが無いと検証できないため後回し
- 次のステップ（§16サーバーインターフェース側）: 上記モジュールを実装に落とす。`Address`の列フィルタ実装から着手予定。

## 10. REPL接続方式の転換（2026-09-18、分散Erlangを撤回しテキスト入出力に一本化）

**動機**: Xipe Totecはもともと「対象プロジェクトのREPLへ手で式を打ち込んで関数ごとに確認する」作業をショートカットするために構想されたツール。ならば評価の経路も、人間がREPLの端末に対して行う操作（式を打ち込み、印字された結果を読む）をそのまま自動化する形にする方が筋が通る、という判断（crux、2026-09-18）。6章の「Erlang分散ノード接続」（`--sname`/cookie/epmdループバック限定/`Node.connect`/`:erpc.call`）は撤回。

**新しい経路（決定事項）**:

- Xipe Totec自身のBEAMは対象プロジェクトの`iex`と分散接続しない。ノード名・cookieの生成、loopback制限（`ERL_EPMD_ADDRESS`等）は不要になった
- 評価は「起動した`iex`の標準入力へテキストとして式を書き込み、標準出力に印字された結果を読む」経路に一本化する（PTY経由でもプレーンなPipe経由でも同じ扱い）
- **束縛の保持が簡略化される**: D回答で検討していた「対象ノード側に束縛保持用の別プロセスを立てる」仕組みは不要になった。iexセッション自身の変数束縛をそのまま使い回せる（人間が対話的にREPLを使うのと同じ）
- 起動完了検知・評価結果の受信は、いずれも「PTY/標準出力のストリームをテキストとして監視し、既知のパターン（バナー・プロンプト、または評価ごとに一意なマーカー）を見つける」という同じ仕組みに一本化する。マーカー方式の具体形（例: `IO.puts("XT_BEGIN_<uid>")`で結果を挟んで印字させる）は次のステップで詰める
- 安全装置（`Process.flag(:max_heap_size, ...)`等）自体は評価コードに引き続き埋め込むが、`:erpc.call`のtimeout引数に頼れなくなるため、xipe_totec側でも監視の仕組みが要る（生存確認・タイムアウトの扱いは次項で確定）

**生存確認・タイムアウトの設計方針（確定・2026-09-18）**: 単純な「一定時間内にマーカーが来なければtimeout」という判定は、(a)依存先の評価に失敗した、(b)計算が単に長引いている、(c)REPLプロセス自体がクラッシュした、を区別できないという指摘（crux）を受け、次の形に決定:

- **(a)は評価テンプレート側の設計で解消する**: 例外を必ずtry/rescueし、成功時は`XT_END_<uid> <result>`、失敗時は`XT_ERROR_<uid> <reason>`のように、**完了時は必ず何らかの終端マーカーを印字する**。これによりtimeout待ちと衝突しなくなる
- **(c)クラッシュ検知**: セッション起動時に立てたSenderの`handle`から届く`"XT_EXIT <status>"`マーカー（10.1節、push型・即座）を監視し、届いたら残りのpassを`:aborted`にしてセッション再起動
- **(b)/(c)のうち"ハング"の区別**: セッション起動時に1つ、バックグラウンドで一定間隔（例: 5秒ごと）にハートビートマーカーを印字し続ける軽量プロセスを立てる。BEAMのプリエンプティブスケジューリングにより、重い計算中でも他プロセスは動けるため、ハートビートは計算の重さに影響されず届き続ける。ハートビートが届いている間は「生きて動いている」(b)と判断して`eval.timeout`（既存config、外側の安全上限）まで待ち、ハートビートが一定回数途切れたら「ハング」とみなしてkill+セッション再起動
- クラッシュ・ハング・完了(成功/失敗)の3種類とも、**同じpush型の`{handle, {:data, binary()}}`チャンネル上のテキストマーカーとして届く**（10.1節のSender契約と統一）。詳細な状態遷移・具体的なタイムアウト値の設定はまだ実装に落とし込んでいない

### 10.1 `Sender`ハンドルの契約は単一メッセージ型に統一（確定・2026-09-18）

PTY経由でもプレーンなpipe経由でも生存監視が同じように機能するかを検討した結果、**`Repl.Sender`のpush契約は`{handle, {:data, binary()}}`一種類だけに統一する**と決定。プロセス終了は別メッセージ型（生の`Port`の`:exit_status`、erlexecベースの`:DOWN`監視など、実装ごとに出どころが違う）にせず、**`"XT_EXIT <status>\n"`という予約テキストマーカーとして同じ`:data`チャンネルに合成して流す**（`XT_BEGIN_<uid>`/`XT_END_<uid>`と同じ命名規則）。理由:

- 実装ごとに異なる生存シグナルの翻訳負担を、受信側ではなく各`Sender`実装側に一本化できる
- 受信側（パーサ・監視ロジック）はトランスポートを問わず同じロジックで扱える
- PTY特有の懸念（エコーバック、cookedモード）は残るが、少なくとも「メッセージ型が実装によって違う」という問題は解消される

`lib/repl_sender_direct.exs`の`Direct`は、この契約に合わせて**転送用の軽量プロセスを挟む形に変更済み**（2026-09-18）: 実際の`Port`はこの転送プロセスが所有し、`{:data, ...}`はそのまま呼び出し元へ転送、`{:exit_status, n}`は`"XT_EXIT <n>\n"`という`:data`メッセージに合成してから転送する。返り値の`handle`はこの転送プロセスの`pid()`であり、生の`Port`ではなくなった。

### 10.2 起動完了検知・離脱も言語環境ごとの算出データに含める（確定・2026-09-18）

`Repl.Launch`（算出プログラム）が、起動コマンド（`argv`/`env`/`cwd`/`files`）に加えて以下の2つも計算し、`message`へ含める:

- **`ready_pattern`**: 起動完了を判定するためのテキストパターン（Elixirの既定値は`"Interactive Elixir"`という部分文字列。バージョン番号は含めない ── iexバナーの`Interactive Elixir (1.18.4) - ...`はバージョンでズレるため）。**部分文字列一致であり正規表現ではない**（JSON化できる値に留めるための単純化。将来必要になれば正規表現ソース文字列として持たせる余地は残す）
- **`exit_input`**: 正常終了のためにREPLへ書き込むテキスト（Elixirの既定値は`"System.halt()\n"`）。BEAMの正規の終了経路を通すことが目的

実行側（`Repl.Sender`とその上に乗る汎用オーケストレーション）は、この2つの値を**言語に関する知識なしにそのまま使う**だけにする。起動完了検知は受信ストリームを`ready_pattern`でスキャンするだけ、離脱は`exit_input`を評価リクエストと同じ「stdinへの書き込み」経路で送るだけ。

**重要な限界（デメリットとして明記）**: `exit_input`による正常終了は、セッションが**stdinを読みに行ける状態**（計算中でなく、ハングもしていない）でなければ効きません。前回設計した「ハートビート断絶→ハング検知→kill+セッション再起動」というシナリオでは、まさにセッションがstdinを読めない状態なので、`exit_input`を送っても意味がありません。したがって`exit_input`は「正常終了時の綺麗な離脱」であり、「ハング時の強制終了」の代替にはならない。**両方を持つ**（正常時は`exit_input`、ハング時は強制的なkill）方針とする。このため`Repl.Sender`のbehaviourには`write/2`（stdinへの書き込み、`exit_input`にも評価リクエストにも使う）に加え、`kill/1`（強制終了、生存確認や`exit_input`が効かなかった場合の最終手段）を追加する。

`Repl.Sender.Direct`は`Port`を直接所有する軽量プロセスを`GenServer`化し、`write/2`（`Port.command/2`）と`kill/1`（実装済み）を実装する。`kill/1`は`Port.close/1`だけには頼らない ── ポートを閉じてもOSプロセス側が気づいて終了する保証は無い（既知のErlangの落とし穴で、まさにハング状態のプロセスを想定するこのコールバックにとって致命的）ため、**`Port.info(port, :os_pid)`で得たOSのpidへ実際にSIGKILLを送る**（`System.cmd("kill", ["-9", pid])`）。killされたプロセスの終了は、Erlangの慣例（128+シグナル番号）通り`:exit_status`として自然に届くので、既存の`XT_EXIT`マーカー変換経路がそのまま使える。新モジュール`Repl.Session`（`lib/repl_session.exs`）が、`Launch`の出す`ready_pattern`/`exit_input`と`Sender`の`send/1`/`write/2`/`kill/1`を組み合わせた汎用オーケストレーション（起動完了待ち・graceful close→timeoutならkillのフォールバック）を提供する。言語固有の分岐はここには一切無い。実装・テスト済み（`sleep 30`する実プロセスを実際にSIGKILLして`XT_EXIT`受信まで確認）。

**PTY特有の未解決課題（2026-09-18、実装は未着手）**: PTY接続時は入力のエコーバックがあるため、こちらが書き込んだマーカーテキストが「①入力のエコー」「②実際の評価結果」の2回ストリームに現れる可能性がある。対策は(a) PTY割り当て時にrawモード/エコー無効を設定する、(b) パーサ側で1回目のエコーを無視するロジックを持つ、のどちらか。今のところ`Sender.Direct`はplain pipeのみでPTY割り当てをしていないため、この課題はPTY対応を追加するときに解決する。

### 10.3 評価リクエスト・ハートビートも算出データに統合（確定・2026-09-18）

当初は「呼び出し式の組み立て」「repr/compare判定ロジック(C)」「マーカーテンプレート」を別々のステップとして並べていたが、**この3つは1つに統合される**と気づいた。理由: repr/compare判定は対象プロジェクト固有の構造体を含みうる値を扱うため、xipe_totec自身のBEAMではなく**対象ノード（起動したiex）自身の中で実行する必要がある**（分散接続を撤回する前の設計でも同じ理由でそうなっていた）。つまり、呼び出し式の組み立て・repr判定(a: pid/port/reference/fun検出→unsupported、b: inspect+再評価の往復検査→exact、c: term_to_binary→binary)・compare判定を全部含んだ**1つの評価コード片**を、マーカー(`XT_BEGIN_<uid>`/`XT_END_<uid>`/`XT_ERROR_<uid>`)で結果を挟んで印字するところまで込みで、対象言語のコードとして組み立てて送り込む。xipe_totec側は既に判定済みのテキストをマーカーで切り出すだけでよい。

これを`eval_template`として、`ready_pattern`/`exit_input`と同じく算出データ（`Repl.Launch`、または将来評価専用に分離するモジュール）に持たせる。加えて、生存監視のための**`heartbeat_input`**（定期的にハートビートマーカーを印字するコード片。対象言語の並行処理機構が要る）も同じ枠に含める。

### 10.4 実機iexでの検証（確認済み・2026-09-18）

`test/live/repl_iex_test.exs`（`test/run.sh`には含まれない。glob対象外の`test/live/`配下に意図的に置いた。個別実行: `elixir test/live/repl_iex_test.exs`）で、これまで`sh`/`cat`/`sleep`のような汎用コマンドでしか検証していなかった`Repl.Launch`/`Sender.Direct`/`Repl.Session`一式を、実際の`iex`に対して確認した。対象は`test/fixtures/calc_sample/calc.exs`（mix無し・外部ライブラリ依存無しの単純な計算モジュール。`xipe scan`/カード化の検証にも後で再利用する想定で用意）。

確認できた実際の出力（`argv: ["iex"], files: ["calc.exs"]`、`project_kind: scripts`相当）:

```
# 起動直後
Erlang/OTP 27 [erts-15.2.7.6] [source] [64-bit] [smp:20:20] [ds:20:20:10] [async-threads:1] [jit:ns]

Interactive Elixir (1.18.4) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)> 

# IO.puts("XT_LIVE_CHECK_" <> to_string(Calc.add(2, 3)))\n を書き込んだ後
XT_LIVE_CHECK_5
:ok
iex(2)> 

# exit_input（"System.halt()\n"）を書き込んだ後
XT_EXIT 0
```

わかったこと:
- **`ready_pattern = "Interactive Elixir"`は実機で正しく検出できる**。バージョン番号を含めなかった判断も裏付けられた
- **`Sender.Direct`（素のpipe、PTY未割り当て）には入力のエコーバックが一切無い**ことを実機で確認。10.1節で懸念していたエコー問題は、PTYを実際に割り当てたときに初めて発生する話で、今のプレーンpipe経路には該当しない
- **評価結果の後に、その式自体の戻り値（`IO.puts/1`は`:ok`を返す）と次のプロンプトが続けて出力される**。`eval_template`の出力パース設計では、このノイズが後ろに付いてくる前提でマーカー抽出を組む必要がある（マーカーで囲えば無視できるはずだが、次に`eval_template`を書くときに要確認）
- **`exit_input`（`System.halt()\n`）は実機のiexに対しても問題なく機能し、`XT_EXIT 0`で綺麗に終了する**ことを確認

**マーカー規約自体（`XT_BEGIN_<uid>`/`XT_END_<uid>`/`XT_ERROR_<uid>`/`XT_EXIT <status>`）はxipe_totec全体で固定の取り決めであり、言語ごとに変わらない。** 変わるのは「その言語でこの文字列をどう印字するか」だけ。受信側のパーサーは、この固定マーカー規約だけを知っていればよく、言語知識を一切持たない（`Repl.Session.await_ready/3`と同じ「バッファに貯めてパターンを探す」方式を再利用する見込み）。

あわせて、他言語（§12.6候補: GHCi/utop/Clojure/Racket）を追加する際に何を用意すればよいかのガイドを`document/repl-adapter-guide.md`として作成（2026-09-18）。

### 10.5 `eval_template`本体、実装・実機検証済み（2026-09-18）

`lib/repl_eval_template.exs`の`EvalTemplate.build/1`。`call_expression/1`（呼び出し式組み立て、既存）に、安全装置（`spawn_monitor`+`Process.flag(:max_heap_size, ...)`+`receive...after`）・repr判定（a: pid/port/reference/fun検出→unsupported、b: inspect+`Code.eval_string`往復検査→exact、c: `:erlang.term_to_binary/1`→binary、10.3節の設計通り）・マーカー印字（`XT_BEGIN_<call_id>`/`XT_END_<call_id>`/成功時、`XT_ERROR_<call_id>`/失敗時）を組み合わせた、対象のiexセッションへ送り込むElixirソーステキストを生成する。`entry.call_id`をそのままマーカー接尾辞・変数名接尾辞に使う（本番はULIDで固定長のため、他のプレースホルダ文字列とのprefix衝突は起きない）。

**評価対象のcallは、`bind_as`の値によらず常に`xt_<call_id>`というトップレベルのセッション変数へ束縛する**（前回確認した通り、`in_plan`参照の構造的な必要性 + tezcatl連携での可視化、crux）。

**実装中に実機検証で見つけたバグ（修正済み）**: 当初の設計は`receive`の結果を`{:xt_ok, val}`/`{:xt_crash, reason}`/`{:xt_timeout, nil}`というタグ付きタプルとして`xt_<call_id>`へ束縛し、その後の`case`文で分岐してrepr判定・マーカー印字をする形だった。これは**Elixirの変数スコープの都合で2重に壊れていた**:

1. `case`ブロックの各分岐内で束縛した変数は、そのブロックの外(トップレベル)には見えない。iexの「入力ごとにトップレベルの束縛を引き継ぐ」仕組みは、各entry(ここでは`case`全体)自体の戻り値を捉えた束縛にしか働かない
2. そのため`xt_<call_id>`には常にタグ付きタプル(`{:xt_ok, 5}`など)が入ったままになり、後続entryが`in_plan`でこの変数を生の値として参照すると型エラーで落ちる

実機(`test/fixtures/calc_sample/calc.exs`に対する2call構成のpass、`c2`が`c1`を`in_plan`参照)で実際に`{:erlang, :*, [xt_ok: 5, xt_ok: 5], ...}`という`badarith`クラッシュとして再現・確認した。**対策**: repr判定・マーカー印字を`case`文に分離せず、`receive`の各分岐の中に直接インライン化し、各分岐の末尾式(成功時は生の値、失敗時は`nil`)がそのまま`receive`全体の戻り値になり、それが`xt_<call_id>`へ束縛される形に変更。修正後、実機で`in_plan`参照が正しく動作することを確認（`Calc.add(2,3)`→`xt_c1=5`→`Calc.square(xt_c1)`→`25`）。

**実機で確認した5パターン**(`test/live/repl_iex_test.exs`、6テスト、個別実行):
- 通常の成功(repr=exact)
- `in_plan`参照(前段の束縛を後段がそのまま使う、上記バグの回帰テスト)
- unsupportedな値(pid) — 正しく`repr=unsupported`として印字される
- 例外発生 — `XT_ERROR_<call_id> crash <reason>`として報告され、**セッション自体はクラッシュせず生き続ける**(spawn_monitorによる隔離が機能している)ことも確認
- タイムアウト(`:timer.sleep(5000)`に`timeout: 300`を設定) — 約320msで`XT_ERROR_<call_id> timeout`として報告され、スポーンしたプロセスは実際にkillされる

**2箇所の小修正、実装・実機検証済み（2026-09-18）**:
- **`width: :infinity`をすべての`display=`用`inspect`呼び出しに追加**: 既定の80桁幅だと大きい値が複数行に整形されてしまい、「1行1フィールド」前提のパーサーが壊れる。実機で100要素のリスト(`Calc.wide_list/0`、`test/fixtures/calc_sample/calc.exs`に追加)を評価し、`display=`が改行無しの1行に収まることを確認した
- **`type=`フィールドを追加**: `Evaluator.Result`の`outcome`が要求する`type`(型名)が印字されていなかった。`is_integer`等の判定カスケードで`"integer"`/`"list"`/`"pid"`等、structなら`inspect(v.__struct__)`を返す小さな判定関数を追加、repr判定の3分岐すべてに`type=`行を追加した

まだ未着手: `heartbeat_input`、`Core.apply_results`への接続、CLIへの配線(ただしCLIは「1プロジェクト1Evaluator+非同期配信」というサーバー側の設計を前提にせず、`xipe scan`/`xipe show`と同じ同期的な一発コマンドとして作れば薄く済む、という整理が付いた・2026-09-18)。

### 10.6 受信側パーサーの分割設計・一部実装済み（2026-09-18）

`parser.exs`(仮称、未実装)が`scan.exs`・`field_drip.exs`・`result.exs`の3つをrequireして組み合わせる形に分割する方針を確定:

- **`result.exs`（実装・テスト済み）**: `lib/repl_eval_result.exs`(`XipeTotec.Repl.Eval.Result`)。`success/3`/`error/3`が、既に実機検証済みの`eval_template`出力形(`repr`/`type`/`display`/`bin_base64`)を入力とし、`Core.apply_results`が受け取れる`Evaluator.Result`形へ変換する。設計上ここは未決定事項が残らない(crux)ため、`scan`/`field_drip`より先に着手した。**scope外として明記**: `:max_heap`は`eval_template`側がまだ他の crash と区別できていない(既知のギャップ、`eval_template`側の課題)ため未対応。`{:skipped,_}`/`{:lost,_}`/`:aborted`はpassレベルのオーケストレーション判断であり、単発の評価結果からは導出できないため対象外
- **`scan.exs`（実装・テスト済み）**: `lib/repl/eval/scan.exs`(`XipeTotec.Repl.Eval.Scan`)。**言語・REPLに依らない汎用層**。既に雑音除去済みのバッファから、指定した`call_id`の`XT_BEGIN`〜`XT_END`ペア、または`XT_ERROR`行を検出するだけ
- **`scan_<REPL>.exs`（`Scan.Direct.Iex`のみ実装・テスト済み。2026-09-18に`Scan.Direct.Iex`へ改名、10.9節参照）**: `lib/repl/eval/scan/direct/iex.exs`(`XipeTotec.Repl.Eval.Scan.Direct.Iex`)。**REPL/トランスポートごとの前処理層**。`Sender.Direct`(素のpipe)経由の`iex`向けに、`XT_HEARTBEAT`・`XT_EXIT <status>`をバッファから検出・除去してから`scan.exs`へ渡す。プロンプト/エコー/ANSI除去も本来ここに入る想定だが、`Direct`は実機検証済みの通りそれらが一切無いため今は素通り。決定事項(crux): ハートビート/EXIT検出も「REPL固有の雑音掃除」としてこの層にまとめる(汎用層でもう一度バッファ全体を舐め直さずに済む)
- **`field_drip.exs`（behaviour定義のみ実装済み）**: `lib/repl/eval/field_drip.exs`(`XipeTotec.Repl.Eval.FieldDrip`)。`Sender`/`Scan.<repl>`と同じ形で、`@callback parse(body) :: map()`だけを持つbehaviour。呼び出し元(`parser.exs`)が具体的な`FieldDrip.Elixir`(未着手、次のステップ)を明示的に渡す。言語の判定は`field_drip`自身が行わない(`Launch`で既にどの言語のセッションかが分かっているため)
- **`parser.exs`（実装・テスト済み）**: `lib/repl/eval/parser.exs`(`XipeTotec.Repl.Eval.Parser`)。`step(buffer, call_id, scan_module, field_drip_module, session_gen)`が`scan_module.clean/1`→`Scan.scan/2`→(成功なら)`field_drip_module.parse/1`→`Result.success/error`を1回で行う。`scan_module`/`field_drip_module`を引数として受け取る設計にしたことで、**今後REPL/言語の対象が増えても`parser.exs`自体は変更不要**（cruxの狙い通り、既に固定される形）。`:pending`の場合でも、その回で見つかったハートビート数/exit_statusは返す(呼び出し元の生存監視が評価待ち中でも取りこぼさないため)。テストは`FieldDrip`のbehaviourを満たすテスト専用のフェイク実装(`FakeFieldDrip`)で配線のみ確認(実際の言語別実装はまだ無い)

**`eval_template`の呼び出し式組み立て部分、実装・テスト済み（2026-09-18）**: `lib/repl/eval_template.exs`（`XipeTotec.Repl.EvalTemplate`）。`Plan.Entry`のmodule/name/argsから呼び出し式テキストを組み立てる、純粋関数のみ（repr/compare判定・マーカー印字・安全装置はまだ未着手、次項）。実装中に見つけた注意点: `binding_name/1`は`call_id`から決定的に生成されるため、**同じプレースホルダ文字列が`:inline_call`のターゲットとしても、より深い位置での`:binding`フォールバックとしても現れうる**（`core.exs`のoccurs-check ── 循環をまたいで同じcallに複数経路で到達するケース）。素朴に「このプレースホルダの出現全部を同じように置換する」と、Coreのoccurs-checkが防いだ無限展開をテキスト組み立て側で再発生させてしまう。`expand/4`の`expanding`（Coreの`visiting`と同じ発想のaccumulator）で、展開中のプレースホルダに再度出会ったらそこは展開せずバインディング参照のまま残す、という形で対応。`core_test.exs`の`c10 -> c8 ⇄ c9`ケースと同じフィクスチャで確認済み（期待通り`"M.g(M.f(M.g(xt_c8)))"`を生成）。

**未着手（次のステップ、この節を書いた時点。以下の訂正参照）**: repr判定（対象ノード側で実行、a: pid/port/reference/fun検出 → unsupported、b: inspect+再評価の往復検査 → exact、c: term_to_binary → binary）、compare判定、`spawn_monitor`+`Process.flag(:max_heap_size, ...)`+`receive...after`の安全装置、マーカー印字、`bind_as`が指定されている場合のセッション変数束縛。これらは対象ノード自身で実行されるElixirコードのテキストとして組み立てる必要があり、呼び出し式組み立てより検証が難しい（`elixir -e`でロジック片は個別に検証できるが、実機のiexセッションでの動作確認はcrux側のライブ検証に委ねる部分が残る）。

**訂正（2026-09-22、外部レビューで指摘）**: 上の「未着手」は§10.6を書いた時点のものがそのまま残っていた。実際にはこのすぐ後の**§10.5（節番号は前後するがこちらが後続の実装）でrepr判定・compare判定・安全装置・マーカー印字とも実装・実機検証済み**になっている。読む順は節番号どおりではなく、この節（10.6）→10.5→10.7…という時系列だったため混乱を招いた。`parser.exs`についても同様（285行目「仮称、未実装」は方針確定時点の記述、291行目「実装・テスト済み」が実際の到達点）。

**テスト作成中に見つけた既存の不具合（プロダクションコードではなくテストの方）**: `repl_sender_direct_test.exs`の最初のテスト（`sh -c "pwd && echo ..."`の出力確認）が、20回に1〜2回の頻度で失敗することを`for`ループで確認した。原因はPortの`:data`メッセージがチャンク境界で分割されうること（`pwd`と`echo`という2つの別々のシェル組み込みコマンドの出力が、別々の`{:data, ...}`メッセージとして届くことがある）を考慮せず、最初の1メッセージだけを見ていたため。以前のセッションでこの同じテストファイルに単発の失敗が出た際「`assert_receive`のタイミング起因の一過性のもの」と評価していたが、それは誤りで、実際には再現するテストバグだった。`collect_until_exit/2`（`XT_EXIT`マーカーまでバッファに貯め続ける、`Repl.Session`と同じ様式）に書き換えて修正、20回連続green化を確認。

### 10.7 `lib/repl_*.exs`をディレクトリ構成に整理（2026-09-18）

`repl_`始まりのファイルが`lib/`直下に10個並んで読みにくくなったため（crux指摘）、`repl_`系だけをディレクトリへ切り出した。既存の`core.exs`/`scanner.exs`等の非`repl_`系ファイルは元の平たいレイアウトのまま変更していない。

```
lib/repl/
  launch.exs             (XipeTotec.Repl.Launch)
  sender.exs              (XipeTotec.Repl.Sender)
  sender_direct.exs        (XipeTotec.Repl.Sender.Direct)
  session.exs              (XipeTotec.Repl.Session)
  eval_template.exs        (XipeTotec.Repl.EvalTemplate)
  eval/
    scan.exs                (XipeTotec.Repl.Eval.Scan)
    field_drip.exs           (XipeTotec.Repl.Eval.FieldDrip)
    result.exs                (XipeTotec.Repl.Eval.Result)
    parser.exs                 (XipeTotec.Repl.Eval.Parser)
    scan/
      direct/
        iex.exs                    (XipeTotec.Repl.Eval.Scan.Direct.Iex)
      pty/
        (空。将来PTY対応のSenderができたときの置き場所)
    field_drip/
      elixir.exs               (XipeTotec.Repl.Eval.FieldDrip.Elixir)
```

`scan/`・`field_drip/`ディレクトリは、cruxの依頼により「対象(言語別/REPL別の具体実装)を置く場所」として先に用意した。`Code.require_file`の相互参照（`sender_direct.exs`→`sender.exs`、`parser.exs`→`scan.exs`/`result.exs`）とテスト側の`require`パスをすべて更新し、`git mv`で追跡済みファイルの履歴を保持。全体テスト(156)・実機テスト(7)とも再確認、green。

### 10.8 `FieldDrip.Elixir`実装 ── パイプライン全体、実機で初めて通しで確認（2026-09-18）

`lib/repl/eval/field_drip/elixir.exs`(`XipeTotec.Repl.Eval.FieldDrip.Elixir`)。`repr=`/`type=`/`display=`/`bin_base64=`のkey=value本文を、改行分割→`=`で最初の1回だけ分割、というだけの実装（この本文フォーマット自体がxipe_totec独自の固定規約なので、対象言語の構文から導出されるものではなく、実装は必然的にシンプルになる）。

**「scanのiex対象」について（この節の初出時点の判断。10.9節で改訂）**: `Scan.Direct`は既に実機`iex`で検証済み（10.4節）なので、新たに`Scan.Iex`のような別モジュールは作らず、`Scan.Direct`がそのままiex(および将来の他REPLでも、plain pipe経由である限り)向けの対象を兼ねる、という整理で進めた。

**`test/live/repl_iex_test.exs`に、パイプライン全体を通しで確認するテストを追加（8件に増加）**: `Repl.Launch`→`Sender.Direct`→`Session.await_ready`→`EvalTemplate.build`→`Direct.write`→**`Parser.step`(`Scan.Direct.<Iex>.clean`→`Scan.scan`→`FieldDrip.Elixir.parse`→`Result.success`)**という一連を、実機の`iex`に対して初めて通しで確認した。フェイク実装(`FakeFieldDrip`)ではなく実際のモジュール同士の組み合わせで、`Core.apply_results`が受け取れる本物の`Evaluator.Result`が生成されることを確認済み。全体テスト160・実機テスト8、green。

**既存実装（`lib/repl_launch.exs`/`lib/repl_sender.exs`/`lib/repl_sender_direct.exs`、2026-09-18作成）への影響**: `Repl.Launch`の`--sname`/`--cookie`/loopback関連（`target_node`/`self_node`/`cookie`の生成と返却、loopback argv/env）は本方針により不要になった。簡略化はまだ未実施（次のステップ）。メッセージ生成/送信の分離、`message["files"]`の扱いは本方針でも有効なまま流用できる。`Sender`の契約自体は上記10.1節の通り改訂済み、`Sender.Direct`も改訂済み。

### 10.9 `Scan.Direct`を`Scan.<transport>.<repl>`の2軸構成に改訂（2026-09-18）

10.8節で「scanはトランスポート軸(`Direct`)、`Launch`/`FieldDrip`は言語軸」という不一致にcruxが気付き、再検討した結果、**`Scan`もトランスポート軸と言語軸の両方を明示的にディレクトリで持たせる**ことに決定:

- `lib/repl/eval/scan/direct.exs`(`XipeTotec.Repl.Eval.Scan.Direct`) → `lib/repl/eval/scan/direct/iex.exs`(`XipeTotec.Repl.Eval.Scan.Direct.Iex`)
- `lib/repl/eval/scan/pty/`を空のプレースホルダとして新設（将来PTY対応のSenderができたときの置き場所）

判断根拠: `Scan`が取り除く雑音(PTYのエコーバック・ANSI)は経験的にはトランスポート軸(PTY/pipe)の性質だが、将来的に特定のREPL固有の出力の癖が見つかる可能性もゼロではなく、**トランスポート軸×言語軸の2次元は名前をどちらかに寄せても消えない**ため、両方を明示的にディレクトリ階層で表現する方が正確かつ`Launch`/`FieldDrip`との一貫性も取れる、という整理。`Code.require_file`・テストファイルの`alias`/require パス（`test/repl_eval_scan_direct_test.exs`→`test/repl_eval_scan_direct_iex_test.exs`に改名含む）をすべて更新、全体テスト(160)・実機テスト(8)とも再確認してgreen。

### 10.10 `heartbeat_input`実装、実機で生存確認込みで検証（2026-09-18）

`Repl.Launch.build/1`に`heartbeat_input`(既定間隔5秒、`:heartbeat_interval_ms`で上書き可)を追加。`ready_pattern`/`exit_input`と同じ算出データの枠に入る。生成されるコード片:

```elixir
xt_heartbeat_pid =
  spawn(fn ->
    xt_beat = fn xt_beat ->
      Process.sleep(<interval_ms>)
      IO.puts("XT_HEARTBEAT")
      xt_beat.(xt_beat)
    end

    xt_beat.(xt_beat)
  end)
```

セッション起動直後に一度だけ送り込む想定(評価リクエストとは別の、独立した常駐ループ)。**BEAMのプリエンプティブスケジューリングにより、重い同期的な計算をしている最中でも定期的に発火し続けることをローカル(elixir -e)・実機(iex)の両方で確認**: `:timer.sleep(1200)`相当の評価を待っている間、200ms間隔のハートビートが2回以上届くことを`test/live/repl_iex_test.exs`の新規テストで確認した(`Parser.step`の`:pending`分岐が返す`cleaned.heartbeats`を評価待ちの間ずっと積算する形に変更)。実機テスト9件(1件追加)、全体テスト160件、green。

**これで生存監視の3本柱(クラッシュ検知の`XT_EXIT`・ハング検知の`XT_HEARTBEAT`断絶・完了検知の`XT_END`/`XT_ERROR`)が全部実装・実機確認済みになった。** ただし「ハートビートが一定回数途切れたらハングとみなしてkillする」という判定ロジック自体(具体的な閾値・状態遷移)はまだ実装していない ── 今回作ったのは信号(マーカー)を出す/受け取る部分までで、それをどう解釈してセッションを再起動するかの判断はCLI/オーケストレーション層(次項)の仕事として残っている。

## 11. 実装レビュー→バグ修正→`xipe eval`まで(2026-09-18、cruxの「決め残しがあれば決めてしまいましょう」依頼を受けて)

前段落(§10.10まで)を実機で使う前提でコードレビューしたところ、実バグが複数見つかった。実装を進める前に直した。

### 11.1 レビューで見つかった実バグ4件、修正

1. **`eval_template.exs`のtimeout分岐が`Process.demonitor`していなかった**: `after`節で`Process.exit(pid, :kill)`する際、`spawn_monitor`の監視参照をdemonitor/flushせずに抜けていた。killで発生する`:DOWN`メッセージが誰にも受信されずセッションプロセスのメールボックスに残り続ける(タイムアウトを繰り返すセッションで蓄積する)。`after`節にも`Process.demonitor(ref, [:flush])`を追加。
2. **crash reasonの`inspect`にオプション漏れ**: `display=`等には`limit: :infinity, printable_limit: :infinity, width: :infinity`を付けていたが、crash時の`XT_ERROR_<id> crash <reason>`行の`inspect(xt_reason)`だけ素の`inspect/1`のままだった。巨大なreasonが省略/改行されるとマーカー行パーサーが壊れる。オプションを揃え、かつ改行を`\n`エスケープする(`xt_oneline`相当)処理も追加(4を参照)。
3. **`Repl.Eval.Result`が`repr`をatomに変換していた**: `repr_atom/1`で`"exact"`等をatom `:exact`等に変換していたが、`core.exs`の`resolve_ref/4`は`ref_call.repr in ["exact", "binary"]`と**文字列**で比較している。atom化されたrepr値は文字列比較と絶対に一致しないため、「plan外の参照が確定済みexact/binary値ならリテラル文字列として埋め込む」という経路が、実際のEvaluator結果に対しては一度も発火しない状態だった(`core_test.exs`の既存テストは手書きの文字列フィクスチャを使っていたため気づかれていなかった)。また§28 B2の「Coreに入る値はJSON化可能な型のみ」というルール自体にも反していた。atom変換をやめ、`eval_template`が印字した文字列をそのまま通すよう修正(`repr`/`compare`両方)。`bin`も同様の理由でbase64文字列のまま保持(decodeしない ── `Store.append`は全カラムを`JSON.encode!`するため、decode済みの生バイト列はJSON化できない)。
4. **`display=`が改行を含みうる値で行ベースパーサーを壊す可能性**: `width: :infinity`は"ソフトな"折り返しは防ぐが、独自`Inspect`実装が強制改行(`Inspect.Algebra.line/1`)を使う値には効かない。修正: (a) `repr=exact`の往復検査条件に`not String.contains?(xt_str, "\n")`を追加(改行を含む値はexactと判定しない)、(b) `unsupported`/`binary`分岐の`display=`は`xt_oneline`(改行を`\n`エスケープするヘルパ)を通す。
5. **(efficiency)** `Scan.Direct.Iex.strip_all/3`がハートビート1件ごとにバッファ全体を再スキャンしていた(O(件数×バッファ長))。`String.split/2`1回に書き換え。

全て`test/repl_eval_template_test.exs`/`test/repl_eval_result_test.exs`/`test/repl_eval_scan_direct_iex_test.exs`にテスト追加・実機(`test/live/repl_iex_test.exs`)で再確認。

### 11.2 `compare`判定の実装(§28 C、分散Erlang撤回後もこの部分は撤回されていない)

`core.exs`の`build_entry/3`が`Plan.Entry.basis`を計算する際、**当初`call.prev`(1つ前の値)を参照していたのは設計ミスだった**と実機テストで判明: `apply_result/3`は`prev: row[:result]`(結果を上書きする直前の行の値)をセットするため、`prev`は常に「今回のevalより2つ前」の値を指す。次のevalの比較対象にすべきは「直近の(今から上書きされる)値」=`call.result`/`call.repr`/`call.bin`である。修正し、`basis`は`{:exact, prev_text} | {:binary, prev_base64} | :none`(前回reprが`unsupported`なら`:none`扱い、§28 Cの「片側でもunsupportedならskipped」と整合)。

`EvalTemplate.build/1`が`entry.basis`に応じて対象ノード側で前回値を再構築するコードを生成: `exact`なら`Code.eval_string/1`、`binary`なら`Base.decode64!/1 |> :erlang.binary_to_term/1`。比較は項として再帰的に行い(map/list/tuple/struct対応)、floatのみ相対/絶対誤差を許容(`compare.float_rel_tol`/`float_abs_tol`、既定`1.0e-9`。**設定ファイル機構がこのプロジェクトに一切存在しないため**、今回は`EvalTemplate`のmodule属性に固定値として置いた ── §28 Cが求めた「設定パラメータ化」の完全な実現ではなく、意図的なスコープ縮小として明記)。結果は`compare=<none|skipped|changed|unchanged>`として`display=`と同じマーカー本文に追加で印字され、`FieldDrip`は元々汎用parseなので変更不要、`Result.success/3`がそのまま`compare`フィールドへ渡す。実機で`unchanged`→`changed`の遷移を確認済み。

### 11.3 `:max_heap`と通常crashの区別

`eval_template`が`Process.flag(:max_heap_size, ...)`超過による強制killを検知できるようにした: その特定pidに対して`:killed`理由の`:DOWN`を送りうるのは(タイムアウト時の`Process.exit(pid,:kill)`とは別のreceive節なので競合しない)このmax_heapフラグ以外に無いため、`xt_reason == :killed`で`XT_ERROR_<id> max_heap`を印字するよう分岐。`Repl.Eval.Result.error/3`に`"max_heap"`節を追加、`Core.apply_result/3`の既存`:max_heap`節にそのまま流れる。実機で`Enum.to_list(1..2_000_000)`を`max_heap_words: 1000`で評価し確認、セッション自体は生存続行することも確認。

### 11.4 `Repl.Evaluator`新設 ── `Parser`出力→`Core.apply_results`→`Store`の配線、ハング判定

`lib/repl/evaluator.exs`(`XipeTotec.Repl.Evaluator`)、`run_pass/3`: `Core.plan_recalc/3`と同じ`opts`(`:call_ids`/`:changed_node_ids`/`:include_writes`)を受け、1セッションを起動してPlanの全entryを順に流し込み、`Core.apply_results/3`まで畳み込んで`{:ok, new_book, results}`を返す(`xipe scan`/`xipe show`と同じ同期一発の形、Old.md自身が予告していた通り)。`:cwd`必須、`:ctx`(git情報、既定nilの3つ組)、`:launch_opts`(`Repl.Launch.build/1`への追加opts)、`:sender`(既定`Sender.Direct`)、`:boot_timeout_ms`/`:hang_grace_ms`を受け付ける（`:heartbeat_interval_ms`は§23でハートビート機構ごと撤去され、代わりに`:interrupt_grace_ms`が増えている）。

ハング判定: 各entryの`eval_template`自体は`entry.limits.timeout`以内に必ず何らかのマーカーで自己終端するが、**セッションそのもの**が完全に固まる(スケジューリングが止まりハートビートすら印字されない)場合はこの安全装置の外側になる。`entry.limits.timeout + 3 * heartbeat_interval_ms`の間、`:data`が一切(ハートビートも含め)届かなければハングと判定し、`sender.kill/1`でセッションを強制終了、そのentryは`{:error, "session_hung"}`、残りのentryは全て`:aborted`(`apply_result/3`の既存の`:aborted`節は本の上ではno-op ── §28 Dの「ノードダウン検知→残りentryを一括abortedに」という発想を、分散ノード前提撤回後の「セッションハング」に転用した形)。ハング後は`Session.close/4`を呼ばない(既にkill済みのhandleに対して再度`write/2`すると、実`Sender.Direct`は`{:exit_status,...}`受信後に自らGenServerを`{:stop,:normal,...}`するため、タイミング次第で`:noproc`になりうる ── `run_entries/5`が`{:ok,results}|{:hung,results}`のタグを返し、`:ok`の時だけ通常のgraceful closeを行うよう分離)。

テスト: `test/repl_evaluator_test.exs`(4件、実iex不要 ── `write/2`が`XT_BEGIN_<id>`を検知して即座に結果を返す/何も返さないフェイクSenderで、配線とハング経路を高速に検証)。実機smoke(未committed scratch script、`test/live/`には未追加)で2entryのplan(片方が他方を`⟦id⟧`参照)を実`iex`に通し、`apply_results`が正しく畳み込まれることも確認。

### 11.5 `Project.find_sheets/1`が`.exs`も拾うよう拡張

`xipe eval`のscripts-mode(`project_kind: scripts`、crux自身の実プロジェクトが該当)ではREPLへロードすべきファイル一覧に`find_sheets/1`の結果をそのまま使う設計だが、旧実装は`.ex`のみを対象にしていた ── cruxの実プロジェクトは`.exs`のみで`.ex`が一つも無い構成のため、このままでは`xipe eval`が常に空のfilesリストになり機能しない。`.ex`除外は元々「安全のため」ではなく(fix Fにより`.exs`のスキャン自体は元から安全)「entry-pointスクリプトと図書館コードの判別」目的だったため、`Path.wildcard`のパターンを`*.{ex,exs}`に拡張。`scan_dir/2`側の挙動(インデックス対象が増える)も含めて意図した変更。テスト追加、既存テスト(全て`.ex`のみのフィクスチャ)は無傷。

### 11.6 `xipe eval` CLIコマンド

`main.exs`に追加。`xipe eval [<dir>] [id...] [--mix]` ── `<dir>`省略時`.`、id省略時は本の全call、`--mix`で`iex -S mix`起動(既定はscripts-mode、`argv: ["iex"], files: Project.find_sheets(dir)`)。`git rev-parse HEAD`/`git show -s --format=%cI HEAD`/`git status --porcelain`から`ctx`(`commit`/`commit_at`/`dirty`)を組み立て(gitが無い/リポジトリでない場合は全て`nil`、失敗しても評価自体は続行)。結果は`Store.persist_diff/4`(6テーブル全部)で永続化し、call毎に1行(`repr`/`compare`/表示値、またはtimeout/max_heap/crash/skipped/lost/aborted)を出力。`xipe`実機で`.exs`のみのscripts-modeプロジェクトを対象に`scan`→`eval`→再`eval`(`compare=unchanged`確認)→git初期化後の再`eval`(commit/commit_at/dirty反映確認)まで一通り確認済み。§16サーバー側の`eval/run`(非同期・pass_id・`notify/rowChanged`配信)は意図的に未着手のまま(`Dispatch`の`@not_implemented`は変更していない) ── Old.md自身が「CLIは薄く先に作れる」としていた通り、こちらは別スコープ。

## 12. コマンドリスト基盤: `Runner`新設(2026-09-18、cruxの提案「入力→コマンドリスト→動作」)

cruxの発案: CLIから追加の操作(`row/add`等)を使えるようにするにあたり、「CLIの引数を直接動作に変換する」のではなく「入力→コマンドリスト→動作」の3段に分け、将来の外部連携(crux案: 将来のtezcatl連携、現時点では具体的な接続方法は未設計)からも同じ「動作」層を使い回せる形にすべきだという提案があった。

**気づき**: この「動作」層は実は既に半分存在していた ── `Dispatch.handle(book, method, params, ctx)`がまさにそれで、§16 WSサーバーは既にこの形(wireメッセージ→Dispatch)になっている。ただしCLIの`scan`/`eval`(§11.6)は`Dispatch`を経由せず`Project.scan_dir`等を直接叩いており、WS側と処理が重複していた。

**設計**: `lib/runner.exs`(`XipeTotec.Runner`)を新設。

- **コマンドリスト**: `[%{"method"=>, "params"=>}, ...]`という、§16.3の実際のwireメッセージと同じ形(JSON化可能)。CLIはこれを組み立てる「入力」側の一つに過ぎない ── 将来別の入力(crux想定のtezcatl連携など)が同じ形のリストを直接渡せる。
- **`Runner.run/4`(「動作」側)**: コマンドを順に実行し、bookを畳み込む。メソッド名で2種類に振り分け: `Dispatch`が知っている全メソッド(`row/add`/`effect/set`/`scan/run`/`cell/resolve`/`graph/*`等)はそのまま`Dispatch.handle/4`へ、**`"eval"`という新しい疑似メソッド**(`Dispatch`のメソッドには**しない** ── REPLのライブI/O・タイミングを伴うため、`Dispatch`の同期的Book→Book契約に元々乗らない設計。これが§16の非同期`"eval/run"`を`Dispatch`側で意図的に未実装のまま止めてある理由でもある。名前を意図的に別にした ── 将来`eval/run`ができても両者の意味論(同期一発 vs 非同期ストリーミング)が違うので、同じ名前の異体と誤解されないようにするため)は`Repl.Evaluator.run_pass/3`へ。
- **コマンド間参照**: `"$<index>.<path>"`という文字列(例: `"$0.id"`)を、実行**時**に前のコマンドの結果から解決する(コマンドリスト自体は未解決のまま「ただのデータ」であり続ける、という分離を保つため)。「行を追加→そのeffectを設定→評価」のような、追加されたidが実行前には分からない一連の操作を1回のコマンドリストで表現できる。
- **launch_opts自動判定**(実装中に見つけた実バグの修正): `"eval"`コマンドで`:launch_opts`を指定しなかった場合、`Runner`が`<root>/mix.exs`の有無を見てscripts-mode/mix-modeを自動選択する(`Project.find_sheets/1`で対象ファイルを集める)。元々この判定は`eval`専用CLIコマンドの中にしかなく、汎用の`xipe do eval ...`経由だと`mix.exs`の無いディレクトリで`iex -S mix`を起動しようとして即座に失敗する実バグがあった。

**副産物で見つかったバグ**: 上記の即時起動失敗時、`Evaluator`が(既に死んでいる)Senderハンドルに対して`kill/1`を呼び、`GenServer.call`が生の`:noproc`で例外を投げてクラッシュしていた。`Sender.Direct.write/2`/`kill/1`を修正 ── `write/2`は`{:error, :noproc}`を返し、`kill/1`は`:ok`を返す(既に死んでいる対象を殺そうとするのは「目的は既に達成されている」ので成功扱いにするのが`Sender`の契約上自然)。

`main.exs`に`xipe do [--dir <dir>] <method> [key=value...] [-- <method> [key=value...]]...`を追加(`--`区切りで複数コマンドを1回のCLI呼び出しに連結)。既存の`xipe scan`/`xipe eval`もこの基盤(`Runner.run/4`、1コマンドのリスト)に乗せ直した。`xipe show`/`xipe serve`はBook操作でも一発評価でもないため変更していない。

テスト: `test/runner_test.exs`(8件、実iex不要)、`test/repl_sender_direct_test.exs`に`:noproc`回帰テスト追加。実機で`xipe do row/add ... -- effect/set ... -- eval call_ids=$0.id`の3コマンド連結を確認済み(`.exs`のみのscripts-modeプロジェクトに対して)。全体テスト177件(fast)+11件(live)、green。

## 13. `Repl.Evaluator`のElixir決め打ちを解消(2026-09-18、cruxのレビュー指摘)

tezcatl連携の相談の中で、`Runner`の`"eval"`コマンド自体は言語非依存な入力(`call_ids`のみ)になっているにも関わらず、`Repl.Evaluator`内部は`Launch`/`EvalTemplate`/`Scan.Direct.Iex`/`FieldDrip.Elixir`(全てElixir実装)を`alias`で決め打ちしていた点をcruxが指摘。`Repl.Eval.Parser.step/5`が既に確立していた「呼び出し元が具体的なモジュールを渡す、内部で言語判定しない」というrepl-adapter-guide.md自身の流儀に倣って書き換えた。

`Evaluator.run_pass/3`に`:launch_module`/`:eval_template_module`/`:scan_module`/`:field_drip_module`の4オプションを追加(全てElixir実装がデフォルト、既存呼び出し元は無改修)。4つをまとめた`adapter`マップとして`run_plan`/`run_entries`/`wait_result`に一貫して通す形にした。

**注意点として明記**: これは「言語ごとの振り分けロジック」を作ったわけではない ── 振り分ける先(2つ目以降の言語アダプタ)がまだ存在しないため、振り分け自体は依然未設計・未着手のまま。今回やったのはあくまで「ハードコードを外して差し替え可能にした」だけで、「どのノードがどの言語のプロジェクトに属するか見て自動選択する」機構は将来の課題として残っている。

テスト: `test/repl_evaluator_test.exs`に、Elixirの実装を一切参照しない架空の「トイ言語」(`ToyLanguage.{Launch,EvalTemplate,Scan,FieldDrip,Sender}`)で`run_pass/3`を実際に完走させるテストを追加 ── 4つのオプションが本当に差し替え可能であることをデフォルト値のまま偶然通っているのではなく機械的に証明。全体テスト182件(fast)+11件(live)、green(既知の無関係なフレーク除く)。

## 14. 外部レビュー5件への対応(2026-09-18)

cruxが§11〜13の実装をレビューに出した結果、5件の指摘を受けた。全て実バグ/実ギャップと認めて対応した。

### 14.1 scripts-modeでエントリースクリプトが実行される(Fix Fとの矛盾)

指摘: §11.5で`find_sheets/1`が`.exs`も拾うようになったが、scripts-modeの`files`はその結果をそのまま`-r`に渡す。`-r`は本物の`Code.require_file`で、`Scanner`のFix F(defmoduleフォームだけコンパイル)と違いファイル全体を実行する。`main.exs`のようなエントリースクリプトを持つプロジェクトで`xipe eval`すると、REPL起動の副作用としてそのスクリプトのトップレベル(サーバー起動等)が丸ごと実行されてしまう。

対応: `lib/repl/source_sanitize.exs`(`XipeTotec.Repl.SourceSanitize`)を新設。`Scanner.only_defmodules/1`を公開関数に変更して再利用し、各ファイルをdefmodule部分のみの一時コピーに変換してから`-r`する。`Runner.default_launch_opts/1`(→`launch_opts_for/2`に改名)がこの一時ディレクトリを生成し、`Evaluator.run_pass/3`終了後(成否問わず)に必ず削除する。呼び出し元が`:launch_opts`を明示的に渡した場合はこの機構を経由しない(呼び出し元の責任)。テスト: `test/repl_source_sanitize_test.exs`(3件、トップレベル副作用が実行されないことを実際に確認)+`test/runner_test.exs`の配線テスト。

### 14.2 構文が閉じていない引数での無限待ち

指摘: ハング判定は「ハートビートも含め何も届かない時間」ベース。しかし`[1, 2`のような閉じていない式を送ると、iexは入力の続き待ち状態(`...(N)>`)になり、以降送った文字列(残りのテンプレート・次entryのテンプレート全体)が同じ壊れた式に吸い込まれる。ハートビートは別プロセスなので届き続け、`after`も発火しないため、待ちが実質無限になる。

対応: 2段構え。①`Evaluator.wait_result/6`の判定を「受信のたびリセットされる沈黙時間」から「entry開始時に1回だけ固定する絶対デッドライン」に変更 ── ハートビートが届き続けても`grace_ms`(既定20秒 = `entry.limits.timeout`の既定5秒 + `3 × heartbeat_interval_ms`の既定5秒×3。**「既定20秒」はデッドライン全体の値**であって`timeout`への上乗せ分ではない、動作原理.md §5の「`timeout` + 3×heartbeat、既定20秒」という書き方と同じ意味。外部レビュー2026-09-22でこの一文だけでは曖昧という指摘があったため明記)で必ず打ち切られる。②`EvalTemplate.build/1`の入口で`Code.string_to_quoted/1`により呼び出し式を検証し、失敗したら対象言語へ一切送らず、xipe_totec自身の側で組み立てた診断メッセージだけを印字する最小テンプレート(`build_syntax_error/3`)を返す ── 実機確認では20秒待たずに299msで即座にエラー化され、後続entryも正常に評価された。テスト: `test/live/repl_iex_test.exs`に実機テスト追加(セッションが継続入力待ちにならないことを確認)。

**追記（2026-09-22、§23）**: ここで説明している「ハートビートを含めた沈黙時間ベースの判定を絶対デッドラインへ変更」という設計自体は変わっていないが、ハートビート機構そのものが§23で撤去された。デフォルトのデッドライン計算式は`entry.limits.timeout + 3 × heartbeat_interval_ms`（既定20秒）から`entry.limits.timeout + @default_deadline_padding_ms`（既定7秒、`lib/repl/evaluator.exs`）に変わっている。`hang_grace_ms`オプション自体の役割（デッドライン全体の値を上書きする）は変わっていない。

### 14.3 ハートビートが結果ブロックの途中に割り込む可能性

指摘: `XT_BEGIN`〜`XT_END`の本文を複数回の`IO.puts`で印字していたため、その間に別プロセス(Logger、評価対象コード自身が起こす非同期出力等)の出力が割り込み、`key=value`形式でない行が紛れ込んで`FieldDrip.Elixir.parse/1`を壊しうる。ハートビート自体は`clean/1`がどこにあっても除去するので無害だが、それ以外の出力は防げない。

対応: `EvalTemplate.build/1`の3分岐(unsupported/exact/binary)全てで、本文の全行を`Enum.join(..., "\n")`で1本の文字列に組み立ててから`IO.puts/1`を1回だけ呼ぶ形に変更。BEAMのgroup leader経由のI/Oは1回の呼び出し単位でアトミックなので、他プロセスの出力がブロックの途中に挟まる余地が無くなる。実機テスト(全12件)で出力形式が変わっていないことを確認済み。

### 14.4 仕様との食い違い(compareの値・basisの参照元)

指摘: ①§11.2で印字している値が`unchanged`だが仕様(§4.6/§6.4)は`same`。②仕様§6.4は「比較の基準Bは、前回列(P)の出どころがuserならB=P、そうでなければB=R_old(評価直前の結果)」だが、実装は常にR_old相当(`call.result`)しか見ておらず、`prev_source=="user"`(`Core.set_prev/3`で利用者が期待値を書いた場合)の経路が実装されていない。`row/update --prev`が未実装なので今は顕在化しないが、コードは既に`set_prev/3`を持っている。

対応: ①`"unchanged"`を`"same"`へ全面改名(`eval_template.exs`/`result.exs`/テスト)。②`Core.build_entry/3`のbasis計算に`call.prev_source == "user"`を最優先でチェックする分岐を追加、`call.prev`を`{:exact, ...}`として使う。`Core.set_prev/3`は既に実装・テスト済みだったため、この分岐追加だけで仕様§6.4のB決定ルールを完全に満たす。テスト: `core_test.exs`に`plan_recalc/3`のbasis専用describeブロックを新設(6件、user優先・auto・unsupportedの各ケース)。

### 14.5 `repl-adapter-guide.md`の陳腐化

指摘: 「会話を知らない読者」を想定した文書なのに、§11以降の変更に追いついていない4箇所(compare未実装という誤記、`XT_ERROR max_heap`マーカーの欠落、`compare=`フィールドの欠落、`evaluator.exs`がディレクトリ構成に無い)。

対応: 全4箇所を更新。加えて、今回見つけたeval_template側の2つの新しい設計原則(「本文は1回のIO.puts/write で出す」「呼び出し式を送る前に構文検査する」)を「変えてはいけないもの」/「eval_template作成に必要な知識」の項目として明文化し、新規言語アダプタが同じ2つのバグを再発させないようにした。`source_sanitize.exs`(Elixir固有、4モジュール契約の外)の位置づけも注記した。

全体テスト194件(fast)+12件(live)、green(既知の無関係なserve_project_test.exsフレークのみ)。

## 15. コマンドパイプライン基盤: `Pipeline`新設(2026-09-18、cruxとの co-design)

cruxの提案:「コマンド入力→参照ファイル→実際の動作」という3段の抽象化。`eval/run`と`row/update`は根本的に同じ処理(Evaluatorでパスを1回走らせる)を経由するはずで、どのmethodがどの処理に対応するかを**コードに直書きせず宣言的な参照ファイルにする**ことで、CLIの`Runner`とサーバーの`Serve.Project`が同じ参照ファイルを読む「2つの入力口」になる、という設計。今日の範囲は明示的に配線のみ(段階の中身は空のまま、明日以降1つずつ実装)。

**新設**: `lib/pipeline.exs`(`XipeTotec.Pipeline`)。

- **参照ファイル**: `pipelines.json`(xipe_totecチェックアウト直下、`__DIR__`相対で読む ── `book.jsonl`のようなCWD相対ではない。理由: `xipe serve`はtezcatlの`XipeConn`から`cd: installDir`で起動されるなど、CWDが対象プロジェクトのルートや任意の場所になりうるため)。中身:
  ```json
  {"eval/run": ["eval"], "row/update": ["edit", "eval"]}
  ```
  `row/update`が「編集(edit)→評価(eval)」の2段合成になっている点が「根本は同じ」という発想の核心 ── `eval`段が本物の実装を持てば、`row/update`はそれを再利用するだけで再計算の半分がほぼタダで手に入る。
- **なぜ`Dispatch`の中ではなく外か**: `eval/run`/`row/update`は生きたREPL評価(I/O、数秒かかりうる)を伴う。`Dispatch.handle/4`は意図的に純粋(scan/runのファイル読み込み以外I/Oなし)、`Serve.Project`の`GenServer.call`も同期処理なので、ここに評価パスを直接組み込むとプロジェクト全体のリクエスト処理が評価中ずっと塞がる(§28 Eが元々指摘していた点で、分散Erlang撤回後も撤回されていない)。そのため`Pipeline`の呼び出しは`Dispatch`の**外**(`Runner.run_one/4`と`Serve.Project.handle_call/3`、両方とも`Dispatch`に落ちる前に`Pipeline.handles?/1`でチェック)に置いた。`Dispatch`自身の`@not_implemented`リストにある`eval/run`/`row/update`はそのまま(`Pipeline`を経由しない呼び出し元への保険として)残してある。
- **段階の実行**: `run/5`が登録済みの段階を順に実行し、最初にエラーを返した段階で打ち切る(Bookは前段の結果を次段へ引き継ぐ)。テスト用に段階ハンドラの表を差し替え可能(`test/pipeline_test.exs`で偽の成功ハンドラを注入し、複数段階が正しく連結・伝播することを実際に証明 ── 今日の本番の段階は両方ともスタブなので、これが無いと逐次実行ロジック自体は未検証のままだった)。
- **今日の段階の中身は両方スタブ**: `"edit"`/`"eval"`とも`not_implemented`エラーを返すだけ。ユーザーから見た挙動は今日時点では変化なし(元々`Dispatch`の`@not_implemented`で同じエラーだったため) ── 純粋な配線替え。

テスト: `test/pipeline_test.exs`(9件)+`test/runner_test.exs`/`test/serve_project_test.exs`にそれぞれ1件(CLIとWS両方が同じ`pipelines.json`を経由することを確認)。全体テスト204件(fast)+12件(live)、green(既知の無関係なフレークのみ)。

**明日以降**: `"edit"`段(`Core.edit_args`/`set_prev`)、`"eval"`段(`Repl.Evaluator.run_pass/3`を非同期プロセスとして再利用する形、§28 Eの設計を参照)を1つずつ実装していく。

## 16. 計算行の表現範囲の確認・writesチェーンのギャップ・依存チェーン交渉機能の設計（2026-09-19）

`~/my_app/tezcatl`セッションでの co-design。cruxから「一般的なREPLの使い方の主要なものをカバーできているか」という確認を受け、実装(`EvalTemplate.call_expression/1`)とspec §1.1/§4.3を突き合わせて計算行の表現範囲を確認し、そこから見つかったギャップの1つ（明示的な副作用呼び出し）を掘り下げる過程で、新しい機能（依存チェーンの対話的交渉）の設計に至った。バグ2件も同セッションで修正済み。

### 16.1 計算行が表現できる範囲（確認、実装変更なし）

計算行は常に`Module.function(arg0, arg1, ...)`という1関数呼び出しの形一つ（`EvalTemplate.call_expression/1`）。パイプ演算子・複数文・マクロ呼び出しは spec §1.1 の非目標に明記されており、多段処理をしたい場合は複数の計算行を`⟦id⟧`参照で繋ぐのが想定パターン（新しい計算行の形を作らない）。一方、個々の引数スロット自体は対象言語の自由な式テキストを許容する（spec §4.3の例: `elem(⟦c_01H9A0…⟧, 1)`）── `Core`は`⟦id⟧`トークンの文字列置換しかしないため、表現力の大部分は「呼び出しの形」ではなく「引数スロットの中身」に宿っている。

**見つかったギャップ2点**:
1. `Scanner.extract_def_clauses/2`（`lib/scanner.exs:233`）は`kind in [:def, :defp]`を無差別にnode化しており、`defp`由来の計算行はElixirの可視性ルール上REPLから呼べず必ずcrashする。未修正（優先度低として記録のみ）。
2. **ライブラリ/標準ライブラリの関数（例: Nx/EXLAの行列演算）は計算行にできない** ── `row/add`の`node`は`:nodes`に実在するidが必要（`dispatch.exs:66-71`）で、`Scanner`は対象プロジェクト自身のソースしかスキャンしないため。唯一の道は対象プロジェクト側に薄いラッパー関数を書くこと（crux確認: 「固有のものをそれぞれ用意することになる」）。P3（自然キー・スキャン済みソース前提）と整合する意図的な境界と判断し、修正不要。spec §1.1の非目標リストに一文足す価値はあるが未実施。

### 16.2 明示的な副作用呼び出しがCLIから実行不能だった（バグ、修正済み）

`Core.filter_by_effect`/`plan_recalc`/`Evaluator.run_pass`は`:include_writes`を最後まで配線済み（`core.exs:221-233`、`evaluator.exs:157`）だったが、**`Runner.run_one/4`の`"eval"`節が`params`から読むのは`"call_ids"`だけ**（`runner.exs:93`、修正前）で、`main.exs`の`xipe eval`にも対応フラグが無く、CLIのどこからも`include_writes`を渡す経路が無かった。なお`filter_by_effect`は`include_writes`の有無に関わらず`node.effect_source == "user"`を要求するため、writes計算行を評価するには`effect/set`で明示指定してあることが前提（既存実装済み）。

**この節では未修正のまま**（`document`反映のみ先行、実装は§16.4のコマンドリスト整備の一部として着手予定）。

### 16.3 入れ子のwritesチェーンは`affected_set`が上流を辿らない

`resolve_ref/4`（`core.exs:416`）は、参照先が`unsupported`かつ`pure`なら`:inline_call`で呼び出し式ごと再帰的に埋め込む（`in_plan_set`に入っているか無関係、occurs-check付きで深さに関係なく自動解決）。しかし参照先が`unsupported`かつ非pure（writes/unknown）だと`:binding`にフォールバックし、これは参照先が**同じplanに既にスケジュール済み**（`in_plan_set`）であることが前提。`plan_recalc`の`affected_set(book, targets, changed_nodes)`（`core.exs:187-198`）は明示ターゲットから**下流**（そのcallを参照している側）へのBFSのみを行い、**上流**（そのcallが参照している側）は一切辿らない。したがって、pureな依存チェーンは深さに関係なく自動解決されるが、**writesの依存チェーンはチェーン中の全idを手動で`call_ids`へ列挙しないと動かない**。

**検討したが不要と判断したもの**: `result`/`repr`を評価せず直接書き込む`stub_result`のようなCore新規関数。`resolve_ref/4`の「既にexact/binaryな値がある参照はそのままリテラル埋め込み」分岐（`core.exs:426`）が、`Store.load`で毎回Bookを読み直す設計と組み合わさることで、**既に無料で同じ効果を持つ**と判明（crux指摘）: 依存を1回だけ実際に評価して確定させ（本実装でなくても最小限のダミー関数でよい）、以降は`call_ids`にそれを含めず上位だけを評価すれば、キャッシュされたexact/binary値がそのまま埋め込まれる。効かないのは(a)呼べる関数が実在しない、(b)戻り値が`unsupported`（セッション変数束縛が要る）の2ケースのみで、いずれも稀として対応を見送り。

### 16.4 対話的な依存チェーン交渉機能（設計のみ、crux発案）

**動機**: `w1(w2(w3(...)))`のような入れ子チェーンを試したいが、深いところ（例: w3）は未実装/実行したくない場合、どこまで実際に評価するかを対話的に決めたい。

**確定した対話フロー**: `eval main.exs def~ -depend`（CLI構文は未確定）で対象の上流依存チェーンを深い方から浅い方へ展開し、`point:w3`のように現在位置を示しながら「Xに値を入れて評価しますか？(y/n)」と問う。`y`ならその値を使い、その段から対象まで全部を実評価して交渉終了。`n`ならその段を切り捨てて1段浅い方へ移り、同じ質問を繰り返す（チェーンを使い切ったら何もしない）。これにより従来別々に検討していた3点（依存チェーン取得・仮値注入・writes opt-in）が1つの交渉に統合される。

**表示規約**: `⟦id⟧`の生の並びは可読性が落ちるため、各段の頭に`;; wN info`という省略コメントを付ける。`info`の中身はカード/テーブル表示側の統一的な短縮表記を流用する想定（具体的なフィールドは未確定）。

**別の単純なユーティリティ**: 依存チェーンをそのまま取得するだけのコマンドも別途用意する価値はある（対話を介さない用途向け）。出力先は素のOSクリップボード（tezcatlのkillringは既にクリップボードを自動取得しているため、tezcatl固有の配線は不要、とcrux確認）。

**アーキテクチャ上の要点（cruxの訂正を経て確定）**: 当初、この対話をtezcatlの`/pty`+`PtyFlow`（`pty_socket.exs`の`{"kind":"start","cmd":...,"cwd":...}`、任意コマンドをPTY越しに中継する既存の汎用機構）に乗せる案を検討したが、cruxが明確に却下: PTYは生の非構造化バイト列を持ち込み、REPL接続で既に未解決と分かっているエコーバック/ANSIノイズ問題（§10.1）を再導入してしまう。代わりに、対話の「大本」を**構造化された（PTYを介さない）I/Oコア**とし、その上に2つのモードを持たせる:

- **対話モード**: 人間がCLIで直接読み書きする、行ベースの人間可読テキスト（PTY無し、REPL評価の`XT_BEGIN`/`XT_END`マーカープロトコルが`Sender.Direct`の素のpipeで既に実現している「構造化されているが端末でも読める」パターンと同型）
- **アダプタモード**: `/xipe`のWS等、人間を介さない側が読み書きする構造化JSON

これは既存の3つの実行経路（`Dispatch`=純粋、`Pipeline`=I/Oあり単発、`Evaluator`=I/Oあり1pass使い切り）のどれにも当てはまらない、**第4の層＝複数ターンにまたがる状態を持つ構造化対話コア**として位置づける。状態（今どの段の回答待ちか）は`Serve.Socket`側（`initialized?`と同じ、接続ローカルの理由）が持ち、tezcatl側は何も記憶せず「今の状態」を毎回そのまま表示するだけでよい（`dialogue-output-panel.js`の`renderProofGeneralOutput`が同じ設計で実証済み、`~/dev/emacs-vent/`の対話ブリッジ前例を参照して確認）。

**cruxの規模感の指摘（重要）**: コマンドリスト（`Runner`の`$<index>.<path>`参照＋`row/add`/`eval`の組み合わせ）が先に整っていれば、対話コア自体は「極めて薄い」形で済むはず。対話コアが持つ状態は`{候補チェーン, 現在位置}`だけ、操作は`answer(:yes, value)`（現在位置から対象まで全部を`Runner`が食える形のコマンドリストとして確定し、そのまま`Runner.run/4`に渡して交渉終了）と`answer(:no)`（1段登って次の質問を再構成）の2つだけで足りる。`Dispatch`/`Pipeline`/`Evaluator`/`Runner`本体はほぼ無改造で済む見込み。

**合意した着手順序（2026-09-19、未着手）**:
1. §16.5のバグ2件を修正（完了、下記参照）
2. コマンドリスト整備: `include_writes`を`Runner`/`main.exs`のCLIまで配線、上流`⟦id⟧`依存を再帰的に辿る新しい`Core`関数を追加し新規`Dispatch`メソッドとして公開（`GraphQuery.graph/neighbors`とは別物 ── あちらは`:links`の静的呼び出しグラフ、こちらは`Core.reference_graph`の計算行依存グラフ）
3. 第4層（構造化・2モードの対話I/O基盤）を汎用インフラとして先に固める（crux: 依存チェーン交渉がその唯一の利用先になったとしても、固めておいて損はない）── **内部構造は§17で決定済み、実装は未着手**
4. w1(w2(w3()))の依存チェーン交渉機能を、(3)の上に乗る具体的な1インスタンスとして実装

### 16.5 バグ2件、修正済み（2026-09-19）

コードレビュー（§11以降と同様のレビュー観点）で見つかった2件、いずれも実装ミスで、Core側の変更は不要な配線バグ:

1. **`Runner`の`"eval"`が`call_ids`省略時に何も評価しない**: `runner.exs`の`"eval"`節は`Map.get(params, "call_ids", [])`が空なら`Core.plan_recalc`が「対象なし」と解釈し評価が0件になっていた。専用の`xipe eval`コマンド（引数省略時は本の全call）と挙動が食い違っていた。修正: `call_ids`が空なら`Map.keys(book.calls)`にフォールバック。`test/runner_test.exs`に回帰テスト追加（`call_ids`省略で本の全call（2件）が評価されることを確認）。
2. **`xipe do ... -- eval`がgitコンテキストを落とす**: `main.exs`の`do_cmd/1`が`git_ctx(dir)`を呼ばず`run_commands/3`に渡していなかったため、`xipe do row/add ... -- eval ...`経由で評価した結果は`commit`/`commit_at`/`dirty`が常に`nil`になっていた（専用の`xipe eval`コマンドなら記録される）。修正: `do_cmd/1`も`eval/1`と同じく`git_ctx(dir)`を`run_commands`へ渡すよう変更。実機で確認済み（gitリポジトリ内で`xipe do row/add ... -- effect/set ... -- eval call_ids=$0.id`を実行し、`book.jsonl`のcall行に実際のcommit sha/commit_at/dirtyが記録されることを確認）。CLI層のテストハーネスが元々存在しない（main.exsは読み込み時に`main/1`を即実行するため`Code.require_file`でのユニットテストが困難）ため、自動テストは追加せず実機確認のみ。

全体テスト（`./test/run.sh`）green（既知の無関係な`serve_project_test.exs`フレークのみ）。両修正とも未コミット。

## 17. 第4層（構造化対話I/Oコア）の内部構造 ── 決定（2026-09-20、`~/my_app/tezcatl`セッションでのco-design、§16.4着手順序ステップ3の内容確定）

**動機**: §16.4で「第4層＝複数ターンにまたがる状態を持つ構造化対話コア」という位置づけまでは決まっていたが、その中身（状態の実際の形、対話とコマンド実行の関係）は未確定だった。ここではその中身を決定した。設計のみで実装は未着手。

**エントリは2種類（決定）**: 第4層が扱う対話ログは、`:in`（人間/アダプタからのコマンド入力）と`:out`（xipe_totecが生成するテキスト）の交互列として表現する。

- REPL評価は既にマーカー越しにパース済みの構造化値（`Repl.Eval.Result`）としてxipe_totecに入ってくる（§10.1〜§10.9）。そのためREPL評価結果の表示値も、交渉中の質問文（`;; wN info`等、対話プログラム自身が組み立てる文）も、この層に届く時点では両方とも「xipe_totecが人間向けに整形したテキスト」という同じ形をしている ── 出どころ（`Repl.Eval.Result`か対話プログラム自身か）が違うだけなので、エントリの種別としては区別しない。
- これにより対話モード（行ベース人間可読テキスト）はこの列をそのままテキスト表示するだけ、アダプタモード（構造化JSON）は同じ列を`{kind: :in | :out, ...}`のJSONとして包むだけになる。当初検討していた「確定した結果を運ぶための専用チャンネル」は不要 ── 交渉終了時の確定メッセージ（例:「以上の内容で評価を行います」）も、そのあとに続く実評価結果も、通常の`:out`エントリがログに積み重なっていくだけで表現できる。

**各多段対話は「対話プログラム」モジュールに委譲（決定）**: 依存チェーン交渉のような個々の多段対話は、それぞれ専用のプログラムモジュールが持つ。汎用コア（第4層本体）はチェーンの深さ等、対話プログラム固有の意味を一切知らない。対話プログラムは`:in`を受けるたびに、次に出す`:out`テキストと、下記の2ビットのメッセージ種別を返す。

**メッセージ種別は2ビット、4通り（決定）**: 当初「残り対話ターン数のカウンタ（int）」を検討したが、実際に必要だったのは独立な2つの二値情報（状態保持の要否、REPLを介するかどうか）だったと判明し、Booleanのペアに整理した。

| bit1: 保持要否 | bit2: 行き先 | コード | 意味 | 例 |
|---|---|---|---|---|
| 保持する | xipe_totec内で完結 | `11` | 対話継続、今回の応答はREPLを介さない | 交渉の次の質問文を出す |
| 保持する | REPLへ | `10` | 対話継続、今回はREPL問い合わせを伴うが対話自体は続く | 交渉中に表示用の値をREPLへ都度確認しに行く、等 |
| 保持不要 | xipe_totec内で完結 | `01` | 単発完結、REPLを介さない | テーブル内の情報出力（matrix.html向け等） |
| 保持不要 | REPLへ | `00` | 単発完結、REPLへ投下して終了 | 通常の`eval`コマンド、交渉が`y`で即確定した最終ターン |

- bit1=1（保持する）の場合、この`:out`をログへ積んで次の`:in`を待つ。状態保持の主体は§16.4で決定済みの通り`Serve.Socket`側（`initialized?`と同じ、接続ローカル）が持つ。
- bit1=0（保持不要）の場合、保持状態を解放する。bit2=0（REPLへ）なら、このタイミングで対話プログラムが確定させたコマンドリストをそのまま`Runner.run/4`へ渡して即実行し、その実行結果（`Evaluator`の表示値等）がさらに後続の`:out`エントリとしてログに続く ── §16.4で決めた「`y`即終了」の意味論は、この`00`ケースの1インスタンスとして統一的に表現される。
- 依存チェーン交渉自体は当面`11`（次の質問を出す）と`00`（`y`で確定・即実行）の2状態しか使わない見込み。`10`/`01`は交渉以外の将来の対話プログラム・単発コマンドのための一般化として用意しておく。

**残作業（未着手）**: 既に実装済みの単発コマンド経路（`Dispatch`/`Pipeline`/`Evaluator`、テーブル系の情報出力を含む）を、この2ビット付きの形に揃えるための見直しが必要（crux、2026-09-20:「このあとはこれを念頭に全体的な改訂を行いつつ…既に実装されたテーブル系のコマンドなどをこの2bit変数の情報を付いた形に変えたり…というか見直しから」）。対象範囲・具体的な改訂内容は今後のセッションで詰める。

### 17.1 既存コマンド経路の洗い出しと分類（2026-09-20、同セッション続き）

上記の見直しに向け、現状実装されている全経路を洗い出し、2ビットへの当てはめを確認した。

**`Dispatch`（Tier1、実装済み）── 全て`01`**: `scan/run`/`row/add`/`row/remove`/`effect/set`/`card/get`/`card/search`/`graph/neighbors`/`graph/export`/`cell/resolve`。いずれもBook操作のみでREPLを介さない同期単発処理。`card/get`/`card/search`（カード＝node+calls+linksの取得）が「テーブル内の情報出力」の既存実例にあたる。

**REPLを介す経路（実装済み）── `00`**: `Runner`の`"eval"`疑似メソッド（CLIの`xipe eval`/`xipe do ... -- eval`）。`Repl.Evaluator.run_pass/3`を1回呼んで同期完結、対話（保持）は発生しない。

**`notify/*`（`Serve.Project`のブロードキャストpush）── `01`と再整理（決定）**: 当初この2ビット案が前提にしていた「1つの`:in`に対する`:out`列」という形に、`notify/*`はそのままでは当てはまらない ── Bookが変化するたびに、変化を起こした本人のセッションに限らず**接続中の全セッションへ**配信される（特定の`:in`と1対1に紐付かない）ため。これを踏まえ、`notify/*`固有の配信性質（全attachedセッションへのブロードキャスト、`notify/rowChanged`のような専用method名での判別）はそのまま残しつつ、**受信側から見たメッセージの型としては他の`:out`と同じ`01`固定タグを持たせる**ことに決定。クライアント側の受信ハンドリングは「返ってきたメッセージが直接の応答か横からのnotifyか」をmethod名で区別しつつ、型としては一律この2ビットで扱えるようになる。`eval/run`実装後に想定される複数回の`notify/rowChanged`連投も同様に「`01`の単発pushの連続」であり、2ビットの「保持」（bit1）が指す対話プログラムの多段応答待ちとは別物 ── 混同しないこと。

**未実装分（`eval/run`/`row/update`/`cell/complete`/`edit/propose`/`edit/apply`/`trace/*`/`provider/recheck`）は個別に先回りして型を割り当てない（決定）**: 実装時に「REPLを介するか」「人間の入力待ちで保持が要るか」の2問に答えるだけで、既存の4分類のいずれかに自然に収まる見込みのため。

**結論**: 2ビットの枠組みは特別扱いのケースを増やすことなく、既存・将来のコマンド（単発・非同期push・多段対話のいずれも）を一律吸収できる。§17冒頭の「残作業」は、既存実装へこのタグを実際に付与していく機械的な改訂であり、分類方針自体の設計はここで完了。

### 17.2 アダプタモード（WS）の応答封筒 ── 決定（2026-09-20、実装着手時）

`InOut.handle/6`が返す`{hold, via_repl, text, ok?, result, error}`を、実際にJSON-RPCの応答としてどう乗せるかは§17時点で未決定だった。`Protocol`は元々`result`/`error`の2値しか知らない。

**決定した封筒の形**: 既存の`{"jsonrpc","id","result"|"error"}`に、2つのトップレベルフィールドを追加する。

- **`from`**: 今は常に`null`の予約フィールド。実際の用途は無いが、tezcatlが同一プロジェクトを複数タブで開く場合（§17冒頭で触れた、relayが状態を持たないブロードキャスト中継のため`Serve.Socket`からは全タブのメッセージが同じ接続上で区別なく届く）に備えた将来の拡張余地として、今のうちに枠だけ確保しておく（crux、2026-09-20）。
- **`dialogue`**: `{"hold": bool, "via_repl": bool, "text": string|null}`。

**注意（極性、2026-09-22追記・外部レビューで指摘）**: `dialogue.hold`/`dialogue.via_repl`は§17冒頭の2ビット表と**素朴に同じ向きではない**。`hold`は`bit1`と同じ向き（保持する=`true`）だが、`via_repl`は`bit2`の**逆**（`lib/in_out.exs`実装：通常の`eval`は`via_repl: true`だが、これは表の`00`行＝`bit2=0`「REPLへ」に対応する。`bit2=1`が「REPLへ」だと誤読しないこと）。表の`bit2`は「xipe_totec内で完結するか」の軸として`1`側を自己完結・`0`側をREPL行きに置いていたのに対し、実装のフィールド名`via_repl`は素直に「REPLを介するかどうか」をそのままの向きで表しているため、両者を突き合わせるときは名前ではなく値の対応（`via_repl: true` ⟺ 表の`bit2=0`行）で確認すること。

**`notify/*`への出自付与は別範囲のまま**（§17.1で先送り済みの通り）── 今回の封筒は直接のリクエスト応答にのみ関わる。

**「I/Oは解析対象ではない」という原則（明言、crux、2026-09-20）**: `dialogue.text`（および`result`の中の人間向け文字列一般）はクライアントが構文解析して意味を取り出すためのものではない ── 表示のための文字列である。`XT_BEGIN_<uid>`/`XT_END_<uid>`のような機械可読マーカー（§10.1、REPL接続専用の内部プロトコル）とは別物、と明確に線引きする。

**表示側の規約（CLI/tezcatl共通の原則、実装はCLI側のみ今回対応）**: `id`/`from`/`dialogue`（および`result`/`error`のどちらが返ったかという封筒レベルの区別）は、人間向けの既定表示では隠す ── CLIも将来のtezcatl側パネルも、既定では`dialogue.text`や`result`の中身を素朴な読める行として見せるだけでよい。封筒全体（生JSON相当）を見せるのは、明示的なデバッグ/verboseオプションを付けて実行した時に限る。tezcatl側の具体的な実装は範囲外（§7同様、方針のみ）。

### 17.3 実装 ── `InOut`/`Dialogue`本体、WS配線、CLI配線確認（2026-09-20、未コミット）

§17/§17.1/§17.2の決定を実装した。

- **`lib/dialogue.exs`（`XipeTotec.Dialogue`）**: `start/1`・`answer/2`の2コールバックのみのbehaviour。実プログラムはまだ無い。
- **`lib/in_out.exs`（`XipeTotec.InOut`）**: `handle/6`が`{dialogue, method}`の組で4分岐（§17本文の通り）、`:done`でコマンドがあれば即`Runner.run/4`へ。プロセスを持たない純粋モジュール（`Runner`/`Dispatch`/`Pipeline`と同じ流儀）。`run_to_completion/7`（`next_answer`/`on_text`の2コールバックを注入する形の駆動ループ）も追加 ── `main.exs`のCLIと`Serve.Socket`のどちらからも同じ関数を使い回せる想定（今回はCLI側のみ実配線）。`test/in_out_test.exs`（9件、`ToyDialogue`使用）。
- **`lib/serve_project.exs`**: `request_dialogue/5`を新設（既存の`request/3`はそのまま）。`Book`変異は引き続きこのGenServerの`handle_call`内1箇所のみ（`InOut.handle/6`はそこから呼ぶだけ）。`state.programs`（既定`InOut.programs/0`、`start_link/1`の`opts`で上書き可 ── テスト用）を追加。`test/serve_project_test.exs`に2件追加。
- **`lib/serve_socket.exs`**: `state.dialogue`を追加（§17の「1接続1対話」通り接続ローカル）。通常のリクエストも`request_dialogue/5`経由に統一。応答封筒（§17.2）を実際に組み立てて返す。`test/serve_socket_test.exs`（新規、2件）で`websocket_handle/2`を直接呼んで確認 ── cowboy/実WS接続は不要（コールバック自体がstateを取る素の関数のため）。
- **`main.exs`**: `xipe dialogue-wiring-check [<dir>]`という**一時的な確認専用**サブコマンド（`XipeTotec.CLI.WiringCheckDialogue`という説明つきの捨てモジュール、§16.4の実対話プログラムが出来次第削除予定）を追加し、`InOut.run_to_completion/7`を実stdin/stdoutで実機確認した。`yes`回答で`row/add`が実行され`book.jsonl`に反映されること（`00`側）、それ以外の回答では何も書き込まれないこと（`01`側）の両方を確認済み。CLI層は既存の制約（main.exsが読み込み即実行のため自動テスト困難、§16.5参照）通り自動テストは無く実機確認のみ。

全体テスト26ファイル、`./test/run.sh`緑（既知の無関係な`serve_project_test.exs`フレーク[^flake]除く）。全て未コミット。

[^flake]: 同じ`book.jsonl`パスを複数プロセスが並行で読み書きする既知のflakeで、今回の変更とは無関係（単独実行では毎回green）。

**まだ無いもの**: `InOut.run_to_completion/7`の`Serve.Socket`側での利用（今回はWSの単発`handle/6`呼び出しのみ配線、複数ターンの駆動ループはCLI側のみ）、実対話プログラム（§16.4の依存チェーン交渉、ステップ4のまま）、`notify/*`への出自付与（§17.1で先送り済み）。

## 18. §16.4ステップ2実装 ── `include_writes`配線 + 上流依存チェーン取得（2026-09-21、未コミット）

§16.4の合意順序のうちステップ2（§16.2で「未修正のまま」としていた分）を実装した。ステップ3（第4層、§17）は既にステップ2より先に完了済みだったため、順序が入れ替わった形。ステップ4（依存チェーン交渉本体）はこの2つの上に乗るので依然未着手。

- **`Core.upstream_chain/2`（新規、`lib/core.exs`）**: `call_ids`自身＋その上流`⟦id⟧`依存を`topo_sort/2`で深い方から浅い方への順に返す。`reference_graph/1`を`affected_set/3`とは逆向き（reverseせず forward）に辿るだけ ── 既存の`bfs/3`をそのまま再利用でき、新しい走査アルゴリズムは書いていない。未知のseed idは黙って何も依存を生まない（エラーにしない）。循環参照は`topo_sort/2`の`done`マーキングにより無限ループにはならない（意味のある順序にはならないが安全に終端する）。`test/core_test.exs`に6件（直線チェーン・葉ノード・下流を含まないことの確認・複数seedのマージ重複排除・未知id・循環）。
- **`Dispatch`の新規メソッド `row/depends`**: `{"call_ids": [...]}` → `{"chain": [...]}`。v0.4仕様の§16.3メソッド表には無い、今回の設計過程で生まれた新規メソッド（`GraphQuery.graph/neighbors`＝静的`:links`呼び出しグラフとは別物、と明記）。`row/`は`row/add`/`row/remove`と同じ計算行レベルの名前空間に合わせた（`graph/`は静的呼び出しグラフの意味で既に使われているため避けた）。`test/dispatch_test.exs`に2件。
- **`include_writes`のCLI配線（`Runner`/`main.exs`）**: `Runner.run_one/4`の`"eval"`節が`params["include_writes"]`を読み`Evaluator.run_pass/3`（→`Core.plan_recalc/3`、既に配線済みだった側）へ渡すよう修正。JSON実bool（`true`）と`xipe do`の素朴なkey=valueパーサーが作る文字列`"true"`の両方を許容する`truthy?/1`を追加（`xipe do`は値の型付けをしないため）。専用の`xipe eval`コマンドにも`--include-writes`フラグを追加（`--mix`と同じ形）。`test/runner_test.exs`に3件（既定で除外される・`include_writes: true`で含まれる・文字列`"true"`でも動く）。
- **実機確認**: `.exs`のみのscripts-modeプロジェクト（`base(x)`→`mid(x)`→`top(x)`の3関数）で、`xipe do row/depends call_ids=...`が実際に`["c_base","c_mid","c_top"]`という深い方から浅い方への順を返すこと、`xipe eval`が`--include-writes`無しではwrites行を1件も評価しない（`results`が空）のに対し`--include-writes`ありだとスケジュールされる（実際にREPLへ投げられる）ことを確認した。**ただし実評価そのものは`session_hung`でクラッシュし、しかも`c_base`/`c_mid`の結果行が出力に一切現れないという未解明の挙動が見つかった** ── `xipe do`のCLIパーサーが単一要素リストを表現できない制約を避けるため`Store`を直接いじって行を仕込んだ手動セットアップだった影響の可能性も含め、原因は今回追跡していない。§16.3が元々指摘していた「入れ子のwritesチェーンは`call_ids`に全部列挙しないと動かない」件とは別に、**新たに見つかった未調査の不具合**として記録しておく。

**追記（2026-09-22、§22で解決）**: 原因を特定し修正した。詳細は§22参照。

全体テスト26ファイル(`core_test.exs`+6/`dispatch_test.exs`+2/`runner_test.exs`+3)、`./test/run.sh`緑（既知の`serve_project_test.exs`フレーク除く）。全て未コミット。

## 19. §16.4ステップ4実装 ── 依存チェーン交渉本体（2026-09-22、未コミット）

§16.4の合意順序のステップ4（w1(w2(w3()))の依存チェーン交渉を、既に完成しているステップ2（`include_writes`/`upstream_chain`/`row/depends`、§18）＋ステップ3（第4層`Dialogue`/`InOut`、§17）の上に乗る具体的な1インスタンスとして実装）を実装した。これで§16.4の4ステップ全てが実装済みになる。cruxとの co-design で2点確認: (B) `Dialogue.start/1`の契約（`params`のみ、`book`を渡されない、§17実装済み）はそのまま変更せず、CLI側で`Core.upstream_chain`/`call_label`によりチェーン解決を先に済ませてから交渉を開始する形にする。(C) 対象に上流依存が無い場合は「何もしない」を本線とし、直接評価したいなら既存の`eval`コマンドを別途叩けばよい（crux: 「直接評価であれば専用のコマンドを叩くはず」）。

- **`Core.set_result/3`（新規）**: ユーザー指定のリテラルをREPL評価無しで直接`result`へ書き込む（交渉の「値を入れて評価」ステップの「値を入れる」側）。`resolve_ref/4`の既存の「exact/binaryなら文字列そのまま埋め込む」分岐（`core.exs:426`）が`result`/`repr`列しか見ないことを確認済みなので、新しい埋め込みロジックは不要 ── §16.3で検討して不要と判断した`stub_result`とは異なる用途（あちらはキャッシュ済み値の再利用、こちらは人間による意図的な代入）だが、実装としては同じ2列を書くだけで足りた。`repr`は常に`"exact"`（評価していないので`"binary"`側の材料が無い）。`result_source: "user"`を新設（`prev_source`の`"user"`マーカーと同型、表示・デバッグ用途のみで`Core`内部はどこも読まない）。`add_call/2`のデフォルト列に`result_source: nil`を追加。
- **`Core.call_label/2`（新規）**: `"Module.name/arity"`形式の短縮ラベル。`GraphQuery`の同形式のprivateな`label/1`（ノード行が引数）とは別に、こちらはcall id起点（call→node解決込み）。§16.4が「カード/テーブル表示側の統一的な短縮表記」として未確定にしていた`;; wN info`のフォーマットを、この形式で確定させた。
- **`Dispatch`の新規メソッド`row/set-result`**: `{"id","result"}` → `Core.set_result/3`。pure（REPL不要）なので`Dispatch`の同期Book-in-Book-out契約にそのまま収まる（`"eval"`が`Runner`の疑似メソッドにせざるを得ないのとは対照的）。`effect/set`と同じ`RuntimeError`→`not_found`変換パターン。
- **`XipeTotec.Dialogue.Depends`（新規、`lib/dialogue/depends.exs`）**: 交渉プログラム本体。`start/1`は`params["chain"]`（`Core.upstream_chain/2`の出力に`Core.call_label/2`でラベルを添えた`[%{"id","label"},...]`、対象自身が末尾）を受け取るのみで`book`には一切触れない（B の決定通り）。対象自身（チェーン末尾）は問わず、それより上流の各段だけを深い順に`;; wN <label>`付きで質問する。`"y"`＋`"value"`（対象言語のリテラルテキスト）でその段に`row/set-result`＋その段より浅い側全部（対象含む）を`include_writes: true`で`eval`という2コマンドに確定、交渉終了。`"n"`は1段浅い方へ（宣言した段はそのまま評価もされず捨てられる）。チェーンを使い切った場合（依存が全部`"n"`、または対象に上流依存が元々無い場合の両方）は`:done`・コマンド無しで終了 ── **crux確認: 直接評価にフォールバックしない**（それが欲しければ既存の`"eval"`コマンドを別途使う）。想定外の回答（`"answer"`が無い/不明、または`"y"`で`"value"`が無い）は同じ質問を再度返す。状態は`%{chain, position}`のみ、cruxの元の見立て通り「極めて薄い」実装になった。
- **CLI配線（`main.exs`）**: `xipe dialogue depends [<dir>] <call_id>`を新設。使い捨ての確認専用`dialogue-wiring-check`（§17.3、`WiringCheckDialogue`）はここで削除 ── 予告通り実対話プログラムに置き換え。`InOut.run_to_completion/7`を実stdin/stdoutで駆動、`"y <literal>"`/`"n"`を`%{"answer"=>,"value"=>}`にパースする一段だけをCLI側が持つ。
- **実機確認**: `.exs`のみのscripts-modeプロジェクト（`base(x)→mid(x)→top(x)`）で、(1) 深いほう(`c_base`)で`n`・次(`c_mid`)で`y 999`と答えると、`c_base`は未評価のまま、`c_mid`に`result="999" repr="exact" result_source="user"`が直接書き込まれ、`c_top`が実REPL評価で`996`（`999-3`）になることを確認、(2) 全段`n`で「上流依存を使い切りました。何も実行しません。」、(3) 対象に上流依存が無い場合は即座に同じメッセージで終了、(4) 未知のcall idはCLI側で明確なエラーになりクラッシュしないこと、をそれぞれ確認した。§18で見つかった`session_hung`の未解明バグ（未追跡のまま）は今回のパスでは再現しなかった（今回はStore直接いじりではなく`Core.add_call`/`set_effect`経由でフィクスチャを作った差の可能性はあるが、原因追跡はしていない）。

全体テスト27ファイル(`core_test.exs`+16/`dispatch_test.exs`+3/新規`dialogue_depends_test.exs`+8)、`./test/run.sh`緑（既知の`serve_project_test.exs`フレーク除く）。全て未コミット。

## 20. `card/get`の`row=`アドレスをカード合成へ統一（2026-09-22、未コミット）

`~/my_app/tezcatl`セッションでの crux との co-design。「CLIからカード単位での出力を可能にする」POCの足りないものを洗い出す過程で、`card/get`が住所の指定方法によって2つの違うレスポンス形を返すことが判明した ── `file`/`module`/`name`/`arity`（`Address.resolve/2`が`{:nodes, id, row}`を返す経路）なら`compose_card/3`済みの「node+calls+links」形だが、`row=<call_id>`（`{:calls, id, row}`を返す経路）は`render_match/2`が`compose_card`を経由せず単一行`%{"id"=>id, "row"=>row}`をそのまま返していた。§16.3仕様文（`xipe_totec_spec_v0.4.html`）の`card/get`の説明文自体は「住所オブジェクトでカードを取得する」とだけあり、住所の種類によってレスポンス形が変わることは想定していない ── 実装が仕様からずれていた1件として扱い、`row=`もカードとして返すよう修正した。人間向けのCLI出力整形（一度実装したが crux の指示で撤回）は今回のスコープ外のまま(P7: 入力体験はクライアントの責務)。

- **`Dispatch.render_match/2`（`lib/dispatch.exs`）**: `{:calls, _id, row}`節を、`row.node`から親ノード行を`Book.get/3`で引いて`compose_card/3`に渡す形に変更。呼び出し側（`card/get`/`card/search`のハンドラ本体）・`Address`・`Core`には変更無し ── `render_match/2`内で完結する変更で足りた。
- **`test/dispatch_test.exs`**: 「`row`アドレスは素の行を返す」ことを検証していた既存テスト1件を、「`row`アドレスも所属カードを合成して返す」ことを検証する内容に更新（新規追加はなし、既存の27ファイル構成のまま）。
- **実機確認**: `test/fixtures/calc_sample/calc.exs`（`Calc.mul/2`等）でスキャン→`row/add`→`effect/set`→`xipe eval`まで実行し、評価済みの計算行に対して`xipe do card/get row=<call_id>`と`xipe do card/get module=Calc name=mul arity=2`を叩き、両者が同一の「node+calls+links」形（`result`/`repr`/`eval_count`等を含む）を返すことを確認した。

`./test/run.sh`全27ファイル・0 failures（`dispatch_test.exs`31件含む）。全て未コミット。

## 21. 編集機能の再考 ── 「参照一覧」への転換 + Scan側多言語対応の設計（2026-09-22、`~/my_app/tezcatl`セッションでのco-design、実装なし・方針のみ）

`edit/propose`/`edit/apply`（README「もう一つの柱」＝連動修正、Tier4未着手）について、cruxから方針転換の提案があった。trace（Tier5、凍結中）が実装できれば「同関数の参照一覧」が芋づる式に副産物として得られる流れになるはずで、その参照一覧を出すところまでがxipe_totecの守備範囲、**実際の書き換え（rename等）はエディタ側（LSPのrename機能等）に持たせる方が自然**という判断（crux）。これはP7「入力体験はクライアントの責務。サーバーは口だけ提供する」・README「何ではないか」節の「判定式など、コードの中身そのものの編集」「汎用リファクタリングツールとしての網羅性」とも整合する ── `edit/propose`/`edit/apply`は今回の方針では実質不要になった。

### 21.1 「参照一覧」の実装コストがゼロに近いことが判明

検討の過程で以下が順に確定した:

- 「参照一覧」に trace は不要。既存の静的 `:links` テーブル（`Scanner`のコンパイラトレーサーが既に生成済み）に対する `ref` カラムでのシンプルな検索（＝「単純なSQLの操作」、crux）で足りる。既存の `graph/neighbors`（`direction: "in"`, `depth: 1`）がほぼそのまま使える
- 当初「テーブルに載っている関数からの限定」問題（未スキャン部分は見えない）と「全区間遡った参照だと整合性を無視する」問題（book.jsonlの過去の行まで遡ると古い情報を拾う）のトレードオフを解消するため、専用の対話フロー（3段階メッセージ＋差分区間の追跡＋`A`/`B`ラベリング機構）を検討したが、**「毎回`scan/run`でフルに作り直してから全体へクエリする」という運用にすれば、そもそも両方の問題が発生しない**ことに気づき（crux）、対話フロー・差分区間追跡・ラベリング機構は全て不要と判断した
- 結論: 参照一覧機能に新規実装は不要。**「`scan/run`のフル再実行」＋「`:links`/`graph/neighbors`への既存クエリ」の組み合わせだけで足りる**（Elixir単一言語プロジェクトの範囲では）

### 21.2 Scan側は多言語対応の拡張点が一切無いことを確認

上記21.1はElixir限定という前提に気づき（crux:「Scan側に多言語対応が出来ていなかったことが引っかかる」）、実装を確認した:

- `Project.find_sheets/1`（`lib/project.exs:41`）: `Path.join(dir, "**/*.{ex,exs}")` と拡張子を文字列リテラルで埋め込み。設定・テーブル引きの余地なし
- `Scanner.scan_links/3`: `Code.compile_quoted/2`（Elixirコンパイラ本体）に丸ごと依存。Elixir以外の構文はそもそもコンパイル不能

対照的に `xipe eval` 側（`Repl.Evaluator`）は `launch_module`/`eval_template_module`/`scan_module`/`field_drip_module` という4つの差し替え可能なオプションを既に持つ（`document/repl-adapter-guide.md`）── 「言語ごとの実装が1つしかない」だけで、差し替える仕組み自体はある。**Scan側はこの仕組み自体が無い**、というのが今回確認した非対称性。

### 21.3 方針: Scanのbehaviour化 + file:path(depth):language:REPLテーブル + 実行リスト自動生成

（cruxとの co-design、実装は次回以降）

- **Scannerをbehaviour化**し、`find_sheets`の拡張子決め打ちを言語→拡張子のテーブル引きに一般化する。Evalが「files（データ）＋4モジュール（選択）」を分けて渡す形と対称に、Scanも「files（データ）＋Scanner実装（言語での選択）」を分けて渡す形にする
- **新規Bookテーブル（仮称`:files`）を新設**: 列は「ファイルパス・深さ・言語・REPL(起動モード)」。既存の`:nodes`/`:sheets`と同じ「再スキャン時のID継続規則」（`Identity`モジュール、§7.3）に乗せ、再生成のたびに自然キー（ファイルパス）で上書き・消失分はtombstone化する（＝カード生成と同じ枠組み。新規の永続化方式は不要）
  - **「深さ」列は複数言語が混在するモノレポでのrootMarker境界判定に必須**と判明（crux）: どのファイルがどの直近のrootMarker（＝どの言語プロジェクトの傘下）に属するかを、tezcatl `lsp.json`の`rootMarkers`walk-upと同じ要領で解決するために使う
- **このテーブルから実行リスト（`Runner`が読める`[%{"method"=>"scan/run","params"=>%{lang:...,files:...}}, ...]`形式のコマンドリスト）を自動生成する**。新しい実行エンジンは不要、既存の`Runner`/`xipe do`のコマンドリスト機構にそのまま乗る
  - **追記（2026-09-23、§29）**: この構想は撤回せず、保留中の trace 機能に着手するときに扱う対象として残す

### 21.4 言語/REPL判定はxipe_totec側に内製せず、LSPへの委譲を基本線にする

「判定メソッド」（rootMarkerベースの言語判定）は、tezcatl側の`lsp.json`と同じロジックをxipe_totec側に複製するのではなく、**§16.3の`provider/*`（Tier4、未実装）経由で外部（接続済みのLSP）から供給される「提案」として受け取る**方針にする（crux）。P8「単体で完結し、外部の提供（言語サーバー等）は上乗せとする」・P4「LLM・ヒューリスティクス・外部提供元は『提案』のみ、受け入れ検査を通ったものだけ採用」と整合。

さらに、Scanが本来行う2つの仕事（定義一覧の抽出＝`:nodes`、呼び出し関係の抽出＝`:links`）がLSP標準リクエストでどこまで代替できるか検討した結果:

| xipe_totecの仕事 | 対応するLSPリクエスト | 備考 |
|---|---|---|
| `:nodes`（module/name/arity/span） | `textDocument/documentSymbol` | ほぼカバー。arityは`detail`文字列依存でサーバー次第の可能性あり |
| `:links`（誰が誰を呼ぶか＝参照一覧） | `callHierarchy/incomingCalls`（LSP 3.16+）、フォールバックで`textDocument/references` | サーバーが対応していれば直接使える。むしろ「参照一覧」機能自体、`:links`テーブルを経由せずこの場で直接使う道もある |
| `body_hash`（変更検知用の内容ハッシュ） | 無し | LSPの範囲外。`documentSymbol`の範囲でソースを自前で読みハッシュを取ればよく、問題にならない |

`callHierarchy`未対応のLSPサーバーがある、という残る限界は**本プロジェクトの対象外として許容する**（crux: サーバーの限界であってxipe_totecが自前で補う話ではない）。

**次のタスクとして確定**: 「LSPへの投稿文（xipe_totecが接続済みLSPへ送るリクエストの仕様）を決める」。`document/repl-adapter-guide.md`と対になる、Scanner側の新規ガイド文書が必要になりそうだが、これも次回以降。

## 22. §18の`session_hung`原因を特定・修正 ── `Core.plan_recalc/3`に`drop_unresolvable/2`を追加（2026-09-22、`~/my_app/tezcatl`セッション、未コミット）

`~/my_app/tezcatl`セッションでの`crux`とのco-design。4文書（README/Old.md/動作原理.md/repl-adapter-guide.md）全体を外部AIレビューに通した指摘（1-1「セッション寿命と`:binding`の前提のずれ」・1-2「§18の`session_hung`原因の推測」）を、実コードで検証・修正した。1-1は「制約として文書化する」方針(a)を採用（分散セッション状態を持たないという既存の設計方針、§16.4追記と整合）。

### 22.1 根本原因（実コードで確認、推測ではない）

`Core.resolve_ref/4`（`lib/core.exs`）の`:binding`分岐（catch-all）は、参照先がこのパス内で束縛される（`:in_plan`）・literal再埋め込み可能（`exact`/`binary`）・再帰inline可能（`unsupported`+pure）のいずれでもない場合に落ちる。ここで生成される`xt_<call_id>`という裸のElixir変数参照は、「このパス内のどこかで束縛される」ことを前提にしているが、`run_pass`はパスごとに新しいiexセッションを起動して閉じる（§11.4/動作原理§5）ため、**この前提は構造的に成立しない**（同一パス内で先行entryとして実際にスケジュールされる`:in_plan`の場合を除く）。

`EvalTemplate.build/1`（`lib/repl/eval_template.exs`）の事前チェック（`Code.string_to_quoted/1`、86行目）は構文の完結性のみを見るため、この種の「構文としては正しいが意味的に未束縛」な変数参照はすり抜ける。`call_expr`は`spawn_monitor(fn -> ... end)`のクロージャ内に埋め込まれる（129行目）が、Elixirは変数束縛をコンパイル時に字句解析で解決するため、`xt_c_mid`のような未束縛変数への参照は**`spawn_monitor`が呼ばれる前に、スニペット全体のコンパイルエラー**になる。マーカー印字コードも同じスニペットの一部としてコンパイルに巻き込まれ実行されないため、`XT_ERROR`すら出ない。Parserは固定デッドラインまで待ち`session_hung`と判定する。§18で「`c_base`/`c_mid`の結果行が一切現れない」と観測されたのはこのため（`filter_by_effect/3`が`effect_source`未設定の`c_base`/`c_mid`をそもそも`scheduled`から除外しており、`c_top`だけが実際にentryとして組み立てられ、上記のコンパイルエラーで沈黙していた）。

### 22.2 修正

- **`Core.resolve_ref/4`**: `:binding`タプルに`ref: ref`を追加（既存コンシューマは`m.field`形式でマップ全体を読むため後方互換）。どの参照先が未解決なのか追跡できるようにするための最小限の追加。
- **`Core.drop_unresolvable/2`（新規、private）+ `shrink/3` + `missing_ref/3`**: `plan_recalc/3`が`filter_by_effect/3`後の`scheduled`集合に対して適用する。各callの`args`を`resolve_refs/4`で（実際に`build_entry`が使うのと同じロジックで）解決してみて、解決不能な`:binding`が1つでも出たら、そのcallを集合から除外し`{:skipped, ref}`として記録する。除外は連鎖しうる（あるcallが除外されると、それに依存していた別のcallも新たに解決不能になる）ため、culprit が見つからなくなるまで集合全体を再走査する不動点計算。既存の`{:skipped, upstream_id}` outcomeタグ（`apply_result/3`・CLIフォーマッタに元々定義済みだが、grep全体で確認した限りこれまで一度も生成されていなかった）にそのまま乗る。
- **`plan_recalc/3`の返り値に`skipped`フィールドを追加**（`%{call_id:, outcome: {:skipped, ref}, compare: "skipped", evaluated_at: nil, session_gen: nil}`のリスト）。`compare`/`evaluated_at`/`session_gen`は`Evaluator`の`:aborted`/`session_hung`結果や`Repl.Eval.Result.error/3`と同じ形に揃えた（CLIの`print_outcome`が`r.compare`を無条件に読むため、揃えないと`KeyError`になることを実機で確認して追加）。
- **`Repl.Evaluator.run_pass/3`**: `plan.skipped`を、REPLセッションを起動する前に`Core.apply_results/3`で先に畳み込む。`plan.entries`が空でも`plan.skipped`があればそれを返り値の`results`とする（従来は空プランなら無条件`{:ok, book, []}`だったが、今は「スキップされた理由」を報告できる）。boot/launch失敗時は引き続き何も永続化しない（次回`run_pass`で同じ判定が再計算されるので実害はない）。

### 22.3 テスト・実機確認

`test/core_test.exs`の既存3件（`:binding`フォールバックが「正常にスケジュールされる」ことを検証していた＝旧バグの挙動そのものを検証していた）を、「解決不能なので`:skipped`になる」ことを検証する内容に更新。新規に「base→mid→top連鎖でbaseが未分類のとき、mid・topともカスケードしてskipされる」テストを追加（§18の実シナリオそのもの）。`test/repl_eval_template_test.exs`の2件は、`plan_recalc`がもう該当entryをスケジュールしなくなったため、`EvalTemplate.call_expression/1`自体の`:binding`/occurs-check処理を直接検証する形（entryを手組み）に書き換え。

実機確認: `base(x)=x+1`/`mid(x)=base(x)*2`/`top(x)=mid(x)-3`という3関数のプロジェクトで、`base`のnodeだけ`effect_source`を未設定のままにし（§18と同じ前提条件）、`Core.add_call`/`Core.set_effect`経由でcalc行を作成（`xipe do`の単一要素リスト制約を回避）。修正前は`session_hung`になっていたはずの`xipe eval .`が、ハングせず即座に

```
eval call c_mid  skipped  upstream c_base did not evaluate  compare=skipped
eval call c_top  skipped  upstream c_mid did not evaluate  compare=skipped
```

と正しく報告することを確認した。`book.jsonl`にも`state: "ref_error"`・`error: "upstream c_base did not evaluate"`等が正しく永続化されている。

`./test/run.sh`全27ファイル・0 failures（`core_test.exs`45件・`repl_eval_template_test.exs`11件含む）。全て未コミット。

## 23. ハートビート撤去 + `erlexec`移行 + `Sender.interrupt/1`新設（2026-09-22、`~/my_app/tezcatl`セッションでのco-design、未コミット）

`repl-adapter-guide.md`の11項目チェックリストのうち項目10（軽量並行機構）・11（plain pipe対応）を巡る議論から出発した方針転換。要点は「xipe_totecから対象REPLへ投じる文言（マーカープロトコル）は既に一律化されている以上、対象言語ごとに違うケアが要るのは①値を渡せるか②値を利用できるかの2つに尽きるのではないか」というcruxの指摘（2026-09-22）を、汎用実行層（Sender）とアダプタ（算出プログラム）の責務分界として詰めた結果。

### 23.1 決定事項

- **ハートビート機構を撤去**。生存確認は「固定デッドライン（既存の§14.2判定はそのまま）＋対象プロセスの**プロセスグループ全体**へのシグナル」という、対象言語に一切コードを書かせない汎用実行層だけの仕組みに一本化。`XT_HEARTBEAT`マーカー・`heartbeat_interval_ms`/`heartbeat_input`フィールド・`Launch.heartbeat_input/1`は全廃。`XT_EXIT`は変更なし
- **`Sender`の起動機構を`erlexec`へ移行**（`lib/repl/sender_direct.exs`）。理由: 生のPort APIにはPOSIXプロセスグループの作成（`setpgid`/`setsid`相当）もグループ宛てシグナル送信（`killpg`相当）も無い。tezcatlの`XipeConn`/`LspServer`が既に使っている依存をそのままコピー（`{group, 0}`で新しいプロセスグループを作って起動）
- **`Sender`に`interrupt/1`を新設**（`kill/1`と同じくグループ宛て、SIGINT）。`kill/1`も同時にグループ全体へのSIGKILLへ修正 ── 旧実装は`Port.info(port, :os_pid)`で取れる単一pidだけを`kill -9`していたため、対象REPLが子プロセスを持つ構成（`iex -S mix`のビルドステップ等）だと孫プロセスを孤児化させるバグを実質的に抱えていた。今回のグループ化で同時に解消
- **`Repl.Launch`に`interruptible`（真偽値1つ）を追加**。対象REPLがSIGINTを受けて評価だけ中断しプロンプトへ戻れるか、それとも即終了するだけかを言語アダプタ側が申告する。`Evaluator.end_hung_session/4`はハング確定時、`interruptible`なら`interrupt/1`→短い猶予で`XT_EXIT`待ち→`kill/1`、そうでなければ直接`kill/1`（**crux「option A」**、2026-09-22: ハング entry 自身の扱い＝`session_hung`・残りentry`:aborted`は変更しない。中断が効いた場合に同一セッションで残りentryの評価を続行する「option B」は今回見送り）

### 23.2 実機確認（2026-09-22）

- **SIGINTがplain pipe経由でもBEAMへ届くことを確認**: `erlexec`で`{group, 0}`付きで起動した`iex`（PTY無し）に対し、**正のospidを渡して**`:exec.kill(ospid, 2)`（`-ospid`ではなく。負のpidを渡すと`{:error, "Not allowed to send signal to all processes"}`になることも確認済み ── erlexec自身が`{group,0}`起動プロセスへのグループ配送を内部で行うため、呼び出し側は普通に正のospidを渡すだけでよい）すると、実際の端末でCtrl-Cを押したときと全く同じ`"BREAK: (a)bort (A)bort with dump (c)ontinue (p)roc info (i)nfo ..."`メニューが出力に現れた
- **exit statusのデコードで実バグを発見・修正**: erlexecの`:DOWN`理由は、exit code 0のときは`{:exit_status, n}`ではなく**裸の`:normal`アトム**（他のnonzero exit codeは`{:exit_status, code <<< 8}`、シグナル死は生のシグナル番号）── 当初この分岐が漏れており、正常終了が`"XT_EXIT :normal\n"`という壊れたマーカーになるバグを実機テストで検出、`:exec.status/1`（erlexec自身のデコーダ）＋`:normal`の特別扱いで修正。`test/repl_sender_direct_test.exs`が変更無しでこのバグを検出した（既存テストの価値）
- **通常評価・タイムアウトパスとも新実装で実機動作確認**: `test/fixtures/calc_sample`相当のプロジェクトで`xipe eval`が引き続き正常動作（`compare=same`まで含め）、無限ループ関数の評価が対象言語側の内部タイムアウト（`spawn_monitor`+`receive...after`、既定5秒）で正しく`timeout`として終わり、プロセスが孤児化しないことをそれぞれ確認した。**「外側のハング判定＋interrupt/1」を要求する真の`session_hung`経路（内部タイムアウト自体が機能しないほどBEAMスケジューラが完全に止まるケース）は、安全に再現する方法が無く実機未確認のまま** ── ユニットテスト（`SilentSender`によるフェイク）でオーケストレーションのロジックは検証済み

### 23.3 文書

`document/repl-adapter-guide.md`を全面改訂: マーカー表・JSON一覧表から`heartbeat_*`を削除し`interruptible`に置換、「`heartbeat_input`を書くために必要な知識」節を「`interruptible`を決めるために必要な知識」に差し替え、チェックリスト項目10を「軽量並行機構の有無」から「SIGINTで中断・復帰できるか」に再定義。候補4言語（OCaml/Haskell/Clojure/Racket）分の項目10・まとめ節も合わせて更新 ── 新設計では対象言語に軽量並行機構が無くてもブロッカーにならない（`interruptible: false`にすればよいだけ）ことを明記した。

### 23.4 テスト

`lib/repl/eval/scan/direct/iex.exs`・`lib/repl/eval/parser.exs`から`heartbeats`フィールドを削除、`test/repl_eval_scan_direct_iex_test.exs`のハートビート専用テスト2件を削除。`test/repl_launch_test.exs`を`interruptible`検証に更新。`Repl.Sender`のfakeを実装している全箇所（`test/repl_evaluator_test.exs`3箇所・`test/runner_test.exs`3箇所）に`interrupt/1`を追加。

`./test/run.sh`全27ファイル・241テスト・0 failures。全て未コミット。

## 24. §21の続き ── `tables/`ディレクトリ設計 + `info.json` + `xipe reflesh`新設（2026-09-23、`~/my_app/tezcatl`セッションでのco-design、一部未コミット）

§21で構想したプロジェクト別`:files`テーブル（Book内テーブルとして新設する案）を、cruxとの追加co-designで具体化した。結論として、Book内テーブルではなく**xipe_totec自身が持つ中央レジストリ**（`tables/`ディレクトリ）に置く設計に変わった。

### 24.1 決定事項（設計のみ、この節の時点では未実装）

- **保存場所を`book.jsonl`(CWD相対、対象プロジェクト側に依存)からxipe_totec自身が持つ中央レジストリへ転換**。理由は3つ（crux、2026-09-23に再確認）: ①対象プロジェクト側を汚さずに済む、②再開のたびの全走査を避けられる（作る情報量自体が小さいのでキャッシュのデメリットが出にくいという判断）、③削除したくなったとき対象プロジェクトへの書き込み権限問題に巻き込まれず、xipe_totec側だけで完結する。ディレクトリ構成:
  ```
  tables/
    └ project/
        └ <ID>_<directory-name>/
            ├ table          … プロジェクトのファイルツリー走査結果（surface_table）
            └ card, table    … 既存の card 相当の専用ディレクトリ
  ```
  **注記（2026-09-23、crux確認済み）**: `card, table`は「新設の`surface_table`だけでなく、**`book.jsonl`自体（`card/get`等が読んでいる既存データ）もこの`tables/project/<id>/`配下へ移す**」という意味だった。この一文は§24.1で最初から書かれていたが（1つ上の「保存場所を`book.jsonl`から…転換」）、§24.2以降の実装では`project.json`（新規メタファイルのみ）しか`tables/`配下に置いておらず、`book.jsonl`自体は今もCWD相対の旧来の場所に残っている ── §27に5つ目のタスクとして追記した
- **プロジェクトごとのファイルツリーテーブルを`surface_table`と命名**（crux）。列はID・ファイルパス・深さ・言語・REPL。`深さ`はモノレポで複数言語混在時にどのファイルがどの直近のrootMarker配下かを判定するために必須（tezcatlの`lsp.json`の`rootMarkers`walk-upと同じ要領、§21.3から継続）
- **REPLでの評価結果を持つテーブルを`eval_table`と命名**（この会話でのco-design。「`depth_table`」も候補に上がったが、`surface_table`の「深さ」列と語がかぶり紛らわしいため`eval_table`を採用 ── 既存語彙(`xipe eval`/`Repl.Evaluator`/`eval_template`)ともそのまま繋がる）
- **プロジェクトのID**: 3桁の整数。Bookの各テーブル行が使うULID（`Id.ulid()`、§7.1）とは別の採番規則で意図的に設計 ── こちらは「対話でユーザーが打ち返す選択トークン」という性質のもので、`Dialogue.Depends`の`wN`ラベル（`lib/dialogue/depends.exs`、`Core.call_label/2`のdoc参照）と同じ位置づけ。**`000`は「新規（未登録）」を示す予約値**とし、実在プロジェクトのIDは`001`から採番する（`wN`が`w0`ではなく`w1`から始まるのと同じ理由で、採番空間の衝突を避けるため）
- **プロジェクト選択・テーブル生成コマンド**（design、実装は次回以降）:
  - `xipe table generate <path>`: `path`のプロジェクトツリーを走査し、そのプロジェクトの`surface_table`を全上書きで再生成する。§21.1の結論（差分区間追跡は不要、フル再実行で整合性問題ごと解消する）を踏襲
  - `xipe choice project <path>`: `path`に対応する`surface_table`が既に`tables/project/`配下にあるかを確認し、無ければ`xipe table generate`を実行してから、選択結果（プロジェクトID）を`info.json`の`project`欄へ書き込む。既存プロジェクトかどうかの判定は`info.json`側に別途インデックスを持たせず、`tables/project/`配下のディレクトリ走査で行う方針（crux承認）

### 24.2 `xipe`をCLI一発コマンド群のまま保つ判断

当初cruxから「既存の一発コマンド群（`xipe scan`/`xipe eval`等）も対話（`InOut`/`Dialogue`)に落とし直す方が、外部（tezcatl等）に出す際の情報提示を`xipe_totec`からの応答に一本化できて一貫性が高いのではないか」という提案があった。この会話での検討の結果:

- `InOut.handle/6`のmoduledoc自身が「`dialogue`と無関係なmethodはRunner.run/4へ素通しされる、InOutが存在しない場合と全く同じ」と明記しており、CLI側を`InOut`経由に揃えること自体は既存の一発コマンドの挙動を変えない
- ただし`InOut`の`dialogue`状態はプロセス内メモリのみ（ディスクに永続化されない）ため、「起動→プロジェクト選択→以降のコマンドがそれを覚えている」を**プロセスをまたいで**実現するには、対話への統合とは別に、選択結果をディスクへ永続化する仕組みが要る
- 結論（crux）: `info.json`へJSON永続化する。プロセス内で完結する処理（`xipe dialogue depends`等の対話プログラム自体）はそのままで、他の一発コマンドは起動時に`info.json`を読んで「現在選択中のプロジェクト」を得る形にする。これにより`xipe`自体を対話セッション化する必要が無くなり、`test/run.sh`等の既存呼び出し方も変えずに済む

### 24.3 `info.json`とその読み書きモジュール

- **`info.json`はxipe_totec自身の直下**（`book.jsonl`のようなCWD相対ではなく、`XipeTotec.Info`モジュール自身の`__DIR__`から絶対パスで解決 ── `book.jsonl`のCWD相対設計は、nixの`xipe`ラッパーが常に`$XIPE_TOTEC_DIR`へ`cd`することに実質依存しており、`info.json`はその前提に乗らない設計にした）
- 内容: `%{"languages" => [...], "repls" => [...], "project" => nil}`。`languages`/`repls`は`xipe reflesh`（下記）が埋める。`project`は`xipe choice project`（§24.1、未実装）が書き込む欄で、この節の時点ではまだ常に`nil`
- **`languages`/`repls`の更新は自動導出ではなく明示コマンド経由**（crux決定）: `field_drip/`/`scan/`配下にファイルが存在するだけでは「実際に動く言語サポートとして確定した」ことにはならない（実装途中のファイルの可能性がある）ため、P4「外部提供元は『提案』のみ、受け入れ検査を通ったものだけ採用」と同じ発想で、`xipe reflesh`という人間が明示的に叩くコマンドを経由させる。コマンド自体の中身はディレクトリ列挙で自動化してよい（手動なのは「コマンドを叩く」という行為であって、中身を手書きすることではない）

### 24.4 実装（この節で実施、未コミット）

§24.1の`tables/`/`surface_table`/`table generate`/`choice project`本体は次回以降に持ち越し、今回は`info.json`の土台のみ実装した:

- **`lib/info.exs`（新規、`XipeTotec.Info`）**: `load/1`・`save/2`（`info.json`の読み書き、`Store`と同じ「pathを引数に取る、既定値はモジュール定数」の形）、`refresh_languages/1`（`lib/repl/eval/field_drip/*.exs`の列挙）、`refresh_repls/1`（`lib/repl/eval/scan/<transport>/*.exs`の列挙、`transport`/`repl`のペアで返す）
- **`main.exs`に`xipe reflesh -l|--languages, -r|--repls, -a|--all`を新設**。フラグ無指定はusageエラー（`P4`と同じ「暗黙に決め打ちしない」方針）。`-l`/`-r`は独立 ── 片方だけの再実行がもう片方を巻き込まない
- **JSON実装について確認**: `xipe_totec`はMixプロジェクトではない（`mix.exs`が無い）ため外部Hexパッケージは`nix/relay-packages.nix`経由でしか追加できない(§17/§23の`cowlib`/`erlexec`と同じ経路)。当初「JSON対応がまだ無いのでnixへ追加が要るかもしれない」という想定があったが、確認の結果`flake.nix`のshellHook自身のコメントに「Core/Store/Scanner/CLI still lean on Elixir 1.18's built-in JSON module」とある通り、Elixir 1.18同梱の`JSON`モジュール（`JSON.encode!/1`/`JSON.decode!/1`）が`lib/store.exs`で既に使われており動作確認済みだったため、**nix側の変更は不要**だった（`JSON.decode!/1`の実機動作は今回`nix develop`シェル内で`JSON.decode!("{\"a\":1}")`を実行し確認)
- **`test/info_test.exs`（新規）**: `load/1`の欠損ファイル時デフォルト、`save/2`→`load/1`往復、`refresh_languages/1`・`refresh_repls/1`がそれぞれ他方のキーを触らないことを検証
- **実機確認**: `xipe reflesh -a`を実行し`info.json`が`{"languages":["elixir"],"project":null,"repls":[{"repl":"iex","transport":"direct"}]}`で生成されることを確認。`xipe reflesh`（フラグ無し）がusageエラーで終わること、`xipe reflesh -l`が`repls`を変更せず`languages`だけ更新することも確認した

`./test/run.sh`全28ファイル・0 failures（`info_test.exs`4件追加）。`info.json`・`lib/info.exs`・`test/info_test.exs`・`main.exs`の変更、全て未コミット。

### 24.5 `surface_table`生成ロジックの実装（同セッション続き、未コミット）

§24.1で設計のみとしていた`surface_table`のうち、行生成ロジック（crux案の3ステップ: 空スキーマ→ID/パス/深さの充填→拡張子からの言語充填）を実装した。`xipe table generate <path>`本体のCLIコマンド化・`tables/project/<ID>_<name>/`への配置（プロジェクトIDの解決が要る）は、こちらも§24.1と同じく引き続き未着手。

- **SQL導入は見送り**（crux、検討の末「必要になってからでも事足りる」と判断）。`Book`（`lib/book.exs`）が6テーブル全てプレーンな`id => 行`のMapで運用されているのと同じ形で、`surface_table`も`id`/`path`/`depth`/`language`だけの単純なJSON配列として実装した
- **`tree`コマンドは使わず`Path.wildcard/1`を使用**（`Project.find_sheets/1`と同じ手段、外部プロセス依存もパース処理も増やさない）
- **`repl`列は今回省略**（値が常に`nil`になる列を持たせるのではなく、column自体を無い状態にした。REPL判定方法が決まり次第追加）
- **拡張子→言語の対応は`@extension_language`としてモジュール内に一時的にハードコード**（`%{"ex" => "elixir", "exs" => "elixir"}`）。cruxの指摘（「JSON更新自体要るのか」）を受けて、本来あるべき形（各`Repl.Eval.FieldDrip.*`モジュールが`extensions/0`のようなcallbackで自己申告し、`xipe reflesh`がそれを集めて回る）は**タスクとして保留**、今回は`SurfaceTable`モジュール内の暫定コードのまま進めた（moduledocに保留である旨を明記）
- **IDの継続規則**: `Identity.sheet_id/2`（`:sheets`テーブル用、パスの完全一致でのみ既存idを再利用）と同じ考え方を、`Identity`モジュール自体は経由せず`SurfaceTable.generate/2`内に直接実装（`surface_table`は`Book`/`book.jsonl`の外にあるため）。再生成のたびに`old_rows`から`path => id`のマップを作り、一致すれば既存id、無ければ`Id.ulid()`で新規発行
- **`lib/surface_table.exs`（新規、`XipeTotec.SurfaceTable`）**: `generate/2`（`dir`を`Path.wildcard`で全ファイル走査、`old_rows`からidを引き継ぎ）、`load/1`・`save/2`（フル上書きのJSON配列、§21.1の「差分追跡は不要、フル再実行で足りる」を踏襲 ── `Store`のappend-log/tombstone方式は使っていない)
- **`test/surface_table_test.exs`（新規、7件）**: 全ファイル走査、深さ計算、既知/未知拡張子での言語充填、新規id発行、再走査でのid安定性（既存パスはid維持・新規パスのみ新id）、`load`/`save`往復を検証

`./test/run.sh`全29ファイル・0 failures（`surface_table_test.exs`7件追加）。`lib/surface_table.exs`・`test/surface_table_test.exs`、未コミット。

### 24.6 プロジェクトID解決 ── `ProjectRegistry`新設（同セッション続き、未コミット）

§24.1で「既存プロジェクトかどうかの判定は`tables/project/`配下のディレクトリ走査で行う」とした部分を、cruxとの追加co-designで詰めて実装した。

- **課題**: `<ID>_<directory-name>/`というディレクトリ命名の`<directory-name>`部分だけでは、`<path>`からIDを一意に引けない（別の実パスが同じベース名を持ちうる、例: `~/work/foo`と`~/other/foo`）
- **決定**: 各プロジェクトディレクトリに`project.json`（`{"path": "<Path.expand/1で正規化した絶対パス>"}`のみ）を新設し、これを実際の照合キーにする。ディレクトリ名の`<directory-name>`部分は人間がls一覧を読むときの可読性のためだけの飾りで、照合には使わない
- **ID採番**: `tables/project/`配下の既存ディレクトリ名先頭3桁の最大値+1。`000`は最初から採番対象外。**IDは削除されても再利用しない**（最大値+1方式、空いている最小値を詰めない）── 削除済みプロジェクトの古いIDを別の新規プロジェクトが引き継いでしまう事故を避けるため
- **`000`の位置づけを確認**: `tables/project/`配下には常に`001`以降しか実在せず、ディスクに`000`という値が書き込まれることは無い。「新規」の`000`は`xipe choice project`（未実装）の応答フロー内だけの一時的な信号という理解でcrux確認済み
- **`register/2`は`surface_table`生成とは独立**: id/ディレクトリ/`project.json`の作成のみを行い、`table`（`SurfaceTable`の出力）には一切触れない。冪等（同じpathを2回登録しても同じidが返り、ディレクトリは重複作成されない）
- **`lib/project_registry.exs`（新規、`XipeTotec.ProjectRegistry`）**: `find/2`（path→既存id、無ければnil）、`next_id/1`、`register/2`（find-or-create、冪等）
- **`test/project_registry_test.exs`（新規、9件）**: 初回登録でのid採番（`001`から）、冪等性（同一path2回登録で重複ディレクトリを作らない）、別pathでの連番、`find`での逆引き、`.`相対パスと絶対パスの正規化一致、削除済み上位id（`005`のみ存在）があっても`006`から採番しid再利用しないこと、3桁プレフィックスを持たない無関係なディレクトリが無視されることを検証

`./test/run.sh`全30ファイル・0 failures（`project_registry_test.exs`9件追加）。`lib/project_registry.exs`・`test/project_registry_test.exs`、未コミット。

## 25. REPL/ビルドツール判定の設計（2026-09-23、`~/my_app/tezcatl`セッションでのco-design、設計のみ・一部プレースホルダ実装）

§24.5で保留していた`surface_table`の`repl`列について、cruxとの議論で設計を前進させた。結論としては実装はまだプレースホルダ止まりだが、方針は固まった。

### 25.1 「LSPへ委譲」の対象を絞り直した

§21.4は「言語/REPL判定はxipe_totec側に内製せず、LSPからの提案として受け取る」としていたが、これは**言語のモノレポ境界判定**（rootMarker walk-up、複数言語混在時にどのファイルがどの直近のプロジェクト配下かを決める、本質的に難しい問題）についての話であって、**プロジェクトルートが1つ決まった後の「どう起動するか」**とは別問題だと整理し直した（crux承認）。後者は既に`Runner.launch_opts_for/2`（`lib/runner.exs:173-184`）が`File.exists?(Path.join(root, "mix.exs"))`だけでmix-mode/scripts-modeを機械的に決めており、LSPを一切使っていない。しかも今の`surface_table`生成（`SurfaceTable.generate/2`）はモノレポ境界分割を最初からやっていない（指定パス配下を丸ごと1プロジェクトとしてフラットに扱う）ため、境界判定という難しい方の問題は今のところ存在せず、`repl`列はLSP無しで機械判定できる、という結論になった。

### 25.2 ビルドツールの多重候補とNixの扱い

- **同一言語内での複数マーカー**: `launch_opts_for/2`の`mix.exs`チェックを、優先順位付きリストへ一般化する（例: Haskellなら`stack.yaml` > `*.cabal` > 裸の`ghci`）。難易度としては今のElixir判定と同種、候補が複数になるだけ
- **Nixは環境（PATH上にコマンドが存在するか）の問題として別軸で扱う**: 今のxipe_totecがElixir対象で動いているのは、`flake.nix`自身のコメントにある通り「xipe_totec自身と対象プロジェクトを同じnixpkgsリビジョン・同じElixir/OTPに固定する」という前提に乗っているだけで、汎用解決ではない。対象プロジェクトが`flake.nix`/`shell.nix`を持つ場合はマーカー表の**最優先項目**とし、起動argvを`["nix","develop",root,"--command"] ++ 元のargv`でラップする。`nix`が無い/flakeが無い場合のみ、素朴なビルドツール判定にフォールバックする
- **`erlexec`/`Sender.Direct`側の変更は不要**: argvの組み立てだけの話なので、`Repl.Launch`が返す`argv`が変わるだけで済む。`{group, 0}`のプロセスグループkillも`nix develop`の子孫プロセスごと落とせるはず（未検証）

### 25.3 `ready_pattern`の頑健性 ── 固定echoマーカー方式

`nix develop`でラップすると、対象プロジェクト自身の`flake.nix`のshellHookが出す`echo`（バナー等）が、REPL本体の起動より前にバッファへ混ざりうることを、この会話中に実際に`nix develop --command elixir ...`を何度も実行して確認した（shellHookの"🔧 Xipe Totec dev shell"等が毎回先頭に出た）。対応方針（crux）: 対象REPL自身の起動バナー文字列（バージョン依存で不安定、`repl-adapter-guide.md`のチェックリスト項目3が元々指摘していた問題でもある）を`ready_pattern`にするのをやめ、xipe_totec自身が固定の`XT_READY`のようなマーカーを明示的にechoさせる初期化ステップを起動シーケンスに挟み、それを`ready_pattern`にする。nixのバナーノイズ問題とElixirの`ready_pattern`不安定さの両方を同じ一手で解消する

### 25.4 判定ロジックの置き場所 ── 言語アダプタ側の自己申告 + プロジェクトごとの永続化された結果

§24.5で保留した「`extensions/0`を`field_drip`モジュールに自己申告させる」のと同じ形を、ビルドツール判定にも適用する（crux）:

- **静的な判定ロジック（言語アダプタ側がコードとして自己申告）**: 「この言語にはどんな入口候補があり、どのマーカーファイルでどう検出し、どう起動argvを組み立てるか」という優先順位表そのものを、その言語のアダプタ側に持たせる
- **動的な結果（プロジェクトごとに1回判定し永続化する事実）**: `xipe table generate`/`xipe choice project`が上記ロジックを対象rootに対して実行して出た結果（「このプロジェクトは`stack`を使っている」）を、判定のたびに毎回マーカーファイルを見直すのではなく`surface_table`の`repl`/`build_tool`列に記録しておく

### 25.5 実装（プレースホルダのみ、未コミット）

上記の判定ロジック自体（マーカー優先順位表、`nix develop`ラップ、`XT_READY`初期化ステップ、`Evaluator`/`Repl.Launch`側の実際の合成）はまだ未実装。今回は`surface_table`のスキーマに列を追加するところまで:

- **`lib/surface_table.exs`**: 行に`"repl"`/`"build_tool"`の2列を追加、両方とも常に`nil`（検出ロジック未実装のプレースホルダ、moduledocに明記）。本来はプロジェクト単位の事実であり同一プロジェクトの全行で同じ値になるはずだが、`project.json`側に1個だけ持たせる案は「検出ロジックが無いうちから保存場所を2箇所に分けて決めるのは早計」として今回は見送り、`surface_table`側の列のまま素直に実装した
- **`test/surface_table_test.exs`**: `repl`/`build_tool`列が常に存在し`nil`であることを検証する1件を追加（計8件）

`./test/run.sh`全30ファイル・0 failures（`surface_table_test.exs`8件、うち1件追加）。`lib/surface_table.exs`・`test/surface_table_test.exs`の変更、未コミット。

判定ロジック本体（§25.2〜25.4の内容をコードにする）と、それを`Evaluator`/`Repl.Launch`で実際に使って`xipe eval`の起動argvを合成する配線は、次回以降に持ち越し。

### 25.6 `nix develop`の起動コスト ── `nix print-dev-env`によるキャッシュ方式（追加co-design、設計のみ）

§25.2の「対象プロジェクトが`flake.nix`を持つ場合`nix develop <root> --command <argv>`でラップする」案について、cruxから「毎回`nix develop`を挟むと時間がかかりすぎるのでは」という指摘があり、この会話内で実測・検討した。

- **実測**（この環境、xipe_totec自身の`flake.nix`に対して）: `nix develop --command true`はコールドで1.76秒、直後の再実行（ウォーム）でも0.34秒かかった。`xipe eval`を編集→再評価のループで多用する使い方だと、起動のたびにこのコストを払うのは無視できない
- **対応方針**: 起動のたびに`nix develop`自体を挟むのをやめ、`nix print-dev-env --json`（`nix-direnv`が使っているのと同じ仕組み、対話シェルに入らず解決済みのビルド環境をJSONで取得できる）で環境変数（主に`PATH`）だけを**登録時に1回だけ**解決してキャッシュする:
  1. `xipe table generate`（またはプロジェクト登録時）に、対象の`flake.nix`がある場合`nix print-dev-env --json`を実行し、`variables`から`PATH`等をtables/project/<id>_<name>/配下へキャッシュ。`flake.nix`/`flake.lock`の内容ハッシュも併せて記録
  2. `xipe eval`時は現在のハッシュとキャッシュ側のハッシュを比較 ── 一致すればキャッシュした環境変数だけを使い、**`nix develop`自体は起動せず**対象REPLのバイナリを直接spawn（`erlexec`の`{:env, ...}`へ渡すだけ）。Elixir対象と同じほぼゼロオーバーヘッドの起動になる
  3. ハッシュが不一致のときだけ`nix print-dev-env`を再実行してキャッシュを更新
- **副次的な効果**: この方式では`nix develop`のshellHook自体を実行しない（環境変数だけを借りて直接バイナリを叩く）ため、§25.3で懸念していた「shellHookのechoバナーノイズが`ready_pattern`検出の邪魔をする」問題はNixに関する限り発生しなくなる。`XT_READY`固定マーカー案（§25.3）は、REPL自身の起動バナーが不安定な言語全般への一般的な頑健化として引き続き有効

実装（キャッシュファイルの形式、ハッシュ比較ロジック、`erlexec`への環境変数受け渡し）は未着手、§25.2〜25.4の判定ロジック本体と合わせて次回以降。

## 26. ハードコーディングをテーブル参照へ ── `Project.find_sheets/1`/`Runner.launch_opts_for/2`（2026-09-23、同セッション続き、未コミット）

§24.1で最初に立てた2段階計画（①テーブルを用意する、②決め打ちになっている箇所をテーブル参照に変える）のうち、cruxとの確認の末、後回しにしていた②へ着手した。cruxの整理: 「プレーンな（ビルドツールを使っていない）プロジェクトなら、ビルドツール判別の仕組み自体はまだ無くても問題ないはず」── 実際には既存コード（`launch_opts_for/2`）は元々`mix.exs`という1つのビルドツールだけは検出できていたので、範囲を「Elixir、かつ検出方法が既にコードとして存在するビルドツール（`mix`のみ）」に絞れば、§25.2〜25.4の一般化されたビルドツール優先順位表を待たずに、最小の改変でテーブル参照化とテストまで完了できると判断した。

### 26.1 `SurfaceTable`に実データを持たせる

- **`SurfaceTable.generate/2`**: `repl`/`build_tool`が常に`nil`のプレースホルダだったのをやめ、`language == "elixir"`の行にだけ実際の値を入れるようにした。`repl`は常に`"iex"`（ElixirのREPLは1つしかない）、`build_tool`は`dir`直下に`mix.exs`があれば`"mix"`、無ければ`nil`（`launch_opts_for/2`が元々インラインでやっていた`File.exists?`チェックをそのままここへ移動、二重管理にはしていない）。Elixir以外の言語・mix以外のビルドツール（stack/cabal、`flake.nix`によるnixラップ）は引き続き未検出のまま`nil`
- `repl`/`build_tool`は行ごとではなくプロジェクト単位の事実（同一プロジェクトの全elixir行で同じ値になる）という位置づけは§25.5のまま変更なし

### 26.2 既存モジュールをテーブル参照へ

- **`Project.find_sheets/1`**（`lib/project.exs`）: `Path.join(dir, "**/*.{ex,exs}")`という拡張子ハードコードをやめ、`SurfaceTable.generate(dir)`を呼んで`language == "elixir"`の行だけ抽出する形に変更。返り値の意味（`.ex`/`.exs`ファイルのdirからの相対パス、ソート済み）は変更していないので、両方のテストがそのままgreenだった（`test/project_test.exs`5件、無変更）
- **`Runner.launch_opts_for/2`**（`lib/runner.exs`）: `File.exists?(Path.join(root, "mix.exs"))`という直接チェックをやめ、新設の`elixir_build_tool/1`（`SurfaceTable.generate(root)`から`language == "elixir"`の行の`build_tool`を1つ取り出すだけ）を経由するように変更。分岐の中身（mix-modeなら`launch_opts: []`、そうでなければ`SourceSanitize.sanitize/2`を通したscripts-mode）は変更なし

### 26.3 テスト・実機確認

- **`test/surface_table_test.exs`**: プレースホルダ検証の1件を、実データを検証する3件に置き換え（mix.exs無しでの`repl="iex"`/`build_tool=nil`、mix.exsありでの`build_tool="mix"`、非elixir行は両方とも`nil`のまま）。計10件（1件純増）
- **`test/runner_test.exs`**: mix-modeパス（`root`に`mix.exs`がある場合に`launch_opts: []`＝`Repl.Launch`の既定`["iex","-S","mix"]`が使われること）を検証するテストを新規追加。**この分岐は今回の変更まで一度もテストが無かった**（scripts-modeパスのテストしか存在しなかった）ため、今回の`elixir_build_tool/1`導入の副産物としてテストカバレッジの穴も埋まった
- **実機確認**: `/tmp`にscripts-modeのサンプルプロジェクト（`test/fixtures/calc_sample/calc.exs`を複製、`mix.exs`無し）を作り、`xipe scan` → `effect/set` → `row/add` → `xipe do ... eval`を実行、`Calc.add(2, 3)`が`repr=exact`の`5`として正しく評価されることを確認した（`SurfaceTable`経由の新しい`find_sheets/1`/`launch_opts_for/2`を実際に通した、単体テストだけでなく本物の`iex`セッション起動を伴う確認）

`./test/run.sh`全30ファイル・0 failures（`surface_table_test.exs`10件・`runner_test.exs`15件）。`lib/surface_table.exs`・`lib/project.exs`・`lib/runner.exs`・`test/surface_table_test.exs`・`test/runner_test.exs`の変更、未コミット。

残っているハードコーディング（`Evaluator`の4モジュール既定値選択）は、§25で設計したビルドツール優先順位表・REPL判定が固まるまで引き続き着手できない。

## 27. 残タスクの整理（2026-09-23、cruxとの確認）

> 2026-09-23: この5項目は`課題.md`の「多言語対応」節へ移した。以下は当時の記録。

§21〜§26の一連の作業を振り返り、多言語対応に向けて残っているタスクをcruxと確認・整理した。5項目（2026-09-23、cruxとの文書レビューで5つ目を追加確認）:

1. **言語ごと・REPLごとのモジュール実装**: `lib/repl/eval/field_drip/elixir.exs`/`lib/repl/eval/scan/direct/iex.exs`に相当する新言語向けファイル一式（`launch`/`eval_template`/`scan`/`field_drip`の4つ、`document/repl-adapter-guide.md`参照）。候補4言語の下書きチェックリスト（同ガイド）はあるが実機未検証
2. **ビルドツール吸収層 + `Evaluator`の言語dispatch配線**: §25で設計した言語ごとのビルドツール優先順位表（stack/cabal/裸、`flake.nix`があれば`nix develop --command`ラップ、§25.6の`nix print-dev-env`キャッシュ方式）、`XT_READY`固定マーカーによる`ready_pattern`の頑健化（§25.3）。これと合わせて、`Evaluator`の`:launch_module`等4オプションを`surface_table`の言語判定に応じて実際に差し替える配線も同じタイミングで行う（今はElixir固定、`evaluator.exs`のmoduledoc自身が「dispatch先が無い」と明言している部分）。①で新言語のモジュールが最低1つ存在しないと、この配線を試す対象が無い点に注意（①が先行する）
3. **コマンドの追加（必要な分だけ）**: 設計済みでまだ配線していない`xipe table generate <path>`（§24.1、`SurfaceTable.generate/2`を呼ぶ）・`xipe choice project <path>`（§24.1・§24.6、`ProjectRegistry`で解決/登録し`info.json`の`project`欄を書く）
4. **`extensions/0`自己申告リファクタリング**（①〜③とは独立した片付けタスク、忘れないよう明記）: `SurfaceTable`内蔵の`@extension_language`ハードコードを、各`field_drip`モジュールが`extensions/0`のようなcallbackで自己申告する形に置き換える（§24.5・§25.4で保留と明記済み）。新言語を1つ足すだけなら忘れても動くが、放置すると新言語を足すたびに同じ二重管理パターンが積み重なるため、①（新言語モジュール実装）とは別の独立項目として扱うことをcruxと確認した
5. **`book.jsonl`の保存場所を`tables/project/<id>/`配下へ移す**（§24.1で最初から書かれていたが、実装（§24.2以降）では拾えておらず、cruxとの文書レビューで発覚）: 今の`book.jsonl`は`main.exs`の`@store_file`によりCWD相対（対象プロジェクト側、または`xipe`実行時のカレントディレクトリ）に置かれたまま。§24.1が最初に挙げた3つの理由（①対象プロジェクトを汚さない、②再開のたびの全走査を避ける、③削除時に対象プロジェクトへの書き込み権限を要さず、xipe_totec側だけで完結する）は`surface_table`だけでなく`book.jsonl`自体にも当てはまる。**③が`book.jsonl`固有の理由**（CWD相対のままだと、対象プロジェクトを削除・整理したくなったとき、そちらへの書き込み権限問題に巻き込まれる）。`main.exs`の`@store_file`・`Serve.Project`のstore_file周りが対象。**③（プロジェクトID解決）が先行する**必要がある（`tables/project/<id>/book.jsonl`という形にするなら、そのidをどう得るかが前提になるため）

依存関係のおおまかな順序: ③(コマンド配線・ID解決) → ⑤(book.jsonl移設) / ①(新言語モジュール) → ②(ビルドツール吸収層・dispatch配線)。④はどことも独立していつでも着手できる。

`document/repl-adapter-guide.md`にも、上記②④のうち`FieldDrip`のbehaviourへ将来追加される予定のcallback（`extensions/0`、ビルドツール判定の自己申告）について、**まだ実装されていない計画段階のものである**ことを明記する形で追記した（「多言語判定層（`tables/`/`info.json`）との関係」節）。実装済みの`XipeTotec.Info`/`XipeTotec.SurfaceTable`が今後どう関わってくるかも合わせて説明してある。

---

## 28. 旧`課題.mkd` ── Evaluator着手前の懸念A〜Hと回答（2026-09-17〜18、Eの2点を除き決定済み）

旧`document/課題.mkd`の全文。A〜Hは回答済み。ただしEの「実行中の要求を待たせるか拒否するか」「`eval/cancel`」は未決のまま`課題.md` §2へ移した（D・Fは§10で撤回、B1/Cの一部は§11.2で変更 ── 末尾の追記参照）。コード中の「Old.md §28 C」等はこの節のA〜Hを指す。

### 懸念（実装着手前の問い）

xipe_totecのOld.md§4.4/§6、core.exsの実装、xipe_totec_spec_v0.4.html§5.4/§12.2/§13.2を突き合わせて確認しました。実装着手前に潰しておきたい懸念を、ブロッキング度順にまとめます。

A. 「セッション」の正体は仕様で確定済み（安心材料）

心配していた「ユーザーの対話中iexに割り込む」形ではありませんでした。§12.2に「REPL起動: 既定の起動コマンド...終了方法」とあり、Xipe Totec自身が専用REPLプロセスを起動・終了まで面倒を見る前提です。つまりXipe Totec専有のプロセスなので、restart_sessionは文字通りkill&再起動で構わず、変数汚染や他セッションへの影響を心配する必要はありません。ここは確認事項というより前提整理です。

B. Core↔Evaluator契約に実装との食い違いが2点（Evaluator着手前に直す必要あり）

1. Plan.Entryにmodule/nameが無い。Old.mdの設計ではexpr: String.t()（呼び出し式そのもの）を持つ想定でしたが、実装済みのCore.build_entry/3はnode_idとargsしか返さず、しかもnode（Book.get(book,:nodes,call.node)で既に取得済み）からeffectしか使っていません。「Evaluatorはbookを知らない」原則を守りつつ§12.2「呼び出し式の組み立ては関数IDと引数の式から」を満たすには、build_entryがmodule/nameをentryにそのまま追加で持たせるだけ（Core自身は言語構文を知らないままでいい、単なるデータ受け渡し）の小さな修正が必要です。これが無いと今のままではEvaluatorは呼び出し式を組み立てられません。
2. evaluated_atの型が食い違っている。Old.mdはDateTime.t()ですが、core_test.exsの実フィクスチャは"2026-09-16T00:00:01Z"という文字列で、Core.apply_resultはこれを無変換でrowへ書き込み、後段のStore.appendがJSON.encode!します。Evaluatorが本物の%DateTime{}を返すと、そのままJSONエンコードに回った時に壊れる可能性があります。文字列（ISO8601）で統一すべきという理解でいいか確認したいです。

C. 未定義のまま残っている核心アルゴリズム

- repr: exact | binary | unsupportedの判定基準がどこにも書かれていません。 具体案:
  a. 値が pid/port/reference/fun を含む（再帰的にも）→ unsupported
  b. inspect(value) を Code.eval_string で評価し直して元の値と等しい → exact
  c. それ以外は :erlang.term_to_binary/1 で保存 → binary
     型の固定列挙より「実際に評価し直して試す」方式の方が保守が楽だと思いますが、確認したいです。
- compare（許容誤差込みの比較）の算出方法も未定（§12.2は「浮動小数点の許容誤差などを含む」としか言っていない）。

D. 分散Erlang接続まわりの具体設計

- ノード名・cookieの決め方（config側のrepl.elixir.commandだけでは--snameの値が決まらない）。
- timeout/max_heapの安全な実現方法 ── 対象ノードにXipe Totec独自のモジュールを事前ロードせずに済む案として、spawn_monitor + Process.flag(:max_heap_size, ...) + receive...afterを1つの文字列テンプレートにまとめ、Code.eval_stringでその場評価する方法を提案します（対象アプリのコードには一切触れない）。
- unsupportedな値は素の項としてXipe Totec側へ持ち帰らないべきという方針。ターゲットノード側の評価セッションに変数として留め置き（Code.eval_stringのbindingsを毎回引き継ぐ）、Xipe Totec側が持つのは表示用文字列だけにする ── pid/portなどは分散転送しても意味を保てないため。
- ノードダウン検知（Node.monitor）→ 残りエントリを一括:abortedにする、という既定動作は確認済みですが、これをどのプロセスが担当するかは未設計。

E. プロセス/GenServerのアーキテクチャ

eval/runはentry.limits.timeout×エントリ数だけ時間がかかりえます。現状のServe.Project.handle_call({:request,...})は同期処理なので、このままeval/runを実装すると他のクライアント要求まで長時間ブロックされます。EvaluatorをServe.Projectとは別プロセス（プロジェクトごとに1つ）にして非同期実行し、結果はnotify/rowChangedで順次配信する設計にすべきだと思いますが、これは前回のtezcatl側XipeConnのような非同期構成の再確認になるので、方針だけ先に合意しておきたいです。

F. セッション状態の蓄積（軽微だが認識しておきたい）

writes効果の計算行がunsupportedとしてセッション変数に束縛された後、別passで再evalされると古い束縛名がターゲットノードの評価スコープに残り続けます（restart_sessionしない限り解消されない）。実害は小さいですが長時間運用での資源蓄積として一応記録しておきたいです。

G. テスト戦略

他の全モジュールはExUnitだけで完結していますが、Evaluatorは本物の2ノード構成が要ります。判定ロジック（repr判定・compare・テンプレート文字列組み立て・binding台帳）を純粋関数として切り出し、Node.connect/:erpc.callを扱う接続層と分離すれば、既存の高速スイートのカバー範囲を最大化できます。2ノード実機テストはtest/run.shとは別スクリプトに隔離するのが良さそうです。

H. スコープ確認

- §13章（Rustler等の境界規則）は今回のEvaluator着手範囲に含めない、という理解でいいですか（仕様上も独立部品と明記）。
- v0.4§12.2の「プロンプト形式」の項目は、Elixir実装が分散BEAM接続（Old.md§6の方針）で行く以上、実質不要になるという理解でいいですか。


### 項目ごとに回答

#### A. セッションの前提

その理解で正しいです。Xipe Totec が起動・終了まで管理する専用プロセスなので、再起動は kill して起こし直すだけで構いません。

一つだけ付け加えると、再起動でセッション変数が消えるのは仕様上の想定内で、それに依存していた計算行は `lost` になります（6.3節）。再起動の副作用として「行が lost になる」ことは、利用者に通知する必要があります。

#### B. Core↔Evaluator の契約

**B1：module/name を Entry に持たせる**

賛成です。Core は言語構文を知らないまま、識別子をそのまま渡すだけなので、原則は崩れません。`module`、`name`、`arity` の3つを入れてください。

ただし、これに関連して私の以前の提案に誤りがありました。`expr`（組み立て済みの呼び出し式）を Core が作る設計は成立しません。理由は2つあります。

1. 呼び出し式の組み立ては言語構文の話なので、Core の担当ではない（B1 の指摘と同じ理由）。
2. 参照先が unsupported かつ pure の場合、「参照先の呼び出し式を再帰的に埋め込む」処理も言語構文の組み立てになる。

正しい分担は次のとおりです。

- **Core**：`args` の中の `⟦id⟧` を、参照先の正規形の文字列に置き換える（単なる文字列置換なので言語非依存）。置き換えられない参照は、種類を示すデータとして残す。
- **REPLアダプタ**：`module`/`name`/`args` から呼び出し式を組み立てる。入れ子の呼び出しもここで作る。

```elixir
%Plan.Entry{
  call_id: id, node_id: id,
  module: String.t(), name: String.t(), arity: non_neg_integer(),
  args: [String.t()],        # 埋め込み可能な参照は置換済み、それ以外はプレースホルダ
  inputs: [
    {:inline_call, %{placeholder: String.t(), module: ..., name: ..., args: [...]}}  # unsupported + pure
    | {:binding, %{placeholder: String.t(), var: atom(), gen: non_neg_integer()}}    # unsupported + 非pure
    | {:in_plan, %{placeholder: String.t(), ref: call_id, var: atom()}}              # 同一計画内
  ],
  bind_as: atom() | nil,
  basis: {:text, String.t()} | {:bin, binary()} | :none,
  limits: %{timeout: pos_integer(), max_heap_words: pos_integer()}
}
```

`inline_call` は入れ子になりうるので、再帰的な構造にしてください。

**B2：時刻は ISO8601 の文字列で統一**

その理解で正しいです。原則として、Core に入る行の値は JSON にそのまま載る型（文字列・数値・真偽値・null・それらの map とリスト）に限ります。`%DateTime{}` は Evaluator と Core の境界で `DateTime.to_iso8601/1` に通してください。Core 側にその型の検査を1つ置いておくと、以後の混入を防げます。

#### C. 未定義のアルゴリズム

**repr の判定：提案の a → b → c の順で正しい**

型の列挙ではなく実際に評価し直す方式に賛成です。これは仕様 12.3節の往復検査そのものです。ただし (a) を先に置く必要があります。`:erlang.term_to_binary/1` は pid や fun も一応シリアライズできてしまい、復元しても意味を持たないためです。型の走査で先に弾いてください。

実装で確実に踏む点が3つあります。

1. **inspect の省略**：既定では要素数 50 で `...` に切られます。`inspect(value, limit: :infinity, printable_limit: :infinity)` を使ってください。
2. **評価は対象ノード側で行う**：正規形の文字列に対象プロジェクトの構造体が含まれるので、Xipe Totec 側のノードでは評価できません。判定そのものを対象ノードで行い、結果（repr、表示文字列、型名、必要ならバイナリ）だけを持ち帰ります。D の方針と一致します。
3. **マップのキー順序**：キーが32個を超えるマップの `inspect` は順序が安定しません。同じ値でも正規形の文字列が変わり、compare が理由なく changed になります。正規形を作る際にキーを並べ替えるか、compare を文字列ではなく項で行うかのどちらかが必要です。

**compare：対象ノード側で項として比較する**

文字列比較では許容誤差を扱えないので、次の形を推奨します。

- 両側を対象ノードで項に戻す（exact なら評価、binary なら `:erlang.binary_to_term/1`）。
- 構造を再帰的に走査し、浮動小数点だけ相対誤差と絶対誤差で比較する。
- 誤差の値は設定パラメータにする（`compare.float_rel_tol`、`compare.float_abs_tol`）。
- 片側でも unsupported なら `skipped`。

#### D. 分散接続

**ノード名と cookie**

Xipe Totec 側で生成し、起動コマンドの雛形に埋め込む形がよいと思います。

- 自ノード：`xipe_<project-id 短縮>`、対象ノード：`xipe_tgt_<project-id 短縮>`。
- cookie はプロジェクトごとにランダム生成し、設定ファイルではなく実行時の状態として持つ。
- `repl.elixir.command` に `{sname}` と `{cookie}` のプレースホルダを許可する。既定値は `iex --sname {sname} --cookie {cookie} -S mix`。非 mix 構成では利用者がここを書き換えます。
- ループバックに限定するため、起動時に `-kernel inet_dist_use_interface '{127,0,0,1}'` を渡し、`ERL_EPMD_ADDRESS=127.0.0.1` を環境変数に入れてください。仕様 16.1節のローカルホスト限定を、分散接続にも適用する形です。

**timeout と max_heap**

提案の方式で問題ありません。補足を3点。

- `:erpc.call(node, Code, :eval_string, [template, bindings], timeout)` の形にすれば、無名関数を転送せずに済みます。無名関数の転送は、対象ノードに同じモジュールが必要になるため避けるべきです。
- `Process.flag(:max_heap_size, ...)` のサイズは**バイトではなくワード**です。設定値の単位を明示してください（上の Entry では `max_heap_words` にしています）。
- 内側の `receive ... after` で時間切れにしたら、`Process.exit(pid, :kill)` で確実に落としてください。`after` を抜けるだけでは、暴走したプロセスは走り続けます。外側の `:erpc.call` の timeout は、内側が効かなかった場合の保険です。

**unsupported な値を持ち帰らない方針**

賛成ですが、実現方法は一段変える必要があります。`Code.eval_string` が返す binding を Xipe Totec 側で保持すると、まさに持ち帰りたくない項（pid、fun）が転送されてしまいます。

代わりに、対象ノード側に束縛を保持する小さなプロセスを1つ置くのが確実です。

- セッション開始時に、`Code.eval_string` で `spawn` と `register` を行い、map を持つ受信ループを立てる（対象アプリのコードには触れません）。
- 評価の雛形の中で、そのプロセスから変数を取り出し、必要なら結果を格納する。
- Xipe Totec 側が持つのは、変数名・世代番号・表示文字列だけ。

この形なら、F の蓄積問題も、不要になった束縛を消す要求を送るだけで解決します。

**ノードダウンの検知**

E で分ける Evaluator プロセス（プロジェクトごとに1つ）が `:net_kernel.monitor_nodes(true)` で監視し、残りのエントリを `:aborted` にして結果を返す担当にするのが自然です。セッションの世代番号もこのプロセスが持ちます。

#### E. プロセス構成

その方針で合意でよいと思います。

- Evaluator をプロジェクトごとに別プロセスにし、`eval/run` は pass_id を返してすぐ戻る。
- 結果は `notify/rowChanged` で順次配信する。通知に pass_id を含めれば、クライアントは自分が投げた再計算の進行を追えます。
- Book の更新は `Serve.Project` への cast で行い、Book を触るのは引き続き1プロセスだけに保つ。
- 同じプロジェクトで再計算が重ならないよう、pass は直列に実行する。実行中の要求は待たせるか拒否するかを決めてください。
- `eval/cancel` を用意しておくと、長い再計算を止められます。CLI の `xipe eval` は、購読して完了まで待つ形になります。

#### F. セッション状態の蓄積

D の束縛保持プロセスを使う前提なら、次の扱いで足ります。

- 束縛の台帳（call_id → 変数名・世代）を Evaluator が持つ。
- 同じ call_id を再評価して新しい束縛を作ったら、古い変数を消す要求を送る。
- 台帳の件数に上限を設け、超えたらセッションを再起動する（`eval.max_bindings`）。

#### G. テスト戦略

賛成です。純粋関数として切り出す対象は、repr の判定規則（型の走査の部分）、比較の走査、雛形の組み立て、台帳の管理、`inputs` の解決順序あたりになります。

あわせて、Evaluator の差し替え可能な偽物（決められた結果を返すもの）を用意しておくと、`plan_recalc` → `apply_results` の往復を ExUnit だけで通しで確かめられます。2ノードの実機テストは別スクリプトに隔離する方針で問題ありません。

#### H. スコープ

- **13章（境界規則）**：今回の範囲外で正しいです。仕様の段階計画でも v0.5 に置いています。
- **プロンプト形式**：Elixir では不要という理解で正しいです。ただしアダプタの項目自体は残してください。GHCi や utop は標準入出力の読み取りになるため、他言語で必要になります。Elixir のアダプタでは空にしておく形です。

#### 進め方

B → C → D → E の順が依存関係に沿っています。B は契約の修正なので最初、C は D の中で対象ノード側に実装することになるので次、D が最も大きく、E はその外側の器です。F・G・H は上の回答で確定として構いません。

---

#### 追記（2026-09-18）: D・F を含む分散Erlang前提の撤回

上記 D（分散接続）・F（セッション状態の蓄積、束縛保持プロセス前提）は、この後の実装過程での co-design（2026-09-18）で**撤回**されました。元々「REPLへ手で式を打ち込んで確認する作業のショートカット」として構想されたツールである以上、評価の経路も人間がREPLの端末に対して行う操作をそのまま自動化する方が筋が通る、という判断です（crux）。

- 分散ノード名・cookie・loopback制限・`Node.connect`・`:erpc.call`は使わない
- 評価は「起動したiexの標準入力へテキストとして式を書き込み、標準出力の印字を読む」経路に一本化
- D で検討していた「対象ノード側の束縛保持プロセス」（F の蓄積問題への対処含む）は不要 ── iexセッション自身の変数束縛をそのまま使い回せる
- C（repr/compare判定ロジック自体、往復検査の方式）・E（プロセス構成の大枠）・G（テスト戦略の分離方針）・H（スコープ）は撤回対象外、そのまま有効

現在の決定・設計の詳細は `Old.md` 10章を参照。この文書（A〜Hの元のやり取り）は当時の検討過程の記録として残す。

---

#### 追記（2026-09-22）: B1の`basis`型・Cの誤差パラメータ化も、実装過程で当初案から変わった

上の2026-09-18追記は「D・Fの撤回」にしか触れていないが、撤回対象外とされたB・Cについても、その後の実装で当初案から変わった点が2つある。この文書は記録として当初案のまま残すが、実装が実際にどうなったかをここに追記しておく。

- **B1の`basis`型**: 上記コードブロックの`basis: {:text, String.t()} | {:bin, binary()} | :none`は当初案のまま。実装（§11.2、2026-09-18）では`{:exact, String.t()} | {:binary, String.t()} | :none`になっている（タグ名が`:text`→`:exact`、`:bin`→`:binary`に変わり、`:bin`の中身も生の`binary()`ではなくbase64文字列）。`repr`/`compare`列も当初案は言及が曖昧だが、実装では終始文字列（atomではない）で統一されている。
- **Cの「誤差の値は設定パラメータにする」**: 実装では意図的に縮小された（§11.2）。設定ファイル読み込みの仕組み自体がこのコードベースに存在しないため、`compare.float_rel_tol`/`compare.float_abs_tol`のような外部設定化は見送り、固定のモジュール属性（`lib/repl/eval_template.exs`の`@default_float_rel_tol`/`@default_float_abs_tol`、共に`1.0e-9`）のまま据え置いている。C自身の判定ロジック（対象ノード側で項として比較・浮動小数点だけ相対/絶対誤差・片側unsupportedならskipped）はそのまま実装された。

なお「詳細はOld.md 10章を参照」という上記追記のポインタも、実際には内容が`Old.md`の§10〜§14に分散している（10章単独ではない）。参照する際はその範囲を見ること。


## 29. 課題.mdの〔要判断〕2件の扱い（2026-09-23、crux）

外部レビューで`課題.md`への移行漏れ候補として挙がった項目のうち2件を、cruxが判断した。

- **テーブルから実行リストを自動生成する構想（§21.3）**: 撤回しない。保留中の trace 機能（§8・Tier5）に着手するときに扱う対象として残す。§21.3の時点で本来そう書いておくべきだった（crux）。`課題.md`では Scanner の言語非依存化（⑥）から外し、`trace/*`の項目の下へ移した
- **`repl`/`build_tool`の置き場所（§25.5）**: `surface_table`の全行に同じ値を複製するいまの形は仮のもの。ビルドツール判定は後で作り、そのときに置き場所も決め直す（crux）。`課題.md`では②（ビルドツール吸収層）の一部とした

## 30. `embody` ── 見えない値にもDBへ入る形を与える、対象プロジェクト側の固定モジュール（2026-09-24、`~/my_app/tezcatl`セッションと`~/my_app/xipe_totec`セッションでのco-design、実装なし・仕様のみ）

§27①（新言語向けモジュール実装）の着手前に、`repl-adapter-guide.md`のチェックリスト項目8（往復検査の機構）がHaskell/OCamlで「構造的な壁」と書かれたまま残っていた件を詰めた。最初の案（30.2）は外部レビューでHaskellでは成立しないと分かり、同日中に30.3の形へ組み直した。xipe_totec本体（`Core`/`repr`語彙/4モジュール契約）には変更を加えない方針は、最初の案から変わっていない。

### 30.1 発端

**出発点（crux）**: GHCiで見えないもの（無限構造、`Show`の無い値）は、普段は誰も見ようとしない。しかしxipe_totecは、**見ない値でもDB（`book.jsonl`）へ入れるために何かしらの形にしなければならない**。また、GHCiに式を通したのに返ってこない、というパターンがあると聞いており、それを必ず返ってくる形に変える仕組みが要る。

これを具体化すると、次の4点になる。

1. **`repr`の3語彙は`Core`の持ち物で、アダプタ側では埋められない**: `repr=exact|binary|unsupported`はアダプタが印字するが、読むのは`Core`（`resolve_ref/4`の`ref_call.repr in ["exact","binary"]`、`build_entry/3`の`basis`決定）。Haskellでは`deriving (Show)`はほぼ全型にあるが`Read`はまれで、**表示はできるが文字列から値を戻せない**値が主流になる。これを`exact`と名乗らせると、`resolve_ref/4`が`show`の出力を呼び出し式へリテラルとして埋め込みにいくが、それがHaskellのソースとして有効である保証は無い（`Map`の`fromList [...]`表記など）。かといって`unsupported`にすると`basis`が`:none`になり、`compare`が効かなくなる（利用者が`set_prev`で期待値を入れても、Haskellではその文字列を戻すのに結局`Read`が要る）
2. **遅延評価と無限構造**: `f x = [1..]`のように、後段で`takeWhile`する前提の純粋関数はHaskellでは普通。`show`をかけると出力が止まらない
3. **結果側に書くスロットが計算行に無い**: 計算行の形は`Module.f(args)`に固定されている（§16.1）
4. **Lisp系では踏まない**: Clojure（`pr-str`/`read-string`）・Racket（`~s`/`read`）は往復検査を標準で持つ。**着手順をClojure/Racketから始めると1.が見えないまま進み、Haskellの最初の値で当たる**

### 30.2 最初の案と、退けた理由

**最初の案（3ファイル構成）**: xipe_totec側が配布する固定コードを対象プロジェクトに同居させる。

| ファイル | 役割 |
|---|---|
| `embody.hs` | `embody.yaml`を読み、そこに書かれた関数を適用して、無限構造なら`take 100`で切り出して返す |
| `embody.yaml` | 観測対象のファイルパスと関数名（形式はHaskellの`Read`形式でもよい） |
| `write.hs` | REPLからファイルパスと関数名を渡されたとき、`embody.yaml`へ書き込む |

「指定した関数に依存するIOとして存在し、その依存先を外から書き換えられる」形にしておけばxipe_totecに乗せられる、という発想（crux）。

**退けた理由（外部レビュー、2026-09-24）**: 書き込み（`write.hs`）は問題ない。成立しないのは**読み出して呼ぶ**段階。

- コンパイル後のHaskellには、`"Target.f"`という文字列に対応する関数を探す表が無い。関数を呼べるのは、ソースに`import Target`と`Target.f`が書いてあるときだけで、それは固定コードには書けない
- 仮に引けても、`embody.hs`をコンパイルする時点では`g`の型が決まらない
- 回避するにはGHC APIか`hint`パッケージで実行時に文字列を式として解釈させる必要があり、「外部依存ゼロ」の狙いとぶつかる
- 動的に呼ぶ以上、ソース上に呼び出しが無いので`embody→対象`のエッジは`callHierarchy`にも出ず、`dep_hash`による変更追随も効かない

ただし、**文字列を式として解釈する役はGHCi自身が既に担っている**。xipe_totecは呼び出し式をテキストとしてREPLへ書き込んでいるので、どの関数を包むかはその1行に書けばよく、関数名は計算行（`book.jsonl`）として既に永続化されている。これで`embody.yaml`と`write.hs`は不要になった。ファイル方式にこだわるなら、`write.hs`が書き出すものをデータではなくHaskellのソース（`import qualified Target; probe_f = Target.f`）にすれば成り立つが、ビルド構成への登録・`:reload`・対象側の改名での巻き添えが増え、下の「xipe_totecがコードを生成する」案に近づく。

**最初の案の検討中に退けていたもの**（引き続き退ける）:

- **4つ目の`repr`値を新設する**（「表示はできる・テキストとしては比較できる・再埋め込みはできない」）: `resolve_ref/4`・`build_entry/3`・仕様の「片側でもunsupportedならskipped」規則に触る。30.3の形なら`Core`を触らずに済む
- **`calls`テーブルに結果側テンプレート列を足す**（`take 100 (%)`のような形を`EvalTemplate`が埋める）: `args`とは別に第二の表現が生まれ、`Core`と`EvalTemplate`の両方に手が入る
- **xipe_totecが`embody.hs`を対話経由で生成・追記する**: 固定コードでなくなり、対象ごとに生成物の管理が要る
- **観測行を消し、その出力を元の対象の行にマージする**: 元の行に載る値が実際には切り出し後の値になり、カード上で区別がつかなくなる（`compare=same`が「先頭100要素が変わっていない」の意味に縮む）。表示の畳み込みはクライアントの責務（P7。§20で人間向けのCLI出力整形を撤回したのと同じ判断）

### 30.3 決定: `embody`は汎用関数だけを持つ固定モジュール

`embody.hs`は`base`だけに依存し、**対象の関数を一切知らない**汎用関数の集まりにする。どの関数に適用するかは、xipe_totecがGHCiへ送る1行が決める。

```haskell
module Embody where
import System.Timeout (timeout)
import Control.Exception (evaluate, try, SomeException)
import System.IO (hFlush, stdout)

-- どんな値でも、有限のdisplay文字列にしてマーカー付きで印字する
observe :: Show a => String -> Int -> a -> IO ()
observe callId usec v = do
  r <- timeout usec (try (evaluate (forceAll (take limit (show v)))))
  case r of
    Nothing        -> putStrLn ("XT_ERROR_" ++ callId ++ " timeout")
    Just (Left e)  -> putStrLn ("XT_ERROR_" ++ callId ++ " crash " ++ oneLine (show (e :: SomeException)))
    Just (Right s) -> mapM_ putStrLn ["XT_BEGIN_" ++ callId, "repr=unsupported", "display=" ++ oneLine s, "XT_END_" ++ callId]
  hFlush stdout
  where forceAll s = length s `seq` s
        oneLine = concatMap (\c -> if c == '\n' then "\\n" else [c])
        limit = 2000

-- 比較したいときに観測行として使う
cut :: [a] -> [a]
cut = take 100
```

（コードは形を示すためのもので、実装時に`repl-adapter-guide.md`の`field_drip`の書式・`compare`判定と合わせて書き直す）

**1. 値ではなく`show`の出力文字列を切る**: `take 100`を値にかけるには型の知識（リストかどうか）が要り、関数ごとの情報が必要になる。`show`の出力を切れば型を問わない。Haskellの`show`は遅延評価されるので、`take 2000 (show [1..])`は無限リストでも無限の木でも先頭だけ作って止まる。関数ごとの情報が要らないので、固定コードの中に丸ごと書ける。

**2. DBに入る形**: DB側には既に「形だけ入れる」枠がある（`repr=unsupported`と`display`の組。Elixirでもpidやfunはこの形で保存している）。したがって`Core`・DBに新しい語彙は要らず、Haskell側の責務は「どんな値でも有限の`display`を1つ作って返すこと」に絞られる。

| 値の種類 | DBに入る形 |
|---|---|
| `Show`と`Read`があり有限 | `repr=exact`（今までどおり、比較もできる） |
| `Show`だけある（`Read`が無い、無限など） | `repr=unsupported`、`display` = `show`の先頭N文字 |
| `Show`が無い（関数、IOなど） | `repr=unsupported`、`display` = 型 |
| 最初の1文字が出る前に止まらない | `timeout` → `XT_ERROR`（切り方では救えない） |

`Show`が無い値の`display`を型にするのは、「Haskellのエンジニアが見るのは値ではなく型」という最初の案の判断（crux）を引き継いでいる。

**3. 比較したい行にだけ観測行を足す**: `unsupported`のままでは`compare`が効かない。変わったかどうかを追いたい行Bにだけ、`Embody.cut(⟦c_B⟧)`という計算行を足す。`take`した有限リストには`Read`があるので`exact`になり、既存の項比較（§11.2）がそのまま働く。30.1の3.（結果側のスロットが無い）は、§16.1が想定する「計算行を`⟦id⟧`で繋ぐ」パターンで解ける。

**観測行は、連鎖の横に生やす観測点**（最初の案から継続）: `A→B→C`という依存の連鎖の任意の地点Bから、`B→観測行`を横に足す。

- `C`が参照するのは`B`であって観測行ではないため、`resolve_ref/4`が切り出し後の値を元の値として埋め込む事故は構造的に起きない
- `B`の行自体は何も変わらない
- `B`から観測行へのエッジは、`:links`ではなく計算行どうしの参照グラフ（`⟦⟧`）に載る。`B`が変われば`affected_set`が下流として拾うので、Scannerの多言語化（課題⑥）を待たずに動く
- 観測が済めば観測行は消してよく、消しても`A→B→C`は無傷
- **観測行は下流から参照しない**。後から誰かが参照を繋いだ場合、それが意図的な違反だと分かるように明文化しておく

**4. 同居**: `cut`を計算行として使うには、`row/add`の都合で`Embody.cut`が`:nodes`に載っている必要がある（`dispatch.exs`の`row/add`は実在するnode idを要求する）。したがって`embody.hs`は対象プロジェクトに同居させ、スキャン対象（`surface_table`）とGHCiのロード対象に入れる。Haskellではビルド構成（`.cabal`の`other-modules`等）への登録も要る。一方、`observe`はテンプレートの中からしか使わないのでnodeである必要は無い。

**P8との関係**: `embody`が無くても、`Show`と`Read`を持つ有限の値は普通に評価できる。位置づけは「無いと動かない」ではなく「無いとHaskellでDBに入れられる範囲が狭い」。

### 30.4 GHCiで「返ってこない」ときの原因と、`observe`で防げるか

| 原因 | 防げるか |
|---|---|
| 無限構造・停止しない計算 | ○ `timeout`と、切った文字列を最後まで評価しきる`length`。遅延のまま印字を始めると`XT_BEGIN`の後に出力が流れ続け、`XT_END`まで届かない |
| パイプ接続時の出力のバッファリング | ○ `hFlush stdout`。GHCi自身が対話用にバッファを切っている可能性もあり、**実害があるかは要実機確認**。`hFlush`は安い保険として入れる |
| メモリを確保しない密なループ | × GHCでは、コンパイル済みのこの種のループを`timeout`で割り込めないことがある。外側の固定デッドライン → SIGINTで止める（GHCiはCtrl-Cでプロンプトに戻れるので`interruptible: true`）。§23で実機未確認のまま残っている経路の出番になる |
| 型エラー・`Show`インスタンスが無い | × `observe`の行自体が型検査を通らず、エラー文が出るだけでマーカーが出ない（§22のHaskell版）。30.5の1. |
| 対象関数が標準入力を読む（`getLine`等） | × xipe_totecが後から送る入力を吸い込む。`reads`に分類された関数でも起こりうる |

### 30.5 未決・要実機確認

1. **30.3の表の段の選び方**: Haskellでは「`Read`があるか」「`Show`があるか」は型検査の時点で決まり、実行時には問えない。候補は、GHCiで`:set -fdefer-type-errors`を有効にし、インスタンス不足を実行時例外に変えてから、`exact`用 → `observe` → 型表示（`Data.Typeable.typeOf`。現代のGHCでは`Typeable`が全型に自動で付く）の順に試す汎用関数を1行で送る案。Elixirの`repr`判定のa→b→c（§28 C）と同じ並びになり、マーカーも増えない。値は`let xt_<id> = ...`で1回だけ束縛し、3段で共有する。**GHCiの挙動は未検証**。成り立たなければ、GHCiの`:type`を別の行で送る案になるが、その場合は1 entry 1往復の`Evaluator`の契約や「変えてはいけない」マーカーの一覧（`repl-adapter-guide.md`）に触る
2. **IOを返す関数**: `observe`は純粋な値を取る。`reads`に分類されたIO関数には、`>>=`でつなぐ`observeIO`のような版が要る
3. **`xipe embody`コマンド**: 「Bに観測行を足すか」を確認し、`row/add`で`Embody.cut(⟦c_B⟧)`を作る対話。`Dialogue.Depends`と同型の2つ目の対話プログラムになる見込み。`embody.hs`の配置自体を手伝うなら、§17の`10`（対話継続かつREPL経由、これまで未使用だった枠）に当たる。WSの応答封筒では`via_repl`の向きが§17の表と逆である点に注意（§17.2）
4. **observe対象がexportされていない場合**: GHCiへ送る1行が`Target.f`を名指しする以上、対象関数がモジュール外から見えている必要がある。Elixirの`defp`（§16.1）と同じ制約だが、Haskellではexport listを絞るのが普通なので遭遇率は高い。GHCiで`:load *Target`（`*`付き）にすれば非exportの関数も見えるので、scripts-mode相当ではこれで回避できる可能性がある（要確認）
5. **`embody.hs`のコンパイル失敗の巻き添え**: 30.3では`embody.hs`は`base`にしか依存しないため、対象の改名で壊れることは無くなった（最初の案の懸念が解消）。残るのはGHC版の差だけ

### 30.6 他言語への一般化

「対象プロジェクト側に置く、xipe_totecのための固定モジュール」という**枠**は4言語すべてに置けるが、**中身の目的は言語ごとに違う**（最初の案から継続）:

| 言語 | `embody`に書くことになるもの |
|---|---|
| Haskell | `observe`（`show`の切り出し・時間切れ・型表示）＋`cut` |
| Clojure | 切り出し（lazy seq、`(range)`等）。往復検査は`pr-str`/`read-string`があるので不要 |
| Racket | 正格かつ`~s`/`read`があるため、枠はほぼ空でよい |
| OCaml | 切り出しは不要（正格）。**型ごとの`to_string`/`of_string`を集める場所**として要る ── 目的が正反対 |

枠が空でよい言語があるため、**これは算出プログラムの5つ目のモジュールではない**。「算出プログラム／汎用実行層」という既存の2分に、**対象プロジェクト側の規約**という第3のカテゴリが加わる。`repl-adapter-guide.md`が冒頭で「新しい言語を足すときは算出プログラム側だけを書けばよい」と断言している箇所は、このカテゴリを含む形に書き換えが要る。チェックリスト項目8も「往復検査に相当する機構があるか」に加えて「無い場合、`embody`に何を書けば埋まるか」まで問う形にし、§23で項目10（SIGINT）を閉じたのと同じ形で閉じる。候補4言語の「構造的な壁」も「`embody`で埋める、中身はこれ」へ書き換える。実装コスト順はClojure/Racket → Haskell → OCamlになる（OCamlは`ppx_deriving`等の外部前処理が要り、Haskellの`deriving`一語ほど安くない）。

**名前**: `embody`は、Haskellの標準的な語彙にもcabal/stackの予約名にも無く、対象プロジェクトに同居させても邪魔にならない。意味としても、見えない値に一時的に体を与えてDBに入れ、済んだら剥がせるという性質に合っている（crux）。

## 31. 基本の流れの点検 ── プロジェクト選択とプロジェクトごとの Book（§27③⑤ の実装、2026-09-24、`~/my_app/xipe_totec`セッション）

cruxの問い「プロジェクトを決める → テーブルを作る → コマンド → テーブルから対応するREPLを通しカードにする、という基本の使い方で抜けているものはあるか」を受け、小さなElixirプロジェクト2つで実際にCLIを通して点検した。

### 31.1 見つかった抜け

1. **`book.jsonl`がプロジェクト間で共有されていて、切り替えると前のプロジェクトが壊れる（実機で確認）**: `book.jsonl`はCWD相対の1ファイルで、`xipe`関数は常に`$XIPE_TOTEC_DIR`へ`cd`していたため、実質xipe_totecのディレクトリに1つだけあった。Aをスキャンした後にBをスキャンすると、Aのノードはすべて墓標になった（スキャンは「今回見つからなかったもの」を消すため）。Aに付けた`effect/set`や計算行は存在しないノードを指す状態で残り、Aを再スキャンするとノードには新しいIDが振られて分類は戻らない。さらにシートIDは相対パスで照合するため、AとBの`m.exs`が同じシートIDを使い回していた。§27⑤は「後回しにできる整理」ではなく、複数プロジェクトを扱う前提だった
2. **コマンドが対象プロジェクトを知らない**: `<dir>`省略時は`.`になり、`cd`のせいでxipe_totec自身のディレクトリが対象になっていた。相対パスの引数もxipe_totec基準で解釈されていた
3. **1引数の関数の計算行をCLIから作れない**（§8.1の既知の件）。回避しようと`args=3,`と書くと、`row/add`がarityを検査しないため`["3", ""]`という2引数の行が黙って作られる（新規）
4. **`effect/set`を忘れると`xipe eval`が黙って何もしない**（新規）: 未分類の行は計画から外される（P1どおり）が、出力は`1 command(s), 1 ok`だけ
5. **surface table が保存されない**（`SurfaceTable.save`がどこからも呼ばれていなかった）

1・2・5を今回直し、3・4は`課題.md`へ載せた。

### 31.2 実装

- **`XipeTotec.Workspace`（`lib/workspace.exs`、新規）**: どのプロジェクトを対象にするかの解決をここに集めた。`choose/2`（`xipe choice project`）、`generate_table/2`（`xipe table generate`）、`resolve/2`（他の全コマンド）、`project/2`（idから`%{id, path, dir, store_file, table_file}`）
- **プロジェクトごとのファイル**: `tables/project/<id>_<name>/`の下に`project.json`（照合キー、§24.6）・`table`（surface table）・`book.jsonl`（Book）。対象プロジェクトのディレクトリには何も書かない（§24.1の3つの理由がそのまま当てはまる）
- **`resolve/2`の規則**: `<dir>`を渡した場合は登録済みでなければエラー（`scan`や`eval`で暗黙に登録しない。プロジェクトを選ぶのは独立した操作、`xipe reflesh`と同じ考え方）。`<dir>`省略時は`info.json`の`project`（id）。未選択ならエラーで、`xipe choice project`を案内する
- **`choose/2`の規則**: 未登録なら登録して表を作る。登録済みで表が無ければ表だけ作る。登録済みで表があればそのまま（作り直しは`xipe table generate`の役目）。最後に`info.json`の`project`を書く。§24.1の設計どおり
- **`ProjectRegistry.lookup/2`（新規）**: idから`{dir, path}`を引く、`find/2`の逆
- **`main.exs`**: `choice project`/`table generate`を追加し、`scan`/`show`/`eval`/`do`/`dialogue depends`/`serve`をすべて`Workspace.resolve/2`経由にした。`show`も`[<dir>]`を取るようにした。`xipe eval`は先頭の引数が既存のディレクトリなら`<dir>`、そうでなければcall idとして扱う
- **`flake.nix`の`xipe`関数から`cd`を外した**: xipe_totec自身が読み書きするファイルはすべて`__DIR__`基準になったので不要。相対パスの引数が呼び出した側のCWDから解釈されるようになった
- **`.gitignore`（xipe_totec直下、新規）**: `/tables/`を除外。絶対パスを含むマシンごとのデータのため
- **ついでに直したもの**: `xipe help`の使用例`effect/set id=$0.id`は誤り（`$0.id`は計算行のIDで、`effect/set`はノードのIDを取る）。`id=n1`に直した

**やっていないこと**: 保存した`table`はまだ誰も読まない。`Project.find_sheets/1`・`Runner.launch_opts_for/2`は今もその場で`SurfaceTable.generate/2`を呼ぶ。読む側へ切り替えるのは②（ビルドツール判定・nix環境のキャッシュ）のときにする。既存の`book.jsonl`の移行は、移すべきファイルが無かったので行っていない。

### 31.3 テスト・実機確認

- `test/workspace_test.exs`（新規、8件）: `lookup/2`、未選択・未登録のエラー、新規登録と選択、登録済みへの切り替え、プロジェクトごとの別ファイル、表の再生成でのid維持、`info.json`の他の欄を壊さないこと
- 実機: 相対パスで`choice project ./a` → `scan` → `row/add`＋`effect/set`＋`eval`（`5`、`repr=exact`）→ `choice project ./b` → `scan` → `choice project ./a` → `show`で、Aのノード・`effect=pure`・リンクが残っていることを確認。未選択時・未登録ディレクトリ指定時のエラー文言も確認。確認後、`tables/`と`info.json`は元に戻した
- `./test/run.sh`全31ファイル・273件、0 failures

## 32. `xipe do`のリスト記法`[...]`と、`row/add`のノード・arity検査（2026-09-24、`~/my_app/xipe_totec`セッション）

§31で見つけた抜け3（1引数の関数の計算行をCLIから作れない、`args=3,`が黙って2引数の行になる）への対応。

### 32.1 決定

- **`[...]`は常にリスト**（crux承認、3案から選択）: `[]`は空、`[10]`は1要素、`[1,2]`は2要素。囲まずにカンマを含む値（`args=1,2`）も従来どおりリストで、それ以外は文字列。退けた案は、キーを繰り返す`args[]=10`（長くなる）と、JSONをそのまま書く`args='["10"]'`（シェルのクォートが面倒）
- **`row/add`は、ノードが実在し、引数の数がarityと合うときだけ行を作る**: 合わなければ`invalid_params`（メッセージに`Module.name/arity`と実際の引数を含める）、ノードが無ければ`not_found`

### 32.2 実装

- **`XipeTotec.CommandLine`（`lib/command_line.exs`、新規）**: `xipe do`の引数解析を`main.exs`から切り出した。これまでCLIの解析はテストが無かった。`parse/1`（argv→コマンドリスト）と`parse_value/1`（値の規則）
- **`Dispatch`の`row/add`**: ノードの実在とarityの検査を追加。**§16.1の「`row/add`の`node`は`:nodes`に実在するidが必要（`dispatch.exs:66-71`）」という記述は、当時のコードと合っていなかった**（実在の検査は無く、存在しないノードに対しても行を作れた）。今回の検査でこの記述が初めて事実になった
- **テストのフィクスチャ**: `in_out_test`・`runner_test`・`serve_project_test`・`serve_socket_test`の計12件が、存在しないノードや合わないarityで`row/add`しており、検査の追加で落ちた。テスト側にノードを用意する形に直した（`serve_project_test`は、空のBookが前提のスキャンのテスト1件だけ`@tag :empty_book`でシードを外す）
- **`xipe help`**の値の規則の説明と、使用例（`call_ids=[$0.id]`）を更新

### 32.3 テスト・実機確認

- `test/command_line_test.exs`（新規、9件）、`test/dispatch_test.exs`に3件（存在しないノード、arityの不一致、0引数）
- 実機: `P.inc/1`に`args=[3]`→`4`、`P.zero/0`に`args=[]`→`0`（どちらも`repr=exact`）。`args=3,`は`P.inc/1 takes 1 arg(s), got 2`、存在しないノードは`not_found`になることを確認。確認後、`tables/`と`info.json`は元に戻した
- `./test/run.sh`全32ファイル・285件、0 failures

**残った制約**: `[...]`の中はカンマで区切るだけなので、カンマを含む要素（Elixirのリストリテラル`[1,2]`を1つの引数として渡すなど）は書けない。`課題.md`に載せた。

## 33. `xipe eval`が評価しなかった行とその理由を出す（2026-09-24、`~/my_app/xipe_totec`セッション）

§31で見つけた抜け4への対応。効果が未分類の行を`xipe eval`すると、`Core.plan_recalc/3`の`filter_by_effect/3`が計画から外し（P1どおり）、出力は`1 command(s), 1 ok`だけだった。外されたことも、どうすれば評価されるかも出なかった。

- **`Core.exclusion_reason/3`（新規、純粋）**: 計画に入らない理由を人が読める文で返す。`plan_recalc/3`の除外の順（存在しない計算行 → 循環参照 → ノード消失 → 効果が未分類 → `writes`/`unknown`で`include_writes`無し）に沿う。未分類なら実行すべき`effect/set id=<node> effect=pure`をそのまま示す
- **`Runner`の`"eval"`**: 評価の後、頼まれたidのうち結果が無いものを`"not_run": [%{"id", "reason"}]`として結果に足す。`Evaluator`・`plan_recalc/3`の戻り値の形は変えていない（`drop_unresolvable/2`で外れた行は、従来どおり`{:skipped, ref}`として結果に入るので`not_run`には出ない）
- **CLI**: `eval call <id>  not run  <理由>`の行を出す
- テスト: `core_test.exs`に5件、`runner_test.exs`に1件。実機で、未分類の行と`writes`の行がそれぞれの理由付きで出ること、`effect/set`後は評価されることを確認。`./test/run.sh`全32ファイル・291件、0 failures

## 34. 拡張子の自己申告化（§27④）と`xipe reflesh`→`xipe refresh`の改名（2026-09-24、`~/my_app/xipe_totec`セッション）

`SurfaceTable`に直書きされていた拡張子→言語の対応表（`@extension_language`、§24.5）を、言語ごとの自己申告に置き換えた。

### 34.1 決定（crux）

1. **申告の置き場所は、新しい「言語の説明」モジュール**（`field_drip`には持たせない）: 言語ごとに1つずつあるモジュールは`field_drip`と`eval_template`だが、どちらも役割が拡張子と関係ない。また、言語単位の申告は拡張子だけで終わらない（ビルドツール判定の優先順位表〈§25.4〉、`embody`の有無〈§30〉）。§24.5の当初予定（`field_drip`に`extensions/0`）はここで変更した
2. **集めるのは`xipe refresh -l`のとき**（実行のたびには聞かない）: 集めた結果は`info.json`に書き、`SurfaceTable`はそれを読むだけにする。モジュールを置いただけでは効かず、登録して初めて使う（P4、`info.json`の既存の考え方どおり）
3. **2つ以上の言語が申告した拡張子は`language: nil`**（`refresh`時にエラーにはしない）: 判定できないものは判定できないと示す（P9）。そのうえで、利用者が行ごとに言語を決めて書き込む surface table 更新コマンドを別途作る（単純な表への書き込みで依存が無いので追加は簡単、crux）。`課題.md`へ載せた

あわせて、`xipe reflesh`は`refresh`のタイポだったので改名した（crux）。旧綴りの別名は残していない。本書の§24・§26等の本文は当時の綴りのまま残してある。

### 34.2 実装

- **`XipeTotec.Repl.Language`（`lib/repl/language.exs`、新規）**: behaviour。いまは`@callback extensions() :: [String.t()]`だけ。1言語1モジュールを`lib/repl/language/<name>.exs`に置き、ファイル名が言語名
- **`XipeTotec.Repl.Language.Elixir`（`lib/repl/language/elixir.exs`、新規）**: `extensions/0`が`["ex", "exs"]`
- **`Info.refresh_languages/2`**: `lib/repl/eval/field_drip/*.exs`の列挙をやめ、`lib/repl/language/*.exs`を読み込んで`extensions/0`を呼ぶ。`info.json`に`languages`（言語名）と`extensions`（拡張子→申告した言語のソート済みリスト。衝突をデータとして残すためリストにした）を書く。言語一覧の出どころも`field_drip/`から`language/`に変わった
- **`SurfaceTable.generate/3`**: `@extension_language`を削除し、`info.json`の`extensions`を引く（テスト用に第3引数で渡せる）。リストの要素が1つならその言語、0個か2個以上なら`nil`
- **`main.exs`**: `reflesh`→`refresh`。`-l`の出力に拡張子も出す
- **`info.json`**: `xipe refresh -a`を実行し、`"extensions": {"ex": ["elixir"], "exs": ["elixir"]}`が入った状態でコミットする。これが無いと、新しく取り出した直後にスキャンが何も見つけない（`info.json`はリポジトリに含めている）

### 34.3 テスト

`info_test.exs`（空の雛形に`extensions`、実物の`language/`の読み込み、一時ディレクトリに`c`と`cpp`を置いた`.h`の衝突）、`surface_table_test.exs`（対応表を明示的に渡す形に変更、衝突で`nil`、登録ゼロで全行`nil`）。`./test/run.sh`全32ファイル・294件、0 failures。スキャン系のテスト（`project_test`・`dispatch_test`の`scan/run`等）は実物の`info.json`を読んで通っている。

## 35. 評価モデルの確定 ── 参照透明の前提、セッションは1回の評価の間だけ、`lost`の廃止、`XT_READY`（2026-09-26、`~/my_app/tezcatl`セッション）

cruxとのco-design。REPLの仕様を詰める中で、仕様書 v0.4 の「REPLセッションの常駐」を前提にした記述と、実装（passごとにiexを起動し直す、§11.4・§22）のずれを整理した。

### 35.1 決定（crux）

1. **Xipe Totecは関数ごとの単体の確認を基本とし、計算行を続けて評価することで依存の連鎖を見る。** 参照透明性は**評価する関数**に求めるもので、**渡された値の出どころ**には求めない。行A（`⟦B⟧`を引数に使う）の関数が参照透明なら、Bが参照透明でなくても、型の合った値を渡した結果として記録は有効とする
2. **再現できない値の参照は認めない**が、これは上の意味（評価する関数が参照透明であること）であって、参照先が`unsupported`だから止める、という意味ではない
3. **仕様書 v0.4 の「常駐」は、対話型を前提にしていなかったための形**だった可能性が高い（crux）。いまの構成では「評価要求1回の間だけREPLを保持し、終われば閉じる」ので、仕様の「セッション」はこの意味に読み替える。常駐（passをまたいでセッションや束縛を持ち越す）はしない
4. **`lost`は廃止。** `lost`は常駐セッションが落ちたとき（再起動で束縛が失われたとき）のための状態で、束縛が評価をまたがない以上、起きる場面が無い。評価の途中でREPLが固まった場合は既存の`aborted`がこれにあたる
5. **表から値を渡せない参照先は、同じ評価に含めて評価し直す（案a）。** 対象は、まだ評価されていない参照先と、pure以外の関数の`unsupported`の値。参照先の行の結果も更新される（依存の連鎖が表にそのまま残る）。参照先も副作用の分類による制限を受け、評価できなければ参照している行は`skipped`（`ref_error`）。pureの`unsupported`は従来どおり呼び出し式を埋め込む（案b「pure以外にも呼び出し式の埋め込みを広げる」は、参照先の行が更新されず連鎖が表に残らないので退けた）
6. **`XT_READY`は「現状のバナー待ち＋echo」の2段**（crux、§25.3の具体化）。バナー（`ready_pattern`）が出るのを待ち（`nil`なら省略）、次に言語ごとの確認用の式（`ready_probe`、Elixirは`IO.puts("XT_" <> "READY")`）を送り、`XT_READY`が出るのを待つ（`nil`なら省略）。バナーの無いREPLでも同じ仕組みで済み、式が実際に評価されたことまで確かめられる。マーカーを式の中で分割して書くので、入力をそのまま返す端末（PTY）でも誤検出しない。実測で、バナーから`XT_READY`までは約30ミリ秒

### 35.2 検討した候補（常駐）

| 案 | 中身 | 退けた理由 / 採った理由 |
|---|---|---|
| 1. passごとに起動（現状） | 毎回新しいREPL | **採用。** ディスク上のコードで評価でき、状態が漏れない（P2）。参照透明の前提なら、passをまたいで値を持ち越す必要が無い |
| 2. サーバーだけ常駐、変化したら再起動 | `xipe start`がREPLを保持 | 速いのはコードが変わっていない間だけ。状態の漏れで結果が履歴に左右されうる。`lost`の扱いが要る |
| 3. 常駐して変更をその場で読み込み直す | `recompile()`等 | 「カードは常にディスクの内容に合わせる」原則（Scanner.Lsp）と衝突 |
| 4. CLIもサーバーのセッションを使う | 2が前提 | 同上 |

実測（calc、scripts-mode）: `xipe eval`全体で約2.7秒、うちCLI自身の起動が約1.7秒、iexの起動が約0.6秒。Mixプロジェクト（`iex -S mix`）は未測定。

### 35.3 実装

- **`Core.plan_recalc/3`**: `with_needed_upstream/2`（新規）で、予定した行が参照している「表から値を渡せない参照先」（未評価、またはpure以外の`unsupported`）を推移的に計画へ加える。pureの`unsupported`は呼び出し式を埋め込むので加えず、その引数の参照先を同じ規則で見る。加えた行も`filter_by_effect/3`を通る。`restart_session`（計画の欄と引数）、`bind_as`（エントリの欄、どこからも読まれていなかった）、`apply_result/3`の`{:lost, ref}`を削除。`:binding`入力から`gen`を削除（`:binding`は「この評価の中で束縛されない参照」を表すだけになり、`drop_unresolvable/2`が`skipped`にする）
- **`Repl.Evaluator`**: 結果の`session_gen`（計算行の`session`列）に評価の id（`pass_id`）を入れる（従来は常に1）
- **`Repl.Launch`**: `ready_probe`を追加。`ready_pattern`は`nil`を許す
- **`Repl.Session.await_ready/4`**: `(sender, handle, message, timeout)`に変更し、上の2段を行う。`timeout`は2段の合計
- **`Protocol`・`main.exs`**: `lost`の表示を削除
- **仕様書 v0.4**: 用語「セッション」・`session`列・`state`の一覧・§6.3（参照の解決）・§6.5（エラー値、`lost`の行を削除、`unreproducible`は下流に伝わるエラー値ではなく注意の表示と明記）・§13（境界規則の「再起動の指示」）・§14.2（評価の手順）・段階計画の該当行を書き換えた。版の行に改訂を記した
- テスト: `core_test`（参照先を評価に含める3件、`lost`の削除）、`repl_session_test`（2段の待ち合わせ2件、引数の変更）、`repl_evaluator_test`（`session_gen`が評価の id）、`repl_launch_test`、`protocol_test`。テスト用の偽のsenderは、起動時にバナーと`XT_READY`を返すようにした。`./test/run.sh` 369件、0 failures。`test/live/repl_iex_test.exs`（本物のiex）12件、0 failures
- 実機: `Probe.mkref/0`（`make_ref()`、reads、`unsupported`）の行Bと、`Probe.is_ref/1`（pure）の行A＝`is_ref(⟦B⟧)`を作り、Aだけを評価した。Bが同じ評価に含まれて新しい参照が作られ、Aは`true`を記録した

### 35.4 REPLの起動失敗でCLIごと落ちる不具合の修正

`Repl.Sender.Direct.send/1`は見張り役のGenServerを`GenServer.start_link/2`で起動していた。OSプロセスの起動をerlexecが拒否すると`init/1`が`{:stop, {:spawn_failed, reason}}`を返し、戻り値は`{:error, ...}`になるが、リンクを通じて終了シグナルも呼び出し元に届き、`xipe eval`（やサーバーの評価プロセス）ごと落ちていた（§35の実装中、flakeの環境変数を文字リストで渡したときに`** (EXIT from ...) {:spawn_failed, ...}`として表面化）。起動の間だけ呼び出し元で終了シグナルを受け止めて捨てる`start_linked/1`に変え、失敗は`{:error, {:spawn_failed, reason}}`として返るようにした（`Evaluator`は既存どおり`launch_failed`として報告する）。テスト（`repl_sender_direct_test`、erlexecが拒否する環境変数の値で起動）は修正前のコードで同じ形で落ち、修正後に通ることを確認した。`./test/run.sh` 370件、0 failures。

## 36. 評価するのは指定した計算行だけ ── 下流・上流の自動評価と呼び出し式の埋め込みをやめる（2026-09-26、`~/my_app/tezcatl`セッション）

評価の入口の一本化（`row/update`の再評価範囲）を詰める中で、cruxから「下流再計算はあくまで可能というだけで、実行は単体、記録もそれだけを前提にしていいか。データベース（Book）に載るのは時系列のはず。下流も含めて載ると、コマンドに明示していない評価を勝手に実行していることにならないか」と指摘があった。実機で確かめると、`xipe eval <R1>`で、R1を参照しているR2まで評価・記録されていた。

### 36.1 決定（crux）

- **評価するのは、評価要求で指定された計算行だけ。** Bookは時系列の記録で、載るのはコマンドで指定した評価だけとする
- **下流の自動評価をやめる**（仕様書 v0.4 §6.6の「affected集合」に由来する、以前からの動作）。下流を評価したいときは、How to use §2.6と同じく行を並べて指定する。専用の手段（`--downstream`など）は作らない
- **上流の自動評価（§35の決定5、案a）もやめる。** §35で採った「表から値を渡せない参照先を自動で同じ評価に含める」は、同じ理由で撤回した。値の無い参照先を使う行は、参照先も一緒に指定したときだけ評価できる
- **pureな関数の`unsupported`の呼び出し式を埋め込む処理（`:inline_call`）もやめる。** 参照先の関数を、記録に残さずに実行していたため。これも参照先を一緒に指定する形に揃えた
- **評価しなかった行（`skipped`）はBookに書かない。** 従来は`state: ref_error`を書いていたが、評価していない行の記録になるため。理由は出力にだけ出す

### 36.2 実装

- **`Core.plan_recalc/3`**: 計画に入るのは`call_ids`で指定され、存在し、循環に入っていない行だけ（`affected_set/3`を使わない）。`with_needed_upstream/2`（§35）を削除。`:changed_node_ids`オプションを削除。`resolve_ref/4`から`:inline_call`の分岐と`visiting`を削除。`apply_result/3`の`{:skipped, _}`はno-op
- **`Repl.Evaluator.run_pass/3`**: `plan.skipped`をBookに畳み込まない（結果の先頭で報告するだけ）
- **`Repl.EvalTemplate`**: `:inline_call`の展開（`resolve_args/2`・`expand/4`）を削除。Coreが作るプレースホルダはすべて最終形なので、呼び出し式は引数をそのまま並べる
- **CLI**: `skipped`の表示を「upstream X has no value to pass on -- evaluate it in the same command (not recorded)」に変更。`xipe dialogue depends`の「その上流を評価します」（実際は下流）を「そこから指定した行までを評価します」に直した（途中の行は元から明示的に並べていたので、動作はこの変更の影響を受けない）
- `Core.affected_set/3`・`dep_hash_affected_nodes/2`・`calls_for_nodes/2`は使われなくなった。扱いは`課題.md`
- 仕様書 v0.4（版の行、§6.3の表と箇条、§6.6、§14.2）、How to use §2.6・§4.2・§3.4・§11、README冒頭、動作原理.md、課題.mdを更新
- テスト: `core_test`（指定した行だけが計画に入る、`unsupported`＋pureは埋め込まず`skipped`・一緒に指定すれば同じpassで渡る、`skipped`/`aborted`はBookを変えない）、`repl_eval_template_test`（`:inline_call`の2件を削除）。`./test/run.sh` 367件、0 failures
- 実機: `xipe eval <R1>`はR1だけ、`xipe eval <R1> <R2>`は両方を評価した。`is_ref(⟦mkref⟧)`だけを指定すると`skipped`で、`book.jsonl`の行数は変わらなかった（86→86）。両方を指定すると、`mkref`が先に評価され、その値で`is_ref`が`true`を記録した

## 37. 評価の入口の一本化 ── `Pipeline`の段を実装し、REPLを使う基本の操作を1つにする（2026-09-26、`~/my_app/tezcatl`セッション）

コマンド追加の準備の最後の項目。REPLを使う処理の入口が3か所（Runnerの`"eval"`、`pipelines.json`＋`Pipeline`〈段はすべてスタブ〉、`Serve.Project`の`@eval_methods`）に分かれていて、同じ`eval/run`がCLIでは未実装、サーバーでは（`Pipeline`を通らずに）動く、という状態だった。

### 37.1 決定（crux、案B）

- **REPLを使う基本の操作は、Runnerの`"eval"`だけ。** 組み合わせのコマンドは`pipelines.json`に段を並べて表す（2026-09-18に設計した「データで持つ組み合わせ」を活かす）。案A（`Pipeline`をやめて`eval/run`を`eval`の別名、`row/update`をRunnerに直書き）は退けた
- **`row/update`は「引数を変えて、その行だけを評価する」**（§36の原則どおり、下流は含めない）

### 37.2 実装

- **`Pipeline`**: `"edit"`段（`params["id"]`の`args`を変える。検査は`row/add`と共通の`Dispatch.check_args/4`、新設）と`"eval"`段（呼び出し元が`ctx.eval`として渡すRunnerの`"eval"`を呼ぶ。`Pipeline`はRunnerに依存しない〈Runnerが`Pipeline`に依存しているので、直接呼ぶと読み込み順の循環でコンパイル時の警告が出た〉）を実装。評価する行は`eval_params/1`が決める（`call_ids`、なければ`id`の1行）。段の結果は順にマージする（`row/update`は編集後の行と評価結果の両方を返す）。`"eval"`段は最後に置く約束
- **`Pipeline.prepare/4`（新設）**: `"eval"`より前の段だけを実行し、評価すべき`eval_params`を返す。サーバーは評価結果だけをその時点のBookに反映するので、`"edit"`を評価回の中で行うと編集が反映されずに失われるため
- **`Serve.Project`**: REPLのメソッド（`Methods`の`repl`、`row/update`を追加）は`start_repl_method/3`で、`"eval"`より前の段をその場で実行して保存・配信し、`"eval"`段（または素の`eval`）を評価回のキューに回す。応答は両方をマージ（`row/update`なら編集後の`row`と`pass_id`）
- **`Runner`**: `Pipeline`へ渡すctxに、自身の`"eval"`を`ctx.eval`として入れる
- **CLI**: `eval`以外でも結果に`"results"`があれば評価結果の行を表示する（`row/update  ok  id=...`の後に`eval call ...`）
- テスト: `pipeline_test`（スタブ前提の2件を実装の検証に書き換え、`row/update`がその行だけを評価すること・検査・`eval/run`・`ctx.eval`無しの拒否・`prepare/4`の5件）、`runner_test`（`row/update`が編集してその行だけを評価）、`serve_project_test`（編集はその場で反映・配信され、評価はその行だけ）、`in_out_test`（`eval/run`が通ること）。`./test/run.sh` 372件、0 failures
- 実機（CLI）: `xipe do row/update id=<R1> 'args=[4]'`で、R1の引数が変わりR1だけが評価された（R1を参照するR2は評価されない）。`xipe do eval/run 'call_ids=[<R1>,<R2>]'`で両方を評価。引数の数が合わない`row/update`は`row/add`と同じ文言で拒否

### 37.3 下流の問い合わせ関数の削除

§36で評価対象の決定に使わなくなった`Core.affected_set/3`・`dep_hash_affected_nodes/2`・`calls_for_nodes/2`を削除した（crux）。「ある行の下流」「ある関数を呼んでいる関数」のような問い合わせは、後で追加する予定のデータベースやsurface tableを検索するコマンド（単純なSQLの応用）で表せるため、専用の関数として持っておく理由が無い。`bfs/3`は`upstream_chain/2`（`row/depends`・`dialogue depends`）が使うので残した。関係するテスト5件を削除。

## 38. OCaml版`embody` ── トップレベル自身の仕組み（`Toploop`）で評価と表示を借りる固定モジュール、Haskell/OCaml共通の実行手順（2026-09-26、`~/my_app/tezcatl`セッション、設計と実機検証のみ、実装なし）

§30（Haskellの`embody`）の考え方をOCamlにも当てはめる相談の中で決めた。着手順はHaskell → OCamlに決定（crux、`next_step.md` §2.4）。REPLは素のものを使う（Haskellは`stack`/`cabal`を経ても中身はGHCi、OCamlは`utop`ではなく素の`ocaml`、crux）。

### 38.1 提案（crux）と、成立する形

cruxの提案は「OCamlでも`embody`のアイデアを元に、指定したモジュールに依存してそのトップレベルを読み、値と共に返す`embody.ml`を用意する」。成立するのは、**対象への依存を`embody.ml`のコンパイル時ではなく、トップレベルが実行時に解決する**形。`embody.ml`は対象を知らない固定のコードで、受け取った式のテキストを、トップレベル自身のパーサ・型検査・表示（`Toploop.execute_phrase`）で評価し、トップレベルが出す表示を文字列として捕まえる。対象のモジュール名・関数名は、xipeが送るテキストにだけ現れる（§30.3の「どの関数を包むかはREPLへ送る1行が決める」と同じ）。コンパイル時に依存させる形は、対象ごとに作り直しが要り型の知識も要るので、§30.2と同じ理由で成立しない。

### 38.2 実機検証（OCaml 5.5.0、`nix shell nixpkgs#ocaml`の素の`ocaml`）

`embody.ml`（`#directory "+compiler-libs"`の後に`#use`）の中身は、式のテキストを`!Toploop.parse_toplevel_phrase`で読み、`Toploop.execute_phrase true ppf`で評価し、`ppf`を`Buffer`に向けて表示を受け取るだけ。対象は`#mod_use "target.ml"`で読み込んだ。

| 送った式 | 受け取った表示 |
|---|---|
| `let xt_1 = Target.area (Target.Rect { w = 3; h = 4 })` | `val xt_1 : float = 12.` |
| `let xt_2 = Target.shapes 3`（ヴァリアントとレコードのリスト） | `val xt_2 : Target.shape list = [Target.Circle 0.; Target.Rect {Target.w = 1; h = 2}; Target.Circle 2.]` |
| 循環するリスト | `val xt_3 : int list = [1; 2; <cycle>]` |
| 関数を返す | `val xt_4 : int -> int = <fun>` |
| 無限の遅延シーケンス | `val xt_5 : int Seq.node = Seq.Cons (0, <fun>)`（有限で返る） |
| 型が合わない式 | 失敗（`Typecore.Error`。人が読める文言にするには`Location.report_exception`などが要る） |
| 実行時の例外 | 失敗（`Exception: Failure "hd".`） |
| `let xt_8 = (xt_2 = Target.shapes 3)` | `val xt_8 : bool = true`（前の束縛を次の式から参照でき、構造の`=`で比較できる） |

分かったこと:

- **型が値と一緒に取れる**（`result_type`列がそのまま埋まる）
- **表示は必ず有限**（深さと長さの上限、循環は`<cycle>`、関数は`<fun>`）。Haskellのように`show`の出力を途中で切る工夫が要らない
- **往復検査の見込み**: 表示がほぼそのままOCamlの式として読める（コンストラクタも修飾付き）。表示を再評価して`=`で比べれば、多くの値は`repr=exact`にできそう。`<fun>`・`<cycle>`・`<abstr>`を含むものは`unsupported`（未実装・未検証）
- **トップレベルの束縛は次の式から見える**: 同じ評価の中の`⟦id⟧`参照（`xt_<id>`）はこのまま使える
- **`#mod_use`はトップレベルの`let () = …`を実行した**（`SourceSanitize`相当が要る）
- 未確認: 1件ごとの時間・メモリの上限、`dune ocaml top`経由のdune管理プロジェクトで同じように動くか

### 38.3 Haskell/OCaml共通の実行手順（crux、2026-09-26）

xipe_totecから見た手順は両言語で同じ。関数Aを見たいときはAの計算行を作って評価し、依存の深さのある評価（`embody` → A → …）は計算行を`⟦id⟧`でつないで並べて指定する（§36）。

- `embody`は、その言語のアダプタ（`EvalTemplate`相当）が評価する呼び出しを**毎回自動で包む**。利用者は行ごとに指定しない（Elixir版がどの行も安全装置で包むのと同じ位置づけ）
- 連鎖の各段は依存の順に1行ずつ`embody`で包まれて評価され、どの段も記録される。前の段の結果は同じ評価の中では変数で渡るので、表示では読み戻せない値も連鎖の途中を通せる。評価をまたいで使えるのは`exact`の値だけ
- Aの引数に入れ子の式（`M.b (M.c 1)`）を直接書くこともでき、その場合に記録されるのはAだけ（利用者が書いた式なので§36の「勝手な評価」にはあたらない）
- 言語による違いは、アダプタが送る1行と`embody`の中身（scripts-modeの読み込み、上限の取り方、往復検査、型の取得）に収まる。表は`next_step.md` §2.5

### 38.4 関連: 言語が混ざるプロジェクト

`.exs`が`.ml`に依存する構成（Aepyornis: Elixirの`lib/`がduneでビルドしたOCamlの実行ファイルをPortで呼ぶ）は、スキャンは動くが、評価は`Runner`の`multiple_languages`（1回の評価は1つの言語、仮の制限）で拒否される。評価を言語ごとに分ける変更、言語をまたぐ`⟦id⟧`参照の扱い、境界規則（仕様§13）が要る。`next_step.md` §2.6。

## 39. 仮の制限（1回の評価は1つの言語）を外す ── 行の言語ごとにREPLを分けて並行評価（2026-09-26、`~/my_app/tezcatl`セッション）

言語が混ざるプロジェクト（Aepyornis: Elixirの`lib/`がduneでビルドしたOCamlの実行ファイルをPortで呼ぶ）を扱う相談の中で決めた（crux「Elixirだし並行して起動する動きは得意なはず。外す準備をしましょう」）。

### 39.1 以前の動きと、確かめたこと

- `Runner`は評価で使う言語を、**指定された行ではなく、プロジェクト全体のsurface tableに登録済みの言語が何種類あるか**で決めていた（`pass_language`）。言語が2つあるだけで、OCamlの行だけを指定しても`multiple_languages`で拒否された。OCamlの部分を別プロジェクトとして登録すれば評価できた
- 値は各言語のREPLの表示テキストのまま保存し、`⟦id⟧`はそのテキストを貼るだけ。xipe_totecが言語どうしで自動で変換している箇所は無い（cruxの方針「値の書き方はxipe_totecの上でも言語に合わせる」と一致）。そのため言語をまたぐ参照は、そのままでは構文エラーになる

### 39.2 実装

- **`Runner`の`"eval"`**: 指定された行を、関数 → ファイル（`sheets`の`path`）→ surface tableの`language`とたどって言語ごとに分け（`eval_groups/4`）、言語ごとにREPLを起動して評価する（`run_group/8`）。グループが2つ以上なら`Task`で並行に走らせる。1つなら従来どおり呼び出し元のプロセスで走らせる。結果は最後にまとめてBookへ畳み込む（`Core.apply_results/3`）。評価のidは全グループで共通
- **言語をまたぐ参照**: 参照先の言語が違う行は評価せず`not_run`に「⟦id⟧ is a <言語> row -- a reference across languages isn't supported yet」を出す。変換は未実装（設計は`next_step.md` §2.6: 計画の時点で変換の段を差し込み、参照先の`result_type`で型ごとの変換モジュールを割り当てる、中立の形を真ん中に置く対応表、登録されていない型はエラー）
- **今の動線（言語が1つのプロジェクト）を変えない**: 言語が1つなら、行の言語がファイルから決まらなくてもその言語で評価する。エラー（`no_language`・`language_not_registered`・`eval_failed`）も従来と同じ形で返す。言語が2つ以上で、ある言語のREPLだけ起動できないときは、その言語の行を`not_run`（「the <言語> REPL: …」）にし、他の言語の結果は返す。全言語で失敗したら`eval_failed`
- テスト用の差し替え口`:info`（info.jsonの代わり）・`:language_modules`（言語名 → モジュール）を`Runner`に足した（`Project.scan_dir`の`:info`と同じ扱い）
- テスト: `runner_test`に3件（Elixirと架空の言語`.toy`が混ざるプロジェクトで、言語ごとの評価・言語をまたぐ参照の`not_run`・同じ言語の中の参照、片方の言語のREPLが起動できないとき、片方の言語だけを指定したとき他方のREPLは起動しない）。`./test/run.sh` 370件、0 failures。`test/live` 12件、0 failures。CLIで言語が1つのプロジェクトの`xipe eval`・`row/update`が従来どおり動くことを確認
- 文書: How to use §9、動作原理.md、課題.md、`next_step.md` §2.2・§2.6・§3

## 40. `input` method と1行1コマンドの `help` ── tezcatl の対話窓の受け口（2026-09-27、`~/my_app/tezcatl`セッション）

tezcatl 側で対話窓（`panels/skins/xipe.html`）と汎用の辞書ができ、打った1行を解釈せず `input` `{"text": "<行>"}`
だけで送る形に決まった（tezcatl `D-xipe対話窓`・`D-辞書`、crux 2026-09-27）。Xipe Totec 側に要るのは、
その1行を受ける `input` と、辞書に登録できる形の `help`（`課題.md` §2 に記録してあった2点）。

### 40.1 決めたこと

- **1行の書き方は CLI と同じ**: 端末で `xipe` に続けて打つもの（先頭の `xipe` は可）。`help [<command>]`・
  `version`・`show`・`scan`・`eval [id...] [--include-writes]`・`do <method> … [-- <method> …]`。method 名から
  始まる行は `do` を省いたものとして読む（`/` を含む語、または `Methods` にある名前）。`'…'`・`"…"` はシェルと
  同じく外す（端末からの写しがそのまま通る）。`<dir>`・`--dir`・`--mix` は取らない（対象は開いている
  プロジェクト）
- **端末が要るコマンドは断る**: `choice project`・`table generate`・`start`/`serve`・`config`・`refresh`・
  `dialogue depends`（プロジェクトを選ぶ・起動する・xipe_totec 自身のファイルを書く。`dialogue depends` は
  サーバーに対話プログラムが無い間、`課題.md` §2）。`input_error` で「端末で xipe … として」と返す
- **`help` は1行1コマンド**: `<コマンド>: <説明>  <引数>`。見出しも折り返しも無い。コマンド名に `:` を含めない
  （tezcatl の辞書は最初の `:` の前を語にする）。CLI の `xipe help` と対話窓の `help` は同じ表から出す。
  対話窓の一覧は窓で使えるものだけ（端末が要るコマンドは載せない）。`"eval"` 疑似 method は `eval` コマンドと
  重なるので載せない。未実装の method も載せない。これまでの長い説明は `help <command>` で出す
- **表は1か所**: CLI コマンドは `lib/help.exs`（名前・引数・一行の説明・長い説明・窓で使えるか）、method は
  `Methods` に `args`/`summary` を足した。`help_test` が、実装済みの method に説明が無ければ落ちる
- **返事は CLI と同じ行**: `dialogue.text` に CLI が出す行（`OutcomeText`・`Show`・`Help`。`main.exs` から
  `lib/` へ移し、CLI もそこから出す）。コマンドなら `result.outcomes`（コマンドごとの `method`・`ok`・`result`・
  `error`）。コマンドの失敗は返事全体の失敗にしない（CLI と同じく残りも走り、行に error が出る）。読めない行
  だけ `error`（`input_error`）
- **評価を待つ**: 1行のコマンドは1つずつ `Serve.Project` の普通の要求として流す。評価（`eval`・`eval/run`・
  `row/update`）は評価回のキューに入り、その行は評価の終わりを待ってから次へ進む。`… -- eval … -- row/check`
  が CLI と同じ意味になるため。待つのは別プロセスで、接続（tezcatl の窓どうしが共有する）はほかの要求に応える
  - `Serve.Project.request_dialogue/5` の `watch:` で、評価回の終わりを `{:xipe_pass_done, pass_id, outcome}`
    として受け取る。評価回をキューに入れるのと同じ呼び出しで登録するので、すぐ終わる評価でも取りこぼさない
  - `$<n>.<path>` は `Runner.substitute_command/2`（`Runner.run/4` と同じ解決）
- **対話**: 対話を保持している間は、次の行がその答え（コマンドに見える行も）。行 → 答えの params は
  `Dialogue` の任意の callback `parse_answer/1`（無ければ `%{"text" => 行}`）。`Dialogue.Depends` の `y <値>`/`n`
  の読み方を CLI から移し、CLI もこれを使う。1行の途中のコマンドが対話を始めたら、その行はそこで終わる
- `input` は `Methods` に載せない（`initialize`・`subscribe` と同じく `Serve.Socket` が扱う）

### 40.2 確かめたこと

- テスト: `help_test`（5件）・`input_test`（8件）・`serve_input_test`（10件、即答の偽 Sender で評価の待ちと
  `$` 参照、対話の保持と答え、`show`、端末が要るコマンド）・`dialogue_depends_test` に1件。
  `./test/run.sh` 41ファイル・399件、0 failures
- tezcatl の E2E（隔離したポートで本物の Xipe Totec の写し）: 新しい `test/e2e/xipe_input.mjs`（14項目）──
  `help` の行、ヤンクして辞書へ `p`、`row/li` から `row/list` の補完、`show`、コマンド列、`eval` が評価を待って
  `add(1,2) = 3` を出す、`choice project` を断る。既存の `xipe_skin`（偽・本物）・`xipe_rows`・`xipe_cards` も通る

## 41. `eval_table` と検索（`xipe search`）、対話プログラムの一覧をサーバーへ（2026-09-27、`~/my_app/tezcatl`セッション）

`next_step.md` §3「次の再開は `eval_table` を実現するところから」（crux、2026-09-26）と、決定済みの検索（§1.1）の実装。
あわせて tezcatl の G8（サーバーに対話プログラムが無い）と §17.3（WebSocket 側の複数ターン対話）を片付けた。

### 41.1 `eval_table`

- 新しい保存先ではなく、`calls` に関数（`module`・`name`・`anykey`・`effect`・`visibility`）とファイル（`path`）を
  横付けした読み取り用の見え方（`lib/eval_table.exs`、`EvalTable.rows/1`）。`課題.md` §1-5 の「`calls` と重なる
  のでは」への答え。列名は Book のまま（`result`。`row/list` の `value` とは違う）。関数が消えた行は横付けの列が空
- WebSocket へ出す method はまだ作っていない（tezcatl の表・カード一覧・ジャンプで要るときに足す）

### 41.2 検索（`Dialogue.Search`）

§1.1 の決定どおり。実装で補ったこと:

- `-s|-e <列> <値> [<取り出す列>]` の取り出す列は省けば `id`（例の `-e module -` が3語のため）。`list` 形にも
  取り出す列を書く（例の `-e path list id` のとおり）。`-` は空のセル。リストの列（`args`）は要素を `, ` で
  つないだ文字列として比べる。取り出した値は重複を除いてリストにする（件数は当たった行の数）
- `view` の表示する列を省くと全列。`view` の後は「検索を終了しますか？y/n」。それ以外の行が来たら問いは
  取り下げて、その行を普通のターンとして読む
- `x` の置き換えは、語・値（`id=x`）・リストの要素（`call_ids=[x]`）・参照（`⟦x⟧`）の位置だけ。語の一部
  （`effect=...`、`n2`）は置き換えない。`get id` の前に `x` を使うと、そう言って実行しない
- surface table は保存済みのものをそのまま読む（作り直さない・保存しない。無ければメモリ上で作る）。
  検索は何も書かない
- 一覧の表示は `N件ヒットしました。（<列>: [先頭10件]（ほか M 件））`

### 41.3 対話プログラムの約束を広げた（`Dialogue`・`InOut`）

- **読み取り用の文脈**: `start/2`・`answer/3` を実装した対話プログラムには、`InOut` が `ctx`（`book`・`root`・
  `project_dir`）を渡す。これまでの `start/1`・`answer/2` もそのまま動く。Book を変えるのは、これまでどおり
  コマンドだけ（「対話プログラムは Book に触らない」§19 は、書かない、という意味で守られる）
- **`{:pass, state, line}`**: 「この行を普通のコマンドとして実行し、対話は保持したまま」。§1.1 の「検索以外の
  コマンドも、対話を保持したまま通せる」の実体。実行するのは駆動側（CLI のプロンプト、`Serve.Input`）で、
  `InOut` は `outcome.run = {:line, line}` として返すだけ
- **`defer_commands: true`**: `:done` のコマンド（`dialogue depends` の `y <値>` の `row/set-result`＋`eval`）を
  `InOut` の中で走らせず、`outcome.run = {:commands, …}` で返す。サーバーでは `Serve.Project` の中で評価すると
  GenServer が評価の間止まるため、`Serve.Input` はこれを付けて、評価回のキューに流す。CLI は付けない（従来どおり）
- **`dialogue/quit`**: どの対話も終える（`quit dialogue`、§1.1「対話一般の終了コマンド」）。行 → 要求は
  `Dialogue.line_request/2`
- **一覧は1か所**: `InOut.programs/0` = `dialogue/depends`・`dialogue/search`。CLI もサーバーもここから使う
  （tezcatl G8）。`dialogue depends` は `call_id` だけで始められる（連鎖は `Depends.chain/2` が文脈の Book から
  組み立てる。CLI は従来どおり `chain` を渡す）

### 41.4 入口

- CLI: `xipe search [<最初のターン>]`（`search>` のプロンプト。EOF でも終わる）。ターンのたびに Book の差分を保存
- 対話窓: `search [<最初のターン>]`・`dialogue depends <call_id>`・`quit dialogue`（`Input`、`help` の表にも追加。
  `dialogue depends` は窓で使えるコマンドになった）
- 1行の途中のコマンドが対話を始めたら、その行はそこで終わる（§40 と同じ）。そのとき始まった対話が最初の
  ターンで `:pass` を返しても、その行は実行しない（次の行で打つ）

### 41.5 確かめたこと

- テスト: `dialogue_search_test`（9件、`eval_table` の横付け・§1.1 の使いどころの例・`x`・`InOut` 経由の
  開始／`:pass`／`quit dialogue`・`dialogue depends` の `call_id` 開始）、`serve_input_test` に2件（窓からの
  検索の一連、窓からの `dialogue depends` の評価が評価回を通る）、`input_test` に1件。`./test/run.sh`
  42ファイル・411件、0 failures
- CLI（作業用の写し）: `xipe search -h` からのターン一式（`-s path … path` → `-e path list id` → `get id -2` →
  `row/list call_ids=[x]` → `view` → `n` → `eval x` → `quit dialogue`）、結果が Book に残ること。
  `xipe dialogue depends` が従来どおり動くこと
- tezcatl E2E `xipe_input.mjs` に検索（`search -e name square` → `get id` → `eval x` = 9 → `quit dialogue`）を追加、
  17項目すべて ok。既存のシナリオも ok

## 42. OCaml の実装 ── 素の `ocaml` トップレベル＋`embody.ml`、テキストから読む Scanner（2026-09-27、`~/my_app/tezcatl`セッション）

着手順を変えて OCaml を先にした（crux「実機確認もできているしね」、`next_step.md` §2.4）。§38 の設計（対象を知らない
固定の `embody.ml` が、式のテキストをトップレベル自身の仕組みで評価し、表示を受け取る）を実装した。

### 42.1 実機で確かめてから決めたこと（OCaml 5.5.0、`nix shell nixpkgs#ocaml`）

- **トップレベル自身の `Toploop` だけを使う**: §38 の試作は `Location` なども使っていたが、素の `ocaml` には
  コンパイラ部品の実装が入っておらず（`Reference to undefined compilation unit Location`）、`ocamlcommon.cma` を
  読むと動くものの、それは**別の写し**で、型エラーがトップレベルの文言にならなかった（`Typecore.Error (_, _, _)`）。
  `Toploop.use_input`（文字列を打ったのと同じに扱う）なら、エラーの報告もトップレベル自身が行う
- **読み込みの安全化（scripts-mode）**: `Toploop.parse_use_file` で位置を得て、トップレベルの式と
  `let ()`/`let _` を空白で塗りつぶした写しを `mod_use_input` で読む（改行は残すので行番号は元のまま）。
  トップレベルの副作用は走らない（確認済み）。§38.2 の「`#mod_use` はトップレベルの `let () = …` を実行する」への対処
- **依存の順**: アルファベット順で読み、失敗したファイルは他を読んだ後にもう一度（進まなくなるまで）。
  `ocamldep` を使わずに済む
- **時間の上限**: `Unix.setitimer` の SIGALRM で `Embody.Timeout` を上げる（無限ループが1秒で止まった）。
  **メモリの上限は持たない**（固まればトップレベルごと落とす、`Evaluator` の既存の経路）
- **SIGINT**: 評価中の句だけが止まり（`Interrupted.`）、トップレベルはその後も読む → `interruptible: true`
- **repr**: 表示（`val xt_<id> : <型> = <値>`）の値をもう一度評価して `=` で等しければ `exact`、それ以外は
  `unsupported`。普通のレコード・ヴァリアント・option・リストは `exact`。**インラインレコード**
  （`Rect of { w; h }`）の表示 `Target.Rect {Target.w = 1; …}` は OCaml のソースとして読めない
  （`Unbound record field Target.w`）ので `unsupported`。`binary` は作っていない（`Marshal` で作れる見込み）
- **compare**: 前回の値（`exact` のときだけ）を評価して `=` で比べる。浮動小数点の許容誤差は無い
- 出力: 時間切れは `XT_ERROR_<id> timeout`、例外は `crash Exception: Failure "hd".`、型エラー・構文エラーは
  トップレベルの文言（位置と `^^^` 付き、改行は `\n`）

### 42.2 部品

| 部品 | ファイル | 中身 |
|---|---|---|
| `embody` | `lib/repl/ocaml/embody.ml`（2026-09-27 に `~/my_app/embody/` へ移した、§44） | `Embody.run id var timeout text prev`（評価・型・repr・compare・マーカー）、`Embody.load_all dir files` |
| 言語の申告 | `lib/repl/language/ocaml.exs` | 拡張子 `ml`、REPL `ocaml`、ビルドツール `dune`（`dune-project`、判定だけ）、`launch_opts/3` は一時ディレクトリに初期化ファイルを書く |
| launch | `lib/repl/ocaml/launch.exs` | `ocaml -init <初期化ファイル>`、バナー無し・`ready_probe`・`#quit;;`・interruptible。`message["files"]` は使わない（`Sender.Direct` はそれを iex の `-r` にするため） |
| eval_template | `lib/repl/ocaml/eval_template.exs` | 1行につき `Embody.run "<id>" "xt_<id>" <ms> "<let xt_<id> = M.f (a) (b);;>" <prev>;;`。呼び出しは文字列で渡るので、引数が閉じていなくてもトップレベルが続きを待つ状態にならない |
| Eval.Scan / FieldDrip | `lib/repl/eval/scan/direct/ocaml.exs`・`lib/repl/eval/field_drip/ocaml.exs` | iex と同じ（`XT_EXIT` の除去、`key=value` の本文）。委譲 |
| Scanner | `lib/scanner/ocaml.exs` | テキストから: 行頭の `let`/`let rec`/`and`（`type` の `and` は除く）、コメント・文字列・文字リテラルは塗りつぶす、ファイル名がモジュール名、`anykey` は `nil`、同名は後ろのもの、すべて `public`。呼び出し関係は `Mod.name` と同じファイルの名前の出現からの推定（自分自身は除く） |

- `info.json` に登録した（`xipe refresh -a`）
- テスト: `test/ocaml_adapter_test.exs`（11件、OCaml 不要）、`test/live/repl_ocaml_test.exs`（5件、`ocaml` が
  PATH に無ければ除外）、fixture `test/fixtures/ocaml_sample/`（`area.ml` が `geometry.ml` を使う、`geometry.ml` に
  トップレベルの副作用）
- 既存のテストへの影響: `runner_test` の評価のテストは `.`（xipe_totec 自身）をプロジェクトとして評価しており、
  OCaml の fixture が入ったことで言語が2つになり、ファイルを持たないテスト用の行の言語が決まらなくなった。
  `language: "elixir"` を明示した。`info_test` は登録される言語・REPL の一覧を更新
- `./test/run.sh` 43ファイル・422件、`test/live` の iex 12件・ocaml 5件、すべて通過。CLI（作業用の写し）で
  scan → row/add → eval を2回（compare が same）確認

### 42.3 残り

- ~~dune のプロジェクト~~ → §43
- ~~ocamllsp の dialect~~ → 見送り（§42.4）
- 同じ名前のファイルが別のディレクトリに2つある構成（モジュール名と写しの置き場所が衝突する）
- `binary` の repr、`compare` の浮動小数点の許容誤差、1件ごとのメモリの上限
- 言語をまたぐ参照の変換（`next_step.md` §2.6）。`type` 列には OCaml の型がそのまま入るので、変換の割り当ての鍵に使える

### 42.4 ocamllsp は使わない（crux、2026-09-27）

dialect（`Scanner.Lsp.Ocaml`）を作る前に、ocaml-lsp-server 1.27.0（OCaml 5.5.0）を実機で確かめた:

| 機能 | 結果 |
|---|---|
| `documentSymbol` | 使える。トップレベルの値は kind 13、入れ子のモジュールは kind 2 の入れ物。`let ()`・トップレベルの式・型は値として出ない |
| `callHierarchy` | **非対応**（能力に `callHierarchyProvider` が無く、要求すると `Request not supported yet!`）。`Scanner.Lsp` は呼び出し関係をこれで取るので、そのままでは OCaml の link が1本も付かない |
| `references` | 同じファイルの中は取れる。ファイルをまたぐ参照は dune でビルドしても取れず、索引（`dune build @ocaml-index`）が要る。それを作る `ocaml-index` は nixpkgs に無い（merlin 5.8 にも同梱されていない、opam では入る） |

**決定（crux）**: 「要はファイル中に記述された関数同士の依存関係さえ分かれば良い」。それはテキストで読む
`Scanner.Ocaml` が満たしている（同じファイルの名前の出現と `Mod.name`）ので、ocamllsp の dialect は作らない。
入れ子のモジュールの中の定義はカードにならないままで、要るようになったら `Scanner.Ocaml` 側で読む。

## 43. OCaml の dune 対応 ── 依存は `dune ocaml top` から、自分のコードはソースから、ライブラリ名は別名で（2026-09-27、`~/my_app/tezcatl`セッション）

dune はビルドツールの項目（next_step §2.3: REPL は素の `ocaml` のまま、ビルドツールは起動の仕方だけを変える）。
`Repl.Language.Ocaml.launch_opts/3` の build_tool が `dune` のとき、初期化ファイルに2つを足す。

### 43.1 実機で確かめたこと（OCaml 5.5.0、dune 3.23.1）

- `dune ocaml top` は（プロジェクトをビルドしてから）`#directory`/`#load` を出す。依存するライブラリ（`str`、
  `OCAMLPATH` で見える外部パッケージ `yojson` 3.0.0）の行と、**プロジェクト自身のライブラリ**（`_build/…/mylib.cma`）の
  行が混ざる。自身の `.cma` を読むと、そのトップレベルの副作用（`let () = print_endline …`）が走る
- そこで、プロジェクトの根の下を指す行を除いた依存だけを読み、自身のコードはこれまでどおりソースから副作用なしで
  読む（`Embody.dune_deps`）。`dune ocaml top` は `embody` がトップレベルの中から実行する（`Unix.open_process_in`）
  ので、対象の環境（flake の dune・`OCAMLPATH`）で動く
- dune のライブラリは既定で包まれる（外からは `Mylib.Words`）。ソースから読んだモジュールは `Words` なので、
  `module Mylib = struct module Words = Words module Stats = Stats end` を定義する。定義は読み込みの再試行の
  合間に、メンバーがそろったものから（`Embody.load_all ~aliases`）。`bin/main.ml`（`Mylib.Words.count` を使う）は
  1回目に失敗し、別名の後で読めた
- 外部パッケージを使う関数（`Yojson.Safe.to_string`）も評価でき、多相ヴァリアントの型・値も取れた

### 43.2 決めたこと

- 別名は `dune` ファイルの `(library (name X))` とそのディレクトリのファイルから Elixir 側で作る
  （`Repl.Language.Ocaml.dune_aliases/2`）。作らないもの: `(wrapped false)`、ライブラリ自身の `x.ml` がある
  （それが入口のモジュール）、1つの `dune` ファイルに複数のライブラリ（`(modules …)` の振り分けを読まない）
- カード（スキャン）のモジュール名はファイル名のまま（`Words`）。`Mylib.Words.count` と書かれた呼び出しは、
  `Words.count` の部分で解決される
- `dune ocaml top` が失敗（ビルドエラーなど）しても、自身のソースの読み込みは続ける（`XT_LOAD_FAILED` を出す）
- **対象プロジェクトに `_build/` ができる**（dune のビルド）。elixir-ls の `.elixir_ls/` と同じく、
  「対象には何も書かない」原則からのずれとして記録する

### 43.3 確かめたこと・残り

- テスト: `ocaml_adapter_test` に4件（別名、作らない3つの場合、初期化ファイル、`launch_opts` の dune）、
  `test/live/repl_ocaml_test.exs` に dune の1件（fixture を一時ディレクトリへ写して動かす。`dune` が無ければ除外）。
  fixture `test/fixtures/ocaml_dune/`（`lib/` が `str` を使う包まれたライブラリ、`bin/main.ml` が `Mylib.Words` を使う）。
  `./test/run.sh` 43ファイル・426件、live の ocaml 6件、すべて通過。CLI（作業用の写し）で `table generate` が
  `build_tool=dune` と判定し、評価と link（`greet → count` など）が付くこと
- 同じ回に、`serve_input_test` の後始末の競合（サーバーがテストのプロセスと一緒に止まる間の `GenServer.stop`）を直した
- 残り: ppx を使うファイル（ソースをそのまま読むので前処理されない）、同名のファイル、複数ライブラリの `dune` ファイル

## 44. embody を別リポジトリへ（`~/my_app/embody/`）と、Haskell の準備（2026-09-27、`~/my_app/tezcatl`セッション）

crux の方針: `embody.ml`・`embody.hs` は公開にあたり別リポジトリにする。Haskell に入る前の準備として:

- `~/my_app/embody/` を作った（flake などのビルド設定は持たない）。中身は共用の説明 `ReadMe.md`（embody とは何か、
  全言語共通の出力の約束、言語ごとの読み込み方と状態）、`embody.ml`（xipe_totec の `lib/repl/ocaml/` から移した。
  冒頭のコメントを独立したリポジトリ向けに書き直した）、`embody.hs`（スタブ。§30.3 の `observe`・`cut` の型だけ。
  `observe` は「未実装」の `XT_ERROR_<id> crash` 行を返す。`ghc -Wall -fno-code` で警告なし）
- xipe_totec は `Repl.Ocaml.Launch.embody_path/0` で探す: `$XIPE_TOTEC_EMBODY_DIR`、無ければ xipe_totec の隣の
  `embody/`。見つからないときは初期化ファイルの `#mod_use` が失敗し、各行が `Unbound module Embody` の crash になる。
  作業用の写しで OCaml を評価するときは環境変数を渡す（CLAUDE.md）
- `~/my_app/nix/dev-tools.nix` に Haskell（`ghc`・`cabal-install`・`stack`・`haskell-language-server`）を足した。
  式の評価で確認（手元の nixpkgs で ghc 9.10.3・HLS 2.13.0.0）。なお `~/my_app/flake.nix` の入力 `path:./UniMath` の
  ディレクトリは今は無い（以前から。今回の変更とは無関係）
- テスト: `ocaml_adapter_test` に embody の置き場所の1件（環境変数を書き換えるので、このファイルは並行実行をやめた）。
  OCaml の単体 16件・実機 6件（移した `embody.ml` で）通過

## 45. GHCi の裏取り（2026-09-27、`~/my_app/tezcatl`セッション、GHC 9.10.3、実装なし）

next_step §2.4 の Haskell の最初の一歩。§30.3・§30.5 の設計のうち、GHCi で成り立つ形を確かめた。試作の `Embody`
（run・whnf・exact・shown・typed・limited）で、次の送り方が全ケースでマーカーを返した。

### 45.1 1件の送り方（`-fdefer-type-errors` の効く範囲に合わせる）

```haskell
let xt_<id> = <呼び出し>                      -- 呼び出しの型エラーは、ここで実行時まで遅れる
let xt_<id>_w = Embody.whnf xt_<id>           -- 呼び出しが走ったか（WHNF まで）
let xt_<id>_x = Embody.exact <前回> xt_<id>    -- Read・Show・Eq が無ければ、この束縛が実行時の TypeError になる
let xt_<id>_s = Embody.shown xt_<id>          -- Show が無ければ同上
let xt_<id>_t = Embody.typed xt_<id>          -- Typeable（全型にある）
Embody.run "<id>" <上限 µs> xt_<id>_w xt_<id>_x xt_<id>_s xt_<id>_t
```

- **`-fdefer-type-errors` は `let` の束縛にだけ効き、プロンプトで直接実行する式には効かない**（§30.5-1 の答え）。
  `Show` の無い値を実行の行に直接書くと、その行ごとコンパイルエラーになり、マーカーが出ずに締切まで待つことになる。
  そのため振り分けに使う式をすべて `let` で束縛し、実行の行は必ず存在する名前だけを参照する
- `run` は値を `evaluate` して、`whnf` → `exact`（TypeError なら次へ）→ `shown`（同）→ 型の順に試す。
  TypeError 以外の例外は `crash`。`timeout` の例外を `try` が捕まえないよう、`try` を `timeout` の外に置く
- 起動フラグ: `-v0 -fdefer-type-errors -Wno-deferred-type-errors -Wno-deferred-out-of-scope-variables`。
  読み込み後に `:module + *M ...`（export されていない関数も `M.f` で呼べる）

### 45.2 確かめたこと

| 項目 | 結果 |
|---|---|
| 起動 | `-v0` でバナー・プロンプト無し。`putStrLn ("XT_" ++ "READY")` は `hFlush` なしで pipe 越しにすぐ届く。小さな対象で約0.13秒 |
| 読み込み | ファイルをパスで渡す（`embody.hs` は小文字のまま読める）。`-isrc` で階層のあるモジュール。`main` は走らない |
| `exact` | `Int`・`[Shape]`（レコード構文を含む）・`Map`（`fromList [...]`）が読み戻せた。前回値と比べて `same`/`changed` |
| `unsupported` | 無限リスト（`show` を2000文字で切る。`Read` があっても切った長さを超えたら `exact` にしない）、関数（表示は型 `Int -> Int`）、`Show` の無い型（`Opaque`）、`IO` の値（`IO [Char]`、実行しない） |
| 失敗 | 例外（`head []`）→ `crash`（CallStack 付き）。呼び出しの型エラー（`add 1.5 2`）→ `crash`（GHC の文言）。構文エラー → `crash … Variable not in scope: xt_<id>`（本来の文言はマーカーの外） |
| 時間の上限 | `timeout` が解釈実行のループを止めた（割り当ての無い `go (k - 1 + 1)` も）。§30.4 の「密なループは割り込めない」は、コンパイル済みのコードの話で、解釈実行では起きなかった |
| 割り当ての上限 | `setAllocationCounter`＋`enableAllocationLimit` で `allocation limit exceeded`。生きているメモリではなく割り当ての総量 |
| SIGINT | 評価だけが止まり（`Interrupted.`）、GHCi は読み続ける → `interruptible: true` |

### 45.3 残り

- `IO` を返す関数の実行（`observeIO`）、`compare` の浮動小数点の許容誤差、割り当ての上限を使うかどうか
- stack・cabal 経由の起動（`stack ghci`・`cabal repl` の中で `embody.hs` を足す方法。ビルドツールの項目）
- 型の既定化（`ExtendedDefaultRules`）で引数の型が変わるか、構文エラーの文言をマーカーに入れる方法
- HLS の dialect を使うか（OCaml と同じく、ファイルの中の関数どうしの依存が分かればよい、という判断が当てはまるか）

## 46. Haskell の実装 ── GHCi＋`embody.hs`（1件6行）、テキストから読む Scanner（2026-09-27、`~/my_app/tezcatl`セッション）

§45 の裏取りの形を実装した。`embody.hs` は別リポジトリ（§44、git@github.com:Crux-xurC/embody.git に初版を push）。

### 46.1 部品

| 部品 | ファイル | 中身 |
|---|---|---|
| `embody.hs` | `~/my_app/embody/embody.hs` | `run`（whnf → exact → shown → 型の順、1回の書き込み）・`whnf`・`exact`・`shown`・`typed`・`cut`。`base` のみ。最初の段の TypeError は呼び出しそのものの型エラー・構文エラーなので、文言付きの `crash`。`try` は `timeout` の外 |
| 言語の申告 | `lib/repl/language/haskell.exs` | 拡張子 `hs`、REPL `ghci`、ビルドツール `stack`（`stack.yaml`）>`cabal`（`*.cabal`・`cabal.project`、判定のみ）。`launch_opts/3` は各ファイルの `module` 行からモジュール名と探索パス（`src/Geo/Shape.hs` → `src`）を決め、`:load`＋`:module + *M …` の GHCi スクリプトを一時ディレクトリに書く。`Main` が2つ以上なら `Main` を読まない |
| launch | `lib/repl/haskell/launch.exs` | `ghci -v0 -w -fdefer-type-errors -Wno-deferred-type-errors -Wno-deferred-out-of-scope-variables -i<dirs> -ghci-script <script>`、バナー無し・`ready_probe`・`:quit`・interruptible |
| eval_template | `lib/repl/haskell/eval_template.exs` | `let` の5行＋`Embody.run` の1行（§45.1）。引数の中の改行は空白にする（`let` の行が途中で終わらないように） |
| Eval.Scan / FieldDrip | `lib/repl/eval/scan/direct/ghci.exs`・`lib/repl/eval/field_drip/haskell.exs` | iex のものに委譲 |
| 共通 | `lib/repl/embody.exs` | embody の置き場所（`$XIPE_TOTEC_EMBODY_DIR`、無ければ xipe_totec の隣の `embody/`）。OCaml の launch もこれを使う |
| Scanner | `lib/scanner/haskell.exs` | テキストから。モジュールは `module` 行（無ければ `Main`）。行頭の小文字の名前で始まり `=` かガードを持つブロックが定義（型シグネチャ・キーワード・中置の定義・パターン束縛は除く、複数の節は1つ）。コメント（`--`（演算子の一部は除く）・入れ子の `{- -}`）・文字列・文字リテラル（名前の `'` は残す）は塗りつぶす。呼び出し関係は `M.f`（別名を解決）、同じモジュールの名前、修飾なしの import のモジュールの名前（自分自身は除く） |

### 46.2 確かめたこと

- テスト: `test/haskell_adapter_test.exs`（12件、GHC 不要）、`test/live/repl_haskell_test.exs`（5件、`ghci` が PATH に
  無ければ除外）、fixture `test/fixtures/haskell_sample/`（export リストで `hidden` を隠す `Target.hs`、`Target` を
  import する `src/Geo/Shape.hs`、`main` を持つ `app/Main.hs`）
- 既存のテストへの影響: `runner_test` の「登録されていない言語」の例が Haskell だったので Clojure に替えた。`info_test` は
  登録される言語・REPL の一覧を更新
- `./test/run.sh` 44ファイル・439件、live の iex 12件・ocaml 6件・ghci 5件、すべて通過。CLI（作業用の写し）で
  scan（16ノード・5リンク）→ row/add → eval（`exact`・`unsupported`・`timeout`・`crash`、`Main.greet`・
  export されていない `Target.hidden`）→ 2回目の eval で `exact` の7行が `compare=same`

### 46.3 残り

- ~~stack・cabal~~ → §47
- `IO` を返す関数の実行（`observeIO`）、構文エラーの文言をマーカーに入れる方法、浮動小数点の比較の許容誤差
- HLS は使わない方向（OCaml と同じく、ファイルの中の関数どうしの依存はテキストで取れる）。決めるのは crux

## 47. Haskell の cabal・stack 対応 ── GHCi を `cabal exec`・`stack exec` の下で起動する（2026-09-27、`~/my_app/tezcatl`セッション）

ビルドツールの項目（dune と同じ位置づけ、crux「これも薄く、GHCi に繋げるまでのパッチ」）。変えたのは
`Repl.Language.Haskell.launch_opts/3` が返す GHCi の起動の仕方（`:argv`）だけで、読み込み・送り方・embody は変えていない。

### 47.1 実機で確かめてから決めたこと（GHC 9.10.3・cabal-install 3.16.1.0・stack 3.9.3、依存は nix の `ghcWithPackages`）

| 案 | 結果 |
|---|---|
| A. `cabal repl` に起動を任せ、`:add embody.hs`・`:module + *M` を足す | 1つのコンポーネントなら動く（オフライン、`split` への依存も解決）。ライブラリと実行ファイルを一度に読む `--enable-multi-repl` では `:add`・`:module` が使えない（`Command is not supported (yet) in multi-mode`）ので embody を足せない |
| **B. 今の `ghci` の起動の前に `cabal exec --`・`stack exec --` を付ける**（採用） | 依存パッケージの見える環境だけを借り、読み込みは xipe のまま。ライブラリ・実行ファイルを一度に読める。依存の見えない素の `ghci` では同じ読み込みが失敗することも確認 |

- **`cabal exec` は、プロジェクトが一度もビルドされていないと起動しない**（ストアのパッケージデータベース
  `store/ghc-…/package.db` が無い、と GHC が止まる）。`--only-dependencies` のビルドでは、依存がすべて nix にあると
  何も作られない。プロジェクトのビルド（`cabal build all`）で作られる。そこで dune（`dune ocaml top` が毎回ビルドする）に
  合わせ、起動のたびに `cabal build --offline all` を走らせてから `cabal exec` する。出力は捨て、失敗しても GHCi の起動は
  続ける（ソースは GHCi が読むので、ビルドの成否には依存しない）。`sh -c '…; exec "$@"'` の形にして、GHCi のフラグは
  引数としてそのまま渡す
- `--offline`: 評価のたびに Hackage へ取りに行かない（§16.1 の「外部ネットワークには接続しない」）。依存はあらかじめ
  使える状態であること（nix・事前のビルド）
- `stack exec --` はビルドしなくても動いた（`resolver: ghc-9.10.3`・`system-ghc: true` の構成で、ネット無し）。stack には
  `--offline` に当たる大域の指定が無く、スナップショットの取得が要る構成ではネットに出る可能性がある
- 対象に `dist-newstyle/`（cabal）・`.stack-work/`（stack）ができる（`_build/`・`.elixir_ls/` と同じく原則からのずれ）

### 47.2 確かめたこと

- テスト: `haskell_adapter_test` に1件（ビルドツールごとの起動）。`test/live/repl_haskell_test.exs` に cabal（一度も
  ビルドしていない写しで、ライブラリの `Target.table` と実行ファイルの `Main.greet`）・stack の各1件（`cabal`・`stack` が
  PATH に無ければ除外。`CABAL_DIR`・`STACK_ROOT` は一時ディレクトリ）
- `./test/run.sh` 44ファイル・440件、live の ghci 7件、すべて通過。CLI（作業用の写し）で `table generate` が
  `build_tool=cabal` と判定し、ビルドから評価まで通ること

## 48. 対話窓の `--` の列に `scan`・`eval` の短縮形を書ける（2026-10-05、`~/my_app/tezcatl`セッション）

tezcatl で普段の流れを一周したとき、対話窓に `scan -- node/resolve … -- eval …` と打つと `input_error`
（`scan: 対話窓では引数を取りません`）になった。短縮形の `scan` は単独の行でしか読まれず、続けるには
`scan/run -- …` と method 名で書く必要があった。窓では `scan` と打つのが普通なので、列の中でも読む。

- `do` の無い行に `--` があれば列として読む（`XipeTotec.Input`）。各段は method 名か、窓の短縮形の
  `scan`・`eval [id...] [--include-writes]`。`eval` の段は `call_ids=[…]`（method の書き方）と裸の id
  （短縮形）を混ぜてよい。`--` を含まない単独の `eval …` は今までどおり
- `do` を付けた行は今までどおり `xipe do` と同じ読み方（短縮形は読まない。端末と1対1のまま）
- 列の区切りは `CommandLine.groups/1` を共用（`xipe do` と同じ）
- `help do` の説明に追記。`How_to_use.md` §6.2 は crux の Emacs で開いたままだったので今回は触っていない
- テスト: `input_test.exs` に1件。tezcatl の `test/e2e/xipe_input.mjs` に `scan -- row/list`

## 49. セッションの記録に起動時刻、Book の差分はまとめて1回で追記（2026-10-06、`~/my_app/tezcatl`セッション）

tezcatl と合同の軽いレビューで見つけた2点。

- `tables/session.json` の生存確認は `kill -0`（pid があるか）だけだったので、再起動や長い時間のあとで pid が
  別のプログラムに再利用されると、それをセッションと見誤り、`<dir>` を省いたコマンドの対象がずれる。
  記録に `os_started`（`ps -o lstart=` の起動時刻、C ロケール）を足し、読むときは同じ pid の起動時刻が
  一致するときだけセッションとする。`os_started` の無い古い記録は今までどおり pid だけで見る
  （`Session`、`session_test.exs` に2件）
- `Store.persist_diff` は変わった行ごとにファイルを開いて追記していた。関数の多いプロジェクトの scan では
  数百回になる。行を集めて1回で追記する（順序は同じ）。途中で切れた行の件（課題.md §6）とは別

## 50. 構造体を返す関数が `session_hung` になっていた（2026-10-06、`~/my_app/tezcatl`セッション）

コードの追跡で見つけ、作業用のコピーと実機の iex で確かめた。

- `EvalTemplate` が値の中を見る2か所 ── `unsupported` の判定（`xt_unsupported?`）と `compare` の比較（`xt_eq`）──
  は、map なら `Enum.any?`/`Enum.all?` を map そのものに掛けていた。構造体も map なので、`Enumerable` の無い構造体
  （`Date`・`URI`・プロジェクト自身の構造体）では `Protocol.UndefinedError`、`Enumerable` のある構造体（`MapSet`・
  `Range`）では要素が `{k, v}` でないので `FunctionClauseError` になる。`{:ok, %Date{}}` のように中に入っていても同じ
- 例外は子プロセスではなくセッション側の `receive` の中で起きるので、マーカーが出ない。その行は締め切りまで待って
  `session_hung`、同じパスの残りはすべて `aborted` になっていた
- 直し方: どちらも `Map.to_list/1` を通してから歩く（構造体の `__struct__` も1つの欄として比べるので、型の違う
  構造体は等しくならない）
- テスト: `repl_eval_template_test.exs` に2件（`Date`・`URI`・`MapSet`・`Range`・タプルや map の中の構造体・
  `@derive {Inspect, only: …}` の構造体＝`binary`・pid を含む map＝`unsupported`、構造体どうしの `compare`）。
  修正を外すと2件とも失敗することを確かめた

## 51. 評価中の行を構造で封じる・`eval/status`・`binary` の値は渡さない（2026-10-06、`~/my_app/tezcatl`セッション）

コードの追跡で見つけた2件（X-2・X-3）と、値の判定に制限が無いという指摘を、crux と相談して扱いを決めた。
方針（crux）: **基本の評価は素のコマンドのまま。不安のある値（`binary` など）だけ対話で決める。** 評価中の行の
変更は、見て避けるだけでなく**構造で封じる**（断る）。

**X-3 ── 評価中のパスをファイルに残し、その行の変更を断る**

- `Serve.Project` はパスを book のスナップショットで走らせ、終わった時点の book に結果を重ねる。その間に
  `row/update` で引数が変わると、計算に使っていない引数の行に値・`prev`・`compare` が書かれていた。CLI どうし
  （別の端末）でも、評価の結果を追記するときに同じことが起きる
- CLI はサーバーが動いていても `book.jsonl` に直接書く（課題 §2）ので、サーバーのメモリだけでは封じられない。
  新しい `XipeTotec.Passes` が、パスの言語ごとのグループを `tables/project/<id>_<名前>/passes/<pass_id>-<言語>.json`
  に置く（`Runner` が走らせる間だけ。`os_pid`・`os_started` で生死を見る ── `Session` と同じ。死んだ記録は読むときに消す）
- `row/update`（`Pipeline` の edit の段）・`row/set-result`・`row/remove`（`Dispatch`）は、その行が評価中なら
  `row_in_pass` で断る。行を変える経路はこの3つだけで、CLI・サーバー・対話のどれもここを通る
- サーバーのパスのプロセスが `Runner` の後始末なしに死んだときは、`Serve.Project` の DOWN で `Passes.clear/2`
  （OS のプロセスは生きているので、記録が生きて見えて行が封じられたままになるのを防ぐ）

**`eval/status`**

- 新しい method（`Dispatch`、読むだけ）。評価中のパスの言語・経過時間・対象の行と、いまの行・段・経過時間。
  サーバーでは順番待ちのパスも足す。`xipe do eval/status`・対話窓の `input` で使える

**値の判定の段を見せる（「判定が制限なしに走る」を閉じる）**

- 読み直すと、1件の締め切り（上限＋2秒）は書き込みから結果までの全体に掛かっていて、判定（`inspect`・評価し直し・
  compare）も含まれていた。問題は、固まったのが呼び出しか判定かを区別できず、どちらも `session_hung` になること
- Elixir の `EvalTemplate` が、子から値を受け取った時点で `XT_CALLED_<id>` を出す。`Evaluator` は `:progress` に
  `"calling"`／`"classifying"` を知らせ（`Runner` が `Passes` に書く）、判定の段で締め切りに当たった行は
  `session_hung (the call returned; judging its value -- repr, compare -- did not finish)` と記録する。
  OCaml・Haskell（embody）はまだ出さないので `calling` のまま（課題 §3 の E-A と一緒に）

**X-2 ── `binary` の値は次の呼び出しに埋め込まない**

- `Core.resolve_ref` は `exact` でも `binary` でも `result` を埋め込んでいたが、`binary` の `result` は表示だけで、
  定義上読み戻せない（`P.get_b(#P.S<a: 1, ...>)` が構文エラーになった。実機で確認）。埋め込むのは `exact` だけにし、
  `binary` は未評価・`unsupported` と同じく「渡せない値」として `skipped`。同じコマンドで参照先も評価すれば
  セッションの束縛で渡る。`bin` から作り直す道は、言語ごとの仕事を素のコマンドの経路に持ち込むので取らない
- `skipped` の行は理由で `dialogue depends <id>`（参照先の代わりの値を入れる）を案内する。`binary` などを
  決める専用の対話は、tezcatl との一貫テストのときに作る（crux）

テスト: `passes_test.exs`（新規、9件: 記録の一生、死んだ記録、`clear`、3つの method が断ること、`eval/status`
とその表示、`Runner` が走らせる間の記録、`skipped` の案内）、`repl_evaluator_test.exs` に2件（段の知らせ、
`XT_CALLED` のあとの `session_hung`）、`core_test.exs` に1件（`binary` は `skipped`、同じパスなら束縛、`exact` は
埋め込む。修正を外すと失敗）。作業用のコピーで CLI を2つ同時に動かし、評価中の `row/update` が断られ、
ほかの行は変えられ、終われば変えられること、`eval/status` が行と段を出すことを確かめた

## 52. `show` の失敗した行は、失敗とその理由を出す（S-2、2026-10-07、`~/my_app/tezcatl`セッション）

`Core.apply_result` は、評価が失敗した行の `result` を前回の値のまま残す（Book は記録なので書き換えない）。
`show`（CLI と対話窓が共通に使う `Show.lines`）はそれを値の欄に出していたので、`0  compare=same  state=eval_error`
のように古い値が今の値に見えた（tezcatl の実地確認 S-2）。

方針（crux）: **値は消さず、表示で示す**。結果はたいてい表で確かめるので、そこで失敗とその理由が分かればよい。
tezcatl の表（`lib/xipe-rows.js`）はすでに失敗の行を「`→ (error)`」と出し、`state`・`error` の列を持っていた。
`Show.lines` も合わせ、失敗の行は `(error: <理由>)  previous=<前回の値>  state=eval_error` と出す（前回の値が無ければ
`previous=` は出さない。`compare` も前回の評価のものなので出さない）。

テスト: `show_test.exs`（新規、4件。修正を外すと失敗の2件が落ちる）。tezcatl の E2E `xipe_input`・`xipe_skin`・
`matrix_skin` も通過

## 53. 引数の既定値を持つ関数は、受け付ける引数の数を人が `arity/set` で決める（2026-10-08、`~/my_app/tezcatl`セッション）

tezcatl の追跡（`../tezcatl/document/2026-10-08_追跡.md` §2）で、`def scale(x, k \\ 2)` のカードが `scale/2` だけになると
分かった。`scale(3)` の計算行は `row/add` が arity で断り、`scale(x)` と既定値に任せて呼ぶ関数からの link は
`link_failures` にも出ずに落ちていた（参照一覧から漏れる）。自前の解析でも elixir-ls 経由でも同じ。トレーサーは呼び出しを
実際の arity（`scale/1`）で記録し、node の照合キーは `{module, name, anykey = 2}` なので当たらない。

方針（crux）: **受け付ける引数の数は人が決める**（`effect/set` と同じ。P1・P4・P9）。Scanner は自動では書き込まない。
既定値の数え方は自前の解析（`Scanner.Elixir`）だけで、「一回やって駄目だったときに見せて、自分で入れてもらう」。
計算行を保存するときに既定値で埋めて node の arity に合わせる案は採らなかった ── 既定値がモジュールの中のもの
（`@default`・`helper()`）を指すと REPL では読めず、link の漏れも直らない。

- `arity/set id=<node> arities=[1,2]`（`Methods`、対話窓からも）: node の `arities` に保存する。node の anykey（定義の arity）を
  含み、それより大きい数は断る。anykey だけにすると消える。anykey が数でない node（OCaml・Haskell）は断る。
  `anykey` と id は変わらないので、既存の Book と計算行はそのまま。再スキャンでも `effect` と同じく引き継ぐ（`Scanner.put_defs`）
- 使うところ: `row/add`・`row/update` の確認（`Core.accepted_arities`）、link の照合（`Scanner.node_for` が、完全一致が無ければ
  同じモジュール・名前で `arities` に含む node を探す ── 自前の解析・elixir-ls の両方がここを通る）、表示（node は
  `M.scale/1..2`、計算行は呼ぶ arity の `M.scale/1`、`Core.call_label`）
- 見せるところ: `row/add` が arity で断ったとき、`ctx.root` があればそのファイルを `Scanner.Elixir.default_arities/4` で読み、
  「自前の解析では既定値の引数があり 1..2 で呼べます: arity/set id=… arities=[1,2] で決めてから」を足す。`scan/run` は、arity だけが
  違って当たらなかった呼び出しを `arity_misses`（`link_failures` とは別。「読めなかった」ではないので link の掃除に関わらない）に出す

テスト: `arity_set_test.exs`（新規、5件）。実機で、自前の解析と elixir-ls（mix プロジェクト、`via: stdio`）の両方で、`arity_misses` →
`arity/set` → 再スキャンで link が付くこと、`scale(4)` の計算行が評価されることを確かめた

## 54. `$n.…` が何も引けなかった `call_ids` は、全件の評価にしない（2026-10-09、`~/my_app/tezcatl`セッション）

tezcatl の追跡（`../tezcatl/document/2026-10-09_追跡.md` §1）で、README の例どおりの `xipe do row/add … -- eval call_ids=$0.id` が、
`row/add` が失敗すると Book の全件を評価すると分かった。コマンド列は失敗で止まらず（`Runner.run/4`）、失敗したコマンドへの
`$0.id` は `nil` になる。`call_ids=$0.id` は `[…]` が無いのでただの文字列で、まるごと `nil` に置き換わり、`List.wrap(nil)` = `[]` が
「`call_ids` を書かない ＝ 全件」と同じに読まれていた。pure・reads の行はすべて評価され、`include_writes=true` なら writes の行も走る。
対話窓（`Serve.Project` のパス）も `Runner.run/4` を通るので同じ。

方針（crux）: **書いたのに空の `call_ids` は断る**。`Runner` の `eval` は、`call_ids` が `nil` か、`nil` を含むリストなら
`invalid_params`（「call_ids が空です（$n.… の参照先が無い…）。何も評価していません」）を返す。書かない・`[]` が全件なのは
そのまま。`Pipeline.eval_params/1` も `nil` を `[]` に変えずに渡す（`eval/run` の経路）。コマンド列が失敗で止まらないのは変えない。

テスト: `runner_test.exs`（`call_ids=$0.id` と `[$0.id]` の両方で断り、何も評価しない）・`pipeline_test.exs`（`eval_params` が `nil` を残す）。
修正を外すと両方とも落ちることを確かめた。全体 475 件通過
