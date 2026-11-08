# Native offline validation

## Scope

This acceptance run uses an owner-trusted original `26.2.1.24` DEB in a disposable, unenrolled NixOS VM. It does not activate either running host, read enrollment credentials, or test authenticated management delivery. Production automatic updates remain on HOLD.

The [decision](linux-package-upgrade-decision.md) owns the native contract and artifact provenance. This page records reproducible validation and revision-bound results.

## Public checks

On 2026-11-08, all nine explicit public check attributes passed on `8b717b8cb026bd099af236cb74d09a1817a0bc6c`: `bootstrap`, `vmtest`, `vendor-runtime`, `ci-policy`, `native-options`, `native-runtime`, `native-backend`, `native-observer`, and `native-controller`. The `default` attribute aliases `vmtest`. The separate `treefmt` check and Pyright on `tests/native-vendor-observer.py` passed. These are fixture and policy checks, not proprietary-agent acceptance.

Run the commands in [README: Checks](../README.md#checks). No public check requires the private DEB.

The documented local-source example now supplies the URL required by current `requireFile`. The option fixture forces `package.src.drvPath` at evaluation time without building the source. `requireFile` marks its output unfree; an evaluation allowance is still required.

## Store containment regression

An earlier offline attempt completed the local replacement and nine-file comparison, then failed after reboot because a stacked `/nix/store` bind had VFS `rw` flags. Its virtiofs superblock remained `ro`, and effective `statvfs` access included `ST_RDONLY`. The mount actor and timing were not established.

The test now explicitly appends `ro`, `nosuid`, and `nodev` to `virtualisation.fileSystems."/nix/store".options`, preserving `bind`. The observer still rejects any `rw` store layer, including hidden stacked records; the new `stacked-rw-store` fixture checks this refusal. No validator exception is used.

A vendor-free probe using the integration candidate package set and exact Zen kernel passed initial boot plus four reboots in 71.80 seconds. At `basic.target` and `multi-user.target` on every boot, the checked-in observer accepted only the store and private scratch shares, read-only store layers, loopback only, and empty IPv4/IPv6 routes. Result: `/nix/store/mrsvm99gajyy9karysf6qfx2zb74fyfs-vm-test-run-s1-strict-store-reboot`. These are checkpoint observations, not continuous protection or VM-escape hardening.

## Private lifecycle procedure

Use only a separately approved local machine with KVM and sufficient measured capacity. Keep the DEB, raw logs, reports, drivers, and any output closures private. Never send them to remote builders, upload hooks, or public caches.

1. Check the original file against the [candidate identity](linux-package-upgrade-decision.md#candidate-and-provenance). Root the exact source inputs, original DEB, driver, and result locally.
1. Disable remote builders and post-build hooks, unset `QEMU_OPTS`, and verify the empty build fence. Do not copy a token or legacy enrollment state.
1. Prepare a fresh empty mode-`0555` directory accessible to the build user. Map it as `/nix/store/.links` using `extra-sandbox-paths`; never map the real host metadata directory. Record its physical identity and verify it is empty. This external mapping is not included in the derivation hash.
1. Evaluate and build the private test driver before starting the VM. Measure unpacked payload bytes, driver closure bytes/path count, free bytes, and free inodes. The local capacity estimate reserves 2 GiB for the VM root, twice unpacked payload size, 64 MiB for reports/logs, and a 25% driver-closure margin; these are run margins, not product requirements.
1. Run `tests/native-vendor.nix` with the original private `vendorDeb` path. Keep the checked-in 900-second test timeout and an outer finite deadline. Do not retry an upgrade inside the VM.
1. Inspect `native-vendor-evidence.json`: require `stage = "complete"`, no failures, one successful upgrade, a complete successful-exec trace with a genuine `dpkg` witness, all five stability windows, nine physical file replacements, reboot persistence, and distinct-closure switch/return. A shell exit alone does not establish acceptance.

For configuration-specific integration, use the candidate configuration package set and the same runtime inputs rather than the standalone flake default:

```nix
let
  candidate = configFlake.nixosConfigurations.frame-native-candidate;
  pkgs = candidate.pkgs;
  test = import ./tests/native-vendor.nix {
    inherit pkgs;
    vendorDeb = /private/path/SentinelAgent_linux_x86_64_v26_2_1_24.deb;
  };
in
test.extendNixOS {
  module = {
    boot.kernelPackages = pkgs.lib.mkForce candidate.config.boot.kernelPackages;
    programs.nix-ld.libraries = pkgs.lib.mkForce candidate.config.programs.nix-ld.libraries;
    nix.package = pkgs.lib.mkForce candidate.config.nix.package;
  };
}
```

This expression is schematic: bind `configFlake` to the isolated candidate and import the test from the reviewed backend checkout. It does not import the full host configuration into the VM. Verify evaluated kernel, loader libraries, Nix, and systemd identities against the candidate before execution.

The recorded integration inputs are Nixpkgs `577e5b3393ab727c2cd3768ef981a7ba7d8c120d` (`sha256-Df87rV1AnZaIX3kM7LZ6bHKKqZ1v8MnK/g286JDTcyw=`), kernel `7.2.14-zen1`, systemd 262, Nix 2.34.9, glibc 2.44, and dpkg 1.23.7. The standalone public suite retains its unchanged lock. No dependency pin is upgraded by this validation.

## Lifecycle result

The actual-module run passed on 2026-11-08 on blackbox using code revision `8b717b8cb026bd099af236cb74d09a1817a0bc6c` and the integration runtime inputs above. The driver completed in 308.13 seconds. The structured report has `stage = "complete"` and an empty `failures` list.

| Observation | Result |
| --- | --- |
| Local supported upgrade | One invocation, exit 0, successful vendor output; no retry |
| Dedicated successful-exec trace | Complete; genuine `dpkg` execution witnessed |
| Physical selected files | All nine gained new inodes with unchanged SHA-256 bytes |
| Bootstrap / after upgrade / after reboot / next closure / restored base | Each passed 15 samples over at least 45.05 seconds; stable PID within each window, zero restarts, advancing watchdog |
| Reboot | New boot ID, same root filesystem UUID, selected snapshot preserved |
| Distinct closures | Test-mode switch to next and back; selected payload, controls, and unit snapshot preserved |
| Containment | Five successful checkpoints, including before reconciliation on both boots; strict store flags, exact shares, no NIC/routes |
| Default dpkg database | Vendor absent before and after, as endpoint observations |

Private result: `/nix/store/ns1cffkmga07lnp3wz08jv5sj00kc62j-vm-test-run-sentinelone-native-vendor-offline`. Private report SHA-256: `bc4d7a98fb1fe0b287a77ea4c48b721a453cc8e9b1a517067692f29be86fb264`. The report and raw vendor logs stay local; no proprietary artifact or output closure is published.

The disposable system closures were `/nix/store/a79czkq67z0l860vzr2mciy6zhz8nga6-nixos-system-machine-test` and `/nix/store/g60kbcxhqi8945qcmdc0l3hqz2r6qnvy-nixos-system-machine-test`. Neither was activated on a running host.

The measured payload was 341,506,743 unpacked bytes. The driver closure was 4,891,636,736 bytes across 904 paths; the preflight observed 841 GiB free. The empty `.links` stand-in was mode `0555`, device `65024`, inode `108003497`, and owner `joern`. Its mapping remains an external, non-hashed run input.

## Limits

A local same-DEB replacement is not authenticated N-to-N+1 delivery. Nine selected physical files do not prove whole-payload or full-state equality. Default-dpkg absence is endpoint evidence, not proof of zero transient writes. Test-mode closure switching is not profile-generation or bootloader rollback. Watchdog observations do not establish protection, hardware compatibility, recovery, vendor support, or arbitrary future-package compatibility.

The guest has no NIC and receives only a read-only store export and private mode-`0700` exchange share. Whole-build-store visibility and virtiofsd without sandbox/seccomp remain limits; this test is not hermetic or hardened against VM escape. Native credentials remain null. Enrollment and management-triggered cross-version acceptance require separate approval.
