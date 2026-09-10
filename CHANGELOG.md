# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `kagent-crds` chart, published from this repo and cut from the same tag: the eight `kagent.dev` CRDs and the kmcp `MCPServer` CRD as templated resources with `helm.sh/resource-policy: keep`, for consumers that let Helm own the CRD lifecycle.
- `tag` is pinned to the vendored upstream release (written by `make sync` from the `vendir.yml` pin) and checked by `make verify-sync`. Every upstream image template coalesces `.Values.tag` first and `.Chart.Version` last, and the chart version is this repo's own.
- `helm.sh/chart` and `app.kubernetes.io/version` sanitise `+` and trailing non-alphanumerics, so they stay valid labels when helm-controller appends `+<digest>` to the chart version.
- `application.giantswarm.io/team` on every rendered resource.

### Changed

- Renovate vendir bumps are completed automatically: the sync-from-upstream workflow re-applies the Giant Swarm delta and opens the reviewable PR from `main#update-chart`, so a bump no longer needs manual `make sync` and pre-commit commits. Renovate's own PR waits for Dependency Dashboard approval, so a bump is proposed once.
- The reviewer diffs under `diffs/` are always plain unified patches, independent of the developer's git external diff tool.
- Upstream kagent updated to v0.10.1. Python agents resume correctly after a
  human-in-the-loop pause again: answering an `ask_user` question or approving a
  tool call no longer fails with `Tool 'X' does not require confirmation.` and
  no longer leaves the session with a dangling `tool_use` (kagent-dev/kagent#2731).
- The chart is flattened: the upstream kagent chart sits at the chart root instead of under `charts/kagent`, so upstream keys move from `kagent.*` to the top level (`controller.*`, `ui.*`, `kagent-tools.*`, ...). A leftover `kagent:` key fails schema validation. The rendered output for the same effective values is unchanged apart from `helm.sh/chart` and `app.kubernetes.io/version` (this chart's version), the new `application.giantswarm.io/team` label on every resource, and the `checksum/*` pod annotations that hash them. See UPGRADE.md.
- `Chart.yaml` reproduces upstream's bundled-subchart `dependencies` with their `condition:` gates (`kmcp.enabled`, `kagent-tools.enabled`, `oauth2-proxy.enabled`, the agents), pointing every entry at the vendored copy under `charts/`. `make verify-sync` fails when the list drifts from `charts/` or from the vendored chart.
- The CRDs are vendored from the published upstream `kagent-crds` chart (the same tag as the controller chart) instead of the kagent and kmcp git tags; the kmcp `MCPServer` CRD comes from the `kmcp-crds` subchart bundled in it.
- `vendir.yml` stages the pristine upstream charts into `vendor/` and flattens them onto `helm/kagent` and `helm/kagent-crds`; `sync/sync.sh` (`make sync`) re-applies the Giant Swarm delta from `sync/patches/` and writes `diffs/`; `sync/verify.sh` (`make verify-sync`, the `Verify vendored chart` GitHub workflow) is the CI gate. Replaces `hack/` and the `verify-vendored-tree` CircleCI job.
- Updated `grafana-mcp` to upstream version `v0.10.0`.
- Updated `k8s-agent` to upstream version `v0.10.0`.
- Updated `kgateway-agent` to upstream version `v0.10.0`.
- Updated `istio-agent` to upstream version `v0.10.0`.
- Updated `promql-agent` to upstream version `v0.10.0`.
- Updated `observability-agent` to upstream version `v0.10.0`.
- Updated `argo-rollouts-agent` to upstream version `v0.10.0`.
- Updated `helm-agent` to upstream version `v0.10.0`.
- Updated `cilium-policy-agent` to upstream version `v0.10.0`.
- Updated `cilium-manager-agent` to upstream version `v0.10.0`.
- Updated `cilium-debug-agent` to upstream version `v0.10.0`.
- Updated `kagent` to upstream version `0.10.0`.
- Updated `kagent-crds` to upstream version `0.10.0`.

### Fixed

- The bundled oauth2-proxy pulls its image from the gsoci mirror
  (`oauth2-proxy.image.registry: gsoci.azurecr.io`,
  `oauth2-proxy.image.repository: giantswarm/oauth2-proxy`) instead of the
  subchart default `quay.io/oauth2-proxy/oauth2-proxy`, like every other image
  the chart renders. The subchart composes the image from its own keys and does
  not inherit `registry`; the quay.io default tripped the
  `restrict-image-registries` Kyverno policy (audit) on every
  `kagent-oauth2-proxy` pod and would not pull behind a registry egress
  allowlist. The tag is unchanged (`v<subchart appVersion>`, currently
  v7.15.3, which retagger mirrors), so the upgrade is an image-reference change
  only. `make verify-sync` asserts both keys and the rendered Deployment image;
  the ATS smoke enables oauth2-proxy (placeholder client, OIDC discovery
  skipped) and asserts the `kagent-oauth2-proxy` Deployment runs the mirror and
  becomes available. (#68)

### Removed

- The `kagent.*` values nesting.
- `hack/` (`crd-keep.sh`, `verify-vendored-version.sh`, `verify-tools-namespace.sh`) and the `make verify` targets; `sync/verify.sh` carries the checks.
- The committed `helm/kagent/charts/kagent-0.10.0.tgz`; `helm/kagent/charts/*.tgz` is ignored.
- Render the bundled `kagent-tools` tool server into the `kagent` namespace
  (`kagent.kagent-tools.namespaceOverride: kagent`, equal to
  `kagent.namespaceOverride`). The upstream chart composes the
  `kagent-tool-server` RemoteMCPServer URL from its own namespace
  (`http://kagent-tools.kagent:8084/mcp`) but leaves the subchart's namespace at
  the release namespace, so with a release namespace other than `kagent` -- the
  agent-platform layout -- the Deployment and Services landed in the release
  namespace, the URL did not resolve ("no such host") and the RemoteMCPServer
  stayed `Accepted=False`: agents referencing the built-in tools had none. On
  upgrade Helm deletes the kagent-tools Deployment, Services and ServiceAccount
  in the release namespace and recreates them in `kagent`; the
  ClusterRoleBinding subject follows the ServiceAccount. `make verify` (the
  `verify-vendored-tree` CircleCI job) now renders the chart with release
  namespace `agent-platform` and fails when the tools Service and the
  RemoteMCPServer URL disagree, and the ATS smoke enables `kagent-tools` and
  waits for the RemoteMCPServer to be `Accepted`.
- The ATS smoke now creates a minimal `kagent.dev/v1alpha2` declarative Agent
  (no `runtime`, so the CRD default applies) against the chart's default
  ModelConfig with a fake provider key, asserts the Deployment the controller
  renders for it runs `gsoci.azurecr.io/giantswarm/golang-adk:*`, and waits for
  the Agent's `Ready` condition, failing fast on image-pull errors and dumping
  the `kagent` namespace on failure. The smoke used to check only that the
  controller Deployment is ready, which is why the broken Go ADK image path of
  the 0.10.0 bump (#63) passed CI.
- Map the Go ADK runtime image to the flat gsoci mirror
  (`kagent.controller.goAgentImage.repository: golang-adk`). Upstream 0.10.0 made
  `runtime: go` the default for declarative agents and reads the image from the
  new `controller.goAgentImage` key, whose upstream default is the nested
  `kagent-dev/kagent/golang-adk` path; retagger publishes the mirror as
  `gsoci.azurecr.io/giantswarm/golang-adk`. Without the mapping every new
  declarative agent pod failed with ImagePullBackOff and its Agent never reached
  Ready.
- The vendored CRDs carry `helm.sh/resource-policy: keep` again, as `make sync` and
  the README document, and `make verify` fails when one does not. Metadata only:
  Helm never deletes a CRD that ships in a chart's `crds/` directory, so no
  deletion behaviour changes.
- Repository renamed from `kagent-app` to `kagent`; chart name and OCI
  coordinates unchanged.
- Set `appVersion` to the upstream release the chart actually vendors (`0.9.12`).
  It was left behind on `0.9.11` when the vendir pin was bumped, because nothing
  tracked or verified it.
- The upstream kagent version is now typed in exactly one place: the `vendir.yml`
  pin that Renovate edits. `make sync` propagates it into the chart metadata, and
  `make verify` -- a new CircleCI job -- fails the build when any copy
  (`vendir.lock.yml`, the vendored subchart, `appVersion`, the `file://`
  dependency, `Chart.lock`, the CRD git ref) disagrees with it. `helm lint`,
  `helm template` and `helm package` all pass on that kind of drift, so a bump
  that never ran `make sync` could ship a chart claiming one upstream release and
  containing another.
- Renovate groups the two `vendir.yml` kagent pins -- the published OCI chart and
  the git tag the CRDs are vendored from -- into a single PR, and never proposes
  an upstream prerelease (upstream tags `0.10.0-rc*` and marks the newest rc as
  the GitHub "Latest" release).
- Drop the `kagent.tag` default. As a subchart, the upstream chart already
  coalesces its image tag to its own `.Chart.Version`, which is the clean
  vendored version, so the pin was a second copy of the version with no effect on
  the rendered output.
- Source the bundled `kagent-tools` tool-server image from
  `gsoci.azurecr.io/giantswarm/kagent-tools` (mirror of
  `ghcr.io/kagent-dev/kagent/tools`) and declare `ephemeral-storage`
  requests/limits on its container, clearing the `restrict-image-registries`
  and `require-emptydir-requests-and-limits` Kyverno audit warnings in the
  `agentic-platform` namespace (giantswarm/giantswarm#36885). Overrides nest
  under `kagent.kagent-tools.tools.*` — the keys the subchart actually reads;
  it does not inherit the parent `kagent.registry`.
- Initial Giant Swarm packaging of the upstream `kagent-dev/kagent` controller
  chart, vendored as a subchart via vendir (pinned `0.9.9`).
- App-owned CRDs: the eight `kagent.dev` CRDs and the `kmcp` `MCPServer` CRD ship
  in `helm/kagent/crds/` with `helm.sh/resource-policy: keep`, delivered via Flux
  `crds: CreateReplace` from the agentic-platform meta-package.

[Unreleased]: https://github.com/giantswarm/kagent/tree/main
