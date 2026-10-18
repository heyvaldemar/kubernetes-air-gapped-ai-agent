#!/usr/bin/env python3
"""mlbom.py NAME URL SHA256 LICENSE - a CycloneDX 1.6 ML-BOM for one model file.

The AI-BOM scripts/model.sh attaches to every model image as an in-toto
attestation signed with the operator's key, and admission reads before the
model server may mount the image: what the model is, where its file came from
at which revision, its sha256, and the licence it is used under.

Deterministic: the same lock line gives the same bytes, so a rebuilt BOM is
the same BOM. No timestamp, and a serial number derived from the file's hash.
"""
import json
import re
import sys
import uuid


def mlbom(name, url, sha, license_id):
    m = re.match(r"^https://huggingface\.co/([^/]+)/([^/]+)/resolve/([0-9a-f]{40})/(.+)$", url)
    if not m:
        sys.exit("not a Hugging Face file URL pinned at a 40-character revision: " + url)
    publisher, repo, revision, filename = m.groups()
    quant = re.search(r"(Q\d_K_[SML]|Q\d_\d|Q\d_K|F16|BF16)", filename)
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, "sha256:" + sha)),
        "version": 1,
        "metadata": {
            "component": {"type": "machine-learning-model", "bom-ref": "model", "name": name},
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
            ],
            "modelCard": {"modelParameters": {"task": "text-generation"}},
        }],
    }


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    json.dump(mlbom(*sys.argv[1:5]), sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
