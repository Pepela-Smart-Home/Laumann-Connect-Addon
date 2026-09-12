#!/usr/bin/env bash
# shellcheck shell=bash
#
# Dependency-free test runner for Laumann Connect's pairing.sh. Only needs
# bash, jq and curl (curl itself is stubbed out below) — the same trio the
# add-on ships with. No bats, no npm, no container.
#
# Exit code is non-zero if any test failed. Run it as:
#   ./tests/run.sh

set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PAIRING_SH="$REPO_ROOT/laumann_connect/rootfs/usr/lib/laumann-connect/pairing.sh"
CONFIG_YAML="$REPO_ROOT/laumann_connect/config.yaml"
FIXTURES="$HERE/fixtures"
STUBS="$HERE/stubs"

# shellcheck source=./lib.sh
source "$HERE/lib.sh"
# shellcheck source=../laumann_connect/rootfs/usr/lib/laumann-connect/pairing.sh
source "$PAIRING_SH"

# Resolved BEFORE prepending tests/stubs to PATH, so tests/stubs/jq (a
# selective passthrough used to simulate a single jq call failing without
# touching any other jq call in the flow) can `exec` the real binary by
# absolute path instead of re-discovering itself via PATH.
export LC_REAL_JQ
LC_REAL_JQ="$(command -v jq)"

export PATH="$STUBS:$PATH"
export LC_PAIRING_SH="$PAIRING_SH"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# run_flow <VAR=val>... — runs lc::main in a fresh bash subprocess (so its
# `set -o errexit/nounset/pipefail` and any trap never leak back into this
# runner), with the given extra/overridden environment variables. Sets
# FLOW_OUT (stdout+stderr combined) and FLOW_RC.
run_flow() {
    set +e
    FLOW_OUT="$(env "$@" bash -c 'source "$LC_PAIRING_SH" && lc::main' 2>&1)"
    FLOW_RC=$?
    set -e
}

# run_flow_traced — like run_flow, but the subprocess enables `set -x` before
# even sourcing pairing.sh, to prove lc::main's own `set +x` (its very first
# statement) wins over an already-tracing caller.
run_flow_traced() {
    set +e
    FLOW_OUT="$(env "$@" bash -c 'set -x; source "$LC_PAIRING_SH" && lc::main' 2>&1)"
    FLOW_RC=$?
    set -e
}

echo "== Pure function tests =="

# --- lc::normalize_code : valid inputs --------------------------------------

declare -A NORMALIZE_VALID=(
    ["K7QM-3XRA"]="K7QM3XRA"
    ["k7qm3xra"]="K7QM3XRA"
    ["K7QM3XRA"]="K7QM3XRA"
    ["K7QM 3XRA"]="K7QM3XRA"
    [" K7QM3XRA "]="K7QM3XRA"
    ["XX-XX-XX-XX"]="XXXXXXXX"
)
for input in "K7QM-3XRA" "k7qm3xra" "K7QM3XRA" "K7QM 3XRA" " K7QM3XRA " "XX-XX-XX-XX"; do
    set +e
    out="$(lc::normalize_code "$input")"
    rc=$?
    set -e
    expected="${NORMALIZE_VALID[$input]}"
    t::eq "normalize_code('${input}') == ${expected}" "$expected" "$out"
    t::rc "normalize_code('${input}') rc == 0" "0" "$rc"
done

# --- lc::normalize_code : invalid inputs ------------------------------------
# (parallel indexed arrays, not associative — bash associative arrays cannot
# hold an empty-string key, and "" is one of the invalid inputs under test)

NORMALIZE_INVALID_INPUTS=(""          "null" "K7QM3XR" "K7QM3XRAA" "K7QM3XR0" "K7QM3XRI" "K7QM3XRO" "K7QM3XR1")
NORMALIZE_INVALID_RCS=(   "1"         "1"    "2"       "2"         "3"        "3"        "3"        "3")
for idx in "${!NORMALIZE_INVALID_INPUTS[@]}"; do
    input="${NORMALIZE_INVALID_INPUTS[$idx]}"
    expected_rc="${NORMALIZE_INVALID_RCS[$idx]}"
    set +e
    out="$(lc::normalize_code "$input")"
    rc=$?
    set -e
    t::rc "normalize_code('${input}') rc == ${expected_rc}" "$expected_rc" "$rc"
    t::eq "normalize_code('${input}') stdout empty" "" "$out"
done

# --- lc::validate_portal_url : valid -----------------------------------------

set +e
out="$(lc::validate_portal_url "https://a.tld")"; rc=$?
set -e
t::eq "validate_portal_url('https://a.tld')" "https://a.tld" "$out"
t::rc "validate_portal_url('https://a.tld') rc" "0" "$rc"

set +e
out="$(lc::validate_portal_url "https://a.tld/")"; rc=$?
set -e
t::eq "validate_portal_url('https://a.tld/') strips trailing slash" "https://a.tld" "$out"
t::rc "validate_portal_url('https://a.tld/') rc" "0" "$rc"

# --- lc::validate_portal_url : invalid ---------------------------------------
# (parallel indexed arrays — see note above about empty-string keys)

URL_INVALID_INPUTS=("http://a.tld" "HTTP://a.tld" "ftp://a" "https://u:p@a.tld" ""    "https://")
URL_INVALID_RCS=(   "2"            "2"            "2"       "3"                 "1"   "4")
for idx in "${!URL_INVALID_INPUTS[@]}"; do
    input="${URL_INVALID_INPUTS[$idx]}"
    expected_rc="${URL_INVALID_RCS[$idx]}"
    set +e
    out="$(lc::validate_portal_url "$input")"
    rc=$?
    set -e
    t::rc "validate_portal_url('${input}') rc == ${expected_rc}" "$expected_rc" "$rc"
done

# --- lc::count_local_ip_literal ----------------------------------------------

t::eq "count_local_ip_literal(valid) == 1" "1" "$(lc::count_local_ip_literal "$FIXTURES/frpc_toml_valid.txt")"
t::eq "count_local_ip_literal(no_localip) == 0" "0" "$(lc::count_local_ip_literal "$FIXTURES/frpc_toml_no_localip.txt")"
t::eq "count_local_ip_literal(double_localip) == 2" "2" "$(lc::count_local_ip_literal "$FIXTURES/frpc_toml_double_localip.txt")"

# --- lc::adapt_frpc_toml : success -------------------------------------------

