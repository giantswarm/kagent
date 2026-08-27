[![CircleCI](https://dl.circleci.com/status-badge/img/gh/giantswarm/kagent/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/giantswarm/kagent/tree/main)

# kagent

Giant Swarm packaging of the upstream [`kagent-dev/kagent`](https://github.com/kagent-dev/kagent)
controller (a Kubernetes-native AI agent runtime). This repo vendors the upstream
app chart as a subchart and ships the kagent CRDs itself, so the app **owns its
CRDs** — the agent-platform meta-package no longer needs the shared
`agentic-platform-crds` bundle for kagent.

> The repo and the chart are both named `kagent`, matching the upstream chart and
> the meta-package component. The Giant Swarm fork of the upstream controller lives
> at [`giantswarm/kagent-upstream`](https://github.com/giantswarm/kagent-upstream).

## Layout

| Path | What |
|---|---|
| `helm/kagent/` | The published GS chart (`kagent`). |
| `helm/kagent/charts/kagent/` | The upstream `kagent` app chart, vendored by vendir (pinned in `vendir.lock.yml`). |
| `helm/kagent/crds/` | The CRDs the app owns: the eight `kagent.dev` CRDs (from the kagent tag) and the `kmcp` `MCPServer` CRD (from the matching kmcp tag), each carrying `helm.sh/resource-policy: keep`. |
| `vendir.yml` | Vendoring config (upstream chart version + CRD sources). |

## CRD delivery (app-owned CRDs)

The CRDs live in the literal `crds/` directory and are delivered via Flux
`crds: CreateReplace` set on the `kagent` component in the agent-platform
meta-package. `CreateReplace` upgrades the CRDs in place on every release (Helm
otherwise never upgrades `crds/`-dir CRDs), while `crds/`-dir CRDs are never
pruned and the `helm.sh/resource-policy: keep` annotation is defense-in-depth, so
the CRDs — and every CR of those kinds — survive uninstall. See
[`decisions/2026-06-21-1123-adr-app-owned-crds.md`](https://github.com/giantswarm/agent-platform)
in the lab for the full rationale.

Because the CRDs are server-side `Replace`d and two of the upstream CRDs are very
large, `CreateReplace` (not client-side apply) is required.

## Re-vendoring

```bash
make sync   # vendir sync + re-inject helm.sh/resource-policy: keep into crds/
```

`vendir sync` overwrites `helm/kagent/crds/` with pristine upstream copies, so the
`keep` annotation is re-injected afterwards (it is not present upstream). Helm never
deletes a CRD that ships in a chart's `crds/` directory and does not read
`helm.sh/resource-policy` there, so the annotation is defence in depth for the tools
that do honour it, not what keeps a `helm uninstall` from removing the CRDs. Requires
[mikefarah `yq` v4](https://github.com/mikefarah/yq) on `PATH` (override with
`make sync YQ=/path/to/yq`). To bump the upstream version, edit the pinned refs in
`vendir.yml`, run `make sync`, then `helm dependency update helm/kagent` and
regenerate the schema/README via pre-commit.

`make verify` (also a CircleCI job) checks the result: every kagent version string
agrees with the `vendir.yml` pin, and every vendored CRD carries the `keep`
annotation. A bump that runs `vendir sync` without `make sync` fails there.
`hack/crd-keep.sh` does the injection, `--check` is the gate, and `--self-test`
covers the document shapes the vendored corpus does not currently contain. The
insert is line-oriented, to keep an upstream bump to a one-line diff, so `yq`
reads the result back and the script refuses a document it cannot annotate. It
calls `yq` as an executable, so it needs one on `PATH` (override with `YQ=`).

## Version / image-tag label

Wrapping the upstream chart as a subchart keeps its `.Chart.Version` at the clean
pinned value (e.g. `0.9.9`) even when helm-controller sources this umbrella chart
via `OCIRepository` (the OCI `+digest` is appended to the umbrella version, not the
subchart). This removes the upstream label/tag corruption that previously required
a `postRenderers` kustomize patch and a hard version pin in the meta-package.

## Installing

This chart is consumed by the agent-platform meta-package. It can also be
installed standalone via the Giant Swarm App Platform once published to the
catalog.

## Credit

- Upstream: <https://github.com/kagent-dev/kagent>
