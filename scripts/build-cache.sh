#!/usr/bin/env bash
set -euo pipefail

output="bin/helloworld"
cache_dir=".cache/build"

hash_sources() {
  {
    find . -maxdepth 1 -type f -name 'go.*' -print
    find . -type f -name '*.go' \
      ! -path './.cache/*' \
      ! -path './.task/*' \
      ! -path './bin/*'
  } | LC_ALL=C sort -u | while IFS= read -r file; do
    rel="${file#./}"
    size="$(wc -c < "$file" | tr -d ' ')"
    digest="$(shasum -a 256 "$file" | awk '{print $1}')"

    printf 'path:%s\n' "$rel"
    printf 'size:%s\n' "$size"
    printf 'sha256:%s\n' "$digest"
  done | shasum -a 256 | awk '{print $1}'
}

mkdir -p "$(dirname "$output")" "$cache_dir"

key="$(hash_sources)"
archive="$cache_dir/$key.tar.xz"

if [[ -f "$archive" ]]; then
  echo "Restoring $output from $archive"
  rm -f "$output"
  tar -xJf "$archive"
else
  echo "No archive for source hash $key; building $output"
  go build -o "$output" .

  tmp="$(mktemp "$cache_dir/$key.XXXXXX.tar.xz")"
  trap 'rm -f "$tmp"' EXIT
  tar -cJf "$tmp" "$output"
  mv "$tmp" "$archive"
  trap - EXIT
  echo "Saved $output to $archive"
fi

test -f "$output"
