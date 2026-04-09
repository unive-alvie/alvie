#!/bin/bash

# ALVIE Docker Build and Push Script
# Local automation for building multi-platform Docker images and pushing to Docker Hub
# 
# Usage:
#   ./docker-build.sh [OPTIONS]
#
# Options:
#   --tag TAG          Docker tag to use (default: latest)
#   --push             Push to Docker Hub after building
#   --no-cache         Build without using cache
#   --help             Show this help message
#
# Examples:
#   ./docker-build.sh --tag latest --push
#   ./docker-build.sh --tag v1.0.0 --push
#   ./docker-build.sh --no-cache --push

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
TAG="latest"
PUSH=false
NO_CACHE=""
HELP=false

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_help() {
    cat << EOF
ALVIE Docker Build and Push Script

Usage:
  ./docker-build.sh [OPTIONS]

Options:
  --tag TAG          Docker tag to use (default: latest)
  --push             Push to Docker Hub after building
  --no-cache         Build without using cache
  --help             Show this help message

Examples:
  ./docker-build.sh --tag latest --push
  ./docker-build.sh --tag v1.0.0 --push
  ./docker-build.sh --no-cache --push

Authentication:
  - Uses existing Docker login (docker login)
  - Prompts for Docker Hub username when pushing
  - Requires Docker to be installed and buildx configured

Notes:
  - Local builds: builds for current platform only (amd64, arm64, etc.)
  - With --push: builds for both amd64 and arm64 architectures
  - Requires Docker buildx to be configured
  - Uses layer caching for faster subsequent builds
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tag)
            TAG="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Get Docker Hub username from environment variable or ask
if [ "$PUSH" = true ] && [ -z "$DOCKERHUB_USERNAME" ]; then
    read -p "Enter Docker Hub username: " DOCKERHUB_USERNAME
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify Docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed"
    exit 1
fi

# Verify docker buildx is available
if ! docker buildx version &> /dev/null; then
    print_error "Docker buildx is not available"
    echo "Please install Docker Desktop or set up buildx: https://docs.docker.com/build/install-buildx/"
    exit 1
fi

# Verify credentials if pushing
if [ "$PUSH" = true ]; then
    if [ -z "$DOCKERHUB_USERNAME" ]; then
        print_error "Docker Hub username is required for push"
        exit 1
    fi
    
    # Check if already logged in to Docker
    if ! docker info &> /dev/null; then
        print_warning "Not logged in to Docker. Please log in:"
        docker login
        
        if ! docker info &> /dev/null; then
            print_error "Docker login failed"
            exit 1
        fi
    fi
    print_success "Docker authenticated"
fi

# For local builds without username, use a default image name
if [ -z "$DOCKERHUB_USERNAME" ]; then
    IMAGE_NAME="alvie:$TAG"
else
    IMAGE_NAME="$DOCKERHUB_USERNAME/alvie:$TAG"
fi

print_header "ALVIE Docker Build and Push"
echo "Tag: $TAG"
echo "Image: $IMAGE_NAME"
if [ "$PUSH" = true ]; then
    echo "Platforms: amd64, arm64 (multi-platform)"
else
    # Detect current platform
    CURRENT_ARCH=$(uname -m)
    case $CURRENT_ARCH in
        x86_64) DOCKER_PLATFORM="amd64" ;;
        aarch64) DOCKER_PLATFORM="arm64" ;;
        *) DOCKER_PLATFORM=$CURRENT_ARCH ;;
    esac
    echo "Platform: linux/$DOCKER_PLATFORM (current system)"
fi
echo "Push to Docker Hub: $([ "$PUSH" = true ] && echo 'Yes' || echo 'No')"
echo ""

# Build command
BUILD_CMD="docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t $IMAGE_NAME \
    $NO_CACHE \
    ."

if [ "$PUSH" = true ]; then
    BUILD_CMD="$BUILD_CMD --push"
    print_warning "Building and pushing to Docker Hub..."
else
    print_warning "Building locally for linux/$DOCKER_PLATFORM (use --push to upload to Docker Hub)..."
    BUILD_CMD="docker buildx build \
        --platform linux/$DOCKER_PLATFORM \
        -t $IMAGE_NAME \
        $NO_CACHE \
        --load \
        ."
fi

echo ""
print_warning "Build command:"
echo "$BUILD_CMD"
echo ""

cd "$SCRIPT_DIR"

# Execute build
if eval "$BUILD_CMD"; then
    print_success "Docker build completed successfully!"
    echo ""
    
    if [ "$PUSH" = true ]; then
        print_success "Image pushed to Docker Hub!"
        echo ""
        echo "To pull the image:"
        echo "  docker pull $IMAGE_NAME"
        echo ""
        echo "To run the image:"
        echo "  docker run --rm -it $IMAGE_NAME"
    else
        print_success "Image built locally!"
        echo ""
        echo "To run the image:"
        echo "  docker run --rm -it $IMAGE_NAME"
        echo ""
        echo "To push to Docker Hub later, run:"
        echo "  docker push $IMAGE_NAME"
    fi
else
    print_error "Docker build failed"
    exit 1
fi