adapt_out="$WORKDIR/adapt_valid_out.toml"
set +e
lc::adapt_frpc_toml "$FIXTURES/frpc_toml_valid.txt" "$adapt_out"
rc=$?
set -e
t::rc "adapt_frpc_toml(valid) rc == 0" "0" "$rc"
if [ -f "$adapt_out" ]; then
    t::eq "adapt_frpc_toml(valid) old 127.0.0.1 literal gone" "0" "$(lc::count_local_ip_literal "$adapt_out")"
    t::not_contains "adapt_frpc_toml(valid) output has no 127.0.0.1 left" "$(cat "$adapt_out")" "127.0.0.1"
    t::contains "adapt_frpc_toml(valid) output has homeassistant" "$(cat "$adapt_out")" 'localIP = "homeassistant"'
    # loginFailExit = false must be present exactly once and BEFORE the first
    # `[[proxies]]` table header — otherwise it silently becomes a field of
    # the last proxy instead of a top-level key (see pairing.sh's comment on
    # lc::adapt_frpc_toml).
    login_fail_exit_count="$(grep -c '^loginFailExit = false$' "$adapt_out" || true)"
    t::eq "adapt_frpc_toml(valid) has exactly one loginFailExit = false line" "1" "$login_fail_exit_count"
    login_fail_exit_line="$(grep -n '^loginFailExit = false$' "$adapt_out" | cut -d: -f1 || true)"
    proxies_line="$(grep -n '^\[\[proxies\]\]$' "$adapt_out" | cut -d: -f1 || true)"
    if [ "${login_fail_exit_line:-999}" -lt "${proxies_line:-0}" ]; then
        t::pass "adapt_frpc_toml(valid) loginFailExit line precedes [[proxies]]"
    else
        t::fail "adapt_frpc_toml(valid) loginFailExit line precedes [[proxies]]" \
            "loginFailExit at line ${login_fail_exit_line:-<missing>}, [[proxies]] at line ${proxies_line:-<missing>}"
    fi
    # Every OTHER line must be byte-identical to the source.
    diff_others="$(diff <(grep -v 'localIP' "$FIXTURES/frpc_toml_valid.txt") <(grep -v -e 'localIP' -e '^loginFailExit = false$' "$adapt_out") || true)"
    t::eq "adapt_frpc_toml(valid) leaves all other lines byte-identical" "" "$diff_others"
else
    t::fail "adapt_frpc_toml(valid) produced an output file"
fi

# --- lc::adapt_frpc_toml : failure --------------------------------------------

for fixture_name in frpc_toml_no_localip frpc_toml_double_localip; do
    adapt_fail_out="$WORKDIR/${fixture_name}_out.toml"
    rm -f "$adapt_fail_out"
    set +e
    lc::adapt_frpc_toml "$FIXTURES/${fixture_name}.txt" "$adapt_fail_out"
    rc=$?
    set -e
    t::rc "adapt_frpc_toml(${fixture_name}) rc == 5" "5" "$rc"
    if [ -f "$adapt_fail_out" ]; then
        t::fail "adapt_frpc_toml(${fixture_name}) must not create an output file"
    else
        t::pass "adapt_frpc_toml(${fixture_name}) created no output file"
    fi
done

# --- lc::adapt_frpc_toml : rc 6 (mktemp itself fails) ------------------------
# Guards the rc-6 path (mktemp/sed/mv failure) that had zero test coverage:
# a regression here (e.g. a dropped status check that lets a half-written
# temp file get mv'd into place anyway) would silently reintroduce the
# corrupt-frpc.toml bug that lc::already_paired's `[ -s ]` check would then
# accept as a valid pairing on the next start.
#
# The failure is forced via an ENOTDIR situation (a *file* sitting where a
# directory is expected), not via `chmod`ing the target directory read-only:
# a directory-permission trick does not stop mktemp when the suite itself
# runs as uid 0 (root ignores directory write-permission bits) — verified in
# `docker run --rm debian:stable-slim`: with the old chmod-500 approach
# `lc::adapt_frpc_toml` returns rc 0 there and this would falsely fail two
# assertions on a container/CI run with a completely intact code path. The
# ENOTDIR approach is rc-6 for every uid, root included.
adapt_notadir="$WORKDIR/adapt_notadir"
: > "$adapt_notadir"
adapt_ro_out="$adapt_notadir/frpc.toml"
set +e
lc::adapt_frpc_toml "$FIXTURES/frpc_toml_valid.txt" "$adapt_ro_out" 2>/dev/null
rc=$?
set -e
t::rc "adapt_frpc_toml(target dir is not a directory, mktemp fails) rc == 6" "6" "$rc"
t::eq "adapt_frpc_toml(target dir is not a directory) leaves the placeholder untouched" "0" "$(t::stat_size "$adapt_notadir")"

# --- lc::adapt_frpc_toml : rc 6 (sed itself fails) ---------------------------
# mktemp succeeds here (a real, writable target dir), so this exercises the
# `! sed ... > "$tmp"` branch specifically. Verified this branch is actually
# reached (not short-circuited by mktemp) via instrumentation. Mutation-tested
# against the current code: replacing the sed status check with
# `sed ... > "$tmp" || true` leaves the suite green (168/168) without this
# test — i.e. without it, a swallowed sed failure goes undetected.
adapt_sed_out="$WORKDIR/adapt_sed_fail_out.toml"
rm -f "$adapt_sed_out"
(
    sed() { return 1; }
    export -f sed
    set +e
    lc::adapt_frpc_toml "$FIXTURES/frpc_toml_valid.txt" "$adapt_sed_out"
    echo "$?" > "$WORKDIR/adapt_sed_fail.rc"
    set -e
)
t::rc "adapt_frpc_toml(sed fails) rc == 6" "6" "$(cat "$WORKDIR/adapt_sed_fail.rc")"
if [ -f "$adapt_sed_out" ]; then
    t::fail "adapt_frpc_toml(sed fails) must not create an output file"
else
    t::pass "adapt_frpc_toml(sed fails) created no output file"
fi
leftover_sed_tmp="$(find "$WORKDIR" -maxdepth 1 -name 'adapt_sed_fail_out.toml.*' | wc -l | tr -d '[:space:]')"
t::eq "adapt_frpc_toml(sed fails) leaves no temp file" "0" "$leftover_sed_tmp"

# --- lc::adapt_frpc_toml : rc 6 (mv itself fails) ----------------------------
# mktemp and sed both succeed here; only mv is made to fail, exercising the
# final `! mv "$tmp" "$out"` branch. Mutation-tested the same way as the sed
# case above: replacing the mv status check with `mv "$tmp" "$out" || true`
# leaves the suite green (168/168) without this test.
adapt_mv_out="$WORKDIR/adapt_mv_fail_out.toml"
rm -f "$adapt_mv_out"
(
    mv() { return 1; }
    export -f mv
    set +e
    lc::adapt_frpc_toml "$FIXTURES/frpc_toml_valid.txt" "$adapt_mv_out"
    echo "$?" > "$WORKDIR/adapt_mv_fail.rc"
    set -e
)
t::rc "adapt_frpc_toml(mv fails) rc == 6" "6" "$(cat "$WORKDIR/adapt_mv_fail.rc")"
if [ -f "$adapt_mv_out" ]; then
    t::fail "adapt_frpc_toml(mv fails) must not create an output file"
else
    t::pass "adapt_frpc_toml(mv fails) created no output file"
fi
leftover_mv_tmp="$(find "$WORKDIR" -maxdepth 1 -name 'adapt_mv_fail_out.toml.*' | wc -l | tr -d '[:space:]')"
t::eq "adapt_frpc_toml(mv fails) leaves no temp file" "0" "$leftover_mv_tmp"

# --- lc::ca_pem_looks_valid ---------------------------------------------------

ca_valid_file="$WORKDIR/ca_valid.crt"
printf -- '-----BEGIN CERTIFICATE-----\nMIIBTEST==\n-----END CERTIFICATE-----\n' > "$ca_valid_file"
if lc::ca_pem_looks_valid "$ca_valid_file"; then t::pass "ca_pem_looks_valid(complete PEM) accepts it"; else t::fail "ca_pem_looks_valid(complete PEM) accepts it"; fi

ca_truncated_file="$WORKDIR/ca_truncated.crt"
printf -- '-----BEGIN CERTIF' > "$ca_truncated_file"
if lc::ca_pem_looks_valid "$ca_truncated_file"; then t::fail "ca_pem_looks_valid(truncated, non-empty) rejects it"; else t::pass "ca_pem_looks_valid(truncated, non-empty) rejects it"; fi

