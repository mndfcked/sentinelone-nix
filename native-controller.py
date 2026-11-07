"""Experimental, root-only native SentinelOne lifecycle controller.

No enrollment logic lives here. A successful seed is never reapplied, and every
interrupted mutation requires explicit operator investigation rather than repair.
"""
import argparse
import contextlib
import errno
import fcntl
import hashlib
import json
import os
import pwd
import stat
import subprocess
import sys
import time
from pathlib import Path

CONTROL = Path("/var/lib/sentinelone-nix")
STATE = CONTROL / "state.json"
DATABASE = CONTROL / "dpkg"
ROOTS = Path("/nix/var/nix/gcroots/sentinelone-nix")
OPT = Path("/opt/sentinelone")
UNIT = Path("/run/systemd/system/sentinelone.service")
DROPIN = Path("/run/systemd/system/sentinelone.service.d")
PERSISTENT_UNIT = Path("/etc/systemd/system/sentinelone.service")
PERSISTENT_DROPIN = Path("/etc/systemd/system/sentinelone.service.d")
BOOT_MARK = Path("/run/sentinelone-nix-reconciled")
BOOT_CONFIG = Path("/run/sentinelone-nix-boot-config")
WAIT_SECONDS = 15


class Refusal(Exception):
    """An unsafe or unknown installation must not be changed."""


def require(condition, message):
    if not condition:
        raise Refusal(message)


def normalized(value):
    require(isinstance(value, str) and value.startswith("/") and value != "/"
            and "\n" not in value and "\r" not in value
            and all(p not in ("", ".", "..") for p in value.split("/")[1:]),
            "invalid absolute runtime path")
    return Path(value)


def overlaps(left, right):
    return left == right or left in right.parents or right in left.parents


def store_path(value):
    require(isinstance(value, str) and value.startswith("/nix/store/")
            and normalized(value).parent == Path("/nix/store"), "invalid store reference")
    return value


def ancestors(path):
    """Only structural ancestors: never walk the vendor payload or BPF mounts."""
    for parent in reversed(path.parents):
        info = parent.lstat()
        writable = info.st_mode & 0o022
        # Nix's store may be root:nixbld 1775. The sticky directory is part of
        # Nix's store trust boundary, not a mutable controller ancestor.
        if parent == Path("/nix/store") and info.st_mode & stat.S_ISVTX:
            writable = info.st_mode & 0o002
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0
                and not writable, "unsafe ancestor: " + str(parent))


def directory(path, private=False):
    ancestors(path)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0
            and not info.st_mode & 0o022, "unsafe directory: " + str(path))
    if private:
        require(stat.S_IMODE(info.st_mode) == 0o700, "directory must be 0700: " + str(path))


def read_regular(path, limit=65536, private=False, check_parents=True, dir_fd=None, device=None):
    if check_parents:
        ancestors(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0
                and not info.st_mode & 0o022 and info.st_size <= limit,
                "unsafe regular file: " + str(path))
        require(device is None or info.st_dev == device, "unit crosses payload filesystem")
        if private:
            require(stat.S_IMODE(info.st_mode) == 0o600, "file must be 0600: " + str(path))
        content = os.read(fd, limit + 1)
        after = os.fstat(fd)
        require(len(content) == info.st_size
                and all(getattr(info, field) == getattr(after, field) for field in
                        ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_size",
                         "st_mtime_ns", "st_ctime_ns")), "file changed during read: " + str(path))
        return content
    finally:
        os.close(fd)


def read_json(path, private=False, check_parents=True, limit=65536):
    return json.loads(read_regular(path, limit=limit, private=private, check_parents=check_parents))


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def mkdir(path, mode=0o700):
    if os.path.lexists(path):
        directory(path, private=(mode == 0o700))
    else:
        ancestors(path)
        path.mkdir(mode=mode)
        sync_directory(path.parent)


