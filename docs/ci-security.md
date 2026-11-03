# CI security

## Workflow permissions and secret handling

Both `.github/workflows/ci.yaml` and `.github/workflows/update-flake-lock.yaml` set workflow-level `permissions: {}` and grant their jobs `contents: read`. Both checkout steps set `persist-credentials: false`.

The lock updater runs on its weekly schedule or through `workflow_dispatch`. Its preflight passes only a boolean indicating whether `FLAKE_LOCK_TOKEN` exists, then fails with a fixed error if it is absent. The secret value goes only to the updater action's `token` input. There is no fallback to `GITHUB_TOKEN`, and the writer token is not set in workflow or job environment variables.

Track secret provisioning, token-scope confirmation, and evidence from an actual updater workflow run in the [implementation PR #7](https://github.com/mndfcked/sentinelone-nix/pull/7). The preflight checks only whether `FLAKE_LOCK_TOKEN` exists. Before relying on the updater, the operator must confirm that the fine-grained token is restricted to this repository and has only the permissions listed below; GitHub grants Metadata read implicitly. A successful branch push and PR creation show that the token can perform those actions, but do not prove it lacks additional permissions. Never read the token value or include token bytes in logs, issues, or chat.

Use a fine-grained token limited to this repository, with Contents read/write and Pull requests read/write; GitHub grants Metadata read implicitly. Do not grant other scopes. The Contents write permission can change repository files beyond `flake.lock`.

## Pinned actions

Every action reference in these workflows is an exact commit SHA. The selected release and source links are:

| Action | Release | Pinned commit and action metadata |
| --- | --- | --- |
| `actions/checkout` | v7.0.1 | [commit](https://github.com/actions/checkout/commit/3d3c42e5aac5ba805825da76410c181273ba90b1), [package-lock.json](https://github.com/actions/checkout/blob/3d3c42e5aac5ba805825da76410c181273ba90b1/package-lock.json), [dist/index.js](https://github.com/actions/checkout/blob/3d3c42e5aac5ba805825da76410c181273ba90b1/dist/index.js), [action.yml](https://github.com/actions/checkout/blob/3d3c42e5aac5ba805825da76410c181273ba90b1/action.yml) |
| `cachix/install-nix-action` | v31.11.3 | [commit](https://github.com/cachix/install-nix-action/commit/75c75c31ebece974e48ebc36b4ad125bd97bd97b), [action.yml](https://github.com/cachix/install-nix-action/blob/75c75c31ebece974e48ebc36b4ad125bd97bd97b/action.yml) |
| `DeterminateSystems/update-flake-lock` | v29 | [release](https://github.com/DeterminateSystems/update-flake-lock/releases/tag/v29), [signed commit](https://github.com/DeterminateSystems/update-flake-lock/commit/da03c0f078bc4b2c37ee4f7e072d34bf8f188bb3), [package-lock.json](https://github.com/DeterminateSystems/update-flake-lock/blob/da03c0f078bc4b2c37ee4f7e072d34bf8f188bb3/package-lock.json), [dist/index.js](https://github.com/DeterminateSystems/update-flake-lock/blob/da03c0f078bc4b2c37ee4f7e072d34bf8f188bb3/dist/index.js), [action.yml](https://github.com/DeterminateSystems/update-flake-lock/blob/da03c0f078bc4b2c37ee4f7e072d34bf8f188bb3/action.yml) |

The selected Cachix commit's PGP signature and the moving `v31` annotated SSH tag were verified. The selected `v31.11.3` tag is lightweight; no tag signature was verified, and no historical evidence establishes that tags have never moved. The installer downloads the Nix 2.35.4 installer over HTTPS without wrapper-level checksum or signature verification. The operator accepted that bootstrap trust risk.

Reviewed changes include core execution dependencies and OpenTelemetry dependencies added through `@determinate-systems/detsys-ts@2.1.3`. The optional signing path now uses OpenPGP 6.3.0 instead of 6.1.0; signing is disabled by default.

## Advisory audit and accepted risks

The public advisory audit covered 145 package names and 216 locked version instances, with zero API errors. It found advisory-affected locked versions, including Undici 6.27.0 in checkout, plus Busboy, UUID, and Handlebars in the audited action dependency sets. The audit did not establish a reachable exploit in these fixed workflows. Checkout uses trusted GitHub endpoints; the reviewed flow does not configure custom TLS or proxy handling or use WebSocket or EventSource paths associated with the advisories. These findings do not mean the affected dependencies are clean or safe for other callers.

The decision is SHIP-WITH-CAUTIONS. Accepted residual risks and upstream refresh follow-ups are tracked in [#4](https://github.com/mndfcked/sentinelone-nix/issues/4). Refresh and re-audit the action dependency trees when upstream releases become available. Review installer integrity controls and release-tag history again if upstream provides stronger verification.

## Updater telemetry and review

Only the updater action step sets `OTEL_SDK_DISABLED: "true"`. This disables OTLP export to `otel.determinate.systems`; it does not disable the check-in. The pinned updater's runtime dependency [`@determinate-systems/detsys-ts@2.1.3`](https://github.com/DeterminateSystems/detsys-ts/blob/99d5b05518240632c090b3c3093be30cac088e8c/src/index.ts) performs a required check-in containing a runner-tracking UUID; hashed repository, workflow, and run identifiers; action, project, and event values; and OS, architecture, and version. Its [telemetry source](https://github.com/DeterminateSystems/detsys-ts/blob/99d5b05518240632c090b3c3093be30cac088e8c/src/telemetry.ts) contains the OTLP behavior. The reviewed payload contains no write token or arbitrary environment variables.

Keep the existing updater PR workflow. Review the full action source, dependency manifest/lock changes, generated `flake.lock`, advisories, and outbound endpoints before merging an update PR. The action does not auto-merge or publish build artifacts.

## Synthetic policy check

Run from the repository root:

```sh
nix build path:.#checks.x86_64-linux.ci-policy --no-link --no-write-lock-file -L
```

The check covers workflow and job permission maps, checkout credential persistence, the exact approved action commit references, updater token routing, missing-token preflight behavior, and updater-only OTLP suppression. It does not validate the configured token's scope or third-party action runtime behavior.
