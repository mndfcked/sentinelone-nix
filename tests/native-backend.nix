{
  pkgs,
  lib,
  nixosModules,
}:
let
  # Deliberately synthetic. This verifies lifecycle integration, never vendor
  # authentication, real N-to-N+1 upgrades, enrollment, or protection.
  fixture =
    version:
    pkgs.runCommand "synthetic-sentinelagent-${version}.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p package/DEBIAN package/opt/sentinelone/{bin,configuration,lib,data}
        cat > package/DEBIAN/control <<EOF
        Package: sentinelagent
        Version: ${version}
        Architecture: amd64
        Depends: coreutils, passwd, kmod
        Maintainer: Synthetic fixture <nobody@example.invalid>
        Description: NOT a vendor agent; lifecycle fixture only
        EOF
        cat > package/DEBIAN/preinst <<'EOF'
        #!/bin/sh
        set -eu
        test "$S1_AGENT_CREATE_USER" = false
        if test "${version}" = 1; then
          test "$HOME" = /root
          umask > /run/native-dpkg-umask
          # Genuine Nix discovery, not merely the existence of symlinks.
          for name in pending transaction; do
            root=/nix/var/nix/gcroots/sentinelone-nix/$name
            test -L "$root"
            ${pkgs.nix}/bin/nix-store --gc --print-roots | ${pkgs.gnugrep}/bin/grep -Fx -- "\"$root\" -> $(readlink "$root")"
          done
        fi
        test "$DPKG_ADMINDIR" = /var/lib/sentinelone-nix/dpkg
        if ! test -e /opt/sentinelone; then
          mkdir -p "$S1_AGENT_CUSTOM_INSTALL_PATH"
          ln -s "$S1_AGENT_CUSTOM_INSTALL_PATH" /opt/sentinelone
        fi
        chown -h sentinelone:sentinelone /opt/sentinelone
        EOF
        cat > package/DEBIAN/postinst <<'EOF'
        #!/bin/sh
        set -eu
        # Only the test requests this pause; dpkg itself holds both private locks.
        if test -e /run/native-dpkg-hold; then
          printf '%s\n' "$$" > /run/native-dpkg-entered
          remaining=120
          while ! test -e /run/native-dpkg-release; do
            test "$remaining" -gt 0 || exit 1
            remaining=$((remaining - 1))
            sleep 1
          done
        fi
        chown sentinelone:sentinelone "$S1_AGENT_CUSTOM_INSTALL_PATH" "$S1_AGENT_CUSTOM_INSTALL_PATH/configuration"
        chmod 1700 "$S1_AGENT_CUSTOM_INSTALL_PATH/configuration"
        install -m 644 /opt/sentinelone/configuration/sentinelone.service /usr/lib/systemd/system/sentinelone.service
        systemctl enable sentinelone.service
        EOF
        chmod 755 package/DEBIAN/{preinst,postinst}
        cat > package/opt/sentinelone/bin/sentinelone-agent <<'EOF'
        #!/bin/sh
        set -eu
        printf '%s\n' "$HOME" "$TMPDIR" "$DEBIAN_FRONTEND" > /opt/sentinelone/data/environment
        echo started >> /opt/sentinelone/data/starts
        while true; do
          systemd-notify WATCHDOG=1
          sleep 1
        done
        EOF
        cat > package/opt/sentinelone/bin/sentinelctl <<'EOF'
        #!/bin/sh
        printf '%s\n' "$NIX_LD_LIBRARY_PATH" "$DPKG_ADMINDIR" "$HOME" "$TMPDIR" "$DEBIAN_FRONTEND" "$@"
        EOF
        chmod 755 package/opt/sentinelone/bin/*
        cat > package/opt/sentinelone/configuration/sentinelone.service <<'EOF'
        [Unit]
        Description=Synthetic sentinelagent ${version}
        RefuseManualStop=yes
        [Service]
        Type=simple
        Environment=HOME=/opt/sentinelone/home TMPDIR=/opt/sentinelone/tmp DEBIAN_FRONTEND=vendor
        ExecStart=/opt/sentinelone/bin/sentinelone-agent
        WorkingDirectory=/opt/sentinelone/bin
        WatchdogSec=30s
        NotifyAccess=all
        Restart=on-failure
        [Install]
        WantedBy=multi-user.target
        EOF
        echo "${version}" > package/opt/sentinelone/data/version
        dpkg-deb --build --root-owner-group package "$out"
      '';
  seed = fixture "1";
  future = fixture "99";
  foreignDropin = pkgs.writeTextDir "lib/systemd/system/sentinelone.service.d/99-foreign.conf" ''
    [Service]
    Environment=DPKG_ADMINDIR=/foreign
  '';
  package = pkgs.runCommand "unused-patched-fixture-output" { passthru.src = seed; } ''
    echo "Native mode must not build patched package output" >&2
    exit 1
  '';
  ctl = "${pkgs.python3}/bin/python3 ${../native-controller.py}";
  node = { lib, ... }: {
    imports = [ ../module.nix ];
    services.sentinelone = {
      enable = true;
      vendorManagedUpdates = true;
      inherit package;
      dataDir = "/var/lib/native-payload";
    };
    environment.systemPackages = [
      pkgs.python3
      pkgs.dpkg
    ];
    system.switch.enable = true;
    systemd.services.sentinelone-init.preStart = ''
      # Observe only: these slots must be created by the controller, not repaired.
      for path in /opt /usr/sbin /usr/lib /usr/lib/systemd; do
        if ! test -e "$path"; then printf '%s\n' "$path"; fi
      done > /run/native-new-public-directories
    '';
    specialisation = {
      next.configuration = {
        environment.etc."native-generation".text = "next";
        # Produce a distinct immutable boot environment without changing seed.
        programs.nix-ld.libraries = [ pkgs.bzip2 ];
      };
      foreign.configuration.systemd.packages = [ foreignDropin ];
      declaredForeign.configuration.systemd.services.sentinelone.serviceConfig.Environment =
        "DPKG_ADMINDIR=/foreign";
      disabled.configuration.services.sentinelone.enable = lib.mkForce false;
      legacy.configuration.services.sentinelone = {
        vendorManagedUpdates = lib.mkForce false;
        sentinelOneManagementTokenPath = "/run/never-read";
        package = lib.mkForce (
          pkgs.runCommand "legacy-transition-fixture" { } "mkdir -p $out/opt/sentinelone"
        );
      };
      moved.configuration.services.sentinelone.dataDir = lib.mkForce "/var/lib/moved-payload";
    };
    virtualisation = {
      memorySize = 1024;
      qemu.networkingOptions = lib.mkForce [ "-net none" ];
      forwardPorts = lib.mkForce [ ];
      vlans = lib.mkForce [ ];
      interfaces = lib.mkForce { };
      useHostCerts = lib.mkForce false;
    };
    networking.useDHCP = lib.mkForce false;
  };
in
pkgs.testers.runNixOSTest {
  name = "sentinelone-native-backend-synthetic";
  globalTimeout = 900;
  nodes = {
    machine = node;
    persistent = { ... }: {
      imports = [ node ];
      systemd.packages = [ foreignDropin ];
    };
    unknown = { ... }: {
      imports = [ node ];
      systemd.services.native-test-conflict = {
        wantedBy = [ "multi-user.target" ];
        before = [ "sentinelone-init.service" ];
        serviceConfig.Type = "oneshot";
        script = "mkdir -p /usr/sbin; touch /usr/sbin/sleep";
      };
    };
  };
  testScript = ''
    import json
    import os
    import shlex
    import time

    control = "/var/lib/sentinelone-nix"
    root = "/var/lib/native-payload"
    state_path = control + "/state.json"
    ctl = "${ctl}"

    def guest(code, node=machine):
        return node.succeed("python3 -c " + shlex.quote(code))

    def payload_layout():
        print(guest("""
    import os,pwd,stat
    from pathlib import Path
    uid = pwd.getpwnam('sentinelone').pw_uid
    data = Path('/var/lib/native-payload')
    opt = Path('/opt/sentinelone')
    assert opt.is_symlink() and opt.lstat().st_uid == uid
    assert os.readlink(opt) == str(data)
    for path, mode in [(data, 0o755), (data / 'configuration', 0o1700)]:
        info = path.lstat()
        assert stat.S_ISDIR(info.st_mode) and info.st_uid == uid
        assert stat.S_IMODE(info.st_mode) == mode
    unit = data / 'configuration/sentinelone.service'
    assert stat.S_IMODE(unit.lstat().st_mode) == 0o644
    for path in [unit, Path('/run/systemd/system/sentinelone.service')]:
        info = path.lstat()
        assert stat.S_ISREG(info.st_mode) and info.st_uid == 0
        assert not info.st_mode & 0o022
    assert stat.S_IMODE(Path('/run/systemd/system/sentinelone.service').lstat().st_mode) in (0o600, 0o644)
    assert unit.read_bytes() == Path('/run/systemd/system/sentinelone.service').read_bytes()
    private = {}
    for mode, paths in [
        (0o700, ['/var/lib/sentinelone-nix', '/var/lib/sentinelone-nix/dpkg',
                  '/nix/var/nix/gcroots/sentinelone-nix',
                  '/run/systemd/system/sentinelone.service.d']),
        (0o600, ['/var/lib/sentinelone-nix/state.json',
                  '/var/lib/sentinelone-nix/controller.lock',
                  '/var/lib/sentinelone-nix/dpkg/lock',
                  '/var/lib/sentinelone-nix/dpkg/lock-frontend',
                  '/run/sentinelone-nix-boot-config', '/run/sentinelone-nix-reconciled',
                  '/run/systemd/system/sentinelone.service.d/50-native-runtime.conf']),
    ]:
        for raw in paths:
            info = Path(raw).lstat()
            assert (stat.S_ISDIR(info.st_mode) if mode == 0o700 else stat.S_ISREG(info.st_mode)), raw
            assert info.st_uid == info.st_gid == 0 and stat.S_IMODE(info.st_mode) == mode, raw
            private[raw] = [oct(mode), info.st_uid, info.st_gid]
    print('Private control metadata:', private)
    assert Path('/proc/sys/fs/protected_hardlinks').read_text().strip() == '1'
    """))

    def state():
        return json.loads(machine.succeed("cat " + state_path))

    def config_path(node=machine):
        return node.succeed("systemctl show sentinelone-init.service -p ExecStart --value").split(" reconcile ")[1].split(" ;")[0].strip()

    def gc_roots(node=machine):
        prefix = "/nix/var/nix/gcroots/sentinelone-nix/"
        roots = {}
        for line in node.succeed("nix-store --gc --print-roots").splitlines():
            name, target = line.split(" -> ", 1)
            # Nix quotes the root name, including these fixed, space-free paths.
            name = shlex.split(name)[0]
            if name.startswith(prefix):
                roots[name] = target
        return roots

    def snapshot(live=False):
        return guest("live = " + repr(live) + "\nconf = " + repr(conf) + """
    import hashlib,json,os
    from pathlib import Path
    paths = [Path('/var/lib/sentinelone-nix/state.json'), Path('/var/lib/sentinelone-nix/dpkg/status'), Path('/run/systemd/system/sentinelone.service'), Path('/run/systemd/system/sentinelone.service.d/50-native-runtime.conf')]
    if live:
        config = json.loads(Path(conf).read_text())
        manifest = json.loads(Path(config['runtime_manifest']).read_text())
        paths += [Path(p) for p in manifest['exports']]
        paths += [Path('/var/lib/sentinelone-nix'), Path('/var/lib/sentinelone-nix/controller.lock'), Path('/var/lib/sentinelone-nix/dpkg'), Path('/opt/sentinelone'), Path('/run/sentinelone-nix-boot-config'), Path('/run/sentinelone-nix-reconciled')]
        for root in [Path('/var/lib/native-payload'), Path('/nix/var/nix/gcroots/sentinelone-nix')]:
            paths += [root, *root.rglob('*')]
    def signature(path):
        info = path.lstat()
        content = os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        return [info.st_ino, info.st_mode, info.st_uid, info.st_gid, content] + ([info.st_mtime_ns, info.st_ctime_ns] if live else [])
    print(json.dumps({str(p):signature(p) for p in paths}, sort_keys=True))
    """)

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sentinelone-init.service")
    machine.wait_for_unit("sentinelone.service")
    machine.wait_until_succeeds("test -s " + root + "/data/starts")
    payload_layout()
    initial = state()
    assert initial["phase"] == "ready" and initial["seed"]["version"] == "1"
    assert initial["mode"] == "vendor-managed"
    conf = config_path()
    assert initial["runtime_active"] == conf
    public = json.loads(guest("conf = " + repr(conf) + """
    import json,os,pwd,stat
    from pathlib import Path
    config = json.loads(Path(conf).read_text())
    manifest = json.loads(Path(config['runtime_manifest']).read_text())
    paths = Path('/run/native-new-public-directories').read_text().splitlines()
    assert '/opt' in paths and set(paths) - {'/opt'}
    assert set(paths) <= {'/opt', *manifest['required_directories']}
    metadata = {}
    for path in paths:
        info = Path(path).lstat()
        assert stat.S_ISDIR(info.st_mode)
        metadata[path] = [oct(stat.S_IMODE(info.st_mode)), info.st_uid, info.st_gid]
    print(json.dumps(metadata))
    """))
    print("New controller-created public directory metadata:", public)
    assert all(info == ["0o755", 0, 0] for info in public.values()), public
    print(guest("paths = " + repr(list(public)) + "\nconf = " + repr(conf) + """
    import json,os,pwd
    from pathlib import Path
    manifest = json.loads(Path(json.loads(Path(conf).read_text())['runtime_manifest']).read_text())
    account = pwd.getpwnam('sentinelone')
    child = os.fork()
    if child == 0:
        os.setgroups([])
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
        os._exit(0 if all(os.access(p, os.X_OK) for p in paths + list(manifest['exports'])) else 1)
    _, status = os.waitpid(child, 0)
    assert os.waitstatus_to_exitcode(status) == 0, 'sentinelone cannot traverse public exports'
    print('Public traversal UID/GID:', account.pw_uid, account.pw_gid, 'exports:', len(manifest['exports']))
    """))
    child_umask = machine.succeed("cat /run/native-dpkg-umask").strip()
    assert int(child_umask, 8) == 0o022, child_umask
    print("Real dpkg maintscript umask:", child_umask)
    assert machine.succeed(ctl + " status " + conf).strip().startswith("{")
    machine.succeed("test $(stat -c %a " + control + ") = 700")
    machine.succeed("test $(stat -c %a " + state_path + ") = 600")
    machine.succeed("test $(stat -c %U " + root + ") = sentinelone")
    machine.succeed("test $(readlink /opt/sentinelone) = " + root)
    machine.succeed("test $(readlink /nix/var/nix/gcroots/sentinelone-nix/active) = " + conf)
    assert gc_roots() == {"/nix/var/nix/gcroots/sentinelone-nix/active": conf}
    guest("import json; from pathlib import Path; c=json.loads(Path(" + repr(conf) + ").read_text()); assert c['runtime'] in Path(" + repr(conf) + ").read_text(); assert '/nix/store/' in c['loader']; assert '/nix/store/' in c['library_path']")
    assert "RefuseManualStop=yes" in machine.succeed("systemctl show sentinelone.service -p RefuseManualStop")
    assert "Restart=on-failure" in machine.succeed("systemctl show sentinelone.service -p Restart")
    assert "WatchdogUSec=30s" in machine.succeed("systemctl show sentinelone.service -p WatchdogUSec")
    closure = set(machine.succeed("nix-store -qR " + conf).splitlines())
    desired = json.loads(machine.succeed("cat " + conf))
    assert desired["runtime"] in closure
    assert desired["loader"].split("/lib/")[0] in closure
    assert all(path.rsplit("/lib", 1)[0] in closure for path in desired["library_path"].split(":")[1:])
    runtime_refs = machine.succeed("nix-store -qR " + desired["runtime"])
    assert "coreutils" in runtime_refs and "shadow" in runtime_refs and "kmod" in runtime_refs
    machine.fail(ctl + " reconcile " + conf)
    before = snapshot()
    machine.succeed(ctl + " preflight " + conf)
    assert before == snapshot()

    # Root tools must ignore vendor-owned Nix configuration. The invalid required
    # include is inert data: no hooks, executable code or enrollment material.
    guest("""
    from pathlib import Path
    config = Path('/opt/sentinelone/home/.config/nix/nix.conf')
    config.parent.mkdir(parents=True)
    config.write_text('include /run/native-canary-must-not-exist\\n')
    """)
    canary_status, canary_output = machine.execute("env -i HOME=/opt/sentinelone/home PATH=/run/current-system/sw/bin nix-store --query --hash " + shlex.quote(conf) + " 2>&1")
    assert canary_status != 0 and "native-canary-must-not-exist" in canary_output
    assert machine.succeed("sentinelctl probe").splitlines() == [
        desired["library_path"], control + "/dpkg", "/root", "/tmp", "noninteractive", "probe"
    ]
    assert machine.succeed("cat " + root + "/data/environment").splitlines() == [
        "/opt/sentinelone/home", "/opt/sentinelone/tmp", "vendor"
    ]
    runtime_dropin = machine.succeed("cat /run/systemd/system/sentinelone.service.d/50-native-runtime.conf")
    assert all(key + "=" not in runtime_dropin for key in ["HOME", "TMPDIR", "DEBIAN_FRONTEND"])

    # Check the assembled desired tree through the actual Nix switch entrypoint.
    # foreign has only systemd.packages; declaredForeign exercises a NixOS unit.
    base_system = machine.succeed("readlink -f /run/current-system").strip()
    for generation, conflict in [
        ("declaredForeign", "sentinelone.service"),
        ("foreign", "sentinelone.service.d/99-foreign.conf"),
    ]:
        target = base_system + "/specialisation/" + generation
        machine.succeed("test -e " + target + "/etc/systemd/system/" + conflict)
        live_before = snapshot(live=True)
        current_before = machine.succeed("readlink /run/current-system; readlink -f /etc/systemd/system")
        tag_before = machine.execute("cat /etc/native-generation")[0:2]
        daemon_before = machine.succeed("systemctl show sentinelone.service -p MainPID -p InvocationID -p FragmentPath -p DropInPaths -p Environment")
        init_before = machine.succeed("systemctl show sentinelone-init.service -p InvocationID -p ExecMainStartTimestampMonotonic")
        pid = machine.succeed("systemctl show sentinelone.service -p MainPID --value").strip()
        process_before = guest("from pathlib import Path; print(Path('/proc/" + pid + "/environ').read_bytes().hex())")
        result, output = machine.execute(target + "/bin/switch-to-configuration test 2>&1", timeout=60)
        print("Desired assembled tree actual-switch result:", generation, result, output)
        assert result != 0 and "foreign desired sentinelone unit or dropin" in output
        assert current_before == machine.succeed("readlink /run/current-system; readlink -f /etc/systemd/system")
        assert tag_before == machine.execute("cat /etc/native-generation")[0:2]
        assert live_before == snapshot(live=True)
        assert daemon_before == machine.succeed("systemctl show sentinelone.service -p MainPID -p InvocationID -p FragmentPath -p DropInPaths -p Environment")
        assert init_before == machine.succeed("systemctl show sentinelone-init.service -p InvocationID -p ExecMainStartTimestampMonotonic")
        assert process_before == guest("from pathlib import Path; print(Path('/proc/" + pid + "/environ').read_bytes().hex())")
        assert gc_roots() == {"/nix/var/nix/gcroots/sentinelone-nix/active": conf}

    # Real vendor-owned package/version changes are not compared to seed identity.
    machine.succeed("env DPKG_ADMINDIR=" + control + "/dpkg S1_AGENT_CUSTOM_INSTALL_PATH=" + root + " S1_AGENT_CREATE_USER=false PATH=/usr/sbin:/usr/bin:/bin ${pkgs.dpkg}/bin/dpkg -i ${future}")
    machine.succeed("echo persistent > " + root + "/data/user-state")
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("sentinelone.service")
    machine.succeed("grep -q '99' /run/systemd/system/sentinelone.service")
    machine.succeed("grep -q '^99$' " + root + "/data/version")
    payload_layout()
    machine.succeed("grep -q persistent " + root + "/data/user-state")
    assert state()["seed"] == initial["seed"]

    # Activation must also succeed during a genuine, half-configured dpkg install.
    # Reinstall version 99 to keep the seed/future-version assertions unchanged.
    conf = config_path()
    active_cli = machine.succeed("sentinelctl probe")
    base_system = machine.succeed("readlink -f /run/current-system").strip()
    next_system = base_system + "/specialisation/next"
    next_resolved = machine.succeed("readlink -f " + next_system).strip()
    machine.succeed("test ! -e /etc/native-generation; touch /run/native-dpkg-hold")
    machine.succeed("systemd-run --unit=native-dpkg-transaction --property=Type=exec --property=RuntimeMaxSec=180s --remain-after-exit ${pkgs.coreutils}/bin/env DPKG_ADMINDIR=" + control + "/dpkg S1_AGENT_CUSTOM_INSTALL_PATH=" + root + " S1_AGENT_CREATE_USER=false PATH=/usr/sbin:/usr/bin:/bin ${pkgs.dpkg}/bin/dpkg -i ${future}")
    lock_witness = """
    import json,os
    from pathlib import Path
    maintscript = int(Path('/run/native-dpkg-entered').read_text())
    status = Path(f'/proc/{maintscript}/status').read_text().splitlines()
    dpkg = int(next(line.split()[1] for line in status if line.startswith('PPid:')))
    assert os.readlink(f'/proc/{dpkg}/exe') == '${pkgs.dpkg}/bin/dpkg'
    assert Path(f'/proc/{dpkg}/cmdline').read_bytes().split(b'\\0')[1:-1] == [b'-i', b'${future}']
    assert b'sentinelagent.postinst' in Path(f'/proc/{maintscript}/cmdline').read_bytes()
    locks = [line.split() for line in Path('/proc/locks').read_text().splitlines()]
    for name in ['lock-frontend', 'lock']:
        info = Path('/var/lib/sentinelone-nix/dpkg', name).stat()
        assert any(fields[1:4] == ['POSIX', 'ADVISORY', 'WRITE']
                   and int(fields[4]) == dpkg
                   and tuple(int(part, 16) for part in fields[5].split(':')[:2]) == (os.major(info.st_dev), os.minor(info.st_dev))
                   and int(fields[5].split(':')[2]) == info.st_ino
                   and fields[6:] == ['0', 'EOF'] for fields in locks), name
    print(json.dumps([dpkg, maintscript]))
    """
    try:
        machine.wait_until_succeeds("test -s /run/native-dpkg-entered", timeout=30)
        transaction_pids = json.loads(guest(lock_witness))
        assert machine.succeed("systemctl show native-dpkg-transaction -p MainPID --value").strip() == str(transaction_pids[0])
        assert machine.succeed("DPKG_ADMINDIR=" + control + "/dpkg dpkg-query -W -f=" + shlex.quote("''${Status}") + " sentinelagent").strip() == "install ok half-configured"
        before = snapshot()
        live_before = snapshot(live=True)
        daemon_identity = machine.succeed("systemctl show sentinelone.service -p MainPID -p InvocationID -p Environment")
        init_identity = machine.succeed("systemctl show sentinelone-init.service -p InvocationID -p ExecMainStartTimestampMonotonic")
        active_environment = dict(item.split("=", 1) for item in shlex.split(machine.succeed("systemctl show sentinelone.service -p Environment --value")))
        assert active_environment["NIX_LD_LIBRARY_PATH"] == desired["library_path"]
        machine.succeed(next_system + "/bin/switch-to-configuration test", timeout=60)
        assert machine.succeed("readlink -f /run/current-system").strip() == next_resolved
        assert machine.succeed("cat /etc/native-generation").strip() == "next"
        assert config_path() != conf
        next_desired = json.loads(machine.succeed("cat " + config_path()))
        assert next_desired["library_path"] != active_environment["NIX_LD_LIBRARY_PATH"]
        assert before == snapshot()
        assert live_before == snapshot(live=True)
        assert daemon_identity == machine.succeed("systemctl show sentinelone.service -p MainPID -p InvocationID -p Environment")
        assert init_identity == machine.succeed("systemctl show sentinelone-init.service -p InvocationID -p ExecMainStartTimestampMonotonic")
        assert state()["runtime_active"] == conf
        assert transaction_pids == json.loads(guest(lock_witness))
        print("Real dpkg/frontend+database locks remained held across next activation:", json.dumps({"pids": transaction_pids, "before_system": base_system, "after_system": next_resolved, "active_config": conf, "desired_config": config_path()}))
        machine.succeed(base_system + "/bin/switch-to-configuration test", timeout=60)
        assert machine.succeed("readlink -f /run/current-system").strip() == base_system
        machine.fail("test -e /etc/native-generation")
        assert config_path() == conf
        assert before == snapshot()
        assert live_before == snapshot(live=True)
        assert daemon_identity == machine.succeed("systemctl show sentinelone.service -p MainPID -p InvocationID -p Environment")
        assert init_identity == machine.succeed("systemctl show sentinelone-init.service -p InvocationID -p ExecMainStartTimestampMonotonic")
        assert transaction_pids == json.loads(guest(lock_witness))
        print("Real dpkg/frontend+database locks remained held across base return:", json.dumps({"pids": transaction_pids, "after_system": base_system}))
    finally:
        machine.succeed("touch /run/native-dpkg-release")
        machine.wait_until_succeeds("test \"$(systemctl show native-dpkg-transaction -p SubState --value)\" = exited", timeout=60)
        print(machine.succeed("journalctl -u native-dpkg-transaction --no-pager"))
    assert machine.succeed("systemctl show native-dpkg-transaction -p Result --value").strip() == "success"
    assert machine.succeed("systemctl show native-dpkg-transaction -p ExecMainStatus --value").strip() == "0"
    assert machine.succeed("systemctl show native-dpkg-transaction -p MainPID --value").strip() == "0"
    guest("from pathlib import Path; assert all(not Path('/proc', str(pid)).exists() for pid in " + repr(transaction_pids) + ")")
    machine.succeed("systemctl stop native-dpkg-transaction")
    assert machine.succeed("DPKG_ADMINDIR=" + control + "/dpkg dpkg-query -W -f=" + shlex.quote("''${Status} ''${Version}") + " sentinelagent").strip() == "install ok installed 99"
    assert machine.succeed("DPKG_ADMINDIR=" + control + "/dpkg dpkg --audit").strip() == ""
    assert active_cli == machine.succeed("sentinelctl probe")
    assert state()["runtime_active"] == conf
    before = snapshot()

    # The actual switch hook must veto before it can stop the protected daemon.
    pid = machine.succeed("systemctl show sentinelone.service -p MainPID --value").strip()
    for generation in ["disabled", "legacy", "moved"]:
        machine.fail(base_system + "/specialisation/" + generation + "/bin/switch-to-configuration test")
        assert machine.succeed("systemctl show sentinelone.service -p MainPID --value").strip() == pid
        assert before == snapshot()

    # Pre-switch checks only stable metadata while real POSIX dpkg locks are held.
    guest("""
    import subprocess
    subprocess.Popen(['python3','-c',"import fcntl,time,os; f=open('/var/lib/sentinelone-nix/dpkg/lock-frontend','r+'); fcntl.lockf(f,fcntl.LOCK_EX); open('/run/native-lock-held','w').write(str(os.getpid())); time.sleep(45)"], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    """)
    machine.wait_until_succeeds("test -f /run/native-lock-held")
    machine.succeed(base_system + "/bin/switch-to-configuration test")
    assert before == snapshot()
    started = time.monotonic()
    machine.fail("sentinelctl lock-contention")
    assert 12 <= time.monotonic() - started <= 23
    assert before == snapshot()
    guest("import os,signal; from pathlib import Path; os.kill(int(Path('/run/native-lock-held').read_text()),signal.SIGTERM)")

    # Direct-kernel
    # changing any host configuration or claiming bootloader rollback coverage.
    machine.shutdown()
    os.environ["QEMU_KERNEL_PARAMS"] = "init=" + next_system + "/init"
    machine.start()
    machine.wait_for_unit("sentinelone-init.service")
    machine.wait_for_unit("sentinelone.service")
    assert machine.succeed("readlink -f /run/current-system").strip() == next_resolved
    next_conf = config_path()
    assert next_conf != conf
    assert state()["runtime_active"] == next_conf
    machine.succeed("nix-store --check-validity " + shlex.quote(next_conf))
    assert machine.succeed("readlink /nix/var/nix/gcroots/sentinelone-nix/active").strip() == next_conf
    assert gc_roots() == {"/nix/var/nix/gcroots/sentinelone-nix/active": next_conf}
    assert machine.succeed("sentinelctl probe") != active_cli
    machine.succeed("grep -q '^99$' " + root + "/data/version")
    assert state()["seed"] == initial["seed"]
    machine.shutdown()
    del os.environ["QEMU_KERNEL_PARAMS"]
    machine.start()
    machine.wait_for_unit("sentinelone-init.service")
    machine.wait_for_unit("sentinelone.service")
    assert state()["runtime_active"] == conf
    assert machine.succeed("sentinelctl probe") == active_cli

    # Pending, malformed, unsafe metadata and unknown GC roots fail closed.
    baseline = snapshot()
    saved = machine.succeed("cat " + state_path)
    for mutation in [
        "s['phase']='pending'",
        "s['schema']=999",
        "s['mode']='legacy'",
        "s['runtime_active']='/tmp/not-a-store-config'",
        "s['data_dir']='/nix/var/nix/gcroots/sentinelone-nix'",
        "s['data_dir']='/nix/var/nix/gcroots'",
        "s['data_dir']='/nix/var/nix/gcroots/sentinelone-nix/payload'",
    ]:
        guest("import json; from pathlib import Path; p=Path(" + repr(state_path) + "); s=json.loads(p.read_text()); " + mutation + "; p.write_text(json.dumps(s))")
        damaged = snapshot()
        machine.fail(ctl + " preflight " + conf)
        machine.fail(ctl + " reconcile " + conf)
        if mutation == "s['phase']='pending'":
            assert json.loads(machine.succeed(ctl + " status " + conf))["phase"] == "pending"
        assert damaged == snapshot()
        guest("from pathlib import Path; Path(" + repr(state_path) + ").write_text(" + repr(saved) + ")")
    guest("from pathlib import Path; Path(" + repr(state_path) + ").write_text('not JSON')")
    machine.fail(ctl + " preflight " + conf)
    guest("from pathlib import Path; Path(" + repr(state_path) + ").write_text(" + repr(saved) + ")")
    machine.succeed("chmod 644 " + state_path)
    machine.fail(ctl + " preflight " + conf)
    machine.succeed("chmod 600 " + state_path)
    machine.succeed("ln -s " + conf + " /nix/var/nix/gcroots/sentinelone-nix/foreign")
    machine.fail(ctl + " preflight " + conf)
    machine.succeed("test -L /nix/var/nix/gcroots/sentinelone-nix/foreign")
    guest("from pathlib import Path; Path('/nix/var/nix/gcroots/sentinelone-nix/foreign').unlink()")
    assert baseline == snapshot()

    # The marker is boot-only. A service first enabled by activation is skipped.
    machine.succeed("mv /run/sentinelone-nix-boot-config /run/saved-native-boot-config")
    machine.fail(ctl + " reconcile " + conf)
    assert baseline == snapshot()
    machine.succeed("mv /run/saved-native-boot-config /run/sentinelone-nix-boot-config")

    # Persistent systemd conflicts are refused before fresh initialization.
    persistent.wait_for_unit("multi-user.target")
    foreign = "/etc/systemd/system/sentinelone.service.d/99-foreign.conf"
    assert "foreign persistent sentinelone unit or dropin" in persistent.succeed("journalctl -u sentinelone-init --no-pager")
    persistent_before = persistent.succeed("stat -c '%i %a %u %g %Y %Z' " + foreign + "; cat " + foreign)
    persistent.fail(ctl + " preflight " + config_path(persistent))
    assert persistent_before == persistent.succeed("stat -c '%i %a %u %g %Y %Z' " + foreign + "; cat " + foreign)
    for path in [control, root, "/opt/sentinelone", "/nix/var/nix/gcroots/sentinelone-nix", "/usr/sbin/sleep"]:
        persistent.fail("test -e " + path)
    assert gc_roots(persistent) == {}

    # Boot a genuine configuration containing a foreign persistent drop-in.
    # /etc/systemd/system is a read-only NixOS link; never write through it.
    persistent_state = machine.succeed("sha256sum " + state_path + " " + control + "/dpkg/status " + root + "/data/version " + root + "/data/user-state")
    machine.shutdown()
    os.environ["QEMU_KERNEL_PARAMS"] = "init=" + base_system + "/specialisation/foreign/init"
    machine.start()
    machine.wait_for_unit("multi-user.target")
    del os.environ["QEMU_KERNEL_PARAMS"]
    assert "foreign persistent sentinelone unit or dropin" in machine.succeed("journalctl -u sentinelone-init --no-pager")
    assert persistent_state == machine.succeed("sha256sum " + state_path + " " + control + "/dpkg/status " + root + "/data/version " + root + "/data/user-state")
    foreign_before = machine.succeed("stat -c '%i %a %u %g %Y %Z' " + foreign + "; cat " + foreign)
    machine.fail(ctl + " preflight " + config_path())
    assert foreign_before == machine.succeed("stat -c '%i %a %u %g %Y %Z' " + foreign + "; cat " + foreign)
    assert persistent_state == machine.succeed("sha256sum " + state_path + " " + control + "/dpkg/status " + root + "/data/version " + root + "/data/user-state")
    assert gc_roots() == {"/nix/var/nix/gcroots/sentinelone-nix/active": conf}

    # Unknown/legacy
    unknown.wait_for_unit("multi-user.target")
    assert "foreign provider slot: /usr/sbin/sleep" in unknown.succeed("journalctl -u sentinelone-init --no-pager")
    unknown.fail("test -e " + control)
    unknown.succeed("rm /usr/sbin/sleep")
    conf_unknown = config_path(unknown)
    unknown.succeed("mkdir -p " + root)
    unknown.fail(ctl + " preflight " + conf_unknown)
    unknown.fail(ctl + " reconcile " + conf_unknown)
    unknown.fail("test -e " + control)
    unknown.succeed("rmdir " + root)
    unknown.succeed("mkdir -p /usr/sbin; touch /usr/sbin/sleep")
    unknown.fail(ctl + " reconcile " + conf_unknown)
    unknown.fail("test -e " + control)
    unknown.succeed("rm /usr/sbin/sleep")
    unknown.succeed("mkdir -m 700 " + control)
    unknown.fail(ctl + " preflight " + conf_unknown)
    unknown.fail("test -e " + state_path)
  '';
}
