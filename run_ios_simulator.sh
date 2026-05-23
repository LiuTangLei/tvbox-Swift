#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="tvbox"
PROJECT="tvbox.xcodeproj"
CONFIGURATION="Debug"
SDK="iphonesimulator"
DERIVED_DATA_PATH="$PWD/build/simulator-derived-data"
BUNDLE_ID="xyz.appinstall.nov.carbon.lam"
SIM_OS="26.4"
DEFAULT_DEVICE_NAMES=(
  "iPhone 17"
  "iPhone 17 Pro"
  "iPhone 17 Pro Max"
  "iPhone 17e"
  "iPhone Air"
  "iPhone 16"
  "iPhone 15"
  "iPhone 14"
  "iPhone SE (4th generation)"
)

usage() {
  cat <<'EOF'
Usage: ./run_ios_simulator.sh [--device-name NAME|--device-udid UDID]

默认会选取可用的 iPhone 模拟器（优先 booted）并构建、安装、启动 TVBox。

Options:
  --device-name NAME   使用指定 iPhone 模拟器名称
  --device-udid UDID   使用指定模拟器 UDID
  -h, --help           显示此帮助信息
EOF
}

find_simulator_by_name() {
  local target_name="$1"
  while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -Fq "$target_name (" && printf '%s\n' "$line" | grep -Eq '(Booted|Shutdown|Shutting Down)\)[[:space:]]*$'; then
      printf '%s\n' "$line" | sed -E 's/^[[:space:]]*[^()]+ \(([A-F0-9-]+)\).*/\1/'
      return 0
    fi
  done < <(xcrun simctl list devices available)
}

find_preferred_simulator() {
  local devices
  devices=$(xcrun simctl list devices available)

  for name in "${DEFAULT_DEVICE_NAMES[@]}"; do
    local udid
    udid=$(find_simulator_by_name "$name") || true
    if [[ -n "$udid" ]]; then
      echo "$name|$udid"
      return 0
    fi
  done

  # 如果默认机型都没找到，则退回到任意可用的 iPhone 模拟器
  while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -Eq '^[[:space:]]*iPhone[^()]+ \([A-F0-9-]+\) \((Booted|Shutdown|Shutting Down)\)[[:space:]]*$'; then
      local name
      local udid
      name=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*([^()]+) \(.*$/\1/')
      udid=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*[^()]+ \(([A-F0-9-]+)\).*/\1/')
      echo "$name|$udid"
      return 0
    fi
  done <<< "$devices"
}

DEVICE_NAME=""
DEVICE_UDID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-name)
      DEVICE_NAME="$2"
      shift 2
      ;;
    --device-udid)
      DEVICE_UDID="$2"
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

if [[ -n "$DEVICE_UDID" ]]; then
  if ! xcrun simctl list devices available | grep -q "$DEVICE_UDID"; then
    echo "❌ 未找到指定 UDID 的可用模拟器: $DEVICE_UDID"
    exit 1
  fi
  TARGET_UDID="$DEVICE_UDID"
  TARGET_NAME="$(xcrun simctl list devices available | grep "$DEVICE_UDID" | sed -E 's/^[[:space:]]*([^()]+) \(.*$/\1/')"
elif [[ -n "$DEVICE_NAME" ]]; then
  TARGET_UDID="$(find_simulator_by_name "$DEVICE_NAME" || true)"
  if [[ -z "$TARGET_UDID" ]]; then
    echo "❌ 未找到指定名称的可用 iPhone 模拟器: $DEVICE_NAME"
    exit 1
  fi
  TARGET_NAME="$DEVICE_NAME"
else
  read -r TARGET_NAME TARGET_UDID <<<"$(find_preferred_simulator | tr '|' ' ')"
  if [[ -z "$TARGET_UDID" ]]; then
    echo "❌ 未找到任何可用的 iPhone 模拟器。请先创建或启动一个 iPhone 模拟器。"
    exit 1
  fi
fi

echo "使用模拟器: $TARGET_NAME ($TARGET_UDID)"

echo "开始构建 tvbox for iPhone simulator..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -destination "platform=iOS Simulator,OS=$SIM_OS,name=$TARGET_NAME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphonesimulator/TVBox.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ 未找到构建产物: $APP_PATH"
  exit 1
fi

echo "确保模拟器已启动..."
xcrun simctl boot "$TARGET_UDID" 2>/dev/null || true

echo "安装 app 到模拟器..."
xcrun simctl install "$TARGET_UDID" "$APP_PATH"

echo "启动 app..."
xcrun simctl launch "$TARGET_UDID" "$BUNDLE_ID"

echo "✅ TVBox 已安装并启动到 $TARGET_NAME ($TARGET_UDID)"