ca_empty_file="$WORKDIR/ca_empty.crt"
: > "$ca_empty_file"
if lc::ca_pem_looks_valid "$ca_empty_file"; then t::fail "ca_pem_looks_valid(empty) rejects it"; else t::pass "ca_pem_looks_valid(empty) rejects it"; fi

if lc::ca_pem_looks_valid "$WORKDIR/ca_does_not_exist.crt"; then t::fail "ca_pem_looks_valid(missing file) rejects it"; else t::pass "ca_pem_looks_valid(missing file) rejects it"; fi

# --- lc::write_ca_pem : success ------------------------------------------------

ca_body="$WORKDIR/ca_body.json"
printf '{"caCertificatePem":"-----BEGIN CERTIFICATE-----\\nMIIBTEST==\\n-----END CERTIFICATE-----\\n"}' > "$ca_body"
ca_write_out="$WORKDIR/ca_write_out.crt"
set +e
lc::write_ca_pem "$ca_body" "$ca_write_out"
rc=$?
set -e
t::rc "write_ca_pem(valid body) rc == 0" "0" "$rc"
if [ -f "$ca_write_out" ]; then
    t::contains "write_ca_pem(valid body) output has END CERTIFICATE" "$(cat "$ca_write_out")" "-----END CERTIFICATE-----"
    mode="$(t::stat_mode "$ca_write_out")"
    t::eq "write_ca_pem(valid body) mode 600" "600" "$mode"
else
    t::fail "write_ca_pem(valid body) produced an output file"
fi

# --- lc::write_ca_pem : rc 6 (mktemp itself fails) ---------------------------
# Same ENOTDIR trick as lc::adapt_frpc_toml's rc-6 test above — works for
# every uid, root included.
ca_notadir="$WORKDIR/ca_notadir"
: > "$ca_notadir"
ca_ro_out="$ca_notadir/pepela-cloud-ca.crt"
set +e
lc::write_ca_pem "$ca_body" "$ca_ro_out" 2>/dev/null
rc=$?
set -e
t::rc "write_ca_pem(target dir is not a directory, mktemp fails) rc == 6" "6" "$rc"
t::eq "write_ca_pem(target dir is not a directory) leaves the placeholder untouched" "0" "$(t::stat_size "$ca_notadir")"

# --- lc::write_ca_pem : rc 6 (jq itself fails) --------------------------------
# Mutation-style guard, analogous to the sed/mv coverage above: a swallowed jq
# failure would still `mv` an empty/partial temp file into place and return 0,
# which lc::ca_pem_looks_valid's caller in lc::main would then have to catch
# on the NEXT start instead of this one.
ca_write_jq_out="$WORKDIR/ca_write_jq_fail_out.crt"
rm -f "$ca_write_jq_out"
(
    jq() { return 1; }
    export -f jq
    set +e
    lc::write_ca_pem "$ca_body" "$ca_write_jq_out"
    echo "$?" > "$WORKDIR/ca_write_jq_fail.rc"
    set -e
)
t::rc "write_ca_pem(jq fails) rc == 6" "6" "$(cat "$WORKDIR/ca_write_jq_fail.rc")"
if [ -f "$ca_write_jq_out" ]; then
    t::fail "write_ca_pem(jq fails) must not create an output file"
else
    t::pass "write_ca_pem(jq fails) created no output file"
fi
leftover_ca_jq_tmp="$(find "$WORKDIR" -maxdepth 1 -name 'ca_write_jq_fail_out.crt.*' | wc -l | tr -d '[:space:]')"
t::eq "write_ca_pem(jq fails) leaves no temp file" "0" "$leftover_ca_jq_tmp"

# --- lc::write_ca_pem : rc 6 (mv itself fails) --------------------------------
ca_write_mv_out="$WORKDIR/ca_write_mv_fail_out.crt"
rm -f "$ca_write_mv_out"
(
    mv() { return 1; }
    export -f mv
    set +e
    lc::write_ca_pem "$ca_body" "$ca_write_mv_out"
    echo "$?" > "$WORKDIR/ca_write_mv_fail.rc"
    set -e
)
t::rc "write_ca_pem(mv fails) rc == 6" "6" "$(cat "$WORKDIR/ca_write_mv_fail.rc")"
if [ -f "$ca_write_mv_out" ]; then
    t::fail "write_ca_pem(mv fails) must not create an output file"
else
    t::pass "write_ca_pem(mv fails) created no output file"
fi
leftover_ca_mv_tmp="$(find "$WORKDIR" -maxdepth 1 -name 'ca_write_mv_fail_out.crt.*' | wc -l | tr -d '[:space:]')"
t::eq "write_ca_pem(mv fails) leaves no temp file" "0" "$leftover_ca_mv_tmp"

# --- lc::explain_status -------------------------------------------------------

set +e; lc::explain_status "200" "" "https://portal.example" >/dev/null; t::rc "explain_status(200) rc" "0" "$?"; set -e

set +e; msg="$(lc::explain_status "400" "" "https://portal.example")"; rc=$?; set -e
t::rc "explain_status(400) rc" "10" "$rc"
t::contains "explain_status(400) message" "$msg" "nicht akzeptiert"

set +e; msg="$(lc::explain_status "429" "42" "https://portal.example")"; rc=$?; set -e
t::rc "explain_status(429) rc" "11" "$rc"
# This branch is only reachable AFTER lc::main's own one automatic retry has
# already happened and failed again (see the comment at its call site in
# pairing.sh) — the message must describe an EXHAUSTED retry, never an
# upcoming one, and must not use "Fehlversuche" (that word belongs to the
# inline first-429 warning logged separately by lc::main itself).
t::contains "explain_status(429) message describes an already-exhausted retry" "$msg" "zweite Versuch"
t::contains "explain_status(429) message includes retry_after" "$msg" "42"
t::not_contains "explain_status(429) message does not promise a further retry" "$msg" "wird genau ein weiterer Versuch"

set +e; msg="$(lc::explain_status "413" "" "https://portal.example")"; rc=$?; set -e
t::rc "explain_status(413) rc" "12" "$rc"
t::contains "explain_status(413) message" "$msg" "zu groß"

set +e; msg="$(lc::explain_status "500" "" "https://portal.example")"; rc=$?; set -e
t::rc "explain_status(500) rc" "13" "$rc"
t::contains "explain_status(500) message" "$msg" "nicht erreichbar"

set +e; msg="$(lc::explain_status "000" "" "https://portal.example")"; rc=$?; set -e
t::rc "explain_status(000) rc" "13" "$rc"
t::contains "explain_status(000) message" "$msg" "nicht erreichbar"

# --- lc::retry_after_seconds ---------------------------------------------------

mk_header() {
    local file="$1" line="$2"
    {
        printf 'HTTP/1.1 429\r\n'
        [ -n "$line" ] && printf '%s\r\n' "$line"
        printf '\r\n'
    } > "$file"
}

h="$WORKDIR/hdr1"; mk_header "$h" "Retry-After: 42"
t::eq "retry_after_seconds(42)" "42" "$(lc::retry_after_seconds "$h")"

h="$WORKDIR/hdr2"; mk_header "$h" "Retry-After: 99999"
t::eq "retry_after_seconds(99999) capped at 600" "600" "$(lc::retry_after_seconds "$h")"

h="$WORKDIR/hdr3"; mk_header "$h" "Retry-After: abc"
t::eq "retry_after_seconds(abc) falls back to default 60" "60" "$(lc::retry_after_seconds "$h")"

