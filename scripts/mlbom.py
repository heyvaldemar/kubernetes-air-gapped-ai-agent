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

LICENSE is an SPDX licence id or an SPDX expression. An id is the licence,
and is written as it is: admission holds it to the site's list. An
expression is evaluated here, because admission does not read one: "A OR B"
offers a choice and "A AND B" adds an obligation, and only the site's list
(read from admission/verify-models.yaml, so it has one home) settles which
apply. The BOM gets the first reading, in the order written, whose every
licence is on the list, as ids marked concluded, and the expression beside
them as declared. When no reading is on the list there is nothing true to
write as concluded, and no BOM is written. A licence with an exception
("X WITH Y") has no id to be written as, and is never concluded.

Deterministic: the same lock line gives the same bytes, so a rebuilt BOM is
the same BOM. No timestamp, and a serial number derived from the file's hash.
"""
import json
import os
import re
import sys
import uuid

POLICY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "admission", "verify-models.yaml")


def allowed():
    """The site's list of licences, from the admission policy that holds it."""
    m = re.search(r"l\.license\.id in \[([^\]]*)\]", open(POLICY).read())
    if not m:
        sys.exit("no licence list in " + POLICY)
    return re.findall(r"'([^']+)'", m.group(1))


def parse(expr):
    """An SPDX licence expression as a tree: ("id", x), ("with", x, y),
    ("and", a, b), ("or", a, b). WITH binds tighter than AND, AND than OR;
    the operators are upper case (SPDX 2.3, Annex D)."""
    toks = re.findall(r"\(|\)|[^\s()]+", expr)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take():
        pos[0] += 1
        return toks[pos[0] - 1]

    def ident():
        t = peek()
        if t is None or t in ("(", ")", "AND", "OR", "WITH"):
            sys.exit("%s: expected a licence id at %r" % (expr, t))
        return take()

    def atom():
        if peek() == "(":
            take()
            e = either()
            if peek() != ")":
                sys.exit("%s: unclosed parenthesis" % expr)
            take()
            return e
        x = ident()
        if peek() == "WITH":
            take()
            return ("with", x, ident())
        return ("id", x)

    def both():
        e = atom()
        while peek() == "AND":
            take()
            e = ("and", e, atom())
        return e

    def either():
        e = both()
        while peek() == "OR":
            take()
            e = ("or", e, both())
        return e

    tree = either()
    if peek() is not None:
        sys.exit("%s: unexpected %r" % (expr, peek()))
    return tree


def readings(tree):
    """Every way the expression may be honoured, in the order written: each
    a list of the licences that all apply."""
    kind = tree[0]
    if kind == "id":
        return [[tree[1]]]
    if kind == "with":
        return [["%s WITH %s" % tree[1:]]]
    if kind == "or":
        return readings(tree[1]) + readings(tree[2])
    return [a + [x for x in b if x not in a] for a in readings(tree[1]) for b in readings(tree[2])]


def licences(declared):
    """The BOM's licences entry for what the lock declares."""
    tree = parse(declared)
    if tree[0] == "id":
        return [{"license": {"id": tree[1]}}], []
    ok = allowed()
    for reading in readings(tree):
        if all(x in ok for x in reading):
            return ([{"license": {"id": x, "acknowledgement": "concluded"}} for x in reading],
                    [{"name": "license-declared", "value": declared}])
    missing = []
    for reading in readings(tree):
        missing += [x for x in reading if x not in ok and x not in missing]
    sys.exit("%s: every reading of it needs %s, and the site allows only %s; no AI-BOM written"
             % (declared, " or ".join(missing), ", ".join(ok)))


def lineage(publisher, repo):
    """The model a GGUF file was converted from, by the naming convention of
    its repository: <maker>/<model>-GGUF when the maker publishes it, or
    <converter>/<Maker>_<model>-GGUF when someone else does. Read from the
    name, not from the maker's records: the BOM says so."""
    base = repo[:-len("-GGUF")] if repo.endswith("-GGUF") else repo
    if "_" in base:
        return tuple(base.split("_", 1))
    return publisher, base


def mlbom(name, url, sha, declared):
    m = re.match(r"^https://huggingface\.co/([^/]+)/([^/]+)/resolve/([0-9a-f]{40})/(.+)$", url)
    if not m:
        sys.exit("not a Hugging Face file URL pinned at a 40-character revision: " + url)
    publisher, repo, revision, filename = m.groups()
    quant = re.search(r"(Q\d_K_[SML]|Q\d_\d|Q\d_K|F16|BF16)", filename)
    maker, base = lineage(publisher, repo)
    entries, noted = licences(declared)
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
            "licenses": entries,
            "hashes": [{"alg": "SHA-256", "content": sha}],
            "externalReferences": [{"type": "distribution", "url": url}],
            "properties": [
                {"name": "huggingface:repository", "value": publisher + "/" + repo},
                {"name": "huggingface:revision", "value": revision},
                {"name": "file", "value": filename},
                {"name": "format", "value": "GGUF"},
                {"name": "quantization", "value": quant.group(1) if quant else "unknown"},
                {"name": "lineage", "value": "the base model is read from the GGUF repository's name"},
            ] + noted,
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
