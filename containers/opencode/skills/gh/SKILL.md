---
name: gh
description: Use the GitHub CLI to interact with GitHub from the command line. Create and review pull requests, manage issues, list and create releases, and call the GitHub REST/GraphQL API.
---

## What I do

- PRs: `gh pr create`, `gh pr checkout`, `gh pr review`, `gh pr merge`, `gh pr list`, `gh pr status`.
- Issues: `gh issue create`, `gh issue list`, `gh issue view`, `gh issue close`.
- Releases: `gh release create`, `gh release list`, `gh release download`.
- API: `gh api <endpoint>` for arbitrary REST/GraphQL calls.

## When to use me

Use this skill when the agent needs to interact with GitHub: open or review pull requests, triage issues, or query
repository metadata. Authentication is handled transparently via the sandbox proxy, so the agent never handles raw
tokens.
