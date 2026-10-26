#!/bin/bash
# Every PR starts from an issue the maintainer has accepted (CONTRIBUTING.md): the issue carries the
# label `accepted` and the PR links it with `Closes #N`. For a PR that doesn't, this leaves one
# comment saying so, and edits that comment once it does. It never closes or blocks anything.
#
#   issue-first.sh pr <number>       check one PR
#   issue-first.sh issue <number>    check the open PRs that link this issue (it was just labeled)
#
# Needs GH_TOKEN and REPO (owner/name). DRY_RUN=1 prints the comment instead of posting it.
set -euo pipefail

owner=${REPO%/*}
name=${REPO#*/}
marker='<!-- araso-issue-first -->'
label=accepted
# PRs opened before the rule was published are left alone.
since=${SINCE:-2026-10-26T02:42:46Z}
ko=https://github.com/nyttastudio/araso/blob/main/CONTRIBUTING.md
en=https://github.com/nyttastudio/araso/blob/main/CONTRIBUTING.en.md

check() {
    local pr=$1 data issues accepted body existing
    data=$(gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr" -f query='
        query($owner: String!, $name: String!, $pr: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $pr) {
              state createdAt authorAssociation author { __typename }
              closingIssuesReferences(first: 10) { nodes { number labels(first: 30) { nodes { name } } } }
            }
          }
        }' --jq .data.repository.pullRequest)

    # The maintainer, collaborators and bots (the release app) don't go through issues.
    if [[ $(jq -r .state <<<"$data") != OPEN ]] \
        || [[ $(jq -r .createdAt <<<"$data") < $since ]] \
        || [[ $(jq -r .author.__typename <<<"$data") == Bot ]] \
        || [[ $(jq -r .authorAssociation <<<"$data") =~ ^(OWNER|MEMBER|COLLABORATOR)$ ]]; then
        echo "#$pr: skipped"
        return
    fi

    issues=$(jq -r '[.closingIssuesReferences.nodes[] | "#\(.number)"] | join(", ")' <<<"$data")
    accepted=$(jq -r --arg label "$label" \
        '[.closingIssuesReferences.nodes[] | select(any(.labels.nodes[]; .name == $label)) | "#\(.number)"] | join(", ")' <<<"$data")

    if [[ -n $accepted ]]; then
        body="$marker
✅ 받아들여진 이슈 $accepted에 연결되었습니다. / Linked to the accepted issue $accepted."
    elif [[ -n $issues ]]; then
        body="$marker
연결된 이슈($issues)가 아직 받아들여지지 않았습니다. 메인테이너가 이슈에서 방향에 답하고 \`$label\` 라벨을 붙이면 이 PR을 리뷰합니다.

The linked issue ($issues) hasn't been accepted yet. This PR will be reviewed once the maintainer has answered there and labeled it \`$label\`."
    else
        body="$marker
보내 주셔서 고맙습니다! Araso의 PR은 메인테이너가 받아들인 이슈에서 시작합니다([CONTRIBUTING.md]($ko)).
이슈를 먼저 열고, 그 이슈에 \`$label\` 라벨이 붙으면 이 PR 설명에 \`Closes #번호\`를 넣어 주세요. 그때까지는 리뷰하지 않습니다.

Thanks for sending this! PRs to Araso start from an issue the maintainer has accepted ([CONTRIBUTING.en.md]($en)). Open an issue first; once it has the \`$label\` label, add \`Closes #<number>\` to this PR's description. It won't be reviewed until then."
    fi

    # One comment per PR, edited as things change.
    existing=$(gh api --paginate "repos/$REPO/issues/$pr/comments" \
        | jq -s --arg marker "$marker" \
            '[add[]? | select(.user.type == "Bot" and (.body | startswith($marker)))] | first | if . then {id, body} else empty end')

    if [[ -z $existing ]]; then
        [[ -n $accepted ]] && { echo "#$pr: linked to $accepted"; return; }
    elif [[ $(jq -r .body <<<"$existing") == "$body" ]]; then
        echo "#$pr: comment up to date"
        return
    fi

    if [[ ${DRY_RUN:-} == 1 ]]; then
        printf '#%s: would %s\n%s\n' "$pr" "$([[ -n $existing ]] && echo edit || echo post)" "$body"
    elif [[ -n $existing ]]; then
        gh api -X PATCH "repos/$REPO/issues/comments/$(jq -r .id <<<"$existing")" -f body="$body" >/dev/null
        echo "#$pr: comment edited"
    else
        gh api "repos/$REPO/issues/$pr/comments" -f body="$body" >/dev/null
        echo "#$pr: comment posted"
    fi
}

case $1 in
pr) check "$2" ;;
issue)
    for pr in $(gh api graphql -F owner="$owner" -F name="$name" -F issue="$2" -f query='
        query($owner: String!, $name: String!, $issue: Int!) {
          repository(owner: $owner, name: $name) {
            issue(number: $issue) { closedByPullRequestsReferences(first: 20) { nodes { number } } }
          }
        }' --jq '.data.repository.issue.closedByPullRequestsReferences.nodes[].number'); do
        check "$pr"
    done
    ;;
*) echo "usage: $0 pr|issue <number>" >&2; exit 2 ;;
esac
