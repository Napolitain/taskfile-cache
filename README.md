# Taskfile Packaging Cache Flow

This repository demonstrates a small persistent cache layer around a Task build.
Task still owns source checksums and up-to-date decisions. The `task-cache`
helper only handles the generated files that Task declares for the build.

## Prerequisites

- Go
- Task (`task` on `PATH`, or `TASK_BIN=/path/to/task`)

## Main Commands

```sh
task build
```

Builds `bin/helloworld` through the cache helper.

```sh
scripts/test-cache-behavior.sh
```

Runs the full expected behavior flow and asserts each cache state.

## Taskfile Flow

The `build` task declares:

- sources: `go.*` and `*.go`
- generated output: `bin/helloworld`
- command: `bin/task-cache --task build -- go build -o bin/helloworld .`

The `build` task depends on the internal `task-cache` task, so Task first builds
the helper binary at `bin/task-cache`.

When `task build` runs:

1. Task calculates its native checksum for the `build` task.
2. Task writes that checksum under `.task/checksum/build`.
3. Task runs `bin/task-cache --task build -- go build -o bin/helloworld .`.
4. The helper reads `Taskfile.yml` and discovers the `build.generates` entries.
5. The helper reads `.task/checksum/build` and uses it as the persistent archive key.
6. The helper looks for `.cache/build/<task-checksum>.tar.xz`.

If the archive exists, the helper restores the generated outputs from the
archive and verifies that every declared generated file exists.

If the archive does not exist, the helper runs the build command after `--`,
verifies the generated files, and saves them into
`.cache/build/<task-checksum>.tar.xz`.

## Restore Behavior

Archives store the generated path exactly as Task declares it. For the current
build task, the archive entry is:

```text
bin/helloworld
```

On restore, the helper extracts into the repository root, recreates parent
directories when needed, and writes the file back to the same relative path:

```text
bin/helloworld
```

There is no separate staging output directory. The restored file appears where a
normal build would have created it.

## Test Script Flow

`scripts/test-cache-behavior.sh` is the executable description of the expected
cache behavior.

It does the following:

1. Resolves the Task binary from `TASK_BIN`, `task`, or `$HOME/go/bin/task`.
2. Copies `main.go` to a temporary file and restores it on exit.
3. Removes `.task`, `.cache`, and `bin` to start from a clean local state.
4. Runs the first build and expects:
   - no matching archive for the current Task checksum
   - the Go build command to run
   - one new `.cache/build/*.tar.xz` archive
5. Runs the second build and expects Task's native up-to-date behavior:
   - `Task "build" is up to date`
   - still only one archive
6. Changes `main.go` from `Hello, World!` to `Hello from cache test!`.
7. Runs the third build and expects:
   - a new Task checksum
   - no matching archive for that checksum
   - a second archive
8. Runs `./bin/helloworld` and verifies the modified output.
9. Restores the original `main.go` and removes `bin/helloworld`.
10. Runs the fourth build and expects:
    - the original Task checksum to match the first archive
    - generated outputs to be restored from `.cache/build/<checksum>.tar.xz`
    - no build command needed for `bin/helloworld`
11. Runs `./bin/helloworld` and verifies the restored `Hello, World!` output.
12. Runs one final build and expects Task's native up-to-date behavior again.

The important scenario is step 10: the source returns to a previously seen
checksum while the generated binary is missing locally. The helper restores the
binary from the persistent archive into the normal generated output path.

## Local State

The flow uses three local directories:

- `.task/checksum/build`: Task's native checksum state
- `.cache/build/`: persistent `tar.xz` archives keyed by Task checksum
- `bin/`: generated helper and application binaries

These are build artifacts and can be removed to reset the local cache behavior.
