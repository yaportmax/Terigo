#!/usr/bin/env python3

import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Dict, Optional


ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = ROOT / ".env"
SECRETS_XCCONFIG_PATH = ROOT / "Configuration" / "Secrets.xcconfig"
TERIGO_PUBLIC_SITE_URL = "https://maxyaport.com/terigo"


def load_key_value_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    if not path.exists():
        return values

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()

    return values


def normalize_xcconfig_url(value: Optional[str]) -> Optional[str]:
    if not value:
        return None

    normalized = value.strip()
    normalized = normalized.replace(":/$()/", "://")
    normalized = normalized.replace("/$()/", "//")
    normalized = normalized.replace("$()", "")
    return normalized or None


def request_json(
    url: str,
    *,
    method: str = "GET",
    body: Optional[dict] = None,
    headers: Optional[Dict[str, str]] = None,
    timeout: int = 30,
) -> tuple[int, dict]:
    payload = json.dumps(body).encode() if body is not None else None
    request_headers = dict(headers or {})
    if body is not None:
        request_headers.setdefault("Content-Type", "application/json")

    request = urllib.request.Request(
        url,
        data=payload,
        headers=request_headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.getcode()
            raw = response.read().decode()
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read().decode()
    except urllib.error.URLError as error:
        raise RuntimeError(f"{method} {url} failed: {error}") from error

    if not raw:
        return status, {}

    try:
        return status, json.loads(raw)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{method} {url} returned non-JSON payload") from error


def request_status(url: str, *, timeout: int = 30) -> int:
    request = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.getcode()
    except urllib.error.HTTPError as error:
        return error.code
    except urllib.error.URLError as error:
        raise RuntimeError(f"HEAD {url} failed: {error}") from error


def hostname_resolves(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    if not parsed.hostname:
        return False

    try:
        socket.getaddrinfo(parsed.hostname, parsed.port or 443)
    except socket.gaierror:
        return False

    return True


def print_results(results: Dict[str, object], failures: list[str], warnings: list[str]) -> None:
    print(json.dumps({
        "results": results,
        "failures": failures,
        "warnings": warnings,
    }, indent=2))


def main() -> int:
    env = load_key_value_file(ENV_PATH)
    secrets = load_key_value_file(SECRETS_XCCONFIG_PATH)

    required_env = [
        "STRAVA_CLIENT_ID",
        "STRAVA_REFRESH_TOKEN",
        "SUPABASE_URL",
        "SUPABASE_PUBLISHABLE_KEY",
    ]

    missing = [key for key in required_env if not env.get(key)]
    if missing:
        print(f"Missing required entries in {ENV_PATH}: {', '.join(missing)}", file=sys.stderr)
        return 1

    supabase_url = env["SUPABASE_URL"].rstrip("/")
    publishable_key = env["SUPABASE_PUBLISHABLE_KEY"]
    broker_base_url = normalize_xcconfig_url(secrets.get("ROUTE_VAULT_STRAVA_AUTH_BROKER_URL"))
    share_base_url = normalize_xcconfig_url(secrets.get("ROUTE_VAULT_SHARE_BASE_URL"))
    share_link_host = (secrets.get("ROUTE_VAULT_SHARE_LINK_HOST") or "").strip()

    results: Dict[str, object] = {}
    failures: list[str] = []
    warnings: list[str] = []

    if not hostname_resolves(supabase_url):
        failures.append(
            f"Supabase host for {supabase_url} does not resolve in DNS. "
            "Check that the Supabase project is active and update ROUTE_VAULT_SUPABASE_URL before installing or archiving the app."
        )

    if broker_base_url and not hostname_resolves(broker_base_url):
        failures.append(
            f"Strava auth broker host for {broker_base_url} does not resolve in DNS. "
            "Check that the backend project is active and update ROUTE_VAULT_STRAVA_AUTH_BROKER_URL."
        )

    if failures:
        print_results(results, failures, warnings)
        return 1

    support_status = request_status(f"{TERIGO_PUBLIC_SITE_URL}/support.html")
    privacy_status = request_status(f"{TERIGO_PUBLIC_SITE_URL}/privacy.html")
    results["support_page_status"] = support_status
    results["privacy_page_status"] = privacy_status
    if support_status != 200:
        failures.append(f"Support page returned HTTP {support_status}.")
    if privacy_status != 200:
        failures.append(f"Privacy page returned HTTP {privacy_status}.")

    refresh_status, refresh_payload = request_json(
        f"{supabase_url}/functions/v1/strava-auth-broker/refresh",
        method="POST",
        body={
            "client_id": env["STRAVA_CLIENT_ID"],
            "refresh_token": env["STRAVA_REFRESH_TOKEN"],
        },
    )
    results["broker_refresh_status"] = refresh_status
    if refresh_status != 200 or not refresh_payload.get("access_token"):
        failures.append("Strava auth broker refresh flow did not return a usable access token.")
        access_token = None
    else:
        access_token = refresh_payload["access_token"]

    if broker_base_url:
        exchange_status, _ = request_json(
            f"{broker_base_url.rstrip('/')}/exchange",
            method="POST",
            body={
                "client_id": env["STRAVA_CLIENT_ID"],
                "code": "invalid-code",
                "redirect_uri": "routevault://localhost/oauth-callback",
            },
        )
        results["broker_exchange_invalid_code_status"] = exchange_status
        if exchange_status != 400:
            failures.append(f"Broker exchange invalid-code probe returned HTTP {exchange_status}, expected 400.")

    athlete = {}
    if access_token:
        athlete_request = urllib.request.Request(
            "https://www.strava.com/api/v3/athlete",
            headers={"Authorization": f"Bearer {access_token}"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(athlete_request, timeout=30) as response:
                athlete = json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            failures.append(f"Strava athlete fetch failed with HTTP {error.code}.")
        except urllib.error.URLError as error:
            failures.append(f"Strava athlete fetch failed: {error}.")

    session_token = None
    first_share_token = None
    if athlete and access_token:
        bootstrap_status, bootstrap_payload = request_json(
            f"{supabase_url}/functions/v1/account-bootstrap",
            method="POST",
            body={
                "stravaSession": {
                    "accessToken": access_token,
                    "refreshToken": refresh_payload.get("refresh_token"),
                    "expiresAt": str(refresh_payload.get("expires_at")),
                    "acceptedScopes": ["read"],
                    "athlete": {
                        "id": athlete.get("id"),
                        "username": athlete.get("username"),
                        "firstName": athlete.get("firstname"),
                        "lastName": athlete.get("lastname"),
                        "profileMedium": athlete.get("profile_medium"),
                        "profile": athlete.get("profile"),
                    },
                },
                "device": {
                    "platform": "backend-verifier",
                    "appVersion": "backend-verifier",
                    "buildNumber": "1",
                },
            },
            headers={
                "apikey": publishable_key,
                "Authorization": f"Bearer {publishable_key}",
            },
        )
        results["account_bootstrap_status"] = bootstrap_status
        if bootstrap_status != 200 or not bootstrap_payload.get("token"):
            failures.append("Account bootstrap did not return a usable Terigo session.")
        else:
            session_token = bootstrap_payload["token"]
            results["account_session_expires_at"] = bootstrap_payload.get("expiresAt")

    if session_token:
        lists_status, lists_payload = request_json(
            f"{supabase_url}/functions/v1/account-lists",
            headers={
                "apikey": publishable_key,
                "Authorization": f"Bearer {publishable_key}",
                "X-RouteVault-Session": f"Bearer {session_token}",
            },
        )
        results["account_lists_status"] = lists_status
        if lists_status != 200:
            failures.append(f"Account lists returned HTTP {lists_status}.")
        else:
            lists = lists_payload.get("lists", [])
            results["account_list_count"] = len(lists)
            if lists:
                first_share_token = lists[0].get("shareToken")

    if session_token and first_share_token:
        shared_url = (
            f"{supabase_url}/functions/v1/shared-list?"
            f"{urllib.parse.urlencode({'token': first_share_token})}"
        )
        shared_status, shared_payload = request_json(
            shared_url,
            headers={
                "apikey": publishable_key,
                "Authorization": f"Bearer {publishable_key}",
                "X-RouteVault-Session": f"Bearer {session_token}",
            },
        )
        results["shared_list_status"] = shared_status
        if shared_status != 200:
            failures.append(f"Shared list fetch returned HTTP {shared_status}.")
        else:
            results["shared_list_route_count"] = len(shared_payload.get("routes", []))

    if share_link_host:
        aasa_status = request_status(f"https://{share_link_host}/.well-known/apple-app-site-association")
        results["aasa_status"] = aasa_status
        if aasa_status != 200:
            warnings.append(
                f"The configured share-link host {share_link_host} does not serve apple-app-site-association (HTTP {aasa_status})."
            )
    else:
        warnings.append("ROUTE_VAULT_SHARE_LINK_HOST is not configured.")

    if share_base_url:
        results["share_base_url"] = share_base_url
        share_page_status = request_status(f"{share_base_url.rstrip('/')}/lists/shared")
        results["share_page_status"] = share_page_status
        if share_page_status != 200:
            failures.append(f"Share page returned HTTP {share_page_status}.")
    else:
        warnings.append("ROUTE_VAULT_SHARE_BASE_URL is empty, so public share links fall back to the Supabase function URL.")

    print_results(results, failures, warnings)

    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print_results({}, [str(error)], [])
        raise SystemExit(1)
