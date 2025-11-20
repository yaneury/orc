#!/usr/bin/env bash

ENV_FILE="$HOME/.twyk.env"

# Check if the .env file exists
if [ -f "$ENV_FILE" ]; then
    # Read the .env file line by line
    while IFS='=' read -r key value; do
        # Export each key-value pair as an environment variable
        export "$key"="$value"
    done < "$ENV_FILE"
else
    echo "Error: .env file not found at $ENV_FILE"
fi

if [[ -z "${TWYK_USER}" || -z "${TWYK_HOST}" || -z "${TWYK_SOURCE}" || -z "${TWYK_DESTINATION}" ]]; then
    echo "Error: TWYK_USER, TWYK_HOST, and TWYK_MEMORIES environment variables are not set."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to proceed."
    exit 1
fi

if ! command -v heif-convert &> /dev/null; then
    echo "Error: heif-convert is not installed. Please install heif-convert to proceed."
    exit 1
fi

usage() {
    echo "Usage: $0 {connect|reboot|shutdown|sleep|wake|sync|update|debug}"
    exit 1
}

function connect() {
  ssh "$TWYK_USER@$TWYK_HOST"
}

function reboot() {
  invoke "sudo reboot"
}

function shutdown() {
  invoke "shutdown now"
}

function wake() {
    invoke "xset -d :0 dpms force on"
    invoke "sudo reboot"
}

function sleep() {
    invoke "xset -d :0 dpms force off"
}

function sync() {
    # Navigate to staging directory
    cd $TWYK_STAGING

    # Recursively find and copy all image files from source to staging (flattens directory structure)
    find "$TWYK_SOURCE" -type f \( -iname "*.heic" -o -iname "*.jpg" -o -iname "*.jpeg" \) -exec cp {} "$TWYK_STAGING/" \;

    # Process HEIC files: rename to lowercase and convert to JPEG
    for filename in *.heic *.HEIC; do
        [ -e "$filename" ] || continue
        new_filename=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
        if [ "$filename" != "$new_filename" ]; then
            mv -f "$filename" "$new_filename" || return 1
            echo "Renamed: $filename -> $new_filename"
        fi
        heif-convert "$new_filename" "${new_filename%.*}.jpeg"
    done

    # Clean up original HEIC files after conversion
    rm -f *.heic

    # Transfer all files (JPEGs only) to remote host, excluding HEIC and DS_Store files
    rsync -avz --exclude='*.heic' --exclude='.DS_Store' $TWYK_STAGING $TWYK_USER@$TWYK_HOST:$TWYK_DESTINATION
}

function build_and_deploy() {
    cd $TWYK_REPO
    version=$(jq -r '.version' package.json)
    target_dir="$(pwd)/src-tauri/target/aarch64-unknown-linux-gnu"
    build_mode=$1
    target="$target_dir/$build_mode/bundle/deb/twyk_${version}_arm64.deb"
    
    PKG_CONFIG_SYSROOT_DIR=/usr/aarch64-linux-gnu/ cargo tauri build --target aarch64-unknown-linux-gnu --bundles deb --$build_mode && \
    scp "$target" "$TWYK_USER@$TWYK_HOST:/tmp/twyk.deb" && \
    invoke "sudo dpkg -i /tmp/twyk.deb" && \
    invoke "rm /tmp/twyk.deb" && \
    invoke "sudo reboot"
}

function invoke() {
  local command=$1

  ssh "$TWYK_USER@$TWYK_HOST" "$command"
}

if [ $# -eq 0 ]; then
    usage
fi

# Handle subcommands using a case statement
case $1 in
    "sleep")
        sleep
        ;;
    "wake")
        wake
        ;;
    "connect")
        connect
        ;;
    "reboot")
        reboot
        ;;
    "shutdown")
        shutdown
        ;;
    "sync")
        sync
        ;;
    "update")
        build_and_deploy "release"
        ;;
    "debug")
        build_and_deploy "debug"
        ;;
    *)
        echo "Invalid subcommand"
        usage
        ;;
esac
