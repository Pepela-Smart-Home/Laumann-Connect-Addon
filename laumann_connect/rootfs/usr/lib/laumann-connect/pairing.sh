#!/usr/bin/env bash
# shellcheck shell=bash
#
# Laumann Connect — pairing and configuration logic.
#
# This file contains the add-on's entire testable logic. The s6-rc scripts under
# /etc/s6-overlay/s6-rc.d are pure glue (each under 10 lines). This file is
# deliberately free of bashio calls in its core logic (only the logging wrapper
# optionally reaches for bashio), so it can be tested directly — without a
# container and without any extra tooling — via ./tests/run.sh.
#
# Sourcing this file has NO side effects. Only calling lc::main changes shell
# options (umask, errexit, nounset, pipefail) and touches the filesystem —
# callers that want to isolate that (tests) should invoke it in a subshell.

: "${LC_DATA_DIR:=/data}"
: "${LC_CA_DIR:=/etc/frp}"
: "${LC_OPTIONS_FILE:=${LC_DATA_DIR}/options.json}"
: "${LC_SUPERVISOR_URL:=http://supervisor}"
: "${LC_HTTP_TIMEOUT_SECONDS:=30}"
: "${LC_RETRY_AFTER_DEFAULT_SECONDS:=60}"
: "${LC_RETRY_AFTER_MAX_SECONDS:=600}"
: "${LC_HA_HOSTNAME:=homeassistant}"

readonly LC_CODE_ALPHABET='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
readonly LC_CODE_LENGTH=8
readonly LC_LOCAL_IP_LITERAL='localIP = "127.0.0.1"'
readonly LC_CA_FILENAME='pepela-cloud-ca.crt'

# ---------------------------------------------------------------------------
# Logging (bashio-optional)
# ---------------------------------------------------------------------------

lc::_log() { # <level> <message...>
    local level="$1"
    shift
    local fn="bashio::log.${level}"
    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn" "$*"
    else
        printf '[%s] %s\n' "$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')" "$*" >&2
    fi
}
lc::log_info() { lc::_log info "$@"; }
lc::log_warning() { lc::_log warning "$@"; }
lc::log_error() { lc::_log error "$@"; }
lc::die() {
    lc::log_error "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------

# lc::normalize_code <raw>
# rc 0 ok (prints normalized 8-char uppercase code) / 1 empty or "null" / 2 wrong
# length after stripping / 3 character outside the alphabet.
lc::normalize_code() {
    local raw="${1:-}"
    local lower_raw
    lower_raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$raw" ] || [ "$lower_raw" = "null" ]; then
        return 1
    fi

    local stripped="${raw//[[:space:]-]/}"
    stripped="$(printf '%s' "$stripped" | tr '[:lower:]' '[:upper:]')"

    if [ -z "$stripped" ]; then
        return 1
    fi
    if [ "${#stripped}" -ne "$LC_CODE_LENGTH" ]; then
        return 2
    fi

    local i c
    for ((i = 0; i < ${#stripped}; i++)); do
        c="${stripped:i:1}"
        case "$LC_CODE_ALPHABET" in
            *"$c"*) ;;
            *) return 3 ;;
        esac
    done

    printf '%s' "$stripped"
    return 0
}

# lc::validate_portal_url <raw>
# rc 0 ok (prints normalized URL without trailing slash) / 1 empty / 2 no https://
# scheme / 3 contains userinfo (@) / 4 no host after the scheme.
lc::validate_portal_url() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        return 1
    fi
    case "$raw" in
        https://*) ;;
        *) return 2 ;;
    esac

    local rest="${raw#https://}"
    rest="${rest%/}"

    case "$rest" in
        *@*) return 3 ;;
    esac
    if [ -z "$rest" ]; then
        return 4
    fi

    printf 'https://%s' "$rest"
    return 0
}

# lc::request_body_json <code>
lc::request_body_json() {
    printf '{"pairingCode":"%s"}' "$1"
}

# lc::count_local_ip_literal <file>
# Prints the number of exact occurrences of the localIP literal. Uses
# `grep -o | wc -l`, NOT `grep -c` — grep -c counts matching lines, not
# occurrences, which would undercount two literals on the same line.
lc::count_local_ip_literal() {
    local file="$1"
    local count
    count="$(grep -o -F "$LC_LOCAL_IP_LITERAL" "$file" 2>/dev/null | wc -l)"
    printf '%s' "${count// /}"
    return 0
}

