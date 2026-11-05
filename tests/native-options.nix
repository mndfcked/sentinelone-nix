{
  pkgs,
  lib,
  nixosModules,
}:
let
  evaluate =
    settings:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixosModules.default
        {
          services.sentinelone = settings;
          system.stateVersion = "25.11";
          boot.isContainer = true;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
        }
      ];
    }).config;
  valid = settings: builtins.all (a: a.assertion) (evaluate settings).assertions;
  base = {
    enable = true;
    sentinelOneManagementTokenPath = "/run/secrets/s1";
  };
  native = {
    enable = true;
    vendorManagedUpdates = true;
  };
  sourceLessPackage = pkgs.runCommand "sentinelone-source-less" { } "touch $out";
  badType =
    settings:
    !(builtins.tryEval (
      builtins.deepSeq (evaluate settings).services.sentinelone.sentinelOneManagementTokenPath true
    )).success;
  disabled = evaluate {
    enable = false;
    package = throw "disabled guard realized proprietary source";
  };
  # Capability simulation, not historical Nixpkgs release compatibility.
  # This module-system fixture intentionally has no system.preSwitchChecks option.
  withoutHook =
    settings:
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        ../module.nix
        {
          options.system.stateVersion = lib.mkOption {
            type = lib.types.str;
            default = "legacy";
          };
          options.assertions = lib.mkOption {
            type = lib.types.listOf lib.types.anything;
            default = [ ];
          };
          config = {
            _module.freeformType = lib.types.lazyAttrsOf lib.types.anything;
            services.sentinelone = settings // {
              package = pkgs.hello;
            };
          };
        }
      ];
    }).config;
  oldLegacy = withoutHook base;
  oldNative = withoutHook native;
  checks = [
    (valid base)
    (builtins.all (a: a.assertion) oldLegacy.assertions)
    (!(oldLegacy.system ? preSwitchChecks))
    (builtins.any (
      a: !a.assertion && lib.hasInfix "requires NixOS system.preSwitchChecks" a.message
    ) oldNative.assertions)
    (!(valid { enable = true; }))
    (valid native)
    (!(valid (native // { sentinelOneManagementTokenPath = "/run/secrets/s1"; })))
    (badType (native // { sentinelOneManagementTokenPath = "/nix/store/unsafe-secret"; }))
    (badType (base // { sentinelOneManagementTokenPath = pkgs.writeText "not-a-secret" ""; }))
    (!(valid (native // { package = sourceLessPackage; })))
    (!(valid (native // { customerId = "legacy"; })))
    (
      !(valid (
        native
        // {
          email = "legacy";
          serialNumber = "legacy";
        }
      ))
    )
    (!(valid (native // { dataDir = "/var/lib/sentinelone-nix"; })))
    (!(valid (native // { dataDir = "/var/lib"; })))
    (!(valid (native // { dataDir = "/var/lib/sentinelone-nix/payload"; })))
    (!(valid (native // { dataDir = "/nix/var/nix/gcroots/sentinelone-nix"; })))
    (!(valid (native // { dataDir = "/nix/var/nix/gcroots"; })))
    (!(valid (native // { dataDir = "/nix/var/nix/gcroots/sentinelone-nix/payload"; })))
    (valid (native // { dataDir = "/nix/var/nix/gcroots/sentinelone-nix-other"; }))
    (valid (base // { dataDir = "/nix/var/nix/gcroots/sentinelone-nix"; }))
    (builtins.isString disabled.system.preSwitchChecks.sentinelone)
    (!((evaluate native).systemd.services ? sentinelone))
    ((evaluate native).systemd.services.sentinelone-init.restartIfChanged == false)
    ((evaluate native).systemd.services.sentinelone-init.stopIfChanged == false)
    (builtins.all (mount: !lib.hasPrefix "/opt/sentinelone" mount.where)
      (evaluate native).systemd.mounts
    )
  ];
in
assert lib.assertMsg (builtins.all (x: x) checks) (builtins.toJSON checks);
pkgs.runCommand "sentinelone-native-options" { } "touch $out"
