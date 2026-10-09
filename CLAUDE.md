# xipe_totec ── 作業を始めるときの案内

記憶が無い状態からでも再開できるように、入口だけをまとめる。中身は各文書が正で、
ここはそこへの道案内。

## 最初に読む順

1. `README.md` ── 何のためのものか、何ではないか、設計原則 P1〜P10、いまどこまで動くか
2. `document/課題.md` ── いま何が未解決で、次に何をするか
3. `document/next_step.md` ── 次の段階の案。各項目の「コメント:」欄に crux の書き込みがあれば、それが最新の意向
4. 言語やコマンドを足すとき: `document/拡張の手引き.md`（何を参考に、どういう動作を満たすか。壊してはいけない約束）
5. 必要なときだけ: `document/動作原理.md`（どの順で何が呼ばれるか）、`document/How_to_use.md`（使い方）、
   `document/Old.md`（決定の経緯。コード中の「Old.md §N」はここ）

**レビューするとき**は、先に `document/課題.md` §6「全体レビュー（2026-10-02〜03）」と
`../tezcatl/forAI/progress.md` の同名の節を読む。既知の指摘と、判断済み（仕様どおり・受け入れ・
決定済みで未実装）のものが載っている。

`../tezcatl/document/Poca — 開発開始のための文書.md`（poca ── tezcatl を開く側のブラウザ、最後の方で作る別のプロジェクト）は、
xipe_totec の実装作業では読まなくてよい（crux、2026-10-08）。

仕様書 `document/xipe_totec_spec_v0.4.html` は叩き台。`Old.md` の決定と食い違うときは `Old.md` を優先する。

## テスト

```
./test/run.sh                           # 全件（XIPE_TOTEC_LSP=off で走る。何も起動しない）
elixir test/live/repl_iex_test.exs      # 実機の iex を使うテスト（run.sh には入っていない）
nix shell nixpkgs#ocaml nixpkgs#dune_3 -c elixir test/live/repl_ocaml_test.exs   # 実機の ocaml・dune（無ければ除外）
nix shell nixpkgs#ghc -c elixir test/live/repl_haskell_test.exs                   # 実機の GHCi（無ければ除外）
```

## 実際に動かして確かめるとき（実環境を汚さない）

xipe_totec は自分の状態を `__DIR__` 基準の固定の場所に持つ（`tables/project/…/book.jsonl`、
`tables/session.json`、`info.json`）。環境変数で差し替えられないので、CLI を試すときは:

1. `lib/`・`main.exs`・`info.json`・`pipelines.json` を作業用ディレクトリへコピーする（OCaml・Haskell を評価するなら
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
  未実装の受け口は `document/課題.md` §2 の「tezcatl の対話窓が待っているもの」
