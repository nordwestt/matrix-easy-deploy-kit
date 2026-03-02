#!/usr/bin/env python3

import argparse
import base64
import copy
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


def b64u(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii").rstrip("=")


def canonical_json_bytes(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def signable_copy(obj: dict) -> dict:
    cloned = copy.deepcopy(obj)
    cloned.pop("signatures", None)
    cloned.pop("unsigned", None)
    return cloned


def api_request(method: str, url: str, token: str | None = None, body: dict | None = None) -> tuple[int, dict]:
    headers = {"Accept": "application/json"}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, data=payload, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return resp.getcode(), json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {"error": raw}
        return exc.code, data


def run_openssl(*args: str, stdin_data: bytes | None = None) -> bytes:
    proc = subprocess.run(
        ["openssl", *args],
        input=stdin_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace").strip() or "openssl failed")
    return proc.stdout


def generate_ed25519_keypair() -> tuple[str, str, bytes, bytes]:
    with tempfile.TemporaryDirectory() as tmp:
        priv = os.path.join(tmp, "key.pem")
        run_openssl("genpkey", "-algorithm", "Ed25519", "-out", priv)
        priv_pem = open(priv, "rb").read()

        pub_der = run_openssl("pkey", "-in", priv, "-pubout", "-outform", "DER")
        if len(pub_der) < 32:
            raise RuntimeError("unexpected Ed25519 DER public key")
        pub_raw = pub_der[-32:]

        return priv, priv_pem.decode("utf-8"), pub_raw, pub_der


def sign_json(obj: dict, key_path: str) -> str:
    data = canonical_json_bytes(signable_copy(obj))
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp.write(data)
        data_path = tmp.name
    try:
        sig = run_openssl("pkeyutl", "-sign", "-inkey", key_path, "-rawin", "-in", data_path)
    finally:
        os.unlink(data_path)
    return b64u(sig)


def add_signature(target: dict, signer_mxid: str, signer_key_id: str, signature: str) -> None:
    sigs = target.setdefault("signatures", {})
    sigs.setdefault(signer_mxid, {})[f"ed25519:{signer_key_id}"] = signature


def upload_cross_signing(base: str, token: str, mxid: str, password: str, keys_payload: dict) -> None:
    endpoints = [
        f"{base}/_matrix/client/v3/keys/device_signing/upload",
        f"{base}/_matrix/client/unstable/keys/device_signing/upload",
    ]

    last_err = None
    for url in endpoints:
        status, data = api_request("POST", url, token=token, body=keys_payload)
        if status in (200, 201):
            return
        if status == 401 and isinstance(data, dict) and data.get("session"):
            retry_payload = copy.deepcopy(keys_payload)
            retry_payload["auth"] = {
                "type": "m.login.password",
                "identifier": {"type": "m.id.user", "user": mxid},
                "password": password,
                "session": dataautomatic ["session"],
            }
            status2, data2 = api_request("POST", url, token=token, body=retry_payload)
            if status2 in (200, 201):
                return
            last_err = f"{url} -> {status2} {data2}"
            continue
        last_err = f"{url} -> {status} {data}"

    raise RuntimeError(f"failed to upload cross-signing keys: {last_err}")


def upload_key_signatures(base: str, token: str, signed_keys: dict) -> None:
    url = f"{base}/_matrix/client/v3/keys/signatures/upload"
    status, data = api_request("POST", url, token=token, body=signed_keys)
    if status in (200, 201):
        return

    wrapped = {"signed_keys": signed_keys}
    status2, data2 = api_request("POST", url, token=token, body=wrapped)
    if status2 in (200, 201):
        return

    raise RuntimeError(f"failed to upload key signatures: {status} {data} / {status2} {data2}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Bootstrap cross-signing and self-sign a device.")
    parser.add_argument("--homeserver", required=True, help="Homeserver base URL, e.g. https://matrix.example.com")
    parser.add_argument("--mxid", required=True, help="User ID to bootstrap, e.g. @hookshot:example.com")
    parser.add_argument("--password", required=True, help="Password for the user")
    parser.add_argument("--device-name", default="Hookshot Trusted Device", help="Device display name for login")
    parser.add_argument("--secrets-out", required=True, help="Path to write bootstrap secrets JSON")
    args = parser.parse_args()

    base = args.homeserver.rstrip("/")

    login_status, login_data = api_request(
        "POST",
        f"{base}/_matrix/client/v3/login",
        body={
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": args.mxid},
            "password": args.password,
            "initial_device_display_name": args.device_name,
        },
    )
    if login_status not in (200, 201):
        raise RuntimeError(f"bot login failed: {login_status} {login_data}")

    access_token = login_data.get("access_token")
    user_id = login_data.get("user_id")
    device_id = login_data.get("device_id")
    if not access_token or not user_id or not device_id:
        raise RuntimeError("login response missing access_token/user_id/device_id")

    query_status, query_data = api_request(
        "POST",
        f"{base}/_matrix/client/v3/keys/query",
        token=access_token,
        body={"device_keys": {user_id: [device_id]}},
    )
    if query_status not in (200, 201):
        raise RuntimeError(f"keys/query failed: {query_status} {query_data}")

    device_obj = (
        query_data.get("device_keys", {})
        .get(user_id, {})
        .get(device_id)
    )
    if not isinstance(device_obj, dict):
        raise RuntimeError(f"could not read device keys for {user_id} {device_id}")

    master_key_path, master_priv_pem, master_pub_raw, _ = generate_ed25519_keypair()
    self_key_path, self_priv_pem, self_pub_raw, _ = generate_ed25519_keypair()
    user_key_path, user_priv_pem, user_pub_raw, _ = generate_ed25519_keypair()

    master_kid = b64u(master_pub_raw)
    self_kid = b64u(self_pub_raw)
    user_kid = b64u(user_pub_raw)

    master = {
        "user_id": user_id,
        "usage": ["master"],
        "keys": {f"ed25519:{master_kid}": b64u(master_pub_raw)},
    }
    add_signature(master, user_id, master_kid, sign_json(master, master_key_path))

    self_signing = {
        "user_id": user_id,
        "usage": ["self_signing"],
        "keys": {f"ed25519:{self_kid}": b64u(self_pub_raw)},
    }
    add_signature(self_signing, user_id, master_kid, sign_json(self_signing, master_key_path))

    user_signing = {
        "user_id": user_id,
        "usage": ["user_signing"],
        "keys": {f"ed25519:{user_kid}": b64u(user_pub_raw)},
    }
    add_signature(user_signing, user_id, master_kid, sign_json(user_signing, master_key_path))

    upload_cross_signing(
        base=base,
        token=access_token,
        mxid=user_id,
        password=args.password,
        keys_payload={
            "master_key": master,
            "self_signing_key": self_signing,
            "user_signing_key": user_signing,
        },
    )

    signed_device = copy.deepcopy(device_obj)
    add_signature(signed_device, user_id, self_kid, sign_json(signed_device, self_key_path))
    upload_key_signatures(base, access_token, {user_id: {device_id: signed_device}})

    os.makedirs(os.path.dirname(args.secrets_out), exist_ok=True)
    with open(args.secrets_out, "w", encoding="utf-8") as f:
        json.dump(
            {
                "user_id": user_id,
                "device_id": device_id,
                "master_key_id": f"ed25519:{master_kid}",
                "self_signing_key_id": f"ed25519:{self_kid}",
                "user_signing_key_id": f"ed25519:{user_kid}",
                "master_private_key_pem": master_priv_pem,
                "self_signing_private_key_pem": self_priv_pem,
                "user_signing_private_key_pem": user_priv_pem,
            },
            f,
            indent=2,
        )

    print(json.dumps({"ok": True, "user_id": user_id, "device_id": device_id}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as ex:
        print(f"ERROR: {ex}", file=sys.stderr)
        raise SystemExit(1)
