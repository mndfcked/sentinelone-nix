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
                ${pkgs.python3}/bin/python3 -B - ${./tests/native-vendor-observer.py} <<'PY'
                import os
                import runpy
                import stat
                import sys

                observer = runpy.run_path(sys.argv[1])
                validate = observer["validate_mapping"]
                target = "/var/lib/sentinelone-vendor-payload"
                vendor_uid = 1234


                def metadata(kind, mode, uid):
                    return os.stat_result((kind | mode, 0, 0, 1, uid, 0, 0, 0, 0, 0))


                parent = metadata(stat.S_IFDIR, 0o755, 0)
                root_link = metadata(stat.S_IFLNK, 0o777, 0)
                vendor_link = metadata(stat.S_IFLNK, 0o777, vendor_uid)
                validate(parent, root_link, target, vendor_uid)
                print("mapping: root-owned link accepted", flush=True)
                validate(parent, vendor_link, target, vendor_uid)
                print("mapping: vendor-owned link accepted", flush=True)

                for label, directory, mapping, link_target in (
                    ("foreign owner", parent, metadata(stat.S_IFLNK, 0o777, 2345), target),
                    ("wrong target", parent, vendor_link, target + "-other"),
                    (
                        "relative target",
                        parent,
                        vendor_link,
                        "../../var/lib/sentinelone-vendor-payload",
                    ),
                    ("directory mapping", parent, metadata(stat.S_IFDIR, 0o755, vendor_uid), target),
                    ("regular mapping", parent, metadata(stat.S_IFREG, 0o644, 0), target),
                    ("nonroot parent", metadata(stat.S_IFDIR, 0o755, vendor_uid), root_link, target),
                    ("group-writable parent", metadata(stat.S_IFDIR, 0o775, 0), root_link, target),
                    ("other-writable parent", metadata(stat.S_IFDIR, 0o757, 0), root_link, target),
                    ("symlink parent", metadata(stat.S_IFLNK, 0o777, 0), root_link, target),
                    ("regular parent", metadata(stat.S_IFREG, 0o644, 0), root_link, target),
                ):
                    try:
                        validate(directory, mapping, link_target, vendor_uid)
                    except AssertionError as error:
                        assert str(error), label + ": missing diagnostic"
                    else:
                        raise AssertionError(label + " accepted")
                    print("mapping: " + label + " rejected")
                PY
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
