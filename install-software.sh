#!/bin/bash

install_dnf() {
    success=false
    attempt=1
    max_attempts=5
    while [ $success = false ] && [ $attempt -le $max_attempts ]; do
        echo "Installing $1 - Attempt #$attempt"
        
        sudo dnf --assumeyes --quiet install $1 
        if [ $? != 200 ]; then
            success=true
        else
            # lock error, retry
            ((attempt++))
            sleep 5
        fi
    done

    if [ $success = false ]; then
        echo "Failed to install $1 after $max_attempts attempts"
        exit 1
    fi
}

# Many of these are already installed, but check any
install_dnf "git"
install_dnf "powershell"
install_dnf "dotnet-sdk-8.0"
install_dnf "dotnet-sdk-9.0"
install_dnf "dotnet-sdk-10.0"