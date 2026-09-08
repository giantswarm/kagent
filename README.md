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
READMEs via pre-commit. Nothing else is typed: `values.yaml`, the tag pin, the
dependency list, `appVersion` and the CRDs are all written from the vendored
tree. A patch fails loudly when upstream moves one of its anchors; that is the
one case that needs a human. Requires `vendir`,
[mikefarah `yq` v4](https://github.com/mikefarah/yq), `helm` and `python3` with
PyYAML.

What the delta is, one patch script per topic under `sync/patches/`:

| Patch | What it does |
|---|---|
| `values` | Generates `values.yaml` from the vendored upstream file (`generate.py`): the gsoci registry and flat image repositories, `fullnameOverride` and `namespaceOverride`, the kagent-tools namespace and image, the `# @schema` annotations (subchart blocks from the vendored dependency list), and the global image `tag` from the `vendir.yml` pin. Every upstream image template coalesces `.Values.tag` first and `.Chart.Version` last; the chart version is this repo's own, so the pin is load-bearing. |
| `chart-label` | Sanitises `helm.sh/chart` and `app.kubernetes.io/version` in upstream's common-labels helper: helm-controller renders the chart version as `X.Y.Z+<digest>`, and `+` is invalid in a label. |
| `team-label` | Adds `application.giantswarm.io/team` to upstream's common-labels helper (app-build-suite `C0001`). |
| `chart-yaml` | Writes `appVersion` and the bundled-subchart dependency list, with upstream's `condition:` gates, from the vendored chart. |
| `crds` | Writes `crds/` and `helm/kagent-crds/templates/` from the vendored `kagent-crds` chart, with `keep` injected. |

`make verify-sync` (the `Verify vendored chart` GitHub workflow) checks the result
without network: the Giant Swarm defaults are in `values.yaml`, the tag pin and both
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

## Keyless OpenAI-compatible endpoints

A `ModelConfig` with `provider: OpenAI` and an `openAI.baseUrl` that points at a
keyless endpoint (an in-cluster vLLM `InferenceService`, LiteLLM, a corporate
proxy) reconciles to `Accepted`, but every Agent that references it crashloops
at boot:

```
failed to create LLM: OPENAI_API_KEY environment variable is not set
```

The vendored Go ADK runtime requires `OPENAI_API_KEY` for `provider: OpenAI`
even when `baseUrl` is set, and the controller renders no key when
`spec.apiKeySecret` is absent. Until the upstream fix
(<https://github.com/kagent-dev/kagent/pull/2739>) is released and vendored,
ship a placeholder secret and reference it from the `ModelConfig`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vllm-placeholder-key
  namespace: kagent
stringData:
  OPENAI_API_KEY: unused
---
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: vllm
  namespace: kagent
spec:
  provider: OpenAI
  model: <model served by the endpoint>
  apiKeySecret: vllm-placeholder-key
  apiKeySecretKey: OPENAI_API_KEY
  openAI:
    baseUrl: http://<service>.<namespace>.svc/v1
```

The endpoint ignores the key. Tracked in
[#57](https://github.com/giantswarm/kagent/issues/57).

## Credit

- Upstream: <https://github.com/kagent-dev/kagent>
