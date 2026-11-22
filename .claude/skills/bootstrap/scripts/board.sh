#!/usr/bin/env bash
# Creates the project's kanban board, links it to the repo, sets its columns and views, and checks its automations.
# Usage: board.sh [name]   (name defaults to the directory name)
#        FACTORY_BOARD_TEMPLATE_OWNER and FACTORY_BOARD_TEMPLATE_NUMBER name a board to copy, such as one whose
#        automations are already on. With neither set, the board is built from nothing (decisions S283a).
#        Safe to re-run. Runs at setup with the owner's gh login, which needs the account-wide `project` permission,
#        and from apply-setup.sh with BOARD_TOKEN, which can see no repo: nothing but the link may need repo access.
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
# Only columns an automation can fill (decisions T5). GitHub's automations cannot react to a
# label, so nothing could move a card into a "Needs human" column; the "Needs you" view below
# shows what is stuck or waiting for approval.
columns='["Backlog","In progress","Deployed"]'
# A column that had another name keeps its id under the new one (decisions T6).
renamed='{"In progress":"In review"}'
# A new board is a copy of the template board these two name, when both are set (decisions S283a).
template_owner="${FACTORY_BOARD_TEMPLATE_OWNER:-}"
template_number="${FACTORY_BOARD_TEMPLATE_NUMBER:-}"

