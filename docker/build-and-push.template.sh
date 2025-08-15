#!/bin/bash
# Build and push custom GitHub runner image with all required tools
# Template version - configure for your organization

set -e

# Load configuration from environment or use defaults
REGISTRY="${REGISTRY_URL:-registry.example.com}"
REPOSITORY="${REGISTRY_NAMESPACE:-your-org}/github-runner"
TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${REGISTRY}/${REPOSITORY}:${TAG}"

echo "Building custom GitHub runner image..."
echo "Image: ${FULL_IMAGE}"

# Build the image
docker build -t "${FULL_IMAGE}" -f Dockerfile.custom-runner .

if [ $? -eq 0 ]; then
    echo "Build successful!"
    
    echo "Pushing image to registry..."
    docker push "${FULL_IMAGE}"
    
    if [ $? -eq 0 ]; then
        echo "Push successful!"
        echo ""
        echo "Image is ready: ${FULL_IMAGE}"
        echo ""
        echo "To deploy, update dind-values.yaml with this image and run:"
        echo "  cd ../deploy && ./deploy.sh"
    else
        echo "Push failed!"
        exit 1
    fi
else
    echo "Build failed!"
    exit 1
fi