# Xipe Totec 実装前確認書 (rev.2)

`~/my_app/xipe_totec_spec_v0.4.html`（v0.4仕様書）をベースにした設計打ち合わせの結果。rev.1に対するレビューで見つかった6件の着手前修正（A〜F）と、進めながら直す点・細かい点をすべて反映済み。仕様書本体（§6.6, §9）にはまだ反映していない差分がある（8章参照）。

**実装状況（2026-09-16、最新状況は次段落）**: `~/my_app/xipe_totec/` に着手済み（git stage済み、未commit）。Book/Store/Core（イベント適用・参照グラフ・循環検出・affected集合・effectフィルタ・topo_sort・plan_recalc・apply_results）/Identity/Scanner（AST抽出＋コンパイラトレーサーによるlink抽出、fix F込み）/Project（ディレクトリ横断の2パス走査＋差分書き込み）まで実装・テスト済み（46 ExUnit tests, all green）。`xipe scan <dir>` → `xipe show` の実機動作を2ファイル構成のサンプルで確認済み。REPLアダプタの接続方式は2026-09-18に分散Erlang接続からテキスト入出力方式へ転換した（10章参照）。

**実装状況（2026-09-18 更新）**: REPL評価パイプラインの中核が実機`iex`で確認済みになった。`Repl.Launch`/`Sender`/`Session`（起動・完了検知・離脱、10.1〜10.2節）、`EvalTemplate`（呼び出し式組み立て・安全装置・repr判定・マーカー印字、10.5節）、`Eval.Scan`/`Scan.Direct.Iex`/`Eval.FieldDrip`/`FieldDrip.Elixir`/`Eval.Result`/`Eval.Parser`（受信パーサー一式、10.6〜10.9節）、`heartbeat_input`（生存監視、10.10節）まで実装・実機テスト済み（`test/live/repl_iex_test.exs`、9テスト）。`lib/repl_*.exs`はディレクトリ構成へ整理済み（10.7節）。

**実装状況（2026-09-18 続報、`xipe eval`まで到達）**: 前段落末尾の「まだ無いもの」を全て実装・実機確認済み(11.1〜11.6節)。`compare`判定（対象ノード側での項比較、浮動小数点許容誤差込み）、`:max_heap`と通常crashの区別、`Parser`出力→`Core.apply_results`→`Store`の配線(`Repl.Evaluator`新設)、ハング判定(セッション全体の無応答をkill+abort)、CLIの`xipe eval`コマンド。加えてレビューで見つかった実バグ4件（`:DOWN`メッセージリーク、crash reasonの`inspect`オプション漏れ、`repr`のatom/string不一致、`basis`が`prev`ではなく`result`を見るべきだった設計ミス）を修正。`Project.find_sheets/1`は`.exs`も拾うよう拡張(11.5節)。全体テスト168件+実機テスト11件、全green（`serve_project_test.exs`の既知の間欠フレークを除く）。**まだ無いのは**: §16サーバー側の非同期`eval/run`(Tier3のまま、意図的に`Dispatch`未着手)、`cell/complete`の値ベース半分、`edit/propose`/`edit/apply`、`trace/*`。

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

Coreは評価を実行しない。計画を作る（純粋）→ Evaluatorが実行する（副作用あり）→ 結果を適用する（純粋）、の3段に分ける。**計画内部の参照（同じ計画内で先に評価される計算行への参照）は、計画作成時点では値が存在しないためテキスト埋め込みができない** ── プレースホルダ＋セッション変数束縛（`in_plan`）で渡す。計画外部の参照のうち、保存済みのexact/binary値を持つものだけがCoreによる文字列置換でそのまま埋め込める。unsupported＋pureな計画外参照は、値の埋め込みではなく呼び出し式そのものの再埋め込みが必要（§6.3）── これは言語構文の組み立てなのでCoreの仕事ではなく、Coreはmodule/name/argsを`inline_call`として渡すだけで、実際の式組み立てはEvaluator（REPLアダプタ）が行う（課題.mkd B回答）。それ以外（unsupported＋非pure、または未知の参照）はセッション変数束縛（`binding`）にフォールバックする。

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
  basis: {:text, String.t()} | {:bin, binary()} | :none,
  limits: %{timeout: pos_integer(), max_heap_words: pos_integer()}
}

