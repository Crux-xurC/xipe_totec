{
  description = "Xipe Totec — spreadsheet-like structure (tables/IDs/references/recalculation) for functional-language projects";

  inputs = {
    # Same commit as ../tezcatl/flake.nix on purpose: Xipe Totec talks to a
    # target project's `iex` session as a distributed BEAM node, and
    # distributed Erlang needs the two ends' OTP versions to stay close.
    # Pinning the same nixpkgs revision keeps this repo, tezcatl, and any
    # personal (non-Mix) target project on the identical Elixir/OTP build.
    nixpkgs.url = "github:NixOS/nixpkgs/6201e203d09599479a3b3450ed24fa81537ebc4e";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      beamPackages = pkgs.beam.packages.erlang_27;

      # WS server stack for spec §16's WebSocket entry (§16 サーバーインター
      # フェース). cowlib/ranch/cowboy only -- xipe_totec is the server being
      # connected to (tezcatl's /xipe relay dials out to it), so no `gun`
      # (WS client) or `erlexec` (child-process spawn) here, unlike
      # ../tezcatl/nix/relay-packages.nix.
      relayPkgs = import ./nix/relay-packages.nix { inherit pkgs beamPackages; };
      relayDeps = [ relayPkgs.cowlib relayPkgs.ranch relayPkgs.cowboy ];
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          beamPackages.elixir
          beamPackages.erlang
        ] ++ relayDeps;

        shellHook = ''
          export XIPE_TOTEC_DIR="$PWD"
          export ELIXIR_ERL_OPTIONS="+fnu"

          # This is not a Mix project (no mix.exs) -- main.exs Code.require_file's
          # everything under lib/, same convention as ../tezcatl. No Hex deps
          # beyond cowlib/ranch/cowboy (nix/relay-packages.nix, 2026-09-17):
          # Core/Store/Scanner/CLI still lean on Elixir 1.18's built-in JSON
          # module and the stdlib alone. cowboy is on PATH via buildInputs
          # above but not required by any lib/*.exs yet -- the §16 WebSocket
          # listener module itself is still unwritten.

          xipe() {
            ( cd "$XIPE_TOTEC_DIR" && elixir main.exs "$@" )
          }

          echo "--------------------------------------------------"
          echo "🔧  Xipe Totec dev shell"
          echo "--------------------------------------------------"
          echo "  xipe <args>  : run the CLI (elixir main.exs <args>)"
          echo "  tests        : ./test/run.sh"
        '';
      };
    };
}
