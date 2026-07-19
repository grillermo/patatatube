# Codex deploy-ios Skill Discovery

## Goal

Make the existing repository-local `deploy-ios` skill discoverable by Codex
without copying or modifying the skill.

## Design

Create `.codex/skills/deploy-ios` as a relative symbolic link to
`../../.claude/skills/deploy-ios`.

The linked directory remains the sole source of the skill's `SKILL.md` and
`deploy-ios.sh`; edits through either path affect the same files.

## Boundaries

- Do not duplicate or edit the skill content.
- Do not expose other `.claude` skills automatically.
- Keep the link relative so the repository remains relocatable.

## Verification

Confirm that the link resolves to the source directory, its `SKILL.md` is
readable at the Codex path, and Git reports it as a symlink.
