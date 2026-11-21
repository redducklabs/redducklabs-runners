# Contributing to Red Duck Labs GitHub Actions Runners

Thank you for your interest in contributing to the Red Duck Labs GitHub Actions Runners project! This document provides guidelines and information for contributors.

## 🤝 Code of Conduct

We are committed to providing a welcoming and inclusive experience for everyone. Please be respectful and constructive in all interactions.

## 🎯 How to Contribute

### Types of Contributions

We welcome various types of contributions:

- **Bug fixes** - Help us identify and fix issues
- **Feature enhancements** - Improve existing functionality
- **New features** - Add new capabilities
- **Documentation** - Improve guides, examples, and documentation
- **Testing** - Add or improve test coverage
- **Security** - Report security issues or improve security measures

### Before You Start

1. **Check existing issues** - Look for existing issues or discussions
2. **Create an issue** - For new features or significant changes, create an issue first
3. **Fork the repository** - Work on your own fork
4. **Follow conventions** - Use our coding and naming conventions

## 🚀 Getting Started

### 1. Fork and Clone

```bash
# Fork the repository on GitHub, then clone your fork
git clone https://github.com/YOUR_USERNAME/redducklabs-runners.git
cd redducklabs-runners

# Add upstream remote
git remote add upstream https://github.com/redducklabs/redducklabs-runners.git
```

### 2. Set Up Development Environment

```bash
# Install required tools
# - bash, git, jq, python3 with PyYAML (offline test suites)
# - helm 3 (CI pins v3.21.4; test/verify-runner-resources.sh renders the chart)
# - shellcheck and actionlint (the linters Validate Config runs)
# - docker (only for runner image changes)
# - gpg (only for test/verify-aws-key-expiry.sh)
# - kubectl within one minor version of the cluster (CI pins v1.36.3) and
#   doctl, only for the live checks against a running fleet
```

No `.env` file or token is needed for the offline suites, the linters, or a
Docker build. No script reads `.env`; `.env.example` only documents the
variable names. The live checks and the local operational scripts read
`GITHUB_TOKEN` and other settings from your shell environment. They use your
current kube context, except `scripts/scale-runners.sh`, which switches to
`$CLUSTER_CONTEXT` (default: the production context
`do-sfo3-redducklabs-cluster`), and `deploy/deploy.sh` (see "Testing Locally").

Most scripts are committed without the executable bit (`git ls-files -s`). Run
them with `bash <path>` (as in the examples below) or `chmod +x` them locally;
CI does the same.

### 3. Create a Branch

```bash
# Create a feature branch
git checkout -b feature/your-feature-name

# Or for bug fixes
git checkout -b fix/issue-description
```

## 📝 Development Guidelines

### Code Style

**Shell Scripts:**
- Use `#!/bin/bash` for all shell scripts
- Include `set -euo pipefail` for error handling (most current scripts do)
- Use UPPER_CASE names for configuration and environment variables
- Add comments explaining complex logic
- Include help/usage functions
- Scripts must pass `bash -n` and `shellcheck -S error`; Validate Config runs
  both on every PR that touches `scripts/`, `test/`, `deploy/` or workflows
- Put shared shell and Python helpers in `scripts/lib/`

**Example:**
```bash
#!/bin/bash
# Description of what this script does

set -euo pipefail

# Configuration
NAMESPACE="arc-runners"
RELEASE_NAME="redducklabs-runners"

# Function to show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help    Show this help message"
}

# Function to check prerequisites
check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed"
        exit 1
    fi
}
```

**YAML Files:**
- Use 2-space indentation
- Include comments explaining configuration options
- Group related settings together
- Use descriptive names for resources

**Documentation:**
- Use clear, concise language
- Include code examples
- Update relevant documentation when making changes
- Use markdown formatting consistently

### File Structure

Follow the established directory structure:

```
redducklabs-runners/
├── docker/                    # Docker configurations
│   ├── Dockerfile.custom-runner
│   ├── aws-cli-public.key     # AWS CLI signing key (public, committed)
│   ├── build-and-push.sh      # Production scripts
│   └── *.template.sh          # Template scripts
├── deploy/                    # Deployment configurations
│   ├── deploy.sh              # Production scripts
│   ├── *.yaml                 # Production configs (values, fence, network policy)
│   ├── trusted-runner-repositories.txt
│   └── *.template.*           # Template configs
├── scripts/                   # Management and workflow scripts
│   └── lib/                   # Shared shell and Python helpers
├── test/                      # Testing scripts
│   ├── fixtures/              # Canned CLI output for the offline suites
│   └── lib/                   # Test helpers
├── docs/                      # Documentation, runbooks, specs and plans
├── claude_help/               # Review process for Claude/Codex workflows
└── .github/
    ├── actions/setup-tools/   # Shared tool-install action
    └── workflows/             # CI/CD workflows
```

