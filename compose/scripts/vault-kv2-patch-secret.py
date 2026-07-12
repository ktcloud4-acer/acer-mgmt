#!/usr/bin/env python3
"""Patch one KV v2 secret field without exposing either secret or token.

The Vault CLI's ``vault kv patch`` first reads ``sys/internal/ui/mounts`` to
discover the mount type. A least-privilege deployment token may deliberately
have PATCH access to one KV path without access to that system metadata. This
helper calls the already-known KV v2 endpoint directly. If the token has the
documented read/write form of KV patch permission instead of PATCH, an explicit
fallback reads the current version and writes a CAS-protected merged document.

The Keycloak client secret arrives only on stdin. The Vault token is read only
from the named file inside the Vault container. Neither value is written to a
file, command line, Docker environment, or output.
"""

from __future__ import annotations

import argparse
import http.client
import json
import socket
import ssl
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote


VAULT_TLS_MOUNT_TEMPLATE = (
    '{{range .Mounts}}{{if eq .Destination "/vault/tls"}}{{.Source}}{{end}}{{end}}'
)
VAULT_NETWORK_IP_TEMPLATE = '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\\n"}}{{end}}'


def docker_stdout(*args: str) -> str:
    """Run Docker without allowing its stdout/stderr to leak sensitive data."""
    completed = subprocess.run(
        ["docker", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError("required Docker inspection or token read failed")
    return completed.stdout


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Patch one Vault KV v2 field using a token stored in a container."
    )
    parser.add_argument("--vault-container", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--mount", required=True)
    parser.add_argument("--secret-path", required=True)
    parser.add_argument("--field", required=True)
    parser.add_argument("--server-name", default="vault")
    parser.add_argument(
        "--allow-rw-fallback",
        action="store_true",
        help="fall back to read + CAS-protected write when PATCH is denied",
    )
    return parser.parse_args()


def vault_request(
    *,
    context: ssl.SSLContext,
    vault_ip: str,
    server_name: str,
    token: str,
    method: str,
    endpoint: str,
    payload: bytes | None = None,
    content_type: str | None = None,
) -> tuple[int, bytes]:
    """Make one TLS-verified Vault request without logging its response body."""
    raw_socket = socket.create_connection((vault_ip, 8200), timeout=10)
    tls_socket = context.wrap_socket(raw_socket, server_hostname=server_name)
    connection = http.client.HTTPConnection(vault_ip, 8200, timeout=10)
    connection.sock = tls_socket

    try:
        connection.putrequest(method, endpoint, skip_host=True)
        connection.putheader("Host", server_name)
        connection.putheader("X-Vault-Request", "true")
        connection.putheader("X-Vault-Token", token)
        if content_type:
            connection.putheader("Content-Type", content_type)
        if payload is not None:
            connection.putheader("Content-Length", str(len(payload)))
        connection.endheaders(payload)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def main() -> int:
    args = parse_args()
    client_secret = sys.stdin.buffer.read()
    if not client_secret:
        raise RuntimeError("received an empty secret payload")

    vault_token = docker_stdout(
        "exec", args.vault_container, "cat", "--", args.token_file
    ).strip()
    if not vault_token:
        raise RuntimeError("Vault token file is empty")

    vault_tls_dir = docker_stdout(
        "inspect", "-f", VAULT_TLS_MOUNT_TEMPLATE, args.vault_container
    ).strip()
    ca_cert = Path(vault_tls_dir) / "ca.crt"
    if not ca_cert.is_file():
        raise RuntimeError("Vault CA certificate is unavailable on the Docker host")

    vault_ip = next(
        (
            value.strip()
            for value in docker_stdout(
                "inspect", "-f", VAULT_NETWORK_IP_TEMPLATE, args.vault_container
            ).splitlines()
            if value.strip()
        ),
        "",
    )
    if not vault_ip:
        raise RuntimeError("Vault container has no network IP address")

    mount = quote(args.mount.strip("/"), safe="")
    secret_path = "/".join(
        quote(segment, safe="")
        for segment in args.secret_path.strip("/").split("/")
        if segment
    )
    if not mount or not secret_path:
        raise RuntimeError("Vault mount and secret path must not be empty")

    try:
        secret_text = client_secret.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError("secret payload is not UTF-8") from exc

    patch_payload = json.dumps(
        {"data": {args.field: secret_text}}, separators=(",", ":")
    ).encode("utf-8")
    context = ssl.create_default_context(cafile=str(ca_cert))
    endpoint = f"/v1/{mount}/data/{secret_path}"
    status, _ = vault_request(
        context=context,
        vault_ip=vault_ip,
        server_name=args.server_name,
        token=vault_token,
        method="PATCH",
        endpoint=endpoint,
        payload=patch_payload,
        # KV v2 accepts partial updates only as JSON Merge Patch.
        content_type="application/merge-patch+json",
    )
    if 200 <= status < 300:
        print("Vault KV v2 secret field patched.")
        return 0
    if status != 403 or not args.allow_rw_fallback:
        raise RuntimeError(f"Vault KV v2 PATCH returned HTTP {status}")

    # This is the KV CLI's documented read/write patch strategy. The response
    # is parsed only in process memory and its version is used as a CAS guard,
    # so a concurrent change cannot be overwritten silently.
    read_status, read_response = vault_request(
        context=context,
        vault_ip=vault_ip,
        server_name=args.server_name,
        token=vault_token,
        method="GET",
        endpoint=endpoint,
    )
    if read_status != 200:
        raise RuntimeError(f"Vault KV v2 fallback read returned HTTP {read_status}")
    try:
        read_data = json.loads(read_response)
        envelope = read_data["data"]
        existing_data = dict(envelope["data"])
        version = envelope["metadata"]["version"]
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError("Vault KV v2 fallback read returned an invalid response") from exc
    if not isinstance(version, int) or version < 1:
        raise RuntimeError("Vault KV v2 fallback read has no usable version")

    existing_data[args.field] = secret_text
    write_payload = json.dumps(
        {"options": {"cas": version}, "data": existing_data}, separators=(",", ":")
    ).encode("utf-8")
    write_status, _ = vault_request(
        context=context,
        vault_ip=vault_ip,
        server_name=args.server_name,
        token=vault_token,
        method="POST",
        endpoint=endpoint,
        payload=write_payload,
        content_type="application/json",
    )
    if not 200 <= write_status < 300:
        raise RuntimeError(
            f"Vault KV v2 read/write fallback returned HTTP {write_status}"
        )

    print("Vault KV v2 secret field patched.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # Keep API response bodies and secret material private.
        print(f"Vault KV v2 PATCH failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
