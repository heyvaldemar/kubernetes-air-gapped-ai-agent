# 3. Model weights as a signed image, mounted as an image volume

- Status: accepted
- Date: 2026-10-18

## Context

A model file is code the cluster runs on: whoever can swap it decides what the agent says. It needs the guarantees an image has, a digest that names exactly these bytes and a signature that says who vouched for them, checked before a pod gets it. And it has to get into a cluster that cannot download anything.

Kubernetes mounts an OCI image as a read-only volume (`volumes[].image`, GA since 1.36). containerd, which kind and most clusters run, mounts only runnable images, not generic OCI artifacts (containerd#11381), so the formats made for models (ModelPack, KitOps, an ORAS artifact) do not mount on it.

## Decision

- **An ordinary image.** `models/Dockerfile` is `FROM scratch` and one `COPY`. The model file is pinned in `models/models.lock` by the publisher's revision and its sha256, and the build refuses a file that does not match.
- **Built reproducibly.** `SOURCE_DATE_EPOCH=0`, timestamps rewritten, an uncompressed layer, BuildKit pinned by digest. Anyone with the same file gets the same image digest; `models.lock` pins it, and every run rebuilds the image and fails if the digest differs.
- **Signed by key, with no transparency log.** Nothing inside the boundary can reach Rekor, so the operator's key is the root of trust: `cosign sign --key … --tlog-upload=false`. cosign 3 refuses that combination under its default signing configuration, so the key path turns it off (`--use-signing-config=false`). CI makes the key pair per run.
- **Verified at admission, offline.** An ImageValidatingPolicy (Kyverno 1.19.1) verifies the signature with the inline public key and `ctlog.insecureIgnoreTlog`. Kyverno extracts images from containers, init containers and ephemeral containers only, so the policy declares an `images` expression of its own for `volumes[].image` (kyverno#17555 would have made that the default, and was closed unmerged on 2026-10-22; the workaround is posted there). A native ValidatingAdmissionPolicy holds the shape without Kyverno: an image volume in the model namespace comes from the models path inside, by digest.

## Consequences

- The model server never downloads a model. It mounts one the cluster has already verified, read-only, and the pod spec names it by digest.
- Skipping the transparency log is a weaker guarantee than keyless signing with one: a stolen key signs anything, and nothing public records it. This file and the policy say so where they do it.
- The e2e run plants four pods the policies must refuse (weights nobody signed, weights signed by another key, the model by tag, an image volume from elsewhere) and one they must admit, the signed model by digest.
- The model is 1 GB more on every node that runs it, in the image store, like any image.

## Alternatives

- **Download the model at start-up** from a model hub. Impossible inside the boundary, and unverified outside it.
- **A model in a PersistentVolume**, copied in by a Job. Nothing at admission knows what is in it.
- **ModelPack or KitOps artifacts.** The right formats once containerd mounts artifacts; on CRI-O they mount today.
- **Keyless signing with a TUF mirror inside.** Kyverno 1.19.1 still contacts the public TUF CDN first (kyverno#17883, fix open). The next step once that lands.

## How to explain this to a customer

The AI model is shipped the way your software is: as a sealed package with a fingerprint, signed by your own key. Before the model server may load it, the cluster checks the fingerprint and the signature, with no internet involved. A model nobody signed, or someone else signed, does not start. And anyone can rebuild the package from the published model file and get the same fingerprint.
