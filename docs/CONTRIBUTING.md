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
# - kubectl (1.24+)
# - helm (3.x)
# - docker
# - doctl (DigitalOcean CLI)

# Set up environment variables
cp .env.example .env
# Edit .env with your development settings

# Set up GitHub token for testing
export GITHUB_TOKEN=ghp_your_development_token
```

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
- Include `set -e` for error handling
- Use meaningful variable names in UPPER_CASE
- Add comments explaining complex logic
- Include help/usage functions

**Example:**
```bash
#!/bin/bash
# Description of what this script does

set -e

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
│   ├── build-and-push.sh      # Production scripts
│   └── *.template.sh          # Template scripts
├── deploy/                    # Deployment configurations
│   ├── deploy.sh              # Production scripts
│   ├── *.yaml                 # Production configs
│   └── *.template.*           # Template configs
├── scripts/                   # Management scripts
├── test/                      # Testing scripts
├── docs/                      # Documentation
└── .github/workflows/         # CI/CD workflows
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

```bash
# Test Docker build
cd docker/
docker build -t test-runner -f Dockerfile.custom-runner .

# Test deployment scripts (dry-run)
cd deploy/
# Edit values for test environment
./deploy.sh --dry-run

# Test management scripts
cd scripts/
./scale-runners.sh status
./test/verify-tools.sh
```

### Testing in Kubernetes

```bash
# Deploy to test cluster
kubectl config use-context your-test-cluster

# Run deployment test
./test/test-deployment.sh

# Verify tools installation
./test/verify-tools.sh
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
2. **Fill out the template** - Provide clear description
3. **Reference issues** - Link to related issues
4. **Add labels** - Use appropriate labels

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

1. **Automated checks** - CI/CD pipeline runs
2. **Code review** - Maintainers review your code
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
- OS: [e.g. Ubuntu 20.04]
- kubectl version: [e.g. 1.25.0]
- helm version: [e.g. 3.10.0]
- Kubernetes version: [e.g. 1.24.0]

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

# Quick testing
./scripts/scale-runners.sh status
./test/test-deployment.sh

# Docker development
docker build -t dev-runner -f docker/Dockerfile.custom-runner docker/
docker run --rm dev-runner python3 --version

# Helm development
helm template redducklabs-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --values deploy/dind-values.yaml
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
- Contributors list in README
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