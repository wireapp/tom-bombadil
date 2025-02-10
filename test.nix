# Run e.g. with `nix build -f test.nix -vv`
#
# This example provides a meta data file and a derivation symlink directory for
# `ShellCheck` (shell script linter written in Haskell.)
let
  pkgs = import <nixpkgs> { };
  tom-bombadil = builtins.getFlake (toString ./.);
in
tom-bombadil.lib.${builtins.currentSystem}.bomDependenciesDrv pkgs [
  pkgs.haskellPackages.ShellCheck
]
  pkgs.haskellPackages
