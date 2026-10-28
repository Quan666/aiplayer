#!/usr/bin/env bash
set -euo pipefail
media_project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
media_test_directory="$(mktemp -d)"
trap 'rm -rf -- "$media_test_directory"' EXIT
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pthread \
  "$media_project_root/client/windows/host_test/media_controls_queue_check.cc" \
  -o "$media_test_directory/media-controls-queue-check"
"$media_test_directory/media-controls-queue-check"