# lc::adapt_frpc_toml <in> <out>
# rc 0 ok / 5 the localIP literal did not occur exactly once (no output file
# written in that case) / 6 mktemp, sed or mv itself failed (e.g. /data out of
# space) — the temp file is removed and no output file is left behind, same
# guarantee as the 5 case. Writes to a temp file first, then moves it into
# place — never edits the destination in place, so a failed run never leaves a
# half-rewritten file that a later "already paired" check would treat as valid.
# Every step's own exit status is checked: a silently swallowed mktemp/sed
# failure would still `mv` a temp file (empty, partial, or literally the
# string "mktemp: ...") into place and return 0, and the caller logs "Kopplung
# erfolgreich" on rc 0 alone.
#
# Also PREPENDS a top-level `loginFailExit = false` line. frpc >= v0.61
# defaults loginFailExit to true (client.go's `EmptyOr(..., true)`), and the
# portal-side renderer never sets it (FrpcSnippetRenderer/TunnelPairingRoutes
# only emit serverAddr/serverPort/trustedCaFile/user/metadatas/proxies) — so
# without this, a SINGLE failed login attempt (e.g. the customer's router or
# DNS hasn't finished coming back up yet after a reboot) makes frpc exit
# non-zero, and frpc/finish then halts the whole add-on: exactly on the
# already-paired, zero-network-calls restart path this add-on exists to
# support, and with no watchdog to bring it back (see config.yaml). Forcing
# it to false makes frpc retry the login forever instead, matching the
# reconnect behaviour it already has after a login that DID succeed. It must
# land BEFORE any `[[proxies]]` table header to be a top-level key — hence
# prepended, not appended.
lc::adapt_frpc_toml() {
    local in="$1" out="$2"
    local count
    count="$(lc::count_local_ip_literal "$in")"
    if [ "$count" -ne 1 ]; then
        return 5
    fi

    local tmp
    tmp="$(mktemp "${out}.XXXXXX")" || return 6
    if ! {
        printf 'loginFailExit = false\n'
        sed 's|localIP = "127\.0\.0\.1"|localIP = "'"${LC_HA_HOSTNAME}"'"|' "$in"
    } > "$tmp"; then
        rm -f "$tmp"
        return 6
    fi
    if ! mv "$tmp" "$out"; then
        rm -f "$tmp"
        return 6
    fi
    return 0
}

# lc::explain_status <http_code> [retry_after] [portal_url]
# Prints the customer-facing message for a given HTTP status and returns a
# distinct exit code per case: 0=200, 10=400, 11=429, 12=413, 13=other/network.
lc::explain_status() {
    local status="$1" retry_after="${2:-}" portal_url="${3:-}"
    case "$status" in
        200)
            return 0
            ;;
        400)
            echo "Der Kopplungscode wurde nicht akzeptiert. Er ist entweder abgelaufen (Codes gelten 15 Minuten), bereits verwendet, oder falsch abgetippt. Fordern Sie bei Laumann Technology einen neuen Code an und tragen Sie ihn in den Add-on-Optionen ein."
            return 10
            ;;
        429)
            # This branch is only ever reached AFTER lc::main has already
            # performed its one automatic retry (see the 429-handling block
            # there) and that retry failed again — never on the first 429,
            # which is handled inline with its own "waiting, will retry once"
            # warning. So this message must describe an EXHAUSTED retry, not
            # an upcoming one — the previous wording ("Es wird genau ein
            # weiterer Versuch ... unternommen") was always false here, since
            # by the time a caller sees it, that one further attempt has
            # already happened and failed.
            echo "Auch der zweite Versuch (nach ${retry_after} Sekunden Wartezeit) wurde vom Server abgelehnt. Warten Sie mindestens 15 Minuten und starten Sie das Add-on danach manuell erneut — ein sofortiger Neustart sperrt Ihre Internetadresse nur weiter."
            return 11
            ;;
        413)
            echo "Die Anfrage war zu groß. Bitte tragen Sie ausschließlich den 8-stelligen Kopplungscode ein."
            return 12
            ;;
        *)
            echo "Der Portal-Server unter ${portal_url} ist nicht erreichbar (HTTP ${status}). Prüfen Sie die Internetverbindung und die Portal-Adresse in den Add-on-Optionen."
            return 13
            ;;
    esac
}

