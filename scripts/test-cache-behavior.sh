#!/usr/bin/env bash
set -euo pipefail

task_bin="${TASK_BIN:-task}"
if ! command -v "$task_bin" >/dev/null 2>&1; then
  if [[ -x "$HOME/go/bin/task" ]]; then
    echo "Using fallback task binary: $HOME/go/bin/task"
    task_bin="$HOME/go/bin/task"
  else
    echo "task binary not found: $task_bin" >&2
    exit 1
  fi
fi

step() {
  printf '\n==> %s\n' "$1"
}

print_command() {
  printf '+'
  local arg
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run() {
  print_command "$@"
  "$@"
}

show_command() {
  print_command "$@"
}

original="$(mktemp)"
run cp main.go "$original"
cleanup() {
  echo "Restoring original main.go"
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

step "Start from a clean local cache and generated-output state"
run rm -rf .task .cache bin

step "Run first build; expect a cache miss and new archive"
show_command "$task_bin" build
first="$("$task_bin" build 2>&1)"
echo "$first"
assert_contains "$first" "No archive for Task hash"
assert_contains "$first" "Saved generated outputs"
assert_archive_count 1

step "Run second build; expect Task native up-to-date cache"
show_command "$task_bin" build
second="$("$task_bin" build 2>&1)"
echo "$second"
assert_contains "$second" 'Task "build" is up to date'
assert_archive_count 1

step "Change source to force a new Task checksum"
run perl -0pi -e 's/Hello, World!/Hello from cache test!/' main.go

step "Run third build; expect a second cache miss and second archive"
show_command "$task_bin" build
third="$("$task_bin" build 2>&1)"
echo "$third"
assert_contains "$third" "No archive for Task hash"
assert_archive_count 2

step "Verify modified binary output"
show_command ./bin/helloworld
modified_output="$(./bin/helloworld)"
echo "$modified_output"
if [[ "$modified_output" != "Hello from cache test!" ]]; then
  echo "modified binary output did not match" >&2
  exit 1
fi

step "Restore original source and remove generated binary"
run cp "$original" main.go
run rm -f bin/helloworld

step "Run fourth build; expect restore from previous archive"
show_command "$task_bin" build
fourth="$("$task_bin" build 2>&1)"
echo "$fourth"
assert_contains "$fourth" "Restoring generated outputs"
assert_archive_count 2

step "Verify restored binary output"
show_command ./bin/helloworld
restored_output="$(./bin/helloworld)"
echo "$restored_output"
if [[ "$restored_output" != "Hello, World!" ]]; then
  echo "restored binary output did not match" >&2
  exit 1
fi

step "Run final build; expect Task native up-to-date cache again"
show_command "$task_bin" build
fifth="$("$task_bin" build 2>&1)"
echo "$fifth"
assert_contains "$fifth" 'Task "build" is up to date'

step "Cache behavior test completed successfully"
