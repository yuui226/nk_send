#!/usr/bin/env bash
# Release archive of the current workspace, then upload to App Store Connect.
# The build becomes available for TestFlight after Apple finishes processing.
# It does not submit App Review and does not release the App Store version.
set -Eeuo pipefail

UPLOAD_STARTED=0
VERSIONS_BUMPED=0
OLD_BUILD=""
YML_BACKUP=""
PBX_BACKUP=""

finish_terminal() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && "$VERSIONS_BUMPED" -eq 1 && "$UPLOAD_STARTED" -eq 0 ]]; then
    cp "$YML_BACKUP" "$PROJECT_YML"
    cp "$PBX_BACKUP" "$PBX"
    printf '\n上传尚未开始，已把构建号恢复为 %s。\n' "$OLD_BUILD" >&2
  fi
  if [[ "$status" -ne 0 ]]; then
    printf '\n正式包上传失败（exit %s）。上面的日志保留在终端中' "$status" >&2
    if [[ -n "${BUILD_DIR:-}" ]]; then
      printf '，副本在 %s' "$BUILD_DIR" >&2
    fi
    printf '。\n' >&2
    if [[ -t 0 ]]; then
      read -r -p '按回车关闭此窗口...' _ || true
    fi
  fi
  exit "$status"
}
trap finish_terminal EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
PROJECT_YML="$PROJECT_ROOT/ios/project.yml"
PBX="$PROJECT_ROOT/ios/ZTransfer.xcodeproj/project.pbxproj"
TEAM_ID="${IOS_DEVELOPMENT_TEAM:-6YY8Y34949}"
APP_ID="6830945574"
DERIVED_DATA="${IOS_RELEASE_DERIVED_DATA:-/tmp/ztransfer-prepay-release-20261102}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "需要在 macOS 上用 Xcode 打正式包。" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "找不到 xcodebuild。请先安装 Xcode，并用 xcode-select 选中它。" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3 来递增构建号并检查发布包。" >&2
  exit 1
fi
if [[ ! -d "$PROJECT_ROOT/ios/ZTransfer.xcodeproj" ]]; then
  echo "找不到 iOS 工程：$PROJECT_ROOT/ios/ZTransfer.xcodeproj" >&2
  exit 1
fi

VERSIONS="$(python3 - "$PROJECT_YML" "$PBX" <<'PY'
import re, sys
from pathlib import Path
yml = Path(sys.argv[1]).read_text()
pbx = Path(sys.argv[2]).read_text()
found = re.findall(r'(?m)^[ \t]*CURRENT_PROJECT_VERSION: "(\d+)"$', yml)
marketing = re.findall(r'(?m)^[ \t]*MARKETING_VERSION: "([^"]+)"$', yml)
pbx_builds = re.findall(r'(?m)^[ \t]*CURRENT_PROJECT_VERSION = (\d+);$', pbx)
pbx_marketing = re.findall(r'(?m)^[ \t]*MARKETING_VERSION = ([^;]+);$', pbx)
if len(found) != 1 or len(marketing) != 1:
    sys.exit("project.yml 里的版本号不唯一，已停止，没有修改文件。")
if len(pbx_builds) != 2 or set(pbx_builds) != {found[0]}:
    sys.exit("project.pbxproj 的构建号没有和 project.yml 对齐，已停止，没有修改文件。")
if len(pbx_marketing) != 2 or set(item.strip() for item in pbx_marketing) != {marketing[0]}:
    sys.exit("营销版本号不一致，已停止，没有修改文件。")
print(found[0])
print(int(found[0]) + 1)
print(marketing[0])
PY
)"
OLD_BUILD="$(printf '%s\n' "$VERSIONS" | sed -n '1p')"
NEW_BUILD="$(printf '%s\n' "$VERSIONS" | sed -n '2p')"
CURRENT_MARKETING="$(printf '%s\n' "$VERSIONS" | sed -n '3p')"
MARKETING_VERSION="$CURRENT_MARKETING"
if [[ -n "${IOS_MARKETING_VERSION:-}" ]]; then
  MARKETING_VERSION="$IOS_MARKETING_VERSION"