# lc::retry_after_seconds <header_file>
# Parses a Retry-After header (case-insensitive) out of a curl -D dump. Falls
# back to LC_RETRY_AFTER_DEFAULT_SECONDS when missing/invalid, capped at
# LC_RETRY_AFTER_MAX_SECONDS, floored at 1.
lc::retry_after_seconds() {
    local header_file="$1"
    local value
    value="$(grep -i '^retry-after:' "$header_file" 2>/dev/null | tail -n1 \
        | sed -E 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*//')"
    value="$(printf '%s' "$value" | tr -d '[:space:]')"

    # Digit count is capped at 9 (max 999999999) on purpose, not just
    # non-empty-digits: an unbounded ^[0-9]+$ still matches a value far
    # outside bash's integer range (e.g. a 20-digit Retry-After), and the
    # `-gt`/`-lt` comparisons below would then fail with "integer expected"
    # instead of capping it — silently returning the raw, uncapped value to
    # the caller. Nine digits is comfortably inside every relevant integer
    # range (32- and 64-bit) and far above LC_RETRY_AFTER_MAX_SECONDS, so it
    # never clips a value that would otherwise pass through untouched.
    if ! [[ "$value" =~ ^[0-9]{1,9}$ ]]; then
        value="$LC_RETRY_AFTER_DEFAULT_SECONDS"
    fi
    if [ "$value" -gt "$LC_RETRY_AFTER_MAX_SECONDS" ]; then
        value="$LC_RETRY_AFTER_MAX_SECONDS"
    fi
    if [ "$value" -lt 1 ]; then
        value=1
    fi

    printf '%s' "$value"
    return 0
}

# lc::read_option <key>
# Reads a single option directly from /data/options.json via jq — never via
# bashio::config, which returns the literal string "null" for a missing key
# (bashio/lib/config.sh) rather than an empty string.
lc::read_option() {
    local key="$1"
    local value
    value="$(jq -r --arg k "$key" '.[$k] // "" | tostring' "$LC_OPTIONS_FILE" 2>/dev/null)" || value=""
    printf '%s' "$value"
    return 0
}

# lc::strip_pairing_code <options_file>
# Prints {"options": <full option set minus pairing_code>}. Deletes the key —
# never sets it to "" — because POST /addons/self/options replaces the whole
# option set rather than merging into it.
lc::strip_pairing_code() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    local result
    result="$(jq -c 'del(.pairing_code) | {options: .}' "$file" 2>/dev/null)" || return 1
    printf '%s' "$result"
    return 0
}

# lc::already_paired [dir]
# rc 0 when a non-empty frpc.toml exists (i.e. a previous pairing succeeded).
lc::already_paired() {
    local dir="${1:-$LC_DATA_DIR}"
    [ -s "${dir}/frpc.toml" ]
}

# lc::ca_pem_looks_valid <file>
# rc 0 when the file exists, is non-empty, AND contains a PEM certificate
# terminator. `[ -s ]` alone is not enough: a CA write interrupted midway
# (disk full, container killed) can leave a non-empty but truncated file,
# which `[ -s ]` would accept as a complete, valid pairing on the next
# start. A truncated CA then fails frpc's TLS handshake, frpc exits non-zero,
# and frpc/finish halts the add-on — with "Bereits gekoppelt" as the last log
# line, actively pointing away from the real cause.
lc::ca_pem_looks_valid() {
    local file="$1"
    [ -s "$file" ] && grep -q -- '-----END CERTIFICATE-----' "$file"
}

