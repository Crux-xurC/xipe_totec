# xipe_totec ── 作業を始めるときの案内

記憶が無い状態からでも再開できるように、入口だけをまとめる。中身は各文書が正で、
ここはそこへの道案内。

## 最初に読む順

1. `README.md` ── 何のためのものか、何ではないか、設計原則 P1〜P10、いまどこまで動くか
2. `document/課題.md` ── いま何が未解決で、次に何をするか
3. `document/next_step.md` ── 次の段階の案。各項目の「コメント:」欄に crux の書き込みがあれば、それが最新の意向
4. 必要なときだけ: `document/動作原理.md`（どの順で何が呼ばれるか）、`document/How_to_use.md`（使い方）、
   `document/Old.md`（決定の経緯。コード中の「Old.md §N」はここ）

仕様書 `document/xipe_totec_spec_v0.4.html` は叩き台。`Old.md` の決定と食い違うときは `Old.md` を優先する。

## テスト

```
./test/run.sh                           # 全件（XIPE_TOTEC_LSP=off で走る。何も起動しない）
elixir test/live/repl_iex_test.exs      # 実機の iex を使うテスト（run.sh には入っていない）
```

## 実際に動かして確かめるとき（実環境を汚さない）

xipe_totec は自分の状態を `__DIR__` 基準の固定の場所に持つ（`tables/project/…/book.jsonl`、
`tables/session.json`、`info.json`）。環境変数で差し替えられないので、CLI を試すときは:

1. `lib/`・`main.exs`・`info.json`・`pipelines.json` を作業用ディレクトリへコピーする
2. 対象も `test/fixtures/calc_sample/` のコピーを使う
3. コピーした側で `XIPE_TOTEC_LSP=off elixir main.exs choice project <コピーした対象>` → `scan` → `do …` → `eval …`

tezcatl の画面から確かめるときは `../tezcatl/test/e2e/README.md`（隔離したポートで中継・偽の Xipe
サーバー・ヘッドレス Chromium を立てる。作業用のコピーもそこで作る）。

## git

`~/my_app` は複数のプロジェクトが入った1つの作業ツリーで、index には**無関係なステージ済みの変更が
常にある**。xipe_totec のコミットはパスを指定して、それらを巻き込まない:

```
git add -A -- xipe_totec
git commit -F <メッセージのファイル> -- xipe_totec          # メッセージは「xipe_totec: 」で始める
git -c core.quotepath=false show --name-only --format= HEAD | grep -v '^xipe_totec/'   # 何も出ないこと
```

push は `xipe_totec` リモートへ subtree split で送る:

```
S=$(git subtree split --prefix=xipe_totec HEAD)
git rev-parse $S^            # xipe_totec/main と同じであること（fast-forward）
git push xipe_totec $S:refs/heads/main
```

**commit も push も、crux が明示的に頼んだときだけ。**

## tezcatl との関係

- tezcatl（`../tezcatl`）は窓。どのプロジェクトを開くかを決めるのは xipe_totec（`xipe choice project`）
- tezcatl は xipe_totec の人向けの文字列を解釈しない（Old.md §17.2「I/Oは解析対象ではない」）
- tezcatl の対話窓は `input` `{"text": "<打った行>"}` だけを送る。行の意味は xipe_totec が決める。
  未実装の受け口は `document/課題.md` §2 の「tezcatl の対話窓が待っているもの」
