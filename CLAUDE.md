# xipe_totec ── 作業を始めるときの案内

記憶が無い状態からでも再開できるように、入口だけをまとめる。中身は各文書が正で、
ここはそこへの道案内。

## 最初に読む順

1. `README.md` ── 何のためのものか、何ではないか、設計原則 P1〜P10、いまどこまで動くか
2. `document/範囲.md` ── **動くと約束している範囲・その外で起きること・これから範囲に入れるもの（予定）**。
   いま未解決のこと・次にやることもここ（tezcatl の分は `../tezcatl/document/範囲.md`）
3. 言語やコマンドを足すとき: `document/拡張の手引き.md`（何を参考に、どういう動作を満たすか。壊してはいけない約束）
4. 必要なときだけ: `document/動作原理.md`（どの順で何が呼ばれるか）、`document/How_to_use.md`（使い方）

**`work_history/` は 2026-10-10 までの記録**（crux、2026-10-10 に移した）: `課題.md`（未解決の一覧と全体レビューの扱い）、
`Old.md`（決定の経緯。**コード中の「Old.md §N」はここ**）、`next_step.md`（次の段階の案と crux のコメント）、
`xipe_totec_spec_v0.4.html`（仕様書の叩き台。`Old.md` の決定と食い違うときは `Old.md` を優先）。
**ふだんは読まない。書き足さない。** `範囲.md` の「根拠」から辿るとき、ある判断の経緯を知りたいときだけ開く。
ほかの文書にある `課題.md`・`Old.md`・`next_step.md` の名前は、`work_history/` の同名のファイルを指す。
これからの経緯は git のコミットメッセージに、決めた範囲は `範囲.md` に書く。

**レビュー・検証をするとき**は、先に `document/範囲.md`（と `../tezcatl/document/範囲.md`）を読む。範囲の外で
書いてあるとおりに起きることは、不具合として挙げない（挙げてよい場合は同文書の「読み方」）。過去の指摘と
その扱いは `work_history/課題.md` §6「全体レビュー（2026-10-02〜03）」。

`../tezcatl/document/Poca — 開発開始のための文書.md`（poca ── tezcatl を開く側のブラウザ、最後の方で作る別のプロジェクト）は、
xipe_totec の実装作業では読まなくてよい（crux、2026-10-08）。

## テスト

```
./test/run.sh                           # 全件（XIPE_TOTEC_LSP=off で走る。何も起動しない）
elixir test/live/repl_iex_test.exs      # 実機の iex を使うテスト（run.sh には入っていない）
nix shell nixpkgs#ocaml nixpkgs#dune_3 -c elixir test/live/repl_ocaml_test.exs   # 実機の ocaml・dune（無ければ除外）
nix shell nixpkgs#ghc -c elixir test/live/repl_haskell_test.exs                   # 実機の GHCi（無ければ除外）
```

## 実際に動かして確かめるとき（実環境を汚さない）

xipe_totec は自分の状態を `__DIR__` 基準の固定の場所に持つ（`tables/project/…/book.jsonl`、
`tables/session.json`、`tables/logging_buffer.txt`、`info.json`）。環境変数で差し替えられないので、CLI を試すときは:

1. `lib/`・`main.exs`・`info.json`・`pipelines.json`・`defaults.json`・`project_env.json` を作業用ディレクトリへコピーする（OCaml・Haskell を評価するなら
   `XIPE_TOTEC_EMBODY_DIR=~/my_app/embody` も。embody は別リポジトリで、既定では xipe_totec の隣を探す）
2. 対象も `test/fixtures/calc_sample/` のコピーを使う
3. コピーした側で `XIPE_TOTEC_LSP=off elixir main.exs choice project <コピーした対象>` → `scan` → `do …` → `eval …`

tezcatl の画面から確かめるときは `../tezcatl/test/e2e/README.md`（隔離したポートで中継・偽の Xipe
サーバー・ヘッドレス Chromium を立てる。作業用のコピーもそこで作る）。

## git

xipe_totec はこのディレクトリが独立した git リポジトリ（2026-10-01 から。`origin` =
`git@github.com:Crux-xurC/xipe_totec.git`、ブランチ `main`）。普通に `git commit` / `git push origin main`
する。`~/my_app` 側の git はもう xipe_totec を追跡しない（`~/my_app` は手元専用の別リポジトリ）。

`tables/`（プロジェクトの登録・Book・選択中のプロジェクト `selection.json`・`session.json`）は
マシンごとのデータで git 管理外。

**commit も push も、crux が明示的に頼んだときだけ。**

## tezcatl との関係

- tezcatl（`../tezcatl`）は窓。どのプロジェクトを開くかを決めるのは xipe_totec（`xipe choice project`）
- tezcatl は xipe_totec の人向けの文字列を解釈しない（Old.md §17.2「I/Oは解析対象ではない」）
- tezcatl の対話窓は `input` `{"text": "<打った行>"}` だけを送る。行の意味は xipe_totec が決める。
  未実装の受け口は `document/範囲.md` の「予定」
