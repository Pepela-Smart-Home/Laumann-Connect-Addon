#!/usr/bin/env bash
# shellcheck shell=bash
#
# Minimal assertion helpers for tests/run.sh. No test framework, no
# dependency beyond bash itself — the whole point of this suite is to run
# with nothing but bash, jq and curl (the same trio the add-on itself needs).

LC_TEST_COUNT=0
LC_TEST_FAILURES=0

t::pass() {
    LC_TEST_COUNT=$((LC_TEST_COUNT + 1))
    printf 'ok      %s\n' "$1"
}

t::fail() {
    LC_TEST_COUNT=$((LC_TEST_COUNT + 1))
    LC_TEST_FAILURES=$((LC_TEST_FAILURES + 1))
    printf 'FAIL    %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '        %s\n' "$2"
    fi
}

# t::eq <test-name> <expected> <actual>
t::eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        t::pass "$name"
    else
        t::fail "$name" "expected [${expected}] got [${actual}]"
    fi
}

# t::rc <test-name> <expected-rc> <actual-rc>
t::rc() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        t::pass "$name"
    else
        t::fail "$name" "expected rc ${expected} got rc ${actual}"
    fi
}

# t::contains <test-name> <haystack> <needle>
t::contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) t::pass "$name" ;;
        *) t::fail "$name" "expected to find [${needle}] in [${haystack}]" ;;
    esac
}

# t::not_contains <test-name> <haystack> <needle>
t::not_contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) t::fail "$name" "expected NOT to find [${needle}] in [${haystack}]" ;;
        *) t::pass "$name" ;;
    esac
}

# t::true <test-name> <condition-description> — call as: if <cond>; then t::true name; else t::fail name; fi
t::true() {
    t::pass "$1"
}

# t::stat_size <path> — file size in bytes. GNU coreutils (Linux, the add-on's
# own Alpine container) and BSD stat (macOS, where these tests also need to
# run per the vault's multi-machine convention) disagree on flag syntax —
# `stat -c` is a fatal "illegal option" on macOS. Try GNU first, fall back to
# BSD; whichever the host actually has will succeed, the other's stderr is
# discarded.
t::stat_size() {
    stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"
}

# t::stat_mode <path> — octal permission bits (e.g. "600"), same GNU/BSD split.
t::stat_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"
}

# t::basenames <dir> — sorted, newline-separated basenames of the regular
# files directly in <dir>. `find -printf` is GNU-only (BSD find on macOS has
# no -printf at all), so this sticks to portable `find` primaries plus a
# `basename` pass instead.
t::basenames() {
    find "$1" -maxdepth 1 -type f -exec basename {} \; | sort
}

t::summary() {
    printf '\n%d/%d tests passed\n' "$((LC_TEST_COUNT - LC_TEST_FAILURES))" "$LC_TEST_COUNT"
    [ "$LC_TEST_FAILURES" -eq 0 ]
}
