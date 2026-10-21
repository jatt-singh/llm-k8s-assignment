# AI usage

## Summary (honest account)

This assessment was built with **Claude Code** (Anthropic, Claude Opus model) running **agentically** in VS Code with shell access on my laptop. Under a tight timebox, I directed the work, made the scope decisions and supervised the run. Claude Code wrote the code, IaC, chart, scripts and docs, executed the toolchain, and iterated on failures until every demo item worked on my machine.

I did **not** hand-write most of the code, and I have not yet reviewed every line in depth. What I can stand behind is that every requirement was **executed and verified on a real cluster**, not just generated (see "How output was validated"). I am continuing to study the Terraform modules and the CI script in detail.

## Tools

| Tool | Used for |
|---|---|
| Claude Code (agentic, with shell access) | Requirement breakdown; writing all services, Dockerfiles, Terraform, Helm chart, CI script, demo scripts and docs; running go test / terraform / helm / kind / trivy / syft; debugging failures |

No other AI tools were used. No proprietary or employer code was shared with the tool.

## My decisions and direction

- Asked for a plain-language breakdown of the brief first, to understand what was being assessed.
- Asked whether to reuse my existing **private GKE Terraform** (a personal learning project). The answer was no, because the brief forbids cloud accounts. I accepted building on **Kind** instead and reusing only the module/env layout as a pattern. The GKE design informed `docs/CLOUD_PORTABILITY.md`.
- Gave the go-ahead to build and test end to end in this repo, and to run it on my laptop (Docker, Kind, model download).
- Asked for a step-by-step demo guide with both `make` and raw terraform/kubectl/helm commands, so I can explain and run each step myself (`docs/DEMO_GUIDE.md`).

## Example prompts

- "Explain what this take-home assessment is asking for, in simple terms."
- "I have Terraform for a VPC and private GKE cluster. Can we reuse it for this assignment?"
- "Build it for this assignment and perform the actions end to end. Add all code in the current folder."
- "Add all the steps to run and test everything in the README."

## What was accepted, rejected or changed

- **Rejected** deploying to GCP with my existing GKE code, because it breaks the "no cloud account" rule.
- **Rejected** ingress-nginx (retired upstream in 2026) in favour of Traefik.
- **Rejected** floating tags. The llama.cpp `:server` tag had been built the same day, so a several-weeks-old build (b11223) was pinned by digest. Helm charts and Terraform providers were pinned to versions at least ~2 weeks old, checked against their registries.
- **Changed** the Go build image from 1.27.1 to 1.27.2 after Trivy reported 3 HIGH stdlib CVEs fixed in 1.27.2.
- **Changed** Alloy from a DaemonSet to a single Deployment, to avoid shipping duplicate log lines.

## Bugs that AI-generated code introduced and testing caught

These are the main reason I trust the result more than I would trust unexecuted output:

1. **Traefik chart values were wrong for the pinned chart version** (`logs` → `log`/`accessLog`, `service.type` → `service.spec.type`). This was caught by the chart schema and by `terraform apply` hanging on a LoadBalancer that Kind never provisions.
2. **The alert never fired.** The error-rate ratio included kubelet health probes and Prometheus scrapes (always 200), which diluted real failures. This was caught by actually taking the LLM down. The rule was fixed to exclude probe and scrape routes, and the alert path was then verified as firing in Prometheus and routed by Alertmanager.
3. **The CI image tag changed mid-run.** The scan step wrote reports into the repo, which made the tree "dirty" and changed the tag that later steps used. The tag is now computed once per run.
4. **`release dev` applied Terraform to prod.** A loop variable in the lint step leaked into the caller because of bash dynamic scoping. This was caught on the full release run; the empty-allowlist guard stopped the app deploy. All loop variables are now `local`. The accidental prod cluster was then used to verify a clean `terraform destroy`.
5. **A Helm template rendered the alert threshold as "0%"** (integer `mul` on 0.05). Fixed with `mulf`.

## How output was validated

1. **Executed, not just read.** `scripts/ci.sh check` runs gofmt/vet, unit tests, shellcheck, hadolint, terraform validate, helm lint, chart policy tests, Trivy (config + image gate) and Syft. `make release ENV=dev` passed end to end.
2. **Every live-demo item was run on the cluster:**
   - LLM answer over TLS
   - 403 from a non-allowlisted source
   - NetworkPolicy edges allowed and blocked as designed
   - HPA scaling 1→3
   - CronJob passing its checksum and prompt checks
   - an alert firing and reaching Alertmanager
   - a bad release stalling and being rolled back
   - prod destroyed cleanly
3. **Facts verified at the source,** not from model memory: model revision and SHA-256 from the Hugging Face API, image digests from registries, chart and provider versions from their indexes.
4. **Security enforced by the cluster:** namespace PSS `restricted` rejects any pod missing the required security settings.

## Risks considered

| Risk | Mitigation |
|---|---|
| Hallucinated versions, flags, chart keys | Resolved live from registries; errors fixed from the actual tool output |
| Insecure defaults | PSS restricted enforced, Trivy config gate, default-deny NetworkPolicies, upstream root image re-wrapped as non-root |
| Secrets leaking | Generated at apply time, git-ignored state, no `set -x`. Verified that no generated secret or private key exists in any commit |
| Licensing | Model Apache-2.0, llama.cpp MIT, charts Apache-2.0. Upstream components consumed as pinned images/charts, not copied |
| Over-reliance on AI / not understanding the code | Stated openly above. A demo guide with raw commands and talking points was written so each step can be run and explained manually |
