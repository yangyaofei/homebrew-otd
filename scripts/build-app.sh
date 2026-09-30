#!/bin/bash
# 构建 OpenTabletDriver-BT.app + PenAssist 插件，并打包签名。
# 本地与 GitHub Actions 共用此脚本。
#
# 环境变量：
#   OTD_REF        OTD fork 分支/tag（默认 pr4672-bluetooth-macos）
#   PENASSIST_REF  PenAssist 分支/tag（默认 master）
#   VERSION        版本号（默认 日期+短 SHA）
#   CERT_FILE      签名 p12 路径   （默认 <repo>/certs/otd-bt-dev-10y.p12）
#   CERT_PW_FILE   签名密码文件    （默认 <repo>/certs/otd-bt-dev-10y.pw）
#   WORK_DIR       工作目录        （默认 <repo>/tmp/build）
# 产物：tmp/dist/otd-bt-<VERSION>.zip（内含 .app + PenAssist.dll）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OTD_REF="${OTD_REF:-pr4672-bluetooth-macos}"
PENASSIST_REF="${PENASSIST_REF:-master}"
VERSION="${VERSION:-$(date +%Y.%-m.%-d)-$(git ls-remote https://github.com/yangyaofei/OpenTabletDriver.git "$OTD_REF" | head -c 7)}"
[ -n "$VERSION" ] || VERSION="$(date +%Y.%-m.%-d)"
CERT_FILE="${CERT_FILE:-$ROOT/certs/otd-bt-dev-10y.p12}"
CERT_PW_FILE="${CERT_PW_FILE:-$ROOT/certs/otd-bt-dev-10y.pw}"
WORK_DIR="${WORK_DIR:-$ROOT/tmp/build}"
DIST="$ROOT/tmp/dist"
BUNDLE_ID="io.github.yangyaofei.otd-bt"

command -v dotnet >/dev/null 2>&1 || export PATH="$HOME/.dotnet:$PATH"
RCODESIGN="${RCODESIGN:-$HOME/.local/bin/rcodesign}"

echo "== otd-bt build: VERSION=$VERSION OTD_REF=$OTD_REF PENASSIST_REF=$PENASSIST_REF"

mkdir -p "$WORK_DIR" "$DIST"
cd "$WORK_DIR"

# 1) 源码
[ -d OpenTabletDriver/.git ] || git clone https://github.com/yangyaofei/OpenTabletDriver.git
git -C OpenTabletDriver fetch -q origin && git -C OpenTabletDriver checkout -q --detach "origin/$OTD_REF" 2>/dev/null || git -C OpenTabletDriver checkout -q "$OTD_REF"
OTD_SHA=$(git -C OpenTabletDriver rev-parse --short HEAD)

[ -d PenAssist/.git ] || git clone --recursive https://github.com/yangyaofei/PenAssist.git
git -C PenAssist fetch -q origin && git -C PenAssist checkout -q --detach "origin/$PENASSIST_REF" 2>/dev/null || git -C PenAssist checkout -q "$PENASSIST_REF"
git -C PenAssist submodule update --init --recursive
PEN_SHA=$(git -C PenAssist rev-parse --short HEAD)

[ -d HIDSharpCore/.git ] || git clone https://github.com/OpenTabletDriver/HIDSharpCore.git
git -C HIDSharpCore fetch -q origin
git -C HIDSharpCore reset -q --hard origin/HEAD
git -C HIDSharpCore clean -qfd
git -C HIDSharpCore apply "$WORK_DIR/OpenTabletDriver/patches/hidsharp-macos-bluetooth.patch"

echo "== refs: otd=$OTD_SHA penassist=$PEN_SHA"

# 2) HidSharp 补丁版
rm -rf HIDSharpCore/HidSharp/bin HIDSharpCore/HidSharp/obj
dotnet build HIDSharpCore/HidSharp/HidSharp.csproj -c Release
HID_DLL="HIDSharpCore/HidSharp/bin/Release/net8.0/HidSharpCore.dll"
[ -f "$HID_DLL" ] || { echo "FATAL: HidSharpCore.dll 未产出"; exit 1; }

