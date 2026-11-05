"""Guest-only selected-file and dedicated successful-exec observations, no vendor calls."""

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

ROOT = "/var/lib/sentinelone-vendor-payload"
CONTROL = "/var/lib/sentinelone-nix"
INSTANCE = "/sys/kernel/tracing/instances/s1-upgrade"
SELECTED = (
    "bin/sentinelone-agent",
    "bin/sentinelctl",
    "bin/sentinelone-watchdog",
    "bin/addon-host",
    "ranger/ranger",
    "lib/libbpf.so",
    "lib/libelf.so",
    "lib/libresolver.so",
    "lib/libdfi.so",
)


def opened(path, flags=os.O_RDONLY):
    """Open every structural component physically, including the final name."""
    parts = Path(path).parts
    assert parts[0] == "/" and all(p not in (".", "..") for p in parts)
    parent = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[1:-1]:
            child = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
            )
            os.close(parent)
            parent = child
        return os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)


def read(path, limit=65536):
    fd = opened(path)
    try:
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                return bytes(data)
            data.extend(chunk)
        raise AssertionError("Observation exceeds byte cap: " + path)
    finally:
        os.close(fd)


def physical_info(path):
    fd = opened(path)
    try:
        return os.fstat(fd)
    finally:
        os.close(fd)


def file_record(path, include_inode=False, limit=65536):
    fd = opened(path)
    try:
        before = os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and before.st_size <= limit, path
        digest = hashlib.sha256()
        count = 0
        while count <= before.st_size:
            chunk = os.read(fd, min(1048576, before.st_size + 1 - count))
            if not chunk:
                break
            count += len(chunk)
            digest.update(chunk)
        after = os.fstat(fd)
        assert count == before.st_size, path + ": short/growing read"
        assert (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) == (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ), path + ": raced read"
        result = {"sha256": digest.hexdigest(), "size": count}
        if include_inode:
            result.update({"inode": before.st_ino, "device": before.st_dev})
        return result
    finally:
        os.close(fd)


def command(argv):
    result = subprocess.run(
        argv,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=5,
        check=True,
    )
    assert len(result.stdout) < 262144
    return result.stdout.decode()


def validate_mounts(mountinfo, effective_flags):
    """Validate every stacked mount record, plus the effective VFS access flags."""
    mounts = []
    for line in mountinfo.splitlines():
        fields = line.split()
        separator = fields.index("-")
        assert separator >= 6 and len(fields) == separator + 4, (
            "Malformed mountinfo: " + line
        )
        mounts.append(
            {
                "target": fields[4],
                "source": fields[separator + 2],
                "fstype": fields[separator + 1],
                "options": fields[5],
                "record": line,
            }
        )
    host_mounts = [m for m in mounts if m["fstype"] in ("virtiofs", "9p")]
    assert host_mounts and all(
        (m["source"], m["target"])
        in (
            ("nix-store", "/nix/.ro-store"),
            ("nix-store", "/nix/store"),
            ("shared", "/tmp/shared"),
        )
        for m in host_mounts
    ), f"Unexpected host share: {host_mounts!r}; flags={effective_flags!r}"
    remote = [m for m in mounts if m["fstype"] in ("nfs", "nfs4", "cifs", "fuse.sshfs")]
    assert not remote, (
        f"Unexpected network share: {remote!r}; flags={effective_flags!r}"
    )
    for target, source, access in (
        ("/nix/store", "nix-store", "ro"),
        ("/nix/.ro-store", "nix-store", "ro"),
        ("/tmp/shared", "shared", "rw"),
    ):
        # Inspect all layers, including any non-host filesystem over these paths.
        matches = [m for m in mounts if m["target"] == target]
        assert matches and all(
            m["source"] == source
            and m["fstype"] == "virtiofs"
            and access in m["options"].split(",")
            and ("rw" if access == "ro" else "ro") not in m["options"].split(",")
            for m in matches
        ), f"Invalid mounts at {target}: {matches!r}; flags={effective_flags!r}"
        assert bool(effective_flags[target] & os.ST_RDONLY) == (access == "ro"), (
            f"Wrong effective access at {target}: {matches!r}; flags={effective_flags!r}"
        )
    return {"host_mounts": host_mounts, "effective_flags": effective_flags}