### Naming Conventions

**Files:**
- Use kebab-case for file names: `scale-runners.sh`
- Use `.template.` for template files: `deploy.template.sh`
- Use descriptive names that indicate purpose

**Variables:**
- Use UPPER_CASE for environment variables: `GITHUB_TOKEN`
- Use lowercase for local variables: `pod_name`
- Use meaningful names: `runner_count` not `rc`

**Resources:**
- Use consistent naming: `redducklabs-runners`
- Include organization prefix for clarity
- Use descriptive labels and annotations

## 🧪 Testing

### Before Submitting

1. **Test your changes** - Ensure everything works as expected
2. **Run existing tests** - Make sure you haven't broken anything
3. **Add new tests** - For new features or bug fixes

### Testing Locally

Run everything from the repository root. These need no cluster, DigitalOcean
or GitHub credentials; Validate Config runs the same suites on PRs:

```bash
# Offline suites (helm, jq and python3 with PyYAML). verify-runner-resources.sh
# also needs network access to ghcr.io to pull the pinned ARC chart.
bash test/verify-runner-resources.sh
bash test/verify-runner-version-guard.sh
bash test/verify-burst-autoscaling.sh
bash test/verify-acceptance.sh

# Linters, as Validate Config runs them
for s in scripts/*.sh scripts/lib/*.sh test/*.sh deploy/*.sh docs/codex/*.sh; do bash -n "$s"; done
shellcheck -S error scripts/*.sh scripts/lib/*.sh test/*.sh deploy/*.sh
actionlint -shellcheck= -pyflakes= .github/workflows/*.yml

# Render the runner scale set offline (pinned chart, placeholder credentials)
helm template redducklabs-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version 0.14.2 \
  --kube-version 1.36.3 \
  -f deploy/dind-values.yaml \
  --set githubConfigSecret.github_token=PLACEHOLDER \
  --set controllerServiceAccount.name=arc-gha-rs-controller \
  --set controllerServiceAccount.namespace=arc-systems
```

On Windows, `verify-burst-autoscaling.sh` and `verify-acceptance.sh` refuse to
run under Git Bash; run the suites in WSL against an LF clone as described in
`CLAUDE.md` ("Running the test suites locally on Windows").

For runner image changes (Build and Push Runner Image runs these on PRs that
touch the image files):

```bash
docker build -t test-runner -f docker/Dockerfile.custom-runner docker/
bash test/verify-cve-floor.sh test-runner
bash test/verify-aws-key-expiry.sh docker/aws-cli-public.key
```

Do not use `deploy/deploy.sh` to test: it takes no options (`--dry-run` is
ignored), switches to the production context and runs a real
`helm upgrade --install` outside the CI gates. Deployment changes are tested
with the offline suites above and rolled out only through the Deploy GitHub
Runners workflow.

### Testing in Kubernetes

These live checks run against the fleet in your current kube context. They do
not change the release or the scale set, but they `kubectl exec` into a runner
pod (`verify-tools.sh` also starts a throwaway container in its dind daemon,
and `verify-security-fixes.sh` runs Trivy scans there). They need access to a
cluster with runners deployed, which outside contributors normally do not
have; maintainers run them as needed.

```bash
kubectl config use-context your-test-cluster
kubectl config current-context

# Release, scale set and runner pod health
bash test/test-deployment.sh

# Tools in a running runner pod, and the security fixes
bash test/verify-tools.sh
bash test/verify-security-fixes.sh
```

## 📋 Pull Request Process

### 1. Prepare Your PR

```bash
# Update your fork
git fetch upstream
git checkout main
git merge upstream/main

# Rebase your feature branch
git checkout feature/your-feature-name
git rebase main

# Push to your fork
git push origin feature/your-feature-name
```

### 2. Create Pull Request

1. **Create PR** on GitHub from your fork
2. **Describe the change** - There is no PR template; say what changed, why,
   and which tests you ran
3. **Reference issues** - Link to related issues
4. **Use a conventional title** - Prefix commits and the PR title with `feat:`,
   `fix:`, `docs:`, `chore:`, `test:` or `ci:`

### 3. PR Requirements

**Required:**
- [ ] Clear description of changes
- [ ] Tests pass (if applicable)
- [ ] Documentation updated
- [ ] No merge conflicts
- [ ] Follows coding conventions

