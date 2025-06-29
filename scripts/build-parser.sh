#!/bin/bash

set -e

# Configuration
LANGUAGE="$1"
REPO_URL="$2"
REF="${3:-master}"
OUTPUT_DIR="${4:-artifacts}"

if [ -z "$LANGUAGE" ] || [ -z "$REPO_URL" ]; then
    echo "Usage: $0 <language> <repo_url> [ref] [output_dir]"
    exit 1
fi

echo "Building parser for $LANGUAGE from $REPO_URL (ref: $REF)"

# Resolve OUTPUT_DIR to absolute path before changing directories
# Create the output directory if it doesn't exist, then resolve to absolute path
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
echo "Output directory: $OUTPUT_DIR"

# Create temporary directory for cloning
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Clone the repository
echo "Cloning repository..."
git clone --depth 1 --branch "$REF" "$REPO_URL" "$TEMP_DIR/repo"

cd "$TEMP_DIR/repo"

# Get the current commit SHA
COMMIT_SHA=$(git rev-parse HEAD)
echo "Commit SHA: $COMMIT_SHA"

# Find all grammar.js files (excluding node_modules and .build directories)
GRAMMAR_FILES=$(find . -name "grammar.js" -not -path "./node_modules/*" -not -path "./.build/*")

if [ -z "$GRAMMAR_FILES" ]; then
    echo "No grammar.js files found in repository"
    exit 1
fi

echo "Found grammar.js files:"
echo "$GRAMMAR_FILES"

# Install npm dependencies if package.json exists
if [ -f "package.json" ]; then
    echo "Installing npm dependencies..."
    npm install --ignore-scripts --omit dev --omit peer --omit optional
fi

# Build parsers for each grammar.js found
while IFS= read -r grammar_file; do
    grammar_dir=$(dirname "$grammar_file")
    echo "Building parser in directory: $grammar_dir"
    
    cd "$grammar_dir"
    
    # Generate parser if needed
    if command -v tree-sitter >/dev/null 2>&1; then
        echo "Generating parser..."
        tree-sitter generate
    fi
    
    # Determine the actual language name from the directory structure
    # For cases like typescript/tsx subdirectories
    if [ "$grammar_dir" = "." ]; then
        lang_variant="$LANGUAGE"
    else
        # Extract the subdirectory name as variant
        subdir_name=$(basename "$grammar_dir")
        if [ "$subdir_name" = "typescript" ] || [ "$subdir_name" = "tsx" ]; then
            lang_variant="$subdir_name"
        elif [ "$subdir_name" = "php_only" ]; then
            lang_variant="php"
        else
            lang_variant="$LANGUAGE"
        fi
    fi
    
    echo "Building for language variant: $lang_variant"
    
    # Build native library
    echo "Building native library..."
    tree-sitter build --output "parser.so"
    
    # Build WebAssembly (requires emcc, docker, or podman)
    echo "Building WebAssembly..."
    
    # Check if we're on Windows where Docker Linux containers may not work
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]] || [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]]; then
        # On Windows, only try WebAssembly if emcc is directly available
        if command -v emcc >/dev/null 2>&1; then
            tree-sitter build --wasm --output "parser.wasm"
        else
            echo "⚠️  Warning: WebAssembly build skipped on Windows - Docker Linux containers not supported"
            echo "   To build WebAssembly on Windows:"
            echo "   - Install Emscripten directly: https://emscripten.org/docs/getting_started/downloads.html"
        fi
    elif command -v emcc >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
        tree-sitter build --wasm --output "parser.wasm"
    else
        echo "⚠️  Warning: WebAssembly build skipped - requires emcc, docker, or podman"
        echo "   To build WebAssembly:"
        echo "   - Install Emscripten: https://emscripten.org/docs/getting_started/downloads.html"
        echo "   - Or install Docker: https://docs.docker.com/get-docker/"
        echo "   - Or install Podman: https://podman.io/getting-started/installation"
    fi
    
    # Determine platform and architecture
    PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    # Normalize architecture names
    case "$ARCH" in
        x86_64|amd64) ARCH="x64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
    esac
    
    # Normalize platform names and set file extension
    case "$PLATFORM" in
        linux)
            PLATFORM="linux"
            EXT="so"
            ;;
        darwin)
            PLATFORM="darwin"
            EXT="dylib"
            ;;
        mingw*|cygwin*|msys*)
            PLATFORM="win32"
            EXT="dll"
            ;;
        *)
            echo "Unsupported platform: $PLATFORM"
            exit 1
            ;;
    esac
    
    # Create output directory structure
    PARSER_OUTPUT_DIR="$OUTPUT_DIR/$lang_variant/$COMMIT_SHA"
    LATEST_OUTPUT_DIR="$OUTPUT_DIR/$lang_variant/latest"
    mkdir -p "$PARSER_OUTPUT_DIR"
    mkdir -p "$LATEST_OUTPUT_DIR"
    
    # Copy built files
    if [ -f "parser.so" ]; then
        cp "parser.so" "$PARSER_OUTPUT_DIR/$PLATFORM-$ARCH.$EXT"
        echo "Native library saved: $PARSER_OUTPUT_DIR/$PLATFORM-$ARCH.$EXT"
    fi
    
    if [ -f "parser.wasm" ]; then
        cp "parser.wasm" "$PARSER_OUTPUT_DIR/parser.wasm"
        echo "WebAssembly saved: $PARSER_OUTPUT_DIR/parser.wasm"
    fi

    cp -r "$PARSER_OUTPUT_DIR/*" "$LATEST_OUTPUT_DIR"
    
    # Return to repo root
    cd "$TEMP_DIR/repo"
    
done <<< "$GRAMMAR_FILES"

echo "Build completed for $LANGUAGE" 