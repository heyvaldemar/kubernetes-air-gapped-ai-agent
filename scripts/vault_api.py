#!/usr/bin/env python3
"""vault_api.py <install|unseal|keys> - Vault inside the boundary (ADR 24),
from the operator's side: the runner, which stands for the operator's
machine as it does for the signing keys (ADR 16). scripts/vault.sh calls it;
tests/e2e/vault.sh imports it for the drills.

    install  after the manifests are applied and the TLS Secret is made:
             initialise Vault (five shares, three to unseal), unseal it,
             configure it from manifests/vault/ with the root token, make an
             operator token for the drills, revoke the root token, and write
             Vault's public key set for the records service
    unseal   unseal it again with three of the shares, after a restart
    keys     write Vault's public key set into the records service's
             ConfigMap again, after a rotation

Everything goes through a port-forward to the pod and Vault's HTTP API,
verified against the CA made for this run. The shares and the tokens are
held in memory and in files under .cache/airgap/vault/, mode 600, and are
never printed, never an argument, never in a log. Standard library only.
"""
import contextlib
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, ".cache", "airgap", "vault")
SETUP = os.path.join(ROOT, "manifests", "vault")
PORT = int(os.environ.get("VAULT_LOCAL_PORT", "18200"))
SHARES, THRESHOLD = 5, 3


def say(msg):
    print("== " + msg, flush=True)


def kubectl(*args, stdin=None, check=True):
    return subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True, check=check).stdout


def secret_file(name):
    return os.path.join(STATE, name)


