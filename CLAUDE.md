# GrimmLink — Claude Instructions

## Git Workflow

### PRs must target `origin` only — NEVER `upstream`

- `origin` = `0xstillb/grimmlink` ← PRs go here
- `upstream` = `WorldTeacher/BookLoreSync-plugin` ← never open PRs here

Always pass `--repo 0xstillb/grimmlink` explicitly when creating PRs:

```bash
gh pr create --repo 0xstillb/grimmlink --base main ...
```
