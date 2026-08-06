# Codex deploy-ios Skill Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repository-local `deploy-ios` skill discoverable at the Codex project path without duplicating it.

**Architecture:** Create a single relative directory symlink at `.codex/skills/deploy-ios`. It points to the existing `.claude/skills/deploy-ios` directory, leaving that directory as the sole source of skill content.

**Tech Stack:** Git-tracked POSIX symbolic link; existing Markdown skill and shell driver.

## Global Constraints

- Create exactly `.codex/skills/deploy-ios` pointing to `../../.claude/skills/deploy-ios`.
- Do not copy or modify `.claude/skills/deploy-ios/SKILL.md` or `deploy-ios.sh`.
- Use a relative target so the checkout remains relocatable.

---

### Task 1: Expose deploy-ios to Codex

**Files:**
- Create: `.codex/skills/deploy-ios` (symbolic link)
- Read-only source: `.claude/skills/deploy-ios/SKILL.md`

**Interfaces:**
- Consumes: the existing skill directory at `.claude/skills/deploy-ios`
- Produces: a Codex-discoverable skill directory at `.codex/skills/deploy-ios`

- [ ] **Step 1: Verify the destination is absent**

Run: `test ! -e .codex/skills/deploy-ios`

Expected: exit code 0.

- [ ] **Step 2: Create the parent directory and relative symbolic link**

Run:

```bash
mkdir -p .codex/skills
ln -s ../../.claude/skills/deploy-ios .codex/skills/deploy-ios
```

- [ ] **Step 3: Verify link resolution and exposed skill metadata**

Run:

```bash
test "$(readlink .codex/skills/deploy-ios)" = ../../.claude/skills/deploy-ios
test -f .codex/skills/deploy-ios/SKILL.md
```

Expected: the target is relative and `SKILL.md` is readable through the Codex path.

- [ ] **Step 4: Stage and verify the Git representation**

Run:

```bash
git add .codex/skills/deploy-ios
git diff --cached --summary -- .codex/skills/deploy-ios
git diff --cached -- .codex/skills/deploy-ios
```

Expected: Git records a single symlink whose content is `../../.claude/skills/deploy-ios`.

- [ ] **Step 5: Commit**

```bash
git commit -m "chore: expose deploy-ios skill to Codex"
```