def write_secret(name, text):
    os.makedirs(STATE, exist_ok=True)
    path = secret_file(name)
    fd = os.open(path + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(path + ".new", path)


@contextlib.contextmanager
def forward(port=PORT):
    """A port-forward to vault-0, held for the block."""
    p = subprocess.Popen(["kubectl", "-n", "vault", "port-forward", "pod/vault-0", "%d:8200" % port],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            with contextlib.suppress(OSError):
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            if p.poll() is not None:
                raise SystemExit("vault: the port-forward to vault-0 ended")
            time.sleep(0.5)
        else:
            raise SystemExit("vault: no port-forward to vault-0 after 30 s")
        yield
    finally:
        p.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            p.wait(5)


_ctx = None


def call(method, path, body=None, token=None, port=PORT, timeout=30):
    """(status, JSON) from Vault's API. Error bodies are kept to Vault's own
    messages, which name no token."""
    global _ctx
    if _ctx is None:
        _ctx = ssl.create_default_context(cafile=secret_file("ca.crt"))
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Vault-Token"] = token
    req = urllib.request.Request("https://127.0.0.1:%d/v1/%s" % (port, path), method=method, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        with e:
            raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else None
        except ValueError:
            return e.code, None


def must(status_body, what):
    status, body = status_body
    if status not in (200, 204):
        raise SystemExit("vault: %s answered HTTP %d: %s" % (what, status, "; ".join((body or {}).get("errors", []))[:300]))
    return body


def health():
    with contextlib.suppress(OSError):
        return call("GET", "sys/health?standbyok=true&sealedcode=200&uninitcode=200")[1]
    return None


def wait_pod():
    for _ in range(150):
        phase = kubectl("-n", "vault", "get", "pod", "vault-0", "-o", "jsonpath={.status.phase}", check=False)
        if phase == "Running":
            return
        time.sleep(2)
    raise SystemExit("vault: vault-0 is not running after 300 s")


def unseal_with_shares():
    shares = json.load(open(secret_file("init.json")))["keys_base64"]
    for share in shares[:THRESHOLD]:
        state = must(call("PUT", "sys/unseal", {"key": share}), "unseal")
    if state["sealed"]:
        raise SystemExit("vault: still sealed after %d shares" % THRESHOLD)
    for _ in range(60):
        if call("GET", "sys/health")[0] == 200:
            return
        time.sleep(1)
    raise SystemExit("vault: unsealed but not active after 60 s")


def template(accessor, scope):
    # The claims Vault adds to each credential: its scope, and the service
    # account that asked, so the records service can log who called.
    alias = "identity.entity.aliases.%s.metadata" % accessor
    return ('{"scope": %s, "k8s_namespace": {{%s.service_account_namespace}}, '
            '"k8s_service_account": {{%s.service_account_name}}}' % (json.dumps(scope), alias, alias))


def configure(root):
    setup = json.load(open(os.path.join(SETUP, "setup.json")))
    # Every request and response, tokens hashed, to the pod's log.
    must(call("PUT", "sys/audit/stdout", {"type": "file", "options": {"file_path": "stdout"}}, root), "audit device")
    must(call("POST", "sys/auth/kubernetes", {"type": "kubernetes"}, root), "enabling Kubernetes auth")
    accessor = must(call("GET", "sys/auth", None, root), "reading auth methods")["data"]["kubernetes/"]["accessor"]
    # The API server by address, so Vault needs no DNS; its CA and the
    # token Vault calls TokenReview with are the pod's own.
    host = kubectl("-n", "default", "get", "service", "kubernetes", "-o", "jsonpath={.spec.clusterIP}")
    port = kubectl("-n", "default", "get", "service", "kubernetes", "-o", "jsonpath={.spec.ports[0].port}")
    must(call("POST", "auth/kubernetes/config", {"kubernetes_host": "https://%s:%s" % (host, port)}, root), "Kubernetes auth config")
    for name in ("records-caller", "operator"):
        must(call("PUT", "sys/policies/acl/" + name, {"policy": open(os.path.join(SETUP, name + ".hcl")).read()}, root),
             "policy " + name)
    k8s = dict(setup["kubernetes_role"])
    must(call("POST", "auth/kubernetes/role/" + k8s.pop("name"), k8s, root), "Kubernetes role")
    must(call("POST", "identity/oidc/config", {"issuer": setup["oidc_issuer"]}, root), "issuer")
    key = dict(setup["key"])
    must(call("POST", "identity/oidc/key/" + key.pop("name"), key, root), "signing key")
    role = dict(setup["role"])
    body = {"key": role["key"], "client_id": role["client_id"], "ttl": role["ttl"],
            "template": template(accessor, role["scope"])}
    must(call("POST", "identity/oidc/role/" + role["name"], body, root), "credential role")
    op = must(call("POST", "auth/token/create-orphan", {"policies": ["operator"], "no_default_policy": True,
                                                         "renewable": False, "ttl": "4h", "display_name": "operator"}, root),
              "operator token")
    write_secret("operator.token", op["auth"]["client_token"])
    return accessor


def write_keys():
    jwks = must(call("GET", "identity/oidc/.well-known/keys"), "key set")
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "records-api-keys", "namespace": "corp"},
          "data": {"jwks.json": json.dumps(jwks, sort_keys=True)}}
    kubectl("apply", "-f", "-", stdin=json.dumps(cm))
    return len(jwks["keys"])


def install():
    start = time.time()
    wait_pod()
    with forward():
        for _ in range(60):
            h = health()
            if h:
                break
            time.sleep(1)
        else:
            raise SystemExit("vault: no answer from vault-0 after 60 s")
        fresh = not h["initialized"]
        if fresh:
            # Init writes the keyring to a volume attached seconds before:
            # AWS run 42458107487 waited 10 s for its answer and gave up, and
            # an init answered to nobody leaves shares no one holds.
            init = must(call("PUT", "sys/init", {"secret_shares": SHARES, "secret_threshold": THRESHOLD}, timeout=120), "init")
            # The shares and the root token reach the disk before anything
            # else is done with them: a run that stops here can unseal again.
            write_secret("init.json", json.dumps({"keys_base64": init["keys_base64"], "root_token": init["root_token"]}))
            say("Vault initialised: %d shares, %d to unseal, written to .cache/airgap/vault/init.json (mode 600)" % (SHARES, THRESHOLD))
        if call("GET", "sys/seal-status")[1]["sealed"]:
            unseal_with_shares()
        saved = json.load(open(secret_file("init.json")))
        if saved.get("root_token"):
            root = saved["root_token"]
            accessor = configure(root)
            # The root token's work is done: revoked, and dropped from the file.
            must(call("POST", "auth/token/revoke-self", {}, root), "revoking the root token")
            write_secret("init.json", json.dumps({"keys_base64": saved["keys_base64"]}))
            say("Vault configured (Kubernetes auth %s, role mcp-server, key records, role records-api); root token revoked" % accessor)
        n = write_keys()
    seconds = round(time.time() - start, 1)
    with open(os.path.join(STATE, "install.json"), "w") as f:
        json.dump({"seconds": seconds, "fresh": fresh}, f)
    say("Vault 2.2.1 up, unsealed and configured in %.1f s; its key set (%d keys) written for the records service" % (seconds, n))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "install":
        install()
    elif cmd == "unseal":
        with forward():
            unseal_with_shares()
        say("Vault unsealed with %d of %d shares" % (THRESHOLD, SHARES))
    elif cmd == "keys":
        with forward():
            n = write_keys()
        say("Vault's key set (%d keys) written for the records service" % n)
    else:
        print("usage: vault_api.py <install|unseal|keys>", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