# 3) PenAssist 插件
dotnet build PenAssist/PenAssist -c Release
PEN_DLL="PenAssist/PenAssist/bin/Release/net10.0/PenAssist.dll"
[ -f "$PEN_DLL" ] || { echo "FATAL: PenAssist.dll 未产出"; exit 1; }

# 4) OTD 自包含发布 + 覆盖补丁 dll
cd OpenTabletDriver
rm -rf bin/otd-sc
dotnet restore OpenTabletDriver.sln --runtime osx-x64
for p in OpenTabletDriver.Daemon OpenTabletDriver.Console OpenTabletDriver.UX.MacOS; do
    dotnet publish "$p" -c Release -r osx-x64 --no-restore --self-contained true -p:UseSharedCompilation=false -o ./bin/otd-sc
done
cp "../$HID_DLL" bin/otd-sc/HidSharpCore.dll
cd "$WORK_DIR"

# 5) 组装 .app
APP="OpenTabletDriver-BT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R OpenTabletDriver/bin/otd-sc/. "$APP/Contents/MacOS/"
# publish 会在 MacOS/ 里生成一个冗余的嵌套 .app（同一套 dll 的副本），
# rcodesign 严格校验拒绝这种布局，且主程序实际使用散装文件——删除。
rm -rf "$APP/Contents/MacOS/OpenTabletDriver.UX.MacOS.app"
cp OpenTabletDriver/eng/bash/macos/Icon.icns "$APP/Contents/Resources/"
cp OpenTabletDriver/eng/bash/macos/Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# 6) 签名：逐个 Mach-O 可执行文件（bundle 级封条不需要——brew 无隔离标志，
#    Gatekeeper 不介入；TCC 按「identifier+证书」记在进程签名上，两者跨版本不变）
#    .NET 平铺布局与 rcodesign 的 bundle 严格规则冲突（MacOS/ 只许 Mach-O），
#    逐二进制签名是两者兼容的唯一方案。
declare -a EXES=(OpenTabletDriver.UX.MacOS OpenTabletDriver.Daemon OpenTabletDriver.Console createdump)
for exe in "${EXES[@]}"; do
    target="$APP/Contents/MacOS/$exe"
    [ -f "$target" ] || continue
    ident="$BUNDLE_ID"
    [ "$exe" = "OpenTabletDriver.Daemon" ] && ident="$BUNDLE_ID.daemon"
    [ "$exe" = "OpenTabletDriver.Console" ] && ident="$BUNDLE_ID.console"
    [ "$exe" = "createdump" ] && ident="$BUNDLE_ID.createdump"
    "$RCODESIGN" sign --p12-file "$CERT_FILE" --p12-password-file "$CERT_PW_FILE" \
        --binary-identifier "$ident" "$target"
done
echo "== 签名信息:"
for exe in "${EXES[@]}"; do
    codesign -dvvv "$APP/Contents/MacOS/$exe" 2>&1 | grep -E "Identifier=|Authority=" | head -2
done

# 7) 打包（一个 zip：app + 插件 dll + 安装说明）
ZIP="otd-bt-$VERSION.zip"
rm -f "$DIST/$ZIP"
STAGE="$WORK_DIR/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$PEN_DLL" "$STAGE/PenAssist.dll"
cat > "$STAGE/INSTALL.txt" << EOF
OpenTabletDriver-BT $VERSION (otd $OTD_SHA, penassist $PEN_SHA)

1. 拖动 OpenTabletDriver-BT.app 到 /Applications（或用 brew cask 安装）
2. PenAssist.dll 放到 ~/Library/Application Support/OpenTabletDriver/Plugins/PenAssist/
   （brew cask 自动完成）
3. 首次运行需在 系统设置→隐私与权限 授权：辅助功能、输入监控
EOF
cd "$STAGE" && ditto -c -k --sequesterRsrc OpenTabletDriver-BT.app PenAssist.dll INSTALL.txt "$DIST/$ZIP" 2>/dev/null || zip -qr "$DIST/$ZIP" OpenTabletDriver-BT.app PenAssist.dll INSTALL.txt
cd "$WORK_DIR"

echo "== SHA256:"
shasum -a 256 "$DIST/$ZIP"
echo "== DONE: $DIST/$ZIP"
