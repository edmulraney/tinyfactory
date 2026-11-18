#!/usr/bin/env bash
# Tests for .claude/skills/bootstrap/scripts/board.sh: the board's columns, its views and the check on its automations.
. "$(dirname "$0")/helpers.sh"

board="$root/.claude/skills/bootstrap/scripts/board.sh"
# The template board these scenarios name; the scenario with no template unsets both.
export FACTORY_BOARD_TEMPLATE_OWNER=template-owner FACTORY_BOARD_TEMPLATE_NUMBER=7

# The board is #4, described by $T/board.json; the token holds only `project`; $T/fail holds a word of the call to fail.
# The template is seen unless $T/template-hidden exists.
github_holds() {
  cat > "$T/board.json" <<'JSON'
{
  "id": "PVT_1",
  "field": {"id": "FIELD_status", "options": [
    {"id": "opt_a", "name": "Backlog"}, {"id": "opt_b", "name": "In progress"}, {"id": "opt_c", "name": "Deployed"}]},
  "labels": {"id": "FIELD_labels"},
  "views": {"nodes": [
    {"id": "VIEW_board", "name": "Board", "layout": "BOARD_LAYOUT", "filter": null,
     "configuration": {"visibleFields": {"nodes": [{"id": "FIELD_title", "name": "Title"}, {"id": "FIELD_labels", "name": "Labels"}]}}},
    {"id": "VIEW_needs", "name": "Needs you", "layout": "TABLE_LAYOUT", "filter": "label:needs-human is:open",
     "configuration": {"visibleFields": {"nodes": []}}},
    {"id": "VIEW_proposals", "name": "Proposals", "layout": "TABLE_LAYOUT", "filter": "label:proposal is:open",
     "configuration": {"visibleFields": {"nodes": []}}},
    {"id": "VIEW_proofs", "name": "Proofs", "layout": "TABLE_LAYOUT", "filter": "label:proof is:open",
     "configuration": {"visibleFields": {"nodes": []}}}]},
  "workflows": {"nodes": [
    {"name": "Auto-add to project", "enabled": true}, {"name": "Item added to project", "enabled": true},
    {"name": "Pull request linked to issue", "enabled": true}, {"name": "Item closed", "enabled": true},
    {"name": "Item reopened", "enabled": true}]}
}
JSON
  echo '[{"title":"myapp","number":4,"closed":false}]' > "$T/projects.json"
  echo none > "$T/fail"
  stub open 'exit 0'
  stub xdg-open 'exit 0'
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api user "*) json "{\"login\":\"owner\"}" "$@" ;;
      "repo view "*) [ -f "$T/sees-repo" ] ;;
      "project link "*) [ -f "$T/sees-repo" ] || { echo "error: your authentication token is missing required scopes [read:org read:discussion]" >&2; exit 1; } ;;
      "project "*) echo "error: your authentication token is missing required scopes [read:org read:discussion]" >&2; exit 1 ;;
      *"projectsV2(first"*) json "{\"data\":{\"user\":{\"id\":\"U_owner\",\"projectsV2\":{\"nodes\":$(cat "$T/projects.json")}}}}" "$@" ;;
      *"template: projectV2("*)
        [ ! -f "$T/template-hidden" ] || { echo "gh: Could not resolve to a ProjectV2 with the number 7." >&2; exit 1; }
        json "{\"data\":{\"user\":{\"template\":{\"id\":\"PVT_template\"}}}}" "$@" ;;
      *"copyProjectV2("*) json "{\"data\":{\"copyProjectV2\":{\"projectV2\":{\"number\":9}}}}" "$@" ;;
      *"createProjectV2("*) json "{\"data\":{\"createProjectV2\":{\"projectV2\":{\"number\":9}}}}" "$@" ;;
      *"repositories(first"*) json "{\"data\":{\"user\":{\"projectV2\":{\"repositories\":{\"nodes\":$(cat "$T/linked.json")}}}}}" "$@" ;;
      *"workflows(first"*) json "{\"data\":{\"user\":{\"projectV2\":$(cat "$T/board.json")}}}" "$@" ;;
      *updateProjectV2Field*) json "{\"data\":{\"updateProjectV2Field\":{\"projectV2Field\":{\"options\":[{\"name\":\"set\"}]}}}}" "$@" ;;
      *createProjectV2View*) json "{\"data\":{\"createProjectV2View\":{\"projectV2View\":{\"id\":\"VIEW_new\",\"filter\":null}}}}" "$@" ;;
      *updateProjectV2View*) exit 0 ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# change '<jq>': changes the board GitHub holds.
change() { jq "$1" "$T/board.json" > "$T/board.tmp" && mv "$T/board.tmp" "$T/board.json"; }

scenario "changes nothing on a board that is already set up, and says where it is"
github_holds
run "$board" myapp
expect_status 0
expect_output "board #4 already exists"
expect_output "columns already set"
expect_output "first view is already a board"
expect_output "board cards already show their labels"
expect_output '"Needs you" view is already set'
expect_output '"Proposals" view is already set'
expect_output '"Proofs" view is already set'
expect_output "all five automations are on"
expect_output "board ok: https://github.com/users/owner/projects/4"
expect_no_call "mutation"
expect_no_call "template: projectV2("
# Decisions U222.
expect_no_call "gh project "

