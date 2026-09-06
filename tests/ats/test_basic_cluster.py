"""ATS smoke for the kagent umbrella chart.

Two things are proven on the kind cluster ATS installs the chart into:

  1. the kagent-controller Deployment comes up (test_pods_available);
  2. the controller can run an Agent (test_declarative_agent_reaches_ready):
     a minimal `kagent.dev/v1alpha2` declarative Agent against the chart's
     default ModelConfig reaches `Ready`, and the Deployment the controller
     renders for it runs the Go ADK runtime image from the flat gsoci mirror.

The second test exists because the first one cannot see the class of bug
upstream 0.10.0 shipped into this chart (giantswarm/kagent#63): declarative
agents default to `runtime: go` and the controller reads that image from
`controller.goAgentImage`, whose upstream default is a nested repository path
the retagger mirror does not publish. The controller stayed healthy, every new
Agent sat in ImagePullBackOff, and CI stayed green. The Agent here sets no
`runtime`, so the CRD default applies -- exactly the path that broke.

The model provider is fake: the smoke never calls a model. `Ready` means the
controller accepted the Agent, rendered its Deployment and that Deployment has
an available replica.
"""

import logging
import time
from typing import Any, Dict, Iterator, List, Optional

import pykube
import pytest
import yaml
from pytest_helm_charts.clusters import Cluster
from pytest_helm_charts.k8s.deployment import wait_for_deployments_to_run

logger = logging.getLogger(__name__)

deployment_name = "kagent-controller"
namespace_name = "kagent"

timeout: int = 180

KAGENT_API_VERSION = "kagent.dev/v1alpha2"
# The ModelConfig the upstream chart renders from `providers.default`
# (`kagent.defaultModelConfigName` in its _helpers.tpl).
MODEL_CONFIG_NAME = "default-model-config"
AGENT_NAME = "ats-smoke-agent"
FAKE_API_KEY = "ats-smoke-fake-key"
# retagger publishes every kagent image flat under gsoci.azurecr.io/giantswarm
# (images/renamed-kagent.yaml); the Go ADK runtime image is the bare
# `golang-adk`, which is what `kagent.controller.goAgentImage.repository` maps.
GO_ADK_IMAGE_PREFIX = "gsoci.azurecr.io/giantswarm/golang-adk:"
MODEL_CONFIG_TIMEOUT = 120
AGENT_DEPLOYMENT_TIMEOUT = 120
AGENT_READY_TIMEOUT = 600
# Container waiting reasons that never resolve on their own: fail right away
# with the reason instead of sitting out the Ready timeout.
IMAGE_PULL_FAILURES = {"ErrImagePull", "ImagePullBackOff", "InvalidImageName"}


@pytest.mark.smoke
def test_api_working(kube_cluster: Cluster) -> None:
    """Test that we can connect to the Kubernetes API."""
    assert kube_cluster.kube_client is not None
    assert len(pykube.Node.objects(kube_cluster.kube_client)) >= 1


@pytest.fixture(scope="module")
def deployment(request, kube_cluster: Cluster) -> List[pykube.Deployment]:
    logger.info("Waiting for kagent-controller deployment..")

    deployment_ready = wait_for_deployment(kube_cluster)

    logger.info("kagent-controller deployment looks satisfied..")

    return deployment_ready


def wait_for_deployment(kube_cluster: Cluster) -> List[pykube.Deployment]:
    deployments = wait_for_deployments_to_run(
        kube_cluster.kube_client,
        [deployment_name],
        namespace_name,
        timeout,
    )
    return deployments


@pytest.mark.smoke
@pytest.mark.upgrade
@pytest.mark.flaky(reruns=1, reruns_delay=15)
def test_pods_available(kube_cluster: Cluster, deployment: List[pykube.Deployment]):
    for s in deployment:
        assert int(s.obj["status"]["readyReplicas"]) == int(
            s.obj["spec"]["replicas"])


# ---------------------------------------------------------------------------
# Declarative Agent smoke
# ---------------------------------------------------------------------------


def _kagent_type(kube_client: pykube.HTTPClient, kind: str) -> Any:
    """pykube class for a kagent.dev/v1alpha2 kind (resolved via API discovery,
    so it needs the CRD to be served -- which the chart install guarantees)."""
    return pykube.object_factory(kube_client, KAGENT_API_VERSION, kind)


