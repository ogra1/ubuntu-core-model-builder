#!/usr/bin/env python3
"""Mock Snap Store + Ubuntu One SSO server for testing the Dart FFI binding.

Emulates the endpoints the Rust driver talks to (same shapes as the
Rust integration test / craft-store fixtures):

  POST /dev/api/acl/               -> {"macaroon": "<v1 binary>"}
  POST /api/v2/tokens/discharge    -> {"discharge_macaroon": "<v1 binary>"}
                                       or 401 {"code": "TWOFACTOR_REQUIRED", ...}
  GET  /api/v2/tokens/whoami       -> {"account": {id, email, username,
                                                  display-name},
                                       "permissions": [...], "expires": "..."}
  GET  /dev/api/account            -> {"account_id", "account_keys": [...],
                                       "stores": [...], "snaps": [...]}
  POST /dev/api/account/account-key-> 200/401 (validates Authorization)

Authenticated endpoints (whoami / account / account-key) require a
`Macaroon root=..., discharge=...` Authorization header — requests without
one get a 401, mirroring the real store.

Behaviour is controlled by flags (see --help). The macaroons served are the
pymacaroons-generated fixtures from the Rust integration test, so the Rust
side's parse/bind/serialize path is exercised for real.

Run:  python3 example/mock_store.py --port 8471 --two-factor --password s3cret

Two-factor is OFF by default (a correct password discharges immediately, a
wrong one gets 401 BAD_CREDENTIALS). Pass --two-factor to make the first
OTP-less discharge answer 401 twofactor-required, which is what exercises
the 2FA challenge pause. --no-two-factor is accepted as an explicit alias
for the default.
"""

import argparse
import json
import socket
import sys
import threading

# Fixtures from snapstore-auth/tests/integration.rs (pymacaroons-generated).
ROOT_MACAROON = (
    "MDAyY2xvY2F0aW9uIGh0dHBzOi8vZGFzaGJvYXJkLnNuYXBjcmFmdC5pbwowMDE5aWRlbnRpZmllciByb290LWlkLTEK"
    "MDAxMGNpZCBjaWQtMDAxCjAwNTF2aWQgDVQZMibgN_0yFc5ogte1xjxpKc5XmjPtPUWWYjviSULNh5-nmPcN1s6-h-c8"
    "qSgmFQvO8Iy__a9fehkpatZve0PCpRiUI3hNCjAwMzhjbCBodHRwczovL2xvZ2luLnVidW50dS5jb20vYXBpL3YyL3Rv"
    "a2Vucy9kaXNjaGFyZ2UKMDAyZnNpZ25hdHVyZSC0CqFfWTisBnfUsDI0y9i5xkTUuL-BFCOwFXL2EJj9dwo"
)
DISCHARGE_MACAROON = (
    "MDAyNmxvY2F0aW9uIGh0dHBzOi8vbG9naW4udWJ1bnR1LmNvbQowMDFiaWRlbnRpZmllciBkaXNjaGFyZ2UtMQo"
    "wMDBmc2lnbmF0dXJlIAo"
)

TWO_FACTOR_BODY = json.dumps({
    "code": "TWOFACTOR_REQUIRED",
    "message": "OTP required",
    "error_list": [
        {"code": "twofactor-required", "message": "OTP required"}
    ],
})
BAD_CREDENTIALS_BODY = json.dumps({
    "code": "BAD_CREDENTIALS",
    "message": "Invalid password",
    "error_list": [
        {"code": "invalid-credentials", "message": "Invalid password"}
    ],
})
UNAUTHENTICATED_BODY = json.dumps({
    "code": "UNAUTHENTICATED",
    "message": "Authorization: Macaroon required",
})

# Returned for authenticated calls when --reject-macaroon is set: simulates a
# session whose macaroon pair has expired / is no longer honoured, while the
# in-process state machine still believes it is signed in. This is exactly the
# condition the "recover from expired macaroon on key registration" fix must
# handle (see RustKeyService._isExpiredCredential / KeyAuthExpiredException).
EXPIRED_MACAROON_BODY = json.dumps({
    "code": "EXPIRED_MACAROON",
    "message": "macaroon is expired, try to refresh it",
    "error_list": [
        {"code": "expired-macaroon", "message": "macaroon is expired, try to refresh it"}
    ],
})

# Account object — mirrors what snapcraft's `whoami` / `keys` commands parse.
ACCOUNT_INFO_BODY = {
    "account_id": "DEADBEEF1234DEADBEEF1234DEADBEEF1234DEAD",
    "account": {
        "id": "DEADBEEF1234DEADBEEF1234DEADBEEF1234DEAD",
        "email": "mock@example.com",
        "username": "mockuser",
        "display-name": "Mock User",
    },
    "account_keys": [
        {
            "name": "mock-key-1",
            "public-key-sha3-384": "aabbccdd00112233445566aabbccdd00112233445566",
            "created-at": "2026-01-01T00:00:00+00:00",
        },
        {
            "name": "mock-key-2",
            "public-key-sha3-384": "ffeeddccb0123456789012ffeeddccb0123456789012",
            "created-at": "2026-02-01T00:00:00+00:00",
        },
    ],
    "stores": [
        {"id": "ubuntu", "name": "Ubuntu", "roles": ["owner"]},
        {
            "id": "mock-brand",
            "name": "Mock Brand",
            "roles": ["admin", "package_publisher"],
        },
    ],
    "snaps": [
        {"name": "mock-snap-1", "id": "snapid-1"},
        {"name": "mock-snap-2", "id": "snapid-2"},
    ],
    "permissions": ["package_access", "package_push"],
    "expires": "2026-10-15T12:00:00+00:00",
}

