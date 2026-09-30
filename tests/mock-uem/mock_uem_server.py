#!/usr/bin/env python3
"""
Minimal HTTPS mock of the Workspace ONE UEM REST endpoints used by this repo's
scripts. For offline testing only: NOT a model of real UEM behaviour. Response shapes
follow the OpenAPI specs (euc-dev/ws1-uem-apis 2410-2607); status codes and headers
for throttling are scripted by the tests because the real ones are undocumented.

Endpoints
  POST /connect/token                          OAuth client_credentials (Basic client auth)
  GET  /api/mdm/smartgroups/{id}
  GET  /api/mdm/smartgroups/search
  GET  /api/mdm/smartgroups/{id}/devices
  POST /api/mdm/devices/{id}/commands?command=X
  GET  /api/mam/apps/purchased/search          (VPP report script)
  GET  /api/mam/apps/purchased/{uuid|id}       (detail; V1 501 for the flexible app)
Control (test harness only)
  POST /__control   JSON: reset | command_script | quota | search_ignores_page
  GET  /__log       request log (auth scheme + header names, never secrets)

Auth accepted: "Bearer tok123", or Basic apiuser:apipass together with aw-tenant-code: TENANT123.
"""
import base64, json, ssl, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE = {}
LOCK = threading.Lock()


def reset():
    STATE.clear()
    STATE.update(
        log=[],
        command_script=[],          # consumed one per command POST: int or {"status":..,"retry_after":..}
        quota_limit=5000,
        quota_remaining=5000,
        quota_reset=int(time.time()) + 300,
        quota_enabled=True,
        search_ignores_page=False,
    )


reset()

SG_ID, SG_UUID = 42, "59720b59-88e5-4ea8-b6d7-66d6b5fe1614"
DEVICES = (
    [{"Id": str(1001 + i), "Name": f"dev-{i}", "Model": "iPhone", "OSVersion": "17", "Username": "u", "Platform": "Apple", "Ownership": "C"} for i in range(12)]
    + [{"Id": str(2001 + i), "Name": f"and-{i}", "Model": "Pixel", "OSVersion": "14", "Username": "u", "Platform": "Android", "Ownership": "C"} for i in range(3)]
)
APPS = [
    {"ApplicationName": "App One", "BundleId": "com.one", "Platform": 2, "LocationGroupId": 7, "Uuid": "11111111-1111-1111-1111-111111111111",
     "Id": {"Value": 501}, "RootOrganizationGroupName": "Org",
     "ManagedDistribution": {"Purchased": 55, "Burned": 3, "OnHold": 0, "Available": 52},
     "Assignments": [{"SmartGroupId": 42, "Allocated": 5, "Redeemed": 3}]},
    {"ApplicationName": "App Flex", "BundleId": "com.flex", "Platform": 2, "LocationGroupId": 7, "Uuid": "22222222-2222-2222-2222-222222222222",
     "Id": {"Value": 502}, "RootOrganizationGroupName": "Org",
     "ManagedDistribution": {"Purchased": 10, "Burned": 9, "OnHold": 0, "Available": 1},
     "Assignments": [{"SmartGroupId": 42, "Allocated": 10, "Redeemed": 9}]},
]


