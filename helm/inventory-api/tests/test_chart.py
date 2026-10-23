"""Render-only chart tests; no cluster, Docker, or Helm plugins required."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


CHART = Path(__file__).resolve().parents[1]


class UniqueKeyLoader(yaml.SafeLoader):
    """Reject duplicate mapping keys rather than silently masking collisions."""


def unique_mapping(loader, node):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if key in mapping:
            raise ValueError(f"Duplicate YAML key: {key}")
        mapping[key] = loader.construct_object(value_node)
    return mapping


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


class ChartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("helm"):
            raise RuntimeError("Helm is required for chart tests")

    def render(self, values=None, profile=None, release="inventory-api", namespace="test-lab", valid=True):
        with tempfile.TemporaryDirectory() as directory:
            command = ["helm", "template", release, str(CHART), "--namespace", namespace]
            if profile:
                command += ["-f", str(CHART / profile)]
            if values is not None:
                override = Path(directory) / "override.yaml"
                override.write_text(yaml.safe_dump(values))
                command += ["-f", str(override)]
            result = subprocess.run(command, capture_output=True, text=True)
        if not valid:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        documents = [doc for doc in yaml.load_all(result.stdout, Loader=UniqueKeyLoader) if doc]
        return {doc["kind"]: doc for doc in documents}

    def container(self, rendered):
        return rendered["Deployment"]["spec"]["template"]["spec"]["containers"][0]

    def test_all_lab_defaults_and_rollout(self):
        rendered = self.render()
        self.assertEqual(set(rendered), {"Deployment", "Service", "ServiceAccount", "ConfigMap", "NetworkPolicy"})
        deployment = rendered["Deployment"]["spec"]
        container = self.container(rendered)
        self.assertEqual(deployment["replicas"], 2)
        self.assertEqual(container["image"], "inventory-api:1.0")
        self.assertEqual(container["imagePullPolicy"], "IfNotPresent")
        self.assertEqual(container["ports"][0]["containerPort"], 8080)
        self.assertEqual(container["readinessProbe"]["httpGet"]["path"], "/ready")
        self.assertEqual(container["livenessProbe"]["httpGet"]["path"], "/health")
        self.assertEqual(container["resources"], {
            "requests": {"cpu": "100m", "memory": "128Mi"},
            "limits": {"cpu": "500m", "memory": "256Mi"},
        })
        self.assertEqual(rendered["Service"]["spec"]["type"], "ClusterIP")
        self.assertEqual(rendered["Service"]["spec"]["ports"][0]["port"], 80)
        self.assertEqual(deployment["strategy"], {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}})

    def test_service_selects_release_pods(self):
        rendered = self.render()
        labels = rendered["Deployment"]["spec"]["template"]["metadata"]["labels"]
        selectors = rendered["Deployment"]["spec"]["selector"]["matchLabels"]
        self.assertEqual(rendered["Service"]["spec"]["selector"], selectors)
        self.assertTrue(all(labels[key] == value for key, value in selectors.items()))
        self.assertEqual(rendered["Service"]["spec"]["ports"][0]["targetPort"], "http")

    def test_dedicated_service_account_and_no_token(self):
        rendered = self.render()
        pod = rendered["Deployment"]["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertFalse(rendered["ServiceAccount"]["automountServiceAccountToken"])
        self.assertEqual(pod["serviceAccountName"], rendered["ServiceAccount"]["metadata"]["name"])

    def test_image_ports_replicas_resources_and_probes_overrides(self):
        rendered = self.render({
            "image": {"repository": "registry.example.com/team/api", "tag": "sha-123", "pullPolicy": "Always"},
            "replicaCount": 3, "containerPort": 9090,
            "service": {"port": 9000, "type": "NodePort"},
            "resources": {"requests": {"cpu": "200m", "memory": "256Mi"}, "limits": {"cpu": "1", "memory": "512Mi"}},
            "readinessProbe": {"httpGet": {"path": "/custom-ready"}, "periodSeconds": 7, "successThreshold": 2},
            "livenessProbe": {"httpGet": {"path": "/custom-health"}, "timeoutSeconds": 4},
            "startupProbe": {"httpGet": {"path": "/health", "port": "http"}, "failureThreshold": 30},
        })
        container = self.container(rendered)
        self.assertEqual(container["image"], "registry.example.com/team/api:sha-123")
        self.assertEqual(container["imagePullPolicy"], "Always")
        self.assertEqual(rendered["Deployment"]["spec"]["replicas"], 3)
        self.assertEqual(container["ports"][0]["containerPort"], 9090)
        self.assertEqual({entry["name"]: entry["value"] for entry in container["env"]}["UVICORN_PORT"], "9090")
        self.assertEqual(rendered["Service"]["spec"]["ports"][0]["port"], 9000)
        self.assertEqual(container["readinessProbe"]["httpGet"], {"path": "/custom-ready", "port": "http"})
        self.assertEqual(container["readinessProbe"]["successThreshold"], 2)
        self.assertEqual(container["livenessProbe"]["timeoutSeconds"], 4)
        self.assertEqual(container["startupProbe"]["failureThreshold"], 30)
        self.assertEqual(container["resources"]["requests"]["cpu"], "200m")

    def test_labels_annotations_and_selector_stability(self):
        rendered = self.render({
            "commonLabels": {"team": "platform"}, "podLabels": {"component": "api"},
            "commonAnnotations": {"owner": "platform"},
            "podAnnotations": {"monitoring": "enabled", "checksum/config": "user-value"},
            "service": {"annotations": {"discovery": "internal"}},
        })
        for resource in rendered.values():
            self.assertEqual(resource["metadata"]["labels"]["team"], "platform")
            self.assertEqual(resource["metadata"]["annotations"]["owner"], "platform")
        metadata = rendered["Deployment"]["spec"]["template"]["metadata"]
        self.assertEqual(metadata["labels"]["component"], "api")
        self.assertEqual(metadata["annotations"]["monitoring"], "enabled")
        self.assertNotEqual(metadata["annotations"]["checksum/config"], "user-value")
        self.assertEqual(len(metadata["annotations"]["checksum/config"]), 64)
        self.assertEqual(rendered["Service"]["metadata"]["annotations"]["discovery"], "internal")

    def test_configmap_reference_and_rollout_checksum(self):
        before = self.render()
        after = self.render({"config": {"INVENTORY_LOG_LEVEL": "DEBUG", "FEATURE_FLAG": "true"}})
        container = self.container(after)
        self.assertEqual(container["envFrom"][0]["configMapRef"]["name"], after["ConfigMap"]["metadata"]["name"])
        self.assertEqual(after["ConfigMap"]["data"]["INVENTORY_LOG_LEVEL"], "DEBUG")
        self.assertEqual(after["ConfigMap"]["data"]["FEATURE_FLAG"], "true")
        self.assertNotEqual(before["Deployment"]["spec"]["template"]["metadata"]["annotations"]["checksum/config"], after["Deployment"]["spec"]["template"]["metadata"]["annotations"]["checksum/config"])

    def test_dev_and_prod_profiles(self):
        for profile, replicas, level, environment in [("values-dev.yaml", 1, "DEBUG", "dev"), ("values-prod.yaml", 2, "INFO", "prod")]:
            with self.subTest(profile=profile):
                rendered = self.render(profile=profile)
                self.assertEqual(rendered["Deployment"]["spec"]["replicas"], replicas)
                self.assertEqual(rendered["ConfigMap"]["data"]["INVENTORY_LOG_LEVEL"], level)
                self.assertEqual(rendered["Deployment"]["metadata"]["labels"]["environment"], environment)

    def test_release_isolation_namespace_and_names(self):
        first = self.render(release="alpha", namespace="dev")
        second = self.render(release="beta", namespace="prod")
        self.assertNotEqual(first["Service"]["metadata"]["name"], second["Service"]["metadata"]["name"])
        self.assertNotEqual(first["Service"]["spec"]["selector"], second["Service"]["spec"]["selector"])
        for resource in second.values():
            self.assertEqual(resource["metadata"]["namespace"], "prod")
        override = self.render({"fullnameOverride": "custom-api"})
        self.assertEqual(override["Service"]["metadata"]["name"], "custom-api")

    def test_hpa_owns_replicas(self):
        rendered = self.render({"autoscaling": {"enabled": True}, "replicaCount": None})
        self.assertNotIn("replicas", rendered["Deployment"]["spec"])
        self.assertEqual(self.container(rendered)["resources"]["requests"]["cpu"], "100m")
        self.assertEqual(rendered["HorizontalPodAutoscaler"]["apiVersion"], "autoscaling/v2")
        hpa = rendered["HorizontalPodAutoscaler"]["spec"]
        self.assertEqual(hpa["scaleTargetRef"]["name"], rendered["Deployment"]["metadata"]["name"])
        self.assertEqual((hpa["minReplicas"], hpa["maxReplicas"]), (2, 5))
        self.assertEqual(hpa["metrics"][0]["resource"]["target"]["averageUtilization"], 70)

    def test_existing_service_account_and_secret_reference(self):
        rendered = self.render({"serviceAccount": {"create": False, "name": "existing-api"}, "existingSecret": "api-secrets"})
        self.assertNotIn("ServiceAccount", rendered)
        self.assertNotIn("Secret", rendered)
        pod = rendered["Deployment"]["spec"]["template"]["spec"]
        self.assertEqual(pod["serviceAccountName"], "existing-api")
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertIn({"secretRef": {"name": "api-secrets"}}, self.container(rendered)["envFrom"])

    def test_optional_ingress_and_route_backends(self):
        ingress = self.render({"ingress": {"enabled": True, "hosts": [{"host": "api.example.com", "paths": [{"path": "/", "pathType": "Prefix"}]}]}})
        backend = ingress["Ingress"]["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]
        self.assertEqual(backend["name"], ingress["Service"]["metadata"]["name"])
        route = self.render({"httpRoute": {"enabled": True, "parentRefs": [{"name": "gateway"}]}})
        self.assertEqual(route["HTTPRoute"]["spec"]["rules"][0]["backendRefs"][0]["name"], route["Service"]["metadata"]["name"])

    def test_runtime_security_baseline_and_writable_tmp(self):
        rendered = self.render()
        pod = rendered["Deployment"]["spec"]["template"]["spec"]
        security = self.container(rendered)["securityContext"]
        self.assertEqual(pod["securityContext"]["runAsUser"], 10001)
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        self.assertEqual(pod["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
        self.assertTrue(security["readOnlyRootFilesystem"])
        self.assertFalse(security["privileged"])
        self.assertFalse(security["allowPrivilegeEscalation"])
        self.assertEqual(security["capabilities"]["drop"], ["ALL"])
        for field in ["hostNetwork", "hostPID", "hostIPC"]:
            self.assertFalse(pod[field])
        self.assertEqual(pod["volumes"], [{"name": "tmp", "emptyDir": {"medium": "Memory", "sizeLimit": "32Mi"}}])
        self.assertEqual(self.container(rendered)["volumeMounts"], [{"name": "tmp", "mountPath": "/tmp", "readOnly": False}])
        env = {item["name"]: item["value"] for item in self.container(rendered)["env"]}
        self.assertEqual(env["INVENTORY_UNREADY_FILE"], "/tmp/inventory-api.unready")
        self.assertEqual(env["TMPDIR"], "/tmp")
        self.assertNotIn("Role", rendered)
        self.assertNotIn("RoleBinding", rendered)
        self.assertNotIn("ClusterRoleBinding", rendered)

    def test_network_policy_allows_only_opted_in_clients_and_dns(self):
        rendered = self.render()
        policy = rendered["NetworkPolicy"]["spec"]
        self.assertEqual(policy["podSelector"]["matchLabels"], rendered["Service"]["spec"]["selector"])
        self.assertEqual(policy["policyTypes"], ["Ingress", "Egress"])
        self.assertEqual(policy["ingress"], [{"from": [{"podSelector": {"matchLabels": {"inventory-api/access": "true"}}}], "ports": [{"protocol": "TCP", "port": "http"}]}])
        self.assertEqual(len(policy["egress"]), 1)
        dns = policy["egress"][0]
        self.assertEqual(dns["ports"], [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}])
        self.assertEqual(dns["to"], [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}])
        closed = self.render({"networkPolicy": {"ingressPeers": []}})
        self.assertEqual(closed["NetworkPolicy"]["spec"]["ingress"], [])

    def test_security_relaxations_are_rejected(self):
        cases = [
            {"podSecurityContext": {"runAsUser": 0}},
            {"podSecurityContext": {"runAsNonRoot": False}},
            {"securityContext": {"runAsUser": 0}},
            {"securityContext": {"privileged": True}},
            {"securityContext": {"allowPrivilegeEscalation": True}},
            {"securityContext": {"readOnlyRootFilesystem": False}},
            {"securityContext": {"capabilities": {"drop": []}}},
            {"securityContext": {"capabilities": {"add": ["NET_ADMIN"]}}},
            {"podSecurityContext": {"seccompProfile": {"type": "Unconfined"}}},
            {"serviceAccount": {"automount": True}},
            {"containerPort": 80},
            {"resources": {"limits": {"memory": "0e9"}}},
            {"hostNetwork": True}, {"hostPID": True}, {"hostIPC": True},
            {"resources": {"requests": {"cpu": None}}},
            {"resources": {"limits": {"memory": "0"}}},
            {"config": {"INVENTORY_UNREADY_FILE": "/app/unready"}},
            {"config": {"INVENTORY_UNREADY_FILE": "/tmp/../app/unready"}},
            {"networkPolicy": {"ingressPeers": [{"podSelector": {}}]}},
            {"networkPolicy": {"ingressPeers": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]}},
            {"networkPolicy": {"enabled": False}},
        ]
        for values in cases:
            with self.subTest(values=values):
                self.render(values, valid=False)

    def test_invalid_combinations_are_rejected(self):
        cases = [
            {"autoscaling": {"enabled": True}},
            {"autoscaling": {"enabled": True, "minReplicas": 4, "maxReplicas": 2}, "replicaCount": None},
            {"autoscaling": {"enabled": True}, "replicaCount": None, "resources": {"requests": {"cpu": "0"}}},
            {"autoscaling": {"enabled": True}, "replicaCount": None, "resources": {"requests": {"cpu": None}}},
            {"containerPort": 0}, {"image": {"tag": 1.0}},
            {"commonLabels": {"app.kubernetes.io/instance": "another-release"}},
            {"config": {"UVICORN_PORT": "9000"}},
            {"serviceAccount": {"create": False}},
            {"replicaCount": None},
            {"strategy": {"rollingUpdate": {"maxUnavailable": 1}}},
            {"image": {"pullPolicy": "Sometimes"}},
            {"config": {"INVENTORY_LOG_LEVEL": "INVALID"}},
            {"config": {"FEATURE_FLAG": True}},
            {"readinessProbe": {"httpGet": {"port": 8080}}},
            {"ingress": {"enabled": True, "hosts": [{"host": "api.example.com", "paths": [{"path": "/", "pathType": "Prefix"}]}]}, "httpRoute": {"enabled": True, "parentRefs": [{"name": "gateway"}]}},
        ]
        for values in cases:
            with self.subTest(values=values):
                self.render(values, valid=False)


if __name__ == "__main__":
    unittest.main()
