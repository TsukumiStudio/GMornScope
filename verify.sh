#!/bin/sh
# Minimal disposable fixture, not a general-purpose test runner.
set -eu
scope_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
godot_bin=${GODOT_BIN:-godot}
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT HUP INT TERM
mkdir -p "$fixture_dir/addons/renamed_scope"
cp "$scope_dir/gmorn_scope.gd" "$scope_dir/verify.gd" "$fixture_dir/addons/renamed_scope/"
printf 'config_version=5\n[application]\nconfig/name="GMornScope verification fixture"\n' > "$fixture_dir/project.godot"
result=0
"$godot_bin" --headless --audio-driver Dummy --path "$fixture_dir" \
  --quit-after 300 --script res://addons/renamed_scope/verify.gd -- "$@" \
  > "$fixture_dir/verify.log" 2>&1 || result=$?
cat "$fixture_dir/verify.log"
if [ "$result" -ne 0 ]; then exit "$result"; fi
# Godot can exit zero after a parse error; require a completed positive summary.
if grep -E 'SCRIPT ERROR:|ERROR:|WARNING:' "$fixture_dir/verify.log" >/dev/null; then exit 1; fi
if ! grep -E '^GMORN_SCOPE_VERIFY_JSON .*"status"[[:space:]]*:[[:space:]]*"pass"' "$fixture_dir/verify.log" >/dev/null; then exit 1; fi
