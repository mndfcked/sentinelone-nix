"""Initialize store-managed state. No vendor updater or enrollment verification."""

import base64
import binascii
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile


MARKER = ".sentinelone-bootstrap.json"
COMPONENTS = {"bin", "ebpfs", "ranger"}
CREDENTIALS = {"install_config", "basic.conf", "installation_params.json"}


class Refusal(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def runtime_path(value):
    require(
        isinstance(value, str)
        and value.startswith("/")
        and value not in {"/", "/nix/store"}
        and not any(ord(c) < 32 or ord(c) == 127 for c in value)
        and all(p not in {"", ".", ".."} for p in value.split("/")[1:])
        and not value.startswith("/nix/store/"),
        "use a canonical absolute runtime filename/directory outside the Nix store",
    )
    return Path(value)


def private_root(info, mode=None):
    return info.st_uid == 0 and not info.st_mode & 0o022 and (
        mode is None or stat.S_IMODE(info.st_mode) == mode
    )


def safe_ancestors(path):
    for ancestor in reversed([path, *path.parents]):
        info = ancestor.lstat()
        require(
            stat.S_ISDIR(info.st_mode) and private_root(info),
            "data directory ancestors must be real root-owned directories without group/other write access",
        )


def no_mounts(path):
    # mountinfo escapes spaces, tabs, newlines and backslashes as octal.
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        mount = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), line.split()[4])
        require(
            mount != str(path) and not mount.startswith(str(path) + "/"),
            "data directory contains a mount; unmount it before initialization",
        )


def object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "token/marker JSON contains duplicate keys")
        result[key] = value
    return result


def token_config(path):
    # Follow runtime secret-manager symlinks, but check the actual opened file
    # before consuming bytes. Nonblocking open also lets us reject FIFOs safely.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(
            stat.S_ISREG(info.st_mode) and not info.st_mode & 0o077,
            "management token source must be a private regular file with no group/other permissions; ask its owner to correct permissions",
        )
        raw = stream.read(1024 * 1024 + 1)
    require(len(raw) <= 1024 * 1024, "management token file is too large")
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    try:
        decoded = base64.b64decode(raw, validate=True)
        config = json.loads(decoded, object_pairs_hook=object_without_duplicates)
    except (ValueError, UnicodeError, binascii.Error):
        raise Refusal("management token must be single-line base64 containing one JSON object") from None
    require(isinstance(config, dict), "management token must decode to one JSON object")
    for key in ("url", "site_key"):
        value = config.get(key)
        require(
            isinstance(value, str)
            and bool(value.strip())
            and not any(ord(c) < 32 or ord(c) == 127 for c in value),
            "management token url and site_key must be nonempty strings without control characters",
        )
    return raw.decode("ascii"), config


def validate_seed(seed):
    for name in COMPONENTS | {"configuration", "lib"}:
        info = (seed / name).lstat()
        require(stat.S_ISDIR(info.st_mode), "package seed is missing required real directories")
    require(not (seed / MARKER).exists(), "package seed contains reserved bootstrap metadata")
    for parent, directories, files in os.walk(seed, followlinks=False):
        for name in directories + files:
            path = Path(parent) / name
            info = path.lstat()
            require(
                stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode),
                "package seed contains a special file",
            )
            if path.is_symlink():
                # Symlink mode bits are always 0777 on Linux; they do not grant
                # access to the target. Preserve legitimate package links.
                target = path.resolve(strict=True)
                require(str(target).startswith("/nix/store/"), "package seed symlink leaves the Nix store")
            else:
                require(not info.st_mode & 0o6022, "package seed has unsafe write or set-id permissions")
    for name in CREDENTIALS:
        path = seed / "configuration" / name
        require(not path.is_symlink(), "package seed credential filenames must not be symlinks")
        require(not path.exists() or path.is_file(), "package seed credential filenames must be files")


