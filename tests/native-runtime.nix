{
  pkgs,
  lib ? pkgs.lib,
}:
let
  wrapperSources = {
    id = "${pkgs.coreutils}/bin/id";
    systemctl = "${pkgs.systemd}/bin/systemctl";
  };
  provider = import ../native-runtime.nix {
    inherit pkgs;
    nativeWrappers = wrapperSources;
  };

  debClosure = pkgs.closureInfo { rootPaths = [ provider.deb ]; };

  syntheticDeb =
    { name, depends }:
    let
      control = pkgs.writeText "${name}-control" ''
        Package: ${name}
        Version: 1
        Architecture: all
        Maintainer: Native runtime test <noreply@example.invalid>
        Depends: ${depends}
        Description: Synthetic dependency contract fixture only
      '';
      payload = pkgs.writeText "${name}-purpose" "Synthetic dependency fixture only.\n";
    in
    pkgs.runCommand "${name}.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p "$TMPDIR/package/DEBIAN" "$TMPDIR/package/usr/share/${name}"
        cp ${control} "$TMPDIR/package/DEBIAN/control"
        cp ${payload} "$TMPDIR/package/usr/share/${name}/purpose.txt"
        dpkg-deb --build --root-owner-group "$TMPDIR/package" "$out"
      '';

  positiveDependencyDeb = syntheticDeb {
    name = "sentinelone-runtime-positive-dependency-test";
    depends = "coreutils, passwd, kmod";
  };
  versionedDependencyDeb = syntheticDeb {
    name = "sentinelone-runtime-versioned-dependency-negative-test";
    depends = "coreutils (>= 0)";
  };
  unrelatedDependencyDeb = syntheticDeb {
    name = "sentinelone-runtime-unrelated-dependency-negative-test";
    depends = "sentinelone-runtime-unprovided-capability";
  };
  maintscriptProbeControl = pkgs.writeText "sentinelone-runtime-maintscript-probe-control" ''
    Package: sentinelone-runtime-maintscript-probe
    Version: 1
    Architecture: all
    Maintainer: Native runtime test <noreply@example.invalid>
    Depends: sentinelone-nix-runtime
    Description: Synthetic maintscript interpreter probe
  '';
  maintscriptProbePreinst = pkgs.writeText "sentinelone-runtime-maintscript-probe-preinst" ''
    #!/bin/bash
    set -eu
    PATH=/sbin:/bin:/usr/sbin:/usr/bin
    export PATH
    id -u > /tmp/sentinelone-native-runtime-maintscript-uid
  '';
  maintscriptProbeDeb =
    pkgs.runCommand "sentinelone-runtime-maintscript-probe.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p "$TMPDIR/package/DEBIAN"
        cp ${maintscriptProbeControl} "$TMPDIR/package/DEBIAN/control"
        cp ${maintscriptProbePreinst} "$TMPDIR/package/DEBIAN/preinst"
        chmod 0755 "$TMPDIR/package/DEBIAN/preinst"
        dpkg-deb --build --root-owner-group "$TMPDIR/package" "$out"
      '';
