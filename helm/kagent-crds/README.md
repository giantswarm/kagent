# kagent-crds

Giant Swarm packaging of the upstream kagent.dev CRDs (Agent, AgentHarness, Memory, ModelConfig, ModelProviderConfig, RemoteMCPServer, SandboxAgent, ToolServer) and the kmcp MCPServer CRD as a Helm-managed chart.

**Homepage:** <https://github.com/giantswarm/kagent>

## Source Code

* <https://github.com/giantswarm/kagent>
* <https://github.com/kagent-dev/kagent>

## Values

The chart takes no values. It renders the eight `kagent.dev` CRDs (`Agent`,
`AgentHarness`, `Memory`, `ModelConfig`, `ModelProviderConfig`, `RemoteMCPServer`,
`SandboxAgent`, `ToolServer`) and the kmcp `MCPServer` CRD, each annotated with
`helm.sh/resource-policy: keep` so an uninstall never cascade-deletes the custom
resources. `values.schema.json` stays permissive on purpose: the Giant Swarm app
platform merges cluster values into every App's values, and a strict schema
would reject them.

Install this chart INSTEAD of relying on the `crds/` dir of the `kagent` chart.
Installing both makes two Helm releases own the same cluster-scoped objects.
