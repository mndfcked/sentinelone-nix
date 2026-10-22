{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.services.sentinelone;
  customerId =
    if cfg.customerId != null then
      cfg.customerId
    else if cfg.email != null && cfg.serialNumber != null then
      "${cfg.email}-${cfg.serialNumber}"
    else
      null;
  runtimePath = types.addCheck types.str (
    value:
    !builtins.hasContext value
    && hasPrefix "/" value
    && value != "/"
    && value != "/nix/store"
    && !hasPrefix "/nix/store/" value
    && builtins.match "[^\n\r]*" value != null
    && all (part: part != "" && part != "." && part != "..") (tail (splitString "/" value))
  );
  mountPaths = [
    "bin"
    "ebpfs"
    "ranger"
  ];
  mkBindMount = path: {
    what = "${cfg.package}/opt/sentinelone/${path}";
    where = "/opt/sentinelone/${path}";
    type = "none";
    options = "bind,ro";
    requires = [
      "opt-sentinelone.mount"
      "sentinelone-init.service"
    ];
    after = [
      "opt-sentinelone.mount"
      "sentinelone-init.service"
    ];
    unitConfig = {
      DefaultDependencies = "no";
      Conflicts = "umount.target";
      Before = "umount.target";
    };
  };
  initConfig = pkgs.writeText "sentinelone-bootstrap-config.json" (
    builtins.toJSON {
      data_dir = cfg.dataDir;
      token_path = cfg.sentinelOneManagementTokenPath;
      package = toString cfg.package;
      customer_id = customerId;
    }
  );
  sentinelctlFhs = pkgs.buildFHSEnv {
    name = "sentinelctl";
    runScript = "/opt/sentinelone/bin/sentinelctl";
  };
  sentinelctlScript = pkgs.writeShellApplication {
    name = "sentinelctl";
    runtimeInputs = with pkgs; [
      config.systemd.package
      util-linux
      sentinelctlFhs
    ];
    text = ''
      if [ "$EUID" -ne 0 ]; then
        echo "$0 must be run with root privileges"
        exit 1
      fi

      exec nsenter --all \
        --target "$(systemctl show -P MainPID sentinelone)" \
        -- sentinelctl "$@"
    '';
  };
in
{
  options = {
    services = {
      sentinelone = {
        enable = mkEnableOption "SentinelOne Service";
        package = mkPackageOption pkgs "sentinelone" { };

        customerId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Set a customer specific identifier for the host. It is common practice to set this as your email and serial number separated by a hyphen.
          '';
          example = "me@gmail.com-FTXYZWW";
        };
        email = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Your email address, used to construct a unique customer ID. Deprecated in favour of customerId.";
          example = "me@gmail.com";
        };
        serialNumber = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Your host machines serial number, used to construct a unique customer ID. Deprecated in favour of customerId.";
          example = "FTXYZWW";
        };
        sentinelOneManagementTokenPath = mkOption {
          type = runtimePath;
          description = ''
            Absolute runtime filename containing a SentinelOne management/site token.
            Use a context-free string, for example a sops-nix or agenix secret path;
            Nix path values and store-backed strings are rejected to avoid copying secrets into the store.
          '';
          example = "/run/secrets/s1_mgmt_token";
        };
        dataDir = mkOption {
          type = runtimePath;
          description = "Absolute runtime directory as a context-free string, never a Nix path or store-backed string.";
          default = "/var/lib/sentinelone";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    warnings =
      optional (cfg.email != null) "services.sentinelone.email is deprecated in favour of customerId."
      ++ optional (
        cfg.serialNumber != null
      ) "services.sentinelone.serialNumber is deprecated in favour of customerId.";

    assertions = [
      {
        assertion = (cfg.customerId != null) -> (cfg.email == null && cfg.serialNumber == null);
        message = ''
          You cannot use services.sentinelone.customerId with the deprecated services.sentinelone.email and services.sentinelone.serialNumber options.
        '';
      }
      {
        assertion = (cfg.email != null) -> (cfg.serialNumber != null);
        message = ''
          services.sentinelone.email requires services.sentinelone.serialNumber to also be set.
        '';
      }
      {
        assertion = (cfg.serialNumber != null) -> (cfg.email != null);
        message = ''
          services.sentinelone.serialNumber requires services.sentinelone.email to also be set.
        '';
      }
    ];

    users.users.sentinelone = {
      isSystemUser = true;
      createHome = true;
      shell = "${pkgs.shadow}/bin/nologin";
      group = "sentinelone";
    };
    users.groups.sentinelone = { };

    # Do not let tmpfiles create/chown unvalidated legacy state.
    systemd.services.sentinelone-init = {
      before = [ "sentinelone.service" ];
      unitConfig.RequiresMountsFor = [ cfg.dataDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        UMask = "0077";
        ExecStart = "${getExe pkgs.python3} ${./bootstrap.py} ${initConfig}";
      };
    };

    environment.systemPackages = [
      cfg.package
      sentinelctlScript
    ];

    systemd.mounts = [
      {
        what = cfg.dataDir;
        where = "/opt/sentinelone";
        type = "none";
        # Keep component mounts from propagating back into the persistent source.
        options = "bind,rprivate";
        requires = [ "sentinelone-init.service" ];
        after = [ "sentinelone-init.service" ];
        # This late, service-owned mount must not precede local-fs.target:
        # its initializer waits for normal boot and runtime secret provisioning.
        unitConfig = {
          DefaultDependencies = "no";
          Conflicts = "umount.target";
          Before = "umount.target";
          RequiresMountsFor = [
            cfg.dataDir
            "/opt"
          ];
        };
      }
    ]
    ++ map mkBindMount mountPaths;

    systemd.services.sentinelone = {
      enable = true;
      description = "SentinelOne";
      requires = [ "sentinelone-init.service" ];
      after = [ "sentinelone-init.service" ];
      path = [
        pkgs.coreutils-full
        pkgs.gawk
        pkgs.zlib
        pkgs.libelf
        pkgs.bash
      ];
      unitConfig = {
        Description = "SentinelOne";
        After = [
          "uptrack-prefetch.service"
          "uptrack.service"
        ];
        RefuseManualStop = "yes";
        StartLimitInterval = "90";
        StartLimitBurst = "4";
        RequiresMountsFor = map (path: "/opt/sentinelone/${path}") mountPaths;
      };
      serviceConfig = {
        Type = "exec";
        ExecStart = "${cfg.package}/opt/sentinelone/bin/sentinelone-agent";
        WorkingDirectory = "/opt/sentinelone/bin";
        WatchdogSec = "30s";
        Restart = "on-failure";
        RestartSec = "4";
        ExecStop = "${lib.getExe sentinelctlFhs} control stop";
        MemoryAccounting = "yes";
        NotifyAccess = "all";
        TasksMax = "infinity";
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
