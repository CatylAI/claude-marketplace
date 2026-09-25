# gh and GitHub feature facts

Version numbers and limits change. The skills in this plugin detect features by behaviour (run
`gh issue edit --help` and look for the flag) and keep the numbers here.

**Verify against current docs** before relying on a number below: `gh <command> --help` on the
installed binary is the ground truth for flags, and `gh --version` prints the installed release.
These were checked against the `cli/cli` source at each release tag, the
`github/rest-api-description` OpenAPI file and the `github/docs` sources, when v2.101.0 was the
latest `gh` release.

## gh CLI

| Feature | First release | Where it is defined |
|---|---|---|
| `gh issue create --parent`, `--type`, `--blocked-by`, `--blocking` | v2.94.0 (absent in v2.93.0) | `pkg/cmd/issue/create/create.go` |
| `gh issue edit --parent`, `--remove-parent`, `--add-sub-issue`, `--remove-sub-issue`, `--type`, `--remove-type`, `--add-blocked-by`, `--remove-blocked-by`, `--add-blocking`, `--remove-blocking` | v2.94.0 | `pkg/cmd/issue/edit/edit.go` |
| `--json issueType,parent,subIssues,subIssuesSummary,blockedBy,blocking` on `gh issue view` and `gh issue list` | v2.94.0 | `api/query_builder.go` |
| `gh project item-edit <number> --owner <o> --url <issue-url> --field <name> --value <option>` | v2.97.0 (absent in v2.96.0) | `pkg/cmd/project/item-edit/item_edit.go` |
| `gh issue close --reason duplicate --duplicate-of <n>` | present in v2.93.0 | `pkg/cmd/issue/close/close.go` |

Behaviour worth knowing:

- `gh issue edit --parent <n>` replaces an existing parent (the code sets `ReplaceExistingParent`),
  so re-parenting is one command. Numbers and issue URLs are both accepted.
- `--json subIssues` returns the first 100 children plus `totalCount`; `blockedBy` and `blocking`
  return the first 50.
- `gh issue close --reason` takes `completed`, `"not planned"` (with a space) or `duplicate`. The
  REST and MCP value is `not_planned`; a script that calls the API directly does not share the
  CLI's literal.
- `gh api`: the method is GET unless parameters are added with `-f`/`-F`, which switch it to POST.
  Pass `--method GET` to send the parameters as a query string instead. `--paginate` adds
  `per_page=100` and follows every page. This holds in every release.
- `gh auth login` requests `repo`, `read:org` and `gist` as its minimum scopes, not `project`.
  Projects v2 commands need `gh auth refresh -s project` (or `-s read:project` for reads).

## GitHub platform

- A parent holds at most 100 sub-issues, nested up to eight levels (github/docs, "Adding
  sub-issues").
- A sub-issue must belong to the same repository owner as its parent (OpenAPI,
  `POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues`).
- REST list endpoints return 30 items per page unless `per_page` (max 100) is set.
- Issue types are defined by an organization and inherited by its repositories
  (`GET /repos/{owner}/{repo}/issue-types`); a repository owned by a personal account has no
  organization to inherit from, so expect an empty list there. Setting a type
  without push access is silently dropped (OpenAPI, `PATCH …/issues/{issue_number}`), so read it
  back.
- GitHub Enterprise Server can lag github.com on sub-issues, issue types and dependencies. A 404
  from one of those endpoints on an issue that exists usually means the feature is missing on that
  deployment, not a bad id.
