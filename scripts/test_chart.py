#!/usr/bin/env python3
"""Policy tests for the rendered Helm chart.

Renders deploy/helm/llm-app for every environment and asserts the invariants the
assessment asks for, so a template change cannot silently drop them:
  - every container: non-root, no privilege escalation, ALL caps dropped,
    read-only root fs, resource requests + limits
  - every pod: seccomp RuntimeDefault, no service account token mounted
  - every long-running container: readiness + liveness probes
  - only the gateway is exposed through an Ingress; all Services are ClusterIP
  - a default-deny NetworkPolicy exists; the gateway has an HPA and PDB
Run: python3 scripts/test_chart.py   (needs helm and PyYAML)
"""
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHART = ROOT / "deploy/helm/llm-app"
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def render(env):
    out = subprocess.run(
        ["helm", "template", "llm-app", str(CHART), "-n", "llm-app",
         "-f", str(CHART / f"values-{env}.yaml"), "--set", "image.tag=test",
         "--set", "ingress.allowedSourceRanges={127.0.0.1/32}"],
        check=True, capture_output=True, text=True).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def pod_spec(doc):
    kind = doc["kind"]
    if kind in ("Deployment", "Job"):
        return doc["spec"]["template"]["spec"]
    if kind == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None


def test_env(env):
    docs = render(env)
    by_kind = {}
    for d in docs:
        by_kind.setdefault(d["kind"], []).append(d)

    for d in docs:
        spec = pod_spec(d)
        if spec is None:
            continue
        name = f"{env}/{d['kind']}/{d['metadata']['name']}"
        psc = spec.get("securityContext", {})
        check(psc.get("runAsNonRoot") is True, f"{name}: pod runAsNonRoot")
        check(psc.get("seccompProfile", {}).get("type") == "RuntimeDefault", f"{name}: seccomp RuntimeDefault")
        check(spec.get("automountServiceAccountToken") is False, f"{name}: SA token must not be mounted")
        check(spec.get("serviceAccountName") not in (None, "default"), f"{name}: dedicated ServiceAccount")

        for c in spec.get("initContainers", []) + spec["containers"]:
            cname = f"{name}/{c['name']}"
            sc = c.get("securityContext", {})
            check(sc.get("allowPrivilegeEscalation") is False, f"{cname}: allowPrivilegeEscalation false")
            check(sc.get("readOnlyRootFilesystem") is True, f"{cname}: readOnlyRootFilesystem")
            check(sc.get("capabilities", {}).get("drop") == ["ALL"], f"{cname}: drop ALL capabilities")
            res = c.get("resources", {})
            check({"cpu", "memory"} <= set(res.get("requests", {})), f"{cname}: cpu/memory requests")
            check({"cpu", "memory"} <= set(res.get("limits", {})), f"{cname}: cpu/memory limits")

        if d["kind"] == "Deployment":
            for c in spec["containers"]:
                check("readinessProbe" in c and "livenessProbe" in c, f"{name}/{c['name']}: readiness+liveness probes")
            strat = d["spec"]["strategy"]["rollingUpdate"]
            check(strat["maxUnavailable"] == 0, f"{name}: rolling update must keep maxUnavailable 0")

    for s in by_kind.get("Service", []):
        check(s["spec"].get("type", "ClusterIP") == "ClusterIP", f"{env}: Service {s['metadata']['name']} must be ClusterIP")

    ingresses = by_kind.get("Ingress", [])
    backends = {p["backend"]["service"]["name"]
                for i in ingresses for r in i["spec"]["rules"] for p in r["http"]["paths"]}
    check(backends == {"gateway"}, f"{env}: only gateway may be exposed, got {backends}")
    check(all(i["spec"].get("tls") for i in ingresses), f"{env}: Ingress must use TLS")

    netpols = {n["metadata"]["name"]: n for n in by_kind.get("NetworkPolicy", [])}
    dd = netpols.get("default-deny-all")
    check(dd is not None and dd["spec"]["podSelector"] == {} and set(dd["spec"]["policyTypes"]) == {"Ingress", "Egress"},
          f"{env}: default-deny-all NetworkPolicy for ingress and egress")

    check(any(h["metadata"]["name"] == "gateway" for h in by_kind.get("HorizontalPodAutoscaler", [])), f"{env}: gateway HPA")
    check(any(p["metadata"]["name"] == "gateway" for p in by_kind.get("PodDisruptionBudget", [])), f"{env}: gateway PDB")
    check(len(by_kind.get("CronJob", [])) == 1, f"{env}: model-verify CronJob")


def test_empty_allowlist_refused():
    r = subprocess.run(["helm", "template", "x", str(CHART), "--set", "image.tag=t",
                        "--set", "ingress.allowedSourceRanges=null"], capture_output=True, text=True)
    check(r.returncode != 0 and "allowedSourceRanges" in r.stderr, "empty IP allowlist must fail to render")


if __name__ == "__main__":
    for env in ("dev", "prod"):
        test_env(env)
    test_empty_allowlist_refused()
    if failures:
        print("chart policy tests FAILED:")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("chart policy tests passed (dev, prod)")
