# Start here — KinCare Round 3 repository pack

## Put these files in the connected GitHub repository

- `KINCARE_ROUND3_MASTER_SPEC.md` → place at `docs/KINCARE_ROUND3_MASTER_SPEC.md`.
- `AGENTS.md` → repository root.
- `.github/copilot-instructions.md` → same path in repository.
- `.cursor/rules/kincare.mdc` → same path in repository.
- `docs/AGENT_WORKFLOW.md` → same path in repository.
- `docs/SUBMISSION_CHECKLIST.md` → same path in repository.

Then commit them before asking any agent to implement features.

## First prompts after connecting each tool

### Antigravity

“Read AGENTS.md, docs/KINCARE_ROUND3_MASTER_SPEC.md and docs/AGENT_WORKFLOW.md. Inspect the repository and environment. Do not generate the whole app yet. Report the missing setup, propose the backend migration sequence, and confirm the assigned branch/file ownership. Do not modify files until I approve the first scoped task.”

### Cursor

“Read AGENTS.md, docs/KINCARE_ROUND3_MASTER_SPEC.md and docs/AGENT_WORKFLOW.md. You are the PWA owner only. Inspect the repository and report the React/PWA implementation plan, required packages and acceptance tests. Do not edit backend migrations or Android files. Do not start coding until the shared Supabase contract is merged.”

### GitHub Copilot

“Use the repository instructions. Help only with the currently assigned task/branch. Do not change shared Supabase schema unless explicitly assigned. Before editing, inspect the diff and git status. After editing, report exact files and tests.”

## Suggested order

1. Connect repository and commit this pack.
2. Check Flutter/Android, Node/npm, Git and Supabase CLI availability.
3. Assign one owner for backend schema and RLS; freeze/merge that contract first.
4. Start Android and PWA branches/worktrees against the same contract.
5. Build and test one vertical slice at a time.

Do not share actual Supabase secrets with agents in chat. Configure local `.env` files and platform-specific secret settings; never commit them.
