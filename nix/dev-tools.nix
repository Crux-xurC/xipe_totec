#nix/dev-tools.nix
{ pkgs, beamPackages }:


with pkgs; [
  # --- Language servers (the ones Scanner.Lsp starts itself, without tezcatl) ---
  # Elixir: the elixir-ls Lsp.Transport.Stdio starts; the same one as tezcatl's nix/dev-tools.nix
  # taken from beamPackages, so it is built with the same Elixir/OTP as xipe_totec
  beamPackages.elixir-ls
]