def atomic(path, content, mode=0o600):
    """Only controller-owned files may be replaced."""
    directory(path.parent)
    if os.path.lexists(path):
        read_regular(path, private=(mode == 0o600))
    temporary = path.with_name(path.name + ".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    except BaseException:
        # Preserve evidence on errors, including interrupted writes.
        raise


def save(state):
    atomic(STATE, (json.dumps(state, sort_keys=True) + "\n").encode())


def load_config(path, full=False):
    config = read_json(path)
    require(config.get("schema") == 1
            and type(config.get("enabled")) is bool
            and type(config.get("native")) is bool, "unknown controller config")
    data = normalized(config.get("data_dir"))
    require(not overlaps(data, CONTROL), "dataDir overlaps native control directory")
    if config["native"]:
        require(not overlaps(data, ROOTS), "dataDir overlaps native GC root directory")
    require(not data.is_relative_to("/nix/store"), "store-backed payload")
    if full:
        require(config["enabled"] and config["native"], "native mode is not enabled")
        for key in ("bootstrap_deb", "runtime", "runtime_deb", "dpkg", "dpkg_query",
                    "dpkg_deb", "systemctl", "nix_store", "loader"):
            require(str(normalized(config.get(key))).startswith("/nix/store/"),
                    "non-store tool/source: " + key)
        store_path(config["runtime"])
        require(isinstance(config.get("path"), str)
                and all(part in ("/usr/sbin", "/usr/bin", "/bin")
                        or part.startswith("/nix/store/") for part in config["path"].split(":"))
                and isinstance(config.get("library_path"), str)
                and config["library_path"].startswith("/opt/sentinelone/lib:"),
                "invalid native environment")
    return config


def state_read():
    if not os.path.lexists(CONTROL):
        require(not os.path.lexists(ROOTS), "GC roots without native state")
        return None
    directory(CONTROL, private=True)
    require(os.path.lexists(STATE), "unrecognized native control directory")
    state = read_json(STATE, private=True)
    require(set(state) == {"schema", "mode", "data_dir", "phase", "runtime_active",
                           "runtime_pending", "seed"}
            and state["schema"] == 1 and state["mode"] == "vendor-managed"
            and state["phase"] in ("pending", "ready"), "unknown native state")
    data = normalized(state["data_dir"])
    require(not overlaps(data, CONTROL), "state dataDir overlaps native control directory")
    require(not overlaps(data, ROOTS), "state dataDir overlaps native GC root directory")
    for key in ("runtime_active", "runtime_pending"):
        if state[key] is not None:
            store_path(state[key])
    seed = state["seed"]
    require(isinstance(seed, dict) and set(seed) == {"deb", "sha256", "version"}
            and isinstance(seed["sha256"], str) and len(seed["sha256"]) == 64
            and isinstance(seed["version"], str), "invalid seed provenance")
    store_path(seed["deb"])
    # No version or seed-identity comparisons: provenance is historical only.
    return state


def root_check(name, target):
    path = ROOTS / name
    require(os.path.lexists(path), "missing GC root: " + name)
    ancestors(path)
    info = path.lstat()
    require(stat.S_ISLNK(info.st_mode) and info.st_uid == 0
            and os.readlink(path) == target, "unknown GC root: " + name)


def roots_layout(expected):
    directory(ROOTS, private=True)
    require({p.name for p in ROOTS.iterdir()} == set(expected), "unknown native GC roots")
    for name, target in expected.items():
        root_check(name, target)


def roots_check(state):
    roots_layout({name: state[key]
                  for name, key in (("active", "runtime_active"), ("pending", "runtime_pending"))
                  if state[key] is not None})


def pin(name, target, config):
    require(not os.path.lexists(ROOTS / name), "existing GC root: " + name)
    run([config["nix_store"], "--realise", target, "--add-root", str(ROOTS / name)], config)
    root_check(name, target)
    sync_directory(ROOTS)


def present(path):
    """Only confirmed ENOENT is absence; dangling links remain present."""
    try:
        path.lstat()
    except FileNotFoundError as error:
        if error.errno == errno.ENOENT:
            return False
        raise
    return True


def persistent_unit_check():
    require(not present(PERSISTENT_UNIT) and not present(PERSISTENT_DROPIN),
            "foreign persistent sentinelone unit or dropin")


def desired_unit_check(desired_system):
    # Follow legitimate store aliases (including specialisations), then inspect
    # the assembled etc tree, which also includes systemd.packages drop-ins.
    system = normalized(desired_system)
    require(system.is_relative_to("/nix/store"), "desired system is not store-backed")
    system = system.resolve(strict=True)
    require(system.is_relative_to("/nix/store"), "desired system target is not store-backed")
    directory(system)
    units = (system / "etc/systemd/system").resolve(strict=True)
    require(units.is_relative_to("/nix/store"), "desired unit tree is not store-backed")
    directory(units)
    require(not present(units / "sentinelone.service")
            and not present(units / "sentinelone.service.d"),
            "foreign desired sentinelone unit or dropin")


def preflight(config, desired_system=None):
    """Read-only and independent of transient dpkg status during a vendor update."""
    state = state_read()
    intended = config["enabled"] and config["native"]
    if state is not None or intended:
        persistent_unit_check()
        if desired_system is not None:
            desired_unit_check(desired_system)
    if state is not None:
        require(state["phase"] == "ready" and state["runtime_active"] is not None
                and state["runtime_pending"] is None, "interrupted native transaction")
        require(intended and state["data_dir"] == config["data_dir"],
                "native mode cannot be disabled, converted, or moved by activation")
        directory(DATABASE, private=True)
        read_regular(CONTROL / "controller.lock", private=True)
        roots_check(state)
    elif intended:
        data = Path(config["data_dir"])
        # Even an empty existing payload is unknown. Never adopt legacy state.
        require(not os.path.lexists(data), "existing payload without native ownership metadata")
        require(not os.path.lexists(OPT), "existing /opt/sentinelone without native metadata")
        require(not os.path.lexists(UNIT) and not os.path.lexists(DROPIN),
                "existing vendor unit without native metadata")
        parent = data.parent
        while not parent.exists():
            require(not parent.is_symlink(), "symlink payload ancestor")
            parent = parent.parent
        directory(parent)
    return state


def runtime_environment(config):
    # Only the platform environment shared with the vendor unit.
    return {
        "PATH": config["path"],
        "NIX_LD": config["loader"],
        "NIX_LD_LIBRARY_PATH": config["library_path"],
        "DPKG_ADMINDIR": str(DATABASE),
        "S1_AGENT_CUSTOM_INSTALL_PATH": config["data_dir"],
        "S1_AGENT_CREATE_USER": "false",
    }


def environment(config):
    # Never inherit enrollment settings, alternate dpkg directories or hooks.
    # Root tools must not read configuration or cache in the vendor-owned home.
    return dict(runtime_environment(config), HOME="/root", TMPDIR="/tmp",
                DEBIAN_FRONTEND="noninteractive")


def run(argv, config, timeout=60):
    result = subprocess.run(argv, env=environment(config), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, check=False)
    # Do not print maintscript output: installation output is not a safe log API.
    require(result.returncode == 0, "command failed: " + Path(argv[0]).name)
    require(len(result.stdout) <= 2 * 1024 * 1024, "excessive command output")
    return result.stdout.decode()


@contextlib.contextmanager
def controller_lock():
    path = CONTROL / "controller.lock"
    if os.path.lexists(path):
        read_regular(path, private=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), "unsafe controller lock")
        deadline = time.monotonic() + WAIT_SECONDS
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                require(time.monotonic() < deadline, "controller lock busy")
                time.sleep(0.1)
        yield
    finally:
        os.close(fd)