def auth_info(headers):
    a = headers.get("Authorization", "")
    tenant = headers.get("aw-tenant-code")
    if a == "Bearer tok123":
        return "bearer", True, tenant is not None
    if a.startswith("Basic "):
        try:
            u, p = base64.b64decode(a[6:]).decode().split(":", 1)
        except Exception:
            return "basic", False, tenant is not None
        return "basic", (u == "apiuser" and p == "apipass" and tenant == "TENANT123"), tenant is not None
    return "none", False, tenant is not None


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, status, body=None, extra=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if STATE["quota_enabled"] and self.path.startswith("/api/"):
            now = int(time.time())
            if now >= STATE["quota_reset"]:
                STATE["quota_remaining"] = STATE["quota_limit"]
                STATE["quota_reset"] = now + 300
            self.send_header("x-ratelimit-limit", str(STATE["quota_limit"]))
            self.send_header("x-ratelimit-remaining", str(STATE["quota_remaining"]))
            self.send_header("x-ratelimit-reset", str(STATE["quota_reset"]))
        for k, v in (extra or {}).items():
            self.send_header(k, str(v))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _record(self, scheme, ok, has_tenant, status=None):
        STATE["log"].append({"method": self.command, "path": self.path.split("?")[0], "query": self.path.partition("?")[2],
                             "auth": scheme, "auth_ok": ok, "tenant_header": has_tenant,
                             "accept": (self.headers.get("Accept") or "").replace(" ", ""), "status": status})

    def _handle(self):
        with LOCK:
            u = urlparse(self.path)
            path, q = u.path, parse_qs(u.query)
            raw = self._body()

            if path == "/__control":
                c = json.loads(raw or b"{}")
                if c.get("reset"):
                    reset()
                for k in ("command_script", "quota_limit", "quota_remaining", "quota_reset", "quota_enabled", "search_ignores_page"):
                    if k in c:
                        STATE[k] = c[k]
                return self._send(200, {"ok": True})
            if path == "/__log":
                return self._send(200, STATE["log"])

            if path == "/connect/token":
                a = self.headers.get("Authorization", "")
                ok = a.startswith("Basic ") and base64.b64decode(a[6:]).decode() == "cid:csecret"
                STATE["log"].append({"method": "POST", "path": path, "auth": "basic-client", "auth_ok": ok, "tenant_header": False, "status": 200 if ok else 401})
                return self._send(200, {"access_token": "tok123", "token_type": "Bearer"}) if ok else self._send(401, {"error": "invalid_client"})

            scheme, ok, tenant = auth_info(self.headers)
            if not ok:
                self._record(scheme, False, tenant, 401)
                return self._send(401, {"errorCode": 401, "message": "Unauthorized"})

            if STATE["quota_enabled"]:
                STATE["quota_remaining"] = max(0, STATE["quota_remaining"] - 1)

            # --- smart groups
            if self.command == "GET" and path == "/api/mdm/smartgroups/search":
                page = int((q.get("page") or ["0"])[0])
                items = [{"Name": "Test SG", "SmartGroupID": SG_ID, "SmartGroupUuid": SG_UUID, "Devices": len(DEVICES)}] if (page == 0 or STATE["search_ignores_page"]) else []
                self._record(scheme, True, tenant, 200)
                return self._send(200, {"Page": page, "PageSize": 500, "Total": 1, "SmartGroups": items})
            if self.command == "GET" and path == f"/api/mdm/smartgroups/{SG_ID}":
                self._record(scheme, True, tenant, 200)
                return self._send(200, {"Name": "Test SG", "SmartGroupID": SG_ID, "SmartGroupUuid": SG_UUID, "Devices": len(DEVICES)})
            if self.command == "GET" and path == f"/api/mdm/smartgroups/{SG_ID}/devices":
                self._record(scheme, True, tenant, 200)
                return self._send(200, {"Devices": DEVICES})

            # --- commands
            if self.command == "POST" and path.startswith("/api/mdm/devices/") and path.endswith("/commands"):
                dev = path.split("/")[4]
                step = STATE["command_script"].pop(0) if STATE["command_script"] else 202
                if isinstance(step, int):
                    step = {"status": step}
                st = step["status"]
                extra = {"Retry-After": step["retry_after"]} if "retry_after" in step else {}
                self._record(scheme, True, tenant, st)
                STATE["log"][-1]["device"] = dev
                STATE["log"][-1]["command"] = (q.get("command") or [""])[0]
                return self._send(st, None if st == 202 else {"errorCode": st, "message": "scripted"}, extra)

            # --- VPP report script
            if self.command == "GET" and path == "/api/mam/apps/purchased/search":
                self._record(scheme, True, tenant, 200)
                return self._send(200, {"Application": APPS, "Total": len(APPS)})
            if self.command == "GET" and path.startswith("/api/mam/apps/purchased/"):
                self._record(scheme, True, tenant, 200)
                return self._send(501, {"message": "Not Implemented"})

            self._record(scheme, True, tenant, 404)
            return self._send(404, {"message": "not found: " + path})

    do_GET = do_POST = do_PUT = do_DELETE = _handle


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
    cert, key = sys.argv[2], sys.argv[3]
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()
