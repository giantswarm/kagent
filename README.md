[![CircleCI](https://dl.circleci.com/status-badge/img/gh/giantswarm/kagent/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/giantswarm/kagent/tree/main)

# kagent

Giant Swarm packaging of the upstream [`kagent-dev/kagent`](https://github.com/kagent-dev/kagent)
controller (a Kubernetes-native AI agent runtime). The upstream chart is vendored
flat onto the chart root, with its bundled subcharts (kmcp, kagent-tools, the
declarative agents, oauth2-proxy) under `charts/`, and the kagent CRDs ship in the
chart's own `crds/` directory, so the app **owns its CRDs**.

> The repo and the chart are both named `kagent`, matching the upstream chart and
> the meta-package component. The Giant Swarm fork of the upstream controller lives
> at [`giantswarm/kagent-upstream`](https://github.com/giantswarm/kagent-upstream).

Consumers set upstream keys at the top level (`controller.*`, `ui.*`, ...). See
[UPGRADE.md](UPGRADE.md) for the move from the `0.1.x` wrapper, which nested them
under `kagent.*`.

## Layout

| Path | What |
|---|---|
| `helm/kagent/` | The published GS chart (`kagent`): the upstream chart flattened onto the root, plus the Giant Swarm delta. |
| `helm/kagent/charts/` | The subcharts bundled in the upstream release, vendored as-is. `Chart.yaml` reproduces upstream's dependency list with its `condition:` gates. |
| `helm/kagent/crds/` | The CRDs the app owns: the eight `kagent.dev` CRDs and the kmcp `MCPServer` CRD, each carrying `helm.sh/resource-policy: keep`. |
| `helm/kagent-crds/` | The same CRDs as a chart of their own, for consumers that want Helm to own the CRD lifecycle. Published from the same tag. |
| `vendir.yml` | Vendoring config: the pristine upstream charts into `vendor/` (git-ignored), then the flatten onto the two charts. |
| `sync/` | `sync.sh` re-vendors and re-applies the delta from `sync/patches/`; `verify.sh` is the CI gate. |
| `diffs/` | One patch file per vendored file this repo changes, so a version bump shows the whole delta from upstream. |

## CRD delivery (app-owned CRDs)

The CRDs live in the literal `crds/` directory and are delivered via Flux
`crds: CreateReplace` set on the `kagent` component in the agent-platform
meta-package. `CreateReplace` upgrades the CRDs in place on every release (Helm
otherwise never upgrades `crds/`-dir CRDs), while `crds/`-dir CRDs are never
pruned and the `helm.sh/resource-policy: keep` annotation is defense-in-depth, so
the CRDs, and every CR of those kinds, survive uninstall.

Because the CRDs are server-side `Replace`d and two of the upstream CRDs are very
large, `CreateReplace` (not client-side apply) is required.

The `kagent-crds` chart is the alternative for a consumer that lets Helm own the
CRDs. Install it *instead of* relying on the `crds/` dir, never both.

## Re-vendoring

```bash
make sync          # vendir sync + re-apply the Giant Swarm delta + rewrite diffs/
make verify-sync   # the CI gate: fail when the tree does not match a sync
```

To bump the upstream version, edit the two pins in `vendir.yml` (`kagent` and
`kagent-crds`, always equal), run `make sync`, then regenerate the schemas and
READMEs via pre-commit. Read `diffs/helm__kagent__values.yaml.patch` and port any
new upstream key into `sync/patches/values/values.yaml`. Requires `vendir`,
[mikefarah `yq` v4](https://github.com/mikefarah/yq), `helm` and `python3`.

What the delta is, one patch script per topic under `sync/patches/`:

| Patch | What it does |
|---|---|
| `values` | Copies the repo-owned `values.yaml` over the vendored one and writes the global image `tag` from the `vendir.yml` pin. Every upstream image template coalesces `.Values.tag` first and `.Chart.Version` last; the chart version is this repo's own, so the pin is load-bearing. |
| `chart-label` | Sanitises `helm.sh/chart` and `app.kubernetes.io/version` in upstream's common-labels helper: helm-controller renders the chart version as `X.Y.Z+<digest>`, and `+` is invalid in a label. |
| `team-label` | Adds `application.giantswarm.io/team` to upstream's common-labels helper (app-build-suite `C0001`). |
| `chart-yaml` | Writes `appVersion` and the bundled-subchart dependency list, with upstream's `condition:` gates, from the vendored chart. |
| `crds` | Writes `crds/` and `helm/kagent-crds/templates/` from the vendored `kagent-crds` chart, with `keep` injected. |

`make verify-sync` (the `Verify vendored chart` GitHub workflow) checks the result
without network: the repo-owned `values.yaml` is in place, the tag pin and both
`appVersion` fields equal the vendored version, no rendered template reads
`.Chart.Version` without the tag fallback, the dependency list matches `charts/`
and every entry has a condition, both label fixes and the team label are in the
helper, every CRD carries `keep`, the two CRD delivery paths ship the same
manifests, and the bundled `kagent-tools` renders into the namespace the
`kagent-tool-server` RemoteMCPServer URL names (the ATS smoke installs into
`kagent`, where release namespace and override coincide, so it cannot see the two
drift).

## Installing

This chart is consumed by the agent-platform meta-package. It can also be
installed standalone via the Giant Swarm App Platform once published to the
catalog.

## Credit

- Upstream: <https://github.com/kagent-dev/kagent>