@contextlib.contextmanager
def dpkg_locks():
    """POSIX record locks, used only for our package-registration observations.

    Never hold either lock across child dpkg. Its normal frontend/database locks
    remain authoritative for installation, with bounded lock retries.
    """
    descriptors = []
    try:
        deadline = time.monotonic() + WAIT_SECONDS
        for name in ("lock-frontend", "lock"):
            path = DATABASE / name
            if os.path.lexists(path):
                read_regular(path)
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            descriptors.append(fd)
            while True:
                try:
                    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    require(time.monotonic() < deadline, "dpkg database/frontend busy")
                    time.sleep(0.1)
        yield
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def install(deb, config):
    # Wait using actual record locks, then release them before real dpkg acquires
    # its own locks. A competing writer winning that race makes dpkg fail closed.
    with dpkg_locks():
        pass
    run([config["dpkg"], "--install", deb], config, timeout=120)


def manifest(config):
    data = read_json(Path(config["runtime_manifest"]), limit=2 * 1024 * 1024)
    require(data.get("schema") == 1 and isinstance(data.get("exports"), dict)
            and isinstance(data.get("required_directories"), list), "invalid runtime manifest")
    for path, item in data["exports"].items():
        normalized(path)
        require(path.startswith("/usr/sbin/") or path in ("/usr/lib/systemd/system", "/bin/bash"),
                "runtime export outside provider slots")
        require(set(item) == {"target", "source", "native_wrapper"}
                and isinstance(item["target"], str) and type(item["native_wrapper"]) is bool,
                "invalid runtime export")
    return data


