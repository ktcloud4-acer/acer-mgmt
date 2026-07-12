#!/usr/bin/env python3
"""Patch one KV v2 secret field without exposing either secret or token.

The Vault CLI's ``vault kv patch`` first reads ``sys/internal/ui/mounts`` to
discover the mount type. A least-privilege deployment token may deliberately
have PATCH access to one KV path without access to that system metadata. This
helper calls the already-known KV v2 endpoint directly.

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
    return parser.parse_args()


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

    payload = json.dumps(
        {"data": {args.field: secret_text}}, separators=(",", ":")
    ).encode("utf-8")
    context = ssl.create_default_context(cafile=str(ca_cert))
    raw_socket = socket.create_connection((vault_ip, 8200), timeout=10)
    tls_socket = context.wrap_socket(raw_socket, server_hostname=args.server_name)
    connection = http.client.HTTPConnection(vault_ip, 8200, timeout=10)
    connection.sock = tls_socket

    try:
        connection.putrequest(
            "PATCH", f"/v1/{mount}/data/{secret_path}", skip_host=True
        )
        connection.putheader("Host", args.server_name)
        connection.putheader("X-Vault-Request", "true")
        connection.putheader("X-Vault-Token", vault_token)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Content-Length", str(len(payload)))
        connection.endheaders(payload)
        response = connection.getresponse()
        status = response.status
        response.read()
    finally:
        connection.close()

    if not 200 <= status < 300:
        raise RuntimeError(f"Vault KV v2 PATCH returned HTTP {status}")

    print("Vault KV v2 secret field patched.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # Keep API response bodies and secret material private.
        print(f"Vault KV v2 PATCH failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