scenario "renames In review to In progress with its id unchanged, and keeps the other columns' ids"
github_holds
change '.field.options[1].name = "In review"'
run "$board" myapp
expect_status 0
expect_call 'singleSelectOptions: [{id: "opt_a", name: "Backlog", color: GRAY, description: ""}, {id: "opt_b", name: "In progress", color: GRAY, description: ""}, {id: "opt_c", name: "Deployed", color: GRAY, description: ""}]'
expect_call "field=FIELD_status"

scenario "sends a column the board never had without an id, and the ones it has with theirs"
github_holds
change '.field.options |= [.[0], .[2]]'
run "$board" myapp
expect_status 0
expect_call 'singleSelectOptions: [{id: "opt_a", name: "Backlog", color: GRAY, description: ""}, {name: "In progress", color: GRAY, description: ""}, {id: "opt_c", name: "Deployed", color: GRAY, description: ""}]'

scenario "renames a new board's own three columns in place"
github_holds
change '.field.options = [{"id":"n1","name":"Todo"},{"id":"n2","name":"In Progress"},{"id":"n3","name":"Done"}]'
run "$board" myapp
expect_status 0
expect_call '[{id: "n1", name: "Backlog", color: GRAY, description: ""}, {id: "n2", name: "In progress", color: GRAY, description: ""}, {id: "n3", name: "Deployed", color: GRAY, description: ""}]'

scenario "adds Labels to the fields the Board view shows, after the ones it already shows"
github_holds
change '.views.nodes[0].configuration.visibleFields.nodes = [{"id":"FIELD_title","name":"Title"},{"id":"FIELD_assignees","name":"Assignees"}]'
run "$board" myapp
expect_status 0
expect_call 'view=VIEW_board'
expect_call 'updateProjectV2View(input: {viewId: $view, configuration: {visibleFieldIds: ["FIELD_title", "FIELD_assignees", "FIELD_labels"]}})'
expect_output "board cards now show: Title, Assignees, Labels"

scenario "stops when the board has no Labels field to show"
github_holds
change '.labels = null'
run "$board" myapp
expect_failure
expect_output "the board has no Labels field"
expect_no_output "board ok"

scenario "makes a table of a new project's first view into a board"
github_holds
change '.views.nodes[0].layout = "TABLE_LAYOUT"'
run "$board" myapp
expect_status 0
expect_call 'updateProjectV2View(input: {viewId: $view, name: "Board", layout: BOARD_LAYOUT})'
expect_output "first view set to board layout"

scenario "creates the Needs you view and filters it to open needs-human tickets"
github_holds
change '.views.nodes |= map(select(.name != "Needs you"))'
run "$board" myapp
expect_status 0
expect_call 'project=PVT_1 -f name=Needs you -f query='
expect_call 'createProjectV2View(input: {projectId: $project, name: $name, layout: TABLE_LAYOUT})'
expect_call "view=VIEW_new -f filter=label:needs-human is:open"
expect_no_call "name=Proposals"
expect_no_call "name=Proofs"

scenario "creates the Proposals and Proofs views on a board that has neither, each filtered to its label"
github_holds
change '.views.nodes |= .[0:2]'
run "$board" myapp
expect_status 0
expect_call 'project=PVT_1 -f name=Proposals -f query='
expect_call 'project=PVT_1 -f name=Proofs -f query='
expect_call "view=VIEW_new -f filter=label:proposal is:open"
expect_call "view=VIEW_new -f filter=label:proof is:open"
expect_output 'created the "Proposals" view'
expect_output '"Proofs" view filtered to: label:proof is:open'
expect_no_call "name=Needs you"
expect_no_call "filter=label:needs-human"

scenario "sets the filter of a view that has the wrong one, and makes no second view of that name"
github_holds
change '.views.nodes[2].filter = "label:proposal"'
run "$board" myapp
expect_status 0
expect_call "view=VIEW_proposals -f filter=label:proposal is:open"
expect_no_call "createProjectV2View"

scenario "stops when GitHub refuses a new view, and does not say the board is set up"
github_holds
change '.views.nodes |= .[0:3]'
echo createProjectV2View > "$T/fail"
run "$board" myapp
expect_failure
expect_no_output 'created the "Proofs" view'
expect_no_output "board ok"

scenario "stops when GitHub refuses a view's filter"
github_holds
change '.views.nodes[3].filter = null'
echo "filter=label:proof" > "$T/fail"
run "$board" myapp
expect_failure
expect_no_output '"Proofs" view filtered to'
expect_no_output "board ok"

scenario "creates the board as a copy of the template when the account has none of that name"
github_holds
echo '[{"title":"another","number":2,"closed":false}]' > "$T/projects.json"
run "$board" myapp
expect_status 0
expect_call "owner=template-owner -F number=7 -f query="
expect_call "project=PVT_template -f account=U_owner -f title=myapp -f query="
expect_call "copyProjectV2(input: {projectId: \$project, ownerId: \$account, title: \$title})"
expect_no_call "createProjectV2("
expect_output "created board #9, a copy of template-owner's board #7"
expect_output "board ok: https://github.com/users/owner/projects/9"
expect_no_call "gh project "