def _condition(obj: Dict[str, Any], cond_type: str) -> Optional[Dict[str, Any]]:
    for cond in obj.get("status", {}).get("conditions") or []:
        if cond.get("type") == cond_type:
            return cond
    return None


def _conditions_summary(obj: Dict[str, Any]) -> str:
    conds = obj.get("status", {}).get("conditions") or []
    if not conds:
        return "no conditions yet"
    return "; ".join(
        f"{c.get('type')}={c.get('status')} ({c.get('reason', '')}: {c.get('message', '')})"
        for c in conds
    )


@pytest.fixture(scope="module")
def provider_secret(
    kube_cluster: Cluster, deployment: List[pykube.Deployment]
) -> Iterator[Optional[str]]:
    """The API-key Secret the default ModelConfig references, with a fake key.

    tests/ats/values.yaml sets a placeholder `apiKey`, so the chart itself
    renders that Secret and this fixture only confirms it is there. Should the
    values ever stop doing that, the fixture creates the Secret instead, so the
    Agent smoke keeps testing the controller rather than the values file.
    Yields the Secret name (None when the ModelConfig's provider needs no key).
    """
    kube_client = kube_cluster.kube_client
    model_config = (
        _kagent_type(kube_client, "ModelConfig")
        .objects(kube_client, namespace=namespace_name)
        .get_by_name(MODEL_CONFIG_NAME)
    )
    spec = model_config.obj["spec"]
    secret_name = spec.get("apiKeySecret")
    if not secret_name:
        logger.info(
            "ModelConfig %s (provider %s) references no API-key Secret",
            MODEL_CONFIG_NAME,
            spec.get("provider"),
        )
        yield None
        return

    secret_key = spec.get("apiKeySecretKey") or f"{spec['provider'].upper()}_API_KEY"
    secrets = pykube.Secret.objects(kube_client, namespace=namespace_name)
    created = False
    if secrets.get_or_none(name=secret_name) is not None:
        logger.info(
            "provider Secret %s/%s exists (rendered by the chart from the "
            "placeholder apiKey in tests/ats/values.yaml)",
            namespace_name,
            secret_name,
        )
    else:
        logger.info(
            "creating provider Secret %s/%s with a fake %s for ModelConfig %s",
            namespace_name,
            secret_name,
            secret_key,
            MODEL_CONFIG_NAME,
        )
        pykube.Secret(
            kube_client,
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": secret_name, "namespace": namespace_name},
                "type": "Opaque",
                "stringData": {secret_key: FAKE_API_KEY},
            },
        ).create()
        created = True

    yield secret_name

    if created:
        try:
            kube_cluster.kubectl(
                f"-n {namespace_name} delete secret {secret_name} --ignore-not-found",
                output_format="",
            )
        except Exception as exc:  # cleanup must never mask a test result
            logger.warning("deleting Secret %s failed: %s", secret_name, exc)


@pytest.fixture(scope="module")
def smoke_agent(
    kube_cluster: Cluster, provider_secret: Optional[str]
) -> Iterator[str]:
    """A minimal declarative Agent. No `runtime`: the CRD default decides which
    ADK image the controller renders, which is the case that broke."""
    agent = yaml.safe_dump(
        {
            "apiVersion": KAGENT_API_VERSION,
            "kind": "Agent",
            "metadata": {"name": AGENT_NAME, "namespace": namespace_name},
            "spec": {
                "description": "ATS smoke agent (never talks to a model)",
                "type": "Declarative",
                "declarative": {
                    "modelConfig": MODEL_CONFIG_NAME,
                    "systemMessage": "You are the ATS smoke agent.",
                },
            },
        }
    )
    kube_cluster.kubectl("apply", std_input=agent, output_format="")
    yield AGENT_NAME
    try:
        kube_cluster.kubectl(
            f"-n {namespace_name} delete agents.kagent.dev {AGENT_NAME} "
            "--ignore-not-found --wait=false",
            output_format="",
        )
    except Exception as exc:  # cleanup must never mask a test result
        logger.warning("deleting Agent %s failed: %s", AGENT_NAME, exc)