h="$WORKDIR/hdr4"; mk_header "$h" ""
t::eq "retry_after_seconds(missing) falls back to default 60" "60" "$(lc::retry_after_seconds "$h")"

h="$WORKDIR/hdr5"; mk_header "$h" "retry-after: 42"
t::eq "retry_after_seconds(lowercase header) == 42" "42" "$(lc::retry_after_seconds "$h")"

# A value with more digits than bash's integer comparison can safely handle
# must fall back to the default, NOT pass the `-gt`/`-lt` checks through with
# a silent "integer expected" error and leak the raw value back to the
# caller (the bug this test guards against — see lc::retry_after_seconds).
h="$WORKDIR/hdr6"; mk_header "$h" "Retry-After: 99999999999999999999"
t::eq "retry_after_seconds(overflow, 20 digits) falls back to default 60" "60" "$(lc::retry_after_seconds "$h")"

h="$WORKDIR/hdr7"; mk_header "$h" "Retry-After: 9223372036854775808"
t::eq "retry_after_seconds(overflow, INT64_MAX+1) falls back to default 60" "60" "$(lc::retry_after_seconds "$h")"

h="$WORKDIR/hdr8"; mk_header "$h" "Retry-After: 604800"
t::eq "retry_after_seconds(within the 9-digit regex, 604800) still capped at 600" "600" "$(lc::retry_after_seconds "$h")"

# --- lc::strip_pairing_code -----------------------------------------------------

opts_file="$WORKDIR/options_for_strip.json"
printf '{"pairing_code":"K7QM3XRA","portal_base_url":"https://portal.example","log_level":"info"}' > "$opts_file"
stripped="$(lc::strip_pairing_code "$opts_file")"
t::not_contains "strip_pairing_code removes the key entirely" "$stripped" "pairing_code"
t::contains "strip_pairing_code keeps portal_base_url" "$stripped" "portal_base_url"
t::contains "strip_pairing_code keeps log_level" "$stripped" "log_level"
t::contains "strip_pairing_code wraps in {\"options\":...}" "$stripped" '"options"'

# --- lc::request_body_json -------------------------------------------------------

t::eq "request_body_json" '{"pairingCode":"K7QM3XRA"}' "$(lc::request_body_json "K7QM3XRA")"

echo
echo "== Flow tests (lc::main via curl stub) =="

# --- Test 12: fresh pairing succeeds -----------------------------------------

data12="$WORKDIR/t12/data"; ca12="$WORKDIR/t12/ca"
mkdir -p "$data12" "$ca12"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test","log_level":"info"}' > "$data12/options.json"
log12="$WORKDIR/t12/calls.log"; : > "$log12"

run_flow \
    LC_DATA_DIR="$data12" LC_CA_DIR="$ca12" LC_OPTIONS_FILE="$data12/options.json" \
    LC_HTTP_TIMEOUT_SECONDS=5 LC_RETRY_AFTER_DEFAULT_SECONDS=1 LC_RETRY_AFTER_MAX_SECONDS=2 \
    LC_TEST_CALL_LOG="$log12" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success.json" \
    LC_TEST_OPTIONS_STATUS=200 SUPERVISOR_TOKEN="test-token"

t::rc "T12 fresh pairing: rc == 0" "0" "$FLOW_RC"
if [ -f "$data12/frpc.toml" ]; then
    t::pass "T12 frpc.toml created"
    t::contains "T12 frpc.toml rewritten for homeassistant" "$(cat "$data12/frpc.toml")" 'localIP = "homeassistant"'
    t::contains "T12 frpc.toml carries loginFailExit = false" "$(cat "$data12/frpc.toml")" 'loginFailExit = false'
    mode="$(t::stat_mode "$data12/frpc.toml")"
    t::eq "T12 frpc.toml mode 600" "600" "$mode"
else
    t::fail "T12 frpc.toml created"
fi
if [ -f "$data12/pepela-cloud-ca.crt" ]; then
    t::pass "T12 CA written to /data"
    mode="$(t::stat_mode "$data12/pepela-cloud-ca.crt")"
    t::eq "T12 /data CA mode 600" "600" "$mode"
else
    t::fail "T12 CA written to /data"
fi
if [ -f "$ca12/pepela-cloud-ca.crt" ]; then
    t::pass "T12 CA copied to /etc/frp"
    t::eq "T12 CA copy matches /data original" "$(cat "$data12/pepela-cloud-ca.crt")" "$(cat "$ca12/pepela-cloud-ca.crt")"
else
    t::fail "T12 CA copied to /etc/frp"
fi
calls12="$(wc -l < "$log12" | tr -d '[:space:]')"
t::eq "T12 exactly 2 curl calls (pair + options)" "2" "$calls12"
t::contains "T12 confirms the pairing code was actually consumed" "$FLOW_OUT" "wurde verbraucht und aus der Konfiguration entfernt"
t::not_contains "T12 no false could-not-be-cleared warning on the happy path" "$FLOW_OUT" "konnte nicht automatisch entfernt werden"

# --- Test 13: restart idempotency (0 curl calls, CA re-provisioned) ---------

frpc_toml_snapshot="$(cat "$data12/frpc.toml")"
ca_snapshot="$(cat "$data12/pepela-cloud-ca.crt")"
ca13_fresh="$WORKDIR/t13/ca"   # simulates /etc/frp being wiped by a container restart
mkdir -p "$ca13_fresh"
log13="$WORKDIR/t13/calls.log"; mkdir -p "$(dirname "$log13")"; : > "$log13"

run_flow \
    LC_DATA_DIR="$data12" LC_CA_DIR="$ca13_fresh" LC_OPTIONS_FILE="$data12/options.json" \
    LC_TEST_CALL_LOG="$log13"

t::rc "T13 restart idempotency: rc == 0" "0" "$FLOW_RC"
calls13="$(wc -l < "$log13" | tr -d '[:space:]')"
t::eq "T13 zero curl calls on restart" "0" "$calls13"
t::eq "T13 frpc.toml unchanged" "$frpc_toml_snapshot" "$(cat "$data12/frpc.toml")"
if [ -f "$ca13_fresh/pepela-cloud-ca.crt" ]; then
    t::pass "T13 CA re-provisioned into fresh /etc/frp"
    t::eq "T13 re-provisioned CA matches stored CA" "$ca_snapshot" "$(cat "$ca13_fresh/pepela-cloud-ca.crt")"
else
    t::fail "T13 CA re-provisioned into fresh /etc/frp"
fi
# data12/options.json still has T12's original pairing_code — the curl stub
# never rewrites it (unlike the real Supervisor), so this restart genuinely
# exercises the already-paired-with-a-stray-code path.
t::contains "T13 warns that a stray pairing_code is ignored on the already-paired path" "$FLOW_OUT" "wird ignoriert"
# Regression guard: an earlier wording claimed the leftover code was "just
# entered" and pushed the customer toward a data reset (see pairing.sh:361's
# comment) — a mutation back to that wording must not slip past unnoticed
# just because "wird ignoriert" still happens to appear in both versions.
t::not_contains "T13 stray-code warning does not claim the code was newly entered" "$FLOW_OUT" "neu eingetragene"

# --- Test 13b: already-paired restart with NO pairing_code option at all ----
# (the common case — must stay silent, no false-positive warning)

