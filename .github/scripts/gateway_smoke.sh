#!/usr/bin/env bash
# Run each service's real "Connectivity test" document against a deployed
# gateway, and decide whether the GATEWAY is at fault.
#
# Why this exists
# ----------------
# The Lua/unit suites prove a stage does what it says in isolation. They
# cannot catch "this stage is inactive on the route that needed it"
# (apisix-gateways#22) or "the deploy silently broke a whole subsystem" (the
# msg-to-mailbox incident that motivated this script: a production redeploy
# left the gateway unroutable and nothing caught it until a human happened to
# test the one broken service by hand). `usvc seller services run-tests`
# executes a service's real published connectivity test from inside the
# cluster, over the same network path customers use — the only check that
# would have caught either.
#
# Scope: connectivity test only, via --category (unitysvc-sellers>=0.3.6,
# unitysvc/unitysvc#2061). Each service here carries exactly one document
# worth running on every deploy — its "Connectivity test". Code examples,
# pricing, and everything else are exercised once by the activation
# pipeline, not needed on every deploy; --category is a pure server-side
# filter, no document-id lookup required.
#
# --include-active is required: by default `run-tests` skips services
# already `active` (frozen content, covered by the daily health sweep) —
# but every service this job exercises is normally active, so without this
# flag the job would silently test nothing.
#
# Gateway fault vs upstream fault
# --------------------------------
# The backend probes the upstream directly whenever an interface-level run
# fails, and labels the result platform_fault (the gateway is broken) or
# upstream_fault (the provider/receiver is down, rate-limiting, or flaking).
# Only the first is this job's business. Everything is retried once first,
# because a single run genuinely does flake.
set -uo pipefail

SERVICES_FILE="${SERVICES_FILE:-.github/gateway-smoke-services.txt}"
SMOKE_SERVICES="${SMOKE_SERVICES:-}"
RETRIES="${RETRIES:-1}"
FAIL_ON_UPSTREAM_FAULT="${FAIL_ON_UPSTREAM_FAULT:-false}"

# ---------------------------------------------------------------------------
# Resolve the service list.
# ---------------------------------------------------------------------------
NAMES=()
if [ -n "$SMOKE_SERVICES" ]; then
    IFS=',' read -ra NAMES <<<"$SMOKE_SERVICES"
else
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
        [ -z "$line" ] && continue
        [ "${line:0:1}" = "#" ] && continue
        NAMES+=("$line")
    done <"$SERVICES_FILE"