scenario "prints one click, auto-add with the repository it names, on a board just copied"
github_holds
echo '[]' > "$T/projects.json"
change '.workflows.nodes |= map(select(.name != "Auto-add to project"))'
run "$board" myapp
expect_status 0
expect_output "select   Auto-add to project"
expect_output "set      Filters: the repository owner/myapp"
[ "$(grep -c '^   select ' <<<"$out")" = 1 ] || fail "expected one click, got: $(grep '^   select ' <<<"$out")"

scenario "creates the board when the only one of that name is closed"
github_holds
echo '[{"title":"myapp","number":3,"closed":true}]' > "$T/projects.json"
run "$board" myapp
expect_status 0
expect_output "created board #9"

scenario "creates the board from nothing when this login cannot see the template"
github_holds
echo '[]' > "$T/projects.json"
touch "$T/template-hidden"
run "$board" myapp
expect_status 0
expect_output "this login cannot see the template board"
expect_call "account=U_owner -f title=myapp -f query="
expect_call "createProjectV2(input: {ownerId: \$account, title: \$title})"
expect_no_call "copyProjectV2("
expect_output "created board #9"
expect_no_output "a copy of"
expect_output "board ok: https://github.com/users/owner/projects/9"

scenario "creates the board from nothing when no template is named"
github_holds
echo '[]' > "$T/projects.json"
run env -u FACTORY_BOARD_TEMPLATE_OWNER -u FACTORY_BOARD_TEMPLATE_NUMBER "$board" myapp
expect_status 0
expect_output "no template board is named, so the board is built from nothing"
expect_no_call "template: projectV2("
expect_call "createProjectV2(input: {ownerId: \$account, title: \$title})"
expect_no_call "copyProjectV2("

scenario "stops when the template cannot be read for another reason, and creates no board"
github_holds
echo '[]' > "$T/projects.json"
echo "template: projectV2(" > "$T/fail"
run "$board" myapp
expect_failure
expect_output "could not connect"
expect_no_call "createProjectV2("
expect_no_call "copyProjectV2("
expect_no_output "board ok"

scenario "stops when GitHub refuses the copy, and creates no board from nothing"
github_holds
echo '[]' > "$T/projects.json"
echo "copyProjectV2(" > "$T/fail"
run "$board" myapp
expect_failure
expect_no_call "createProjectV2("
expect_no_output "created board"
expect_no_output "board ok"

scenario "stops when GitHub refuses to create the board from nothing"
github_holds
echo '[]' > "$T/projects.json"
touch "$T/template-hidden"
echo "createProjectV2(" > "$T/fail"
run "$board" myapp
expect_failure
expect_no_output "created board"
expect_no_output "board ok"

scenario "links the board to the repo when this login can see it and it is not linked"
github_holds
touch "$T/sees-repo"; echo '[]' > "$T/linked.json"
run "$board" myapp
expect_status 0
expect_call "gh project link 4 --owner owner --repo owner/myapp"

scenario "leaves a board that is already linked to the repo linked"
github_holds
touch "$T/sees-repo"; echo '[{"nameWithOwner":"owner/myapp"}]' > "$T/linked.json"
run "$board" myapp
expect_status 0
expect_output "board already linked to owner/myapp"
expect_no_call "gh project link"

scenario "prints the clicks for an automation that is off, with the column it moves a card to"
github_holds
change '.workflows.nodes[2].enabled = false'
run "$board" myapp
expect_status 0
expect_output "select   Pull request linked to issue"
expect_output "set      Set value: Status → In progress"
expect_output "open     https://github.com/users/owner/projects/4/workflows"
expect_no_output "select   Item closed"
expect_no_output "all five automations are on"

scenario "stops when the board cannot be read, and changes nothing"
github_holds
echo "workflows(first" > "$T/fail"
run "$board" myapp
expect_failure
expect_no_call "mutation"
expect_no_output "board ok"

scenario "stops when the boards cannot be listed, and creates none"
github_holds
echo "projectsV2(first" > "$T/fail"
run "$board" myapp
expect_failure
expect_no_call "createProjectV2("
expect_no_output "board ok"

scenario "stops when GitHub refuses the columns"
github_holds
change '.field.options[1].name = "In review"'
echo updateProjectV2Field > "$T/fail"
run "$board" myapp
expect_failure
expect_no_output "columns set"
expect_no_output "board ok"

scenario "stops when GitHub refuses the Board view's fields"
github_holds
change '.views.nodes[0].configuration.visibleFields.nodes = []'
echo visibleFieldIds > "$T/fail"
run "$board" myapp
expect_failure
expect_no_output "board cards now show"
expect_no_output "board ok"

scenario "asks for the automation that moves a reopened ticket's card out of Deployed"
github_holds
change '.workflows.nodes |= map(select(.name != "Item reopened"))'
run "$board" myapp
expect_status 0
expect_output "select   Item reopened"
expect_output "set      Set value: Status → Backlog"
expect_no_output "all five automations are on"
