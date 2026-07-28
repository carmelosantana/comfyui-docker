#!/usr/bin/env bash
# Minimal dependency-free assertion harness.
set -u
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" != "$actual" ]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: ${msg} (expected='${expected}' actual='${actual}')"
  else
    echo "  ok:   ${msg}"
  fi
}

assert_true() {
  local cond_desc="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if eval "$1"; then
    echo "  ok:   ${cond_desc}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: ${cond_desc} (condition false: $1)"
  fi
}

finish() {
  echo "---- ${TESTS_RUN} checks, ${TESTS_FAILED} failed ----"
  [ "$TESTS_FAILED" -eq 0 ]
}