data13b="$WORKDIR/t13b/data"; ca13b="$WORKDIR/t13b/ca"
mkdir -p "$data13b" "$ca13b"
cp "$data12/frpc.toml" "$data13b/frpc.toml"
cp "$data12/pepela-cloud-ca.crt" "$data13b/pepela-cloud-ca.crt"
printf '{"portal_base_url":"https://portal.example.test","log_level":"info"}' > "$data13b/options.json"
log13b="$WORKDIR/t13b/calls.log"; : > "$log13b"

run_flow LC_DATA_DIR="$data13b" LC_CA_DIR="$ca13b" LC_OPTIONS_FILE="$data13b/options.json" LC_TEST_CALL_LOG="$log13b"

t::rc "T13b already paired, no pairing_code option: rc == 0" "0" "$FLOW_RC"
t::not_contains "T13b no stray-code warning when pairing_code is absent" "$FLOW_OUT" "wird ignoriert"
t::eq "T13b zero curl calls" "0" "$(wc -l < "$log13b" | tr -d '[:space:]')"

# --- Test 14: paired but CA missing from /data --------------------------------

data14="$WORKDIR/t14/data"; ca14="$WORKDIR/t14/ca"
mkdir -p "$data14" "$ca14"
printf 'placeholder toml content\n' > "$data14/frpc.toml"
printf '{}' > "$data14/options.json"
log14="$WORKDIR/t14/calls.log"; : > "$log14"

run_flow LC_DATA_DIR="$data14" LC_CA_DIR="$ca14" LC_OPTIONS_FILE="$data14/options.json" LC_TEST_CALL_LOG="$log14"

t::rc "T14 paired but CA missing: rc == 1" "1" "$FLOW_RC"
t::contains "T14 message mentions incomplete pairing" "$FLOW_OUT" "unvollständig"
t::eq "T14 zero curl calls" "0" "$(wc -l < "$log14" | tr -d '[:space:]')"

# --- Test 14b: paired but the stored CA in /data is present-but-truncated ----
# Regression guard for the MINOR finding: `[ -s ]` alone would accept this
# file as a valid pairing (it's non-empty), install the broken CA into
# /etc/frp, and only fail later at frpc's TLS handshake — with "Bereits
# gekoppelt" as the last log line, actively misdirecting the customer away
# from the real cause. lc::ca_pem_looks_valid must catch it right here,
# before the CA is ever installed.
data14b="$WORKDIR/t14b/data"; ca14b="$WORKDIR/t14b/ca"
mkdir -p "$data14b" "$ca14b"
printf 'valid frpc toml content\n' > "$data14b/frpc.toml"
printf -- '-----BEGIN CERTIF' > "$data14b/pepela-cloud-ca.crt"
printf '{}' > "$data14b/options.json"
log14b="$WORKDIR/t14b/calls.log"; : > "$log14b"

run_flow LC_DATA_DIR="$data14b" LC_CA_DIR="$ca14b" LC_OPTIONS_FILE="$data14b/options.json" LC_TEST_CALL_LOG="$log14b"

t::rc "T14b paired but CA truncated: rc == 1" "1" "$FLOW_RC"
t::contains "T14b message mentions incomplete/invalid pairing" "$FLOW_OUT" "unvollständig"
t::contains "T14b message mentions the certificate specifically" "$FLOW_OUT" "Zertifikat"
t::eq "T14b zero curl calls" "0" "$(wc -l < "$log14b" | tr -d '[:space:]')"
if [ -f "$ca14b/pepela-cloud-ca.crt" ]; then
    t::fail "T14b truncated CA must not be installed into /etc/frp"
else
    t::pass "T14b truncated CA not installed into /etc/frp"
fi

# --- Test 14c: fresh pairing where the CA write itself fails (rc 6) ---------
# Regression guard for the write-side half of the MINOR finding: before the
# fix, the CA write was a bare `jq ... > "$ca_data"` with no status check, so
# a failure there either aborted lc::main with a raw, untranslated bash error
# (no German customer-facing message, unlike every other failure path) or —
# worse — left a half-written file behind for the NEXT start's
# lc::ca_pem_looks_valid to trip over instead. Forced here via
# tests/stubs/jq + LC_TEST_FAIL_CA_JQ, which fails only the one
# `jq -r '.caCertificatePem'` call lc::write_ca_pem makes — every other jq
# call in the flow (options.json, response-field validation, frpcToml/
# clientId/subdomain extraction, pairing-code stripping) still goes through
# untouched, so this exercises exactly the CA-write branch and nothing else.
data14c="$WORKDIR/t14c/data"; ca14c="$WORKDIR/t14c/ca"
mkdir -p "$data14c" "$ca14c"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data14c/options.json"
log14c="$WORKDIR/t14c/calls.log"; : > "$log14c"

run_flow LC_DATA_DIR="$data14c" LC_CA_DIR="$ca14c" LC_OPTIONS_FILE="$data14c/options.json" \
    LC_TEST_CALL_LOG="$log14c" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success.json" \
    LC_TEST_FAIL_CA_JQ=1

t::rc "T14c CA write failure: rc == 1" "1" "$FLOW_RC"
t::contains "T14c message mentions the certificate could not be saved" "$FLOW_OUT" "Zertifikat konnte nicht gespeichert werden"
t::not_contains "T14c message is not a raw bash/mktemp error" "$FLOW_OUT" "mktemp:"
t::not_contains "T14c message is not a raw bash error" "$FLOW_OUT" "Ist ein Verzeichnis"
if [ -f "$data14c/pepela-cloud-ca.crt" ]; then
    t::fail "T14c no half-written CA left behind under /data"
else
    t::pass "T14c no half-written CA left behind under /data"
fi
if [ -f "$data14c/frpc.toml" ]; then
    t::pass "T14c frpc.toml was written before the CA step (not the bug under test)"
else
    t::fail "T14c frpc.toml was written before the CA step (not the bug under test)"
fi

# --- Test 15: portal returns 400 ----------------------------------------------

data15="$WORKDIR/t15/data"; ca15="$WORKDIR/t15/ca"
mkdir -p "$data15" "$ca15"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data15/options.json"
log15="$WORKDIR/t15/calls.log"; : > "$log15"

run_flow LC_DATA_DIR="$data15" LC_CA_DIR="$ca15" LC_OPTIONS_FILE="$data15/options.json" \
    LC_TEST_CALL_LOG="$log15" LC_TEST_PAIR_STATUS=400

t::rc "T15 400 response: rc == 1" "1" "$FLOW_RC"
t::contains "T15 message mentions rejection" "$FLOW_OUT" "nicht akzeptiert"
t::eq "T15 exactly 1 curl call" "1" "$(wc -l < "$log15" | tr -d '[:space:]')"
only_options_file="$(t::basenames "$data15")"
t::eq "T15 /data contains only options.json" "options.json" "$only_options_file"

# --- Test 16: 429 then 200 (exactly one retry, succeeds) ----------------------

data16="$WORKDIR/t16/data"; ca16="$WORKDIR/t16/ca"
mkdir -p "$data16" "$ca16"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data16/options.json"
log16="$WORKDIR/t16/calls.log"; : > "$log16"

run_flow LC_DATA_DIR="$data16" LC_CA_DIR="$ca16" LC_OPTIONS_FILE="$data16/options.json" \
    LC_RETRY_AFTER_DEFAULT_SECONDS=1 LC_RETRY_AFTER_MAX_SECONDS=2 \
    LC_TEST_CALL_LOG="$log16" LC_TEST_PAIR_STATUS_SEQUENCE="429,200" LC_TEST_RETRY_AFTER=1 \
    LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success.json" LC_TEST_OPTIONS_STATUS=200 SUPERVISOR_TOKEN="test-token"

