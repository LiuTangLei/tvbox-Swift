#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="tvbox"
CONFIGURATION="Release"
PROJECT="tvbox.xcodeproj"
EXPORT_OPTIONS="ExportOptions.plist"
OUTPUT_IPA="TVBox.ipa"
BUILD_ROOT="build/package-ios"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
ARCHIVE_PATH="$BUILD_ROOT/tvbox.xcarchive"
EXPORT_PATH="$BUILD_ROOT/exported"
STAGING_DIR="$BUILD_ROOT/staging"
SIGN_MODE="auto"

usage() {
    cat <<'EOF'
Usage: ./package_ios.sh [--unsigned|--signed] [--out PATH]

默认行为:
- 存在 IOS-key/secrets.sh 时，生成已签名 IPA。
- 不存在签名材料时，生成适合 Sideloadly 重签名的 unsigned IPA。

Options:
  --unsigned   强制生成 unsigned IPA
  --signed     强制使用 IOS-key 下的签名材料导出 IPA
  --out PATH   指定输出 IPA 路径，默认 TVBox.ipa
  -h, --help   显示帮助
EOF
}

regenerate_project_if_possible() {
    if command -v xcodegen >/dev/null 2>&1 && [ -f "project.yml" ]; then
        echo "Regenerating project with XcodeGen..."
        xcodegen generate
    else
        echo "跳过 XcodeGen，直接使用现有 tvbox.xcodeproj"
    fi
}

strip_signatures() {
    local app_path="$1"

    find "$app_path" -depth \( \
        -name '*.app' -o \
        -name '*.appex' -o \
        -name '*.framework' -o \
        -name '*.dylib' \
    \) -print0 | while IFS= read -r -d '' path; do
        /usr/bin/codesign --remove-signature "$path" >/dev/null 2>&1 || true
    done

    find "$app_path" \( \
        -name '_CodeSignature' -o \
        -name 'CodeResources' -o \
        -name '*.xcent' \
    \) -print0 | while IFS= read -r -d '' path; do
        rm -rf "$path"
    done
}

build_unsigned_ipa() {
    local products_dir app_path staged_app_path output_path

    echo "开始构建 unsigned iOS app..."
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk iphoneos \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        build

    products_dir="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos"
    app_path="$products_dir/TVBox.app"
    if [ ! -d "$app_path" ]; then
        app_path=$(find "$products_dir" -maxdepth 1 -type d -name '*.app' | head -n 1)
    fi

    if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
        echo "❌ 错误: 未找到已构建的 iOS app 包。"
        exit 1
    fi

    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR/Payload"
    staged_app_path="$STAGING_DIR/Payload/$(basename "$app_path")"

    echo "打包 Payload..."
    ditto "$app_path" "$staged_app_path"
    strip_signatures "$staged_app_path"

    output_path="$PWD/$OUTPUT_IPA"
    rm -f "$output_path"
    (
        cd "$STAGING_DIR"
        /usr/bin/zip -qry "$output_path" Payload
    )

    echo "✅ 已生成 unsigned IPA: $OUTPUT_IPA"
    echo "可直接导入 Sideloadly，由 Sideloadly 进行重签名安装。"
}

build_signed_ipa() {
    local p12_path provision_path ipa_file

    if [ ! -f "IOS-key/secrets.sh" ]; then
        echo "❌ 错误: 未找到 IOS-key/secrets.sh，无法执行 signed 导出。"
        exit 1
    fi

    # shellcheck disable=SC1091
    source "IOS-key/secrets.sh"

    p12_path="IOS-key/cert.p12"
    provision_path="IOS-key/cert.mobileprovision"

    echo "安装 Provisioning Profile..."
    mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
    cp "$provision_path" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROVISION_UUID.mobileprovision"

    echo "导入 P12 证书..."
    security import "$p12_path" -k ~/Library/Keychains/login.keychain-db -P "$P12_PASSWORD" -T /usr/bin/codesign || true
    security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db

    echo "开始构建 signed iOS Archive..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "generic/platform=iOS" \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        PROVISIONING_PROFILE_SPECIFIER="$PROVISION_UUID" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"

    if [ ! -f "$EXPORT_OPTIONS" ]; then
        echo "ℹ️  未找到 $EXPORT_OPTIONS，仅生成 Archive。"
        echo "✅ 构建完成！Archive 路径: $ARCHIVE_PATH"
        echo "您可以打开 Xcode 使用 Distribute App 手动导出 IPA。"
        exit 0
    fi

    echo "发现 $EXPORT_OPTIONS，尝试导出 signed IPA..."
    mkdir -p "$EXPORT_PATH"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH" \
        -allowProvisioningUpdates

    ipa_file=$(find "$EXPORT_PATH" -name '*.ipa' | head -n 1)
    if [ -n "$ipa_file" ]; then
        cp "$ipa_file" "$OUTPUT_IPA"
        echo "✅ 已生成 signed IPA: $OUTPUT_IPA"
    else
        echo "⚠️  未能在导出目录中找到 .ipa 文件。"
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --unsigned)
            SIGN_MODE="unsigned"
            shift
            ;;
        --signed)
            SIGN_MODE="signed"
            shift
            ;;
        --out)
            OUTPUT_IPA="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

echo "清理旧的 iOS 打包产物..."
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$STAGING_DIR"
rm -f "$OUTPUT_IPA"

regenerate_project_if_possible

if [ "$SIGN_MODE" = "auto" ]; then
    if [ -f "IOS-key/secrets.sh" ]; then
        SIGN_MODE="signed"
    else
        SIGN_MODE="unsigned"
    fi
fi

if [ "$SIGN_MODE" = "signed" ]; then
    build_signed_ipa
else
    build_unsigned_ipa
fi
