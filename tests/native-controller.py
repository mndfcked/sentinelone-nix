"""Hermetic controller fault tests, not proof of genuine Nix GC registration.

The synthetic VM covers real nix-store/dpkg/systemd. Here only subprocesses,
store-file reads and host ownership/ancestors are substituted. Controller state,
atomic publication, root layouts and failure/refusal behavior use real files.
"""
import contextlib
import importlib.util
import json
import os
import pwd
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).parents[1] / "native-controller.py"
spec = importlib.util.spec_from_file_location("native_controller", SOURCE)
assert spec is not None and spec.loader is not None
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)

OLD = "/nix/store/old-config"
NEW = "/nix/store/new-config"
SEED = "/nix/store/seed.deb"


class Injected(OSError):
    pass


class Fixture:
    def __init__(self, fresh=False, fault=None, same_config=False):
        self.stack = contextlib.ExitStack()
        try:
            self.setup(fresh, fault, same_config)
        except BaseException:
            self.stack.close()
            raise

    def setup(self, fresh, fault, same_config):
        self.fresh = fresh
        self.fault = fault
        self.hit = False
        self.events = []
        self.owners = {}
        self.vendor_uid = 998
        self.stack.enter_context(patch.object(pwd, "getpwnam", return_value=pwd.struct_passwd(
            ("sentinelone", "x", self.vendor_uid, 997, "", "/opt/sentinelone/home", "/bin/false"))))
        self.base = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.control = self.base / "control"
        self.roots = self.base / "roots"
        self.data = self.base / "payload"
        self.config_path = Path(OLD if same_config else NEW)
        self.config = {
            "schema": 1, "enabled": True, "native": True,
            "data_dir": str(self.data), "bootstrap_deb": SEED,
            "runtime": "/nix/store/runtime", "runtime_deb": "/nix/store/provider.deb",
            "runtime_manifest": str(self.base / "manifest"),
            "path": "/usr/sbin:/usr/bin:/bin", "loader": "/nix/store/loader/lib/ld.so",
            "library_path": "/opt/sentinelone/lib:/nix/store/libs/lib",
            **{name: "/nix/store/tools/bin/" + name for name in
               ("dpkg", "dpkg_query", "dpkg_deb", "systemctl", "nix_store")},
        }
        self.seed = {"deb": SEED, "sha256": "0" * 64, "version": "1"}
        self.state = {
            "schema": 1, "mode": "vendor-managed", "data_dir": str(self.data),
            "phase": "ready", "runtime_active": OLD, "runtime_pending": None,
            "seed": self.seed,
        }
        self.paths = {
            "CONTROL": self.control, "STATE": self.control / "state.json",
            "DATABASE": self.control / "dpkg", "ROOTS": self.roots,
            "OPT": self.base / "opt", "UNIT": self.base / "sentinelone.service",
            "DROPIN": self.base / "sentinelone.service.d",
            "PERSISTENT_UNIT": self.base / "persistent.service",
            "PERSISTENT_DROPIN": self.base / "persistent.service.d",
            "BOOT_CONFIG": self.base / "boot-config", "BOOT_MARK": self.base / "boot-marker",
        }
        for name, value in self.paths.items():
            self.stack.enter_context(patch.object(controller, name, value, create=True))
        self.stack.enter_context(patch.object(controller, "ancestors", lambda path: None))
        def root_owned(original):
            def observe(*args, **kwargs):
                info = original(*args, **kwargs)
                fields = list(info)
                fields[4:6] = [self.owners.get(info.st_ino, 0), 0]
                return os.stat_result(fields, {name: getattr(info, name) for name in
                                             ("st_atime_ns", "st_mtime_ns", "st_ctime_ns")})
            return observe

        for name in ("stat", "lstat", "fstat"):
            self.stack.enter_context(patch.object(os, name, root_owned(getattr(os, name))))
        original_read = controller.read_regular

        def read(path, *args, **kwargs):
            if str(path) in (OLD, NEW):
                return json.dumps(self.config).encode()
            return original_read(path, *args, **kwargs)

        self.stack.enter_context(patch.object(controller, "read_regular", read))
        self.hardlinks = self.base / "protected-hardlinks"
        self.hardlinks.write_bytes(b"1\n")
        original_os_open = os.open

        def os_open(path, *args, **kwargs):
            if str(path) == "/proc/sys/fs/protected_hardlinks":
                path = self.hardlinks
            return original_os_open(path, *args, **kwargs)

        self.stack.enter_context(patch.object(os, "open", os_open))
        seed_file = self.base / "seed.deb"
        seed_file.write_bytes(b"synthetic metadata input")
        original_open = open
        self.stack.enter_context(patch.object(
            controller, "open", lambda path, *a, **kw:
            original_open(seed_file if str(path) == SEED else path, *a, **kw), create=True))
        self.stack.enter_context(patch.object(subprocess, "run", self.command))
        self.paths["BOOT_CONFIG"].write_text(str(self.config_path) + "\n")
        self.paths["BOOT_CONFIG"].chmod(0o600)
        (self.base / "manifest").write_text(json.dumps(
            {"schema": 1, "exports": {}, "required_directories": []}))
        if not fresh:
            self.control.mkdir(mode=0o700)
            self.paths["DATABASE"].mkdir(mode=0o700)
            self.roots.mkdir(mode=0o700)
            (self.roots / "active").symlink_to(OLD)
            (self.control / "controller.lock").touch(mode=0o600)
            controller.save(self.state)
            self.payload()
            controller.registration_check(b"[Service]\n", self.config, mutate=True)
        self.events.clear()
        original_replace = os.replace

        def replace(source, target):
            promoting = Path(source) == self.roots / "pending"
            publishing = Path(target) == self.paths["STATE"]
            ready = publishing and json.loads(Path(source).read_bytes())["phase"] == "ready"
            kind = "rename" if promoting else "ready" if ready else "pending" if publishing else None
            if kind:
                self.trip(kind + "-before-replace")
            original_replace(source, target)
            if kind:
                self.events.append(kind + "-replaced")
                self.trip(kind + "-after-replace")

        self.stack.enter_context(patch.object(os, "replace", replace))
        original_sync = controller.sync_directory

        def sync(path):
            assert "cleanup" not in self.events, "fallible fsync after guard removal"
            if path == self.roots and "rename-replaced" not in self.events:
                if "pin-transaction" in self.events:
                    self.trip("transaction-fsync")
                elif "pin-pending" in self.events:
                    self.trip("pending-pin-fsync")
            if path == self.roots and "rename-replaced" in self.events:
                self.trip("promoted-fsync")
            if path == self.control and "ready-replaced" in self.events:
                self.trip("ready-fsync")
            if path == self.control and "pending-replaced" in self.events:
                self.trip("pending-fsync")
            original_sync(path)
            if path == self.control and "ready-replaced" in self.events:
                self.trip("ready-after-fsync")

        self.stack.enter_context(patch.object(controller, "sync_directory", sync))
        original_check = controller.root_check

        def check(name, target):
            if "pin-" + name in self.events and "pending-replaced" not in self.events:
                self.trip(name + "-validation")
            if "rename-replaced" in self.events:
                self.trip("post-rename-validation")
            original_check(name, target)

        self.stack.enter_context(patch.object(controller, "root_check", check))
        original_unlink = Path.unlink

        def unlink(path, *args, **kwargs):
            if path == self.roots / "transaction":
                self.events.append("cleanup")
                self.trip("cleanup-unlink")
            return original_unlink(path, *args, **kwargs)

        self.stack.enter_context(patch.object(Path, "unlink", unlink))
        original_lock = controller.controller_lock

        @contextlib.contextmanager
        def lock():
            with original_lock():
                if fault == "marker-race":
                    self.paths["BOOT_MARK"].write_bytes(b"other attempt\n")
                yield
                self.trip("lock-exit")
            self.events.append("lock-released")

        self.stack.enter_context(patch.object(controller, "controller_lock", lock))

    def close(self):
        self.stack.close()

    def trip(self, point):
        if self.fault == point:
            self.hit = True
            raise Injected(point)

    def payload(self):
        self.data.mkdir(exist_ok=True)
        unit = self.data / "configuration"
        unit.mkdir(exist_ok=True)
        (unit / "sentinelone.service").write_bytes(b"[Service]\n")
        if not os.path.lexists(self.paths["OPT"]):
            self.paths["OPT"].symlink_to(self.data)

    def targets(self):
        return {os.readlink(p) for p in self.roots.iterdir() if p.is_symlink()} if self.roots.exists() else set()

    def command(self, argv, **kwargs):
        output = b""
        code = 0
        if argv[1:] == ["is-active", "--quiet", "multi-user.target"]:
            code = 3
        elif argv[0] == self.config["nix_store"]:
            target, root = argv[2], Path(argv[4])
            assert argv[1] == "--realise" and argv[3] == "--add-root"
            self.events.append("pin-" + root.name)
            self.trip(root.name + "-before-link")
            root.symlink_to(target)
            self.trip(root.name + "-after-link")
        elif argv[0] == self.config["dpkg_deb"]:
            output = b"Package: sentinelagent\nVersion: 1\nArchitecture: amd64\n"
        elif argv[0] == self.config["dpkg"]:
            self.events.append("package")
            pending = json.loads(self.paths["STATE"].read_bytes())
            assert pending["phase"] == "pending"
            assert str(self.config_path) in self.targets(), "package mutation without new root"
            assert (self.roots / "transaction").is_symlink(), "package mutation without guard"
            if argv[-1] == SEED:
                self.events.append("seed")
                self.payload()
        elif argv[0] == self.config["dpkg_query"]:
            output = (b"install ok installed" if argv[1] == "-W" else
                      b"sentinelagent: /opt/sentinelone/configuration/sentinelone.service")
        elif argv[1:] == ["--no-block", "start", "sentinelone.service"]:
            self.events.append("queue")
            assert (self.roots / "transaction").is_symlink(), "queue without guard"
            self.trip("queue")
        return subprocess.CompletedProcess(argv, code, output, b"")

    def desired_tree(self):
        # Substitute only the store filesystem boundary. No host store writes.
        store = self.base / "store"
        system = store / "test-system"
        units = store / "test-units"
        units.mkdir(parents=True)
        (system / "etc/systemd").mkdir(parents=True)
        (system / "etc/systemd/system").symlink_to(units)
        original_resolve, original_lstat = Path.resolve, Path.lstat

        def mapped(path):
            return store / path.relative_to("/nix/store") if path.is_relative_to("/nix/store") else path

        def resolve(path, *args, **kwargs):
            result = original_resolve(mapped(path), *args, **kwargs)
            return Path("/nix/store") / result.relative_to(store) if result.is_relative_to(store) else result

        self.stack.enter_context(patch.object(Path, "resolve", resolve))
        self.stack.enter_context(patch.object(
            Path, "lstat", lambda path, *a, **kw: original_lstat(mapped(path), *a, **kw)))
        return "/nix/store/test-system", system, units

    def reconcile(self):
        controller.reconcile(self.config_path, self.config)

    def snapshot(self):
        return {str(p.relative_to(self.base)):
                (p.lstat().st_mode, os.readlink(p) if p.is_symlink() else p.read_bytes() if p.is_file() else None)
                for p in self.base.rglob("*")}


