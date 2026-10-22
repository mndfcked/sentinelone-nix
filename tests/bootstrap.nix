{
  lib,
  pkgs,
  nixosModules,
}:
let
  agent = pkgs.writeShellScript "bootstrap-agent" ''
    touch /run/sentinelone-started
    while true; do sleep 5; done
  '';
  package = pkgs.runCommand "sentinelone-bootstrap-fixture" { } ''
    mkdir -p $out/opt/sentinelone/{bin,ebpfs,ranger,lib,configuration,data}
    install -m 755 ${agent} $out/opt/sentinelone/bin/sentinelone-agent
    install -m 755 ${pkgs.writeShellScript "sentinelctl" ""} $out/opt/sentinelone/bin/sentinelctl
    printf 'seed data\n' > $out/opt/sentinelone/data/seed
    chmod 750 $out/opt/sentinelone/data
    chmod 640 $out/opt/sentinelone/data/seed
    ln -s seed $out/opt/sentinelone/data/seed-link
    install -m 755 ${agent} $out/opt/sentinelone/data/executable
    head -c 16384 /dev/zero > $out/opt/sentinelone/data/large
  '';
  node = fixturePackage: {
    imports = [ nixosModules.default ];
    environment.systemPackages = [ pkgs.python3 ];
    users.users.reader.isNormalUser = true;
    services.sentinelone = {
      enable = true;
      package = fixturePackage;
      customerId = "fixture-customer";
      dataDir = "/var/lib/bootstrap-test/state";
      sentinelOneManagementTokenPath = "/run/bootstrap-token";
    };
    systemd.services.sentinelone = {
      wantedBy = lib.mkForce [ ];
      unitConfig.RefuseManualStop = lib.mkForce "no";
      serviceConfig.ExecStop = lib.mkForce [ ];
    };
  };
  badSeed = pkgs.runCommand "sentinelone-invalid-seed" { } ''
    mkdir -p $out/opt/sentinelone/{bin,ebpfs,ranger,lib}
    install -m 755 ${agent} $out/opt/sentinelone/bin/sentinelone-agent
  '';
  backingRoot = "/var/lib/bootstrap-backing-test";
  delayedBackingNode = lib.recursiveUpdate (node package) {
    services.sentinelone.dataDir = "${backingRoot}/state";
    systemd.mounts = [
      {
        what = "tmpfs";
        where = backingRoot;
        type = "tmpfs";
        options = "mode=0755,size=64m";
        requires = [ "sentinelone-test-backing-delay.service" ];
        after = [ "sentinelone-test-backing-delay.service" ];
        unitConfig.DefaultDependencies = "no";
      }
    ];
    systemd.services.sentinelone-test-backing-delay = {
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/sleep 1";
      };
    };
    systemd.services.sentinelone-init.serviceConfig.ExecStartPre = lib.mkAfter [
      "${pkgs.util-linux}/bin/mountpoint -q ${backingRoot}"
    ];
  };
