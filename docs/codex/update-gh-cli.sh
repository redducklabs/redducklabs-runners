#!/usr/bin/env bash
set -euo pipefail

echo "Adding GitHub CLI official apt repository..."
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

echo "Updating apt package lists..."
sudo apt update

echo "Installing latest GitHub CLI package..."
sudo apt install -y gh

echo
echo "Installed gh version:"
gh --version

echo
echo "Checking GitHub auth status:"
gh auth status

echo
echo "Checking GitHub Projects command:"
gh project list --owner redducklabs