class PayloadTests(unittest.TestCase):
    def fixture(self):
        fixture = Fixture()
        self.addCleanup(fixture.close)
        return fixture

    def test_root_owned_structure_remains_valid(self):
        fixture = self.fixture()
        self.assertEqual(b"[Service]\n", controller.payload_check(fixture.config))

    def test_vendor_owned_opt_link_is_valid_without_reownership(self):
        fixture = self.fixture()
        link = fixture.paths["OPT"]
        fixture.owners[link.lstat().st_ino] = fixture.vendor_uid
        before = link.lstat()
        self.assertEqual(b"[Service]\n", controller.payload_check(fixture.config))
        after = link.lstat()
        self.assertEqual((before.st_uid, before.st_mode, before.st_ctime_ns),
                         (after.st_uid, after.st_mode, after.st_ctime_ns))

    def test_vendor_owned_sticky_configuration_is_valid(self):
        fixture = self.fixture()
        parent = fixture.data / "configuration"
        fixture.owners[parent.stat().st_ino] = fixture.vendor_uid
        parent.chmod(0o1700)
        fixture.owners[fixture.data.stat().st_ino] = fixture.vendor_uid
        self.assertEqual(b"[Service]\n", controller.payload_check(fixture.config))

    def test_unsafe_payload_structure_is_refused(self):
        cases = [
            ("opt", "owner"), ("opt", "target"), ("opt-parent", "mode"),
            ("data", "owner"), ("data", "group-write"), ("data", "other-write"),
            ("data", "symlink"),
            ("configuration", "owner"), ("configuration", "group-write"),
            ("configuration", "other-write"), ("configuration", "symlink"),
            ("unit", "owner"), ("unit", "vendor-owner"), ("unit", "group-write"),
            ("unit", "other-write"), ("unit", "symlink"), ("unit", "oversized"),
            ("unit", "fifo"),
        ]
        for entry, kind in cases:
            with self.subTest(entry=entry, kind=kind):
                fixture = Fixture()
                try:
                    parent = fixture.data / "configuration"
                    unit = parent / "sentinelone.service"
                    path = {"opt": fixture.paths["OPT"], "opt-parent": fixture.paths["OPT"].parent,
                            "data": fixture.data, "configuration": parent, "unit": unit}[entry]
                    if kind in ("owner", "vendor-owner"):
                        fixture.owners[path.lstat().st_ino] = (fixture.vendor_uid if kind == "vendor-owner"
                                                              else fixture.vendor_uid + 1)
                    elif kind == "target":
                        path.unlink()
                        path.symlink_to(str(fixture.data) + "/")
                    elif kind == "symlink":
                        moved = path.with_name(path.name + "-moved")
                        path.rename(moved)
                        path.symlink_to(moved)
                    elif kind == "oversized":
                        path.write_bytes(b"x" * 65537)
                    elif kind == "fifo":
                        path.unlink()
                        os.mkfifo(path)
                    else:
                        path.chmod(path.stat().st_mode | (0o020 if kind == "group-write" else 0o002))
                    before = fixture.snapshot() if kind != "fifo" else None
                    with self.assertRaises((controller.Refusal, OSError)):
                        controller.payload_check(fixture.config)
                    if before is not None:
                        self.assertEqual(before, fixture.snapshot())
                finally:
                    fixture.close()

    def test_local_vendor_account_is_required(self):
        fixture = self.fixture()
        with (
            patch.object(pwd, "getpwnam", side_effect=KeyError("sentinelone")),
            self.assertRaises(controller.Refusal),
        ):
            controller.payload_check(fixture.config)

    def test_protected_hardlinks_is_required(self):
        fixture = self.fixture()
        for value in (b"0\n", b"2\n", b"", b"1 extra\n", b"1" + b" " * 32):
            with self.subTest(value=value):
                fixture.hardlinks.write_bytes(value)
                with self.assertRaises(controller.Refusal):
                    controller.payload_check(fixture.config)

    def test_only_subordinate_structural_filesystem_crossings_are_refused(self):
        fixture = self.fixture()
        paths = [fixture.data, fixture.data / "configuration",
                 fixture.data / "configuration/sentinelone.service"]
        inodes = [path.stat().st_ino for path in paths]
        original_fstat = os.fstat
        for crossing in ("configuration", "unit", "whole-data-mount"):
            with self.subTest(crossing=crossing):
                changed = set(inodes if crossing == "whole-data-mount" else
                              [inodes[1 if crossing == "configuration" else 2]])

                def fstat(fd, changed=changed):
                    info = original_fstat(fd)
                    if info.st_ino not in changed:
                        return info
                    fields = list(info)
                    fields[2] += 1
                    return os.stat_result(fields, {name: getattr(info, name) for name in
                                                 ("st_atime_ns", "st_mtime_ns", "st_ctime_ns")})

                with patch.object(os, "fstat", fstat):
                    if crossing == "whole-data-mount":
                        self.assertEqual(b"[Service]\n", controller.payload_check(fixture.config))
                    else:
                        with self.assertRaises(controller.Refusal):
                            controller.payload_check(fixture.config)

    def test_replaced_parent_cannot_redirect_read_to_another_root_owned_unit(self):
        fixture = self.fixture()
        parent = fixture.data / "configuration"
        replacement = fixture.base / "unrelated-root-unit"
        replacement.mkdir()
        (replacement / "sentinelone.service").write_bytes(b"[Service]\nExecStart=/malicious\n")
        original_open = os.open
        descriptors = []
        swapped = False

        def os_open(path, *args, **kwargs):
            nonlocal swapped
            if Path(path).name == "sentinelone.service":
                parent.rename(fixture.data / "pinned-configuration")
                parent.symlink_to(replacement)
                swapped = True
            fd = original_open(path, *args, **kwargs)
            descriptors.append(fd)
            return fd

        with patch.object(os, "open", os_open):
            content = controller.payload_check(fixture.config)
        self.assertTrue(swapped, "replacement race never reached")
        self.assertEqual(b"[Service]\n", content)
        for fd in descriptors:
            with self.assertRaises(OSError):
                os.fstat(fd)

    def test_concurrent_same_size_unit_mutation_is_refused(self):
        fixture = self.fixture()
        unit = fixture.data / "configuration/sentinelone.service"
        info = unit.stat()
        original_read = os.read
        mutated = False

        def read(fd, size):
            nonlocal mutated
            content = original_read(fd, size)
            if os.fstat(fd).st_ino == info.st_ino:
                unit.write_bytes(b"[Socket] \n")
                os.utime(unit, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000_000))
                mutated = True
            return content

        with patch.object(os, "read", read), self.assertRaises(controller.Refusal):
            controller.payload_check(fixture.config)
        self.assertTrue(mutated, "read mutation never reached")

    def test_unit_size_bound_includes_65536_bytes(self):
        fixture = self.fixture()
        content = b"x" * 65536
        (fixture.data / "configuration/sentinelone.service").write_bytes(content)
        self.assertEqual(content, controller.payload_check(fixture.config))


