# sentinelone-nix

## About

Package and module to use SentinelOne on NixOS. Based on the SentinelOne package from [GitLab](https://gitlab.com/gitlab-com/gl-infra/reliability).

## Production status

The production module remains the audited upstream integration: it runs package binaries from the Nix store and uses read-only bind mounts. This branch has not made the integration safe to re-enable. Keep `services.sentinelone.enable` disabled; production automatic upgrades are unsupported.

Deployment blockers remain in the existing code: token-bearing initialization files receive mode `0755`, initialization can leave partial state, the customer ID fallback is defective, and upgrade-state handling remains unresolved. The runtime probe below does not fix those defects or remediate any prior credential exposure. Real vendor-package validation remains pending. Any such test must run in a disposable VM without a token or network access. Production auto-upgrade remains unsupported pending an updater contract, provenance checks, and vendor validation.

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
  };
};
services.sentinelone = {
  sentinelOneManagementTokenPath = config.sops.secrets.s1_mgmt_token.path;
};

```
