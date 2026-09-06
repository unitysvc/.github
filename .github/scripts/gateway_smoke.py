#!/usr/bin/env python3
"""Run each service's real "Connectivity test" document against a deployed
gateway, and decide whether the GATEWAY is at fault.

Why this exists
----------------
The Lua/unit suites prove a stage does what it says in isolation. They cannot
catch "this stage is inactive on the route that needed it" (apisix-gateways#22)
or "the deploy silently broke a whole subsystem" (the msg-to-mailbox incident
that motivated this script: a production redeploy left the gateway unroutable
and nothing caught it until a human happened to test the one broken service by
hand). `usvc seller services run-tests` executes a service's real published
connectivity test from inside the cluster, over the same network path
customers use — the only check that would have caught either.

Scope: connectivity test only
------------------------------
Each service here carries exactly one document worth running on every deploy:
its "Connectivity test" (category `connectivity_test`). Code examples,
pricing, and everything else are exercised by the activation pipeline once,
not on every deploy — running them here would triple the cost of this job for
no coverage this job is meant to provide. The connectivity doc's id is
resolved dynamically per run (`services show --format json`) rather than
hardcoded, so a service can regenerate its documents without silently going
stale here.

--include-active is required: by default `run-tests` skips services already
in `active` status (its content is "frozen" and covered by the daily health
sweep) — but every service this job exercises is normally active, so without
this flag the job would silently test nothing.

Gateway fault vs upstream fault
--------------------------------
The backend probes the upstream directly whenever an interface-level run
fails, and labels the result `platform_fault` (the gateway is broken) or
`upstream_fault` (the provider/receiver is down, rate-limiting, or flaking).
Only the first is this job's business. Everything is retried once first,
because a single run genuinely does flake.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass, field

PLATFORM_FAULT = "platform_fault"
UPSTREAM_FAULT = "upstream_fault"


def run_cli(args: list[str], timeout: int = 1200) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["usvc", "seller", "services", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def load_services() -> list[dict]:
    """Every service the key can see, so names resolve to ids locally."""
    proc = run_cli(["list", "--all", "-f", "json"], timeout=300)
    if proc.returncode != 0:
        sys.exit(f"::error::could not list services: {proc.stdout}{proc.stderr}")
    raw = proc.stdout
    end = raw.rfind("]")
    if end == -1:
        sys.exit(f"::error::unexpected list output: {raw[:400]}")
    return json.loads(raw[: end + 1], strict=False)


def resolve(name: str, catalog: list[dict]) -> tuple[str | None, str]:
    """Resolve a service_name to ONE service id.

    Names are not unique: a service and its pending/rejected revision share
    one, and which rows exist differs per environment. Prefer the live row —
    the point is to test what customers actually hit.
    """
    rows = [s for s in catalog if s.get("name") == name]
    if not rows:
        return None, f"no service named {name!r} (renamed, or not uploaded here)"
    for status in ("active", "approved"):
        live = [s for s in rows if s.get("status") == status]
        if live:
            return live[0]["id"], status
    rows.sort(key=lambda s: s.get("updated_at") or "", reverse=True)
    return rows[0]["id"], rows[0].get("status", "unknown")


def connectivity_doc_id(service_id: str) -> str | None:
    """Find the id of the service's "Connectivity test" document.

    Resolved fresh per run rather than hardcoded: a service can regenerate
    its documents (new doc id) without this job silently going stale.
    """
    proc = run_cli(["show", "--id", service_id, "--format", "json"], timeout=120)
    if proc.returncode != 0:
        return None
    raw = proc.stdout
    end = raw.rfind("}")
    if end == -1:
        return None
    try:
        data = json.loads(raw[: end + 1], strict=False)
    except json.JSONDecodeError:
        return None
    for doc in data.get("documents", []):
        if doc.get("category") == "connectivity_test":
            return doc.get("id")
    return None


@dataclass
class Result:
    name: str
    service_id: str | None = None
    status: str = ""
    ok: bool = False
    platform_faults: list[str] = field(default_factory=list)
    upstream_faults: list[str] = field(default_factory=list)
    detail: str = ""
    attempts: int = 0


def failed_lines(stdout: str) -> list[str]:
    return [ln.strip() for ln in stdout.splitlines() if ln.strip().startswith("✗")]


def test_service(name: str, service_id: str, doc_id: str, retries: int) -> Result:
    res = Result(name=name, service_id=service_id)
    for attempt in range(1, retries + 2):
        res.attempts = attempt
        proc = run_cli(
            [
                "run-tests",
                "--id",
                service_id,
                "--document-id",
                doc_id,
                "--include-active",
                "--force",
            ]
        )
        out = proc.stdout + proc.stderr
        bad = failed_lines(out)
        res.platform_faults = [ln for ln in bad if PLATFORM_FAULT in ln]
        res.upstream_faults = [ln for ln in bad if UPSTREAM_FAULT in ln]
        # Neither label: the CLI itself failed (auth, timeout, bad id) — that is
        # not an upstream problem, so treat it as ours to look at.
        other = [ln for ln in bad if ln not in res.platform_faults and ln not in res.upstream_faults]
        res.platform_faults += other
        res.ok = proc.returncode == 0
        summary = next((ln for ln in out.splitlines() if "Success:" in ln), "")
        res.detail = summary.strip() or out.strip()[-300:]
        if res.ok:
            return res
        if not bad and proc.returncode != 0:
            res.platform_faults = [f"run-tests exited {proc.returncode}: {out.strip()[-300:]}"]
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--services-file", default=".github/gateway-smoke-services.txt")
    ap.add_argument("--services", default="", help="comma-separated override")
    ap.add_argument("--retries", type=int, default=1)
    ap.add_argument(
        "--fail-on-upstream-fault",
        action="store_true",
        help="also fail when only the provider/receiver misbehaved (default: report only)",
    )
    args = ap.parse_args()

    if args.services.strip():
        names = [n.strip() for n in args.services.split(",") if n.strip()]
    else:
        with open(args.services_file) as fh:
            names = [ln.strip() for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
    if not names:
        sys.exit("::error::no services to test")

    catalog = load_services()
    results: list[Result] = []
    for name in names:
        service_id, status = resolve(name, catalog)
        if not service_id:
            r = Result(name=name, status=status)
            r.platform_faults = [status]
            results.append(r)
            print(f"::error::{name}: {status}")
            continue
        print(f"::group::{name} ({status}, {service_id[:8]})")
        doc_id = connectivity_doc_id(service_id)
        if not doc_id:
            r = Result(name=name, service_id=service_id, status=status)
            r.platform_faults = ["no 'Connectivity test' document found on this service"]
            results.append(r)
            print(r.platform_faults[0])
            print("::endgroup::")
            continue
        r = test_service(name, service_id, doc_id, args.retries)
        r.status = status
        results.append(r)
        print(r.detail)
        print("::endgroup::")

    broken = [r for r in results if r.platform_faults]
    degraded = [r for r in results if not r.platform_faults and r.upstream_faults]
    passed = [r for r in results if r.ok]

    lines = [
        "# Gateway smoke test",
        "",
        f"**{len(passed)}/{len(results)} services fully green.**",
        "",
        "| service | result | attempts |",
        "| --- | --- | --- |",
    ]
    for r in results:
        if r.platform_faults:
            verdict = "GATEWAY FAULT"
        elif r.upstream_faults:
            verdict = "upstream flaked (tolerated)"
        else:
            verdict = "pass"
        lines.append(f"| `{r.name}` | {verdict} | {r.attempts} |")
    for r in broken:
        lines += ["", f"### `{r.name}` — gateway fault", "", "```"]
        lines += r.platform_faults[:20]
        lines.append("```")
    for r in degraded:
        lines += ["", f"### `{r.name}` — upstream fault (not failing the build)", "", "```"]
        lines += r.upstream_faults[:20]
        lines.append("```")
    report = "\n".join(lines)
    print(report)
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a") as fh:
            fh.write(report + "\n")
    if path := os.environ.get("GITHUB_OUTPUT"):
        with open(path, "a") as fh:
            fh.write(f"passed={len(passed)}\n")
            fh.write(f"total={len(results)}\n")
            fh.write(f"broken={','.join(r.name for r in broken)}\n")

    if broken:
        for r in broken:
            print(f"::error title=Gateway fault::{r.name}: {r.platform_faults[0][:400]}")
        return 1
    if degraded:
        for r in degraded:
            print(f"::warning title=Upstream fault::{r.name}: {r.upstream_faults[0][:400]}")
        if args.fail_on_upstream_fault:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
