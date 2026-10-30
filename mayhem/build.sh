#!/usr/bin/env bash
#
# mayhem/build.sh — build resiprocate's fuzz harnesses (libFuzzer + standalone) and its test suite.
# Runs inside the commit image as `mayhem` in /mayhem; re-runnable and offline (no fetches).
#   fuzz binaries : /mayhem/{fuzzUtil,fuzzStack,aresfuzz,aresfuzzname}[-standalone]
#   test suite    : mayhem/_build-tests  (project's normal flags; run by mayhem/test.sh)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Feature set follows upstream's OSS-Fuzz recipe (build/oss-fuzz/build.sh): the stack + utility
# libraries and the bundled ARES resolver, with every optional dependency off so nothing is fetched.
COMMON_OPTS=(
  -DBUILD_SHARED_LIBS=OFF -DBUILD_CLICKTOCALL=OFF -DBUILD_QPID_PROTON=OFF -DBUILD_RECON=OFF
  -DBUILD_REFLOW=OFF -DBUILD_REND=OFF -DBUILD_REPRO=OFF -DBUILD_RETURN=OFF -DBUILD_TFM=OFF
  -DBUILD_MEDIA=OFF -DREGENERATE_MEDIA_SAMPLES=OFF -DUSE_DTLS=OFF -DUSE_KURENTO=OFF
  -DUSE_MAXMIND_GEOIP=OFF -DUSE_POPT=OFF -DWITH_C_ARES=OFF -DWITH_SSL=OFF -DBUILD_TESTING=ON
)

# cmake wipes its cache when the compiler path changes (the image build resolves `clang` through the
# ccache masquerade dir, a re-run does not) and, when it does, drops the -D options on the command
# line. Start such a tree over instead.
fresh_if_compiler_changed() {
  local dir="$1"
  if [ -f "$dir/CMakeCache.txt" ] &&
     ! grep -qx "CMAKE_C_COMPILER:[A-Z]*=$(command -v "$CC")" "$dir/CMakeCache.txt"; then
    rm -rf "$dir"
  fi
}

# 1) Sanitized + instrumented project and harness objects. -fsanitize=fuzzer-no-link gives the
#    library SanCov edge coverage; without it Mayhem would record 0 edges.
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O2 -DNDEBUG"
fresh_if_compiler_changed mayhem/_build
cmake -S . -B mayhem/_build -GNinja -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" "${COMMON_OPTS[@]}"
cmake --build mayhem/_build -j"$MAYHEM_JOBS" --target rutil resipares fuzzStack aresfuzz

# 2) Re-link every harness twice from cmake's objects: libFuzzer, and the run-once standalone
#    reproducer; both carry the LeakSanitizer-off hook.
B=mayhem/_build
LIBRUTIL=$B/rutil/librutil.a
LIBRESIP=$B/resip/stack/libresip.a
LIBARES=$B/rutil/dns/ares/libresipares.a
for f in "$LIBRUTIL" "$LIBRESIP" "$LIBARES"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done

OBJ=/tmp/mayhem-objs.$$
mkdir -p "$OBJ"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OBJ/lsan_off.o"

link_harness() { # name, libs..., -- objs...
  local name="$1"; shift
  local libs=() objs=()
  while [ "$1" != "--" ]; do libs+=("$1"); shift; done; shift
  objs=("$@")
  for o in "${objs[@]}"; do [ -f "$o" ] || { echo "missing $o" >&2; exit 1; }; done
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $LIB_FUZZING_ENGINE \
    "${objs[@]}" "$OBJ/lsan_off.o" "${libs[@]}" -pthread -o "$SRC/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
    "${objs[@]}" "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" "${libs[@]}" -pthread -o "$SRC/$name-standalone"
}

# fuzzUtil and aresfuzzname use wider harnesses from mayhem/harness/ in place of upstream's two-call
# originals (rutil/test/fuzzUtil.cxx, rutil/dns/ares/ares-test-fuzz-name.c), which reach <100 edges.
$CXX $FUZZ_FLAGS -std=c++17 -I. -I"$B" -c mayhem/harness/fuzzUtil.cxx -o "$OBJ/fuzzUtil.o"
$CC $FUZZ_FLAGS -I rutil/dns/ares -I"$B" -c mayhem/harness/ares-test-fuzz-name.c -o "$OBJ/ares-test-fuzz-name.o"

link_harness fuzzUtil "$LIBRUTIL" -- "$OBJ/fuzzUtil.o"
link_harness fuzzStack "$LIBRESIP" "$LIBRUTIL" "$LIBARES" -- \
  $B/resip/stack/test/CMakeFiles/fuzzStack.dir/fuzzStack.cxx.o \
  $B/resip/stack/test/CMakeFiles/fuzzStack.dir/TestSupport.cxx.o
link_harness aresfuzz "$LIBARES" -- $B/rutil/dns/ares/CMakeFiles/aresfuzz.dir/ares-test-fuzz.c.o
link_harness aresfuzzname "$LIBARES" -- "$OBJ/ares-test-fuzz-name.o"
rm -rf "$OBJ"

# 3) The project's own test suite with its NORMAL flags (no sanitizers, no -gdwarf-3, no SanCov).
fresh_if_compiler_changed mayhem/_build-tests
cmake -S . -B mayhem/_build-tests -GNinja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" "${COMMON_OPTS[@]}"
cmake --build mayhem/_build-tests -j"$MAYHEM_JOBS" --target \
  testData testParseBuffer testDnsUtil testXMLCursor testMD5Stream testDigestStream testDataStream \
  testUri testParserCategories testSipMessage testEmbedded testMultipartMixedContents testSipFrag testTuple
