#!/usr/bin/env bash
# deploy-ios.sh — commit all pending changes, push, then run ./deploy.
#
# The repo's ./deploy (Ruby) bumps the iOS version, builds a fresh .ipa,
# cuts a GitHub Release and rewrites ios/apps.json — but it ONLY commits
# project.yml + apps.json. Any other pending work (Swift changes, etc.)
# must be committed and pushed first or it never ships. This wrapper does
# that, then hands off to ./deploy.
#
# Usage:
#   deploy-ios.sh                         # commit pending, push, ./deploy (patch bump)
#   deploy-ios.sh patch|minor|major       # forward bump kind to ./deploy
#   deploy-ios.sh 1.4.2                    # forward explicit version to ./deploy
#   deploy-ios.sh -m "message" minor      # custom commit message for pending changes
#   deploy-ios.sh --dry-run [args]        # run preflight checks only; commit nothing
#
# Remote is named `github` (there is no `origin`); ./deploy pushes there too.

set -euo pipefail

msg="Commit pending changes before iOS deploy"
dry_run=0
bump=""

while [ $# -gt 0 ]; do
  case "$1" in
    -m) msg="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) bump="$1"; shift ;;
  esac
done

root="$(git rev-parse --show-toplevel)"
cd "$root"

remote="github"
branch="$(git rev-parse --abbrev-ref HEAD)"
default="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"

# --- preflight (safe; --dry-run stops after this) ---------------------------
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$1"; }

use_full_xcode() {
  if xcodebuild -version >/dev/null 2>&1; then
    ok "xcodebuild is available"
    return
  fi

  local xcode_app="${XCODE_APP:-/Applications/Xcode.app}"
  local developer_dir="$xcode_app/Contents/Developer"

  [ -d "$developer_dir" ] || fail "xcodebuild requires full Xcode; install Xcode.app or set XCODE_APP"

  export DEVELOPER_DIR="$developer_dir"
  xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild failed with DEVELOPER_DIR=$DEVELOPER_DIR"

  ok "using full Xcode at $DEVELOPER_DIR"
}

command -v gh >/dev/null 2>&1 || fail "gh CLI not on PATH (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated (gh auth login)"
ok "gh authenticated"

git remote get-url "$remote" >/dev/null 2>&1 || fail "no git remote named '$remote'"
ok "remote '$remote' present"

[ "$branch" = "$default" ] || fail "on '$branch', not default '$default' — ./deploy requires the default branch"
ok "on default branch '$branch'"

[ -x "$root/deploy" ] || fail "$root/deploy missing or not executable"
ok "./deploy is executable"

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen missing; install with: brew install xcodegen"
ok "xcodegen is available"

use_full_xcode

# --- resolve a free version (auto-bump past any pre-existing tag/release) ----
# ./deploy bumps off MARKETING_VERSION in project.yml, which can lag reality
# if a prior run cut a GitHub release/tag but died before committing the bump.
# Resolve the target version here, against GitHub itself, so that case can't
# collide — then pass ./deploy an explicit X.Y.Z instead of a bump keyword.
version_yml="$root/ios/PatataTube/project.yml"
current_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/p' "$version_yml" | head -1)"
[ -n "$current_version" ] || fail "no MARKETING_VERSION in $version_yml"

bump_version() {
  local ver="$1" kind="$2" maj min pat
  IFS=. read -r maj min pat <<<"$ver"
  case "$kind" in
    major) echo "$((maj + 1)).0.0" ;;
    minor) echo "$maj.$((min + 1)).0" ;;
    *)     echo "$maj.$min.$((pat + 1))" ;;
  esac
}

version_taken() {
  local tag="v$1"
  gh release view "$tag" >/dev/null 2>&1 && return 0
  [ -n "$(git ls-remote --tags "$remote" "refs/tags/$tag" 2>/dev/null)" ] && return 0
  return 1
}

if [[ "$bump" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  candidate="$bump"
  version_taken "$candidate" && fail "release v$candidate already exists — pick a different version"
else
  candidate="$(bump_version "$current_version" "${bump:-patch}")"
  while version_taken "$candidate"; do
    echo "release v$candidate already exists — bumping past it"
    candidate="$(bump_version "$candidate" patch)"
  done
fi
bump="$candidate"
ok "target version v$bump (from v$current_version)"

echo "--- pending changes ---"
git status --short
echo "--- plan ---"
echo "  1. git add -A && git commit -m \"$msg\"   (skipped if nothing pending)"
echo "  2. git push $remote $branch"
echo "  3. ./deploy $bump"

if [ "$dry_run" -eq 1 ]; then
  ok "dry run — nothing committed, pushed, or deployed"
  exit 0
fi

# --- commit + push pending work ---------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "$msg"
  ok "committed pending changes"
else
  echo "no pending changes — nothing to commit"
fi

git push "$remote" "$branch"
ok "pushed to $remote/$branch"

# --- hand off to the release script -----------------------------------------
exec ./deploy ${bump:+"$bump"}