in
pkgs.testers.nixosTest {
  name = "sentinelone-bootstrap";
  nodes = {
    machine = node package;
    badSeed = node badSeed;
    lateBacking = delayedBackingNode;
  };
  testScript = ''
    import base64
    import json
    import shlex

    root = "/var/lib/bootstrap-test/state"
    parent = "/var/lib/bootstrap-test"
    marker = root + "/.sentinelone-bootstrap.json"
    lock = parent + "/.state.bootstrap.lock"
    mounts = ["opt-sentinelone-" + p + ".mount" for p in ["bin", "ebpfs", "ranger"]] + ["opt-sentinelone.mount"]

    def guest(code, node=machine):
        return node.succeed("python3 -c " + shlex.quote(code))

    def write_token(value, node=machine):
        guest("from pathlib import Path; p = Path('/run/bootstrap-token'); p.write_text(" + repr(value) + "); p.chmod(0o600)", node)

    def encoded(value):
        return base64.b64encode(json.dumps(value).encode()).decode()

    def reset():
        machine.succeed("systemctl stop sentinelone.service " + " ".join(mounts))
        machine.succeed("systemctl reset-failed")
        guest("import shutil; from pathlib import Path; p = Path(" + repr(root) + "); p.unlink() if p.is_symlink() else shutil.rmtree(p) if p.exists() else None; Path('/run/sentinelone-started').unlink(missing_ok=True)")

    def refused(unit="sentinelone.service"):
        machine.succeed("systemctl reset-failed")
        machine.fail("systemctl start " + unit)
        machine.fail("systemctl is-active --quiet sentinelone.service")
        for mount in mounts:
            machine.fail("systemctl is-active --quiet " + mount)
        guest("from pathlib import Path; assert not Path('/run/sentinelone-started').exists()")

    def snapshot(path=root):
        # Independent manifest: content hashes, modes, ownership and symlink targets.
        return guest("""
    import hashlib, json, os, stat
    from pathlib import Path
    root = Path(PATH)
    result = {}
    for path in [root, *sorted(root.rglob('*'))] if not root.is_symlink() else [root]:
        s = path.lstat()
        content = os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        result[str(path.relative_to(root))] = [s.st_mode, s.st_uid, s.st_gid, content]
    print(json.dumps(result, sort_keys=True))
    """.replace("PATH", repr(path)))

    start_all()
    machine.wait_for_unit("multi-user.target")
    guest("from pathlib import Path; Path(" + repr(parent) + ").mkdir(mode=0o755)")
    token = encoded({"url": "http://fixture.invalid", "site_key": "synthetic-secret"})
    write_token(token + "\n")
    machine.succeed("systemctl start sentinelone.service")
    machine.wait_for_unit("sentinelone.service")
    machine.wait_until_succeeds("test -e /run/sentinelone-started")
    guest("from pathlib import Path; p = Path(" + repr(root + "/configuration/install_config") + "); assert 'S1_AGENT_CUSTOMER_ID=fixture-customer\\n' in p.read_text(); assert p.stat().st_mode & 0o777 == 0o600; assert p.stat().st_uid == 0")
    for name in ["install_config", "basic.conf", "installation_params.json"]:
        machine.fail("su -s /bin/sh reader -c 'cat " + root + "/configuration/" + name + "'")
    guest("import json; from pathlib import Path; c = json.loads(Path(" + repr(root + "/configuration/basic.conf") + ").read_text()); assert c == {'mgmt_device-type': 1, 'mgmt_site-key': 'synthetic-secret', 'mgmt_url': 'http://fixture.invalid'}")
    guest("import json; from pathlib import Path; p = Path(" + repr(marker) + "); m = json.loads(p.read_text()); assert m == {'schema': 1, 'package': '${package}'}; assert p.stat().st_uid == 0; assert p.stat().st_mode & 0o777 == 0o600")
    guest("import os; from pathlib import Path; root = Path(" + repr(root) + "); seed = Path('${package}/opt/sentinelone'); assert root.stat().st_mode & 0o777 == 0o700; assert (root/'data').stat().st_mode == (seed/'data').stat().st_mode; assert (root/'data/seed').stat().st_mode == (seed/'data/seed').stat().st_mode; assert (root/'data/executable').stat().st_mode == (seed/'data/executable').stat().st_mode; assert os.readlink(root/'data/seed-link') == 'seed'")
    machine.succeed("touch /opt/sentinelone/lib/live-data")
    machine.fail("touch /opt/sentinelone/bin/should-be-read-only")
    machine.fail("journalctl -b --grep='ordering cycle' --quiet")

    # Enrollment may consume its files. The marker is not an enrollment health check.
    machine.succeed("systemctl stop sentinelone.service " + " ".join(mounts))
    guest("from pathlib import Path; c = Path(" + repr(root + "/configuration") + "); [(c/name).unlink() for name in ['install_config', 'basic.conf', 'installation_params.json']]; Path('/run/bootstrap-token').unlink(); Path('/run/sentinelone-started').unlink()")
    before = snapshot()
    machine.succeed("systemctl start sentinelone.service")
    machine.wait_until_succeeds("test -e /run/sentinelone-started")
    after = snapshot()
    assert before == after, (before, after)
    # Restarting only the daemon leaves mounts active and must also work.
    guest("from pathlib import Path; Path('/run/sentinelone-started').unlink()")
    machine.succeed("systemctl restart sentinelone.service")
    machine.wait_until_succeeds("test -e /run/sentinelone-started")
    assert before == snapshot()

    # A different package must not combine old assets with new store binaries.
    machine.succeed("systemctl stop sentinelone.service " + " ".join(mounts))
    guest("import json; from pathlib import Path; p = Path(" + repr(marker) + "); p.write_text(json.dumps({'schema': 1, 'package': '/nix/store/different-package'})); Path('/run/sentinelone-started').unlink()")
    before = snapshot()
    refused()
    assert before == snapshot()
    assert "store-managed package mismatch" in machine.succeed("journalctl -u sentinelone-init --no-pager")
    reset()

    # A readable source is refused without chmod/chown or persistent writes.
    guest("from pathlib import Path; Path(" + repr(lock) + ").unlink()")
    write_token(token)
    guest("from pathlib import Path; Path('/run/bootstrap-token').chmod(0o644)")
    source_before = snapshot("/run/bootstrap-token")
    refused()
    assert source_before == snapshot("/run/bootstrap-token")
    guest("from pathlib import Path; assert not Path(" + repr(root) + ").exists(); assert not Path(" + repr(lock) + ").exists(); Path('/run/bootstrap-token').unlink()")

    # FIFOs and directories cannot be consumed as token files (and cannot block).
    guest("from pathlib import Path; import os; os.mkfifo('/run/bootstrap-token', 0o600)")
    source_before = snapshot("/run/bootstrap-token")
    refused()
    assert source_before == snapshot("/run/bootstrap-token")
    guest("from pathlib import Path; Path('/run/bootstrap-token').unlink(); Path('/run/bootstrap-token').mkdir(mode=0o700)")
    refused()
    guest("from pathlib import Path; assert not Path(" + repr(root) + ").exists(); assert not Path(" + repr(lock) + ").exists(); Path('/run/bootstrap-token').rmdir()")

    # Neither missing nor malformed inputs create a persistent root, stage, or lock.
    refused()
    guest("from pathlib import Path; assert not Path(" + repr(root) + ").exists(); assert not Path(" + repr(lock) + ").exists()")
    invalid = [
        "not base64",
        token[:12] + "\n" + token[12:],
        token + "\n\n",
        encoded([]),
        encoded({}),
        encoded({"url": None, "site_key": "x"}),
        encoded({"url": "", "site_key": "x"}),
        encoded({"url": "http://fixture.invalid", "site_key": 7}),
        encoded({"url": "http://fixture.invalid", "site_key": ""}),
        encoded({"url": "http://fixture.invalid\nINJECT=yes", "site_key": "x"}),
        encoded({"url": "http://fixture.invalid", "site_key": "x\ny"}),
    ]
    for value in invalid:
        write_token(value)
        refused()
        guest("from pathlib import Path; assert not Path(" + repr(root) + ").exists(); assert not Path(" + repr(lock) + ").exists(); assert not list(Path(" + repr(parent) + ").glob('.state.bootstrap-*'))")
    write_token(token)

    # Preserve legacy/partial state, malformed markers, and private ownership.
    for metadata in [None, "not JSON", "{}", '{"schema":true,"package":"${package}"}', '{"schema":1,"package":"${package}","extra":1}']:
        reset()
        guest("from pathlib import Path; import os; p = Path(" + repr(root) + "); p.mkdir(mode=0o751); f = p/'operator-data'; f.write_text('preserve me'); f.chmod(0o640); os.chown(f, 1000, 100)")
        if metadata is not None:
            guest("from pathlib import Path; p = Path(" + repr(marker) + "); p.write_text(" + repr(metadata) + "); p.chmod(0o600)")
        before = snapshot()
        refused()
        assert before == snapshot()
    # Valid-looking metadata with unsafe mode, owner, or symlink is also refused.
    for unsafe in ["p.chmod(0o644)", "os.chown(p, 1000, 100)", "p.rename('/var/lib/bootstrap-test/foreign-marker'); p.symlink_to('/var/lib/bootstrap-test/foreign-marker')"]:
        reset()
        guest("from pathlib import Path; import os, json; Path(" + repr(root) + ").mkdir(mode=0o700); p = Path(" + repr(marker) + "); p.write_text(json.dumps({'schema': 1, 'package': '${package}'})); p.chmod(0o600); " + unsafe)
        before = snapshot()
        refused()
        assert before == snapshot()
    reset()
    guest("from pathlib import Path; import os; p = Path(" + repr(root) + "); p.mkdir(mode=0o700); (p/'unprivileged-state').touch(); os.chown(p, 1000, 100)")
    before = snapshot()
    refused()
    assert before == snapshot()
    reset()

    # Root/ancestor symlinks or writable ancestors are never adopted or changed.
    guest("from pathlib import Path; p = Path('/var/lib/operator-data'); p.mkdir(); (p/'keep').write_text('unchanged'); Path(" + repr(root) + ").symlink_to(p)")
    before = snapshot("/var/lib/operator-data")
    refused()
    assert before == snapshot("/var/lib/operator-data")
    reset()
    guest("from pathlib import Path; Path(" + repr(parent) + ").chmod(0o777)")
    refused()
    guest("from pathlib import Path; p = Path(" + repr(parent) + "); assert p.stat().st_mode & 0o777 == 0o777; p.chmod(0o755)")
    guest("from pathlib import Path; p = Path(" + repr(parent) + "); p.rename('/var/lib/bootstrap-real'); p.symlink_to('/var/lib/bootstrap-real')")
    refused()
    guest("from pathlib import Path; p = Path(" + repr(parent) + "); p.unlink(); Path('/var/lib/bootstrap-real').rename(p)")

    # A nested mount and orphan staging both fail without cleanup or adoption.
    guest("from pathlib import Path; p = Path(" + repr(root) + "); p.mkdir(); (p/'nested').mkdir()")
    before = snapshot()
    machine.succeed("mount -t tmpfs tmpfs " + root + "/nested")
    refused()
    machine.succeed("umount " + root + "/nested")
    assert before == snapshot()
    reset()
    stage = parent + "/.state.bootstrap-interrupted"
    guest("from pathlib import Path; import os; p = Path(" + repr(stage) + "); p.mkdir(mode=0o700); (p/'unfinished').write_text('keep'); os.chown(p, 1000, 100)")
    before = snapshot(stage)
    refused()
    assert before == snapshot(stage)
    guest("import shutil; shutil.rmtree(" + repr(stage) + ")")

    # A real copy failure via the service's resource limit cannot publish partial state.
    guest("from pathlib import Path; p = Path('/run/systemd/system/sentinelone-init.service.d'); p.mkdir(parents=True); (p/'copy-failure.conf').write_text('[Service]\\nLimitFSIZE=1024\\n')")
    machine.succeed("systemctl daemon-reload")
    refused()
    guest("from pathlib import Path; assert not Path(" + repr(root) + ").exists(); assert not list(Path(" + repr(parent) + ").glob('.state.bootstrap-*')); Path('/run/systemd/system/sentinelone-init.service.d/copy-failure.conf').unlink()")
    machine.succeed("systemctl daemon-reload")
    machine.succeed("systemctl reset-failed")
    # A secret-manager-style root-controlled symlink may point to a private
    # source owned by the configured secret recipient, rather than root.
    guest("from pathlib import Path; import os; d = Path('/run/synthetic-secrets.d/1'); d.mkdir(parents=True, mode=0o751); p = d/'token'; Path('/run/bootstrap-token').rename(p); os.chown(p, 1000, 100); Path('/run/bootstrap-token').symlink_to(p)")
    source_before = snapshot('/run/synthetic-secrets.d/1/token')
    # An empty root-owned directory is also an allowed destination, atomically replaced.
    guest("from pathlib import Path; Path(" + repr(root) + ").mkdir(mode=0o750)")
    machine.succeed("systemctl start sentinelone.service")
    machine.wait_until_succeeds("test -e /run/sentinelone-started")
    assert source_before == snapshot('/run/synthetic-secrets.d/1/token')
    assert "synthetic-secret" not in machine.succeed("journalctl -b --no-pager")
    assert token not in machine.succeed("journalctl -b --no-pager")
    assert "synthetic-secret" not in machine.succeed("ps axeww")
    assert token not in machine.succeed("ps axeww")
    reset()

    # Starting base or component mounts directly must also require successful init.
    guest("from pathlib import Path; Path('/run/bootstrap-token').unlink()")
    for unit in mounts:
        refused(unit)

    # An invalid immutable seed fails before any persistent writes, even with a token.
    badSeed.wait_for_unit("multi-user.target")
    guest("from pathlib import Path; Path(" + repr(parent) + ").mkdir(mode=0o755); p = Path('/run/bootstrap-token'); p.write_text(" + repr(token) + "); p.chmod(0o600)", badSeed)
    badSeed.fail("systemctl start sentinelone.service")
    guest("from pathlib import Path; assert not Path(" + repr(root) + ").exists(); assert not Path(" + repr(lock) + ").exists(); assert not Path('/run/sentinelone-started').exists()", badSeed)

    lateRoot = "/var/lib/bootstrap-backing-test/state"
    lateParent = "/var/lib/bootstrap-backing-test"
    lateMarker = lateRoot + "/.sentinelone-bootstrap.json"
    lateBacking.wait_for_unit("multi-user.target")
    guest("from pathlib import Path; p = Path(" + repr(lateParent) + "); p.mkdir(mode=0o755, exist_ok=True); p.chmod(0o755)", lateBacking)
    write_token(token + "\n", lateBacking)
    lateBacking.fail("mountpoint -q " + shlex.quote(lateParent))
    lateBacking.succeed("systemctl start sentinelone-init.service")
    lateBacking.succeed("mountpoint -q " + shlex.quote(lateParent))
    lateBacking.succeed("test -f " + shlex.quote(lateMarker))
    lateBacking.succeed("test \"$(stat -f -c %T " + shlex.quote(lateRoot) + ")\" = tmpfs")
    lateBacking.succeed("systemctl show -P Result sentinelone-init.service | grep -Fx success")
    guest("import json; from pathlib import Path; p = Path(" + repr(lateMarker) + "); m = json.loads(p.read_text()); assert m == {'schema': 1, 'package': '${package}'}; assert p.stat().st_uid == 0; assert p.stat().st_mode & 0o777 == 0o600; assert Path(" + repr(lateRoot) + ").stat().st_dev == Path(" + repr(lateParent) + ").stat().st_dev", lateBacking)
    lateBacking.fail("systemctl is-active --quiet sentinelone.service")
  '';
}