fi
if [ ${#NAMES[@]} -eq 0 ]; then
    echo "::error::no services to test"
    exit 1
fi

# ---------------------------------------------------------------------------
# Load the full catalog once, so names resolve to ids locally. The CLI's
# JSON output has two quirks jq won't tolerate: (1) a human summary line
# ("N services displayed — no more items.") after the JSON array, and (2)
# literal, unescaped control characters (raw newlines) inside string field
# values. `python3 -c` here isn't orchestration logic — it's a one-line
# `json.loads(..., strict=False)` + re-dump to hand jq something it can
# actually parse; every subsequent step is plain bash + jq.
# ---------------------------------------------------------------------------
CATALOG_RAW="$(usvc seller services list --all -f json)" || {
    echo "::error::could not list services"
    exit 1
}
CATALOG="$(python3 -c '
import json, sys
raw = sys.stdin.read()
end = raw.rfind("]")
if end == -1:
    sys.exit("::error::unexpected list output: " + raw[:400])
json.dump(json.loads(raw[: end + 1], strict=False), sys.stdout)
' <<<"$CATALOG_RAW")" || {
    echo "::error::could not parse service catalog JSON"
    exit 1
}

# Resolve a service_name to ONE service id. Names are not unique: a service
# and its pending/rejected revision share one, and which rows exist differs
# per environment. Prefer the live row (active, then approved) — the point
# is to test what customers actually hit; otherwise the most recently
# updated row.
resolve_id() {
    jq -r --arg name "$1" '
        [.[] | select(.name == $name)] as $rows
        | if ($rows | length) == 0 then "NOTFOUND"
          else (
            ([$rows[] | select(.status == "active" or .status == "approved")]) as $live
            | if ($live | length) > 0 then "\($live[0].id)\t\($live[0].status)"
              else (
                $rows | sort_by(.updated_at // "") | reverse | .[0]
                | "\(.id)\t\(.status // "unknown")"
              )
              end
          )
        end
    ' <<<"$CATALOG"
}

# ---------------------------------------------------------------------------
# Run one service's connectivity test, with a retry.
# ---------------------------------------------------------------------------
BROKEN_NAMES=()
DEGRADED_NAMES=()
PASSED_COUNT=0
SUMMARY_ROWS=()
DETAIL_SECTIONS=()

test_service() {
    local name="$1" sid="$2"
    local attempt out platform_lines upstream_lines other_lines rc detail

    for attempt in $(seq 1 $((RETRIES + 1))); do
        out="$(usvc seller services run-tests --id "$sid" --category connectivity_test --include-active --force 2>&1)"
        rc=$?
        # CLI failure lines are indented ("  ✗   ...") — match anywhere on
        # the line, not anchored, matching the CLI's own `.strip()` display.
        platform_lines="$(grep '✗' <<<"$out" | grep 'platform_fault' || true)"
        upstream_lines="$(grep '✗' <<<"$out" | grep 'upstream_fault' || true)"
        # Neither label: the CLI itself failed (auth, timeout, bad id) — not
        # an upstream problem, so treat it as ours to look at.
        other_lines="$(grep '✗' <<<"$out" | grep -v 'platform_fault' | grep -v 'upstream_fault' || true)"
        [ -n "$other_lines" ] && platform_lines="$(printf '%s\n%s' "$platform_lines" "$other_lines" | sed '/^$/d')"
        detail="$(grep 'Success:' <<<"$out" | head -1)"
        [ -z "$detail" ] && detail="$(tail -c 300 <<<"$out")"

        if [ "$rc" -eq 0 ]; then
            echo "$detail"
            PASSED_COUNT=$((PASSED_COUNT + 1))
            SUMMARY_ROWS+=("| \`$name\` | pass | $attempt |")
            return 0
        fi
        if [ -z "$platform_lines" ] && [ -z "$upstream_lines" ]; then
            platform_lines="run-tests exited $rc: $(tail -c 300 <<<"$out")"
        fi
    done

    echo "$detail"
    if [ -n "$platform_lines" ]; then
        BROKEN_NAMES+=("$name")
        SUMMARY_ROWS+=("| \`$name\` | GATEWAY FAULT | $attempt |")
        DETAIL_SECTIONS+=("### \`$name\` — gateway fault"$'\n'$'\n'"\`\`\`"$'\n'"$platform_lines"$'\n'"\`\`\`")
        echo "::error title=Gateway fault::${name}: $(head -c 400 <<<"$platform_lines")"
    else
        DEGRADED_NAMES+=("$name")
        SUMMARY_ROWS+=("| \`$name\` | upstream flaked (tolerated) | $attempt |")
        DETAIL_SECTIONS+=("### \`$name\` — upstream fault (not failing the build)"$'\n'$'\n'"\`\`\`"$'\n'"$upstream_lines"$'\n'"\`\`\`")
        echo "::warning title=Upstream fault::${name}: $(head -c 400 <<<"$upstream_lines")"
    fi
}

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
for name in "${NAMES[@]}"; do
    resolved="$(resolve_id "$name")"
    sid="${resolved%%$'\t'*}"
    status="${resolved#*$'\t'}"
    if [ "$sid" = "NOTFOUND" ]; then
        echo "::error::${name}: no service named '${name}' (renamed, or not uploaded here)"
        BROKEN_NAMES+=("$name")
        SUMMARY_ROWS+=("| \`$name\` | GATEWAY FAULT | 0 |")
        DETAIL_SECTIONS+=("### \`$name\` — gateway fault"$'\n'$'\n'"\`\`\`"$'\n'"no service named '$name' (renamed, or not uploaded here)"$'\n'"\`\`\`")
        continue
    fi
    echo "::group::${name} (${status}, ${sid:0:8})"
    test_service "$name" "$sid"
    echo "::endgroup::"
done

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
TOTAL=${#NAMES[@]}
{
    echo "# Gateway smoke test"
    echo
    echo "**${PASSED_COUNT}/${TOTAL} services fully green.**"
    echo
    echo "| service | result | attempts |"
    echo "| --- | --- | --- |"
    printf '%s\n' "${SUMMARY_ROWS[@]}"
    for section in "${DETAIL_SECTIONS[@]+"${DETAIL_SECTIONS[@]}"}"; do
        echo
        echo "$section"
    done
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "passed=${PASSED_COUNT}"
        echo "total=${TOTAL}"
        echo "broken=$(IFS=,; echo "${BROKEN_NAMES[*]+"${BROKEN_NAMES[*]}"}")"
    } >>"$GITHUB_OUTPUT"
fi

if [ ${#BROKEN_NAMES[@]} -gt 0 ]; then
    exit 1
fi
if [ ${#DEGRADED_NAMES[@]} -gt 0 ] && [ "$FAIL_ON_UPSTREAM_FAULT" = "true" ]; then
    exit 1
fi
exit 0
