# QY·FM 原生鸿蒙版

这是 QY·FM 的独立 HarmonyOS ArkTS / ArkUI 工程，代码与发布包位于
[zzg341125/QYFM-HM](https://github.com/zzg341125/QYFM-HM)。

## 当前能力

- 首页、设置页、配色、行高、圆形台标、底部胶囊按钮和播放条按 Android `v1.0.8` Release 重做。
- 安装后的桌面图标按 Android `v1.0.8` Release 的自适应图标背景色和前景矢量生成。
- 原生 AVPlayer 网络电台播放与 AVSession 锁屏播控。
- 原生 A2DP 蓝牙连接监听；同一设备断开后 120 分钟内重连自动续播。
- 蓝牙断开后使用低开销静音音频流维持长时任务，避免系统在约 1 分钟后停止监听。
- 电台搜索、新增、长按编辑、拖动排序、二次确认左滑删除与顺序持久化。
- 点击整行播放、启动自动播放、最后电台与列表记忆、11 套主题、透明播放条、极速起播和更大缓冲。
- M3U / M3U8 导入导出，支持 `#EXTINF` 名称及 `tvg-logo`。
- 本地 JSON 备份/恢复；WebDAV 每次上传生成独立时间戳版本，可从云端列表恢复任意版本。
- WebDAV 备份包含电台、设置、Base64 台标和显式 `stationOrder`，恢复后保持原播放列表顺序。
- HLS 直播缓冲水位优化，断流后按 1/2/4/8/16/30 秒退避自动重连，返回前台自动续播。
- 睡眠定时、锁屏播控、断开耳机暂停、同设备 120 分钟重连续播。
- GitHub 原生版版本检查、AppGallery 系统升级入口、自动和手动检查。
- 播放页与设置页使用原生虚拟化列表和弹性滚动。

## 重要系统约束

HarmonyOS 不允许普通第三方应用静默安装自身。在线升级流程负责检测并展示系统升级框，或跳转到 GitHub 发布页下载 HAP；最终安装由 HarmonyOS 系统安装器确认。

原生 A2DP 回调在应用进程存活时可靠工作。为了覆盖用户要求的 120 分钟等待窗口，本项目在暂停真实电台后启动一条静音音频保持流。它会带来少量持续功耗，可在设置中关闭“蓝牙重连自动续播”。

## 工具链

需要 DevEco Studio 6.1+ 或 HarmonyOS Command Line Tools 26+，并安装 API 23 SDK。

```powershell
devecocli build
devecocli run
```

签名需要先执行：

```powershell
devecocli auth login
devecocli signature generate --product default
```

## 发布约定

- 使用 `harmony-v1.x.x` 标签发布 HarmonyOS 原生版。
- 每个 Release 附带签名 HAP，应用内更新检查读取本仓库的最新稳定 Release。
- 本机签名证书、密码和构建缓存不进入仓库。

详细实现与真机验收说明见 [docs/HARMONYOS_NATIVE_MIGRATION.md](docs/HARMONYOS_NATIVE_MIGRATION.md)。
