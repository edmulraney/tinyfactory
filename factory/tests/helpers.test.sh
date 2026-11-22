#!/usr/bin/env bash
# Tests for replace_first in helpers.sh, which builds the descriptions tests give scripts (decisions H22).
. "$(dirname "$0")/helpers.sh"

text='## Why
Users asked for it.

## How it was verified
`pnpm test` passed, and the owner'"'"'s "export" worked.

## Not proven
Nothing'

scenario "swaps a section that spans lines for another, keeping the rest as it was"
replace_first "$text" '## Not proven
Nothing' '## Not proven
The first run.'
[ "$replaced" = '## Why
Users asked for it.

## How it was verified
`pnpm test` passed, and the owner'"'"'s "export" worked.

## Not proven
The first run.' ] || fail "got: $replaced"

scenario "takes backticks, quotes, a star and a bracket as written, in the old text and the new"
replace_first "$text" '`pnpm test` passed, and the owner'"'"'s "export" worked.' '````
* [x] a list item, `quoted`, with a \ and a $HOME
````'
[ "$replaced" = '## Why
Users asked for it.

## How it was verified
````
* [x] a list item, `quoted`, with a \ and a $HOME
````

## Not proven
Nothing' ] || fail "got: $replaced"
replace_first 'a * b [c] d' '* b [c]' '?'
[ "$replaced" = 'a ? d' ] || fail "a star in the old text was read as a pattern: $replaced"

scenario "swaps only the first of two, and removes the text when the new one is empty"
replace_first 'one two one' 'one' 'three'
[ "$replaced" = 'three two one' ] || fail "got: $replaced"
replace_first 'one two one' 'one ' ''
[ "$replaced" = 'two one' ] || fail "got: $replaced"

scenario "fails the scenario when the old text is not there, and leaves the text unchanged"
replace_first "$text" '## Not here' 'anything'
[ "$replaced" = "$text" ] || fail "the text was changed: $replaced"
[[ "$_problems" == "replace_first found nothing to replace: ## Not here"* ]] || fail "the scenario was not failed"
# That failure was the point of this scenario, so it is taken back; any other stays.
_problems=${_problems#"replace_first found nothing to replace: ## Not here"$'\n'}
