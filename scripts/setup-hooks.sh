#!/usr/bin/env bash

# Script to set up git hooks for the project.
# Run this once after cloning the repository.

set -e

# Change to the project root directory
cd "$(git rev-parse --show-toplevel)"

echo "🚀 Setting up git hooks..."

# Ensure the .githooks directory exists
if [ ! -d ".githooks" ]; then
    echo "❌ Error: .githooks directory not found."
    exit 1
fi

# Make hooks executable
chmod +x .githooks/*

# Configure git to use the .githooks directory
git config core.hooksPath .githooks

echo "✅ Git hooks configured successfully!"
echo "Hooks will now enforce:"
echo "  - Conventional Commits + 50/72 rule (commit-msg)"
echo "  - Zig formatting check (pre-commit)"
