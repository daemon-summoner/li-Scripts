#!/bin/bash

# Debug version of ubuntu_setup.sh to identify the exit point

set -euo pipefail

# Color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'
ARROW="➜"

print_status() {
    echo -e "${BLUE}${ARROW}${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

# Check if package is installed with debug
is_package_installed() {
    local package="$1"
    echo "DEBUG: Checking if $package is installed"
    set +e
    dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    local result=$?
    set -e
    echo "DEBUG: Package $package check result: $result"
    return $result
}

# Simple batch install test
test_batch_install() {
    local packages=("vim" "curl" "wget" "nano" "build-essential")
    local total=${#packages[@]}
    local current=0
    
    print_status "Testing batch installation with ${total} packages..."
    
    # Update package cache
    print_status "Updating package cache..."
    set +e
    apt-get update -qq
    local update_result=$?
    set -e
    
    if [ $update_result -ne 0 ]; then
        print_warning "Package cache update failed (exit code: $update_result)"
    else
        print_success "Package cache updated"
    fi
    
    print_status "Checking which packages need installation..."
    
    # Create package list excluding already installed ones
    local to_install=()
    local checked=0
    for package in "${packages[@]}"; do
        ((checked++))
        printf "\rChecking package %d/%d: %s" $checked $total "$package"
        
        set +e
        is_package_installed "$package"
        local is_installed=$?
        set -e
        
        if [ $is_installed -ne 0 ]; then
            to_install+=("$package")
            echo " - NEEDS INSTALL"
        else
            echo " - ALREADY INSTALLED"
            ((current++))
        fi
    done
    echo
    
    if [ ${#to_install[@]} -eq 0 ]; then
        print_success "All packages already installed!"
        return 0
    fi
    
    print_status "Packages to install: ${to_install[*]}"
    
    # Try batch install
    print_status "Attempting batch installation..."
    set +e
    batch_output=$(apt-get install -y -q \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${to_install[@]}" 2>&1)
    local batch_result=$?
    set -e
    
    if [ $batch_result -eq 0 ]; then
        print_success "Batch installation successful!"
        return 0
    else
        print_warning "Batch installation failed (exit code: $batch_result)"
        echo "Error output: $batch_output"
    fi
    
    print_success "Debug test completed successfully!"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    echo "Try: sudo $0"
    exit 1
fi

echo "Starting debug test..."
test_batch_install
echo "Debug test finished - script did not exit unexpectedly!"