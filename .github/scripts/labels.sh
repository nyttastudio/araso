#!/bin/bash
# Labels issues and PRs (.github/labels.yml says which labels there are, CONTRIBUTING.md how they're
# used). It only adds labels, so one the maintainer took off stays off until the issue changes again.
#
#   labels.sh sync              create or update every label in .github/labels.yml (needs ruby)
#   labels.sh form <number>     an issue just opened: the area picked in its form's dropdown
#   labels.sh pr <number>       a PR: the kind and area labels of the issues it closes
#   labels.sh issue <number>    an issue just labeled: the same for the open PRs that close it
#
# Needs GH_TOKEN and REPO (owner/name). DRY_RUN=1 prints what it would change instead.
set -euo pipefail

owner=${REPO%/*}
name=${REPO#*/}
# What a PR takes from its issue: the kind and the areas, never a status such as accepted.
inherited='^(bug|enhancement|docs|ci|area: .+|platform: .+)$'

run() {
    if [[ ${DRY_RUN:-} == 1 ]]; then echo "  would run: $*"; else "$@"; fi
}

add() {
    local number=$1 args=() label
    shift
    (($#)) || { echo "#$number: nothing to add"; return; }
    for label; do args+=(-f "labels[]=$label"); done
    echo "#$number: + $*"
    run gh api "repos/$REPO/issues/$number/labels" "${args[@]}" >/dev/null
}

# The option of the issue forms' "영역 / Area" dropdown (ISSUE_TEMPLATE/bug.yml, feature.yml).
area_label() {
    case $1 in
    한국어*) echo "area: korean" ;;
    일본어*) echo "area: japanese" ;;
    언어*) echo "area: decision" ;;
    자판*) echo "area: layout" ;;
    학습*) echo "area: dictionary" ;;
    특정*) echo "area: app-compat" ;;
    설치*) echo "area: install" ;;
    설정*) echo "area: settings" ;;
    Windows*) echo "platform: windows" ;;
    esac
}

pr() {
    local number=$1 data labels=()
    data=$(gh api graphql -F owner="$owner" -F name="$name" -F pr="$number" -f query='
        query($owner: String!, $name: String!, $pr: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $pr) {
              labels(first: 50) { nodes { name } }
              closingIssuesReferences(first: 10) { nodes { labels(first: 30) { nodes { name } } } }
            }
          }
        }' --jq .data.repository.pullRequest)
    mapfile -t labels < <(jq -r --arg re "$inherited" '
        [.labels.nodes[].name] as $has
        | [.closingIssuesReferences.nodes[].labels.nodes[].name | select(test($re)) | select(. as $l | $has | index($l) | not)]
        | unique[]' <<<"$data")
    add "$number" "${labels[@]}"
}

case ${1:-} in
sync)
    ruby -ryaml -rjson -e 'YAML.load_file(ARGV[0]).each { |l| puts l.to_json }' \
        "$(dirname "$0")/../labels.yml" | while read -r label; do
        echo "$(jq -r .name <<<"$label")"
        run gh label create "$(jq -r .name <<<"$label")" --repo "$REPO" --force \
            --color "$(jq -r .color <<<"$label")" --description "$(jq -r .description <<<"$label")"
    done
    ;;
form)
    area=$(gh api "repos/$REPO/issues/$2" --jq .body | tr -d '\r' \
        | awk '/^### 영역 \/ Area/ { found = 1; next } found && NF { print; exit }')
    label=$(area_label "$area")
    if [[ -n $label ]]; then add "$2" "$label"; else echo "#$2: no area picked"; fi
    ;;
pr) pr "$2" ;;
issue)
    for number in $(gh api graphql -F owner="$owner" -F name="$name" -F issue="$2" -f query='
        query($owner: String!, $name: String!, $issue: Int!) {
          repository(owner: $owner, name: $name) {
            issue(number: $issue) { closedByPullRequestsReferences(first: 20) { nodes { number } } }
          }
        }' --jq '.data.repository.issue.closedByPullRequestsReferences.nodes[].number'); do
        pr "$number"
    done
    ;;
*) echo "usage: $0 sync | form <number> | pr <number> | issue <number>" >&2; exit 2 ;;
esac
