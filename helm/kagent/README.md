# kagent

Giant Swarm packaging of the upstream kagent-dev/kagent controller (Kubernetes-native AI agent runtime). The upstream app chart is vendored as a subchart; the kagent.dev and kmcp CRDs ship in this chart's crds/ directory so the app owns its CRDs (delivered via Flux CreateReplace).

**Homepage:** <https://github.com/giantswarm/kagent>

## Source Code

* <https://github.com/giantswarm/kagent>
* <https://github.com/kagent-dev/kagent>

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| file://charts/kagent | kagent | 0.9.12 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| kagent.fullnameOverride | string | `"kagent"` |  |
| kagent.registry | string | `"gsoci.azurecr.io/giantswarm"` |  |
| kagent.controller.image.repository | string | `"kagent-controller"` |  |
| kagent.controller.agentImage.repository | string | `"kagent-app"` |  |
| kagent.controller.skillsInitImage.repository | string | `"kagent-skills-init"` |  |
| kagent.ui.image.repository | string | `"kagent-ui"` |  |
| kagent.namespaceOverride | string | `"kagent"` |  |
| kagent.kagent-tools.tools.image.registry | string | `"gsoci.azurecr.io"` |  |
| kagent.kagent-tools.tools.image.repository | string | `"giantswarm/kagent-tools"` |  |
| kagent.kagent-tools.tools.resources.requests.cpu | string | `"100m"` |  |
| kagent.kagent-tools.tools.resources.requests.memory | string | `"128Mi"` |  |
| kagent.kagent-tools.tools.resources.requests.ephemeral-storage | string | `"50Mi"` |  |
| kagent.kagent-tools.tools.resources.limits.cpu | string | `"1"` |  |
| kagent.kagent-tools.tools.resources.limits.memory | string | `"512Mi"` |  |
| kagent.kagent-tools.tools.resources.limits.ephemeral-storage | string | `"512Mi"` |  |