t::rc "T16 429 then 200: rc == 0" "0" "$FLOW_RC"
pair_calls16="$(grep -c '/api/tunnel-clients/pair' "$log16" || true)"
options_calls16="$(grep -c '/addons/self/options' "$log16" || true)"
t::eq "T16 exactly 2 pair calls" "2" "$pair_calls16"
t::eq "T16 exactly 1 options call" "1" "$options_calls16"

# --- Test 17: 429 twice — exactly 2 attempts, then give up --------------------

data17="$WORKDIR/t17/data"; ca17="$WORKDIR/t17/ca"
mkdir -p "$data17" "$ca17"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data17/options.json"
log17="$WORKDIR/t17/calls.log"; : > "$log17"

run_flow LC_DATA_DIR="$data17" LC_CA_DIR="$ca17" LC_OPTIONS_FILE="$data17/options.json" \
    LC_RETRY_AFTER_DEFAULT_SECONDS=1 LC_RETRY_AFTER_MAX_SECONDS=2 \
    LC_TEST_CALL_LOG="$log17" LC_TEST_PAIR_STATUS_SEQUENCE="429,429" LC_TEST_RETRY_AFTER=1

t::rc "T17 429 twice: rc == 1" "1" "$FLOW_RC"
pair_calls17="$(grep -c '/api/tunnel-clients/pair' "$log17" || true)"
options_calls17="$(grep -c '/addons/self/options' "$log17" || true)"
t::eq "T17 exactly 2 pair calls (no 3rd attempt)" "2" "$pair_calls17"
t::eq "T17 zero options calls" "0" "$options_calls17"
# The customer-facing message here is only ever shown AFTER the one
# automatic retry has already happened and failed again — it must describe
# that exhausted state, not promise a retry that has already occurred (or
# use the "Fehlversuche" wording reserved for the earlier, separate warning
# that a retry is about to happen).
t::contains "T17 message describes an already-exhausted retry, not an upcoming one" "$FLOW_OUT" "zweite Versuch"
t::not_contains "T17 message does not promise a further retry" "$FLOW_OUT" "wird genau ein weiterer Versuch"

# --- Test 18: 413 -------------------------------------------------------------

data18="$WORKDIR/t18/data"; ca18="$WORKDIR/t18/ca"
mkdir -p "$data18" "$ca18"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data18/options.json"
log18="$WORKDIR/t18/calls.log"; : > "$log18"

run_flow LC_DATA_DIR="$data18" LC_CA_DIR="$ca18" LC_OPTIONS_FILE="$data18/options.json" \
    LC_TEST_CALL_LOG="$log18" LC_TEST_PAIR_STATUS=413

t::rc "T18 413: rc == 1" "1" "$FLOW_RC"
t::contains "T18 message mentions payload too large" "$FLOW_OUT" "zu groß"
t::eq "T18 exactly 1 curl call" "1" "$(wc -l < "$log18" | tr -d '[:space:]')"

# --- Test 19: network failure (000) -------------------------------------------

data19="$WORKDIR/t19/data"; ca19="$WORKDIR/t19/ca"
mkdir -p "$data19" "$ca19"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data19/options.json"
log19="$WORKDIR/t19/calls.log"; : > "$log19"

run_flow LC_DATA_DIR="$data19" LC_CA_DIR="$ca19" LC_OPTIONS_FILE="$data19/options.json" \
    LC_TEST_CALL_LOG="$log19" LC_TEST_PAIR_STATUS=000

t::rc "T19 network failure: rc == 1" "1" "$FLOW_RC"
t::contains "T19 message mentions unreachable" "$FLOW_OUT" "nicht erreichbar"

# --- Test 20: insecure portal URL rejected before any network call -----------

data20="$WORKDIR/t20/data"; ca20="$WORKDIR/t20/ca"
mkdir -p "$data20" "$ca20"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"http://insecure.example.test"}' > "$data20/options.json"
log20="$WORKDIR/t20/calls.log"; : > "$log20"

run_flow LC_DATA_DIR="$data20" LC_CA_DIR="$ca20" LC_OPTIONS_FILE="$data20/options.json" LC_TEST_CALL_LOG="$log20"

t::rc "T20 insecure portal URL: rc == 1" "1" "$FLOW_RC"
t::contains "T20 message demands https://" "$FLOW_OUT" "https://"
t::eq "T20 zero curl calls" "0" "$(wc -l < "$log20" | tr -d '[:space:]')"

# --- Test 21: missing pairing code rejected before any network call ----------

data21="$WORKDIR/t21/data"; ca21="$WORKDIR/t21/ca"
mkdir -p "$data21" "$ca21"
printf '{"portal_base_url":"https://portal.example.test"}' > "$data21/options.json"
log21="$WORKDIR/t21/calls.log"; : > "$log21"

run_flow LC_DATA_DIR="$data21" LC_CA_DIR="$ca21" LC_OPTIONS_FILE="$data21/options.json" LC_TEST_CALL_LOG="$log21"

t::rc "T21 missing pairing code: rc == 1" "1" "$FLOW_RC"
t::contains "T21 message says no code on file" "$FLOW_OUT" "Kein Kopplungscode hinterlegt"
t::eq "T21 zero curl calls" "0" "$(wc -l < "$log21" | tr -d '[:space:]')"

# --- Test 22: 200 but frpcToml has no localIP literal -------------------------

data22="$WORKDIR/t22/data"; ca22="$WORKDIR/t22/ca"
mkdir -p "$data22" "$ca22"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data22/options.json"
log22="$WORKDIR/t22/calls.log"; : > "$log22"

run_flow LC_DATA_DIR="$data22" LC_CA_DIR="$ca22" LC_OPTIONS_FILE="$data22/options.json" \
    LC_TEST_CALL_LOG="$log22" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success_no_localip.json"

t::rc "T22 renderer drift: rc == 1" "1" "$FLOW_RC"
t::contains "T22 message mentions renderer change" "$FLOW_OUT" "Renderer"
if [ -f "$data22/frpc.toml" ]; then
    t::fail "T22 frpc.toml must not be created"
else
    t::pass "T22 frpc.toml not created"
fi

# --- Test 22b: 200 but the response body is missing all required fields ------

data22b="$WORKDIR/t22b/data"; ca22b="$WORKDIR/t22b/ca"
mkdir -p "$data22b" "$ca22b"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data22b/options.json"
log22b="$WORKDIR/t22b/calls.log"; : > "$log22b"

run_flow LC_DATA_DIR="$data22b" LC_CA_DIR="$ca22b" LC_OPTIONS_FILE="$data22b/options.json" \
    LC_TEST_CALL_LOG="$log22b" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_missing_fields.json"

t::rc "T22b missing response fields: rc == 1" "1" "$FLOW_RC"
t::contains "T22b message mentions unexpected response" "$FLOW_OUT" "Unerwartete Antwort"
if [ -f "$data22b/frpc.toml" ]; then
    t::fail "T22b frpc.toml must not be created"
else
    t::pass "T22b frpc.toml not created"
fi

# --- Test 23: clear_pairing_code fails (options 500) — overall still success -

data23="$WORKDIR/t23/data"; ca23="$WORKDIR/t23/ca"
mkdir -p "$data23" "$ca23"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data23/options.json"
log23="$WORKDIR/t23/calls.log"; : > "$log23"