def exports_check(current, previous=None, fresh=False):
    """Accept only absent new slots or exact previously owned links."""
    expected = manifest(current)
    old = {} if fresh else manifest(previous)["exports"] if previous is not None else expected["exports"]
    for raw in expected["required_directories"]:
        path = normalized(raw)
        if path.exists():
            directory(path)
        else:
            require(not os.path.lexists(path), "foreign provider directory")
    for raw, entry in old.items():
        path = Path(raw)
        ancestors(path)
        info = path.lstat()
        require(stat.S_ISLNK(info.st_mode) and info.st_uid == 0,
                "foreign provider slot: " + raw)
        require(os.readlink(path) == entry["target"], "unknown provider export: " + raw)
    for raw in expected["exports"].keys() - old.keys():
        require(not os.path.lexists(raw), "foreign provider slot: " + raw)


def installed(config, package):
    status = run([config["dpkg_query"], "-W", "-f=${Status}", package], config)
    require(status == "install ok installed", "package not configured: " + package)


def protected_hardlinks_check():
    path = Path("/proc/sys/fs/protected_hardlinks")
    ancestors(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0
                and not info.st_mode & 0o022, "unsafe protected_hardlinks sysctl")
        value = os.read(fd, 16)
        require(len(value) < 16 and value.strip() == b"1", "protected_hardlinks must be 1")
    finally:
        os.close(fd)


def payload_check(config):
    try:
        vendor_uid = pwd.getpwnam("sentinelone").pw_uid
    except KeyError as error:
        raise Refusal("missing local sentinelone account") from error
    protected_hardlinks_check()
    data = Path(config["data_dir"])
    ancestors(data)
    directory(OPT.parent)
    link = OPT.lstat()
    require(stat.S_ISLNK(link.st_mode) and link.st_uid in (0, vendor_uid)
            and os.readlink(OPT) == str(data), "unexpected vendor /opt mapping")
    persistent_unit_check()
    # Pin only the structural path, never traverse payload contents or BPF mounts.
    # Root manages the namespace; the vendor UID may own these directories/link,
    # but the current unit must still be root-owned and protected from writes.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    data_fd = os.open(data, flags)
    try:
        info = os.fstat(data_fd)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid in (0, vendor_uid)
                and not info.st_mode & 0o022, "unsafe payload directory")
        device = info.st_dev
        config_fd = os.open("configuration", flags, dir_fd=data_fd)
        try:
            info = os.fstat(config_fd)
            require(stat.S_ISDIR(info.st_mode) and info.st_uid in (0, vendor_uid)
                    and not info.st_mode & 0o022, "unsafe vendor unit directory")
            require(info.st_dev == device, "configuration crosses payload filesystem")
            content = read_regular(Path("sentinelone.service"), check_parents=False,
                                   dir_fd=config_fd, device=device)
        finally:
            os.close(config_fd)
    finally:
        os.close(data_fd)
    owned = run([config["dpkg_query"], "-S",
                 "/opt/sentinelone/configuration/sentinelone.service"], config).strip()
    require(owned in (
        "sentinelagent: /opt/sentinelone/configuration/sentinelone.service",
        "sentinelagent:amd64: /opt/sentinelone/configuration/sentinelone.service"),
        "current vendor unit is not owned by sentinelagent")
    return content


