# Linux package and upgrade decision

Status: HOLD for the authenticated bootstrap/update pair and the core-upgrade contract.

Date: 2026-10-22

Tracking: [issue #2](https://github.com/mndfcked/sentinelone-nix/issues/2)

## Decision

The owner accepted one locally handed-off Debian package as a bootstrap candidate, version N `26.2.1.24`. This records the candidate and its byte digest. It does not establish independent vendor authenticity, a supported N-to-N+1 path, or readiness for production. No package default changes here. Keep `services.sentinelone.enable = false`.

The authenticated bootstrap/update input pair and exact core-upgrade contract remain on HOLD. Owner acceptance of those complete inputs and contract is pending. Acceptance of the local handoff applies to bootstrap sourcing for this candidate only; it is not a final release process or a substitute for ongoing update inputs.

## Candidate and provenance

| Item | Evidence and limit |
| --- | --- |
| Artifact | `SentinelAgent_linux_x86_64_v26_2_1_24.deb`, package `sentinelagent` `26.2.1.24`, architecture `amd64`; 61,602,192 bytes. Declared Debian dependencies: `coreutils`, `passwd`, `kmod`; these do not establish kernel requirements. |
| Handoff | Owner-reported official vendor package, received from the owner's trusted administrator. The owner accepted that handoff as the trust source. The administrator is unnamed. |
| SHA-256 | `3ff2e97e591135410abafb90e9297cb550738caadf0dd4119b2013574b29e630` |
| Nix SRI | `sha256-P/LpflkRNUEKuvuQ6Sl8tVBzjKrfDdQRmyATV0sp5jA=` |
| Verification performed | Local artifact metadata and byte digest were inspected before this documentation task. A digest checks byte identity when compared; it does not establish who built or signed the package. |
| Verification missing | No independent vendor signature was checked. No independent administrator-supplied digest or vendor attestation is recorded. No N+1 package identity or provenance was supplied. |
| Existing default | [`package.nix` at the reviewed base](https://github.com/mndfcked/sentinelone-nix/blob/6f305bf0147b4283fa966a33396037fadf95e761/package.nix) defines `24.3.3.1` from a third-party URL and a hash. That is the repository's old default, not this selected input or a verified predecessor. No default bump is proposed. |

Nix copies the local `src` into the store; use only permitted stores/builders/caches.

## Local bootstrap example

The module provides `pkgs.sentinelone` through its NixOS overlay. [`module.nix` at the reviewed base](https://github.com/mndfcked/sentinelone-nix/blob/6f305bf0147b4283fa966a33396037fadf95e761/module.nix) defines `services.sentinelone.package`. An owner may test the local candidate in a private configuration:

```nix
services.sentinelone = {
  enable = false;
  package = pkgs.sentinelone.overrideAttrs (_old: {
    version = "26.2.1.24";
    src = /home/joern/Downloads/SentinelAgent_linux_x86_64_v26_2_1_24.deb;
  });
};
```

The external absolute path is host-specific. Pure flake evaluation may reject access to it; local evaluation may require `--impure`. Other machines and remote builders do not automatically have this file.

The digest can be checked against the local file with:

```sh
sha256sum /home/joern/Downloads/SentinelAgent_linux_x86_64_v26_2_1_24.deb
```

Compare the command output with expected SHA-256 `3ff2e97e591135410abafb90e9297cb550738caadf0dd4119b2013574b29e630`. Stop and do not use the file if it differs. A matching digest pins bytes only; it is not independent authenticity evidence.

## Public claims, repository facts, and open checks

| Area | Public vendor material or repository fact | Version-specific status |
| --- | --- | --- |
| LSU and core updates | SentinelOne describes Live Security Updates (LSU) detection logic/models as updated in isolated user mode, separate from core components. It says core components are updated through Upgrade Policy or manually by customers' IT/Security ([source](https://www.sentinelone.com/blog/crowdstrike-global-outage-threat-actor-activity-and-risk-mitigation-strategies/)). | This is product-wide information, not the exact Linux `26.2.1.24` command, version pair, lifecycle, or policies. Those remain unknown and on HOLD. |
| Exact Linux upgrade contract | No Linux-specific command or policy is established by the cited article. | Exact Linux core command, package lifecycle, channel, and policy remain unconfirmed; no vendor-supported `sentinelctl upgrade` syntax is established. |
| Linux kernel model | The vendor's [Linux and Kubernetes agent v22.3 announcement](https://www.sentinelone.com/blog/feature-spotlight-announcing-general-availability-ga-of-linux-and-k8s-agents-v22-3-for-cloud-workload-security/) described that release's agents as user-space/eBPF without kernel modules. | This is historical product information, not proof of support or requirements for `26.2.1.24` or NixOS. Kernel, eBPF, configuration, capabilities, and root/privilege requirements are unknown. |
| NixOS integration | [`module.nix` at the reviewed base](https://github.com/mndfcked/sentinelone-nix/blob/6f305bf0147b4283fa966a33396037fadf95e761/module.nix) runs the store package, uses read-only component bind mounts, and has systemd watchdog/restart settings. The repository README says production automatic upgrades are unsupported. | These are repository behaviors, not vendor support evidence. The read-only mounts may conflict with a vendor updater that replaces files in its install root; the supported interaction is unknown. |
| Security and release status | No version-specific vendor evidence is established by the sources above. | Vendor/owner summaries are needed for advisories and CVEs, release notes, support lifecycle, SBOM and component versions, patch status, and source/license gaps. An absence of known CVEs is not safety approval. The package's source and license availability are not established for this version. |

User-space or eBPF product claims do not establish NixOS support. Source and license availability, version-specific security status, and operational requirements remain unconfirmed.

## Core-upgrade contract

The contract below remains open. It must distinguish core upgrades from LSU content updates and cover both attended and unattended operation where the vendor supports them.

| Contract question | Required evidence |
| --- | --- |
| Command and target | Official Linux command and exact arguments, supported source and target versions, channel, and package format. No command syntax is inferred here. |
| Policy | Supported update policy, eligibility/rollout behavior, and whether unattended core upgrades are supported and intended. |
| Service health | Stop/restart behavior, watchdog interaction, health checks, and recovery after an interrupted or failed update. |
| Installation effects | Package-manager or vendor-script behavior, anti-tamper requirements, privileges, writable install-root expectations, and interaction with this module's read-only binds. |
| State and rollback | Persistent state effects across restart, reboot, Nix rebuild, and recovery. Nix generation rollback does not roll back agent state. |
| LSU | Whether and how LSU content updates are controlled separately from core versions, and the chosen core and LSU policies. |

A Nix package replacement or generation switch is not a substitute for the vendor's supported core-upgrade procedure. Weekly manual package handoffs are not an accepted final update process. [Issue #3](https://github.com/mndfcked/sentinelone-nix/issues/3) remains blocked until the required package/update inputs and contract are accepted; its required runtime proof remains outside this documentation task.

## Inputs needed to leave HOLD

| Owner | Public-safe input |
| --- | --- |
| @mndfcked | Obtain administrator/vendor attestations and a summary of the N+1 package identity, provenance, digest, and trust verification. Record an explicit proceed/hold decision after the gaps are answered. |
| Vendor/TAM, summarized by owner | Official Linux upgrade and LSU contract, version-specific requirements and release/security summaries, plus SBOM/component, patch, source, and license-gap summaries. |
| [Issue #3](https://github.com/mndfcked/sentinelone-nix/issues/3) owner | Later, provide actual N-to-N+1 runtime evidence under that issue. It is not part of this documentation change. |

Only public-safe summaries belong in this record. Restricted documents, installer copies, tokens, private URLs, and raw logs remain outside the repository. Missing evidence keeps the decision on HOLD.