Evaluator.run(plan, session) :: [Evaluator.Result.t()]
# Evaluatorはbookを知らない。正規化・repr判定・比較（許容誤差込み）はここ（REPLアダプタ)の仕事

%Evaluator.Result{
  call_id: id,
  outcome:
    {:ok, %{repr: :exact | :binary | :unsupported,
            display: String.t(), type: String.t(), bin: binary() | nil}}
    | {:error, reason} | :timeout | :max_heap
    | {:skipped, upstream_id} | {:lost, ref} | :aborted,
  compare: :none | :same | :changed | :skipped,
  evaluated_at: String.t(),         # ISO8601文字列。Store.appendがそのままJSON.encode!するため%DateTime{}は不可
  session_gen: non_neg_integer()
}

Core.apply_results(book, ctx, results) :: Book.t()
# ctx = %{pass_id, commit, commit_at, dirty} ── git読み取りはGenServer側で行い、ここに渡すだけ
```

補足:
- `eval_count`は`:ok`/`:error`/`:timeout`/`:max_heap`でのみ増やす。`:skipped`/`:lost`/`:aborted`では増やさない
- `:aborted`はセッションが実行途中で落ちた場合、残りのエントリに返す
- `bind_as`の指定があっても、実際に束縛を残すのは結果が`unsupported`のときだけ
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
- ~~**Erlang分散ノード接続**（`--sname`/cookie/epmdループバック限定）~~ **2026-09-18に撤回・10章のテキスト入出力方式に置き換え**（旧記述は課題.mkd Dに残るが、参照する場合は10章の決定が優先）

## 7. tezcatl連携（方針のみ。ビルド対象外）

rev.1の方針（`/xipe`をLSPソケットと同型で新設、既存`/lsp`をprovider経由で共有）は変更なし。追加で:

- **9.3節の範囲の明確化**: 確認書ではNIF境界の話として書いていたが、仕様上は依存ライブラリ全般・Elixir/OTPの版・Nixの入力すべてが対象。実装担当に狭く伝わらないよう明記しておく
- **複数タブからの応答**: 1本の接続を複数ブラウザタブで共有する構成では、Xipe Totecが送った`provider/*`要求に複数タブが応答しうる。**同じ要求IDへの最初の応答だけを採用する**とXipe Totec側で決めておけば、中継（tezcatl relay）は中身を見ないままで済む

## 8. 未決定・要検討事項 / フォローアップ

- 自然キー索引の具体的なデータ構造（保留、大きな問題にはならない想定）
- 階層コードの桁あふれ時の区切り文字は**不要と判明**（既に`.`区切りのため、ある階層だけ`103`のように桁が増えても読み取りに支障なし。保留事項から解消）
- `trace`/`run`テーブルのストレージ方式（ETS併用にするか）はv0.5で再検討
- **仕様書本体への反映が必要**: call_hashによる評価省略をやめた点（旧§6.6・§9の記述）は、v0.4仕様書のテキスト自体にまだ反映されていない。実装が固まった後で仕様書側も更新する

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
  - `lib/serve_project.exs`（`XipeTotec.Serve.Project`、GenServer、新規）── prebuild §3「1プロジェクト1GenServer」の実体。state=`%{book,root,store_file,sessions}`。`Dispatch`実行→Book差分を`Store.append`→応答。変更があれば`notify/rowChanged`等をattach中の全セッションへブロードキャスト（**id書き換えは無し** ── `LspServer`と違い外部の単一プロセスへ中継しているわけではなく、Xipe Totec自身がid空間の持ち主なので不要と判断）
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

**未着手（次のステップ）**: repr判定（対象ノード側で実行、a: pid/port/reference/fun検出 → unsupported、b: inspect+再評価の往復検査 → exact、c: term_to_binary → binary）、compare判定、`spawn_monitor`+`Process.flag(:max_heap_size, ...)`+`receive...after`の安全装置、マーカー印字、`bind_as`が指定されている場合のセッション変数束縛。これらは対象ノード自身で実行されるElixirコードのテキストとして組み立てる必要があり、呼び出し式組み立てより検証が難しい（`elixir -e`でロジック片は個別に検証できるが、実機のiexセッションでの動作確認はcrux側のライブ検証に委ねる部分が残る）。

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
3. **`Repl.Eval.Result`が`repr`をatomに変換していた**: `repr_atom/1`で`"exact"`等をatom `:exact`等に変換していたが、`core.exs`の`resolve_ref/4`は`ref_call.repr in ["exact", "binary"]`と**文字列**で比較している。atom化されたrepr値は文字列比較と絶対に一致しないため、「plan外の参照が確定済みexact/binary値ならリテラル文字列として埋め込む」という経路が、実際のEvaluator結果に対しては一度も発火しない状態だった(`core_test.exs`の既存テストは手書きの文字列フィクスチャを使っていたため気づかれていなかった)。また課題.mkd B2の「Coreに入る値はJSON化可能な型のみ」というルール自体にも反していた。atom変換をやめ、`eval_template`が印字した文字列をそのまま通すよう修正(`repr`/`compare`両方)。`bin`も同様の理由でbase64文字列のまま保持(decodeしない ── `Store.append`は全カラムを`JSON.encode!`するため、decode済みの生バイト列はJSON化できない)。
4. **`display=`が改行を含みうる値で行ベースパーサーを壊す可能性**: `width: :infinity`は"ソフトな"折り返しは防ぐが、独自`Inspect`実装が強制改行(`Inspect.Algebra.line/1`)を使う値には効かない。修正: (a) `repr=exact`の往復検査条件に`not String.contains?(xt_str, "\n")`を追加(改行を含む値はexactと判定しない)、(b) `unsupported`/`binary`分岐の`display=`は`xt_oneline`(改行を`\n`エスケープするヘルパ)を通す。
5. **(efficiency)** `Scan.Direct.Iex.strip_all/3`がハートビート1件ごとにバッファ全体を再スキャンしていた(O(件数×バッファ長))。`String.split/2`1回に書き換え。

全て`test/repl_eval_template_test.exs`/`test/repl_eval_result_test.exs`/`test/repl_eval_scan_direct_iex_test.exs`にテスト追加・実機(`test/live/repl_iex_test.exs`)で再確認。

### 11.2 `compare`判定の実装(課題.mkd C、分散Erlang撤回後もこの部分は撤回されていない)

`core.exs`の`build_entry/3`が`Plan.Entry.basis`を計算する際、**当初`call.prev`(1つ前の値)を参照していたのは設計ミスだった**と実機テストで判明: `apply_result/3`は`prev: row[:result]`(結果を上書きする直前の行の値)をセットするため、`prev`は常に「今回のevalより2つ前」の値を指す。次のevalの比較対象にすべきは「直近の(今から上書きされる)値」=`call.result`/`call.repr`/`call.bin`である。修正し、`basis`は`{:exact, prev_text} | {:binary, prev_base64} | :none`(前回reprが`unsupported`なら`:none`扱い、課題.mkd Cの「片側でもunsupportedならskipped」と整合)。

`EvalTemplate.build/1`が`entry.basis`に応じて対象ノード側で前回値を再構築するコードを生成: `exact`なら`Code.eval_string/1`、`binary`なら`Base.decode64!/1 |> :erlang.binary_to_term/1`。比較は項として再帰的に行い(map/list/tuple/struct対応)、floatのみ相対/絶対誤差を許容(`compare.float_rel_tol`/`float_abs_tol`、既定`1.0e-9`。**設定ファイル機構がこのプロジェクトに一切存在しないため**、今回は`EvalTemplate`のmodule属性に固定値として置いた ── 課題.mkd Cが求めた「設定パラメータ化」の完全な実現ではなく、意図的なスコープ縮小として明記)。結果は`compare=<none|skipped|changed|unchanged>`として`display=`と同じマーカー本文に追加で印字され、`FieldDrip`は元々汎用parseなので変更不要、`Result.success/3`がそのまま`compare`フィールドへ渡す。実機で`unchanged`→`changed`の遷移を確認済み。

### 11.3 `:max_heap`と通常crashの区別

`eval_template`が`Process.flag(:max_heap_size, ...)`超過による強制killを検知できるようにした: その特定pidに対して`:killed`理由の`:DOWN`を送りうるのは(タイムアウト時の`Process.exit(pid,:kill)`とは別のreceive節なので競合しない)このmax_heapフラグ以外に無いため、`xt_reason == :killed`で`XT_ERROR_<id> max_heap`を印字するよう分岐。`Repl.Eval.Result.error/3`に`"max_heap"`節を追加、`Core.apply_result/3`の既存`:max_heap`節にそのまま流れる。実機で`Enum.to_list(1..2_000_000)`を`max_heap_words: 1000`で評価し確認、セッション自体は生存続行することも確認。

### 11.4 `Repl.Evaluator`新設 ── `Parser`出力→`Core.apply_results`→`Store`の配線、ハング判定

`lib/repl/evaluator.exs`(`XipeTotec.Repl.Evaluator`)、`run_pass/3`: `Core.plan_recalc/3`と同じ`opts`(`:call_ids`/`:changed_node_ids`/`:include_writes`)を受け、1セッションを起動してPlanの全entryを順に流し込み、`Core.apply_results/3`まで畳み込んで`{:ok, new_book, results}`を返す(`xipe scan`/`xipe show`と同じ同期一発の形、prebuild.md自身が予告していた通り)。`:cwd`必須、`:ctx`(git情報、既定nilの3つ組)、`:launch_opts`(`Repl.Launch.build/1`への追加opts)、`:sender`(既定`Sender.Direct`)、`:heartbeat_interval_ms`/`:boot_timeout_ms`/`:hang_grace_ms`を受け付ける。

ハング判定: 各entryの`eval_template`自体は`entry.limits.timeout`以内に必ず何らかのマーカーで自己終端するが、**セッションそのもの**が完全に固まる(スケジューリングが止まりハートビートすら印字されない)場合はこの安全装置の外側になる。`entry.limits.timeout + 3 * heartbeat_interval_ms`の間、`:data`が一切(ハートビートも含め)届かなければハングと判定し、`sender.kill/1`でセッションを強制終了、そのentryは`{:error, "session_hung"}`、残りのentryは全て`:aborted`(`apply_result/3`の既存の`:aborted`節は本の上ではno-op ── 課題.mkd Dの「ノードダウン検知→残りentryを一括abortedに」という発想を、分散ノード前提撤回後の「セッションハング」に転用した形)。ハング後は`Session.close/4`を呼ばない(既にkill済みのhandleに対して再度`write/2`すると、実`Sender.Direct`は`{:exit_status,...}`受信後に自らGenServerを`{:stop,:normal,...}`するため、タイミング次第で`:noproc`になりうる ── `run_entries/5`が`{:ok,results}|{:hung,results}`のタグを返し、`:ok`の時だけ通常のgraceful closeを行うよう分離)。

テスト: `test/repl_evaluator_test.exs`(4件、実iex不要 ── `write/2`が`XT_BEGIN_<id>`を検知して即座に結果を返す/何も返さないフェイクSenderで、配線とハング経路を高速に検証)。実機smoke(未committed scratch script、`test/live/`には未追加)で2entryのplan(片方が他方を`⟦id⟧`参照)を実`iex`に通し、`apply_results`が正しく畳み込まれることも確認。

### 11.5 `Project.find_sheets/1`が`.exs`も拾うよう拡張

`xipe eval`のscripts-mode(`project_kind: scripts`、crux自身の実プロジェクトが該当)ではREPLへロードすべきファイル一覧に`find_sheets/1`の結果をそのまま使う設計だが、旧実装は`.ex`のみを対象にしていた ── cruxの実プロジェクトは`.exs`のみで`.ex`が一つも無い構成のため、このままでは`xipe eval`が常に空のfilesリストになり機能しない。`.ex`除外は元々「安全のため」ではなく(fix Fにより`.exs`のスキャン自体は元から安全)「entry-pointスクリプトと図書館コードの判別」目的だったため、`Path.wildcard`のパターンを`*.{ex,exs}`に拡張。`scan_dir/2`側の挙動(インデックス対象が増える)も含めて意図した変更。テスト追加、既存テスト(全て`.ex`のみのフィクスチャ)は無傷。

### 11.6 `xipe eval` CLIコマンド

`main.exs`に追加。`xipe eval [<dir>] [id...] [--mix]` ── `<dir>`省略時`.`、id省略時は本の全call、`--mix`で`iex -S mix`起動(既定はscripts-mode、`argv: ["iex"], files: Project.find_sheets(dir)`)。`git rev-parse HEAD`/`git show -s --format=%cI HEAD`/`git status --porcelain`から`ctx`(`commit`/`commit_at`/`dirty`)を組み立て(gitが無い/リポジトリでない場合は全て`nil`、失敗しても評価自体は続行)。結果は`Store.persist_diff/4`(6テーブル全部)で永続化し、call毎に1行(`repr`/`compare`/表示値、またはtimeout/max_heap/crash/skipped/lost/aborted)を出力。`xipe`実機で`.exs`のみのscripts-modeプロジェクトを対象に`scan`→`eval`→再`eval`(`compare=unchanged`確認)→git初期化後の再`eval`(commit/commit_at/dirty反映確認)まで一通り確認済み。§16サーバー側の`eval/run`(非同期・pass_id・`notify/rowChanged`配信)は意図的に未着手のまま(`Dispatch`の`@not_implemented`は変更していない) ── prebuild.md自身が「CLIは薄く先に作れる」としていた通り、こちらは別スコープ。

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

対応: 2段構え。①`Evaluator.wait_result/6`の判定を「受信のたびリセットされる沈黙時間」から「entry開始時に1回だけ固定する絶対デッドライン」に変更 ── ハートビートが届き続けても`grace_ms`(既定20秒)で必ず打ち切られる。②`EvalTemplate.build/1`の入口で`Code.string_to_quoted/1`により呼び出し式を検証し、失敗したら対象言語へ一切送らず、xipe_totec自身の側で組み立てた診断メッセージだけを印字する最小テンプレート(`build_syntax_error/3`)を返す ── 実機確認では20秒待たずに299msで即座にエラー化され、後続entryも正常に評価された。テスト: `test/live/repl_iex_test.exs`に実機テスト追加(セッションが継続入力待ちにならないことを確認)。

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
- **なぜ`Dispatch`の中ではなく外か**: `eval/run`/`row/update`は生きたREPL評価(I/O、数秒かかりうる)を伴う。`Dispatch.handle/4`は意図的に純粋(scan/runのファイル読み込み以外I/Oなし)、`Serve.Project`の`GenServer.call`も同期処理なので、ここに評価パスを直接組み込むとプロジェクト全体のリクエスト処理が評価中ずっと塞がる(課題.mkd Eが元々指摘していた点で、分散Erlang撤回後も撤回されていない)。そのため`Pipeline`の呼び出しは`Dispatch`の**外**(`Runner.run_one/4`と`Serve.Project.handle_call/3`、両方とも`Dispatch`に落ちる前に`Pipeline.handles?/1`でチェック)に置いた。`Dispatch`自身の`@not_implemented`リストにある`eval/run`/`row/update`はそのまま(`Pipeline`を経由しない呼び出し元への保険として)残してある。
- **段階の実行**: `run/5`が登録済みの段階を順に実行し、最初にエラーを返した段階で打ち切る(Bookは前段の結果を次段へ引き継ぐ)。テスト用に段階ハンドラの表を差し替え可能(`test/pipeline_test.exs`で偽の成功ハンドラを注入し、複数段階が正しく連結・伝播することを実際に証明 ── 今日の本番の段階は両方ともスタブなので、これが無いと逐次実行ロジック自体は未検証のままだった)。
- **今日の段階の中身は両方スタブ**: `"edit"`/`"eval"`とも`not_implemented`エラーを返すだけ。ユーザーから見た挙動は今日時点では変化なし(元々`Dispatch`の`@not_implemented`で同じエラーだったため) ── 純粋な配線替え。

テスト: `test/pipeline_test.exs`(9件)+`test/runner_test.exs`/`test/serve_project_test.exs`にそれぞれ1件(CLIとWS両方が同じ`pipelines.json`を経由することを確認)。全体テスト204件(fast)+12件(live)、green(既知の無関係なフレークのみ)。

**明日以降**: `"edit"`段(`Core.edit_args`/`set_prev`)、`"eval"`段(`Repl.Evaluator.run_pass/3`を非同期プロセスとして再利用する形、課題.mkd Eの設計を参照)を1つずつ実装していく。

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
