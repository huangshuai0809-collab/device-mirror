# Device Mirror 0.1.4 — Preview

把 iPad 投屏到 Mac 的一个窗口里，支持无线 AirPlay 和 USB 数据线。

## 安装

下载 `DeviceMirror-0.1.4-macOS-arm64.zip`，解压后打开 **Device Mirror.app**。需要 Apple Silicon Mac 和 macOS 14 或更新版本。

这是临时签名的预览版，未做 Apple 公证。如果系统阻止打开，可在「系统设置 → 隐私与安全性」中查看该 App 的打开选项。更新前请先退出旧版。

## 功能和修复

- 无线 AirPlay 与 USB 投屏，可缩放、置顶窗口。
- 修复首次配对时反复输入密码的问题。
- 调整窗口绘图方式，改善 Zoom 网页版共享窗口时的黑屏问题。
- 修复右上角按钮图标和文字重叠。

无线声音仍为实验功能，USB 目前只传画面。界面为简体中文。

## 源码

`DeviceMirror-0.1.4-source.zip` 包含应用源码、依赖源码压缩包、许可证及本地补丁。可离线准备依赖并构建。`SHA256SUMS.txt` 提供两个安装文件的校验值。

---

Mirror your iPad in a resizable Mac window over AirPlay or USB. This preview includes fixes for initial PIN pairing, black window capture in Zoom web sharing, and overlapping toolbar labels.

The app download requires Apple Silicon and macOS 14+. It has an ad hoc signature and is not Apple-notarized. AirPlay audio is experimental; USB is video only. The interface is in Simplified Chinese. The complete source archive includes the original dependency archives and local patch for an offline source build.
