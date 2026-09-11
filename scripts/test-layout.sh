#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/threadsnospoiler-tests.XXXXXX)
c++ -std=c++14 -Wall -Wextra -Werror tests/row_geometry_test.cpp -o "$test_dir/row_geometry_test"
"$test_dir/row_geometry_test"
