#nix/dev-tools.nix
{ pkgs, beamPackages }:


with pkgs; [
  # --- Language servers (Scanner.Lsp が tezcatl なしで自分で起動するもの) ---
  # Elixir: Lsp.Transport.Stdio が起動する elixir-ls。tezcatl の nix/dev-tools.nix と同じもの
  # beamPackages 側を使い、xipe_totec と同じ Elixir/OTP でビルドされたものに揃える
  beamPackages.elixir-ls
]