run_flow LC_DATA_DIR="$data23" LC_CA_DIR="$ca23" LC_OPTIONS_FILE="$data23/options.json" \
    LC_TEST_CALL_LOG="$log23" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success.json" \
    LC_TEST_OPTIONS_STATUS=500 SUPERVISOR_TOKEN="test-token"

t::rc "T23 clear_pairing_code fails but pairing still succeeds: rc == 0" "0" "$FLOW_RC"
t::contains "T23 warns about the field not being cleared" "$FLOW_OUT" "konnte nicht automatisch entfernt werden"
if [ -f "$data23/frpc.toml" ]; then t::pass "T23 frpc.toml still present"; else t::fail "T23 frpc.toml still present"; fi

# --- Test 24: SUPERVISOR_TOKEN unset — same graceful degradation -------------

data24="$WORKDIR/t24/data"; ca24="$WORKDIR/t24/ca"
mkdir -p "$data24" "$ca24"
printf '{"pairing_code":"K7QM-3XRA","portal_base_url":"https://portal.example.test"}' > "$data24/options.json"
log24="$WORKDIR/t24/calls.log"; : > "$log24"

# SUPERVISOR_TOKEN must be cleared from THIS shell's environment before
# run_flow forks its child (env "$@" bash -c ...) — run_flow only ever
# overrides/adds variables via `env`, it never removes an already-exported
# one, so unsetting it after the call (as before) tested nothing but this
# runner's own ambient environment happening to lack the variable.
unset SUPERVISOR_TOKEN 2>/dev/null || true
run_flow LC_DATA_DIR="$data24" LC_CA_DIR="$ca24" LC_OPTIONS_FILE="$data24/options.json" \
    LC_TEST_CALL_LOG="$log24" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success.json"

t::rc "T24 no SUPERVISOR_TOKEN: rc == 0" "0" "$FLOW_RC"
t::contains "T24 warns about the field not being cleared" "$FLOW_OUT" "konnte nicht automatisch entfernt werden"
options_calls24="$(grep -c '/addons/self/options' "$log24" || true)"
t::eq "T24 zero options calls (never even attempted)" "0" "$options_calls24"

echo
echo "== Secret hygiene tests =="

# --- Test 25/26: no secret ever reaches stdout/stderr, even with tracing on --

secret_token="super-secret-rotated-token-value"
secret_pem_fragment="MIIBTESTCERTIFICATECONTENTFORFIXTUREPURPOSESONLY"
secret_code="K7QM3XRA"
secret_code_raw="K7QM-3XRA"

data25="$WORKDIR/t25/data"; ca25="$WORKDIR/t25/ca"
mkdir -p "$data25" "$ca25"
printf '{"pairing_code":"%s","portal_base_url":"https://portal.example.test"}' "$secret_code_raw" > "$data25/options.json"
log25="$WORKDIR/t25/calls.log"; : > "$log25"

run_flow LC_DATA_DIR="$data25" LC_CA_DIR="$ca25" LC_OPTIONS_FILE="$data25/options.json" \
    LC_TEST_CALL_LOG="$log25" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success.json" \
    LC_TEST_OPTIONS_STATUS=200 SUPERVISOR_TOKEN="test-token"

t::not_contains "T25 log output never contains the tunnel token" "$FLOW_OUT" "$secret_token"
t::not_contains "T25 log output never contains the CA PEM body" "$FLOW_OUT" "$secret_pem_fragment"
t::not_contains "T25 log output never contains the pairing code" "$FLOW_OUT" "$secret_code"

data26="$WORKDIR/t26/data"; ca26="$WORKDIR/t26/ca"
mkdir -p "$data26" "$ca26"
printf '{"pairing_code":"%s","portal_base_url":"https://portal.example.test"}' "$secret_code_raw" > "$data26/options.json"
log26="$WORKDIR/t26/calls.log"; : > "$log26"

run_flow_traced LC_DATA_DIR="$data26" LC_CA_DIR="$ca26" LC_OPTIONS_FILE="$data26/options.json" \
    LC_TEST_CALL_LOG="$log26" LC_TEST_PAIR_STATUS=200 LC_TEST_PAIR_BODY_FILE="$FIXTURES/pair_success.json" \
    LC_TEST_OPTIONS_STATUS=200 SUPERVISOR_TOKEN="test-token"

t::not_contains "T26 (tracing forced on by caller) never contains the tunnel token" "$FLOW_OUT" "$secret_token"
t::not_contains "T26 (tracing forced on by caller) never contains the CA PEM body" "$FLOW_OUT" "$secret_pem_fragment"
t::not_contains "T26 (tracing forced on by caller) never contains the pairing code" "$FLOW_OUT" "$secret_code"

# --- Test 27: no leftover temp artifacts under /data after success ----------

files27="$(t::basenames "$data25" | tr '\n' ' ')"
t::eq "T27 /data contains exactly options.json, frpc.toml, pepela-cloud-ca.crt" \
    "frpc.toml options.json pepela-cloud-ca.crt " "$files27"

# --- Test 28: the pairing code never appears in curl's own argv -------------

t::not_contains "T28 curl argv log never contains the pairing code" "$(cat "$log25")" "$secret_code"

echo
echo "== s6-rc glue script tests (frpc/finish, pairing/run) =="

FRPC_FINISH="$REPO_ROOT/laumann_connect/rootfs/etc/s6-overlay/s6-rc.d/frpc/finish"
PAIRING_RUN="$REPO_ROOT/laumann_connect/rootfs/etc/s6-overlay/s6-rc.d/pairing/run"

# run_finish <exit_code> <signal> — runs frpc/finish with a temp results dir
# and a stub halt binary (LC_TEST_HALT_LOG records whether halt was invoked).
# Sets FINISH_OUT, FINISH_RC, FINISH_HALT_LOG, FINISH_RESULTS_DIR.
run_finish() {
    # Placed under $WORKDIR (not the bare mktemp default location) so the
    # single `trap 'rm -rf "$WORKDIR"' EXIT` above actually cleans these up —
    # a bare `mktemp -d`/`mktemp` here would leak a directory and a file into
    # the system temp directory on every call, uncleaned by anything.
    FINISH_RESULTS_DIR="$(mktemp -d "$WORKDIR/finish-results.XXXXXX")"
    FINISH_HALT_LOG="$(mktemp "$WORKDIR/finish-halt.XXXXXX")"
    set +e
    FINISH_OUT="$(LC_S6_RESULTS_DIR="$FINISH_RESULTS_DIR" \
        LC_S6_HALT_BIN="$STUBS/halt" LC_TEST_HALT_LOG="$FINISH_HALT_LOG" \
        bash "$FRPC_FINISH" "$1" "$2" 2>&1)"
    FINISH_RC=$?
    set -e
}

# --- Test 29: clean exit (0) — no message, no exitcode file, halt not called -

run_finish 0 0
t::rc "T29 finish(0,0): rc == 0" "0" "$FINISH_RC"
t::eq "T29 finish(0,0): no output" "" "$FINISH_OUT"
t::eq "T29 finish(0,0): no exitcode file written" "" "$(cat "$FINISH_RESULTS_DIR/exitcode" 2>/dev/null || true)"
t::eq "T29 finish(0,0): halt not called" "" "$(cat "$FINISH_HALT_LOG")"

# --- Test 30: s6 "killed by signal" sentinel (256) — same as a clean exit ---

