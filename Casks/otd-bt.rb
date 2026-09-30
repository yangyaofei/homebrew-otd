cask "otd-bt" do
  version "0.0.0"
  sha256 ":no-check"

  url "https://github.com/yangyaofei/homebrew-otd/releases/download/v#{version}/otd-bt-#{version}.zip",
      verified: "github.com/yangyaofei/homebrew-otd/"
  name "OpenTabletDriver BT"
  desc "OpenTabletDriver fork with Wacom Bluetooth (CTL-4100WL/6100WL) macOS support + PenAssist plugin"
  homepage "https://github.com/yangyaofei/homebrew-otd"

  depends_on macos: ">= :sonoma"

  app "OpenTabletDriver-BT.app"
  artifact "PenAssist.dll",
           target: "~/Library/Application Support/OpenTabletDriver/Plugins/PenAssist/PenAssist.dll"

  quit "io.github.yangyaofei.otd-bt"

  caveats <<~EOS
    首次运行需在 系统设置 → 隐私与权限 中授权：
      - 辅助功能 (Accessibility)
      - 输入监控 (Input Monitoring)
    平板需先在系统蓝牙设置中配对。升级不会要求重新授权。
  EOS

  zap trash: [
    "~/Library/Application Support/OpenTabletDriver",
  ]
end
