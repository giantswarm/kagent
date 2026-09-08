#!/usr/bin/env python3
"""Write helm/kagent/values.yaml from the vendored upstream values.

Usage: generate.py <vendor values.yaml> <vendor Chart.yaml> <vendir.yml> <output>

The Giant Swarm delta is a fixed set of anchored text replacements on the
upstream file, so comments, ordering and every new upstream key survive a bump
untouched. Each anchor must match exactly once; when upstream reworks a block
the sync fails here instead of publishing a chart that silently lost a default.

What the delta is:

* the global image `tag`, written from the vendir.yml pin. Every upstream image
  template coalesces `.Values.tag` first and `.Chart.Version` last, and the chart
  version is this repo's own, so the pin is load-bearing;
* the Giant Swarm registry and the flat mirror names retagger publishes;
* `fullnameOverride` and `namespaceOverride`, and the kagent-tools namespace that
  must equal it;
* `# @schema` annotations: every bundled subchart block (read from the vendored
  Chart.yaml dependencies) and every upstream block whose full key set is not in
  the defaults is a free-form object. Helm validates a subchart's own defaults,
  merged under its key, against this chart's schema, so anything stricter
  rejects the upstream defaults themselves;
* two spaces before inline comments, which app-build-suite's chart-testing
  yamllint requires.
"""

import re
import sys

import yaml

values_path, chart_path, vendir_path, out_path = sys.argv[1:5]
text = open(values_path, encoding="utf-8").read()


def replace(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"{values_path}: expected exactly one occurrence of\n{old}\nfound {count}. "
            "Re-derive the values delta against the new upstream file."
        )
    text = text.replace(old, new)


vendir = yaml.safe_load(open(vendir_path, encoding="utf-8"))
tag = next(
    c["helmChart"]["version"]
    for d in vendir["directories"] if d["path"] == "vendor"
    for c in d["contents"] if c["path"] == "kagent"
)
subcharts = [d["name"] for d in yaml.safe_load(open(chart_path, encoding="utf-8"))["dependencies"]]

replace(
    "# Default values for kagent\n\n",
    """# Values for the kagent chart, written by sync/patches/values/generate.py from
# the vendored upstream values: the upstream file with the Giant Swarm defaults
# applied (registry, flat image repositories, pinned tag, naming, the
# kagent-tools namespace) and the `# @schema` annotations the values.schema.json
# generator reads. Edit the generator, not this file; `make sync` rewrites it.
#
# Cluster-specific wiring (controller auth mode, metrics env, model providers,
# oauth2-proxy, OTel) stays in the agent-platform meta-package.
#
# Every bundled subchart block is a free-form object in the schema
# (skipProperties; Helm validates the subchart's own defaults, merged under its
# key, against this chart's schema), and so is every upstream block whose full
# key set is not spelled out below, so a consumer can set any upstream key.

""",
)
replace(
    'tag: ""\nregistry: "ghcr.io"\n',
    f"""# Global image tag for the controller, the UI and the agent runtime images the
# controller hands out (IMAGE_TAG, SKILLS_INIT_IMAGE_TAG, GO_IMAGE_TAG). Every
# one of those templates coalesces this key first and .Chart.Version last, and
# the chart version is this repo's own, so the pin is load-bearing. Written
# from the vendir.yml pin; `make verify-sync` fails when the two disagree.
tag: "{tag}"
# Pull kagent images from the Giant Swarm retagged registry. retagger mirrors
# them under flat names (kagent-controller, kagent-app, ...), not the upstream
# kagent-dev/kagent/* hierarchy, so every repository below is the flat name.
registry: gsoci.azurecr.io/giantswarm
""",
)
replace(
    'nameOverride: ""\nfullnameOverride: ""\n',
    """nameOverride: ""
# Pin the release-independent name so the controller Service is always
# `kagent-controller` regardless of the release name.
fullnameOverride: kagent
""",
)
replace(
    '# @default -- `.Release.Namespace`\nnamespaceOverride: ""\n',
    """# @default -- `.Release.Namespace`
# Keep kagent core resources in a dedicated namespace separate from the release
# namespace. Must equal `kagent-tools.namespaceOverride` below.
namespaceOverride: kagent
""",
)
for upstream, flat in [
    ("kagent-dev/kagent/app", "kagent-app"),
    ("kagent-dev/kagent/skills-init", "kagent-skills-init"),
    ("kagent-dev/kagent/golang-adk", "golang-adk"),
    ("kagent-dev/kagent/controller", "kagent-controller"),
    ("kagent-dev/kagent/ui", "kagent-ui"),
]:
    replace(f"    repository: {upstream}\n", f"    repository: {flat}\n")

replace(
    """kagent-tools:
  enabled: true
  nameOverride: tools
""",
    """kagent-tools:
  enabled: true
  nameOverride: tools
  # Keep equal to `namespaceOverride` above. The subchart renders its
  # Deployment, Services and ServiceAccount into its OWN namespaceOverride
  # (default: the release namespace), while this chart's `kagent-tool-server`
  # RemoteMCPServer composes the tool-server URL from THIS chart's namespace
  # (templates/toolserver-kagent.yaml renders
  # `http://<tools fullname>.<kagent namespace>:8084/mcp`). Nothing upstream
  # ties the two together; with a release namespace other than `kagent` the
  # Service lands in the release namespace, the URL does not resolve and the
  # RemoteMCPServer stays Accepted=False. `make verify-sync` renders that layout
  # and fails when the two namespaces disagree.
  namespaceOverride: kagent
""",
)
replace(
    """  tools:
    loglevel: "debug"
    metrics:
      port: 8085""",
    """  tools:
    # The subchart reads its own image keys and does NOT inherit the parent
    # `registry`. Mirror of ghcr.io/kagent-dev/kagent/tools. `tag` stays unset:
    # the subchart coalesces it to its own Chart.Version, which is the vendored
    # kagent-tools version.
    image:
      registry: gsoci.azurecr.io
      repository: giantswarm/kagent-tools
    # ephemeral-storage requests and limits are required because the cluster
    # injects a writable /tmp emptyDir (readOnlyRootFilesystem) without a
    # sizeLimit, which trips require-emptydir-requests-and-limits unless the
    # mounting container declares ephemeral-storage.
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
        ephemeral-storage: 50Mi
      limits:
        cpu: "1"
        memory: 512Mi
        ephemeral-storage: 512Mi
    loglevel: "debug"
    metrics:
      port: 8085""",
)

FREE_FORM_BLOCKS = ["controller", "ui", "database", "providers", "otel", "rbac", "proxy", "substrateWorkerPool"]
for key in subcharts + FREE_FORM_BLOCKS:
    replace(f"\n{key}:\n", f"\n{key}:  # @schema skipProperties: true; additionalProperties: true\n")
for key in ["podSecurityContext", "securityContext"]:
    replace(f"\n{key}:\n", f"\n{key}:  # @schema additionalProperties: true\n")
for key in ["labels", "podLabels", "annotations", "podAnnotations", "nodeSelector"]:
    replace(f"\n{key}: {{}}\n", f"\n{key}: {{}}  # @schema additionalProperties: true\n")


def space_comment(line: str) -> str:
    m = re.match(r"^(.*?\S) #(.*)$", line)
    if not m or line.lstrip().startswith("#"):
        return line
    before = m.group(1)
    if before.count('"') % 2 or before.count("'") % 2:
        return line
    return f"{before}  #{m.group(2)}"


text = "\n".join(space_comment(line) for line in text.split("\n"))
open(out_path, "w", encoding="utf-8").write(text)
