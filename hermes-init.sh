#!/usr/bin/env bash
set -Eeuo pipefail

cd ~
git clone https://github.com/enovikov11/tigor-ai.git

cd ~/tigor-ai
git remote remove origin
git remote add forgejo-push-for-preview http://10.67.69.2:3000/hermes/tigor-ai.git
git remote add github-pull-and-push-to-main https://github.com/enovikov11/tigor-ai.git

mkdir -p ~/tigor-ai.worktrees

cd ~
git clone https://github.com/enovikov11/tigor-no-ai.git

cd ~/tigor-no-ai
git remote remove origin
git remote add github-pull https://github.com/enovikov11/tigor-no-ai.git
git remote add github-push-to-feature-branch https://github.com/enovikov11-ai-agent/tigor-no-ai.git

mkdir -p cd ~/tigor-no-ai.worktrees

ln -s ~/tigor-ai/.hermes ~/.hermes
