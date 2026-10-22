# Changelog

## Unreleased

- Documented the locally handed-off Linux package candidate, provenance limits, and the pending authenticated package/update and core-upgrade contract.
- Refreshed the fork from its audited upstream baseline.
- Added a development-only NixOS VM check with source-built synthetic runtime fixtures. It does not implement production automatic updates or validate vendor binaries.
- Hardened store-managed bootstrap with validated runtime input, a private source-token check, root-owned private staging and generated credentials, a serialized lock, and atomic publication. Mounts and the daemon now require successful initialization.
- Breaking: refuse nonempty unmarked or malformed state and store-package mismatches without automatic migration, deletion, or re-enrollment. Interrupted staging requires operator review. Completion metadata records schema and package identity only, not enrollment health or vendor authenticity.
- Breaking: token and data paths must be absolute runtime strings without Nix store context. Readable token sources are refused without permission changes; private secret-manager symlink targets remain supported.
- Fixed the deprecated email/serial-number customer ID fallback and added synthetic VM regressions for bootstrap failure, state preservation, restart, mount dependencies, and customer ID compatibility. Production auto-upgrade and real vendor validation remain unsupported.
- Bootstrap initialization waits for the filesystem backing `dataDir`, preventing state writes to an underlay directory before the mount is ready.