CONFIG = {}
REGISTERED_KEYS = []


def has_macaroon(headers: dict) -> bool:
    auth = headers.get("authorization", "")
    return auth.startswith("Macaroon root=") and "discharge=" in auth


def handle(conn: socket.socket) -> None:
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(65536)
            if not chunk:
                return
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        head_text = head.decode("latin-1")
        lines = head_text.split("\r\n")
        method_path = lines[0].split(" ")
        method = method_path[0] if method_path else ""
        path = method_path[1] if len(method_path) > 1 else ""
        content_length = 0
        headers = {}
        for line in lines[1:]:
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
            if k.strip().lower() == "content-length":
                content_length = int(v.strip())
        body = rest
        while len(body) < content_length:
            chunk = conn.recv(65536)
            if not chunk:
                break
            body += chunk
        body = body[:content_length].decode("utf-8", "replace")
        payload = json.loads(body) if body else {}

        status, resp = route(method, path, headers, payload)
        resp_bytes = resp.encode("utf-8")
        reason = {
            200: "OK",
            201: "Created",
            400: "Bad Request",
            401: "Unauthorized",
            404: "Not Found",
        }.get(status, "Error")
        raw = (
            f"HTTP/1.1 {status} {reason}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(resp_bytes)}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("latin-1") + resp_bytes
        conn.sendall(raw)
        print(f"[mock] {method} {path} -> {status}", file=sys.stderr, flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[mock] handler error: {exc}", file=sys.stderr, flush=True)
    finally:
        conn.close()


def route(method: str, path: str, headers: dict, payload: dict) -> tuple[int, str]:
    # --- public (login flow) ---
    if method == "POST" and path == "/dev/api/acl/":
        # The current snap-store root-macaroon endpoint (U1_SNAP_STORE
        # protocol); the legacy /v1/tokens/usso path is gone from the
        # real store (404).
        return 200, json.dumps({"macaroon": ROOT_MACAROON})

    if method == "POST" and path == "/api/v2/tokens/discharge":
        password = payload.get("password", "")
        otp = payload.get("otp", "")
        if CONFIG["two_factor"] and not otp:
            return 401, TWO_FACTOR_BODY
        if password != CONFIG["password"]:
            return 401, BAD_CREDENTIALS_BODY
        if CONFIG["two_factor"] and otp != CONFIG["good_code"]:
            return 401, TWO_FACTOR_BODY
        return 200, json.dumps({"discharge_macaroon": DISCHARGE_MACAROON})

    # --- test control (public: no macaroon, used by the Dart e2e tests) ---
    if method == "GET" and path == "/__registered":
        # The account-key assertions this mock has recorded (tests assert
        # the upload reached the store). Not part of the real store API.
        return 200, json.dumps({"keys": REGISTERED_KEYS})

    if method == "POST" and path == "/__reject":
        # Flip the "macaroon no longer honoured" mode at runtime (tests
        # log in against a healthy store, then simulate expiry). Not part
        # of the real store API.
        CONFIG["reject_macaroon"] = not CONFIG["reject_macaroon"]
        return 200, json.dumps({"reject_macaroon": CONFIG["reject_macaroon"]})

    # --- authenticated ---
    if not has_macaroon(headers):
        return 401, UNAUTHENTICATED_BODY
    if CONFIG["reject_macaroon"]:
        # The request carries a macaroon (a logged-in session) but the store
        # no longer honours it — 401 on every authenticated endpoint.
        return 401, EXPIRED_MACAROON_BODY

    if method == "GET" and path == "/api/v2/tokens/whoami":
        return 200, json.dumps(ACCOUNT_INFO_BODY)

    if method == "GET" and path == "/dev/api/account":
        body = dict(ACCOUNT_INFO_BODY)
        return 200, json.dumps(body)

    if method == "GET" and path.startswith("/api/v2/stores/") and path.endswith("/snaps"):
        # Brand-store catalog (auth required — checked above).
        return 200, json.dumps({
            "snaps": [
                {"name": "mock-gadget", "id": "gadget-1"},
                {"name": "mock-kernel", "id": "kernel-1"},
            ]
        })

    if method == "POST" and path == "/dev/api/account/account-key":
        assertion = payload.get("account_key_request", "")
        if not assertion:
            return 400, json.dumps(
                {"code": "BAD_REQUEST", "message": "account_key_request missing"}
            )
        REGISTERED_KEYS.append(assertion)
        return 201, json.dumps({"status": "ok"})

    return 404, json.dumps({"message": "not found"})


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8471)
    ap.add_argument("--two-factor", action="store_true",
                    help="first discharge (no otp) returns 401 twofactor-required")
    ap.add_argument("--no-two-factor", dest="two_factor",
                    action="store_false",
                    help="no 2FA challenge (default): a wrong password is "
                         "answered with 401 BAD_CREDENTIALS directly")
    ap.add_argument("--good-code", default="654321",
                    help="the 2FA code that succeeds (default 654321)")
    ap.add_argument("--reject-macaroon", action="store_true",
                    help="authenticated endpoints answer 401 'macaroon is "
                         "expired' (simulates an expired session; login still works)")
    ap.add_argument("--password", default="s3cret",
                    help="the password that succeeds (default s3cret)")
    args = ap.parse_args()

    CONFIG.update({
        "two_factor": args.two_factor,
        "good_code": args.good_code,
        "password": args.password,
        "reject_macaroon": args.reject_macaroon,
    })

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(16)
    print(f"[mock] listening on http://127.0.0.1:{args.port} "
          f"(two_factor={args.two_factor})", file=sys.stderr, flush=True)
    while True:
        conn, _addr = server.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
