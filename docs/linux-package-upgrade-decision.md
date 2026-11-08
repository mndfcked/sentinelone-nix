# Linux package and upgrade decision

Status: the credential-free actual-DEB module lifecycle passed offline. Native local-update mode remains experimental and unenrolled. Production automatic updates remain on HOLD.

Date: 2026-11-08

Tracking: [#2](https://github.com/mndfcked/sentinelone-nix/issues/2) and [#3](https://github.com/mndfcked/sentinelone-nix/issues/3) remain open and are not fulfilled by the work recorded here.

## Decision

The store-managed legacy module remains the default, and [package.nix](../package.nix) still selects the existing `24.3.3.1` package. The legacy package, `package.nix`, and `bootstrap.py` remain unchanged, and the package source and version were not re-vetted in this work. No default-package change is proposed. The native work targets one personal installation. Backward compatibility with legacy configurations is not guaranteed.

The experimental, default-off `services.sentinelone.vendorManagedUpdates` mode uses the original local DEB from `services.sentinelone.package.src` once to initialize fresh state. It does not use patched legacy package output. The vendor installer and updater own later payload versions and the current vendor unit; later boots do not restore the seed. The `package` override and `dataDir` option remain the source and payload-location interfaces. The Nix integration does not enroll the agent or implement an update downloader, and authenticated management remains unverified. Keep `services.sentinelone.enable = false` on live hosts.

Production automatic updates remain on HOLD pending separately approved secret-safe enrollment and a management-triggered N-to-N+1 test. Continuing the investigation does not require an up-front vendor questionnaire or recurring N+1 DEB handoffs.

## Candidate and provenance

The candidate is the owner-trusted administrator handoff of `SentinelAgent_linux_x86_64_v26_2_1_24.deb`, package `sentinelagent` version `26.2.1.24`, architecture `amd64`, size 61,602,192 bytes. The owner accepted the administrator handoff as the trust source.

| Evidence | Value and limit |
| --- | --- |
| SHA-256 | `3ff2e97e591135410abafb90e9297cb550738caadf0dd4119b2013574b29e630` |
| Nix SRI | `sha256-P/LpflkRNUEKuvuQ6Sl8tVBzjKrfDdQRmyATV0sp5jA=` |
| Declared dependencies | `coreutils`, `passwd`, and `kmod`. These do not establish kernel requirements. |
| Trust evidence | Owner-reported official vendor package from a trusted administrator. The owner accepted that handoff. |
| Not established | No independent vendor signature, independent digest, vendor attestation, SBOM, or release security audit was recorded. The digest confirms byte identity when checked; it does not prove who built or signed the file. |

The native module reads the original DEB from `services.sentinelone.package.src` once, only when creating fresh native state. It leaves the source untouched and does not use the patched package output from the legacy package derivation. Later boots do not restore the seed.

The current Nixpkgs metadata for selected runtime packages, including dpkg, shadow, kmod, nix-ld, coreutils, bash, util-linux, and Python, reports maintainers, non-broken packages, and no known vulnerabilities. This is package metadata, not a complete upstream CVE audit or a security certification.

## Local source example

After adding this repository as a pinned flake input named `sentinelone`, use this complete NixOS module example to select the original local DEB without enabling the service:

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.sentinelone.nixosModules.sentinelone ];

  services.sentinelone = {
    enable = false;
    vendorManagedUpdates = true;
    sentinelOneManagementTokenPath = null;
    customerId = null;
    email = null;
    serialNumber = null;
    dataDir = "/var/lib/sentinelone";
    package = pkgs.sentinelone.overrideAttrs (_old: {
      version = "26.2.1.24";
      src = pkgs.requireFile {
        name = "SentinelAgent_linux_x86_64_v26_2_1_24.deb";
        sha256 = "sha256-P/LpflkRNUEKuvuQ6Sl8tVBzjKrfDdQRmyATV0sp5jA=";
        # No public artifact URL exists; the DEB arrives by owner-trusted
        # administrator handoff. Current nixpkgs requireFile still demands a
        # pointer (or a custom message) for its failure message.
        url = "https://www.sentinelone.com/";
      };
    });
  };
}
```

Only enable this configuration in a separately approved disposable VM with fresh candidate state. This is not a live-host activation recommendation.

Import the owner-trusted file once into a permitted private local Nix store before realizing or building the required source:

```sh
nix-store --add-fixed sha256 /path/to/SentinelAgent_linux_x86_64_v26_2_1_24.deb
```

Keep that basename: it must match `requireFile.name`. Never commit or upload the proprietary artifact, send it to remote builders or upload daemons, or place it in public caches. Unfree metadata does not enforce these transfer restrictions.

`pkgs.requireFile` does not download the file; the file need not already be present merely to evaluate the expression. It marks the source with an unfree license (undistributable artifact), so the evaluating configuration needs an unfree allowance, such as `nixpkgs.config.allowUnfreePredicate` matching the package; the one-time local import itself needs none.

## Native mode contract and limits

The native mode requires `system.preSwitchChecks`. When enabled, it requires `sentinelOneManagementTokenPath = null` and rejects non-null `customerId`, `email`, and `serialNumber`. The token-path option is now nullable with a null default; legacy mode still requires a non-null token path when enabled. Native mode does not silently ignore enrollment settings.

Native credential application is not implemented. The vendor CLI help advertises a positional token, and the installer logs and passes a token. This project does not add that token argument, invent stdin or file flags, reuse the legacy token writer, or claim enrollment. Do not use the legacy bootstrap mechanism to enroll native mode.

The controller stores root-only state, locks, and a private dpkg database under `/var/lib/sentinelone-nix`, outside the vendor payload. It explicitly creates root-only control directories at mode `0700` and state, lock, marker, and environment files at mode `0600`. The vendor payload lives at `dataDir`, with an exact `/opt/sentinelone` symlink to that path. The private database does not make the vendor payload private. The controller uses normal `dpkg` with an isolated `DPKG_ADMINDIR`; it does not use a fake package database or force flags.

In the normal vendor 26 layout, the `/opt/sentinelone` symlink and vendor configuration directory are owned by the Nix `sentinelone` account; the unit file is root-owned mode `0644`. Under the protected `/opt` root, the controller accepts the expected vendor structures when owned by root or the Nix vendor account and requires the symlink target to match `dataDir` exactly. It reads the selected unit through a pinned physical data/config directory file descriptor and relative `O_NOFOLLOW` lookup. The unit must be a root-owned regular file, have no group or other write permission, be at most 65,536 bytes, and remain stable across the before-and-after checks. The configuration directory and unit must stay on the `dataDir` filesystem; mounting the whole `dataDir` is permitted. Same-device checks do not prove that a same-filesystem bind mount is absent. Runtime `fs.protected_hardlinks=1` is required for the read-only guard. The controller does not chmod or chown vendor objects or change vendor policies.

Active and pending configuration roots live under `/nix/var/nix/gcroots/sentinelone-nix`, outside the payload; `dataDir` must not overlap that directory or the control directory in either direction. A transient `transaction` root retains the old configuration (the new one on first install) through promotion, Ready publication, start queuing, and controller-lock release. Any leftover guard blocks further use. Final guard removal is deliberately not directory-fsynced: a crash may leave an obsolete guard requiring operator investigation, while the new active root and Ready state are already durable.

A runtime provider package at version 1 supplies unversioned `coreutils`, `passwd`, and `kmod` package names. The provider uses individual global FHS links, plus `/bin/bash` and `/usr/lib/systemd/system -> /run/systemd/system`. Unpatched vendor ELFs use `nix-ld` with libgcc, the C++ runtime, zlib, and elfutils. Existing security wrappers and PAM integration remain in use. This is not general Debian compatibility. New or versioned dependencies and conflicting FHS slots fail normal checks.

Boot-time reconciliation initializes fresh native state, refreshes the provider, and registers the current vendor unit. The initializer's umask `0022` preserves the requested public FHS directory mode `0755` and gives child `dpkg` its normal umask. Vendor-chosen directory modes, including `1700` and `0700`, remain unchanged. Root-only control directories are created at `0700`, and state, lock, marker, and environment files at `0600`. Root installation commands use a fresh `HOME=/root`, `TMPDIR=/tmp`, and noninteractive Debconf. The vendor-unit drop-in sets only six runtime variables, preserving the vendor's own `HOME`, `TMPDIR`, and Debconf values. The vendor unit's umask and other vendor policies remain unchanged. Same-boot activation checks the existing mode read-only and does not reinstall the seed or change the provider, environment, unit, or agent. Enabling native mode on an already-running host waits for the next boot. Pinned provider tools and libraries refresh at boot. NixOS security wrappers remain owned by the current OS configuration; the native GC root does not freeze their implementation.

After fresh initialization, the vendor installer and updater own future payload versions and the current vendor unit. Later boots ignore the seed version and store identity, do not restore the seed, and use the current protected vendor unit. The vendor watchdog, restart, and manual-stop policy is preserved.

Missing, unknown, unsafe, legacy, or interrupted state and conflicting FHS slots fail closed without cleanup, adoption, or reseeding. Native control and GC-root metadata names remain reserved, and ambiguous state is refused.

Before native initialization and during existing-native checks, the controller rejects persistent `/etc/systemd/system/sentinelone.service` and `sentinelone.service.d` entries. The pre-switch hook also checks those exact names in the desired configuration's assembled `etc/systemd/system` tree, including `systemd.packages` contributions. NixOS supplies that new configuration path as the hook's first positional argument, `$1`; the hook passes it as `preflight CONFIG --system "$1"`. The guard JSON still contains only schema, mode booleans, and `dataDir`, with no package, source, provider, or system-build dependency.

Desired store aliases, including specialisation paths, resolve read-only to a store-backed configuration and physical unit directory. Missing, unsafe, out-of-store, or unreadable trees fail closed. Even an empty drop-in directory, masked unit, or dangling symlink is foreign. Inspection errors are not absence. Manual `preflight CONFIG` retains current-tree-only semantics. These checks read no transient dpkg status and do not walk the vendor payload or BPF mounts.

The controller preserves payload, control database, GC roots, and evidence on error. While the module remains imported, its pre-switch check vetoes disabling native mode, changing backend, or changing `dataDir` when native state exists. Entering native mode rejects any existing payload, including legacy state. Removing the module entirely cannot be intercepted. Historical Nixpkgs, profile, and bootloader rollback behavior is not established. Nix generation rollback does not roll back mutable agent state.

Recovery requires an operator-approved vendor stop and recovery plan. Do not add a marker, delete state, or force dependencies to bypass a refusal. There is no generic repair, adoption, or uninstall path.

The checks assume a trusted root-managed filesystem and mount namespace, and a trusted vendor installer, updater, and service account. Path, Unix ownership, and checks on the private dpkg database path do not authenticate who wrote the current unit bytes, prove freshness, or prevent rollback. They cannot defend against a compromised vendor account during its ownership-change window or a process holding a retained writable file descriptor. No checksum framework authenticates the unit.

## Evidence and remaining work

The current revision-bound results and reproduction procedure live in [native offline validation](native-offline-validation.md). All nine explicit public check attributes passed, with the separate formatting check and scoped Pyright. The actual-module lifecycle passed using the isolated integration candidate's Nixpkgs, exact Zen kernel, loader libraries, Nix, and systemd inputs. It recorded one same-DEB replacement, a real successful dpkg exec witness, nine new physical inodes with unchanged bytes, five 45-second watchdog windows, reboot persistence, and distinct-closure switch/return. No running host was activated.

Earlier scratch-prototype results are separate from this completed module run. Earlier actual-module failures included host ENOSPC during report saving (cause unknown), an unmeasured capacity margin, missing guest store metadata, and strict rejection of a stacked store bind with VFS rw flags on a read-only superblock. The current run uses measured capacity checks, an empty mode-0555 external metadata stand-in, and explicit read-only VM bind options without weakening per-layer validation. The validation page records those constraints and remaining containment limits.

The local-source example is covered at evaluation time without building the proprietary source. The old package default and standalone lock remain unchanged. Exact delivery-head remote CI is recorded in the PR; an earlier green SHA does not cover later changes.

Separately approved secret-safe enrollment and management-triggered N-to-N+1 acceptance remain future requirements. The current native mode has no credential writer or authenticated-management test, and token, customer ID, email, and serial-number settings must remain null. The successful offline lifecycle does not establish service health, host-hardware compatibility, protection or recovery behavior, vendor support for NixOS, whole-payload or full-state equality, profile or bootloader rollback, or compatibility with arbitrary future packages.
