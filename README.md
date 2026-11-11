# cloud-results

Written by `.github/workflows/cloud-results.yml` on main, and by nothing else: after each run of aws.yml, gke.yml and aks.yml on main, the run's own record and the results it uploaded, checked against the digest GitHub reported and signed by that workflow (ADR 25). Nothing here is edited by hand, and a record is never replaced.

Each directory holds `record.json`, its signature `record.json.sigstore.json`, and the run's artifact when it uploaded one. The record names the artifact's sha256, so the one signature covers both:

```sh
cosign verify-blob record.json --bundle record.json.sigstore.json \
  --certificate-identity https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/.github/workflows/cloud-results.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
sha256sum e2e-results-*.zip   # the value record.json gives as artifact.sha256
```

| Cloud | Run | Started by | Ended | Date | Results kept |
|---|---|---|---|---|---|
| aks | [42809539539](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/42809539539) | schedule | success | 2026-11-10 | [aks/42809539539-1](aks/42809539539-1), 732 bytes |
| gke | [40563292517](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40563292517) | workflow_dispatch | success | 2026-10-27 | [gke/40563292517-1](gke/40563292517-1), 13024 bytes |
| gke | [40560466605](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40560466605) | workflow_dispatch | failure | 2026-10-27 | [gke/40560466605-1](gke/40560466605-1), 769 bytes |
| gke | [40555921881](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40555921881) | workflow_dispatch | success | 2026-10-27 | [gke/40555921881-1](gke/40555921881-1), 761 bytes |
| gke | [40550142699](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40550142699) | workflow_dispatch | failure | 2026-10-27 | the run uploaded no e2e-results-gke |
| aws | [40168111062](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40168111062) | workflow_dispatch | success | 2026-10-25 | [aws/40168111062-1](aws/40168111062-1), 9915 bytes |
| aws | [40161497976](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40161497976) | workflow_dispatch | failure | 2026-10-25 | [aws/40161497976-1](aws/40161497976-1), 8788 bytes |
| aws | [40052214040](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40052214040) | workflow_dispatch | success | 2026-10-24 | [aws/40052214040-1](aws/40052214040-1), 12307 bytes |
| aws | [40048612675](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40048612675) | workflow_dispatch | failure | 2026-10-24 | the run uploaded no e2e-results-aws |
| aws | [39914708816](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39914708816) | workflow_dispatch | success | 2026-10-23 | [aws/39914708816-1](aws/39914708816-1), 10660 bytes |
| aws | [39905417932](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39905417932) | workflow_dispatch | success | 2026-10-23 | [aws/39905417932-1](aws/39905417932-1), 10672 bytes |
| aws | [39898005905](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39898005905) | workflow_dispatch | failure | 2026-10-23 | [aws/39898005905-1](aws/39898005905-1), 10725 bytes |
| aws | [39893082349](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39893082349) | workflow_dispatch | failure | 2026-10-23 | [aws/39893082349-1](aws/39893082349-1), 9049 bytes |
| aws | [39744285464](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39744285464) | schedule | success | 2026-10-22 | [aws/39744285464-1](aws/39744285464-1), 9283 bytes |
| aws | [39700915485](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39700915485) | workflow_dispatch | success | 2026-10-22 | [aws/39700915485-1](aws/39700915485-1), 9281 bytes |
| aws | [39636241165](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39636241165) | workflow_dispatch | success | 2026-10-21 | [aws/39636241165-1](aws/39636241165-1), 630 bytes |
| aws | [39632816543](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39632816543) | workflow_dispatch | failure | 2026-10-21 | [aws/39632816543-1](aws/39632816543-1), 648 bytes |
| aws | [39624648738](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39624648738) | workflow_dispatch | failure | 2026-10-21 | the run uploaded no e2e-results-aws |