def registration_check(content, config, mutate=False):
    # The runtime unit may have been created by the genuine vendor maintscript.
    if os.path.lexists(UNIT):
        require(read_regular(UNIT) == content, "conflicting current vendor unit")
    elif mutate:
        atomic(UNIT, content, mode=0o644)
    else:
        raise Refusal("current vendor unit is not registered")
    def escaped(value):
        return value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")

    text = ("[Service]\n" + "".join(
        'Environment="' + key + "=" + escaped(value) + '"\n'
        for key, value in runtime_environment(config).items()
    )).encode()
    if os.path.lexists(DROPIN):
        directory(DROPIN, private=True)
        require({p.name for p in DROPIN.iterdir()} <= {"50-native-runtime.conf"},
                "foreign sentinelone dropin")
    elif mutate:
        mkdir(DROPIN)
    else:
        raise Refusal("native runtime dropin missing")
    dropin = DROPIN / "50-native-runtime.conf"
    if os.path.lexists(dropin):
        require(read_regular(dropin, private=True) == text, "conflicting native environment")
    elif mutate:
        atomic(dropin, text)
    else:
        raise Refusal("native environment missing")


def active_config(state):
    roots_check(state)
    return load_config(Path(state["runtime_active"]), full=True)


def reconcile(config_path, config):
    store_path(str(config_path))
    require(read_regular(BOOT_CONFIG, private=True).decode().strip() == str(config_path),
            "reconciliation requires this boot's configuration; reboot required")
    require(not os.path.lexists(BOOT_MARK), "reconciliation already attempted this boot; reboot required")
    target = subprocess.run(
        [config["systemctl"], "is-active", "--quiet", "multi-user.target"],
        env=environment(config), stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
    require(target.returncode == 3, "boot reconciliation window closed; reboot required")
    state = preflight(config)
    fresh = state is None
    previous = None if fresh else active_config(state)
    exports_check(config, previous, fresh=fresh)
    mkdir(CONTROL)
    with controller_lock():
        require(not os.path.lexists(BOOT_MARK),
                "reconciliation already attempted this boot; reboot required")
        # Another invocation must not turn a fresh observation into adoption.
        if fresh:
            require({p.name for p in CONTROL.iterdir()} == {"controller.lock"},
                    "native state changed while waiting")
        else:
            require(state_read() == state, "native state changed while waiting")
        # Boot marker
        atomic(BOOT_MARK, b"boot reconciliation attempted\n")
        if fresh:
            # Read only metadata from the original DEB; never patched output.
            fields = run([config["dpkg_deb"], "-f", config["bootstrap_deb"],
                          "Package", "Version", "Architecture"], config)
            metadata = dict(line.split(": ", 1) for line in fields.splitlines())
            require(metadata.get("Package") == "sentinelagent"
                    and metadata.get("Architecture") == "amd64", "unsupported bootstrap DEB")
            with open(config["bootstrap_deb"], "rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            state = {
                "schema": 1, "mode": "vendor-managed", "data_dir": config["data_dir"],
                "phase": "pending", "runtime_active": None,
                "runtime_pending": str(config_path),
                "seed": {"deb": config["bootstrap_deb"], "sha256": digest,
                         "version": metadata["Version"]},
            }
        else:
            state = dict(state, phase="pending", runtime_pending=str(config_path))
        # Prepare genuine pins before publishing package intent. Any partial
        # preparation is retained as unknown state, never adopted on another boot.
        mkdir(ROOTS)
        old_roots = {} if fresh else {"active": state["runtime_active"]}
        roots_layout(old_roots)
        guard_target = str(config_path) if fresh else state["runtime_active"]
        pin("pending", str(config_path), config)
        pin("transaction", guard_target, config)
        # Persist and fsync before any payload/provider/database mutation.
        save(state)
        mkdir(DATABASE)
        # Locks protect registration observations only. Child dpkg owns its locks.
        with dpkg_locks():
            if not fresh:
                installed(previous, "sentinelone-nix-runtime")
                installed(previous, "sentinelagent")
        for raw in manifest(config)["required_directories"]:
            mkdir(normalized(raw), mode=0o755)
        install(config["runtime_deb"], config)
        with dpkg_locks():
            installed(config, "sentinelone-nix-runtime")
            exports_check(config)
        if fresh:
            mkdir(OPT.parent, mode=0o755)
            install(config["bootstrap_deb"], config)
        with dpkg_locks():
            installed(config, "sentinelagent")
            content = payload_check(config)
            registration_check(content, config, mutate=True)
        run([config["systemctl"], "daemon-reload"], config)
        run([config["systemctl"], "--runtime", "enable", "sentinelone.service"], config)
        # No synchronous start: vendor units may order themselves after multi-user
        # or this initializer. All validation/mutation is complete before queuing.
        roots_layout(dict(old_roots, pending=str(config_path), transaction=guard_target))
        os.replace(ROOTS / "pending", ROOTS / "active")
        roots_layout({"active": str(config_path), "transaction": guard_target})
        sync_directory(ROOTS)
        state = dict(state, phase="ready", runtime_active=str(config_path), runtime_pending=None)
        save(state)
        run([config["systemctl"], "--no-block", "start", "sentinelone.service"], config)
    # Retain the guard through lock release, including a failed close. This is
    # the final fallible operation: do not fsync after unlink. A crash may leave
    # an obsolete guard (which preflight refuses), never an unrooted runtime.
    roots_layout({"active": str(config_path), "transaction": guard_target})
    (ROOTS / "transaction").unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "reconcile", "status", "exec"))
    parser.add_argument("config", type=Path)
    args = parser.parse_args(sys.argv[1:3])
    desired_system = None
    if args.command == "exec":
        require(len(sys.argv) >= 4 and sys.argv[3] == "--", "exec requires -- ARGS")
    elif args.command == "preflight" and len(sys.argv) != 3:
        require(len(sys.argv) == 5 and sys.argv[3] == "--system",
                "preflight requires optional --system NEW_SYSTEM")
        desired_system = sys.argv[4]
        require(normalized(desired_system).is_relative_to("/nix/store"),
                "desired system is not store-backed")
    else:
        require(len(sys.argv) == 3, "unexpected controller arguments")
    require(os.geteuid() == 0, "root privileges required")
    config = load_config(args.config, full=args.command == "reconcile")
    if args.command == "preflight":
        preflight(config, desired_system)
    elif args.command == "reconcile":
        reconcile(args.config, config)
    elif args.command == "status":
        state = state_read()
        print(json.dumps({"mode": "vendor-managed" if state else "uninitialized",
                          "phase": state["phase"] if state else None,
                          "data_dir": state["data_dir"] if state else config["data_dir"],
                          "runtime_active": state["runtime_active"] if state else None}))
    else:
            state = preflight(config)
            if state is None:
                raise Refusal("native installation is not initialized")
            # A new generation
            # and provider must never be mixed with the still-active installation.
            current = active_config(state)
            require(current["data_dir"] == state["data_dir"], "active config mapping mismatch")
            exports_check(current)
            with dpkg_locks():
                installed(current, "sentinelagent")
                payload_check(current)
            os.execve("/opt/sentinelone/bin/sentinelctl",
                      ["sentinelctl", *sys.argv[4:]], environment(current))


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("sentinelone-native: " + str(error), file=sys.stderr)
        sys.exit(1)