**Optional but Recommended:**
- [ ] Screenshots for UI changes
- [ ] Performance impact assessment
- [ ] Security implications noted
- [ ] Backward compatibility considered

### 4. Review Process

1. **Automated checks** - Path-filtered checks run on GitHub-hosted runners:
   - **Validate Config** for changes under `deploy/`, `scripts/`, `test/`,
     `.github/workflows/` or `.github/actions/`: YAML syntax, the
     GitHub-hosted runner policy (every workflow job must use a literal
     `runs-on: ubuntu-latest`), actionlint, `bash -n`, shellcheck, the offline
     suites, ARC chart pin agreement, and a tracked-secrets check
   - **Build and Push Runner Image** for changes to the Dockerfile, its build
     script, the AWS CLI key, `.trivyignore`, or the image test scripts: a
     validation build with a smoke test, the AWS key expiry check, the CVE
     floor gate and a report-only Trivy scan (nothing is pushed from a PR)
   - A documentation-only PR triggers no checks
2. **Code review** - Maintainers review your code. Significant specs, plans
   and PRs also go through an independent Codex review
   ([`claude_help/codex-review-process.md`](../claude_help/codex-review-process.md))
3. **Feedback** - Address any comments or suggestions
4. **Approval** - Get approval from maintainers
5. **Merge** - PR is merged into main branch

## 🐛 Bug Reports

### Before Reporting

1. **Search existing issues** - Check if bug is already reported
2. **Try latest version** - Ensure you're using the latest code
3. **Minimal reproduction** - Create a minimal example

### Bug Report Template

```markdown
**Describe the bug**
A clear description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Run command '...'
2. See error

**Expected behavior**
What you expected to happen.

**Environment:**
- OS: [e.g. Ubuntu 24.04]
- kubectl version: [e.g. 1.36.3]
- helm version: [e.g. 3.21.4]
- Kubernetes version: [e.g. 1.36.3]

**Additional context**
- Logs
- Configuration files
- Screenshots
```

## 💡 Feature Requests

### Before Requesting

1. **Check existing issues** - Feature might already be planned
2. **Consider alternatives** - Are there existing solutions?
3. **Provide use case** - Explain why this is needed

### Feature Request Template

```markdown
**Is your feature request related to a problem?**
A clear description of the problem.

**Describe the solution you'd like**
A clear description of what you want to happen.

**Describe alternatives you've considered**
Alternative solutions or features you've considered.

**Use case**
Specific scenarios where this would be useful.

**Additional context**
Any other context or screenshots.
```

## 🔒 Security Issues

**Do not report security issues in public issues!**

For security vulnerabilities:
1. Email: security@redducklabs.com
2. Provide detailed information
3. Allow time for response and fix
4. Follow responsible disclosure

## 📚 Development Resources

### Useful Commands

```bash
# Development cluster setup
kubectl config use-context development-cluster

# Quick testing (scale-runners.sh switches to $CLUSTER_CONTEXT, which
# defaults to the production context; set it for another cluster)
CLUSTER_CONTEXT=development-cluster bash scripts/scale-runners.sh status
bash test/test-deployment.sh

# Docker development
docker build -t dev-runner -f docker/Dockerfile.custom-runner docker/
docker run --rm dev-runner python3 --version

# Helm development: use the full offline render from "Testing Locally"
# (pinned --version and placeholder credentials)
```

### Documentation

- [GitHub Actions Runner Controller](https://github.com/actions/actions-runner-controller)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Helm Documentation](https://helm.sh/docs/)
- [Docker Documentation](https://docs.docker.com/)

### Tools

- **Linting:** Use shellcheck for shell scripts
- **Testing:** Test scripts in isolated environments
- **Validation:** Use kubeconform for Kubernetes manifests

## 🎉 Recognition

Contributors will be recognized in:
- Release notes for significant contributions
- Special mentions for security reports

## 🆘 Getting Help

If you need help:

1. **Check documentation** - README, setup guides, etc.
2. **Search issues** - Someone might have had similar problems
3. **Create an issue** - Ask for help with clear details
4. **Contact maintainers** - For urgent issues

## 📝 License

By contributing, you agree that your contributions will be licensed under the same license as the project (MIT License).

## 🚀 Development Workflow Summary

1. **Fork** the repository
2. **Create** a feature branch
3. **Make** your changes
4. **Test** thoroughly
5. **Document** your changes
6. **Submit** a pull request
7. **Respond** to feedback
8. **Celebrate** when merged! 🎉

Thank you for contributing to Red Duck Labs GitHub Actions Runners!