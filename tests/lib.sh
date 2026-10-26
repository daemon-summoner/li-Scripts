#!/usr/bin/env bash
# tests/lib.sh - fail/pass primitives for the li-Scripts test suite.
# Source it from a test script. fail exits non-zero; pass records a green line.

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}
pass() { printf 'ok   %s\n' "$*"; }
skip() { printf 'skip %s\n' "$*"; }
