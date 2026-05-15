#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# push-imageviewerkit.sh
# Run this ONCE in Terminal to fix Homebrew, install gh, and push to GitHub.
# ─────────────────────────────────────────────────────────────────────────────

set -e

REPO_DIR="/Users/osmansezer/Documents/Enchanté/Conversations/0E5C28F0-8AAA-430A-9E20-8C28839E86C4/ImageViewerKit"
GITHUB_REPO_NAME="ImageViewerKit"     # change if you want a different name
GITHUB_VISIBILITY="public"            # or "private"

echo "╔══════════════════════════════════════════════╗"
echo "║  ImageViewerKit — GitHub Push Setup Script   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: Fix Homebrew permissions ─────────────────────────────────────────
echo "▶ Step 1/4 — Fixing Homebrew permissions..."
sudo chown -R "$(whoami)" /opt/homebrew /Users/"$(whoami)"/Library/Logs/Homebrew
echo "   ✅ Homebrew permissions fixed"

# ── Step 2: Install gh CLI ───────────────────────────────────────────────────
echo ""
echo "▶ Step 2/4 — Installing GitHub CLI..."
if command -v gh &> /dev/null; then
    echo "   ✅ gh already installed: $(gh --version | head -1)"
else
    brew install gh
    echo "   ✅ gh installed"
fi

# ── Step 3: Authenticate with GitHub ────────────────────────────────────────
echo ""
echo "▶ Step 3/4 — Authenticating with GitHub..."
echo "   (A browser window or token prompt will appear)"
gh auth login --hostname github.com --git-protocol https --web
echo "   ✅ Authenticated"

# ── Step 4: Create remote repo and push ─────────────────────────────────────
echo ""
echo "▶ Step 4/4 — Creating GitHub repo and pushing..."
cd "$REPO_DIR"

gh repo create "$GITHUB_REPO_NAME" \
    --$GITHUB_VISIBILITY \
    --description "A reusable macOS Swift framework for viewing HDR, HEIC, RAW, EXR and 100+ image formats" \
    --source . \
    --remote origin \
    --push

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ Done! Repo live at:                      ║"
echo "║  https://github.com/$(gh api user -q .login)/$GITHUB_REPO_NAME  "
echo "╚══════════════════════════════════════════════╝"
