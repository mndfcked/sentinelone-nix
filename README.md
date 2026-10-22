# sentinelone-nix

## About

Package and module to use SentinelOne on NixOS. Based on the SentinelOne package from [GitLab](https://gitlab.com/gitlab-com/gl-infra/reliability).

## Production status

The store-managed module still runs package binaries from the immutable Nix store and uses read-only component bind mounts. Bootstrap hardening does not make the integration ready to re-enable. Keep `services.sentinelone.enable` disabled; production automatic upgrades remain unsupported.

Bootstrap now protects generated credentials, publishes initialized state atomically, and handles the legacy customer ID fallback. It refuses unknown existing state and package mismatches. These changes do not remediate any prior credential exposure. A vendor updater contract, update provenance checks, and real vendor-package validation remain deployment blockers. Any vendor-package smoke test must run in a disposable VM without a token or network access.

## Store-managed bootstrap

Initialization validates the package seed and runtime token before creating persistent bootstrap state. It copies into a root-owned `0700` staging directory beside `dataDir`, preserves copied directory permissions and executable bits, and writes generated credential files as root-owned `0600` files. A serialized root-only lock sits outside the installation. The helper publishes the completed tree with a same-filesystem rename. The base mount, read-only component mounts, and daemon all require successful initialization.

`sentinelOneManagementTokenPath` and `dataDir` accept canonical absolute runtime strings outside `/nix/store`. Nix path values and strings with store context are rejected to prevent copying credentials or persistent data into the store. A secret manager's runtime `.path` string remains supported. The token source must be a regular file with no group/other permissions, such as mode `0400` or `0600`. Runtime secret-manager symlinks and private files owned by the configured secret recipient are supported. The initializer never fixes the source file's permissions or ownership.

The token must contain single-line base64 encoding of one JSON object with nonempty string `url` and `site_key` fields. One trailing newline in the token file is accepted. Embedded token newlines and control characters in decoded fields are rejected. Token bytes are read only at initialization and never passed through command arguments, environment variables, or diagnostics.

The destination may be absent or an empty root-owned directory. Its parent must already exist. The destination and its ancestors must be real root-owned directories without group/other write access; symlinks and nested mounts are refused. The base bind mount uses private propagation so component mounts do not appear inside the persistent source tree.

### Existing state and package changes

This is a breaking change for existing installations: nonempty state without a valid `.sentinelone-bootstrap.json` marker is refused unchanged. Legacy or partial installations are never adopted, deleted, migrated, or re-enrolled automatically. For example, an old unmarked `/var/lib/sentinelone` prevents the daemon and its mounts from starting. Inspect the refusal with:

```sh
journalctl -u sentinelone-init.service
```

Preserve the existing tree and request an explicit operator migration or upgrade plan. Do not delete state or add a marker to bypass the refusal. Interrupted staging directories also require operator review; the helper only cleans staging created by its own invocation.

The marker records a schema and the exact store package identity. A matching marker permits startup without rereading the original token, including after enrollment consumes its bootstrap files. A different package identity or malformed marker prevents startup without changing existing contents, permissions, or ownership. The marker does not verify a vendor signature, enrollment health, or the installed vendor version.

### Bootstrap regression checks

Run each check separately from the repository root:

```sh
nix build path:.#checks.x86_64-linux.bootstrap --no-link --no-write-lock-file -L
nix build path:.#checks.x86_64-linux.vmtest --no-link --no-write-lock-file -L
```

These checks use synthetic packages and fake runtime tokens. They cover credential confidentiality, failed initialization and retry, preservation of refused state, marker/package compatibility, service and mount dependencies, and modern and deprecated customer ID options. The fixtures do not validate real vendor enrollment or updates.

## Development runtime probe

Run from the repository root:

```sh
nix build path:.#checks.x86_64-linux.vendor-runtime --no-link --no-write-lock-file -L
```

The check builds unpatched, source-built distro-style ELF fixtures and shared libraries, then runs them in a NixOS VM. It exercises the conventional `/lib64/ld-linux-x86-64.so.2` interpreter with explicit systemd `NIX_LD` and `NIX_LD_LIBRARY_PATH`, and checks direct, bundled, transitive, and loader-fallback library resolution and precedence. It also checks distro-style and trusted Nix-packaged child execution, confirms the service and its distro child share the VM's PID and mount namespaces, and expects failure when a required SONAME filename is missing. A synthetic A-to-B executable replacement remains B after service restart and VM reboot. An admin fixture succeeds after the service is stopped.

Without the explicit `NIX_LD` variables, the distro-style fixture still executes through the global fallback but selects a different library (`941` instead of the expected `45`). This confirms the need for the explicit service environment in this setup, not general ELF compatibility.

The check does not run the production initializer or updater, switch a NixOS generation, or validate real SentinelOne binaries, enrollment, eBPF, Live Security Update, or update signatures.

## Usage

To use this module, add it to your flake inputs as

```
inputs.sentinelone.url = "github:mndfcked/sentinelone-nix";
```

Pin a reviewed revision before deployment.

Then, import and use the module in your NixOS configuration as

```
imports = [
    inputs.sentinelone.nixosModules.sentinelone
];
services.sentinelone = {
  enable = false;
  sentinelOneManagementTokenPath = "/run/secrets/s1_mgmt_token";
  customerId = "example-customer-id";
  package = pkgs.sentinelone.overrideAttrs (old: {
    version = "sentinelone.package.version"; 
    src = pkgs.fetchurl {
        url = "https://url-to-sentinelone-package.deb";
        hash = "sentinelone-hash";
    };
  });
};
```

overriding `package` to point to a URL where a SentinelOne `deb` is available.

`sentinelOneManagementTokenPath` could be from a [sops-nix](https://github.com/Mic92/sops-nix) secret such as

```
sops = {
  secrets.s1_mgmt_token = {
    sopsFile = ../../secrets/sentinelone.yaml;
    mode = "0600";
  };
};
services.sentinelone = {
  sentinelOneManagementTokenPath = config.sops.secrets.s1_mgmt_token.path;
};

```
