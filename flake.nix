{
  description = "Tom BOMbadil creates Bills-of-Materials (BOMs) and pushes them";

  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    ,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        haskellPackagesOverlay = {
          overrides = self: super: {
            tom-bombadil = super.developPackage {
              root = ./.;
              overrides = self: super: {
                aeson = super.aeson_2_2_3_0;
                hashable = pkgs.haskell.lib.doJailbreak super.hashable_1_4_7_0;
                attoparsec-aeson = super.attoparsec-aeson_2_2_2_0;
              };
            };
          };
        };

        haskellPackages = pkgs.haskellPackages.override haskellPackagesOverlay;

        formatters = [
          (pkgs.haskell.lib.justStaticExecutables pkgs.haskellPackages.ormolu)
          (pkgs.haskell.lib.justStaticExecutables pkgs.haskellPackages.cabal-fmt)
          pkgs.nixpkgs-fmt
          pkgs.treefmt
          pkgs.shellcheck
        ];

        treefmt-command = pkgs.writeShellApplication {
          name = "nix-fmt-treefmt";
          text = ''
            exec ${pkgs.treefmt}/bin/treefmt --config-file ./treefmt.toml "$@"
          '';
          runtimeInputs = formatters;
        };

        statix-command = pkgs.writeShellApplication {
          name = "statix-check";
          runtimeInputs = [ pkgs.statix ];
          text = ''
            statix check ${toString ./.} || exit 1
            echo "Statix check passed!"
          '';
        };

        # Not all GHC versions are expected to work. However, we're providing
        # dev envs to ease future development.
        ghcVersions = [
          "ghc92"
          "ghc94"
          "ghc96"
          "ghc98"
          "ghc910"
        ];

        haskellPackagesFor =
          ghc_version: (pkgs.haskell.packages.${ghc_version}).override haskellPackagesOverlay;
        additionalDevShells = builtins.listToAttrs (
          map
            (ghc_version: {
              name = ghc_version;
              value = (haskellPackagesFor ghc_version).shellFor {
                packages = p: [ p.tom-bombadil ];
                withHoogle = true;
                buildInputs = [
                  pkgs.ghcid
                  pkgs.statix
                  statix-command
                  # We need to be careful to not rebuild HLS, because that would be expensive.
                  (pkgs.haskell-language-server.override {
                    supportedGhcVersions = [ (pkgs.lib.removePrefix "ghc" ghc_version) ];
                  })
                  pkgs.cyclonedx-cli
                ] ++ formatters;
              };
            })
            ghcVersions
        );

        toplevelDerivations =
          pkgs: haskellPackages:
          let
            mk =
              pkg:
              pkgInfo {
                inherit pkg;
                inherit (pkgs) lib hostPlatform writeText;
              };
            out = allToplevelDerivations {
              inherit (pkgs) lib;
              fn = mk;
              # more than two takes more than 32GB of RAM, so this is what
              # we're limiting ourselves to
              recursionDepth = 2;
              keyFilter = k: k != "passthru";
              # only import the package sets we want; this makes the database
              # less copmplete but makes it so that nix doesn't get OOMkilled
              pkgSet = {
                inherit pkgs;
                inherit haskellPackages;
              };
            };
          in
          pkgs.writeText "all-toplevel.jsonl" (builtins.concatStringsSep "\n" out);

        # collects information about a single nixpkgs package
        pkgInfo =
          { lib
          , pkg
          , ...
          }:
          (
            with builtins;
            assert lib.isDerivation pkg;
            let
              # trace with reason
              trc = info: pkg: trace (info + ": " + toString pkg);

              # if thing is a list, map the function, else apply f to thing and return a singleton of
              # it
              mapOrSingleton = f: x: if isList x then map f x else [ (f x) ];

              # things to save from the src attr (the derivation that was created by a fetcher)
              srcInfo = {
                urls = (pkg.src.urls or (trc "package didn't have src or url" pkg [ ])) ++ [
                  (pkg.src.url or null)
                ];
              };

              dp = builtins.tryEval pkg.drvPath;

              # things to save from the meta attr
              metaInfo =
                let
                  m = pkg.meta or (trc "package didn't have meta" pkg { });
                in
                {
                  homepage = m.homepage or (trc "package didn't have homepage" pkg null);
                  description = m.description or (trc "package didn't have description" pkg null);
                  licenseSpdxId = mapOrSingleton
                    (l: {
                      id = l.spdxId or (trc "package license doesn't have a spdxId" pkg null);
                      name = l.fullName or (trc "package license doens't have a name" pkg null);
                    })
                    (m.license or (trc "package does not have a license" pkg null));

                  # based on heuristics, figure out whether something is an application for now this only checks whether this
                  # componnent has a main program
                  type = if m ? mainProgram then "application" else "library";

                  name = pkg.pname or pkg.name or (trc "name is missing" pkg null);
                  version = pkg.version or (trc "version is missing" pkg null);
                };
            in
            if dp.success then
              let
                info = builtins.toJSON (
                  srcInfo // metaInfo // { drvPath = builtins.unsafeDiscardStringContext dp.value; }
                );
              in
              info
            else
              trc "drvPath of package could not be computed" pkg { }
          );

        # this tries to recurse into pkgs to collect metadata about packages within nixpkgs
        # it needs a recusionDepth, because pkgs is actually not a tree but a graph so you
        # will go around in circles; also it helps bounding the memory needed to build this
        # we also pass a keyFilter to ignore certain package names
        # else, this just goes through the packages, tries to evaluate them, if that succeeds
        # it goes on and remembers their metadata
        # there's a lot of obfuscation caused by the fact that everything needs to be tryEval'd
        # reason being that there's not a single thing in nixpkgs that is reliably evaluatable
        allToplevelDerivations =
          { lib
          , pkgSet
          , fn
          , recursionDepth
          , keyFilter
          ,
          }:
          (
            let
              go =
                depth: set':
                let
                  evaluateableSet = builtins.tryEval set';
                in
                if evaluateableSet.success && builtins.isAttrs evaluateableSet.value then
                  let
                    set = evaluateableSet.value;
                  in
                  (
                    if (builtins.tryEval (lib.isDerivation set)).value then
                      let
                        meta = builtins.tryEval (fn set);
                      in
                      builtins.deepSeq meta (
                        builtins.trace ("reached leaf: " + toString set) (
                          if meta.success then [ meta.value ] else builtins.trace "package didn't evaluate" [ ]
                        )
                      )
                    else if depth >= recursionDepth then
                      builtins.trace ("max depth of " + toString recursionDepth + " reached") [ ]
                    else
                      let
                        attrVals = builtins.tryEval (builtins.attrValues (lib.filterAttrs (k: _v: keyFilter k) set));
                        go' =
                          d: s:
                          let
                            gone' = builtins.tryEval (go d s);
                          in
                          if gone'.success then gone'.value else builtins.trace "could not recurse because of eval error" [ ];
                      in
                      if attrVals.success then
                        (builtins.concatMap
                          (go' (
                            builtins.trace ("depth was: " + toString depth) (depth + 1)
                          ))
                          attrVals.value)
                      else
                        builtins.trace "could not evaluate attr values because of eval error" [ ]
                  )
                else
                  builtins.trace "could not evaluate package or package was not an attrset" [ ];
            in
            go 0 pkgSet
          );
        pkgsAsSymlinks =
          allLocalPackages:
          pkgs.symlinkJoin {
            name = "all-local-packages";
            paths = allLocalPackages;
          };
      in
      {
        packages = {
          default = haskellPackages.tom-bombadil;
          bomDependencies = self.lib.${system}.bomDependenciesDrv
            pkgs [ haskellPackages.tom-bombadil ]
            haskellPackages;
        };

        apps = {
          create-sbom = {
            type = "app";
            program = "${haskellPackages.tom-bombadil}/bin/create-sbom";
          };
          upload-bom = {
            type = "app";
            program = "${haskellPackages.tom-bombadil}/bin/upload-bom";
          };
        };

        # Development shell with required dependencies
        devShells = {
          default = additionalDevShells.ghc96;
        } // additionalDevShells;

        formatter = treefmt-command;

        checks = {
          statix =
            pkgs.runCommand "statix-check"
              {
                buildInputs = [ statix-command ];
              }
              ''
                statix-check > $out
              '';
        };

        lib = rec {
          bomDependenciesDrv =
            allPkgs: allLocalPackages: haskellPackages:
            pkgs.stdenv.mkDerivation (finalAttrs: {
              pname = "BOM dependencies";
              version = "0.1";

              src = ./.;

              buildPhase = ''
                mkdir -p $out

                cp ${toplevelDerivations allPkgs haskellPackages} $out/all-toplevel.jsonl

                ls ${pkgsAsSymlinks allLocalPackages}
                mkdir -p $out/all-local-packages
                cp -r ${pkgsAsSymlinks allLocalPackages}/* $out/all-local-packages
              '';
            });
        };
      }
    );
}
