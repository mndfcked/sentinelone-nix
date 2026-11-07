# Manual, private-source seam. The required original DEB is an owner-trusted
# administrator handoff, not independently signed/authenticated. Never public CI.
{ pkgs, vendorDeb }:
let
  lib = pkgs.lib;
  sha256 = "3ff2e97e591135410abafb90e9297cb550738caadf0dd4119b2013574b29e630";
  original =
    assert builtins.isPath vendorDeb;
    assert builtins.hashFile "sha256" vendorDeb == sha256;
    builtins.path {
      path = vendorDeb;
      name = "sentinelone-original-vendor.deb";
    };
  package =
    pkgs.runCommand "sentinelone-native-unused-patched-output"
      {
        passthru.src = original;
      }
      ''
        echo "Native tests must use the original DEB, never patched package output" >&2
        exit 1
      '';
  observer = ./native-vendor-observer.py;
in
pkgs.testers.runNixOSTest {
  name = "sentinelone-native-vendor-offline";
  globalTimeout = 900;
  qemu.forceAccel = true;
  nodes.machine = {
    imports = [ ../module.nix ];
    services.sentinelone = {
      enable = true;
      vendorManagedUpdates = true;
      inherit package;
      dataDir = "/var/lib/sentinelone-vendor-payload";
      customerId = null;
      email = null;
      serialNumber = null;
      sentinelOneManagementTokenPath = null;
    };
    environment.systemPackages = [
      pkgs.python3
      pkgs.dpkg
    ];
    environment.etc."sentinelone-test-generation".text = lib.mkDefault "base\n";
    specialisation.s1-platform-next.configuration = {
      environment.etc."sentinelone-test-generation".text = lib.mkForce "next\n";
    };
    system.switch.enable = true;
    nix.settings.build-users-group = lib.mkForce "";

    # The real controller requires multi-user.target not yet active. Hold that
    # target while the backdoor runs; never replace the module's boot marker.
    systemd.services.sentinelone-init.wantedBy = lib.mkForce [ ];
    systemd.services.sentinelone-test-containment = {
      wantedBy = [ "multi-user.target" ];
      before = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "240s";
      };
      script = ''
        until test -e /run/sentinelone-test-contained; do sleep 0.1; done
      '';
    };
    virtualisation = {
      memorySize = lib.mkForce 2048;
      mountHostNixStore = lib.mkForce true;
      useNixStoreImage = lib.mkForce false;
      writableStore = lib.mkForce false;
      useHostCerts = lib.mkForce false;
      qemu.networkingOptions = lib.mkForce [ "-net none" ];
      forwardPorts = lib.mkForce [ ];
      vlans = lib.mkForce [ ];
      interfaces = lib.mkForce { };
      # Only the host store and this driver's private exchange directory.
      sharedDirectories = lib.mkForce {
        nix-store = {
          source = "/nix/store";
          target = "/nix/.ro-store";
          writable = false;
        };
        shared = {
          source = ''"''${SHARED_DIR}"'';
          target = "/tmp/shared";
          writable = true;
        };
      };
    };
    networking.interfaces = lib.mkForce { };
    networking.useDHCP = lib.mkForce false;
  };
  testScript = ''
    import datetime as dt
    import hashlib
    import json
    import os
    from pathlib import Path
    import re
    import shlex
    import stat
    import time
    from typing import Any

    ORIGINAL = "${original}"
    PYTHON = "${pkgs.python3}/bin/python3"
    OBSERVER = "${observer}"
    DPKG = "${pkgs.dpkg}/bin/dpkg"
    QUERY = "${pkgs.dpkg}/bin/dpkg-query"
    DATABASE = "/var/lib/sentinelone-nix/dpkg"
    upgrade: dict[str, Any] = {"attempts": 0}
    report: dict[str, Any] = {
        "schema": 1,
        "failures": [],
        "stage": "containment",
        "package": {
            "version": "26.2.1.24",
            "sha256": "${sha256}",
            "size": 61602192,
            "source": ORIGINAL,
            "trust": "owner-trusted administrator handoff; not independently authenticated",
        },
        "containment": [],
        "windows": {},
        "snapshots": {},
        "upgrade": upgrade,
        "limits": [
            "Unenrolled offline local SAME-PACKAGE replacement of owner-trusted v26 only.",
            "Nine physical no-follow selected files; no BPF treewalk or full-state equality.",
            "Default dpkg absence is endpoint evidence, not proof of zero transient writes.",
            "Test-mode system closures, not profile-generation or bootloader rollback.",
            "No management delivery, N-to-N+1, health, Frame hardware or production support claim.",
            "Dedicated successful-exec window only; no args, ptrace, global tracing or failed-exec/absence inference.",
        ],
    }
    report_path = Path(driver.out_dir) / "native-vendor-evidence.json"


    def save():
        report_path.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")


    def observe(mode, *extra):
        return json.loads(machine.succeed(shlex.join([PYTHON, OBSERVER, mode, *extra])))


    def containment():
        # On each boot this runs before init; activation checks run again later.
        argv = (
            Path(f"/proc/{machine.pid}/cmdline")
            .read_bytes()
            .decode()
            .rstrip("\0")
            .split("\0")
        )
        assert Path(argv[0]).name == "qemu-system-x86_64"
        assert any(argv[i : i + 2] == ["-net", "none"] for i in range(len(argv)))
        assert all(
            argv[i : i + 2] == ["-net", "none"] for i, a in enumerate(argv) if a == "-net"
        )
        assert not any(
            a.split("=", 1)[0] in ("-netdev", "-nic", "-fsdev", "-virtfs")
            or a.startswith("-net=")
            for a in argv
        )
        devices = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-device"]
        allowed = {
            "virtio-rng-pci",
            "virtio-blk-pci",
            "virtio-keyboard",
            "usb-tablet",
            "vhost-user-fs-pci",
            "virtio-serial",
            "virtconsole",
        }
        assert all(d.split(",")[0] in allowed for d in devices)
        shares = [d for d in devices if d.startswith("vhost-user-fs-pci,")]
        tags = []
        for share in shares:
            match = re.search(r"(?:^|,)tag=([^,]+)", share)
            assert match is not None
            tags.append(match.group(1))
        assert sorted(tags) == ["nix-store", "shared"]
        assert argv[argv.index("-m") + 1] == "2048"
        assert machine.qmp_client is not None
        network = machine.qmp_client.send(
            "human-monitor-command", {"command-line": "info network"}
        )
        assert isinstance(network.get("return"), str) and not network["return"].strip()
        assert machine.shared_dir.resolve().is_relative_to(machine.tmp_dir.resolve())
        assert stat.S_IMODE(machine.shared_dir.stat().st_mode) == 0o700
        guest = observe("containment")
        report["containment"].append(
            {
                "qemu_net": ["-net", "none"],
                "qmp_network": network["return"],
                "devices": devices,
                "guest": guest,
                "scratch_mode": "0700",
            }
        )
        save()


    def configured():
        states = {}
        for name in ("sentinelagent", "sentinelone-nix-runtime"):
            status = machine.succeed(
                shlex.join([QUERY, "--admindir=" + DATABASE, "-W", "-f=''${Status}", name])
            )
            assert status == "install ok installed", name
            states[name] = status
        assert not machine.succeed(
            shlex.join([DPKG, "--admindir=" + DATABASE, "--audit"])
        ).strip()
        return states


    def default_absent():
        status, output = machine.execute(
            shlex.join(["env", "-u", "DPKG_ADMINDIR", QUERY, "-W", "sentinelagent"])
            + " 2>/dev/null"
        )
        assert status == 1 and not output.strip()
        return {"exit": status, "vendor_absent": True}


    def stable(label):
        report["stage"] = label + "-stable-window"
        save()
        machine.wait_for_unit("sentinelone.service", timeout=dt.timedelta(seconds=90))
        samples = []
        started = time.monotonic()
        properties = (
            "ActiveState,SubState,Result,MainPID,NRestarts,WatchdogUSec,"
            "WatchdogTimestampMonotonic,RefuseManualStop,Restart,FragmentPath"
        )
        for second in range(3, 46, 3):
            time.sleep(max(0, started + second - time.monotonic()))
            output = machine.succeed(
                "systemctl show sentinelone.service --property=" + properties
            )
            p = dict(line.split("=", 1) for line in output.splitlines())
            samples.append(p)
            report["windows"][label] = {
                "samples": samples,
                "elapsed": time.monotonic() - started,
            }
            save()
            assert all(
                p[key] == value
                for key, value in {
                    "ActiveState": "active",
                    "SubState": "running",
                    "Result": "success",
                    "NRestarts": "0",
                    "WatchdogUSec": "30s",
                    "RefuseManualStop": "yes",
                    "Restart": "on-failure",
                    "FragmentPath": "/run/systemd/system/sentinelone.service",
                }.items()
            ), label
            assert p["MainPID"].isdecimal() and int(p["MainPID"]) > 0
            assert int(p["WatchdogTimestampMonotonic"]) > 0
        assert len({p["MainPID"] for p in samples}) == 1
        ticks = [int(p["WatchdogTimestampMonotonic"]) for p in samples]
        assert all(a <= b for a, b in zip(ticks, ticks[1:])) and ticks[-1] > ticks[0]
        report["windows"][label]["elapsed"] = time.monotonic() - started
        save()


    def snapshot(label, expected=None):
        report["stage"] = label + "-snapshot"
        save()
        current = observe("snapshot")
        current["configured"] = configured()
        assert current["state"]["seed"] == {
            "deb": ORIGINAL,
            "sha256": "${sha256}",
            "version": "26.2.1.24",
        }
        if expected is not None:
            assert current == expected, label + ": selected state changed"
        report["snapshots"][label] = current
        save()
        return current


    def boot():
        machine.wait_for_unit("basic.target", timeout=dt.timedelta(seconds=90))
        machine.wait_for_unit("post-boot.service", timeout=dt.timedelta(seconds=90))
        containment()
        machine.succeed(
            "test -f /run/sentinelone-nix-boot-config; test ! -e /run/sentinelone-nix-reconciled"
        )
        assert (
            machine.succeed(
                "systemctl show sentinelone.service -p LoadState --value"
            ).strip()
            == "not-found"
        )
        machine.wait_for_unit("register-nix-paths.service", timeout=dt.timedelta(seconds=90))
        boot_config = machine.succeed("cat /run/sentinelone-nix-boot-config").strip()
        config = json.loads(machine.succeed("cat " + shlex.quote(boot_config)))
        machine.succeed(shlex.join([config["nix_store"], "--check-validity", boot_config]))
        report["stage"] = "module-boot-reconcile"
        save()
        machine.succeed(
            "systemctl start sentinelone-init.service", timeout=dt.timedelta(seconds=190)
        )
        machine.succeed("install -m 0600 /dev/null /run/sentinelone-test-contained")
        machine.wait_for_unit("multi-user.target", timeout=dt.timedelta(seconds=30))


    def bounded(argv):
        # Drain after the 1 MiB prefix, preserving pipefail and closed stdin.
        inner = shlex.join(["timeout", "--signal=TERM", "--kill-after=3s", "90s", *argv])
        inner += " < /dev/null 2>&1 | { head -c 1048576; cat > /dev/null; }"
        return machine.execute(
            shlex.join(
                [
                    "timeout",
                    "--signal=TERM",
                    "--kill-after=3s",
                    "96s",
                    "${pkgs.bash}/bin/bash",
                    "-o",
                    "pipefail",
                    "-c",
                    inner,
                ]
            ),
            timeout=dt.timedelta(seconds=110),
        )


    try:
        save()
        assert "QEMU_OPTS" not in os.environ, "Outer invocation must unset QEMU_OPTS"
        machine.start(allow_reboot=True)
        machine.wait_for_unit("basic.target", timeout=dt.timedelta(seconds=90))
        containment()
        report["default_database_before"] = default_absent()
        assert (
            machine.succeed("sha256sum " + shlex.quote(ORIGINAL)).split()[0] == "${sha256}"
        )
        assert machine.succeed("stat -c %s " + shlex.quote(ORIGINAL)).strip() == "61602192"
        machine.succeed("test ! -e /var/lib/sentinelone-nix; test ! -e /opt/sentinelone")
        boot()
        stable("bootstrap")
        before = snapshot("before-upgrade")
        boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
        root_uuid = machine.succeed("findmnt -n -o UUID -T /").strip()
        assert root_uuid
        report["identity_before"] = {"boot_id": boot_id, "root_uuid": root_uuid}
        report["stage"] = "single-supported-upgrade"
        trace_start = observe("trace-start")
        upgrade["trace_start"] = trace_start
        save()
        try:
            upgrade["attempts"] = 1
            save()
            status, output = bounded(
                [
                    "/run/current-system/sw/bin/sentinelctl",
                    "control",
                    "upgrade",
                    "--output",
                    ORIGINAL,
                ]
            )
            cli: dict[str, Any] = {
                "exit": status,
                "output_bytes": len(output.encode()),
                "output_sha256": hashlib.sha256(output.encode()).hexdigest(),
                "successful_output": "Agent upgrade successful" in output
                and "Agent is running" in output,
                "command_timeout": 90,
                "drain_timeout": 96,
                "driver_timeout": 110,
                "output_cap": 1048576,
                "stdin": "closed",
                "retries": 0,
            }
            upgrade["command"] = cli
        finally:
            upgrade["trace_stop"] = observe("trace-stop", str(trace_start["inode"]))
            save()
        assert status == 0 and len(output.encode()) < 1048576 and cli["successful_output"]
        events = upgrade["trace_stop"]["events"]
        assert upgrade["trace_stop"]["complete"]
        assert (
            upgrade["trace_stop"]["per_cpu_after"].keys()
            == trace_start["per_cpu_before"].keys()
        )
        assert any(e["filename"] == DPKG for e in events), (
            "No positive real dpkg successful-exec witness"
        )
        stable("after-upgrade")
        upgraded = snapshot("after-upgrade")
        assert len(before["payload"]) == len(upgraded["payload"]) == 9
        assert all(
            upgraded["payload"][name]["inode"] != item["inode"]
            and upgraded["payload"][name]["sha256"] == item["sha256"]
            for name, item in before["payload"].items()
        )
        assert before["controls"] == upgraded["controls"]
        assert before["unit"] == upgraded["unit"]
        report["stage"] = "reboot"
        save()
        machine.reboot()
        boot()
        assert machine.succeed("cat /proc/sys/kernel/random/boot_id").strip() != boot_id
        assert machine.succeed("findmnt -n -o UUID -T /").strip() == root_uuid
        report["identity_after_reboot"] = {
            "boot_id": machine.succeed("cat /proc/sys/kernel/random/boot_id").strip(),
            "root_uuid": root_uuid,
        }
        stable("after-reboot")
        snapshot("after-reboot", upgraded)
        base = machine.succeed("readlink -f /run/current-system").strip()
        assert machine.succeed("cat /etc/sentinelone-test-generation").strip() == "base"
        alternate = machine.succeed(
            "readlink -f " + shlex.quote(base + "/specialisation/s1-platform-next")
        ).strip()
        assert (
            base.startswith("/nix/store/")
            and alternate.startswith("/nix/store/")
            and base != alternate
        )
        report["system_closures"] = {"base": base, "next": alternate, "activations": []}
        for label, target, tag in (
            ("next", alternate, "next"),
            ("base-restored", base, "base"),
        ):
            report["stage"] = label + "-activation"
            save()
            status, output = bounded([target + "/bin/switch-to-configuration", "test"])
            assert status == 0 and len(output.encode()) < 1048576, label
            assert machine.succeed("readlink -f /run/current-system").strip() == target
            assert machine.succeed("cat /etc/sentinelone-test-generation").strip() == tag
            containment()
            stable(label)
            snapshot(label, upgraded)
            assert (
                machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
                == report["identity_after_reboot"]["boot_id"]
            )
            assert machine.succeed("findmnt -n -o UUID -T /").strip() == root_uuid
            report["system_closures"]["activations"].append(
                {
                    "path": target,
                    "tag": tag,
                    "mode": "test",
                    "boot_id": report["identity_after_reboot"]["boot_id"],
                    "root_uuid": root_uuid,
                }
            )
        report["default_database_after"] = default_absent()
        report["stage"] = "complete"
        save()
        print("PRIVATE_NATIVE_VENDOR_REPORT=" + str(report_path))
    except Exception as error:
        # Do not copy exception text, vendor output or raw logs into the report.
        report["failures"].append(
            {"type": type(error).__name__, "stage": report.get("stage", "starting")}
        )
        window = report["windows"].get(report["stage"].removesuffix("-stable-window"))
        if window and window["samples"]:
            print("VENDOR_STABILITY_DIAGNOSTIC=" + json.dumps({
                "stage": report["stage"], "count": len(window["samples"]),
                "first": window["samples"][0], "last": window["samples"][-1],
            }, sort_keys=True))
        try:
            status = machine.succeed(
                "systemctl show sentinelone.service --property="
                "ActiveState,SubState,Result,MainPID,NRestarts,ExecMainCode,ExecMainStatus"
            )
            report["unit_failure_diagnostic"] = dict(
                line.split("=", 1) for line in status.splitlines()
            )
            print("VENDOR_UNIT_DIAGNOSTIC=" + json.dumps(report["unit_failure_diagnostic"], sort_keys=True))
        except Exception as status_error:
            print("VENDOR_UNIT_DIAGNOSTIC=" + type(status_error).__name__)
        try:
            diagnostic_code = """
    import json
    import os
    import pwd
    import stat

    result = {"paths": {}}
    for path in [
        "/opt",
        "/opt/sentinelone",
        "/var/lib/sentinelone-vendor-payload",
        "/var/lib/sentinelone-vendor-payload/configuration",
        "/var/lib/sentinelone-vendor-payload/configuration/sentinelone.service",
    ]:
        try:
            meta = os.lstat(path)
            entry = {
                "exists": True,
                "type": stat.filemode(meta.st_mode)[0],
                "uid": meta.st_uid,
                "gid": meta.st_gid,
                "mode": oct(stat.S_IMODE(meta.st_mode)),
            }
            if stat.S_ISLNK(meta.st_mode):
                entry["readlink"] = os.readlink(path)[:2048]
            result["paths"][path] = entry
        except FileNotFoundError:
            result["paths"][path] = {"exists": False}
        except OSError as path_error:
            result["paths"][path] = {"error": type(path_error).__name__}
    try:
        account = pwd.getpwnam("sentinelone")
        result["sentinelone"] = {"uid": account.pw_uid, "gid": account.pw_gid}
    except KeyError:
        result["sentinelone"] = {"exists": False}
    print(json.dumps(result, sort_keys=True))
    """
            diagnostic_status, diagnostic_output = machine.execute(
                shlex.join([PYTHON, "-c", diagnostic_code]),
                timeout=dt.timedelta(seconds=10),
            )
            if diagnostic_status != 0:
                raise RuntimeError("guest collector exit " + str(diagnostic_status))
            diagnostic = json.loads(diagnostic_output)
            diagnostic_json = json.dumps(diagnostic, sort_keys=True)
            if len(diagnostic_json.encode()) > 16384:
                raise ValueError("guest collector exceeded 16 KiB")
            report["vendor_mapping_diagnostic"] = diagnostic
        except Exception as collector_error:
            diagnostic_json = json.dumps({"collector_error": type(collector_error).__name__})
        print("VENDOR_MAPPING_DIAGNOSTIC=" + diagnostic_json)
        save()
        raise
  '';
}
