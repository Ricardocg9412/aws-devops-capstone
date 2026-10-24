"""Operational evidence checks using fixture CLIs, without a cluster or cloud."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(shutil.which("jq") is None, reason="jq is required for operational scripts")


def analyze(tmp_path, lines):
    log = tmp_path / "application.log"
    log.write_text("\n".join(json.dumps(line) if not isinstance(line, str) else line for line in lines))
    result = subprocess.run([str(ROOT / "scripts/log-analyzer.sh"), str(log)], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def test_log_analyzer_counts_actual_fields_and_ignores_noise(tmp_path):
    def request(status, duration, path="/items"):
        return {"message": "request_completed", "method": "GET", "path": path,
                "status_code": status, "duration_ms": duration}
    result = analyze(tmp_path, ["Uvicorn startup", "{bad json", [], "null",
                               request(200, 10), request(404, 20), request(503, 30, "/ready"),
                               request(200, None), request(600, 10)])
    assert result == {"total_requests": 4, "http_4xx": 1, "http_5xx": 1,
                      "most_frequent_endpoint": {"endpoint": "GET /items", "count": 3},
                      "average_duration_ms": 20, "duration_samples": 3, "ignored_log_lines": 5}


def test_log_analyzer_handles_empty_input(tmp_path):
    result = analyze(tmp_path, [])
    assert result["total_requests"] == 0
    assert result["average_duration_ms"] is None
    assert result["most_frequent_endpoint"] is None


@pytest.mark.parametrize("scenario,reason", [
    ("image-pull", "ImagePullBackOff"),
    ("crash", "CrashLoopBackOff"),
    ("readiness", "ContainersNotReady"),
    ("scheduling", "Unschedulable"),
])
def test_diagnostics_keep_failure_evidence_without_metrics_or_secret_values(tmp_path, scenario, reason):
    sensitive = "DO_NOT_CAPTURE_SECRET_VALUE"
    state = {"waiting": {"reason": reason, "message": "Back-off pulling image"}}
    conditions = [{"type": "Ready", "status": "False", "reason": reason, "message": "Readiness probe failed: HTTP 503"}]
    if scenario == "scheduling":
        conditions = [{"type": "PodScheduled", "status": "False", "reason": reason, "message": "Insufficient cpu"}]
        state = {}
    if scenario == "readiness":
        state = {"running": {"startedAt": "2026-10-23T00:00:00Z"}}
    restart_count = 3 if scenario == "crash" else 0
    pods = {"items": [{"metadata": {"name": "inventory-api-test", "namespace": "devops-lab", "annotations": {"private": sensitive}},
                      "spec": {"nodeName": None if scenario == "scheduling" else "test-node",
                               "containers": [{"name": "api", "image": "inventory-api:abc", "imagePullPolicy": "Never",
                                               "env": [{"name": "PASSWORD", "value": sensitive}], "args": [sensitive],
                                               "resources": {"requests": {"cpu": "100m", "memory": "128Mi"}},
                                               "readinessProbe": {"httpGet": {"path": "/ready", "port": 8080,
                                                                               "httpHeaders": [{"name": "Authorization", "value": sensitive}]}}}]},
                      "status": {"phase": "Pending", "conditions": conditions,
                                 "containerStatuses": [{"name": "api", "ready": False, "restartCount": restart_count, "state": state,
                                                        "lastState": {"terminated": {"reason": "Error", "exitCode": 1, "message": sensitive}}}]}}]}
    fixtures = {
        "pods": pods,
        "deployments": {"items": [{"metadata": {"name": "inventory-api", "generation": 1},
                                   "spec": {"replicas": 1, "template": {"spec": {"containers": pods["items"][0]["spec"]["containers"]}}},
                                   "status": {"readyReplicas": 0, "conditions": conditions}}]},
        "events": {"items": [{"type": "Warning", "reason": reason, "message": "Insufficient cpu" if scenario == "scheduling" else reason,
                              "involvedObject": {"kind": "Pod", "name": "inventory-api-test"}}]},
        "services": {"items": [{"metadata": {"name": "inventory-api"}, "spec": {"type": "ClusterIP", "ports": [{"port": 80}]}}]},
        "endpointslices": {"items": []},
        "node": {"metadata": {"name": "test-node", "annotations": {"private": sensitive}}, "spec": {},
                 "status": {"conditions": [{"type": "MemoryPressure", "status": "False"}]}},
        "helm-status": {"name": "inventory-api", "namespace": "devops-lab", "version": 2,
                        "info": {"status": "failed", "notes": sensitive}, "config": {"password": sensitive},
                        "manifest": sensitive, "chart": {"metadata": {"name": "inventory-api", "version": "0.1.0"}}},
        "helm-history": [{"revision": 2, "status": "failed", "description": sensitive}],
    }
    fixture_file = tmp_path / "fixtures.json"
    fixture_file.write_text(json.dumps(fixtures))
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    # Write fake CLIs with an absolute interpreter so PATH contains no ambiguity.
    cli = f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
args=sys.argv[1:]
data=json.loads(Path(os.environ['DIAGNOSTIC_FIXTURES']).read_text())
with open(os.environ['DIAGNOSTIC_CALLS'],'a') as calls:
    calls.write(json.dumps(args)+'\\n')
if Path(sys.argv[0]).name=='helm':
    print(json.dumps(data['helm-status' if 'status' in args else 'helm-history']))
elif 'top' in args:
    print('Metrics API not available',file=sys.stderr); sys.exit(1)
elif 'rollout' in args:
    print('Waiting for deployment rollout: 0 of 1 replicas available'); sys.exit(1)
elif 'logs' in args:
    if '--previous' in args:
        print('Application crashed: exit 1')
    print(json.dumps({'password': 'DO_NOT_CAPTURE_SECRET_VALUE'}))
    print('Authorization: Bearer DO_NOT_CAPTURE_SECRET_VALUE')
    print(json.dumps({'message':'request_completed','method':'GET','path':'/ready','status_code':503,'duration_ms':2.5}))
elif 'get' in args:
    print(json.dumps(data[args[args.index('get')+1]]))
else:
    sys.exit(2)
'''
    for name in ["kubectl", "helm"]:
        executable = fake_bin / name
        executable.write_text(cli)
        executable.chmod(0o755)
    env = {**os.environ, "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
           "DIAGNOSTICS_DIR": str(tmp_path / "evidence"), "KUBE_CONTEXT": "fixture-context",
           "DIAGNOSTIC_FIXTURES": str(fixture_file), "DIAGNOSTIC_CALLS": str(tmp_path / "calls.jsonl")}
    result = subprocess.run([str(ROOT / "scripts/collect-diagnostics.sh"), "devops-lab", "inventory-api"],
                            env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    output = next((tmp_path / "evidence").iterdir())
    evidence = "\n".join(path.read_text() for path in output.iterdir() if path.is_file())
    assert sensitive not in evidence
    assert reason in (output / "pod-descriptions.txt").read_text()
    assert reason in (output / "events.json").read_text()
    assert 'metrics-pods.txt\t1' in (output / "collection-status.tsv").read_text()
    assert 'rollout-inventory-api.txt\t1' in (output / "collection-status.tsv").read_text()
    assert json.loads((output / "helm-history.json").read_text())[0]["status"] == "failed"
    assert json.loads((output / "http-summary.json").read_text())["http_5xx"] >= 1
    calls = [json.loads(line) for line in (tmp_path / "calls.jsonl").read_text().splitlines()]
    assert all("--context" in call or "--kube-context" in call for call in calls)
    assert not any("secrets" in call or "describe" in call for call in calls)
    if scenario == "crash":
        assert json.loads((output / "pod-readiness-restarts.json").read_text())[0]["containers"][0]["restartCount"] == 3
        assert any('--previous' in call for call in calls)
        assert 'Application crashed' in (output / 'logs-inventory-api-test-api-previous.log').read_text()


def test_diagnostics_keep_partial_evidence_when_cluster_is_unavailable(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    for name in ["kubectl", "helm"]:
        executable = fake_bin / name
        executable.write_text('#!/usr/bin/env bash\necho "Cluster unavailable" >&2\nexit 1\n')
        executable.chmod(0o755)
    env = {**os.environ, "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
           "DIAGNOSTICS_DIR": str(tmp_path / "evidence")}
    result = subprocess.run([str(ROOT / "scripts/collect-diagnostics.sh"), "devops-lab", "inventory-api"],
                            env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    output = next((tmp_path / "evidence").iterdir())
    assert 'pods.json\t1' in (output / 'collection-status.tsv').read_text()
    assert 'helm-history.json\t1' in (output / 'collection-status.tsv').read_text()
    assert 'metrics-pods.txt\t1' in (output / 'collection-status.tsv').read_text()
    assert json.loads((output / 'http-summary.json').read_text())['total_requests'] == 0
