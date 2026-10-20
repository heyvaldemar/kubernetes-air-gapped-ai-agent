#!/usr/bin/env python3
"""mlbom.py NAME URL SHA256 LICENSE - a CycloneDX 1.6 ML-BOM for one model file.

The AI-BOM scripts/model.sh attaches to every model image as an in-toto
attestation signed with the operator's key, and admission reads before the
model server may mount the image: what the model is, where its file came from
at which revision, its sha256, and the licence it is used under.

The BOM's subject is the image the attestation is attached to; the model
file is its one component, and the model it was converted from is that
component's ancestor. Whoever published the GGUF file is its publisher, which
is not always the model's maker: bartowski/Qwen_Qwen3.5-2B-GGUF is Qwen's
model, converted and published by bartowski.

Deterministic: the same lock line gives the same bytes, so a rebuilt BOM is
the same BOM. No timestamp, and a serial number derived from the file's hash.
"""
import json
import re
import sys
import uuid


def lineage(publisher, repo):
    """The model a GGUF file was converted from, by the naming convention of
    its repository: <maker>/<model>-GGUF when the maker publishes it, or
    <converter>/<Maker>_<model>-GGUF when someone else does. Read from the
    name, not from the maker's records: the BOM says so."""
    base = repo[:-len("-GGUF")] if repo.endswith("-GGUF") else repo
    if "_" in base:
        return tuple(base.split("_", 1))
    return publisher, base


def mlbom(name, url, sha, license_id):
    m = re.match(r"^https://huggingface\.co/([^/]+)/([^/]+)/resolve/([0-9a-f]{40})/(.+)$", url)
    if not m:
        sys.exit("not a Hugging Face file URL pinned at a 40-character revision: " + url)
    publisher, repo, revision, filename = m.groups()
    quant = re.search(r"(Q\d_K_[SML]|Q\d_\d|Q\d_K|F16|BF16)", filename)
    maker, base = lineage(publisher, repo)
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, "sha256:" + sha)),
        "version": 1,
        "metadata": {
            "component": {"type": "container", "bom-ref": "image", "name": name,
                          "description": "the model image scripts/model.sh builds from the file, which this BOM is attached to"},
        },
        "components": [{
            "type": "machine-learning-model",
            "bom-ref": "model",
            "name": name,
            "version": revision,
            "publisher": publisher,
            "licenses": [{"license": {"id": license_id}}],
            "hashes": [{"alg": "SHA-256", "content": sha}],
            "externalReferences": [{"type": "distribution", "url": url}],
            "properties": [
                {"name": "huggingface:repository", "value": publisher + "/" + repo},
                {"name": "huggingface:revision", "value": revision},
                {"name": "file", "value": filename},
                {"name": "format", "value": "GGUF"},
                {"name": "quantization", "value": quant.group(1) if quant else "unknown"},
                {"name": "lineage", "value": "the base model is read from the GGUF repository's name"},
            ],
            "pedigree": {"ancestors": [{
                "type": "machine-learning-model",
                "bom-ref": "base-model",
                "name": maker + "/" + base,
                "publisher": maker,
                "externalReferences": [{"type": "website", "url": "https://huggingface.co/%s/%s" % (maker, base)}],
            }]},
            "modelCard": {"modelParameters": {"task": "text-generation"}},
        }],
        "dependencies": [{"ref": "image", "dependsOn": ["model"]}],
    }


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    json.dump(mlbom(*sys.argv[1:5]), sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
