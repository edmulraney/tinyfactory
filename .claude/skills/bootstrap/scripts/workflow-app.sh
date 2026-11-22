#!/usr/bin/env bash
# Creates a GitHub App that can write this repo's files, workflows included, installs it here only and stores its key.
# Usage: workflow-app.sh [name]   (name defaults to the directory name; run after github.sh)
#        Stores the secret WORKFLOW_APP_PRIVATE_KEY and the variables WORKFLOW_APP_CLIENT_ID and WORKFLOW_APP_SLUG.
#        Safe to re-run: skips making an app when all three exist, and still checks the ruleset's bypass list.
#        FORCE=1 makes a new app; delete the old one at https://github.com/settings/apps.
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
repo="$owner/$name"
api="https://api.github.com"

# pass_ruleset <slug>: puts the app on the bypass list of the ruleset on main, when there is one.
# Where GitHub locks main with the ruleset github.sh sets, it would refuse the installer's push (decisions S385c).
pass_ruleset() {
  local rulesets id app ruleset
  if ! rulesets=$(gh api "repos/$repo/rulesets" 2>&1); then
    # GitHub answers 403 where the plan has no rulesets, so main has none (free-tier entry 7).
    grep -q 'HTTP 403' <<<"$rulesets" && return 0
    echo "cannot read the rulesets of $repo, so the app may be refused on main; re-run: $rulesets"; exit 1
  fi
  id=$(jq -r '[.[] | select(.name == "main is merge-only")][0].id // empty' <<<"$rulesets")
  [ -n "$id" ] || return 0
  app=$(gh api "apps/$1" --jq .id) || { echo "cannot read the id of the app '$1'; re-run"; exit 1; }
  ruleset=$(gh api "repos/$repo/rulesets/$id") || { echo "cannot read the ruleset on main of $repo; re-run"; exit 1; }
  if jq -e --argjson app "$app" 'any(.bypass_actors[]?; .actor_type == "Integration" and .actor_id == $app)' <<<"$ruleset" >/dev/null; then
    return 0
  fi
  jq --argjson app "$app" '{bypass_actors: ((.bypass_actors // []) + [{actor_id: $app, actor_type: "Integration", bypass_mode: "always"}])}' <<<"$ruleset" \
    | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null \
    || { echo "cannot put the app '$1' on the bypass list of the ruleset on main of $repo, so its push would be refused; re-run"; exit 1; }
  echo "the ruleset on main lets '$1' push: the installer's commit is not refused"
}

# Read on their own lines so that a login that cannot read them stops here, before an app is made.
secrets=$(gh secret list -R "$repo" --json name --jq '.[].name') \
  || { echo "cannot read the secrets of $repo: sign in to gh as an admin of the repo and re-run"; exit 1; }
variables=$(gh variable list -R "$repo" --json name --jq '.[].name') \
  || { echo "cannot read the variables of $repo: sign in to gh as an admin of the repo and re-run"; exit 1; }
if [ "${FORCE:-}" != 1 ] && grep -qx WORKFLOW_APP_PRIVATE_KEY <<<"$secrets" \
  && grep -qx WORKFLOW_APP_CLIENT_ID <<<"$variables" && grep -qx WORKFLOW_APP_SLUG <<<"$variables"; then
  slug=$(gh variable get WORKFLOW_APP_SLUG -R "$repo") || { echo "cannot read the variable WORKFLOW_APP_SLUG of $repo; re-run"; exit 1; }
  pass_ruleset "$slug"
  mark done "workflow app ok: secret WORKFLOW_APP_PRIVATE_KEY and variables WORKFLOW_APP_CLIENT_ID, WORKFLOW_APP_SLUG already set (FORCE=1 to replace them)"
  exit 0
fi
for tool in python3 openssl curl; do
  command -v "$tool" >/dev/null || { echo "$tool not found; it is needed to create the app"; exit 1; }
done

