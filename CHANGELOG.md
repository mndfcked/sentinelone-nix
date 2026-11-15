# Changelog

## Unreleased

Production automatic updates remain on HOLD.

- Added an experimental native vendor-managed backend, selected by `services.sentinelone.vendorManagedUpdates` (default off). It bootstraps once from the package DEB into vendor-owned mutable state, after which the vendor updater owns core versions. Ownership checks follow the vendor layout and the initializer's umask (`0022`); controller directories stay `0700` and state files `0600`. VM store binds are read-only (`ro,nosuid,nodev`) with strict per-layer validation. [Offline validation](docs/native-offline-validation.md) with the actual DEB (real `dpkg`, same-DEB replacement, watchdog windows, reboot, switch/return) passed and records reproduction steps and limits. Authenticated N-to-N+1 remains unproved. Native pre-switch checks inspect the desired configuration's assembled systemd tree as well as the current persistent tree, and refuse actual switches into declared-unit and package-provided drop-in conflicts before activation; native metadata names are reserved, and compatibility with legacy configurations is not guaranteed. Every host that imports the module, legacy and disabled included, gets a `system.preSwitchChecks.sentinelone` guard (python3 in the system closure); on non-native hosts it refuses a switch only when native control or GC-root metadata exists.

- Native mode accepts an optional `sentinelOneManagementTokenPath`. At fresh install the controller reads the runtime file once and passes the token to the seed installer only through the `S1_AGENT_MANAGEMENT_TOKEN` environment variable. The controller never puts the token in the Nix store, on a command line, in its state, or in its output. The vendor installer may still log the token or pass it to its own CLI as an argument; that is outside this project's control. The file must be root-owned, no group or other permissions (for example 0400 or 0600), single-line base64 of a JSON object with `url` and `site_key`. Anything else fails before any change and the error names the path only. Existing state is not re-enrolled; `customerId`, `email`, and `serialNumber` are still rejected. The variable is unverified against the real vendor installer, and an authenticated N-to-N+1 upgrade on a real host remains unverified.

- Documented the owner-trusted Linux package candidate, its provenance limits, and a disabled native configuration with a one-time private local import. The legacy package default remains unchanged.

- Pinned `actions/checkout` v7.0.1, `cachix/install-nix-action` v31.11.3, and `DeterminateSystems/update-flake-lock` v29 to reviewed commits. Disabled updater OTLP export while keeping its required check-in. Completed the public advisory audit of 145 package names and 216 locked version instances with zero API errors. Documented accepted residual risks and upstream refresh follow-ups; live updater verification remains blocked pending secret provisioning and scope verification.

- Refreshed the fork from its audited upstream baseline.

- Added development-only NixOS VM checks with synthetic runtime fixtures. They do not validate the proprietary native package, enrollment, or production automatic updates.

- Hardened store-managed bootstrap with validated runtime input, a private source-token check, root-owned private staging and generated credentials, a serialized lock, and atomic publication. Mounts and the daemon now require successful initialization.

- Breaking: refuse nonempty unmarked or malformed state and store-package mismatches without automatic migration, deletion, or re-enrollment. Interrupted staging requires operator review. Completion metadata records schema and package identity only, not enrollment health or vendor authenticity.

- Breaking: token and data paths must be absolute runtime strings without Nix store context. Readable token sources are refused without permission changes; private secret-manager symlink targets remain supported.

- Fixed the deprecated email/serial-number customer ID fallback and added synthetic VM regressions for bootstrap failure, state preservation, restart, mount dependencies, and customer ID compatibility. Production auto-upgrade and real vendor validation remain unsupported.

- Bootstrap initialization waits for the filesystem backing `dataDir`, preventing state writes to an underlay directory before the mount is ready.
