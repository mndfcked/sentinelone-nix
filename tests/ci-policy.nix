{ pkgs }:
let
  python = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.pyyaml
  ]);
  source = ../.;
in
pkgs.runCommand "sentinelone-ci-policy"
  {
    nativeBuildInputs = [ python ];
  }
  ''
    ${python}/bin/python ${source}/tests/test_ci_policy.py
    touch "$out"
  ''
