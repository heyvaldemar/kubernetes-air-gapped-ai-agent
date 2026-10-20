# 2. The registry inside has its own name and speaks only TLS

- Status: accepted
- Date: 2026-10-18

## Context

Inside the boundary, every image comes from one registry, zot, seeded by digest before the cut. The kubelet asks containerd for images by their original names (`docker.io/library/python@sha256:…`), and containerd's mirrors can redirect those names to the registry inside. That serves the kubelet and nothing else.

An admission controller reads registries itself. Kyverno, verifying a signature, asks for the signature by the image's name, and knows nothing of containerd's mirrors. An image named `docker.io/...` would send it to Docker Hub, which is outside. So the images the policy checks, the model first of all, need a name that points inside.

## Decision

- **A name of its own.** The registry is `registry.boundary.internal:5000`. `.internal` is the top-level domain ICANN reserved for private use in 2024, so it cannot collide with a public name. The node resolves it through `/etc/hosts`, pods through a `hosts` entry in CoreDNS, and the host through its own `/etc/hosts`, so a signature names the image exactly as the policy will look it up.
- **TLS from a CA made for the boundary.** `scripts/airgap.sh registry` makes the CA and the registry's certificate. containerd trusts it through `hosts.toml`, Kyverno through the chart's `global.caCertificates`, and cosign and oras through the bundle they are handed. A plain-HTTP request to the registry is refused, and the e2e run checks that it is.
- **Mirrors for the five upstream hosts** the cluster's images come from (docker.io, ghcr.io, quay.io, registry.k8s.io, reg.kyverno.io), each a path in the same registry, so the third-party images keep their original names and digests.
- **Signatures travel with their images** (`oras cp -r`, the OCI referrers API), where the source serves that API. reg.kyverno.io does not; its images come in without referrers, and the seed step says so.
- **Anyone reads, one account writes.** *Amended 2026-10-20.* The registry had TLS and nothing else: anything that reached it could push. zot now holds writing to one account, `loader` (`airgap/zot.json`, `accessControl`), whose bcrypt hash `scripts/airgap.sh registry` writes from a password made per run and kept beside the operator's key. The password reaches `htpasswd` and `oras login` on stdin, never as an argument; oras and cosign read the login from `DOCKER_CONFIG`. Reads stay open, so the nodes pull and Kyverno reads a signature with no credential, and an image's integrity rests on its digest and, for a model, its signature, not on who may read it. e2e check 12: a push with no password, and with a wrong one, is refused with 401; with the loader's it starts, and is cancelled. Static check `boundary`, three plants.

## Consequences

- Anything the policy verifies lives under `registry.boundary.internal:5000/models/`. Third-party images keep their upstream names and are not signature-checked here; the supply-chain admission repository is where that is done.
- The CA is made per run. In a real install it is the site's CA, and its key is not on a CI runner.
- One registry, one replica. A site would run it highly available, with its storage backed up.
- Reads are anonymous inside the boundary: a workload that reaches the registry can pull any image in it. The images are public ones and models with public weights; a site carrying something that is not would give containerd and Kyverno pull credentials too.
- The loader's password is a file on the machine that loads the bundle, as the operator's key is. At a site it lives in the site's secret store.

## Alternatives

- **Rewrite every image to the internal name.** Works for admission, and makes every manifest differ from upstream's; the mirrors keep the third-party images as their maintainers name them.
- **Plain HTTP inside the boundary**, with Kyverno's `--allowInsecureRegistry`. The first thing a security review would flag.
- **distribution (registry:3).** No referrers API yet (distribution#4828), which cosign 3's signatures need.

## How to explain this to a customer

Everything your cluster runs comes from one registry inside your network, under a name that only exists inside it, over an encrypted connection your own certificate authority vouches for. The checks that decide what may run read from that registry too, so nothing about the decision depends on reaching the internet.
