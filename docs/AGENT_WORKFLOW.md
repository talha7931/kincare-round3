# KinCare — Multi-Agent Repository Workflow

This workflow is designed for Antigravity, Cursor and GitHub Copilot working against one GitHub repository without overwriting each other's changes.

## 1. The golden rule

**One shared repository, one master spec, one owner per workstream, separate branches/worktrees, reviewed merges.**

Do not have all three agents edit the same checkout/branch at once. Do not ask multiple agents to redesign the schema or edit the same shared contract concurrently.

## 2. Suggested ownership

| Tool | Primary responsibility | Allowed scope |
|---|---|---|
| Antigravity | Integration lead and Android workstream | Flutter files in `android_app/`, integration planning; backend migrations only when explicitly assigned |
| Cursor | PWA workstream | React/TypeScript files in `pwa/`, PWA-specific tests |
| GitHub Copilot | In-editor assistance, small scoped fixes and code review | Only files in the currently assigned branch/task; not an independent schema owner |
| Project owner (Talha) | Product decisions, review and merge approval | Master spec, priorities, secrets, branch/merge approvals |

Designate **one backend/schema owner** (initially Antigravity unless Talha assigns otherwise) for `supabase/migrations/`, generated database types and `docs/API_CONTRACTS.md`. Other agents may review but must not make parallel schema edits.

## 3. Repository connection sequence

1. Create one private GitHub repository named `kincare-round3` (or choose the final name).
2. Add the supplied master spec, `AGENTS.md`, `.github/copilot-instructions.md`, `.cursor/rules/kincare.mdc` and `docs/AGENT_WORKFLOW.md` to the repository before asking agents to code.
3. Connect/clone the same repository in Antigravity and Cursor. Open the repository root, not just a subfolder, so each tool can discover shared instructions.
4. Enable GitHub Copilot in the same repository in the editor where it is used.
5. Verify `git remote -v`, `git status` and the current branch in each working environment.
6. Keep `main` as the reviewed integration branch. Create feature branches from the latest `main`.

## 4. Parallel work without file collisions

### Recommended branch ownership

- `feature/backend-contract` — Supabase migrations, RLS, seed/demo data, generated types and API contract. Single owner.
- `feature/android` — all `android_app/` work. Antigravity owner.
- `feature/pwa` — all `pwa/` work. Cursor owner.
- `feature/docs-demo` — documentation, test plan and demo script. Copilot may assist; Talha reviews.

After `feature/backend-contract` is reviewed and merged, Android and PWA work from the same updated `main` so they target identical table names and payloads.

### Separate Git worktrees (best for true parallel work)

From a clean main clone, create one worktree per agent:

```bash
git switch main
git pull --ff-only
git worktree add ../KinCare-backend -b feature/backend-contract main
git worktree add ../KinCare-android -b feature/android main
git worktree add ../KinCare-pwa -b feature/pwa main
git worktree add ../KinCare-docs -b feature/docs-demo main
```

Open each folder in the corresponding tool. If worktrees are unfamiliar, use sequential work in one clone instead; do not improvise multiple agents in one shared working directory.

After backend schema is accepted, merge `feature/backend-contract` to `main`, then update Android/PWA branches:

```bash
git fetch origin
git switch feature/android
git merge origin/main

git switch feature/pwa
git merge origin/main
```

Resolve conflicts deliberately. Do not use force push or `reset --hard` to “fix” a conflict.

## 5. Task handoff template

Before each agent starts, give it:

```text
Read AGENTS.md and docs/KINCARE_ROUND3_MASTER_SPEC.md.
You own only: [explicit folders/files].
Branch: [assigned branch].
Task: [one small vertical slice].
Acceptance criteria: [observable outcomes].
Do not edit: [shared schema/contracts/other agent folders].
Run: [specific tests/build command].
Do not merge or push to main. Report changed files, actual test output, limitations and commit hash.
```

## 6. Integration protocol

- Merge backend/schema contract first.
- Android and PWA consume the same approved schema and response payload definitions.
- Each branch must run its own tests/build before pull request/merge.
- Use small pull requests/commits; avoid one huge end-of-week merge.
- Talha reviews the changed files and the test evidence before merging.
- After each merge, pull latest `main` into the other workstream and run a smoke test.
- When one agent changes a contract, it must notify the other platform owner with the exact changed fields and migration/commit reference.

## 7. Daily workflow

1. Read current `main`, assigned tasks and open blockers.
2. Confirm branch and clean working tree.
3. Work only in owned directories.
4. Run format, static analysis, unit tests and build relevant to the changed app.
5. Commit with a descriptive message.
6. Provide handoff using the AGENTS.md required format.
7. Review/merge after project-owner approval.

## 8. Conflict and safety rules

- Never let two agents edit `supabase/migrations/` concurrently.
- Never let two agents edit the same platform's app files concurrently.
- Shared design tokens/API payloads must be changed through a reviewed contract update.
- Never paste secrets into agent prompts or commit `.env` files.
- Keep `.env.example` with variable names only; put actual secrets in local untracked `.env` files or managed deployment secrets.
- Use synthetic test profiles/photos/voice recordings for demos unless the owner has explicit consent for real media.
- If an agent suggests removing a feature in this spec, it must explain the deadline reason and request approval; it must not silently omit it.

## 9. Windows PowerShell worktree commands

Run these from the main local clone after the initial docs/instructions commit has been pushed to GitHub. First create/merge the backend contract branch; only then create the Android and PWA worktrees from updated `main`.

```powershell
# From the main clone
 git switch main
 git pull --ff-only

# Once backend contract changes are reviewed and merged to main:
 git worktree add ..\KinCare-android -b feature/android main
 git worktree add ..\KinCare-pwa -b feature/pwa main
```

Open `KinCare-android` in Antigravity and `KinCare-pwa` in Cursor. Keep the original clone for integration/review. Copilot can assist inside the currently assigned branch/editor; if you want it to work independently at the same time, give it its own worktree and a narrowly scoped branch (for example `feature/tests-docs`). Never run multiple agents against the same working directory simultaneously.

## 10. Recommended agent sequence for this short sprint

1. **Antigravity — repository audit and backend contract:** verify toolchain, create/review migrations and RLS; no app feature work until schema is stable.
2. **Merge the backend contract.** Freeze table names, fields and response payloads.
3. **Antigravity — Android worktree; Cursor — PWA worktree:** implement the same vertical slice against the frozen contract.
4. **Copilot — review/support:** use it for small isolated fixes, tests, documentation, code explanation and PR review. Do not let it independently redesign the schema.
5. **Talha — integration owner:** run both apps, verify cross-client sync, review diffs and approve merges.

If the team cannot comfortably manage worktrees, work sequentially in a single clone and switch tools one at a time. That is safer than parallel edits in one folder.