elif [[ -t 0 ]]; then
  printf '构建号自动从 %s 加到 %s，不用填写。\n' "$OLD_BUILD" "$NEW_BUILD"
  printf '版本号现在是 %s。直接回车则保持不变，这个包可以进 TestFlight。\n' "$CURRENT_MARKETING"
  printf '已上架的 %s 不能再用相同或更小的版本号提交商店审核。要送审请填更高的版本，例如 2.06。\n' "$CURRENT_MARKETING"
  read -r -p '版本号: ' TYPED_VERSION || true
  if [[ -n "${TYPED_VERSION//[[:space:]]/}" ]]; then
    MARKETING_VERSION="${TYPED_VERSION//[[:space:]]/}"
  fi
fi
MARKETING_VERSION="$(python3 - "$CURRENT_MARKETING" "$MARKETING_VERSION" <<'PY'
import re, sys
current, requested = sys.argv[1:]
if not re.fullmatch(r"\d{1,9}(?:\.\d{1,9}){0,2}", requested):
    sys.exit("版本号须是一到三段非负整数，例如 2.05 或 2.06。已停止，没有修改文件。")

def parts(value):
    return tuple(int(item) for item in value.split("."))

def compare(left, right):
    width = max(len(left), len(right))
    left += (0,) * (width - len(left))
    right += (0,) * (width - len(right))
    return (left > right) - (left < right)

order = compare(parts(requested), parts(current))
if order < 0:
    sys.exit(f"版本号 {requested} 小于当前 {current}。苹果不接受更小的版本。已停止，没有修改文件。")
if order == 0 and requested != current:
    sys.exit(
        f"版本号 {requested} 和当前 {current} 按整数比较是同一个版本（例如 2.05 与 2.5）。"
        "保持不变请直接回车；要送审请填写更高的版本，例如 2.06。"
    )
print(requested)
PY
)"

BUILD_DIR="$PROJECT_ROOT/ios/.build/appstore-$(date +%Y%m%d)/build${NEW_BUILD}"
if [[ -e "$BUILD_DIR" ]]; then
  echo "构建目录已存在，拒绝覆盖：$BUILD_DIR" >&2
  exit 1
fi
mkdir -p "$BUILD_DIR"
YML_BACKUP="$BUILD_DIR/project.yml.before"
PBX_BACKUP="$BUILD_DIR/project.pbxproj.before"
cp "$PROJECT_YML" "$YML_BACKUP"
cp "$PBX" "$PBX_BACKUP"

cat > "$BUILD_DIR/validation-options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>validation</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
cat > "$BUILD_DIR/upload-options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

printf '当前代码将打成正式包 %s（%s），上传到 App Store Connect。\n' "$MARKETING_VERSION" "$NEW_BUILD"
printf '构建号从 %s 递增。上传后进入 TestFlight 处理。\n' "$OLD_BUILD"
printf '不会提交 App 审核，也不会发布 App Store 版本。\n'

VERSIONS_BUMPED=1
python3 - "$PROJECT_YML" "$PBX" "$OLD_BUILD" "$NEW_BUILD" "$CURRENT_MARKETING" "$MARKETING_VERSION" <<'PY'
import re, sys
from pathlib import Path
yml_path, pbx_path, old_build, new_build, old_marketing, new_marketing = sys.argv[1:]
yml = Path(yml_path).read_text()
pbx = Path(pbx_path).read_text()
yml2, build_count = re.subn(
    rf'(?m)^([ \t]*CURRENT_PROJECT_VERSION: "){re.escape(old_build)}(")$',
    rf'\g<1>{new_build}\2',
    yml,
    count=1,
)
pbx2, pbx_build_count = re.subn(
    rf'(?m)^([ \t]*CURRENT_PROJECT_VERSION = ){re.escape(old_build)}(;)$',
    rf'\g<1>{new_build}\2',
    pbx,
)
marketing_count = pbx_marketing_count = 0
if old_marketing != new_marketing:
    yml2, marketing_count = re.subn(
        rf'(?m)^([ \t]*MARKETING_VERSION: "){re.escape(old_marketing)}(")$',
        rf'\g<1>{new_marketing}\2',
        yml2,
        count=1,
    )
    pbx2, pbx_marketing_count = re.subn(
        rf'(?m)^([ \t]*MARKETING_VERSION = ){re.escape(old_marketing)}(;)$',
        rf'\g<1>{new_marketing}\2',
        pbx2,
    )