def write_private(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


def sync_tree(path):
    for parent, directories, files in os.walk(path):
        for name in files:
            item = Path(parent) / name
            if not item.is_symlink():
                with item.open("rb") as stream:
                    os.fsync(stream.fileno())
        sync_directory(Path(parent))


def sync_directory(path):
    fd = os.open(path, os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def known_state(destination, package):
    marker = destination / MARKER
    require(marker.exists(), "existing nonempty state has no bootstrap marker; preserve it for operator review (no automatic migration or re-enrollment)")
    info = marker.lstat()
    require(
        stat.S_ISREG(info.st_mode) and private_root(info, 0o600) and info.st_nlink == 1,
        "bootstrap marker must be a root-owned private regular file; preserve state for operator review",
    )
    try:
        value = json.loads(marker.read_text(), object_pairs_hook=object_without_duplicates)
    except (ValueError, UnicodeError):
        raise Refusal("malformed bootstrap marker; preserve state for operator review") from None
    require(
        isinstance(value, dict) and set(value) == {"schema", "package"}
        and type(value["schema"]) is int and value["schema"] == 1
        and isinstance(value["package"], str),
        "unknown bootstrap marker schema; preserve state for operator review",
    )
    require(value["package"] == package, "store-managed package mismatch; preserve state and request an explicit operator upgrade plan")


def initialize(config):
    require(os.geteuid() == 0, "initialization requires root")
    os.umask(0o077)
    destination = runtime_path(config["data_dir"])
    token_path = runtime_path(config["token_path"])
    package = config["package"]
    seed = Path(package) / "opt/sentinelone"
    customer = config["customer_id"]
    require(customer is None or not any(ord(c) < 32 or ord(c) == 127 for c in customer), "customer ID must not contain control characters")
    safe_ancestors(destination.parent)
    no_mounts(destination)
    if destination.exists() or destination.is_symlink():
        safe_ancestors(destination)
    prefix = "." + destination.name + ".bootstrap-"
    require(not any(p.name.startswith(prefix) for p in destination.parent.iterdir()), "interrupted bootstrap staging exists; preserve it for operator review (no automatic cleanup)")
    token = decoded = None
    if destination.exists() and any(destination.iterdir()):
        known_state(destination, package)
    else:
        # Even the persistent lock is created only after input validation.
        validate_seed(seed)
        token, decoded = token_config(token_path)
    lock_path = destination.parent / ("." + destination.name + ".bootstrap.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, "r+") as lock:
        info = os.fstat(lock.fileno())
        require(stat.S_ISREG(info.st_mode) and private_root(info, 0o600) and info.st_nlink == 1, "bootstrap lock must be a root-owned private regular file")
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Recheck after the serialized lock, before inspecting or changing state.
        safe_ancestors(destination.parent)
        no_mounts(destination)
        require(not any(p.name.startswith(prefix) for p in destination.parent.iterdir()), "interrupted bootstrap staging exists; preserve it for operator review (no automatic cleanup)")
        original = None
        if destination.exists() or destination.is_symlink():
            safe_ancestors(destination)
            original = destination.stat()
            if any(destination.iterdir()):
                known_state(destination, package)
                return
        if token is None or decoded is None:
            raise Refusal("data directory changed during initialization; retry after operator review")
        stage = Path(tempfile.mkdtemp(prefix=prefix, dir=destination.parent))
        stage_info = stage.stat()
        try:
            for source in seed.iterdir():
                if source.name in COMPONENTS:
                    (stage / source.name).mkdir(mode=0o755)
                elif source.is_dir() and not source.is_symlink():
                    shutil.copytree(source, stage / source.name, symlinks=True)
                else:
                    shutil.copy2(source, stage / source.name, follow_symlinks=False)
            lines = ["S1_AGENT_MANAGEMENT_TOKEN=" + token, "S1_AGENT_DEVICE_TYPE=desktop", "S1_AGENT_AUTO_START=true"]
            if customer is not None:
                lines.append("S1_AGENT_CUSTOMER_ID=" + customer)
            write_private(stage / "configuration/install_config", "\n".join(lines) + "\n")
            write_private(stage / "configuration/installation_params.json", json.dumps({"PACKAGE_TYPE": "deb", "SERVICE_TYPE": "systemd"}) + "\n")
            write_private(stage / "configuration/basic.conf", json.dumps({"mgmt_device-type": 1, "mgmt_site-key": decoded["site_key"], "mgmt_url": decoded["url"]}) + "\n")
            sync_tree(stage)
            write_private(stage / MARKER, json.dumps({"schema": 1, "package": package}) + "\n")
            sync_directory(stage)
            no_mounts(destination)
            if original is None:
                require(not destination.exists() and not destination.is_symlink(), "data directory changed during initialization")
            else:
                current = destination.lstat()
                require(current.st_ino == original.st_ino and current.st_dev == original.st_dev and not any(destination.iterdir()), "data directory changed during initialization")
            os.rename(stage, destination)
            sync_directory(destination.parent)
        finally:
            # Only the private directory created by this invocation is eligible.
            if stage.exists():
                current = stage.lstat()
                require(current.st_ino == stage_info.st_ino and current.st_dev == stage_info.st_dev and private_root(current, 0o700), "staging identity changed; preserve it for operator review")
                no_mounts(stage)
                shutil.rmtree(stage)


def main():
    try:
        initialize(json.loads(Path(sys.argv[1]).read_text()))
    except Refusal as error:
        print("sentinelone bootstrap refused: " + str(error), file=sys.stderr)
        return 1
    except Exception as error:
        # Avoid JSON parser contents, token bytes, or secret-bearing tracebacks.
        print("sentinelone bootstrap failed (" + type(error).__name__ + "); preserve existing state and check runtime input files/package seed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
