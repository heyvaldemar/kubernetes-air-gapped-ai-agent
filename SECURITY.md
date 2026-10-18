# Security policy

## Supported versions

| Version | Supported |
|---|---|
| The latest release | yes |
| `main` | yes |
| Older releases | no |

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Email to v@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; valid, responsibly disclosed reports are credited in the changelog. Please do not open public issues for security reports.

## What this repository is

A reference architecture, not a hosted service. A vulnerability here is most likely a way past something the README says holds: a route out of the boundary, a model image admitted without the operator's signature, an image volume the policies do not see, a tool argument the MCP server's schema lets through, or a credential the agent can reach.

## Supply chain

- Container images are pinned by digest, and CI fails on one that is not; every image the cluster runs must also be in `airgap/images.txt`, the list the registry inside is seeded from.
- The model file is pinned by the publisher's revision and its sha256, and the model image by the digest its reproducible build gives (`models/models.lock`); every run rebuilds it and fails if the digest moved.
- GitHub Actions are pinned by commit SHA; CLI tools by version and sha256 (`tools.lock`); CI images by digest (`ci-images.pins`); the admission chart by the sha256 of its archive (`admission/charts.lock`).

## Credentials

None stored. CI makes the operator's signing key and the boundary's CA on the runner for each run and throws them away with it. The records service's key is generated at install and exists only in the cluster. No model provider is called: the model runs inside the boundary.