in
pkgs.testers.runNixOSTest {
  name = "sentinelone-native-runtime-provider";

  nodes.machine = { ... }: {
    environment.systemPackages = [
      pkgs.dpkg
      pkgs.python3
    ];
    security.wrappers = lib.mapAttrs (_: source: {
      inherit source;
      owner = "root";
      group = "root";
    }) wrapperSources;
    users.groups.sentinelone = { };
    users.users.sentinelone = {
      isSystemUser = true;
      group = "sentinelone";
      home = "/var/empty";
      createHome = false;
    };

    virtualisation.mountHostNixStore = lib.mkForce true;
    virtualisation.useNixStoreImage = lib.mkForce false;
    virtualisation.writableStore = lib.mkForce false;
    virtualisation.useHostCerts = lib.mkForce false;
    virtualisation.qemu.networkingOptions = lib.mkForce [ "-net none" ];
    virtualisation.forwardPorts = lib.mkForce [ ];
    virtualisation.vlans = lib.mkForce [ ];
    virtualisation.interfaces = lib.mkForce { };
    networking.interfaces = lib.mkForce { };
    networking.useDHCP = lib.mkForce false;
    networking.firewall.enable = lib.mkForce true;
    systemd.services.register-nix-paths.enable = lib.mkForce false;
  };

  testScript = ''
    import json
    import os
    import runpy
    import shlex

    with open("${provider.manifest}") as manifest_file:
        manifest = json.load(manifest_file)
    assert set(manifest) == {"schema", "exports", "required_directories"}
    assert manifest["schema"] == 1
    with open("${debClosure}/store-paths") as closure_file:
        deb_closure = set(closure_file.read().splitlines())
    assert "${provider.runtime}" in deb_closure
    assert "${pkgs.bash}" in deb_closure
    assert "${pkgs.coreutils}" in deb_closure
    assert "${pkgs.systemd}" in deb_closure
    exports = manifest["exports"]

    assert "/bin/sh" not in exports
    assert "/usr/bin/env" not in exports

    ordinary = exports["/usr/sbin/printf"]
    assert ordinary["target"].startswith("/nix/store/")
    assert ordinary["source"] == ordinary["target"]
    assert ordinary["native_wrapper"] is False

    wrapped_id = exports["/usr/sbin/id"]
    assert wrapped_id == {
        "target": "/run/wrappers/bin/id",
        "source": "${wrapperSources.id}",
        "native_wrapper": True,
    }
    systemctl_export = exports["/usr/sbin/systemctl"]
    assert systemctl_export == {
        "target": "${provider.runtime}/bin/systemctl",
        "source": "${provider.runtime}/bin/systemctl",
        "native_wrapper": False,
    }
    runtime_systemctl_wrapper = "${provider.runtime}/native-wrapper-sources/systemctl"
    assert os.readlink(runtime_systemctl_wrapper) == "${wrapperSources.systemctl}"

    runtime_directory = exports["/usr/lib/systemd/system"]
    assert runtime_directory == {
        "target": "/run/systemd/system",
        "source": None,
        "native_wrapper": False,
    }

    forwarded_arguments = runpy.run_path("${../native-systemctl.py}")[
        "forwarded_arguments"
    ]
    assert forwarded_arguments(["enable", "sentinelone.service"]) == [
        "--runtime",
        "enable",
        "sentinelone.service",
    ]
    assert forwarded_arguments(["disable", "sentinelone.service"]) == [
        "--runtime",
        "disable",
        "sentinelone.service",
    ]
    for arguments in (
        ["--version"],
        ["enable", "other.service"],
        ["enable", "sentinelone.service", "--no-reload"],
        ["--no-reload", "enable", "sentinelone.service"],
        ["disable", "sentinelone.service", "--no-reload"],
    ):
        assert forwarded_arguments(arguments) == arguments

    machine.start()
    machine.succeed("test -d /run/systemd/system")
    machine.succeed("test -e /bin/sh")
    machine.succeed("test -e /usr/bin/env")
    machine.succeed(
        "printf '%s\\n' 'foreign unknown target witness' "
        "> /bin/sentinelone-native-runtime-foreign-target"
    )
    machine.succeed("install -d /run/systemd/system/sentinelone.service.d")
    machine.succeed(
        "printf '%s\\n' 'foreign runtime witness' "
        "> /run/systemd/system/.s1-native-runtime-witness"
    )
    machine.succeed(
        "printf '%s\\n' '[Service]' "
        "'Environment=S1_FOREIGN_DROPIN=preserve' "
        "> /run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
    )
    foreign_before = (
        machine.succeed("stat -c '%n:%F:%d:%i:%u:%g:%a' /bin/sh /usr/bin/env"),
        machine.succeed("sha256sum /bin/sh /usr/bin/env"),
        machine.succeed("readlink -e /bin/sh /usr/bin/env"),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "sha256sum /bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
        machine.succeed(
            "sha256sum /run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
    )
    runtime_dir_identity = machine.succeed(
        "stat -c '%d:%i:%u:%g:%a' /run/systemd/system"
    ).strip()

    assert machine.succeed(
        "${pkgs.dpkg}/bin/dpkg-deb --field ${provider.deb} Package"
    ).strip() == "sentinelone-nix-runtime"
    assert machine.succeed(
        "${pkgs.dpkg}/bin/dpkg-deb --field ${provider.deb} Version"
    ).strip() == "1"
    assert machine.succeed(
        "${pkgs.dpkg}/bin/dpkg-deb --field ${provider.deb} Architecture"
    ).strip() == "amd64"
    assert machine.succeed(
        "${pkgs.dpkg}/bin/dpkg-deb --field ${provider.deb} Provides"
    ).strip() == "coreutils, passwd, kmod"

    admin = "/tmp/sentinelone-runtime-private-admindir"
    machine.succeed("mkdir -p " + admin)
    machine.succeed(
        "dpkg --admindir=" + admin + " --install ${provider.deb}"
    )
    assert "Status: install ok installed" in machine.succeed(
        "dpkg --admindir=" + admin + " --status sentinelone-nix-runtime"
    )
    machine.succeed(
        "dpkg --admindir=" + admin + " --install ${maintscriptProbeDeb}"
    )
    assert "Status: install ok installed" in machine.succeed(
        "dpkg --admindir=" + admin
        + " --status sentinelone-runtime-maintscript-probe"
    )
    assert machine.succeed(
        "cat /tmp/sentinelone-native-runtime-maintscript-uid"
    ).strip() == "0"
    assert manifest["required_directories"] == [
        "/bin",
        "/run/systemd/system",
        "/usr",
        "/usr/sbin",
        "/usr/lib",
        "/usr/lib/systemd",
    ]
    assert machine.succeed("readlink /bin/bash").strip() == (
        "${pkgs.bash}/bin/bash"
    )
    assert exports["/bin/bash"] == {
        "target": "${pkgs.bash}/bin/bash",
        "source": "${pkgs.bash}/bin/bash",
        "native_wrapper": False,
    }
    package_files = machine.succeed(
        "dpkg-query --admindir=" + admin + " -L sentinelone-nix-runtime"
    ).splitlines()
    assert package_files.count("/bin/bash") == 1
    assert package_files.count("/bin/sh") == 0
    assert "/usr/bin/env" not in package_files
    assert "/run/systemd/system" not in package_files
    assert machine.succeed("readlink /usr/sbin/systemctl").strip() == (
        "${provider.runtime}/bin/systemctl"
    )
    assert machine.succeed("readlink /usr/sbin/id").strip() == "/run/wrappers/bin/id"
    assert machine.succeed("readlink /usr/lib/systemd/system").strip() == (
        "/run/systemd/system"
    )
    machine.succeed("test -x /run/wrappers/bin/id")
    machine.succeed("test -x /run/wrappers/bin/systemctl")

    path_systemctl = machine.succeed(
        "PATH=/sbin:/bin:/usr/sbin:/usr/bin sh -c 'command -v systemctl'"
    ).strip()
    resolved_path_systemctl = machine.succeed(
        "readlink -f " + shlex.quote(path_systemctl)
    ).strip()
    resolved_adapter = machine.succeed("readlink -f /usr/sbin/systemctl").strip()
    assert resolved_path_systemctl == resolved_adapter
    bash_version = machine.succeed("/bin/bash --version")
    assert "GNU bash" in bash_version
    assert machine.succeed("/usr/sbin/bash -c 'printf BASH_PROVIDER_OK'").strip() == (
        "BASH_PROVIDER_OK"
    )

    machine.succeed(
        "/usr/sbin/printf 'native-runtime-file\\n' > /tmp/s1-native-source"
    )
    machine.succeed("/usr/sbin/cp /tmp/s1-native-source /tmp/s1-native-copy")
    machine.succeed("/usr/sbin/chmod 0640 /tmp/s1-native-copy")
    machine.succeed("/usr/sbin/chown sentinelone:sentinelone /tmp/s1-native-copy")
    machine.succeed("cmp /tmp/s1-native-source /tmp/s1-native-copy")
    machine.succeed("test \"$(stat -c '%a' /tmp/s1-native-copy)\" = 640")
    machine.succeed(
        "test \"$(stat -c '%U:%G' /tmp/s1-native-copy)\" = sentinelone:sentinelone"
    )
    assert machine.succeed("/usr/sbin/sha256sum /tmp/s1-native-copy").split()[0] == (
        machine.succeed("/usr/sbin/sha256sum /tmp/s1-native-source").split()[0]
    )

    machine.succeed("/usr/sbin/groupadd --system s1runtimeprobe")
    machine.succeed(
        "/usr/sbin/useradd --system --gid s1runtimeprobe --no-create-home "
        "--home-dir /var/empty --shell /usr/sbin/nologin s1runtimeprobe"
    )
    uid = int(machine.succeed("/usr/sbin/id -u s1runtimeprobe").strip())
    assert uid > 0
    account = machine.succeed("/usr/sbin/getent passwd s1runtimeprobe").strip().split(":")
    assert account[6] == "/usr/sbin/nologin", account
    assert " L " in machine.succeed("/usr/sbin/passwd -S s1runtimeprobe")
    machine.succeed("/usr/sbin/userdel s1runtimeprobe")
    machine.succeed("/usr/sbin/groupdel s1runtimeprobe")
    assert machine.execute("/usr/sbin/getent passwd s1runtimeprobe")[0] != 0

    modules = machine.succeed("/usr/sbin/lsmod")
    module_name = machine.succeed(
        "/usr/sbin/awk 'NR == 1 { print $1; exit }' /proc/modules"
    ).strip()
    assert module_name
    assert any(line.split()[:1] == [module_name] for line in modules.splitlines())
    module_file = machine.succeed(
        "/usr/sbin/modinfo -F filename " + shlex.quote(module_name)
    ).strip()
    vermagic = machine.succeed(
        "/usr/sbin/modinfo -F vermagic " + shlex.quote(module_name)
    ).split()
    assert module_file
    assert vermagic[0] == machine.succeed("uname -r").strip()
    machine.succeed(
        "/usr/sbin/modprobe --dry-run --show-depends " + shlex.quote(module_name)
    )

    machine.succeed("/usr/sbin/systemctl daemon-reload")
    before_unit = machine.succeed(
        "/usr/sbin/systemctl show sentinelone.service -p LoadState -p FragmentPath"
    )
    assert "LoadState=not-found" in before_unit
    assert "FragmentPath=" in before_unit

    adapter_version = machine.succeed("/usr/sbin/systemctl --version")
    wrapper_version = machine.succeed("/run/wrappers/bin/systemctl --version")
    assert adapter_version == wrapper_version
    adapter_status, adapter_error = machine.execute(
        "/usr/sbin/systemctl invalid-sentinelone-command"
    )
    wrapper_status, wrapper_error = machine.execute(
        "/run/wrappers/bin/systemctl invalid-sentinelone-command"
    )
    assert adapter_status == wrapper_status != 0
    assert adapter_error == wrapper_error

    machine.succeed(
        "printf '%s\\n' '[Unit]' "
        "'Description=Never-started SentinelOne runtime adapter test' "
        "'[Service]' 'Type=oneshot' "
        "'ExecStart=/usr/sbin/touch /tmp/sentinelone-native-unit-started' "
        "'[Install]' 'WantedBy=multi-user.target' "
        "> /run/systemd/system/sentinelone.service"
    )
    machine.succeed("/usr/sbin/systemctl daemon-reload")
    loaded_unit = machine.succeed(
        "/usr/sbin/systemctl show sentinelone.service -p LoadState -p FragmentPath"
    )
    assert "LoadState=loaded" in loaded_unit
    assert "FragmentPath=/run/systemd/system/sentinelone.service" in loaded_unit
    machine.succeed(
        "PATH=/sbin:/bin:/usr/sbin:/usr/bin systemctl enable sentinelone.service"
    )
    assert machine.succeed(
        "/usr/sbin/systemctl is-enabled sentinelone.service"
    ).strip() == "enabled-runtime"
    machine.succeed(
        "test -L /run/systemd/system/multi-user.target.wants/sentinelone.service"
    )
    machine.succeed(
        "test ! -e /etc/systemd/system/multi-user.target.wants/sentinelone.service"
    )
    assert machine.execute("/usr/sbin/systemctl is-active sentinelone.service")[0] != 0
    machine.succeed(
        "test ! -e /tmp/sentinelone-native-unit-started"
    )
    machine.succeed(
        "PATH=/sbin:/bin:/usr/sbin:/usr/bin systemctl disable sentinelone.service"
    )
    machine.succeed(
        "test ! -e /run/systemd/system/multi-user.target.wants/sentinelone.service"
    )
    disabled_status, disabled_output = machine.execute(
        "/usr/sbin/systemctl is-enabled sentinelone.service"
    )
    assert disabled_status != 0
    assert disabled_output.strip() == "disabled"

    adapter_status, adapter_error = machine.execute(
        "/usr/sbin/systemctl --no-reload enable sentinelone.service 2>&1"
    )
    wrapper_status, wrapper_error = machine.execute(
        "/run/wrappers/bin/systemctl --no-reload enable sentinelone.service 2>&1"
    )
    assert adapter_status == wrapper_status != 0
    assert adapter_error == wrapper_error
    assert "Read-only file system" in adapter_error
    machine.succeed(
        "test ! -e /run/systemd/system/multi-user.target.wants/sentinelone.service"
    )

    # NixOS's live /etc unit tree is immutable. Exercise successful permanent
    # enable/disable in a writable root, passing every extra argument through.
    unit_root = "/tmp/sentinelone-native-systemctl-root"
    machine.succeed("mkdir -p " + unit_root + "/etc/systemd/system")
    machine.succeed(
        "cp /run/systemd/system/sentinelone.service "
        + unit_root + "/etc/systemd/system/sentinelone.service"
    )
    machine.succeed(
        "PATH=/sbin:/bin:/usr/sbin:/usr/bin "
        "systemctl --no-reload --root=" + unit_root + " enable sentinelone.service"
    )
    machine.succeed(
        "test -L " + unit_root
        + "/etc/systemd/system/multi-user.target.wants/sentinelone.service"
    )
    machine.succeed(
        "test ! -e " + unit_root
        + "/run/systemd/system/multi-user.target.wants/sentinelone.service"
    )
    machine.succeed(
        "PATH=/sbin:/bin:/usr/sbin:/usr/bin "
        "systemctl --no-reload --root=" + unit_root + " disable sentinelone.service"
    )
    machine.succeed(
        "test ! -e " + unit_root
        + "/etc/systemd/system/multi-user.target.wants/sentinelone.service"
    )
    machine.succeed(
        "test ! -e /tmp/sentinelone-native-unit-started"
    )

    machine.succeed(
        "dpkg --admindir=" + admin + " --install ${positiveDependencyDeb}"
    )
    assert "Status: install ok installed" in machine.succeed(
        "dpkg --admindir=" + admin
        + " --status sentinelone-runtime-positive-dependency-test"
    )

    versioned_status, versioned_output = machine.execute(
        "dpkg --admindir=" + admin + " --install ${versionedDependencyDeb}"
    )
    assert versioned_status != 0, versioned_output
    machine.succeed(
        "dpkg --admindir=" + admin
        + " --remove sentinelone-runtime-versioned-dependency-negative-test"
    )

    unrelated_status, unrelated_output = machine.execute(
        "dpkg --admindir=" + admin + " --install ${unrelatedDependencyDeb}"
    )
    assert unrelated_status != 0, unrelated_output
    machine.succeed(
        "dpkg --admindir=" + admin
        + " --remove sentinelone-runtime-unrelated-dependency-negative-test"
    )

    assert machine.succeed(
        "stat -c '%d:%i:%u:%g:%a' /run/systemd/system"
    ).strip() == runtime_dir_identity
    assert foreign_before == (
        machine.succeed("stat -c '%n:%F:%d:%i:%u:%g:%a' /bin/sh /usr/bin/env"),
        machine.succeed("sha256sum /bin/sh /usr/bin/env"),
        machine.succeed("readlink -e /bin/sh /usr/bin/env"),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "sha256sum /bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
        machine.succeed(
            "sha256sum /run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
    )

    machine.succeed("unlink /run/systemd/system/sentinelone.service")
    machine.succeed("/run/wrappers/bin/systemctl daemon-reload")
    machine.succeed(
        "dpkg --admindir=" + admin
        + " --remove sentinelone-runtime-maintscript-probe "
        "sentinelone-runtime-positive-dependency-test"
    )
    machine.succeed("dpkg --admindir=" + admin + " --remove sentinelone-nix-runtime")
    assert machine.execute("test -e /usr/sbin/cp")[0] != 0
    assert machine.execute("test -e /usr/lib/systemd/system")[0] != 0
    assert machine.execute("test -L /usr/lib/systemd/system")[0] != 0
    assert machine.execute("test -e /bin/bash")[0] != 0
    assert machine.succeed(
        "stat -c '%d:%i:%u:%g:%a' /run/systemd/system"
    ).strip() == runtime_dir_identity
    assert foreign_before == (
        machine.succeed("stat -c '%n:%F:%d:%i:%u:%g:%a' /bin/sh /usr/bin/env"),
        machine.succeed("sha256sum /bin/sh /usr/bin/env"),
        machine.succeed("readlink -e /bin/sh /usr/bin/env"),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "sha256sum /bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
        machine.succeed(
            "sha256sum /run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
    )

    machine.succeed("dpkg --admindir=" + admin + " --install ${provider.deb}")
    assert "Status: install ok installed" in machine.succeed(
        "dpkg --admindir=" + admin + " --status sentinelone-nix-runtime"
    )
    assert machine.succeed("readlink /bin/bash").strip() == (
        "${pkgs.bash}/bin/bash"
    )
    assert machine.succeed("readlink /usr/lib/systemd/system").strip() == (
        "/run/systemd/system"
    )
    assert machine.succeed(
        "stat -c '%d:%i:%u:%g:%a' /run/systemd/system"
    ).strip() == runtime_dir_identity
    assert foreign_before == (
        machine.succeed("stat -c '%n:%F:%d:%i:%u:%g:%a' /bin/sh /usr/bin/env"),
        machine.succeed("sha256sum /bin/sh /usr/bin/env"),
        machine.succeed("readlink -e /bin/sh /usr/bin/env"),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "sha256sum /bin/sentinelone-native-runtime-foreign-target"
        ),
        machine.succeed(
            "stat -c '%n:%F:%d:%i:%u:%g:%a' "
            "/run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
        machine.succeed(
            "sha256sum /run/systemd/system/.s1-native-runtime-witness "
            "/run/systemd/system/sentinelone.service.d/50-offline-probe.conf"
        ),
    )
  '';
}
