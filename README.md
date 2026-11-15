# QY·FM 原生鸿蒙版

这是 QY·FM 的独立 HarmonyOS ArkTS / ArkUI 工程，代码与发布包位于
[zzg341125/QYFM-HM](https://github.com/zzg341125/QYFM-HM)。

## 当前能力

- 首页、设置页、配色、行高、圆形台标、底部胶囊按钮和播放条按 Android `v1.0.8` Release 重做。
- 安装后的桌面图标按 Android `v1.0.8` Release 的自适应图标背景色和前景矢量生成。
- 原生 AVPlayer 网络电台播放与 AVSession 锁屏播控。
- 原生 A2DP 蓝牙连接监听；同一设备重连续播窗口可在 15–480 分钟之间设置。
- 蓝牙断开后使用低开销静音音频流维持长时任务，避免系统在约 1 分钟后停止监听。
- 点击电台整行只播放；编辑模式下左滑显示“编辑、删除”，点击编辑按钮才打开编辑窗口；长按普通电台可拖动排序。
- 点击整行播放、启动自动播放、最后电台与列表记忆、11 套主题、透明播放条和 0.25 秒极速起播。
- M3U / M3U8 导入导出，支持 `#EXTINF` 名称及 `tvg-logo`。
- 本地 JSON 备份/恢复，并兼容 Android `v1.0.8` ZIP（`playlist.json`、`playlist.m3u`、台标和显式顺序）。
- WebDAV 每次上传生成独立时间戳版本，并可从云端列表恢复 Android `v1.0.8` ZIP 或本机 JSON 版本。
- WebDAV 备份包含电台、设置、Base64 台标和显式 `stationOrder`，恢复后保持原播放列表顺序。
- 播放使用 0.25 秒起播水位、30 秒缓冲能力、15 秒连接看门狗和备用线路优先切换，兼容 HLS 7–10 秒分片；返回前台自动续播。
- 兼容 Android 备份中的多线路地址；主线路失败时按备份顺序切换到后续线路，不把线路倒序。
- 允许传统电台使用的 HTTP 明文流，并可按 station 名称从 radio.cn 刷新官方直播线路；旧新西兰 936 域名会自动迁移。
- B3 清晨音乐台的旧 64k MP3 直链自动迁移到同频道 HTTPS HE-AAC HLS 流，降低网络抖动造成的破音和杂音。
- 锁屏媒体台标超过系统元数据上限时自动省略，不会再把大尺寸 Base64 台标误判为播放失败。
- 睡眠定时显示具体结束时刻，锁屏播控、断开耳机暂停和可配置窗口内重连续播。
- 应用内优先下载 GitHub 签名 `.app` 安装包并调起系统安装页面；系统要求时选择手机中已有的应用安装器，并在系统安全提示中确认。
- 在线升级会在解压签名 APP 前创建独立目标目录，避免系统错误 `900002`。
- 播放页与设置页使用原生虚拟化列表和弹性滚动。

## 重要系统约束

HarmonyOS 不允许普通第三方应用静默安装自身。在线升级流程负责检测并展示系统升级框，或跳转到 GitHub 发布页下载 HAP；最终安装由 HarmonyOS 系统安装器确认。

原生 A2DP 回调在应用进程存活时可靠工作。为了覆盖用户设置的等待窗口，本项目在暂停真实电台后启动一条静音音频保持流。它会带来少量持续功耗，可在设置中关闭“蓝牙重连自动续播”。

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
