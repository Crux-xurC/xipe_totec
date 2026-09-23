# WS server stack for spec §16.1's "WebSocket（localhost）" entry point, plus
# erlexec for §10's REPL process spawning (`Repl.Sender.Direct`, 2026-09-22 --
# process-group isolation + group-wide interrupt/kill, Old.md §23).
# Same packages, same versions, same hashes as ../../tezcatl/nix/relay-packages.nix
# and ../../nix/exla-packages.nix (fetchHex hashes are content-addressed, so
# copying is safe as long as the version matches -- both of those pin the
# identical nixpkgs revision and erlang_27 that this flake.nix does).
#
# Still smaller than tezcatl's file: xipe_totec is the *server* being
# connected to for §16 (relay's /xipe connects out to it), so it needs
# cowboy itself but not `gun` (a WS *client* lib -- that's the relay's job).
# `erlexec` moved from "not needed" to "needed" once `xipe eval` started
# spawning real OS processes of its own (§10) -- a different spawn need
# than §16's WS server, not a contradiction of the note above.
{ pkgs, beamPackages }:

rec {
  cowlib = beamPackages.buildRebar3 rec {
    pname = "cowlib";
    version = "2.13.0";
    name = pname;
    src = pkgs.fetchHex {
      pkg = pname;
      version = version;
      sha256 = "sha256-4eEoTcP8Awpksa0Ng4KufpnaRsMka4FTGKS4SIc4AKQ=";
    };
  };

  ranch = beamPackages.buildRebar3 rec {
    pname = "ranch";
    version = "2.1.0";
    name = pname;
    src = pkgs.fetchHex {
      pkg = pname;
      version = version;
      sha256 = "sha256-JE7j+iphdScNjh/FkCT9nbx2KUoyEFfej4A7FHnnaRY=";
    };
  };

  cowboy = beamPackages.buildRebar3 rec {
    pname = "cowboy";
    version = "2.12.0";
    name = pname;
    src = pkgs.fetchHex {
      pkg = pname;
      version = version;
      sha256 = "sha256-inq+bRgzcs6yHKonCb7JKKsrcuGKORGqF3Fjm++CZR4=";
    };
    beamDeps = [ cowlib ranch ];
  };

  erlexec = beamPackages.buildRebar3 rec {
    pname = "erlexec";
    version = "2.3.4";
    name = pname;
    src = pkgs.fetchHex {
      pkg = pname;
      version = version;
      sha256 = "sha256-qwxsNWmp+ZH7/mYklhqIaIYQc4WJ/5260k25uyeuIzs=";
    };
    nativeBuildInputs = [ pkgs.gnumake ];
  };
}
