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

t::summary() {
    printf '\n%d/%d tests passed\n' "$((LC_TEST_COUNT - LC_TEST_FAILURES))" "$LC_TEST_COUNT"
    [ "$LC_TEST_FAILURES" -eq 0 ]
}