def wait_for_model_config_accepted(
    kube_cluster: Cluster, timeout_seconds: int = MODEL_CONFIG_TIMEOUT
) -> None:
    """The controller accepts the default ModelConfig (it resolved the provider
    Secret). Failing here, not at the Agent, names the actual problem."""
    kube_client = kube_cluster.kube_client
    model_configs = _kagent_type(kube_client, "ModelConfig").objects(
        kube_client, namespace=namespace_name
    )
    deadline = time.monotonic() + timeout_seconds
    obj: Dict[str, Any] = {}
    while time.monotonic() < deadline:
        obj = model_configs.get_by_name(MODEL_CONFIG_NAME).obj
        accepted = _condition(obj, "Accepted")
        if accepted is not None and accepted.get("status") == "True":
            logger.info("ModelConfig %s is Accepted", MODEL_CONFIG_NAME)
            return
        time.sleep(5)
    raise AssertionError(
        f"ModelConfig {namespace_name}/{MODEL_CONFIG_NAME} not Accepted after "
        f"{timeout_seconds}s: {_conditions_summary(obj)}"
    )


def _agent_deployments(kube_client: pykube.HTTPClient) -> List[pykube.Deployment]:
    """Deployments the controller owns on behalf of the smoke Agent (looked up
    by ownerReference, so the controller's naming scheme is not assumed)."""
    return [
        dep
        for dep in pykube.Deployment.objects(kube_client, namespace=namespace_name)
        if any(
            ref.get("kind") == "Agent" and ref.get("name") == AGENT_NAME
            for ref in dep.obj["metadata"].get("ownerReferences") or []
        )
    ]


def wait_for_agent_deployment(
    kube_cluster: Cluster, timeout_seconds: int = AGENT_DEPLOYMENT_TIMEOUT
) -> pykube.Deployment:
    kube_client = kube_cluster.kube_client
    agents = _kagent_type(kube_client, "Agent").objects(
        kube_client, namespace=namespace_name
    )
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        deps = _agent_deployments(kube_client)
        if deps:
            assert len(deps) == 1, (
                f"expected one Deployment owned by Agent {AGENT_NAME}, found "
                f"{sorted(d.name for d in deps)}"
            )
            logger.info("controller rendered Deployment %s for Agent %s", deps[0].name, AGENT_NAME)
            return deps[0]
        time.sleep(5)
    agent = agents.get_or_none(name=AGENT_NAME)
    raise AssertionError(
        f"the controller rendered no Deployment for Agent {namespace_name}/{AGENT_NAME} "
        f"within {timeout_seconds}s; Agent conditions: "
        f"{_conditions_summary(agent.obj) if agent else 'Agent not found'}"
    )


def assert_go_adk_image(agent_deployment: pykube.Deployment) -> None:
    """The agent runs the Go ADK runtime image from the flat gsoci mirror.

    A wrong repository path shows up as ImagePullBackOff only minutes later;
    this names the misconfiguration the moment the Deployment exists.
    """
    images = [
        c["image"]
        for c in agent_deployment.obj["spec"]["template"]["spec"].get("containers") or []
    ]
    assert any(image.startswith(GO_ADK_IMAGE_PREFIX) for image in images), (
        f"Deployment {namespace_name}/{agent_deployment.name} runs {images}; expected "
        f"the Go ADK runtime image {GO_ADK_IMAGE_PREFIX}* -- the upstream chart "
        "defaults declarative agents to runtime: go and renders that image from "
        "controller.goAgentImage, so kagent.controller.goAgentImage.repository in "
        "helm/kagent/values.yaml has to stay the flat mirror name `golang-adk` "
        "(giantswarm/kagent#63)"
    )
    logger.info("agent image is %s", images)


def _container_statuses(pod: pykube.Pod) -> List[Dict[str, Any]]:
    status = pod.obj.get("status", {})
    return list(status.get("initContainerStatuses") or []) + list(
        status.get("containerStatuses") or []
    )


