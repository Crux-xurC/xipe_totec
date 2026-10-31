{
  description = "Xipe Totec — spreadsheet-like structure (tables/IDs/references/recalculation) for functional-language projects";

  inputs = {
    # The same nixpkgs revision as tezcatl's flake.nix on purpose: the two
    # run side by side (tezcatl's relay talks to `xipe start`), and one pin
    # keeps both, and a target project that uses the same pin, on the
    # identical Elixir/OTP build.
    nixpkgs.url = "github:NixOS/nixpkgs/6201e203d09599479a3b3450ed24fa81537ebc4e";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      beamPackages = pkgs.beam.packages.erlang_27;

      # WS server stack for the WebSocket entry -- cowlib/ranch/cowboy -- plus `gun`, the WS client
      # Scanner.Lsp's Lsp.Transport.Relay dials tezcatl's /lsp with.
      # `erlexec` is for a different spawn
      # need: `Repl.Sender.Direct` uses it to launch the target project's
      # REPL in its own process group, so a hang/interrupt on that REPL
      # can be signaled group-wide without touching xipe_totec's own
      # process or leaving grandchildren orphaned.
      relayPkgs = import ./nix/relay-packages.nix { inherit pkgs beamPackages; };
      relayDeps = [ relayPkgs.cowlib relayPkgs.ranch relayPkgs.cowboy relayPkgs.gun relayPkgs.erlexec ];
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          beamPackages.elixir
          beamPackages.erlang
        ]
        ++ (import ./nix/dev-tools.nix {
          inherit pkgs beamPackages;
        })
        ++ relayDeps;

        shellHook = ''
          export XIPE_TOTEC_DIR="$PWD"
          export ELIXIR_ERL_OPTIONS="+fnu"

          # This is not a Mix project (no mix.exs) -- main.exs Code.require_file's
          # everything under lib/, the same convention as tezcatl. The only Hex
          # packages are those of nix/relay-packages.nix (cowboy and its deps
          # for `xipe start`'s WebSocket server, gun for tezcatl's /lsp,
          # erlexec for the REPLs); the rest leans on Elixir 1.18's built-in
          # JSON module and the stdlib alone.

          # No cd: every file xipe_totec itself reads/writes (info.json,
          # pipelines.json, tables/project/<id>_<name>/{project.json,table,
          # book.jsonl}) resolves from main.exs's own __DIR__, so a relative
          # <path> argument stays relative to the caller's own CWD.
          xipe() {
            elixir "$XIPE_TOTEC_DIR/main.exs" "$@"
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
