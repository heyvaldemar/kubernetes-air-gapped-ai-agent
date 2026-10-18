# 8. One signed file across the gap

- Status: accepted
- Date: 2026-10-18

## Context

Until now the registry inside was seeded from the internet on the same host, and the boundary closed afterwards. That proves the cluster runs with no route out. It does not show how anything reaches a site that never had one. There, everything arrives as a file carried across: through a data diode, on removable media, through a transfer service with its own review. Whatever crosses has to be checked on the inside by someone who did not build it, before any of it is loaded.

## Decision

- **Everything the cluster runs crosses as one file.** `scripts/bundle.sh create`, on the connected side, copies every repository and tag of the staging registry into OCI layouts, with what refers to each image (the model's signature travels with the model), puts the admission chart beside them, writes a SHA256SUMS over every file, and tars it all with sorted names, no times and no owners.
- **The file is signed with the operator's key, with no transparency log.** A site that cannot reach a log cannot check one; the key is what its policy already trusts for the model.
- **On the inside, the signature first, the checksums second, then the load.** `scripts/bundle.sh load` reads nothing from a file whose signature does not verify against the operator's public key, and loads nothing from one whose checksums do not match.
- **The e2e run goes through exactly that path.** After the bundle is made, the staging registry is replaced by an empty one, the chart is deleted, and the boundary closes. The acceptance test (`tests/e2e/run.sh`, check 10) proves that the registry inside held nothing when the file was loaded, that it now holds exactly what the file carried, tag by tag and by digest, and that the same file with one byte changed is refused and loads nothing.

## Consequences

- A release ships as a file a customer can verify with one command and a public key, and a hash read to them over a second channel.
- The run's disk use peaks at three copies of everything; the script deletes its staging layouts once the file is signed, and the copied blobs once they are in the registry.
- The bundle needs GNU tar and coreutils, like `close` needs iptables: the connected side and the inside are Linux.

## Alternatives

- **Zarf.** A complete air-gap packager, and the one a reviewer from that world will ask about. It brings its own registry and a mutating webhook that rewrites image references; this repository already has a registry with a name of its own and admission it can explain line by line, and adding a second admission path would make that explanation longer.
- **Hauler.** Close to what this script does, with charts and files as first-class content. One more tool to pin and trust; `oras` and `cosign` are already in the toolchain and do the two halves.
- **Seeding the inside registry over a temporary connection.** That is what the run did before. It is the step a real site does not have.

## How to explain this to a customer

Everything we install arrives as one file. Before it goes anywhere near your cluster, your side checks two things with a public key we gave you in advance: that we signed it, and that not one byte changed on the way. If either check fails, nothing is loaded. Our test does the same every day, including with a file we damaged on purpose.