# Through the API, not `gh project`, which a token with only `project` is refused (decisions U222).
account=$(gh api graphql --paginate -f owner="$owner" -f query='
  query($owner: String!, $endCursor: String) {
    user(login: $owner) { id projectsV2(first: 100, after: $endCursor) {
      nodes { number title closed }
      pageInfo { hasNextPage endCursor }
    } }
  }' --jq '.data.user')
number=$(jq -rs --arg name "$name" \
  '[.[].projectsV2.nodes[] | select(.title == $name and (.closed | not)) | .number] | first // ""' <<<"$account")
if [ -z "$number" ]; then
  template=""
  if [ -n "$template_owner" ] && [ -n "$template_number" ]; then
    # Only an answer that the template is hidden builds from nothing; any other failure stops (decisions S283b).
    template=$(gh api graphql -f owner="$template_owner" -F number="$template_number" -f query='
      query($owner: String!, $number: Int!) {
        user(login: $owner) { template: projectV2(number: $number) { id } }
      }' --jq '.data.user.template.id' 2>&1) || {
      grep -qF "Could not resolve" <<<"$template" || { echo "$template" >&2; exit 1; }
      template=""
    }
  fi
  if [ -n "$template" ]; then
    number=$(gh api graphql -f project="$template" -f account="$(jq -rs '.[0].id' <<<"$account")" -f title="$name" -f query='
      mutation($project: ID!, $account: ID!, $title: String!) {
        copyProjectV2(input: {projectId: $project, ownerId: $account, title: $title}) { projectV2 { number } }
      }' --jq '.data.copyProjectV2.projectV2.number')
    echo "created board #$number, a copy of $template_owner's board #$template_number"
  else
    if [ -n "$template_owner" ] && [ -n "$template_number" ]; then
      echo "this login cannot see the template board, $template_owner's #$template_number, so the board is built from nothing"
    else
      echo "no template board is named, so the board is built from nothing"
    fi
    number=$(gh api graphql -f account="$(jq -rs '.[0].id' <<<"$account")" -f title="$name" -f query='
      mutation($account: ID!, $title: String!) {
        createProjectV2(input: {ownerId: $account, title: $title}) { projectV2 { number } }
      }' --jq '.data.createProjectV2.projectV2.number')
    echo "created board #$number"
  fi
else
  echo "board #$number already exists, skipping create"
fi
url="https://github.com/users/$owner/projects/$number"

# Linking is the one step that needs repo access, so it is skipped when there is nothing to do
# or no way to do it. The factory's board token cannot see a private repo at all; the link it
# would make was made at setup, with the owner's login.
if ! gh repo view "$owner/$name" >/dev/null 2>&1; then
  echo "this login cannot see $owner/$name, so the board's link to it is left as setup made it"
elif gh api graphql -f owner="$owner" -F number="$number" -f query='
  query($owner: String!, $number: Int!) {
    user(login: $owner) { projectV2(number: $number) { repositories(first: 100) { nodes { nameWithOwner } } } }
  }' --jq '.data.user.projectV2.repositories.nodes[].nameWithOwner' | grep -qxF "$owner/$name"; then
  echo "board already linked to $owner/$name"
else
  gh project link "$number" --owner "$owner" --repo "$owner/$name" >/dev/null
  echo "board linked to $owner/$name"
fi

board=$(gh api graphql -f owner="$owner" -F number="$number" -f query='
  query($owner: String!, $number: Int!) {
    user(login: $owner) { projectV2(number: $number) {
      id
      field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
      labels: field(name: "Labels") { ... on ProjectV2FieldCommon { id } }
      views(first: 20) { nodes { id name layout filter configuration { visibleFields(first: 50) { nodes { ... on ProjectV2FieldCommon { id name } } } } } }
      workflows(first: 50) { nodes { name enabled } }
    } }
  }' --jq '.data.user.projectV2')

# Columns. Each option that stays is sent with its id: an option sent without one is a new
# option, and replacing an option clears the status of its cards and resets every automation
# that pointed at it (that broke the automations once). A new board's own three columns are
# renamed in place for the same reason: its "Item closed" automation already points at the last.
# A column is found by its name, or else by the name it had before.
options=$(jq -c --argjson want "$columns" --argjson renamed "$renamed" '
  .field.options as $have
  | if ($have | map(.name)) == ["Todo", "In Progress", "Done"]
    then [range(0; 3) | {id: $have[.].id, name: $want[.]}]
    else $want | map(. as $n | {name: $n}
      + (([$have[] | select(.name == $n)] + [$have[] | select(.name == $renamed[$n])] | first // empty | {id}) // {}))
    end' <<<"$board")
if [ "$(jq -c '.field.options | map(.name)' <<<"$board")" != "$columns" ]; then
  # GraphQL input, not JSON: keys unquoted, the colour an enum.
  input=$(jq -r 'map("{" + (if .id then "id: \(.id | tojson), " else "" end)
    + "name: \(.name | tojson), color: GRAY, description: \"\"}") | join(", ")' <<<"$options")
  gh api graphql -f field="$(jq -r .field.id <<<"$board")" -f query="
    mutation(\$field: ID!) {
      updateProjectV2Field(input: {fieldId: \$field, singleSelectOptions: [$input]}) {
        projectV2Field { ... on ProjectV2SingleSelectField { options { name } } }
      }
    }" --jq '.data.updateProjectV2Field.projectV2Field.options | "columns set: " + (map(.name) | join(" → "))'
else
  echo "columns already set"
fi

first=$(jq -c '.views.nodes[0]' <<<"$board")
if [ "$(jq -r .layout <<<"$first")" != BOARD_LAYOUT ]; then
  gh api graphql -f view="$(jq -r .id <<<"$first")" -f query='
    mutation($view: ID!) {
      updateProjectV2View(input: {viewId: $view, name: "Board", layout: BOARD_LAYOUT}) { projectV2View { layout } }
    }' >/dev/null
  echo "first view set to board layout"
else
  echo "first view is already a board"
fi

# The cards show their labels, so `needs-human` and `deployed` are seen without opening one. The
# view's fields are set as a whole list, so the ones it already shows are sent back with Labels.
shown=$(jq -c '[.views.nodes[0].configuration.visibleFields.nodes[] | select(.id)]' <<<"$board")
labels=$(jq -r '.labels.id // ""' <<<"$board")
if [ -z "$labels" ]; then
  echo "the board has no Labels field, so its cards cannot show labels" >&2
  exit 1
elif jq -e --arg id "$labels" 'map(.id) | index($id) == null' <<<"$shown" >/dev/null; then
  ids=$(jq -r --arg id "$labels" 'map(.id) + [$id] | map(tojson) | join(", ")' <<<"$shown")
  gh api graphql -f view="$(jq -r .id <<<"$first")" -f query="
    mutation(\$view: ID!) {
      updateProjectV2View(input: {viewId: \$view, configuration: {visibleFieldIds: [$ids]}}) { projectV2View { id } }
    }" >/dev/null
  echo "board cards now show: $(jq -r --arg id "$labels" '[.[].name] + ["Labels"] | join(", ")' <<<"$shown")"
else
  echo "board cards already show their labels"
fi

# Three more views, each a list of open tickets with one label: what is stuck or waiting for
# approval (the one thing the columns cannot show), what the factory suggests changing, and what
# is left to confirm once a merged change has run (decisions T5, T85f). Tables, because each is a
# list to work through, not stages to move between.
while IFS='|' read -r view filter; do
  found=$(jq -c --arg name "$view" '.views.nodes[] | select(.name == $name)' <<<"$board" | head -1)
  if [ -z "$found" ]; then
    found=$(gh api graphql -f project="$(jq -r .id <<<"$board")" -f name="$view" -f query='
      mutation($project: ID!, $name: String!) {
        createProjectV2View(input: {projectId: $project, name: $name, layout: TABLE_LAYOUT}) { projectV2View { id filter } }
      }' --jq '.data.createProjectV2View.projectV2View')
    echo "created the \"$view\" view"
  fi
  if [ "$(jq -r '.filter // ""' <<<"$found")" != "$filter" ]; then
    # The filter is set by an update because the create mutation does not take one.
    gh api graphql -f view="$(jq -r .id <<<"$found")" -f filter="$filter" -f query='
      mutation($view: ID!, $filter: String!) {
        updateProjectV2View(input: {viewId: $view, filter: $filter}) { projectV2View { filter } }
      }' >/dev/null
    echo "\"$view\" view filtered to: $filter"
  else
    echo "\"$view\" view is already set"
  fi
done <<'LIST'
Needs you|label:needs-human is:open
Proposals|label:proposal is:open
Proofs|label:proof is:open
LIST

# GitHub's own automations add the tickets and move them, and no workflow moves a card (decisions T4).
# GitHub's API can read whether each is on
# but cannot switch one on or say what it is set to, so this is a step left for the human; the
# script prints the clicks and confirms on its next run. A copied board lacks only the first.
# GitHub fills in the first one's filter with a text that leaves most tickets out (decisions S563q).
off=""
while IFS='|' read -r workflow setting; do
  if [ "$(jq -r --arg n "$workflow" '[.workflows.nodes[] | select(.name == $n) | .enabled] | any' <<<"$board")" != true ]; then
    off+="   select   $workflow"$'\n'"   set      $setting"$'\n'"   click    Save and turn on workflow"$'\n'
  fi
done <<LIST
Auto-add to project|Filters: the repository $owner/$name, and the text is:issue is:open
Item added to project|Set value: Status → Backlog
Pull request linked to issue|Set value: Status → In progress
Item closed|Set value: Status → Deployed
Item reopened|Set value: Status → Backlog
LIST

if [ -z "$off" ]; then
  echo "all five automations are on"
  mark done "board ok: $url"
else
  off=${off%$'\n'}
  owner_block <<NOTE
Switch on the board's automations in the browser: GitHub's API cannot.
$url/workflows
$off
They are what put each ticket on the board and move it; without them the board stays empty.
NOTE
  (open "$url/workflows" || xdg-open "$url/workflows") >/dev/null 2>&1 || true
  mark needs-owner "board: its automations are left for you to switch on at $url/workflows"
fi
