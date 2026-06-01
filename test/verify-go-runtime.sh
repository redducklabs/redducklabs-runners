#!/bin/bash

# Test script to verify Go runtime is available in the custom runner image
# This script tests the critical fix for Go runtime availability

set -euo pipefail

echo "🧪 Testing Go runtime availability in custom runner image..."

# Function to run test in container
test_go_in_container() {
    local container_name="test-runner-go-runtime"
    
    echo "🔧 Starting test container..."
    
    # Run container in detached mode
    docker run -d --name "$container_name" redducklabs/custom-runner:latest sleep 3600 || {
        echo "❌ Failed to start test container"
        return 1
    }
    
    # Function to cleanup container
    cleanup() {
        echo "🧹 Cleaning up test container..."
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
    }
    
    # Set trap to ensure cleanup
    trap cleanup EXIT
    
    echo "✅ Test container started successfully"
    
    # Test 1: Verify Go binary exists and is executable
    echo "🔍 Test 1: Checking Go binary availability..."
    if docker exec "$container_name" which go >/dev/null 2>&1; then
        echo "✅ Go binary found in PATH"
    else
        echo "❌ Go binary not found in PATH"
        return 1
    fi
    
    # Test 2: Check Go version matches expected version
    echo "🔍 Test 2: Checking Go version..."
    GO_VERSION_ACTUAL=$(docker exec "$container_name" go version | awk '{print $3}' | sed 's/go//')
    GO_VERSION_EXPECTED="1.26.3"
    
    if [[ "$GO_VERSION_ACTUAL" == "$GO_VERSION_EXPECTED" ]]; then
        echo "✅ Go version correct: $GO_VERSION_ACTUAL"
    else
        echo "❌ Go version mismatch. Expected: $GO_VERSION_EXPECTED, Got: $GO_VERSION_ACTUAL"
        return 1
    fi
    
    # Test 3: Verify Go environment variables are set
    echo "🔍 Test 3: Checking Go environment variables..."
    
    GOROOT=$(docker exec "$container_name" printenv GOROOT)
    GOPATH=$(docker exec "$container_name" printenv GOPATH)
    
    if [[ "$GOROOT" == "/usr/local/go" ]]; then
        echo "✅ GOROOT correctly set: $GOROOT"
    else
        echo "❌ GOROOT incorrect. Expected: /usr/local/go, Got: $GOROOT"
        return 1
    fi
    
    if [[ "$GOPATH" == "/home/runner/go" ]]; then
        echo "✅ GOPATH correctly set: $GOPATH"
    else
        echo "❌ GOPATH incorrect. Expected: /home/runner/go, Got: $GOPATH"
        return 1
    fi
    
    # Test 4: Test basic Go functionality
    echo "🔍 Test 4: Testing Go compilation..."
    
    # Create a simple Go program
    docker exec "$container_name" sh -c 'echo "package main; import \"fmt\"; func main() { fmt.Println(\"Go runtime working!\") }" > /tmp/test.go'
    
    # Compile and run the program
    if docker exec "$container_name" go run /tmp/test.go | grep -q "Go runtime working!"; then
        echo "✅ Go compilation and execution working"
    else
        echo "❌ Go compilation or execution failed"
        return 1
    fi
    
    # Test 5: Verify Go workspace permissions
    echo "🔍 Test 5: Checking Go workspace permissions..."
    
    if docker exec --user runner "$container_name" test -w /home/runner/go; then
        echo "✅ Go workspace writable by runner user"
    else
        echo "❌ Go workspace not writable by runner user"
        return 1
    fi
    
    # Test 6: Test go mod functionality (critical for CI workflows)
    echo "🔍 Test 6: Testing go mod functionality..."
    
    docker exec --user runner "$container_name" sh -c 'cd /home/runner && mkdir -p test-project && cd test-project'
    
    if docker exec --user runner "$container_name" sh -c 'cd /home/runner/test-project && go mod init test-project' >/dev/null 2>&1; then
        echo "✅ go mod init working"
    else
        echo "❌ go mod init failed"
        return 1
    fi
    
    # Test 7: Verify no cached modules (security requirement)
    echo "🔍 Test 7: Verifying no cached test fixtures or modules..."
    
    CACHED_MODULES=$(docker exec "$container_name" find /usr/local/go -name "testdata" -o -name "*_test.go" -o -name "*.pem" -o -name "*.key" 2>/dev/null | wc -l)
    
    if [[ "$CACHED_MODULES" -eq 0 ]]; then
        echo "✅ No cached modules or test fixtures found"
    else
        echo "❌ Found $CACHED_MODULES cached modules or test fixtures"
        echo "🔍 Listing found items:"
        docker exec "$container_name" find /usr/local/go -name "testdata" -o -name "*_test.go" -o -name "*.pem" -o -name "*.key" 2>/dev/null || true
        return 1
    fi
    
    echo "🎉 All Go runtime tests passed!"
    return 0
}

# Check if Docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker not found. Please install Docker to run tests."
    exit 1
fi

# Check if the image exists
if ! docker images redducklabs/custom-runner:latest --format "table {{.Repository}}:{{.Tag}}" | grep -q "redducklabs/custom-runner:latest"; then
    echo "❌ Custom runner image not found. Please build the image first:"
    echo "   cd docker && ./build-and-push.sh"
    exit 1
fi

# Run the tests
if test_go_in_container; then
    echo "🎊 SUCCESS: Go runtime fix verified! The runner now has:"
    echo "   ✅ Go 1.26.3 runtime available"
    echo "   ✅ Proper environment variables set"
    echo "   ✅ Clean workspace for runner user"
    echo "   ✅ No cached modules or test fixtures"
    echo "   ✅ Full Go compilation functionality"
    exit 0
else
    echo "💥 FAILURE: Go runtime tests failed!"
    echo "   The fix needs additional work."
    exit 1
fi