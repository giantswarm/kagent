# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- The vendored CRDs carry `helm.sh/resource-policy: keep` again, as `make sync` and
  the README document, and `make verify` fails when one does not. Metadata only:
  Helm never deletes a CRD that ships in a chart's `crds/` directory, so no
  deletion behaviour changes.
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

[Unreleased]: https://github.com/giantswarm/kagent-app/tree/main
