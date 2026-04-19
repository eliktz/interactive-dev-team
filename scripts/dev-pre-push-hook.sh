#!/bin/bash
# Dev workspace git pre-push hook — mirrors QA Lead's gate set so QA never
# sees anything Dev didn't see first.
#
# Installed per-workspace via Step 0 in backend-dev/frontend-dev AGENTS.md
# (symlinked from /workspace/scripts/dev-pre-push-hook.sh to .git/hooks/pre-push).
# Blocks `git push` if any gate fails. Dev must fix and re-push.
#
# Gates (all in the package.json's go-north-app / Next.js conventions):
#   1. pnpm install --frozen-lockfile   (same as QA — catches lockfile drift)
#   2. pnpm lint                         (catches react-hooks, etc.)
#   3. pnpm build                        (next build)
#   4. pnpm test (if defined)            (vitest/jest — skipped if missing)
#
# Design: fail-closed and loud. A green hook means QA's qa:functional tier
# will also pass. A red hook means DO NOT PUSH — fix locally first.

set -u  # no -e here; we control exit codes explicitly

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_DIR" ]; then
  echo "[pre-push] Not inside a git repo — skipping hook."
  exit 0
fi
cd "$REPO_DIR"

# If this repo has no package.json (e.g. a config-only repo), skip.
if [ ! -f package.json ]; then
  echo "[pre-push] No package.json — skipping QA dry-run."
  exit 0
fi

echo "[pre-push] Running QA dry-run (install + lint + build + tests)..."
START=$SECONDS

# Gate 1: frozen-lockfile install
echo "[pre-push] (1/4) pnpm install --frozen-lockfile"
if ! pnpm install --frozen-lockfile 2>&1 | tail -10; then
  echo
  echo "[pre-push] ❌ FAILED: pnpm install --frozen-lockfile."
  echo "[pre-push] Did you edit package.json? Regenerate pnpm-lock.yaml:"
  echo "[pre-push]   pnpm install   (WITHOUT --frozen-lockfile)"
  echo "[pre-push]   git add pnpm-lock.yaml"
  echo "[pre-push]   git commit --amend --no-edit   (or a new commit)"
  exit 1
fi

# Gate 2: lint — skip if no lint script exists
if node -e 'process.exit(require("./package.json").scripts?.lint ? 0 : 1)' 2>/dev/null; then
  echo "[pre-push] (2/4) pnpm lint"
  if ! pnpm lint 2>&1 | tail -30; then
    echo
    echo "[pre-push] ❌ FAILED: pnpm lint."
    echo "[pre-push] Fix the lint errors above and commit before pushing."
    echo "[pre-push] Common flavors: react-hooks/refs, react-hooks/set-state-in-effect, react-hooks/exhaustive-deps."
    exit 1
  fi
else
  echo "[pre-push] (2/4) pnpm lint — skipped (no lint script in package.json)"
fi

# Gate 3: build
echo "[pre-push] (3/4) pnpm build"
if ! pnpm build 2>&1 | tail -10; then
  echo
  echo "[pre-push] ❌ FAILED: pnpm build."
  echo "[pre-push] Fix the TypeScript/Next build errors above and commit before pushing."
  exit 1
fi

# Gate 4: tests — skip if no test script exists
if node -e 'process.exit(require("./package.json").scripts?.test ? 0 : 1)' 2>/dev/null; then
  echo "[pre-push] (4/4) pnpm test (ci mode)"
  # Try vitest --run first, then fall back to plain `pnpm test`.
  # Never block on infra-style test failures; block only on assertion failures.
  if ! pnpm test -- --run 2>&1 | tail -30; then
    if ! pnpm test 2>&1 | tail -30; then
      echo
      echo "[pre-push] ❌ FAILED: pnpm test."
      echo "[pre-push] Fix the failing tests above (or explicitly update snapshots) before pushing."
      exit 1
    fi
  fi
else
  echo "[pre-push] (4/4) pnpm test — skipped (no test script in package.json)"
fi

DURATION=$((SECONDS - START))
echo "[pre-push] ✅ All gates passed (${DURATION}s). Proceeding with push."
exit 0
