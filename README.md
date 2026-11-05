# sentinelone-nix

## About

NixOS package and module for SentinelOne, based on the SentinelOne package from [GitLab](https://gitlab.com/gitlab-com/gl-infra/reliability).

## Production status

The store-managed legacy module remains the default. Its package in [package.nix](package.nix) is still version 24.3.3.1 from the existing third-party source. The native work does not update or re-vet that package. Keep `services.sentinelone.enable = false` on live hosts.

`services.sentinelone.vendorManagedUpdates = true` selects an experimental, unenrolled native mode for a local vendor-managed payload. The Nix integration does not provide credential enrollment or implement an update downloader. The vendor updater owns agent versions and intended update delivery; authenticated management remains unverified. Production automatic updates remain on HOLD pending separately approved secret-safe enrollment and a management-triggered N-to-N+1 test. See the [Linux package and upgrade decision](docs/linux-package-upgrade-decision.md).

## Modes

### Store-managed legacy

Legacy remains the default mode. It runs package binaries from the immutable Nix store and uses read-only component bind mounts. The existing `bootstrap.py`, token handling, and customer-ID behavior remain unchanged.

When legacy mode is enabled, `sentinelOneManagementTokenPath` is required. It accepts a canonical absolute runtime string without Nix store context. Nix path values and store-backed strings are rejected. A secret manager's runtime `.path` string remains supported. The token source must be a regular file with no group or other permissions, such as mode `0400` or `0600`. Runtime secret-manager symlinks and private files owned by the configured secret recipient are supported. The initializer does not change source permissions or ownership.

The token must contain a single-line base64 encoding of one JSON object with nonempty string `url` and `site_key` fields. One trailing newline is accepted. Embedded token newlines and control characters in decoded fields are rejected. Token bytes are read only during initialization and are not passed through command arguments, environment variables, or diagnostics.

The destination may be absent or an empty root-owned directory. Its parent must already exist. The destination and its ancestors must be real root-owned directories without group or other write access. Symlinks and nested mounts are refused. The base bind mount uses private propagation so component mounts do not appear inside the persistent source tree.

Existing nonempty state without a valid `.sentinelone-bootstrap.json` marker is refused unchanged. Legacy or partial installations are never adopted, deleted, migrated, or re-enrolled automatically. For example, an old unmarked `/var/lib/sentinelone` prevents the daemon and its mounts from starting. Inspect a refusal with:

```sh
journalctl -u sentinelone-init.service
```

Preserve the existing tree and request an explicit operator migration or upgrade plan. Do not delete state or add a marker to bypass the refusal. Interrupted staging directories also require operator review. The helper only cleans staging created by its own invocation.

The marker records a schema and the exact store package identity. A matching marker permits startup without rereading the original token, including after enrollment consumes its bootstrap files. A different package identity or malformed marker prevents startup without changing existing contents, permissions, or ownership. The marker does not verify a vendor signature, enrollment health, or installed vendor version.

### Experimental native mode

Native mode targets one personal installation. Backward compatibility with legacy configurations is not guaranteed.

Native mode is selected with `services.sentinelone.vendorManagedUpdates = true`. It requires the NixOS `system.preSwitchChecks` API. When the service is enabled in native mode:

- `sentinelOneManagementTokenPath` must be null. The option now has a nullable type and a null default, while legacy mode still requires a token path when enabled.
- `customerId`, `email`, and `serialNumber` must all be null. Native mode rejects these settings rather than ignoring them.
- `dataDir` must not overlap `/var/lib/sentinelone-nix` or `/nix/var/nix/gcroots/sentinelone-nix`, in either direction.

Native mode does not enroll the agent. Vendor credential application remains unresolved. Do not pass a token through the CLI, invent another input method, or reuse the legacy bootstrap path for native enrollment.

The native controller uses the original administrator-provided DEB at `services.sentinelone.package.src`, not the patched package output. The vendor package receives `S1_AGENT_CUSTOM_INSTALL_PATH=dataDir` and `S1_AGENT_CREATE_USER=false`; `/opt/sentinelone` is an exact symlink to `dataDir`. The agent runs as a host systemd service. Native mode adds no container, namespace, `nsenter`, store-agent process, or read-only payload bind mounts.

The filesystem roles are separate:

- Vendor payload: `dataDir`, reached through `/opt/sentinelone`.
- Root-only controller state, lock, and private dpkg database: `/var/lib/sentinelone-nix`.
- Nix GC roots: `/nix/var/nix/gcroots/sentinelone-nix`. They retain complete configuration, runtime, and library references. See the [transaction guard contract](docs/linux-package-upgrade-decision.md#native-mode-contract-and-limits).

The private dpkg database is package-registration state. It does not make the vendor payload private. The controller uses normal `dpkg` with an isolated `DPKG_ADMINDIR`; it does not fake package state or pass force flags. It installs a runtime provider package at version 1 with unversioned `Provides: coreutils, passwd, kmod`. A future vendor package that adds versioned or unsupported dependencies fails normal package checks.

The provider exposes individual global FHS links, including commands under `/usr/sbin`, `/bin/bash`, and `/usr/lib/systemd/system -> /run/systemd/system`. Existing NixOS security wrappers and PAM integration remain in use. Unpatched vendor ELFs use `nix-ld` with libgcc, the C++ runtime, zlib, and elfutils. No ABI aliases or general Debian compatibility layer are provided.

Initialization, provider refresh, and registration of the current vendor unit happen at boot only. Enabling native mode on an already-running host waits until the next boot. Same-boot activation performs read-only stable-mode checks; it does not reinstall the seed or change the provider, environment, unit, or agent. Pinned provider tools and libraries refresh at the next boot. NixOS security wrappers remain owned by the current OS configuration; the native GC root does not freeze their implementation.

The seed DEB is installed only for a fresh native state. The vendor owns installed agent versions. Later boots ignore the seed version and store identity and use the current protected vendor unit. The existing vendor watchdog, restart, and manual-stop policy is preserved. This mode does not provide a generic repair, adoption, or uninstall path.

Unknown, missing, unsafe, legacy, or interrupted state and conflicting global FHS slots fail closed. Native control and GC-root metadata names remain reserved; ambiguous state is refused. The controller does not clean state, adopt an installation, or reseed after an error.

The pre-switch hook checks both the current persistent systemd tree and the desired configuration's assembled `etc/systemd/system` tree, using the new configuration path supplied by NixOS as `$1`. A `sentinelone.service` or `sentinelone.service.d` entry blocks native mode, including package-provided drop-ins, empty directories, masks, and dangling symlinks. Missing, unsafe, out-of-store, or unreadable desired trees fail closed before activation or service stops. Manual `preflight CONFIG` checks only the current tree; `preflight CONFIG --system NEW_SYSTEM` also checks the desired tree.

While the module remains imported, its pre-switch check vetoes disabling native mode, changing backend, or changing `dataDir` when native state exists. Entering native mode rejects any existing payload, including legacy state. Removing the module entirely cannot be intercepted. Historical Nixpkgs, profile, and bootloader rollback behavior has not been proved. A Nix generation rollback does not roll back mutable agent state.

Preserve the payload, controller database, GC roots, and evidence after an error. Recovery requires an operator-approved vendor stop and recovery plan. Do not add markers, delete state, or force dependencies to bypass a refusal.

## Checks

Run public checks separately from the repository root. These commands build checks and do not activate a NixOS configuration.

```sh
nix build path:.#checks.x86_64-linux.bootstrap --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.vmtest --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.vendor-runtime --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.ci-policy --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.native-options --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.native-runtime --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.native-backend --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.native-observer --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.native-controller --no-link --no-write-lock-file -L
```

The bootstrap and native checks use fixtures. The controller check injects filesystem and command failures without the proprietary DEB; the synthetic backend VM checks genuine Nix roots and package operations. A separate private VM check uses the owner-trusted DEB and is excluded from public CI. See [evidence and remaining work](docs/linux-package-upgrade-decision.md#evidence-and-remaining-work) for public-suite results and the still-unsuccessful real-artifact module test. Fixture checks do not prove enrollment, vendor authenticity, or a vendor-supported N-to-N+1 update.

For pinned checkout, installer, updater, advisory, and token-handling details, see [CI security](docs/ci-security.md).

## Usage

Add this repository as a flake input and pin a reviewed revision:

```nix
inputs.sentinelone.url = "github:mndfcked/sentinelone-nix";
```

Import the module and keep the service disabled on live hosts:

```nix
imports = [
  inputs.sentinelone.nixosModules.sentinelone
];

services.sentinelone = {
  enable = false;
  vendorManagedUpdates = false;
  sentinelOneManagementTokenPath = "/run/secrets/s1_mgmt_token";
  customerId = "example-customer-id";
};
```

The module overlay provides `pkgs.sentinelone`. The `services.sentinelone.package` option can be overridden for local testing. See the [disabled native configuration example](docs/linux-package-upgrade-decision.md#local-source-example) for the owner-trusted candidate, its provenance limits, and the one-time local fixed-store import.
