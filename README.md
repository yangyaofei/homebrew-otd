# homebrew-otd

OpenTabletDriver BT（macOS Wacom 蓝牙支持 fork）+ PenAssist 插件的 CI/CD 与 brew tap。

## 安装

```bash
brew tap yangyaofei/otd
brew install --cask otd-bt
```

升级：`brew upgrade --cask otd-bt`（签名身份稳定，升级后无需重新授权）

## 结构

- `scripts/build-app.sh` —— 构建（本地/CI 共用）：clone fork+插件 → HidSharp 补丁 → 自包含发布 → rcodesign 签名 → 单 zip（app+插件）
- `.github/workflows/release.yml` —— 推 `v*` tag 或手动触发 → 构建 → Release → 自动回写 cask 版本
- `Casks/otd-bt.rb` —— cask 公式（app + 插件 dll 一步装齐）
- `certs/`（gitignored）—— 10 年自签证书；CI 用 secrets `OTD_BT_P12_B64` / `OTD_BT_P12_PW`

## 首次授权

辅助功能、输入监控（系统设置 → 隐私与权限）。之后跨版本不再弹。

## 依赖的上游

- OTD fork：`yangyaofei/OpenTabletDriver` 分支 `pr4672-bluetooth-macos`（基于 PR#4672）
- 插件：`yangyaofei/PenAssist`
- HidSharp 补丁：随 fork 的 `patches/` 携带，待上游 `HIDSharpCore` 合并后此步骤自动失效
