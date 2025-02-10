#!/usr/bin/env bash

set -e

nix build -f test.nix -vv
nix run .\#create-sbom -- --meta result/all-toplevel.jsonl --all-local-packages result/all-local-packages --root-package-name "ShellCheck"

nix develop --command bash -c "cyclonedx validate --input-file sbom.json"