def containment():
    links = json.loads(command(["ip", "-j", "link", "show"]))
    assert [link["ifname"] for link in links] == ["lo"], "Guest interfaces"
    assert not command(["ip", "-4", "route", "show"]).strip(), "IPv4 routes"
    assert not command(["ip", "-6", "route", "show"]).strip(), "IPv6 routes"
    # The bounded, physical reader preserves stacked records hidden by summaries.
    mountinfo = read(f"/proc/{os.getpid()}/mountinfo", 262144).decode()
    effective_flags = {}
    for path in ("/nix/store", "/nix/.ro-store", "/tmp/shared"):
        fd = opened(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            # statvfs accepts an fd: keep the no-follow path identity pinned.
            effective_flags[path] = os.statvfs(fd).f_flag
        finally:
            os.close(fd)
    return {
        "interfaces": ["lo"],
        "ipv4_routes": [],
        "ipv6_routes": [],
        **validate_mounts(mountinfo, effective_flags),
    }


def mount_smoke():
    """Pure regressions; no filesystem probes, guest, or vendor execution."""
    mountinfo = (
        "71 62 0:30 / /nix/.ro-store ro,relatime shared:5 - virtiofs nix-store ro\n"
        "74 62 0:31 / /tmp/shared rw,relatime shared:7 - virtiofs shared rw\n"
        "77 62 0:30 / /nix/store ro,relatime shared:8 - virtiofs nix-store ro\n"
        "41 77 0:30 / /nix/store ro,nosuid,nodev,relatime shared:9 - virtiofs nix-store ro\n"
        "42 71 0:30 / /nix/.ro-store ro,relatime shared:6 - virtiofs nix-store ro\n"
    )
    flags = {"/nix/store": 4103, "/nix/.ro-store": 4097, "/tmp/shared": 4096}
    assert flags["/nix/store"] & os.ST_RDONLY and flags["/nix/.ro-store"] & os.ST_RDONLY
    assert len(validate_mounts(mountinfo, flags)["host_mounts"]) == 5
    checks = ["stacked-ro accepted"]

    def rejected(label, records=mountinfo, effective=flags):
        try:
            validate_mounts(records, effective)
        except AssertionError as error:
            assert str(error), "Missing diagnostic"
            checks.append(label + " rejected")
        else:
            raise AssertionError(label + " accepted")

    rejected(
        "mixed-ro/rw",
        mountinfo.replace("/nix/store ro,relatime", "/nix/store rw,relatime"),
    )
    rejected(
        "hidden-rw-store",
        mountinfo.replace(
            "/nix/.ro-store ro,relatime", "/nix/.ro-store rw,relatime", 1
        ),
    )
    rejected(
        "unexpected-source", mountinfo.replace("nix-store ro", "other-store ro", 1)
    )
    rejected(
        "unexpected-fstype",
        mountinfo.replace("virtiofs nix-store", "tmpfs nix-store", 1),
    )
    rejected(
        "absent-mount",
        "\n".join(line for line in mountinfo.splitlines() if "/nix/store " not in line),
    )
    rejected(
        "unexpected-share", mountinfo + "90 62 0:32 / /host rw - virtiofs extra rw\n"
    )
    rejected(
        "network-share", mountinfo + "90 62 0:32 / /host rw - nfs server:/host rw\n"
    )
    rejected(
        "readonly-scratch-record", mountinfo.replace("/tmp/shared rw", "/tmp/shared ro")
    )
    for path in ("/nix/store", "/nix/.ro-store"):
        rejected(
            "effective-writable-" + path,
            effective={**flags, path: flags[path] & ~os.ST_RDONLY},
        )
    rejected(
        "effective-readonly-scratch",
        effective={**flags, "/tmp/shared": flags["/tmp/shared"] | os.ST_RDONLY},
    )
    return {"checks": checks}


def snapshot():
    # Mount exclusions precede any payload open; never walk mounted BPF trees.
    mountinfo = read(f"/proc/{os.getpid()}/mountinfo", 262144).decode()
    targets = [line.split()[4] for line in mountinfo.splitlines()]
    payload = {}
    for relative in SELECTED:
        path = ROOT + "/" + relative
        assert not any(
            t != "/" and (path == t or path.startswith(t + "/")) for t in targets
        ), path + ": mounted subtree"
        payload[relative] = file_record(
            path, include_inode=True, limit=128 * 1024 * 1024
        )
    assert stat.S_ISDIR(physical_info(ROOT).st_mode)
    assert stat.S_ISDIR(physical_info("/opt").st_mode)
    mapping = os.lstat("/opt/sentinelone")
    assert mapping.st_uid == 0 and stat.S_ISLNK(mapping.st_mode)
    assert os.readlink("/opt/sentinelone") == ROOT
    for path in (
        "/etc/systemd/system/sentinelone.service",
        "/etc/systemd/system/multi-user.target.wants/sentinelone.service",
    ):
        assert not os.path.lexists(path), (
            "Persistent vendor unit would evade reboot gate"
        )
    controls = {}
    for path in (CONTROL, CONTROL + "/dpkg", "/nix/var/nix/gcroots/sentinelone-nix"):
        info = physical_info(path)
        assert (
            stat.S_ISDIR(info.st_mode)
            and info.st_uid == 0
            and stat.S_IMODE(info.st_mode) == 0o700
        ), path
        controls[path] = {"uid": info.st_uid, "mode": stat.S_IMODE(info.st_mode)}
    for path in (
        CONTROL + "/state.json",
        CONTROL + "/controller.lock",
        "/run/sentinelone-nix-boot-config",
        "/run/sentinelone-nix-reconciled",
        "/run/systemd/system/sentinelone.service.d/50-native-runtime.conf",
    ):
        info = physical_info(path)
        assert info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600, path
        controls[path] = {
            **file_record(path),
            "uid": info.st_uid,
            "mode": stat.S_IMODE(info.st_mode),
        }
    state = json.loads(read(CONTROL + "/state.json"))
    assert (
        state["phase"] == "ready"
        and state["mode"] == "vendor-managed"
        and state["data_dir"] == ROOT
    )
    assert state["runtime_pending"] is None
    assert (
        os.readlink("/nix/var/nix/gcroots/sentinelone-nix/active")
        == state["runtime_active"]
    )
    vendor = ROOT + "/configuration/sentinelone.service"
    runtime = "/run/systemd/system/sentinelone.service"
    unit = file_record(vendor)
    assert unit == file_record(runtime), (
        "Registered unit differs from CURRENT vendor unit"
    )
    info = physical_info(runtime)
    assert info.st_uid == 0 and not info.st_mode & 0o022
    lines = read(vendor).decode().splitlines()
    assert all(
        line in lines
        for line in ("WatchdogSec=30s", "RefuseManualStop=yes", "Restart=on-failure")
    )
    return {"payload": payload, "unit": unit, "controls": controls, "state": state}


def trace_write(relative, value):
    fd = opened(INSTANCE + "/" + relative, os.O_WRONLY)
    try:
        data = value.encode()
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def trace_text(relative, limit=65536):
    return read(INSTANCE + "/" + relative, limit).decode()


def cpu_stats():
    fd = opened(INSTANCE + "/per_cpu", os.O_RDONLY | os.O_DIRECTORY)
    try:
        names = os.listdir(fd)
    finally:
        os.close(fd)
    assert 0 < len(names) <= 256 and all(re.fullmatch(r"cpu[0-9]+", n) for n in names)
    stats = {}
    for name in sorted(names):
        text = trace_text("per_cpu/" + name + "/stats")
        counters = {
            key.strip(): int(value.strip())
            for line in text.splitlines()
            if ":" in line
            for key, value in [line.split(":", 1)]
            if value.strip().isdigit()
        }
        assert all(
            counters.get(k) == 0
            for k in ("overrun", "commit overrun", "dropped events")
        ), "Trace loss"
        stats[name] = counters
    return stats


def trace_start():
    mounts = read(f"/proc/{os.getpid()}/mountinfo", 262144).decode().splitlines()
    assert any(
        line.split()[4] == "/sys/kernel/tracing" and " - tracefs " in line
        for line in mounts
    )
    # No reuse, permission changes, global tracing or new mount.
    os.mkdir(INSTANCE)
    inode = physical_info(INSTANCE).st_ino
    try:
        trace_write("tracing_on", "0\n")
        assert trace_text("current_tracer").strip() == "nop"
        assert trace_text("events/enable").strip() == "0"
        trace_write("buffer_size_kb", "256\n")
        raw = trace_text("buffer_size_kb").strip()
        match = re.fullmatch(r"(\d+)(?:\s+\(units kilobytes\))?", raw)
        assert match is not None and 0 < int(match[1]) <= 512, (
            "Trace buffer readback: " + raw
        )
        assert "sched_process_exec:" not in trace_text("trace", 4 * 1024 * 1024)
        event_format = trace_text("events/sched/sched_process_exec/format")
        assert all(field in event_format for field in ("filename", "pid", "old_pid"))
        trace_write("events/sched/sched_process_exec/enable", "1\n")
        assert trace_text("events/sched/sched_process_exec/enable").strip() == "1"
        before = cpu_stats()
        trace_write("tracing_on", "1\n")
        assert trace_text("tracing_on").strip() == "1"
        return {
            "inode": inode,
            "instance": INSTANCE,
            "requested_kib": 256,
            "reported_kib": int(match[1]),
            "raw_readback": raw,
            "per_cpu_before": before,
        }
    except BaseException:
        trace_write("tracing_on", "0\n")
        raise


def trace_stop(inode):
    assert physical_info(INSTANCE).st_ino == inode, "Dedicated trace identity changed"
    was_on = trace_text("tracing_on").strip() == "1"
    trace_write("tracing_on", "0\n")
    assert was_on and trace_text("tracing_on").strip() == "0"
    assert trace_text("current_tracer").strip() == "nop"
    assert trace_text("events/sched/sched_process_exec/enable").strip() == "1"
    after = cpu_stats()
    trace = trace_text("trace", 4 * 1024 * 1024)
    events = []
    count = 0
    for line in trace.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        match = re.search(
            r"sched_process_exec:\s+filename=(.*?)\s+pid=(\d+)\s+old_pid=(\d+)\s*$",
            line,
        )
        assert match is not None, "Malformed/incomplete successful-exec trace"
        count += 1
        # Export only package-manager filenames/PIDs, never raw trace or args.
        if Path(match[1]).name == "dpkg":
            events.append(
                {"filename": match[1], "pid": int(match[2]), "old_pid": int(match[3])}
            )
    return {
        "complete": True,
        "event_count": count,
        "events": events,
        "per_cpu_after": after,
    }


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "containment":
        result = containment()
    elif mode == "mount-smoke":
        result = mount_smoke()
    elif mode == "snapshot":
        result = snapshot()
    elif mode == "trace-start":
        result = trace_start()
    elif mode == "trace-stop":
        result = trace_stop(int(sys.argv[2]))
    else:
        raise ValueError("Unknown observation")
    print(json.dumps(result, sort_keys=True))
