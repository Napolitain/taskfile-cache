#!/usr/bin/env bash
set -euo pipefail

task_bin="${TASK_BIN:-task}"
if ! command -v "$task_bin" >/dev/null 2>&1; then
  if [[ -x "$HOME/go/bin/task" ]]; then
    task_bin="$HOME/go/bin/task"
  else
    echo "task binary not found: $task_bin" >&2
    exit 1
  fi
fi

original="$(mktemp)"
cp main.go "$original"
cleanup() {
  cp "$original" main.go
  rm -f "$original"
}
trap cleanup EXIT

archive_count() {
  find .cache/build -type f -name '*.tar.xz' 2>/dev/null | wc -l | tr -d ' '
}

assert_contains() {
  local output="$1"
  local needle="$2"
  if [[ "$output" != *"$needle"* ]]; then
    echo "expected output to contain: $needle" >&2
    echo "$output" >&2
    exit 1
  fi
}

assert_archive_count() {
  local expected="$1"
  local actual
  actual="$(archive_count)"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected $expected cache archives, found $actual" >&2
    find .cache/build -type f -name '*.tar.xz' 2>/dev/null >&2 || true
    exit 1
  fi
}

rm -rf .task .cache bin

first="$("$task_bin" build 2>&1)"
echo "$first"
assert_contains "$first" "No archive for Task hash"
assert_contains "$first" "Saved generated outputs"
assert_archive_count 1

second="$("$task_bin" build 2>&1)"
echo "$second"
assert_contains "$second" 'Task "build" is up to date'
assert_archive_count 1

perl -0pi -e 's/Hello, World!/Hello from cache test!/' main.go

third="$("$task_bin" build 2>&1)"
echo "$third"
assert_contains "$third" "No archive for Task hash"
assert_archive_count 2

if [[ "$(./bin/helloworld)" != "Hello from cache test!" ]]; then
  echo "modified binary output did not match" >&2
  exit 1
fi

cp "$original" main.go
rm -f bin/helloworld

fourth="$("$task_bin" build 2>&1)"
echo "$fourth"
assert_contains "$fourth" "Restoring generated outputs"
assert_archive_count 2

if [[ "$(./bin/helloworld)" != "Hello, World!" ]]; then
  echo "restored binary output did not match" >&2
  exit 1
fi

fifth="$("$task_bin" build 2>&1)"
echo "$fifth"
assert_contains "$fifth" 'Task "build" is up to date'