# install-workflows.yml writes workflow files with this app's token, which a workflow's own token cannot (decisions W5).
# GitHub creates an app from a description posted by the browser of the person who will own it,
# then sends that browser back with a one-time code. So a page on this machine posts the
# description, and the same local server waits for the code. An app's name is unique across all
# of GitHub and at most 34 characters; GitHub's page lets the human change it if it is taken.
manifest=$(jq -cn --arg name "$(cut -c1-34 <<<"$name-workflows")" --arg url "https://github.com/$repo" '{
  name: $name, url: $url, public: false,
  description: "Installs workflow changes the repo owner has approved. Used only by install-workflows.yml.",
  hook_attributes: {url: $url, active: false},
  default_permissions: {contents: "write", workflows: "write"},
  default_events: []
}')
block=$(printf '%s\n' "Create the app in the browser: open the link and click Create GitHub App." "{start}" | owner_block)
code=$(MANIFEST="$manifest" BLOCK="$block" python3 -u -c '
import html, http.server, json, os, secrets, sys, time, urllib.parse, webbrowser
state = secrets.token_hex(16)
result = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def page(self, status, text):
        body = ("<!doctype html><meta charset=utf-8><body>%s</body>" % text).encode()
        self.send_response(status); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        url = urllib.parse.urlparse(self.path); query = urllib.parse.parse_qs(url.query)
        if url.path == "/":
            manifest = json.loads(os.environ["MANIFEST"])
            manifest["redirect_url"] = "http://127.0.0.1:%d/created" % self.server.server_port
            self.page(200, "<form id=f method=post action=\"https://github.com/settings/apps/new?state=%s\">"
                "<input type=hidden name=manifest value=\"%s\"><button>Continue to GitHub</button></form>"
                "<script>document.getElementById(\"f\").submit()</script>" % (state, html.escape(json.dumps(manifest))))
        elif url.path == "/created" and query.get("state") == [state] and query.get("code"):
            result["code"] = query["code"][0]
            self.page(200, "The app is created. Go back to the terminal.")
        else:
            self.page(404, "Not found.")
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
start = "http://127.0.0.1:%d/" % server.server_port
print(os.environ["BLOCK"].replace("{start}", start), file=sys.stderr, flush=True)
try: webbrowser.open(start)
except Exception: pass
deadline = time.time() + 600               # nobody clicked in 10 minutes
while "code" not in result and time.time() < deadline:
    server.timeout = max(1, deadline - time.time())
    server.handle_request()
if "code" not in result: sys.exit(1)
print(result["code"])
') || { echo "nobody created the app in time"; exit 1; }

# From here until the key is stored, an app exists whose key is held only by this process, and
# no API deletes an app. Whatever stops the script, say exactly what to delete: a retry would
# make a second app.
slug=''
stored=''
leftover() {
  [ -z "$stored" ] || return 0
  echo "AN APP IS LEFT ON GITHUB and its key is stored nowhere${slug:+: '$slug'}."
  echo "Delete it before re-running: https://github.com/settings/apps/${slug:+$slug/advanced}"
}
trap leftover EXIT
created=$(gh api -X POST "app-manifests/$code/conversions")
slug=$(jq -r '.slug // empty' <<<"$created")
client_id=$(jq -r '.client_id // empty' <<<"$created")
pem=$(jq -r '.pem // empty' <<<"$created")
unset created
[ -n "$slug" ] && [ -n "$client_id" ] && [ -n "$pem" ] || { echo "GitHub's answer had no name, client id or key for the app"; exit 1; }

# An app proves who it is with a ten-minute pass signed by its key; that pass can ask where the
# app is installed and for an installation's token. Signing it here also proves the key works.
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
pass() {
  local now head body
  now=$(date +%s)
  head=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  body=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$client_id" | b64)
  printf '%s.%s.%s' "$head" "$body" "$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -sign <(printf '%s\n' "$pem") | b64)"
}
as_app() { curl -sS -H "Authorization: Bearer $(pass)" -H 'Accept: application/vnd.github+json' "$@"; }

url="https://github.com/apps/$slug/installations/new"
owner_block <<STEPS
Install the app on $repo alone, in the browser.
$url
   choose   Only select repositories
   select   $repo
   click    Install
STEPS
(open "$url" || xdg-open "$url") >/dev/null 2>&1 || true

# Limited to this repo: installed on any other, the app's key could write that one too, so that
# is not accepted (decisions W6). "Only select repositories" can still hold several, so
# the installation's own token is asked which repos it reaches. Getting that token also proves
# the key does the one thing the workflow needs, before it is stored. The token is given
# straight back.
installation=''
warned=''
deadline=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  answer=$(as_app "$api/repos/$repo/installation") || answer='{}'
  id=$(jq -r '.id // empty' <<<"$answer")
  if [ -n "$id" ]; then
    reach=''
    if [ "$(jq -r .repository_selection <<<"$answer")" = selected ]; then
      token=$(as_app -f -X POST "$api/app/installations/$id/access_tokens" | jq -r '.token // empty') || token=''
      [ -n "$token" ] || { echo "the new app could not get a token for $repo"; exit 1; }
      # Names are compared in lower case: GitHub ignores case in a repo's name, and the name
      # here comes from the folder.
      reach=$(curl -fsS -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$api/installation/repositories?per_page=2" \
        | jq -r '"\(.total_count) \(.repositories[0].full_name | ascii_downcase)"') || reach=''
      curl -fsS -X DELETE -H "Authorization: Bearer $token" "$api/installation/token" || true
      unset token
    fi
    if [ "$reach" = "1 $(tr '[:upper:]' '[:lower:]' <<<"$repo")" ]; then
      installation=$id
      break
    elif [ -z "$warned" ]; then
      warned=1
      owner_block <<STEPS
Change the app to 'Only select repositories' with only $repo: it is installed on more.
https://github.com/settings/installations/$id
STEPS
    fi
  fi
  perl -e 'select(undef, undef, undef, 5)'
done
[ -n "$installation" ] || { echo "the app was not installed on $repo alone within 10 minutes"; exit 1; }
[ "$(jq -r '[.permissions.contents, .permissions.workflows] | join(",")' <<<"$answer")" = "write,write" ] \
  || { echo "the app was installed without permission to write contents and workflows: $(jq -c .permissions <<<"$answer")"; exit 1; }

gh variable set WORKFLOW_APP_CLIENT_ID -R "$repo" --body "$client_id"
gh variable set WORKFLOW_APP_SLUG -R "$repo" --body "$slug"
# Piped to gh, so the key is never printed or written to disk.
printf '%s\n' "$pem" | gh secret set WORKFLOW_APP_PRIVATE_KEY -R "$repo"
stored=1
pass_ruleset "$slug"
mark done "workflow app ok: '$slug' is installed on $repo only and may write contents and workflows; secret WORKFLOW_APP_PRIVATE_KEY and variables WORKFLOW_APP_CLIENT_ID, WORKFLOW_APP_SLUG stored"
