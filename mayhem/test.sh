#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Runs resiprocate's own unit tests (built by mayhem/build.sh with normal flags). Each test binary
# asserts internally and, on success, prints its own verdict line. A test counts as passed only when it
# exits 0 AND prints that verdict, so a program neutered to exit(0) produces no verdict and fails.
TESTS="testData testParseBuffer testDnsUtil testXMLCursor testMD5Stream testDigestStream testDataStream
       testUri testParserCategories testSipMessage testEmbedded testMultipartMixedContents testSipFrag testTuple"
VERDICT='(All OK|ALL OK|TEST OK|Tests OK|OVERALL RESULTS: PASSED)'

passed=0; failed=0
for t in $TESTS; do
  bin=$(find mayhem/_build-tests -name "$t" -type f -perm -u+x 2>/dev/null | head -1)
  if [ -z "$bin" ]; then echo "FAIL $t: test binary missing (build.sh bug)" >&2; failed=$((failed+1)); continue; fi
  out=$(cd "$(dirname "$bin")" && timeout 600 "./$t" 2>&1); rc=$?
  if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -Eq "$VERDICT"; then
    echo "PASS $t"; passed=$((passed+1))
  else
    echo "FAIL $t (rc=$rc)"; printf '%s\n' "$out" | tail -5; failed=$((failed+1))
  fi
done

emit_ctrf "resiprocate-unit-tests" "$passed" "$failed" 0