def _pods_summary(pods: List[pykube.Pod]) -> str:
    if not pods:
        return "no pods"
    parts = []
    for pod in pods:
        waiting = [
            f"{cs['name']}:{cs['state']['waiting'].get('reason', 'Waiting')}"
            for cs in _container_statuses(pod)
            if "waiting" in cs.get("state", {})
        ]
        parts.append(
            f"{pod.name} phase={pod.obj.get('status', {}).get('phase')}"
            + (f" waiting={waiting}" if waiting else "")
        )
    return "; ".join(parts)


def wait_for_agent_ready(
    kube_cluster: Cluster,
    agent_deployment: pykube.Deployment,
    timeout_seconds: int = AGENT_READY_TIMEOUT,
) -> None:
    """Poll the Agent's Ready condition. An image-pull failure on one of its
    pods fails the wait immediately with the kubelet's reason."""
    kube_client = kube_cluster.kube_client
    agents = _kagent_type(kube_client, "Agent").objects(
        kube_client, namespace=namespace_name
    )
    selector = agent_deployment.obj["spec"]["selector"]["matchLabels"]
    deadline = time.monotonic() + timeout_seconds
    polls = 0
    agent_obj: Dict[str, Any] = {}
    pods: List[pykube.Pod] = []
    while time.monotonic() < deadline:
        agent_obj = agents.get_by_name(AGENT_NAME).obj
        ready = _condition(agent_obj, "Ready")
        if ready is not None and ready.get("status") == "True":
            logger.info("Agent %s is Ready: %s", AGENT_NAME, _conditions_summary(agent_obj))
            return
        pods = list(
            pykube.Pod.objects(kube_client, namespace=namespace_name).filter(
                selector=selector
            )
        )
        for pod in pods:
            for cs in _container_statuses(pod):
                waiting = cs.get("state", {}).get("waiting") or {}
                if waiting.get("reason") in IMAGE_PULL_FAILURES:
                    raise AssertionError(
                        f"pod {namespace_name}/{pod.name} container {cs['name']} "
                        f"cannot pull {cs.get('image')}: {waiting['reason']}: "
                        f"{waiting.get('message', '')}"
                    )
        polls += 1
        if polls % 3 == 0:
            logger.info(
                "waiting for Agent %s to become Ready: %s; pods: %s",
                AGENT_NAME,
                _conditions_summary(agent_obj),
                _pods_summary(pods),
            )
        time.sleep(10)
    raise AssertionError(
        f"Agent {namespace_name}/{AGENT_NAME} not Ready after {timeout_seconds}s: "
        f"{_conditions_summary(agent_obj)}; pods: {_pods_summary(pods)}"
    )


def _dump_kagent_state(kube_cluster: Cluster) -> None:
    """Best-effort dump of the kagent namespace into the test log when the
    Agent smoke fails, so the CI log explains itself. ATS's own diagnostics
    run after teardown, when the Agent is already being deleted."""
    commands = [
        f"-n {namespace_name} get pods -o wide",
        f"-n {namespace_name} get agents.kagent.dev,modelconfigs.kagent.dev,deployments",
        f"-n {namespace_name} describe agents.kagent.dev {AGENT_NAME}",
        f"-n {namespace_name} describe modelconfigs.kagent.dev {MODEL_CONFIG_NAME}",
        f"-n {namespace_name} get events --sort-by=.lastTimestamp",
        f"-n {namespace_name} logs deployment/{deployment_name} --tail=200",
    ]
    for cmd in commands:
        try:
            logger.error("$ kubectl %s\n%s", cmd, kube_cluster.kubectl(cmd, output_format=""))
        except Exception as exc:  # diagnostics must never mask the assertion
            logger.error("kubectl %s failed: %s", cmd, exc)


@pytest.mark.smoke
def test_declarative_agent_reaches_ready(kube_cluster: Cluster, smoke_agent: str) -> None:
    """A minimal declarative Agent (no `runtime`, default ModelConfig, fake
    provider key) gets a Deployment on the flat gsoci Go ADK image and reaches
    Ready."""
    try:
        wait_for_model_config_accepted(kube_cluster)
        agent_deployment = wait_for_agent_deployment(kube_cluster)
        assert_go_adk_image(agent_deployment)
        wait_for_agent_ready(kube_cluster, agent_deployment)
    except BaseException:
        _dump_kagent_state(kube_cluster)
        raise
