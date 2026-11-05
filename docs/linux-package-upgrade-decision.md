# Linux package and upgrade decision

Status: production automatic updates remain on HOLD. Native local-update mode is experimental and unenrolled.

Date: 2026-11-05

Tracking: [#2](https://github.com/mndfcked/sentinelone-nix/issues/2) and [#3](https://github.com/mndfcked/sentinelone-nix/issues/3) remain open and are not fulfilled by the work recorded here.

## Decision

The store-managed legacy module remains the default, and [package.nix](../package.nix) still selects the existing `24.3.3.1` package. That package source and version were not re-vetted in this work. No default-package change is proposed. The native work targets one personal installation; backward compatibility with legacy configurations is not guaranteed.

The experimental `services.sentinelone.vendorManagedUpdates` mode uses a local original DEB and vendor-managed mutable payload. The Nix integration does not enroll the agent or implement an update downloader. The vendor updater owns agent versions and intended update delivery; authenticated management remains unverified. Keep `services.sentinelone.enable = false` on live hosts.

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

The native module reads the original DEB from `services.sentinelone.package.src`, not the patched package output from the legacy package derivation. The seed is used only when creating fresh native state.

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

Keep that basename: it must match `requireFile.name`. `pkgs.requireFile` does not download the file; the file need not already be present merely to evaluate the expression. Keep the artifact out of this repository and artifact repositories. Do not send it to remote builders, upload daemons, or public caches. A matching hash pins byte identity, not independent vendor authenticity. Later vendor-managed updates do not require handing over each next DEB.

## Native mode contract and limits

The native mode requires `system.preSwitchChecks`. When enabled, it requires `sentinelOneManagementTokenPath = null` and rejects non-null `customerId`, `email`, and `serialNumber`. The token-path option is now nullable with a null default; legacy mode still requires a non-null token path when enabled. Native mode does not silently ignore enrollment settings.

Credential application remains unresolved. The vendor CLI help advertises a positional token, and the installer logs and passes a token. This project does not add that token argument, invent stdin or file flags, reuse the legacy token writer, or claim enrollment. Do not use the legacy bootstrap mechanism to enroll native mode.

The controller stores root-only state, locks, and a private dpkg database under `/var/lib/sentinelone-nix`. The vendor payload lives at `dataDir`, with an exact `/opt/sentinelone` symlink to that path. The private database does not make the vendor payload private. The controller uses normal `dpkg` with an isolated `DPKG_ADMINDIR`; it does not use a fake package database or force flags.

Active and pending configuration roots live under `/nix/var/nix/gcroots/sentinelone-nix`, outside the payload; `dataDir` must not overlap that directory or the control directory in either direction. A transient `transaction` root retains the old configuration (the new one on first install) through promotion, Ready publication, start queuing, and controller-lock release. Any leftover guard blocks further use. Final guard removal is deliberately not directory-fsynced: a crash may leave an obsolete guard requiring operator investigation, while the new active root and Ready state are already durable.

A runtime provider package at version 1 supplies unversioned `coreutils`, `passwd`, and `kmod` package names. The provider uses individual global FHS links, plus `/bin/bash` and `/usr/lib/systemd/system -> /run/systemd/system`. Unpatched vendor ELFs use `nix-ld` with libgcc, the C++ runtime, zlib, and elfutils. Existing security wrappers and PAM integration remain in use. This is not general Debian compatibility. New or versioned dependencies and conflicting FHS slots fail normal checks.

Boot-time reconciliation initializes fresh native state, refreshes the provider, and registers the current vendor unit. Root installation commands use a fresh `HOME=/root`, `TMPDIR=/tmp`, and noninteractive Debconf. The vendor-unit drop-in sets only six runtime variables, preserving the vendor's own HOME, TMPDIR, and Debconf values. Same-boot activation checks the existing mode read-only and does not reinstall the seed or change the provider, environment, unit, or agent. Enabling native mode on an already-running host waits for the next boot. Pinned provider tools and libraries refresh at boot. NixOS security wrappers remain owned by the current OS configuration; the native GC root does not freeze their implementation.

After fresh initialization, the vendor owns installed agent versions. Later boots ignore the seed version and store identity and use the current protected vendor unit. The vendor watchdog, restart, and manual-stop policy is preserved.

Missing, unknown, unsafe, legacy, or interrupted state and conflicting FHS slots fail closed without cleanup, adoption, or reseeding. Native control and GC-root metadata names remain reserved, and ambiguous state is refused.

Before native initialization and during existing-native checks, the controller rejects persistent `/etc/systemd/system/sentinelone.service` and `sentinelone.service.d` entries. The pre-switch hook also checks those exact names in the desired configuration's assembled `etc/systemd/system` tree, including `systemd.packages` contributions. NixOS supplies that new configuration path as the hook's first positional argument, `$1`; the hook passes it as `preflight CONFIG --system "$1"`. The guard JSON still contains only schema, mode booleans, and `dataDir`, with no package, source, provider, or system-build dependency.

Desired store aliases, including specialisation paths, resolve read-only to a store-backed configuration and physical unit directory. Missing, unsafe, out-of-store, or unreadable trees fail closed. Even an empty drop-in directory, masked unit, or dangling symlink is foreign. Inspection errors are not absence. Manual `preflight CONFIG` retains current-tree-only semantics. These checks read no transient dpkg status and do not walk the vendor payload or BPF mounts.

The controller preserves payload, control database, GC roots, and evidence on error. While the module remains imported, its pre-switch check vetoes disabling native mode, changing backend, or changing `dataDir` when native state exists. Entering native mode rejects any existing payload, including legacy state. Removing the module entirely cannot be intercepted. Historical Nixpkgs, profile, and bootloader rollback behavior is not established. Nix generation rollback does not roll back mutable agent state.

Recovery requires an operator-approved vendor stop and recovery plan. Do not add a marker, delete state, or force dependencies to bypass a refusal. There is no generic repair, adoption, or uninstall path.

## Evidence and remaining work

A separate scratch prototype used the actual owner-trusted `26.2.1.24` DEB in a normal installation. It ran `sentinelctl control upgrade --output <same-26.2.1.24-DEB>` and observed a successful real `dpkg` execution. This was a same-package local replacement, not a vendor-confirmed management contract, enrollment, or N-to-N+1 update.

The prototype observed new inodes with unchanged bytes for all nine selected ELF/library files. The service passed a 45-second watchdog window after the update and after reboot. The test also rebooted and switched between two distinct system closures while retaining the selected agent state. Its observer did not walk the full payload or establish full-tree equality. Default dpkg absence was endpoint evidence only; it did not prove that no transient writes occurred.

A full public flake-suite invocation against a metadata-free source snapshot completed successfully, covering legacy bootstrap and VM checks, the vendor-runtime ELF fixture, CI policy, native options/runtime/backend, the observer check, and treefmt. That invocation included the root-HOME canary and vendor-environment preservation coverage and reused cached outputs; it did not execute every build or VM from scratch. A separate invocation of the identical bootstrap derivation passed in 40.98 seconds after an earlier execution timed out at journal capture; the cause of that stall is unknown. These results predate the transaction-guard and persistent-path fixes. The controller fault check covers those failure boundaries separately. Public fixtures do not use the proprietary DEB and do not prove enrollment or a real vendor upgrade.

The synthetic backend VM separately passed actual switches that refused desired declared-unit and package-provided drop-in conflicts before changing the current generation, controller or provider state, unit registration, daemon PID, or process environment. It also passed same-boot base-to-next-to-base activation while a genuine dpkg postinst held both POSIX database locks, preserving the active native state. The controller fault suite passed its existing transaction matrix and new desired-tree, inspection-error, path, and CLI cases. These are synthetic checks; they add no real-artifact module proof.

The private real-artifact module VM is still unsuccessful. Its latest Nix build passes all strict containment checks, then stops before the initializer or vendor runs: the standard `register-nix-paths.service` fails with `error: creating directory "/nix/store/.links": Read-only file system`. A separate source-root registration experiment outside the build sandbox returned exit 0 for both store-path validity and canonical GC-root creation checks; those exit statuses were not counts of valid paths or roots. The experiment had access to `/nix/store/.links`, so its result is not representative of the failing Nix build sandbox. Real-artifact module proof remains pending; the scratch prototype does not supply it.

Separately approved secret-safe enrollment and management-triggered N-to-N+1 acceptance are still required. The observed local same-package command does not satisfy either requirement. Even successful acceptance would not establish host-hardware compatibility, protection or recovery behavior, vendor support for NixOS, or compatibility with arbitrary future packages.
