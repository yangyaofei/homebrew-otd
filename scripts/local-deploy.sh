#!/bin/bash
# 本地迭代部署：publish → 组装 → 签名(与 build-app.sh 完全同一方式) → 安装 → 重启
# 用法: ./local-deploy.sh [版本号]   (默认 0.0.0-local.时间戳)
# 签名恒定 → 重编译后不再需要重新授权
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OTD_SRC="${OTD_SRC:-$HOME/workspace/OpenTabletDriver/OpenTabletDriver}"
HIDSHARP_DLL="${HIDSHARP_DLL:-$HOME/workspace/research-plan/otd-tablet/day-04-bluetooth/artifacts/hidsharpcore/HidSharp/bin/Release/net8.0/HidSharpCore.dll}"
STAGE="$ROOT/stage"
APP_NAME=OpenTabletDriver-BT.app
VERSION="${1:-0.0.0-local.$(date +%Y%m%d%H%M)}"
IDENTITY=io.github.yangyaofei.otd-bt
CERT_FILE="$ROOT/certs/otd-bt-dev-10y.p12"
CERT_PW_FILE="$ROOT/certs/otd-bt-dev-10y.pw"
RCSIGN="$HOME/.local/bin/rcodesign"

export PATH="$HOME/.dotnet:$PATH"

echo "==> publish (RID=osx-x64)"
( cd "$OTD_SRC" && dotnet restore OpenTabletDriver.sln --runtime osx-x64 )
mkdir -p "$STAGE/bin"
for p in OpenTabletDriver.Daemon OpenTabletDriver.Console OpenTabletDriver.UX.MacOS; do
  dotnet publish "$OTD_SRC/$p" -c Release -r osx-x64 --no-restore --self-contained true \
    -p:UseSharedCompilation=false -o "$STAGE/bin"
done
# 蓝牙补丁 dll 覆盖（NuGet 原版不认蓝牙平板）
[ -f "$HIDSHARP_DLL" ] && cp "$HIDSHARP_DLL" "$STAGE/bin/HidSharpCore.dll"

echo "==> assemble $APP_NAME ($VERSION)"
APP="$STAGE/$APP_NAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R "$STAGE/bin/." "$APP/Contents/MacOS/"
rm -rf "$APP/Contents/MacOS/OpenTabletDriver.UX.MacOS.app"
cp "$OTD_SRC/eng/bash/macos/Icon.icns" "$APP/Contents/Resources/"
cp "$OTD_SRC/eng/bash/macos/Info.plist" "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $IDENTITY" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
# .NET 运行时致命错误时自动写 minidump（下次 daemon 猝死可尸检）
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:DOTNET_DbgEnableMiniDump string 1" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:DOTNET_DbgMiniDumpType string 1" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:DOTNET_DbgMiniDumpName string $HOME/Library/Logs/OpenTabletDriver-crash.dmp" "$APP/Contents/Info.plist" 2>/dev/null || true

echo "==> sign（与 build-app.sh 同一 rcodesign 方式/同一证书）"
for exe in OpenTabletDriver.UX.MacOS OpenTabletDriver.Daemon OpenTabletDriver.Console createdump; do
  f="$APP/Contents/MacOS/$exe"; [ -f "$f" ] || continue
  id="$IDENTITY"
  case "$exe" in
    OpenTabletDriver.Daemon) id="$IDENTITY.daemon" ;;
    OpenTabletDriver.Console) id="$IDENTITY.console" ;;
    createdump) id="$IDENTITY.createdump" ;;
  esac
  "$RCSIGN" sign --p12-file "$CERT_FILE" --p12-password-file "$CERT_PW_FILE" \
    --binary-identifier "$id" "$f"
done

echo "==> install & relaunch"
# 清理残留 IPC socket（pkill/SIGKILL 后可能遗留，会让新 daemon 误判 already running）
rm -f "${TMPDIR}CoreFxPipe_OpenTabletDriver.Daemon" "${TMPDIR}CoreFxPipe_OpenTabletDriver.UX.Singleton" 2>/dev/null || true
pkill -f OpenTabletDriver || true
sleep 2
rm -rf "/Applications/$APP_NAME"
cp -R "$APP" "/Applications/"
open "/Applications/$APP_NAME"
echo "OK $VERSION installed"
