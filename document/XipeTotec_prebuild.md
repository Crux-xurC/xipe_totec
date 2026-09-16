# Xipe Totec 実装前確認書 (rev.2)

`~/my_app/xipe_totec_spec_v0.4.html`（v0.4仕様書）をベースにした設計打ち合わせの結果。rev.1に対するレビューで見つかった6件の着手前修正（A〜F）と、進めながら直す点・細かい点をすべて反映済み。仕様書本体（§6.6, §9）にはまだ反映していない差分がある（8章参照）。

**実装状況（2026-09-16）**: `~/my_app/xipe_totec/` に着手済み（git stage済み、未commit）。Book/Store/Core（イベント適用・参照グラフ・循環検出・affected集合・effectフィルタ・topo_sort・plan_recalc・apply_results）/Identity/Scanner（AST抽出＋コンパイラトレーサーによるlink抽出、fix F込み）/Project（ディレクトリ横断の2パス走査＋差分書き込み）まで実装・テスト済み（46 ExUnit tests, all green）。`xipe scan <dir>` → `xipe show` の実機動作を2ファイル構成のサンプルで確認済み。**未着手なのはEvaluator/REPLアダプタ（distributed Erlang接続・実評価）とCLIの`eval`/`row`系コマンド** ── 実プロジェクトでのライブ検証が要るため、crux側のトレースセッションに委ねる。

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

Coreは評価を実行しない。計画を作る（純粋）→ Evaluatorが実行する（副作用あり）→ 結果を適用する（純粋）、の3段に分ける。**計画内部の参照（同じ計画内で先に評価される計算行への参照）は、計画作成時点では値が存在しないためテキスト埋め込みができない** ── プレースホルダ＋セッション変数束縛で渡す（計画外部の参照だけが6.3節表通りテキスト埋め込みできる）。

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
  expr: String.t(),                 # 計画外の参照は埋め込み済み、計画内の参照はプレースホルダ
  inputs: [%{ref: id, var: atom(), from: :plan | {:session, gen}}],
  bind_as: atom() | nil,            # nodeがpureでない場合にCoreが指定。変数名はcall_idから決定的に生成
                                     # （inputsのvarと自然に一致する）
  basis: {:text, String.t()} | {:bin, binary()} | :none,
  limits: %{timeout: pos_integer(), max_heap: pos_integer()}
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
  evaluated_at: DateTime.t(),
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
- **Erlang分散ノード接続**（5.4節「REPLにモジュールを読み込ませる」からの変更点として明記）: `iex`起動コマンドに`--sname`とcookieを含める、epmdはループバックのみで待ち受けさせる、Xipe Totec自身とOTPの版が離れすぎると分散接続できない（互換は前後数メジャー版程度）という制約を配布時の注釈に加える。個人環境は双方Nixで固定するため問題にならない

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
- 次のステップ: 上記モジュールを実装に落とす。`Address`の列フィルタ実装から着手予定。
