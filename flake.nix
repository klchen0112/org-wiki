{
  description = "org-wiki — Org-native LLM Wiki tools for Emacs (read-only spike)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      buildFor =
        pkgs:
        let
          inherit (pkgs) lib;

          # The ELPA archive used by this nixpkgs revision has been retired.
          emacsPackages = (pkgs.emacsPackagesFor pkgs.emacs-nox).overrideScope (
            _final: prev: {
              org = prev.org.overrideAttrs (_old: {
                version = "9.8.10";
                src = pkgs.fetchurl {
                  urls = [
                    "https://elpa.gnu.org/packages/org-9.8.10.tar"
                    "https://raw.githubusercontent.com/emacs-elpa/mirror/refs/tags/2026-09-15/stable/gnu/org-9.8.10.tar"
                  ];
                  hash = "sha256-iQqd1cTx0nn27Qs9EGcNeWqsy3/ccaKmZc0VO+xGPx0=";
                };
              });
            }
          );

          # Pin typed tool schema support used by the Elisp memory server.
          mcp-server-lib = emacsPackages.mcp-server-lib.overrideAttrs (old: {
            version = "0.5.0";
            src = pkgs.fetchFromGitHub {
              owner = "laurynas-biveinis";
              repo = "mcp-server-lib.el";
              rev = "e93ef3a2c0b9d4e965321608f2b1c19ea655bb52";
              hash = "sha256-sz72k5bSedLweaX8rkP/BPttdsWCmOJY+jRT9A8JUEg=";
            };
            postPatch = (old.postPatch or "") + ''
              patchShebangs emacs-mcp-stdio.sh
            '';
          });

          runtimeDeps =
            epkgs:
            with epkgs;
            [
              org
              org-roam
              org-ql
            ]
            ++ [ mcp-server-lib ];

          devDeps =
            epkgs: with epkgs; [
              undercover
              package-lint
              relint
              # Optional integrations exercised by the skip-unless-guarded
              # integration tests; present here so those tests run in the
              # gates rather than skipping.  gptel stays out of
              # runtimeDeps: org-wiki-gptel.el is a soft dependency.
              consult
              embark
              gptel
            ];

          emacsForDev = emacsPackages.emacsWithPackages (epkgs: runtimeDeps epkgs ++ devDeps epkgs);

          packageSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./org-wiki.el
              ./org-wiki-health.el
              ./org-wiki-mcp.el
              ./org-wiki-commands.el
              ./org-wiki-gptel.el
              ./org-wiki-qmd.el
              ./org-wiki-memory.el
            ];
          };

          checkSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./org-wiki.el
              ./org-wiki-health.el
              ./org-wiki-mcp.el
              ./org-wiki-commands.el
              ./org-wiki-gptel.el
              ./org-wiki-qmd.el
              ./org-wiki-memory.el
              ./org-wiki-test.el
              ./org-wiki-commands-test.el
              ./org-wiki-gptel-test.el
              ./org-wiki-qmd-test.el
              ./org-wiki-memory-test.el
              ./tests/memory_stdio.py
              ./Makefile
              ./flake.nix
              ./scripts
              ./baselines
            ];
          };

          org-wiki = emacsPackages.trivialBuild {
            pname = "org-wiki";
            version = "0.1.0";
            src = packageSrc;
            packageRequires = runtimeDeps emacsPackages;
            meta = {
              description = "Org-native LLM Wiki tools for Emacs (read-only spike)";
              homepage = "https://github.com/jwiegley/dot-emacs";
              license = lib.licenses.bsd3;
            };
          };

          # Run a Makefile target in an isolated copy of the source.
          # Byte-compiled files are removed first: `make' would treat
          # store-copied .elc files (all timestamps are epoch) as
          # current, and coverage must instrument sources, not .elc.
          mkMakeCheck =
            name: target: extraInputs:
            pkgs.runCommand "org-wiki-check-${name}"
              {
                nativeBuildInputs = [
                  emacsForDev
                  pkgs.gnumake
                ]
                ++ extraInputs;
              }
              ''
                cp -r ${checkSrc}/. build
                chmod -R u+w build
                cd build
                patchShebangs scripts
                find . -name '*.elc' -delete
                export HOME="$TMPDIR"
                make ${target} EMACS=emacs
                touch $out
              '';
        in
        {
          package = org-wiki;

          devShell = pkgs.mkShell {
            packages = [
              emacsForDev
              pkgs.eask-cli
              pkgs.gitMinimal
              pkgs.python3
              pkgs.gnumake
              pkgs.lefthook
              pkgs.shfmt
              pkgs.nixfmt
              pkgs.lcov
            ];
          };

          checks = {
            build = org-wiki;
            compile = mkMakeCheck "compile" "build" [ ];
            tests = mkMakeCheck "tests" "test" [ ];
            memory-stdio = mkMakeCheck "memory-stdio" "test-memory-stdio" [
              pkgs.gitMinimal
              pkgs.python3
            ];
            lint = mkMakeCheck "lint" "lint" [ ];
            format = mkMakeCheck "format" "format-check" [
              pkgs.nixfmt
              pkgs.shfmt
            ];
            coverage = mkMakeCheck "coverage" "coverage-check" [ ];
            fuzz = mkMakeCheck "fuzz" "fuzz" [ ];
            # Benchmarks run to completion in the sandbox to prove the
            # harness works; the 5% regression gate runs in lefthook on
            # real hardware, where the committed baseline is valid.
            bench = mkMakeCheck "bench" "bench" [ ];
          };
        };
    in
    {
      packages = eachSystem (pkgs: rec {
        org-wiki = (buildFor pkgs).package;
        default = org-wiki;
      });

      devShells = eachSystem (pkgs: {
        default = (buildFor pkgs).devShell;
      });

      checks = eachSystem (pkgs: (buildFor pkgs).checks);

      formatter = eachSystem (pkgs: pkgs.nixfmt);
    };
}
