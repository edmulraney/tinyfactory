#!/usr/bin/env bash
# Says what in a review's verdict is over a limit: a field's words, or its assumptions (decisions A169b, A224a).
# Usage: OUTPUT='<json>' long-fields.sh
set -uo pipefail

# Never fails: that a result is no verdict is for post-verdict.sh to say.
# Only the schema's fields are read: another key's name would go as written into a comment and $GITHUB_OUTPUT.
jq -r --argjson max_words 40 '
  def long(name; fields): arrays | to_entries[] | (.key + 1) as $n | .value | objects
    | . as $item | fields | . as $field | $item[$field] | strings
    | ([scan("\\S+")] | length) as $words
    | select($words > $max_words) | "\(name) \($n)'"'"'s `\($field)` is \($words) words";
  objects | [(.findings | long("finding"; "file", "problem", "fix")),
    (.assumptions | long("assumption"; "assumes", "if_wrong")),
    (.assumptions | arrays | length | select(. > 3) | "it gives \(.) assumptions, and 3 is the most")] | join("; ")' \
  <<<"${OUTPUT:-}" 2>/dev/null || true