# lc::write_ca_pem <body_json_file> <out>
# rc 0 ok / 6 mktemp, jq or mv itself failed (e.g. /data out of space) — the
# temp file is removed and no output file is left behind. Mirrors
# lc::adapt_frpc_toml's write-to-temp-then-mv discipline for exactly the same
# reason: a half-written CA must never sit at `out` where a later
# lc::ca_pem_looks_valid/`[ -s ]` check could mistake it for a complete one.
lc::write_ca_pem() {
    local body="$1" out="$2"
    local tmp
    tmp="$(mktemp "${out}.XXXXXX")" || return 6
    if ! jq -r '.caCertificatePem' "$body" > "$tmp"; then
        rm -f "$tmp"
        return 6
    fi
    if ! chmod 0600 "$tmp"; then
        rm -f "$tmp"
        return 6
    fi
    if ! mv "$tmp" "$out"; then
        rm -f "$tmp"
        return 6
    fi
    return 0
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# lc::http_pair <portal_url> <code> <body_out> <header_out>
# Prints the HTTP status code (or "000" on a connection-level failure). The
# pairing code is sent over stdin, never as a curl argument (argv is readable
# via /proc/*/cmdline inside the container). The response body is written
# straight to a file, never captured into a shell variable or logged.
lc::http_pair() {
    set +x
    local portal="$1" code="$2" body_out="$3" header_out="$4"
    local status
    status=$(
        lc::request_body_json "$code" \
            | curl -sS --fail-with-body \
                --proto '=https' --proto-redir '=https' \
                --max-time "${LC_HTTP_TIMEOUT_SECONDS}" \
                -H 'Content-Type: application/json' \
                --data-binary @- \
                -D "$header_out" -o "$body_out" -w '%{http_code}' \
                "${portal}/api/tunnel-clients/pair" 2>/dev/null
    ) || status="${status:-000}"
    printf '%s' "${status:-000}"
}

# lc::clear_pairing_code
# Best-effort: consumes the pairing code from /data/options.json via the
# Supervisor's own API so it cannot be reused. A failure here is only ever a
# warning — the pairing itself already succeeded by the time this runs.
lc::clear_pairing_code() {
    set +x
    [ -n "${SUPERVISOR_TOKEN:-}" ] || return 1
    local payload
    payload="$(lc::strip_pairing_code "$LC_OPTIONS_FILE")" || return 1
    printf '%s' "$payload" \
        | curl -sS --max-time 15 -X POST \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            -o /dev/null -w '%{http_code}' \
            "${LC_SUPERVISOR_URL}/addons/self/options" \
        | grep -q '^2' || return 1
    lc::log_info "Der Kopplungscode wurde verbraucht und aus der Konfiguration entfernt — das ist beabsichtigt. Eine erneute Kopplung benötigt einen neuen Code."
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

lc::main() {
    umask 077
    set -o errexit -o nounset -o pipefail
    set +x

    install -d -m 0700 "$LC_DATA_DIR" "$LC_CA_DIR"

    local ca_data="${LC_DATA_DIR}/${LC_CA_FILENAME}"
    local ca_etc="${LC_CA_DIR}/${LC_CA_FILENAME}"
    local frpc_toml="${LC_DATA_DIR}/frpc.toml"

    if lc::already_paired "$LC_DATA_DIR"; then
        if ! lc::ca_pem_looks_valid "$ca_data"; then
            lc::die "Die gespeicherte Kopplung ist unvollständig oder beschädigt (Zertifikat fehlt oder ist ungültig). Setzen Sie die Add-on-Daten zurück und koppeln Sie mit einem neuen Code erneut."
        fi
        # The container is layer storage under /etc, not /data — it never
        # survives a restart, so it has to be re-seeded on every start, even
        # (especially) on this "nothing to do" path.
        install -m 0600 "$ca_data" "$ca_etc"
        lc::log_info "Bereits gekoppelt — verwende die gespeicherte Konfiguration."
        # A pairing_code left in the options is silently ignored on this path
        # — it is never read, let alone consumed — so a customer who pastes a
        # rotated code and restarts sees no feedback at all otherwise. Only
        # warn when something is actually there and looks like a real code,
        # so a blank options field (the common case) stays silent.
        #
        # This field is NOT necessarily something the customer "just typed
        # in": lc::clear_pairing_code (below, on the success path) is
        # best-effort and can fail (Supervisor API hiccup, missing
        # SUPERVISOR_TOKEN — see its own comment), in which case a pairing
        # that already succeeded leaves its now-spent code sitting in the
        # field indefinitely. The wording here must stay neutral about which
        # of the two happened — it must never claim the code is "newly
        # entered", and its remedy must not push a customer with a perfectly
        # working, already-paired install to reset their add-on data just
        # because the leftover-clear step once failed.
        local stray_code
        set +e
        stray_code="$(lc::normalize_code "$(lc::read_option pairing_code)")"
        set -e
        if [ -n "$stray_code" ]; then
            lc::log_warning "Im Feld Kopplungscode steht noch ein Wert — er wird ignoriert, weil bereits eine Kopplung besteht. Stammt er von der letzten erfolgreichen Kopplung, können Sie das Feld einfach leeren. Nur um einen NEUEN Code zu verwenden, müssen Sie die Add-on-Daten zurücksetzen und erneut koppeln."
        fi
        return 0
    fi

    local portal_raw portal rc
    portal_raw="$(lc::read_option portal_base_url)"
    set +e
    portal="$(lc::validate_portal_url "$portal_raw")"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 2 ]; then
            lc::die "Die Portal-Adresse muss mit https:// beginnen. Der Kopplungscode darf niemals unverschlüsselt übertragen werden."
        fi
        lc::die "Die Portal-Adresse in den Add-on-Optionen ist ungültig. Prüfen Sie die Eingabe."
    fi

    local code_raw code
    code_raw="$(lc::read_option pairing_code)"
    set +e
    code="$(lc::normalize_code "$code_raw")"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        lc::die "Kein Kopplungscode hinterlegt. Fordern Sie einen Code bei Laumann Technology an und tragen Sie ihn in den Add-on-Optionen ein."
    fi

    local body header
    body="$(mktemp "${LC_DATA_DIR}/pair-body.XXXXXX")"
    header="$(mktemp "${LC_DATA_DIR}/pair-header.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$body' '$header'" EXIT INT TERM

    local status
    status="$(lc::http_pair "$portal" "$code" "$body" "$header")"

    local retry_after=""
    if [ "$status" = "429" ]; then
        retry_after="$(lc::retry_after_seconds "$header")"
        lc::log_warning "Zu viele Fehlversuche – warte ${retry_after} Sekunden vor dem letzten Versuch."
        sleep "$retry_after"
        status="$(lc::http_pair "$portal" "$code" "$body" "$header")"
    fi

    if [ "$status" != "200" ]; then
        local message
        set +e
        message="$(lc::explain_status "$status" "$retry_after" "$portal")"
        set -e
        lc::die "$message"
    fi

    if ! jq -e '(.frpcToml != null and .frpcToml != "")
            and (.caCertificatePem != null and .caCertificatePem != "")
            and (.clientId != null and .clientId != "")
            and (.subdomain != null and .subdomain != "")' "$body" >/dev/null 2>&1; then
        lc::die "Unerwartete Antwort vom Portal-Server (fehlende Felder). Bitte informieren Sie Laumann Technology."
    fi

    local raw_toml
    raw_toml="$(mktemp "${LC_DATA_DIR}/pair-raw.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$body' '$header' '$raw_toml'" EXIT INT TERM
    jq -r '.frpcToml' "$body" > "$raw_toml"

    set +e
    lc::adapt_frpc_toml "$raw_toml" "$frpc_toml"
    rc=$?
    set -e
    if [ "$rc" -eq 5 ]; then
        lc::die "Unerwartetes frpc.toml-Format vom Portal-Server — der Renderer auf Serverseite hat sich geändert. Bitte informieren Sie Laumann Technology."
    elif [ "$rc" -ne 0 ]; then
        lc::die "Die frpc.toml konnte nicht geschrieben werden (z. B. kein Speicherplatz mehr unter /data). Prüfen Sie den freien Speicherplatz und starten Sie das Add-on erneut."
    fi
    chmod 0600 "$frpc_toml"

    set +e
    lc::write_ca_pem "$body" "$ca_data"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        lc::die "Das Zertifikat konnte nicht gespeichert werden (z. B. kein Speicherplatz mehr unter /data). Prüfen Sie den freien Speicherplatz und starten Sie das Add-on erneut."
    fi
    install -m 0600 "$ca_data" "$ca_etc"

    local client_id subdomain
    client_id="$(jq -r '.clientId' "$body")"
    subdomain="$(jq -r '.subdomain' "$body")"
    lc::log_info "Kopplung erfolgreich. Client: ${client_id}, Subdomain: ${subdomain}."

    if ! lc::clear_pairing_code; then
        lc::log_warning "Der Kopplungscode konnte nicht automatisch entfernt werden — die Kopplung ist dennoch erfolgreich."
    fi

    rm -f "$body" "$header" "$raw_toml"
    trap - EXIT INT TERM
    return 0
}
