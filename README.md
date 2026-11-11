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
| aws | [39632816543](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39632816543) | workflow_dispatch | failure | 2026-10-21 | [aws/39632816543-1](aws/39632816543-1), 648 bytes |
| aws | [39624648738](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39624648738) | workflow_dispatch | failure | 2026-10-21 | the run uploaded no e2e-results-aws |
