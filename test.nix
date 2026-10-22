{
  lib,
  pkgs,
  nixosModules,
  stub ? true,
}:
let
  agentStub = pkgs.writeShellScript "sentinelone-agent" ''
    while true; do
      ${pkgs.systemd}/bin/systemd-notify WATCHDOG=1 || true
      sleep 10
    done
  '';
  # fake agent package providing everything module.nix expects from cfg.package
  stubPackage = pkgs.runCommand "sentinelone-stub" { } ''
    mkdir -p $out/opt/sentinelone/{bin,ebpfs,ranger,lib,configuration}
    install -m 755 ${agentStub} $out/opt/sentinelone/bin/sentinelone-agent
    install -m 755 ${pkgs.writeShellScript "sentinelctl" ""} $out/opt/sentinelone/bin/sentinelctl
  '';
  # Synthetic data only: production token sources must never enter the store.
  fixtureToken = pkgs.writeText "synthetic-s1-token" "eyJ1cmwiOiAiaHR0cHM6Ly9zZW50aW5lbG9uZS1wcm9ncmFtLnNlbnRpbmVsb25lLm5ldCIsICJzaXRlX2tleSI6ICJmM2M4N2IyZTlhMWQ0YzZlIn0KCg==";
  defaultTestAttrs = {
    imports = [
      nixosModules.default
      "${pkgs.path}/nixos/tests/common/user-account.nix"
    ];
    users.users.alice.extraGroups = [ "wheel" ];
    security.sudo.wheelNeedsPassword = false;
    services.sentinelone = {
      enable = true;
      sentinelOneManagementTokenPath = "/run/synthetic-s1-token";
    }
    // lib.optionalAttrs stub { package = stubPackage; };
    systemd.services.sentinelone-test-token = {
      before = [ "sentinelone-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/install -m 600 ${fixtureToken} /run/synthetic-s1-token";
      };
    };
    systemd.services.sentinelone-init = {
      requires = [ "sentinelone-test-token.service" ];
      after = [ "sentinelone-test-token.service" ];
    };
  };
  evaluate =
    settings:
    import "${pkgs.path}/nixos/lib/eval-config.nix" {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        defaultTestAttrs
        { services.sentinelone = settings; }
      ];
    };
  options = (evaluate { }).options.services.sentinelone;
  failedSentinelAssertions =
    settings:
    lib.filter (
      entry: !entry.assertion && lib.hasInfix "services.sentinelone." entry.message
    ) (evaluate settings).config.assertions;
in
assert failedSentinelAssertions { customerId = "modern"; } == [ ];
assert
  failedSentinelAssertions {
    email = "legacy";
    serialNumber = "serial";
  } == [ ];
assert
  builtins.length (failedSentinelAssertions {
    customerId = "modern";
    email = "legacy";
    serialNumber = "serial";
  }) == 1;
assert
  builtins.length (failedSentinelAssertions {
    email = "legacy";
  }) == 1;
assert
  builtins.length (failedSentinelAssertions {
    serialNumber = "serial";
  }) == 1;
assert lib.all
  (
    option:
    lib.all (value: !option.type.check value) [
      ./test.nix
      "${fixtureToken}"
      "/nix/store/synthetic-token"
      "/nix/store"
      "relative/runtime-path"
      "/run/../unsafe"
      "/run/token\nextra"
    ]
  )
  [
    options.sentinelOneManagementTokenPath
    options.dataDir
  ];
assert options.sentinelOneManagementTokenPath.type.check "/run/secrets/s1-token";
assert options.dataDir.type.check "/var/lib/sentinelone";
pkgs.testers.nixosTest {
  name = "sentinelone" + lib.optionalString stub "-stub";
  nodes = {
    withoutCustomerId = defaultTestAttrs;

    withCustomerId = lib.recursiveUpdate defaultTestAttrs {
      services.sentinelone.customerId = "goon@goon.ventures-42069B00B5";
    };

    withDepracatedOptions = lib.recursiveUpdate defaultTestAttrs {
      services.sentinelone = {
        email = "goon@goon.ventures";
        serialNumber = "42069B00B5";
      };
    };
  };

  testScript = ''
    start_all()

    withoutCustomerId.wait_for_unit("sentinelone.service")
    withoutCustomerId.fail("grep -q '^S1_AGENT_CUSTOMER_ID=' /var/lib/sentinelone/configuration/install_config")
    withoutCustomerId.succeed("mountpoint -q /opt/sentinelone")
    withoutCustomerId.succeed("touch /opt/sentinelone/lib/.write-test && rm /opt/sentinelone/lib/.write-test")
    withoutCustomerId.fail("touch /opt/sentinelone/bin/.write-test")
    withoutCustomerId.fail("grep -q sentinelone /etc/fstab")
    withoutCustomerId.fail("journalctl -b --grep='ordering cycle' --quiet")

    withCustomerId.wait_for_unit("sentinelone.service")
    withCustomerId.succeed("grep -Fx 'S1_AGENT_CUSTOMER_ID=goon@goon.ventures-42069B00B5' /var/lib/sentinelone/configuration/install_config")

    withDepracatedOptions.wait_for_unit("sentinelone.service")
    withDepracatedOptions.succeed("grep -Fx 'S1_AGENT_CUSTOMER_ID=goon@goon.ventures-42069B00B5' /var/lib/sentinelone/configuration/install_config")
  '';
}
