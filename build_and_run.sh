#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/Etchost.app"

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
  build [Debug|Release]   xcodegen + xcodebuild 빌드 (기본: Debug)
  test                    swift test 실행
  run [Debug|Release]     빌드 후 ~/Applications에 설치하고 실행 (기본: Debug)
  install                 마지막 빌드 결과를 ~/Applications에 설치 (빌드 안 함)
  lint                    SwiftLint 검사
  clean                   build/ + Etchost.xcodeproj 정리

Examples:
  $0 build
  $0 run
  $0 run Release
EOF
}

build_app() {
    local config="${1:-Debug}"
    echo "Generating Xcode project..."
    (cd "$SCRIPT_DIR" && xcodegen)
    echo "Building $config..."
    xcodebuild build \
        -project "$SCRIPT_DIR/Etchost.xcodeproj" \
        -scheme Etchost \
        -destination 'platform=macOS' \
        -configuration "$config" \
        -derivedDataPath "$BUILD_DIR"
}

find_built_app() {
    find "$BUILD_DIR" -name "Etchost.app" -type d | head -1
}

install_app() {
    local app_path
    app_path="$(find_built_app)"
    if [[ -z "$app_path" ]]; then
        echo "Error: 빌드된 Etchost.app을 찾지 못했습니다. 먼저 '$0 build'를 실행하세요."
        exit 1
    fi
    mkdir -p "$INSTALL_DIR"
    echo "Installing to $INSTALLED_APP ..."
    rm -rf "$INSTALLED_APP"
    cp -R "$app_path" "$INSTALLED_APP"
    echo "Installed."
}

launch_app() {
    echo "Stopping any existing Etchost..."
    pkill -f "Etchost.app" 2>/dev/null || true
    sleep 0.5
    echo "Launching $INSTALLED_APP ..."
    open "$INSTALLED_APP"
}

run_tests() {
    echo "Running swift tests..."
    (cd "$SCRIPT_DIR" && swift test)
}

run_lint() {
    echo "Running SwiftLint..."
    (cd "$SCRIPT_DIR" && swiftlint --config ".swiftlint.yml")
}

clean_build() {
    echo "Cleaning..."
    rm -rf "$BUILD_DIR" "$SCRIPT_DIR/Etchost.xcodeproj"
}

main() {
    local command="${1:-}"
    shift || true
    case "$command" in
        build)
            build_app "${1:-Debug}"
            ;;
        test)
            run_tests
            ;;
        run | debug)
            build_app "${1:-Debug}"
            install_app
            launch_app
            ;;
        install)
            install_app
            ;;
        lint)
            run_lint
            ;;
        clean)
            clean_build
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
