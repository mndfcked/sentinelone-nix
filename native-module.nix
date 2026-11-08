{
  lib,
  pkgs,
  config,
}:
let
  cfg = config.services.sentinelone;
  provider = import ./native-runtime.nix {
    inherit pkgs;
    systemdPackage = config.systemd.package;
    nativeWrappers = lib.mapAttrs (_: wrapper: toString wrapper.source) (
      lib.filterAttrs (_: wrapper: wrapper.enable) config.security.wrappers
    );
  };
  libraries = [
    pkgs.stdenv.cc.cc.libgcc
    (lib.getLib pkgs.stdenv.cc.cc)
    (lib.getLib pkgs.zlib)
    (lib.getLib pkgs.elfutils)
  ];
  bootConfig = pkgs.writeText "sentinelone-native-boot.json" (
    builtins.toJSON {
      schema = 1;
      enabled = true;
      native = true;
      data_dir = cfg.dataDir;
      bootstrap_deb = toString cfg.package.src;
      runtime = toString provider.runtime;
      runtime_deb = toString provider.deb;
      runtime_manifest = toString provider.manifest;
      dpkg = "${pkgs.dpkg}/bin/dpkg";
      dpkg_query = "${pkgs.dpkg}/bin/dpkg-query";
      dpkg_deb = "${pkgs.dpkg}/bin/dpkg-deb";
      systemctl = "${config.systemd.package}/bin/systemctl";
      nix_store = "${config.nix.package}/bin/nix-store";
      loader = "${pkgs.stdenv.cc.bintools.dynamicLinker}";
      library_path = "/opt/sentinelone/lib:${lib.makeLibraryPath config.programs.nix-ld.libraries}";
      path = "/usr/sbin:${
        lib.makeBinPath [
          pkgs.dpkg
          pkgs.coreutils
          pkgs.bash
          pkgs.gnutar
          pkgs.gzip
          pkgs.diffutils
          pkgs.glibc.bin
        ]
      }:/usr/bin:/bin";
    }
  );
  controller = "${lib.getExe pkgs.python3} ${./native-controller.py}";
  admin = pkgs.writeShellScriptBin "sentinelctl" ''
    exec ${controller} exec ${bootConfig} -- "$@"
  '';
in
{
  assertions = [
    {
      assertion = cfg.package ? src;
      message = "Native SentinelOne requires package.src containing the original vendor DEB.";
    }
  ];
  users.groups.sentinelone = { };
  users.users.sentinelone = {
    isSystemUser = true;
    group = "sentinelone";
    home = "/opt/sentinelone/home";
    createHome = false;
  };
  programs.nix-ld = {
    enable = true;
    inherit libraries;
  };
  environment.systemPackages = [ admin ];
  # Stage 2 runs this only at boot, never during switch activation. A freshly
  # enabled service on an already-running system must wait until the next boot.
  boot.postBootCommands = ''
    (umask 077; printf '%s\n' ${lib.escapeShellArg (toString bootConfig)} > /run/sentinelone-nix-boot-config)
  '';
  # Registration and provider changes happen only at boot, never activation.
  systemd.services.sentinelone-init = {
    description = "Experimental offline native SentinelOne boot reconciliation";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    restartIfChanged = false;
    stopIfChanged = false;
    unitConfig = {
      RequiresMountsFor = [
        cfg.dataDir
        "/var/lib/sentinelone-nix"
      ];
      ConditionPathExists = "/run/sentinelone-nix-boot-config";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0022";
      TimeoutStartSec = "180s";
      ExecStart = "${controller} reconcile ${bootConfig}";
    };
  };
}