run_finish 256 15
t::rc "T30 finish(256,15): rc == 0" "0" "$FINISH_RC"
t::eq "T30 finish(256,15): no output" "" "$FINISH_OUT"
t::eq "T30 finish(256,15): no exitcode file written" "" "$(cat "$FINISH_RESULTS_DIR/exitcode" 2>/dev/null || true)"
t::eq "T30 finish(256,15): halt not called" "" "$(cat "$FINISH_HALT_LOG")"

# --- Test 31: a real crash (nonzero, not the 256 sentinel) halts the add-on -

run_finish 1 0
t::contains "T31 finish(1,0): logs the exit code" "$FINISH_OUT" "frpc exited with code 1"
t::eq "T31 finish(1,0): writes the exit code to the results file" "1" "$(cat "$FINISH_RESULTS_DIR/exitcode")"
t::contains "T31 finish(1,0): halt was called" "$(cat "$FINISH_HALT_LOG")" "halt called"

run_finish 2 0
t::contains "T32 finish(2,0): logs the exit code" "$FINISH_OUT" "frpc exited with code 2"
t::eq "T32 finish(2,0): writes the exit code to the results file" "2" "$(cat "$FINISH_RESULTS_DIR/exitcode")"

# run_pairing_run <options_file> — runs pairing/run with a stub bashio and a
# stub pairing.sh (tests/stubs/noop-pairing.sh), isolating the log_level
# extraction/dispatch logic (finding #4's fix) from the full lc::main flow,
# which T12-T28 above already cover via run_flow. Sets PR_OUT, PR_RC.
run_pairing_run() {
    local options_file="$1"
    set +e
    PR_OUT="$(
        LC_OPTIONS_FILE="$options_file" LC_PAIRING_SH="$STUBS/noop-pairing.sh" \
        bash -c '
            bashio::log.level() { printf "LOGLEVEL=%s\n" "$1"; }
            source "$0"
        ' "$PAIRING_RUN" 2>&1
    )"
    PR_RC=$?
    set -e
}

# --- Test 33: pairing/run picks up log_level from a normal options.json ----

data33="$WORKDIR/t33"; mkdir -p "$data33"
printf '{"log_level":"debug"}' > "$data33/options.json"
run_pairing_run "$data33/options.json"
t::rc "T33 pairing/run with log_level=debug: rc == 0" "0" "$PR_RC"
t::contains "T33 dispatches the configured log level" "$PR_OUT" "LOGLEVEL=debug"
t::contains "T33 reaches lc::main" "$PR_OUT" "STUB_LC_MAIN_CALLED"

# --- Test 34: pairing/run survives a missing options.json (finding #4) -----

run_pairing_run "$WORKDIR/does-not-exist/options.json"
t::rc "T34 pairing/run with missing options.json: rc == 0" "0" "$PR_RC"
t::contains "T34 falls back to log level info" "$PR_OUT" "LOGLEVEL=info"
t::contains "T34 still reaches lc::main (no FATAL abort)" "$PR_OUT" "STUB_LC_MAIN_CALLED"

# --- Test 35: pairing/run survives an unparsable options.json --------------

data35="$WORKDIR/t35"; mkdir -p "$data35"
printf 'not valid json' > "$data35/options.json"
run_pairing_run "$data35/options.json"
t::rc "T35 pairing/run with corrupt options.json: rc == 0" "0" "$PR_RC"
t::contains "T35 falls back to log level info" "$PR_OUT" "LOGLEVEL=info"
t::contains "T35 still reaches lc::main (no FATAL abort)" "$PR_OUT" "STUB_LC_MAIN_CALLED"

echo
echo "== Static checks =="

if command -v shellcheck >/dev/null 2>&1; then
    # -x follows the `# shellcheck source=` directives (resolved via -P SCRIPTDIR,
    # relative to each script's own directory, since the CWD this runner is
    # invoked from can be anything); -e SC2016 excludes the two single-quoted
    # `bash -c '...'` payloads in run_flow/run_flow_traced above, which are
    # deliberately single-quoted so $LC_PAIRING_SH expands inside the child
    # bash, not in this shell.
    if shellcheck -s bash -x -P SCRIPTDIR -e SC2016 \
        "$PAIRING_SH" \
        "$REPO_ROOT/laumann_connect/rootfs/etc/s6-overlay/s6-rc.d/pairing/run" \
        "$REPO_ROOT/laumann_connect/rootfs/etc/s6-overlay/s6-rc.d/frpc/run" \
        "$REPO_ROOT/laumann_connect/rootfs/etc/s6-overlay/s6-rc.d/frpc/finish" \
        "$HERE/run.sh" "$HERE/lib.sh" "$HERE/stubs/curl" "$HERE/stubs/halt" "$HERE/stubs/noop-pairing.sh"; then
        t::pass "shellcheck clean"
    else
        t::fail "shellcheck clean"
    fi
else
    echo "skip    shellcheck not installed — skipping static shell lint"
fi

if python3 -c "import yaml" >/dev/null 2>&1; then
    if python3 - "$CONFIG_YAML" "$REPO_ROOT/laumann_connect/translations/en.yaml" "$REPO_ROOT/laumann_connect/translations/de.yaml" <<'PY'
import sys, yaml
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        yaml.safe_load(f)
PY
    then
        t::pass "config.yaml and translations/*.yaml are valid YAML"
    else
        t::fail "config.yaml and translations/*.yaml are valid YAML"
    fi
else
    echo "skip    PyYAML not installed — skipping YAML validity check"
fi

# --- Schema self-test: config.yaml's pairing_code regex vs normalize_code ----

if python3 -c "import yaml" >/dev/null 2>&1; then
    schema_regex="$(python3 - "$CONFIG_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = yaml.safe_load(f)
raw = cfg["schema"]["pairing_code"]
# raw looks like: match(<regex>)?
inner = raw[len("match("):]
inner = inner.rsplit(")", 1)[0]
print(inner)
PY
    )"
    if python3 - "$schema_regex" <<'PY'
import re, sys
pattern = sys.argv[1]
valid = ["K7QM-3XRA", "k7qm3xra", "K7QM3XRA", "K7QM 3XRA", " K7QM3XRA ", "XX-XX-XX-XX"]
invalid = ["", "null", "K7QM3XR", "K7QM3XRAA", "K7QM3XR0", "K7QM3XRI", "K7QM3XRO", "K7QM3XR1"]
ok = True
for v in valid:
    if not re.match(pattern, v):
        print("expected schema regex to match:", repr(v)); ok = False
for v in invalid:
    if re.match(pattern, v):
        print("expected schema regex to reject:", repr(v)); ok = False
sys.exit(0 if ok else 1)
PY
    then
        t::pass "config.yaml pairing_code regex matches lc::normalize_code's fixture set"
    else
        t::fail "config.yaml pairing_code regex matches lc::normalize_code's fixture set"
    fi
else
    echo "skip    PyYAML not installed — skipping schema/normalize_code drift check"
fi

# --- Regression guard: pairing_code must never be a default under options: --

if python3 -c "import yaml" >/dev/null 2>&1; then
    if python3 - "$CONFIG_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = yaml.safe_load(f)
sys.exit(1 if "pairing_code" in cfg.get("options", {}) else 0)
PY
    then
        t::pass "pairing_code is absent from config.yaml's options: block (FUND 1 regression guard)"
    else
        t::fail "pairing_code is absent from config.yaml's options: block (FUND 1 regression guard)"
    fi
else
    echo "skip    PyYAML not installed — skipping FUND 1 regression guard"
fi

echo
t::summary
