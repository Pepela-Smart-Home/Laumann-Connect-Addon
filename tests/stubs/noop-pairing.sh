#!/usr/bin/env bash
# shellcheck shell=bash
#
# Stand-in for the real pairing.sh, used only by the pairing/run tests below
# to isolate that script's own log_level-extraction/bashio-dispatch logic
# (finding #4's fix) from the full lc::main pairing flow — which already has
# dedicated coverage via run_flow's T12-T28 tests further up in this file.
# Sourcing this file must stay side-effect free, same contract as the real
# pairing.sh.
lc::main() {
    echo "STUB_LC_MAIN_CALLED"
    return 0
}
