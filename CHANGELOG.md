# Changelog

## Unreleased

- Native pre-switch checks now inspect the desired configuration's assembled systemd tree as well as the current persistent tree. Actual switches into declared-unit and package-provided drop-in conflicts are refused before activation. Backward compatibility with legacy configurations is not guaranteed; native metadata names remain reserved.

- Added the experimental `services.sentinelone.vendorManagedUpdates` native mode. It uses the original `package.src` DEB, requires null token and enrollment-ID settings, and performs initialization and provider registration at boot only. Root commands use a fresh root HOME while the vendor unit keeps its own environment. Transaction roots retain configuration references across failures; persistent systemd conflicts and payload overlap with GC roots are refused. See the [decision and evidence](docs/linux-package-upgrade-decision.md) for the contract and verification limits. Real-artifact module proof remains pending, and production automatic updates remain on HOLD. [#2](https://github.com/mndfcked/sentinelone-nix/issues/2) and [#3](https://github.com/mndfcked/sentinelone-nix/issues/3) remain open and are not fulfilled by this work.

- Documented the owner-trusted Linux package candidate, its provenance limits, and a disabled native configuration with a one-time private local import. The legacy package default remains unchanged.

- Pinned `actions/checkout` v7.0.1, `cachix/install-nix-action` v31.11.3, and `DeterminateSystems/update-flake-lock` v29 to reviewed commits. Disabled updater OTLP export while keeping its required check-in. Completed the public advisory audit of 145 package names and 216 locked version instances with zero API errors. Documented accepted residual risks and upstream refresh follow-ups; live updater verification remains blocked pending secret provisioning and scope verification.

- Refreshed the fork from its audited upstream baseline.

- Added development-only NixOS VM checks with synthetic runtime fixtures. They do not validate the proprietary native package, enrollment, or production automatic updates.

- Hardened store-managed bootstrap with validated runtime input, a private source-token check, root-owned private staging and generated credentials, a serialized lock, and atomic publication. Mounts and the daemon now require successful initialization.

- Breaking: refuse nonempty unmarked or malformed state and store-package mismatches without automatic migration, deletion, or re-enrollment. Interrupted staging requires operator review. Completion metadata records schema and package identity only, not enrollment health or vendor authenticity.

- Breaking: token and data paths must be absolute runtime strings without Nix store context. Readable token sources are refused without permission changes; private secret-manager symlink targets remain supported.

- Fixed the deprecated email/serial-number customer ID fallback and added synthetic VM regressions for bootstrap failure, state preservation, restart, mount dependencies, and customer ID compatibility. Native mode rejects customer-ID enrollment settings. Production automatic updates remain on HOLD, and the current native artifact VM is pending.

- Bootstrap initialization waits for the filesystem backing `dataDir`, preventing state writes to an underlay directory before the mount is ready.
