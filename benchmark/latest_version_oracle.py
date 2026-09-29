#!/usr/bin/env python3
"""Independent ground-truth "latest version" oracle for the packages in
benchmark/top-packages.json - queries ecosyste.ms's package registry API
directly, not yul's own resolver.

Why this exists: analyze_top.py (and analyze_top_opencode.py) determine
whether a rep's final manifest is "already latest" by running `yul scan`
on it - that's yul checking its own opinion of what's outdated, not an
independent source. This script hits packages.ecosyste.ms directly instead,
so the two can be cross-checked against each other rather than one
validating itself.

Note this isn't a *fully* independent data source, just an independent code
path: yul's own resolvers (pkg/*/*.go) go through the git-pkgs/manifests and
git-pkgs/enrichment libraries, which for at least some ecosystems also read
from ecosyste.ms under the hood. A mismatch between this script and `yul
scan` still means something (a resolver bug, a stale git-pkgs mirror, or a
version published between the two queries), just not "yul is simply wrong
about reality."

Usage:
    python3 benchmark/latest_version_oracle.py [--top-packages PATH] [--json-out PATH]

Requires network access (one GET per package against packages.ecosyste.ms).
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
API_BASE = "https://packages.ecosyste.ms/api/v1/registries"


def fetch_latest(registry, package, retries=6):
    url = f"{API_BASE}/{urllib.parse.quote(registry, safe='')}/packages/{urllib.parse.quote(package, safe='')}"
    # ecosyste.ms 403s urllib's default "Python-urllib/x.y" User-Agent
    # (bot-blocking, presumably) - curl's default UA sails through fine, so
    # just borrow a generic browser-like one instead of chasing their exact
    # allowlist.
    req_headers = {"User-Agent": "Mozilla/5.0 (compatible; yul-benchmark-oracle/1.0)"}
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=req_headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.load(resp)
            return {
                "latest_version": data.get("latest_release_number"),
                "published_at": data.get("latest_release_published_at"),
                "url": url,
                "error": None,
            }
        except urllib.error.HTTPError as e:
            last_err = f"HTTP {e.code}"
            if e.code == 404:
                break  # package genuinely not found under this registry name - no point retrying
        except Exception as e:
            last_err = str(e)
        time.sleep(1 + attempt)
    return {"latest_version": None, "published_at": None, "url": url, "error": last_err}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top-packages", default=str(HERE / "top-packages.json"))
    ap.add_argument("--json-out", default=None)
    ap.add_argument("--delay", type=float, default=2.0,
                     help="seconds between requests. ecosyste.ms intermittently "
                          "returns HTTP 402 for a request that succeeds moments "
                          "later on retry, for endpoints nowhere near the real "
                          "quota (X-RateLimit-Remaining stays in the thousands) - "
                          "looks like backend flakiness on their end, not a real "
                          "payment wall or a pacing issue this delay can fully fix "
                          "(default: 2.0)")
    args = ap.parse_args()

    top_packages = json.loads(Path(args.top_packages).read_text())["ecosystems"]

    rows = []
    first = True
    for eco, data in top_packages.items():
        registry = data["registry"]
        for pkg in data["packages"]:
            if not first:
                time.sleep(args.delay)
            first = False
            result = fetch_latest(registry, pkg)
            rows.append({"ecosystem": eco, "package": pkg, "registry": registry, **result})
            status = result["latest_version"] or f"ERROR: {result['error']}"
            print(f"{eco:15s} {pkg:45s} -> {status}", file=sys.stderr)

    ok = [r for r in rows if r["latest_version"]]
    failed = [r for r in rows if not r["latest_version"]]

    print(f"\n{len(ok)}/{len(rows)} resolved, {len(failed)} failed", file=sys.stderr)
    if failed:
        print("Failed lookups:", file=sys.stderr)
        for r in failed:
            print(f"  {r['ecosystem']}/{r['package']}: {r['error']}", file=sys.stderr)

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(rows, indent=2))
        print(f"\nWrote {len(rows)} rows to {args.json_out}", file=sys.stderr)
    else:
        json.dump(rows, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