class Transactions(unittest.TestCase):
    def fixture(self, **kwargs):
        fixture = Fixture(**kwargs)
        self.addCleanup(fixture.close)
        return fixture

    def test_faults_preserve_roots_and_refuse_without_repair(self):
        faults = [
            "pending-before-link", "pending-after-link", "pending-validation", "pending-pin-fsync",
            "transaction-before-link", "transaction-after-link", "transaction-validation", "transaction-fsync",
            "pending-before-replace", "pending-after-replace", "pending-fsync",
            "rename-before-replace", "rename-after-replace",
            "post-rename-validation", "promoted-fsync",
            "ready-before-replace", "ready-after-replace", "ready-fsync", "ready-after-fsync",
            "queue", "lock-exit", "cleanup-unlink",
        ]
        for fresh in (False, True):
            for fault in faults:
                with self.subTest(fresh=fresh, fault=fault):
                    fixture = Fixture(fresh=fresh, fault=fault)
                    try:
                        with self.assertRaises(Injected):
                            fixture.reconcile()
                        self.assertTrue(fixture.hit, "fault never reached")
                        targets = fixture.targets()
                        if not fresh:
                            self.assertIn(OLD, targets)
                        if fault != "pending-before-link":
                            self.assertIn(NEW, targets)
                        else:
                            self.assertNotIn(NEW, targets)
                        if fault in ("pending-before-link", "pending-after-link", "pending-validation",
                                     "pending-pin-fsync", "transaction-before-link",
                                     "transaction-after-link", "transaction-validation", "transaction-fsync"):
                            self.assertNotIn("package", fixture.events)
                            self.assertEqual(None if fresh else fixture.state,
                                             controller.state_read() if not fresh else
                                             json.loads(fixture.paths["STATE"].read_bytes())
                                             if fixture.paths["STATE"].exists() else None)
                        if not fresh:
                            self.assertNotIn("seed", fixture.events)
                        before = fixture.snapshot()
                        if not fresh and fault == "pending-before-link":
                            # No pin or intent was published, so the unchanged old
                            # installation is still valid. No new runtime is claimed.
                            self.assertEqual(fixture.state, controller.preflight(fixture.config))
                        else:
                            with self.assertRaises(controller.Refusal):
                                controller.preflight(fixture.config)
                        self.assertEqual(before, fixture.snapshot())
                    finally:
                        fixture.close()

    def test_success_and_leftover_cleanup_guard(self):
        for fresh in (False, True):
            with self.subTest(fresh=fresh):
                fixture = Fixture(fresh=fresh)
                try:
                    fixture.reconcile()
                    self.assertEqual({"active"}, {p.name for p in fixture.roots.iterdir()})
                    self.assertEqual({NEW}, fixture.targets())
                    self.assertEqual("ready", controller.preflight(fixture.config)["phase"])
                    self.assertEqual(1 if fresh else 0, fixture.events.count("seed"))
                    self.assertLess(fixture.events.index("lock-released"), fixture.events.index("cleanup"))
                    self.assertEqual("cleanup", fixture.events[-1])
                    # Simulate a crash resurrecting the deliberately non-fsynced cleanup.
                    (fixture.roots / "transaction").symlink_to(NEW if fresh else OLD)
                    before = fixture.snapshot()
                    with self.assertRaises(controller.Refusal):
                        controller.preflight(fixture.config)
                    self.assertEqual(before, fixture.snapshot())
                finally:
                    fixture.close()

    def test_persistent_systemd_conflicts_refuse_without_mutation(self):
        for fresh in (False, True):
            for kind in ("unit", "empty-dropin", "foreign-dropin", "dangling-dropin"):
                with self.subTest(fresh=fresh, kind=kind):
                    fixture = Fixture(fresh=fresh)
                    try:
                        dropin = fixture.paths["PERSISTENT_DROPIN"]
                        if kind == "unit":
                            fixture.paths["PERSISTENT_UNIT"].symlink_to("/missing")
                        elif kind == "dangling-dropin":
                            dropin.symlink_to("/missing")
                        else:
                            dropin.mkdir()
                            if kind == "foreign-dropin":
                                (dropin / "99-foreign.conf").write_text(
                                    "[Service]\nEnvironment=DPKG_ADMINDIR=/foreign\n")
                        before = fixture.snapshot()
                        with self.assertRaises(controller.Refusal):
                            controller.preflight(fixture.config)
                        with self.assertRaises(controller.Refusal):
                            fixture.reconcile()
                        if not fresh:
                            with self.assertRaises(controller.Refusal):
                                controller.payload_check(fixture.config)
                        self.assertEqual(before, fixture.snapshot())
                        self.assertEqual([], fixture.events)
                    finally:
                        fixture.close()

    def test_native_config_and_persisted_payload_cannot_overlap_control_or_roots(self):
        fixture = self.fixture()
        path = fixture.base / "candidate.json"
        for reserved in (fixture.control, fixture.roots):
            for data in (reserved, reserved.parent, reserved / "payload"):
                with self.subTest(data=data):
                    config = dict(fixture.config, data_dir=str(data))
                    path.write_text(json.dumps(config))
                    before = fixture.snapshot()
                    with self.assertRaises(controller.Refusal):
                        controller.load_config(path)
                    self.assertEqual(before, fixture.snapshot())
                    controller.save(dict(fixture.state, data_dir=str(data)))
                    before = fixture.snapshot()
                    with self.assertRaises(controller.Refusal):
                        controller.preflight(config)
                    self.assertEqual(before, fixture.snapshot())
                    controller.save(fixture.state)
            neighbor = str(reserved) + "-other"
            path.write_text(json.dumps(dict(fixture.config, data_dir=neighbor)))
            self.assertEqual(neighbor, controller.load_config(path)["data_dir"])
            controller.save(dict(fixture.state, data_dir=neighbor))
            self.assertEqual(neighbor, controller.state_read()["data_dir"])
            controller.save(fixture.state)
        # GC-root exclusion is native-only; do not change legacy path behavior.
        path.write_text(json.dumps(dict(fixture.config, native=False, data_dir=str(fixture.roots))))
        self.assertEqual(str(fixture.roots), controller.load_config(path)["data_dir"])

    def test_desired_system_conflicts_and_inspection_errors_refuse_read_only(self):
        for fresh in (False, True):
            for kind in ("unit", "empty-dropin", "foreign-dropin", "dangling-dropin",
                         "missing-tree", "outside-tree", "missing-system", "outside-system",
                         "unsafe-tree", "nondirectory-tree", "permission", "loop", "io-error"):
                with self.subTest(fresh=fresh, kind=kind):
                    fixture = Fixture(fresh=fresh)
                    try:
                        desired, system, units = fixture.desired_tree()
                        tree_link = system / "etc/systemd/system"
                        if kind == "unit":
                            (units / "sentinelone.service").symlink_to("/dev/null")
                        elif kind == "dangling-dropin":
                            (units / "sentinelone.service.d").symlink_to("/missing")
                        elif kind in ("empty-dropin", "foreign-dropin"):
                            dropin = units / "sentinelone.service.d"
                            dropin.mkdir()
                            if kind == "foreign-dropin":
                                (dropin / "99-foreign.conf").write_text(
                                    "[Service]\nEnvironment=DPKG_ADMINDIR=/foreign\n")
                        elif kind in ("missing-tree", "outside-tree"):
                            tree_link.unlink()
                            if kind == "outside-tree":
                                tree_link.symlink_to(fixture.base)
                        elif kind == "unsafe-tree":
                            units.chmod(0o777)
                        elif kind == "nondirectory-tree":
                            tree_link.unlink()
                            file = system.parent / "not-a-directory"
                            file.write_text("not a unit tree")
                            tree_link.symlink_to(file)
                        elif kind == "missing-system":
                            desired = "/nix/store/missing-system"
                        elif kind == "outside-system":
                            alias = system.parent / "outside"
                            alias.symlink_to(fixture.base)
                            desired = "/nix/store/outside"
                        elif kind in ("permission", "loop", "io-error"):
                            original_lstat = Path.lstat
                            error = {"permission": PermissionError(13, "denied"),
                                     "loop": OSError(40, "loop"),
                                     "io-error": OSError(5, "I/O error")}[kind]

                            def lstat(path, *args, **kwargs):
                                if path == Path("/nix/store/test-units/sentinelone.service"):
                                    raise error
                                return original_lstat(path, *args, **kwargs)

                            fixture.stack.enter_context(patch.object(Path, "lstat", lstat))
                        before = fixture.snapshot()
                        with self.assertRaises((controller.Refusal, OSError, RuntimeError)):
                            controller.preflight(fixture.config, desired)
                        self.assertEqual(before, fixture.snapshot())
                        self.assertEqual([], fixture.events)
                    finally:
                        fixture.close()

    def test_desired_system_alias_and_manual_preflight_cli(self):
        fixture = self.fixture()
        desired, system, units = fixture.desired_tree()
        alias = system / "specialisation/foreign"
        alias.parent.mkdir()
        alias.symlink_to(system)
        config_path = fixture.base / "guard.json"
        config_path.write_text(json.dumps(fixture.config))
        # Runtime-only vendor registration is not a desired persistent conflict.
        before = fixture.snapshot()
        with patch.object(os, "geteuid", return_value=0):
            for extra in ([], ["--system", desired],
                          ["--system", desired + "/specialisation/foreign"]):
                with self.subTest(extra=extra), patch.object(
                        sys, "argv", ["sentinelone-native", "preflight", str(config_path), *extra]):
                    controller.main()
            (units / "sentinelone.service").symlink_to("/missing")
            # Manual preflight deliberately checks only the current tree.
            with patch.object(sys, "argv", ["sentinelone-native", "preflight", str(config_path)]):
                controller.main()
            for command, extra in [
                ("preflight", ["--system", desired]),
                ("preflight", ["--system"]),
                ("preflight", ["--bad", desired]),
                ("preflight", ["--system", desired, "extra"]),
                ("preflight", ["--system", "/nix/store-backup/system"]),
                ("preflight", ["--system", "relative"]),
                ("preflight", ["--system", desired + "/../other"]),
                ("reconcile", ["--system", desired]),
                ("status", ["--system", desired]),
                ("exec", ["--system", desired]),
            ]:
                with self.subTest(command=command, extra=extra), patch.object(
                        sys, "argv", ["sentinelone-native", command, str(config_path), *extra]):
                    with self.assertRaises((controller.Refusal, OSError)):
                        controller.main()
            (units / "sentinelone.service").unlink()
        self.assertEqual(before, fixture.snapshot())
        self.assertEqual([], fixture.events)

    def test_current_persistent_inspection_errors_are_not_absence(self):
        fixture = self.fixture()
        before = fixture.snapshot()
        original_lstat = Path.lstat

        def lstat(path, *args, **kwargs):
            if path == fixture.paths["PERSISTENT_UNIT"]:
                raise PermissionError(13, "denied")
            return original_lstat(path, *args, **kwargs)

        with patch.object(Path, "lstat", lstat):
            with self.assertRaises((controller.Refusal, OSError)):
                controller.preflight(fixture.config)
        self.assertEqual(before, fixture.snapshot())
        self.assertEqual([], fixture.events)

    def test_native_store_payload_exclusion_is_component_aware(self):
        fixture = self.fixture()
        path = fixture.base / "candidate.json"
        path.write_text(json.dumps(dict(fixture.config, data_dir="/nix/store-backup/payload")))
        self.assertEqual("/nix/store-backup/payload", controller.load_config(path)["data_dir"])
        for data in ("/nix/store", "/nix/store/payload"):
            path.write_text(json.dumps(dict(fixture.config, data_dir=data)))
            with self.assertRaises(controller.Refusal):
                controller.load_config(path)

    def test_same_config_marker_race_refuses_before_root_or_package_changes(self):
        fixture = self.fixture(fault="marker-race", same_config=True)
        before = fixture.snapshot()
        with self.assertRaises(controller.Refusal):
            fixture.reconcile()
        after = fixture.snapshot()
        after.pop("boot-marker")
        self.assertEqual(before, after)
        self.assertEqual([], fixture.events)


if __name__ == "__main__":
    unittest.main()
