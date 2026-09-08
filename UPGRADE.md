# Upgrading

## 0.1.x to 0.2.0

`0.2.0` flattens the chart. The upstream kagent chart used to be a subchart under
`charts/kagent`, so every consumer nested its values under `kagent.*`. The upstream
files now sit at the chart root, so upstream keys move to the top level. The chart
stays on the `0.x` line because upstream kagent is on `0.x` (`appVersion` `0.10.0`).

### What you have to change

Drop the `kagent:` key and lift everything under it up one level:

```yaml
# 0.1.x
kagent:
  controller:
    replicas: 2
  kagent-tools:
    enabled: true

# 0.2.0
controller:
  replicas: 2
kagent-tools:
  enabled: true
```

In the agent-platform meta-package the top-level `kagent:` block was always flat, so
installation overrides there do not move. Only the meta-package's forwarding of the
block changes (agent-platform tracks `0.2.x` from the release that drops `valuesKey`).

`helm show values` of `0.2.0` lists the full set. The chart validates values against
`values.schema.json`, so a leftover `kagent:` key fails the install with
`Additional property kagent is not allowed` rather than being ignored.

### What does not change

- Resource names, the pod selectors and the namespaces. No object is renamed, so the
  upgrade is in place and needs no delete.
- The rendered output for the same effective values, apart from three labels, none
  of them a selector label, and the pod annotations that hash them:
  - `helm.sh/chart` and `app.kubernetes.io/version` now carry this chart's own
    version instead of the upstream one.
  - `application.giantswarm.io/team` is new on every resource.
  - `checksum/configmap`, `checksum/secret` and `checksum/ui-config` on the controller
    and UI pods change with those labels, so both Deployments roll once.
- The image tags. `tag` is pinned to the upstream release the chart vendors, so the
  controller, UI and agent runtime images stay at `0.10.0`.
- CRD delivery. The `crds/` dir is still app-owned, still annotated
  `helm.sh/resource-policy: keep`, and consumers still apply the chart with Flux
  `crds: CreateReplace`.

### New in 0.2.0

- `kagent-crds`, the same CRDs as a chart of their own, published to the same catalog
  and cut from the same tag. It is for consumers that want Helm to own the CRD
  lifecycle. Install it *instead of* relying on the `crds/` dir; installing both makes
  two Helm releases own the same cluster-scoped objects.
