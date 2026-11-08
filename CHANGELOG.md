# Changelog

## Unreleased

- Fixed native ownership checks for the vendor layout and the initializer's umask: `0022` preserves requested public FHS directory mode `0755` and gives child `dpkg` its normal umask. Vendor-chosen modes and unit policies remain unchanged; controller directories stay `0700` and state files `0600`.

- Completed the private actual-DEB module lifecycle with the integration candidate's Nixpkgs, exact Zen kernel, and runtime inputs. One local same-DEB replacement, real `dpkg` execution, nine selected file replacements, five watchdog windows, reboot, and distinct-closure switch/return passed. All nine explicit public checks passed. [Offline validation](docs/native-offline-validation.md) records revisions, reproduction steps, and limits. Authenticated N-to-N+1 remains unproved.

- Kept strict per-layer read-only VM store validation and requested explicit `ro,nosuid,nodev` bind options across reboots. Added a stacked writable-layer rejection fixture and evaluation coverage for the documented `requireFile` example.

- Native pre-switch checks now inspect the desired configuration's assembled systemd tree as well as the current persistent tree. Actual switches into declared-unit and package-provided drop-in conflicts are refused before activation. Backward compatibility with legacy configurations is not guaranteed; native metadata names remain reserved.

Production automatic updates remain on HOLD.

- Documented the owner-trusted Linux package candidate, its provenance limits, and a disabled native configuration with a one-time private local import. The legacy package default remains unchanged.

- Pinned `actions/checkout` v7.0.1, `cachix/install-nix-action` v31.11.3, and `DeterminateSystems/update-flake-lock` v29 to reviewed commits. Disabled updater OTLP export while keeping its required check-in. Completed the public advisory audit of 145 package names and 216 locked version instances with zero API errors. Documented accepted residual risks and upstream refresh follow-ups; live updater verification remains blocked pending secret provisioning and scope verification.

- Refreshed the fork from its audited upstream baseline.

- Added development-only NixOS VM checks with synthetic runtime fixtures. They do not validate the proprietary native package, enrollment, or production automatic updates.

- Hardened store-managed bootstrap with validated runtime input, a private source-token check, root-owned private staging and generated credentials, a serialized lock, and atomic publication. Mounts and the daemon now require successful initialization.

- Breaking: refuse nonempty unmarked or malformed state and store-package mismatches without automatic migration, deletion, or re-enrollment. Interrupted staging requires operator review. Completion metadata records schema and package identity only, not enrollment health or vendor authenticity.

- Breaking: token and data paths must be absolute runtime strings without Nix store context. Readable token sources are refused without permission changes; private secret-manager symlink targets remain supported.

Production automatic updates remain on HOLD.

- Bootstrap initialization waits for the filesystem backing `dataDir`, preventing state writes to an underlay directory before the mount is ready.
