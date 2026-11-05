{
  description = "SentinelOne for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # Only used during development, can be disabled by flake users like this:
    #   sentinelone.inputs.treefmt-nix.follows = "";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      flake-parts,
      nixpkgs,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } (
      {
        inputs,
        lib,
        withSystem,
        ...
      }:
      {
        imports = [
          inputs.flake-parts.flakeModules.easyOverlay
        ]
        ++ (if inputs.treefmt-nix ? flakeModule then [ inputs.treefmt-nix.flakeModule ] else [ ]);
        systems = [
          "x86_64-linux"
        ];
        perSystem =
          {
            config,
            pkgs,
            system,
            ...
          }:
          {
            overlayAttrs = {
              inherit (config.packages) sentinelone;
            };

            packages = {
              sentinelone = pkgs.callPackage ./package.nix { };
              # VM test using the real agent package, not publicly fetchable
              vmtest = import ./test.nix {
                inherit lib pkgs;
                inherit (self) nixosModules;
                stub = false;
              };
            };

            checks = {
              default = self.checks.${system}.vmtest;
              vmtest = (
                import ./test.nix {
                  inherit lib pkgs;
                  inherit (self) nixosModules;
                }
              );
              vendor-runtime = import ./tests/runtime-probe.nix { inherit pkgs; };
              bootstrap = import ./tests/bootstrap.nix {
                inherit lib pkgs;
                inherit (self) nixosModules;
              };
              ci-policy = import ./tests/ci-policy.nix { inherit pkgs; };
              native-runtime = import ./tests/native-runtime.nix { inherit pkgs; };
              native-options = import ./tests/native-options.nix {
                inherit lib pkgs;
                inherit (self) nixosModules;
              };
              native-backend = import ./tests/native-backend.nix {
                inherit lib pkgs;
                inherit (self) nixosModules;
              };
              native-controller = pkgs.runCommand "native-controller-faults" { } ''
                ${pkgs.python3}/bin/python3 -B ${./tests/native-controller.py} ${./native-controller.py}
                touch $out
              '';
              native-observer = pkgs.runCommand "native-observer" { } ''
                ${pkgs.python3}/bin/python3 -B ${./tests/native-vendor-observer.py} mount-smoke > $out
              '';
            };
          }
          // lib.optionalAttrs (inputs.treefmt-nix ? flakeModule) {
            treefmt = {
              programs.nixfmt = {
                enable = true;
                package = pkgs.nixfmt;
              };
              programs.mdformat.enable = true;
            };
          };

        flake = {
          nixosModules = {
            default = {
              imports = [
                ./module.nix
              ];
              nixpkgs.overlays = [
                self.overlays.default
              ];
            };
            sentinelone = self.nixosModules.default;
          };
        };
      }
    );

}
