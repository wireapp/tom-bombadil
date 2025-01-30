# tom-bombadil

Tom BOMbadil creates Bills-of-Materials (BOMs) and pushes them.

## Usage

There are three steps:

1. Create a JSON file with Nix meta data and a folder with links to derivations
   of concern.
1. Create the BOM file (`sbom.json`) from these inputs.
1. Push (upload) the BOM file to our dependency tracking service.

### 1. Create Inputs

This step needs access to your Nix context. It is provided as a Nix flake
library function.

```nix
  tom-bombadil = builtins.getFlake "git+file:///home/sven/src/tom-bombadil";
  bomDependencies = tom-bombadil.lib.${builtins.currentSystem}.bomDependenciesDrv pkgs localPkgs haskellPackages;
```

Where

- `pkgs` is the full package set (e.g. `nixpkgs`.)
- `localPkgs` are the packages to create BOM root entries for.
- `haskellPackages` `pkgs.haskellPackages` with overrides/overlays

The derivation can than be built with e.g. (for `wire-server`):

```nix
nix -Lv build -f nix wireServer.bomDependencies
```

This leads to a `results/` folder containing the mentioned files.

### 2. Create BOM file

`create-sbom` is a Haskell program. To execute it on the results folder run:

```shell
nix run ../tom-bombadil\#create-sbom -- --meta result/all-toplevel.jsonl --all-local-packages result/all-local-packages
```

This leads to the SBOM json file being written to `sbom.json`.

### 3. Push (upload) BOM file

To upload the `sbom.json` run:

```shell
nix run ../tom-bombadil\#upload-bom -- -p my-project -v 0.1 -k $MY_API_KEY -f sbom.json
```