if build_count != 1 or pbx_build_count != 2:
    sys.exit(f"构建号替换数量异常：yml {build_count}，pbxproj {pbx_build_count}")
if old_marketing != new_marketing and (marketing_count != 1 or pbx_marketing_count != 2):
    sys.exit(f"版本号替换数量异常：yml {marketing_count}，pbxproj {pbx_marketing_count}")
Path(yml_path).write_text(yml2)
Path(pbx_path).write_text(pbx2)
PY

ARCHIVE="$BUILD_DIR/ZTransfer-${MARKETING_VERSION}-${NEW_BUILD}.xcarchive"
cd "$PROJECT_ROOT"
echo "正在归档 Release..."
xcodebuild archive \
  -project "$PROJECT_ROOT/ios/ZTransfer.xcodeproj" \
  -scheme ZTransfer \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE" \
  -resultBundlePath "$BUILD_DIR/archive-result.xcresult" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  2>&1 | tee "$BUILD_DIR/archive.log"
grep -q '\*\* ARCHIVE SUCCEEDED \*\*' "$BUILD_DIR/archive.log"

APP="$ARCHIVE/Products/Applications/ZTransfer.app"
if [[ ! -d "$APP" ]]; then
  echo "归档里没有 ZTransfer.app：$APP" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP"
ARCHIVED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
ARCHIVED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
ENCRYPTION="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$APP/Info.plist")"
if [[ "$ARCHIVED_VERSION" != "$MARKETING_VERSION" || "$ARCHIVED_BUILD" != "$NEW_BUILD" ]]; then
  echo "归档版本是 ${ARCHIVED_VERSION}（${ARCHIVED_BUILD}），与 ${MARKETING_VERSION}（${NEW_BUILD}）不一致。" >&2
  exit 1
fi
if [[ "$ENCRYPTION" != "false" ]]; then
  echo "出口合规标记不是 false，已停止上传。" >&2
  exit 1
fi
python3 "$PROJECT_ROOT/ios/scripts/verify-release-bundle.py" --submission "$APP" \
  > "$BUILD_DIR/bundle-check.json"

echo "正在做 App Store 上传前校验..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$BUILD_DIR/validation-export" \
  -exportOptionsPlist "$BUILD_DIR/validation-options.plist" \
  -allowProvisioningUpdates \
  2>&1 | tee "$BUILD_DIR/validation.log"
grep -q '\*\* EXPORT SUCCEEDED \*\*' "$BUILD_DIR/validation.log"

echo "校验已通过，正在上传 ${MARKETING_VERSION}（${NEW_BUILD}）..."
UPLOAD_STARTED=1
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$BUILD_DIR/upload-export" \
  -exportOptionsPlist "$BUILD_DIR/upload-options.plist" \
  -allowProvisioningUpdates \
  2>&1 | tee "$BUILD_DIR/upload.log"
grep -q 'Upload succeeded' "$BUILD_DIR/upload.log"
grep -q '\*\* EXPORT SUCCEEDED \*\*' "$BUILD_DIR/upload.log"

printf '\n已上传 %s（%s）。\n' "$MARKETING_VERSION" "$NEW_BUILD"
printf 'TestFlight：https://appstoreconnect.apple.com/apps/%s/testflight/ios\n' "$APP_ID"
printf '苹果处理完成前不能安装或选入审核。此脚本没有提交审核，也没有发布商店版本。\n'
printf '日志：%s\n' "$BUILD_DIR"
