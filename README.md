# QY·FM 原生鸿蒙版

这是 QY·FM 的独立 HarmonyOS ArkTS / ArkUI 工程，代码与发布包位于
[zzg341125/QYFM-HM](https://github.com/zzg341125/QYFM-HM)。

## 当前能力

- 首页、设置页、配色、行高、圆形台标、底部胶囊按钮和播放条按 Android `v1.0.8` Release 重做。
- 安装后的桌面图标按 Android `v1.0.8` Release 的自适应图标背景色和前景矢量生成。
- 原生 AVPlayer 网络电台播放与 AVSession 锁屏播控。
- 原生 A2DP 蓝牙连接监听；同一设备重连续播窗口可在 15–480 分钟之间设置。
- 蓝牙断开后立即停止播放并移除锁屏暂停卡片；应用进程仍在时可记录设备并在续播窗口内自动恢复。
- 点击电台整行只播放；编辑模式下左滑显示“编辑、删除”，点击编辑按钮才打开编辑窗口；长按普通电台可拖动排序。
- 点击整行播放、启动自动播放、最后电台与列表记忆、11 套主题、透明播放条和 0.25 秒极速起播。
- M3U / M3U8 导入导出，支持 `#EXTINF` 名称及 `tvg-logo`。
- 本地 JSON 备份/恢复，并兼容 Android `v1.0.8` ZIP（`playlist.json`、`playlist.m3u`、台标和显式顺序）。
- WebDAV 每次上传生成独立时间戳版本，并可从云端列表恢复 Android `v1.0.8` ZIP 或本机 JSON 版本。
- WebDAV 备份包含电台、设置、Base64 台标和显式 `stationOrder`，恢复后保持原播放列表顺序。
- 播放使用 0.25 秒起播水位、30 秒缓冲能力、15 秒连接看门狗和备用线路优先切换，兼容 HLS 7–10 秒分片；返回前台自动续播。
- 点击电台直接使用当前已有地址起播，官方线路查询、媒体会话和后台任务不再阻塞首帧；官方线路仅在后台准备为备用线路。
- 台湾地区失效直播地址按主机和路径统一迁移：臺北總台旧域名转到国教电台当前入口，亚洲/飞扬转到稳定 HTTP 路由，台北/正声/央广使用动态直播入口，避免过期 `chunklist` 会话和欧洲节点长握手。
- 已验证的台湾 AAC HLS 使用独立 FFmpeg 分片读取器，自动取得主列表、滚动子列表并移除每片 ID3 头；首片直接解码，不依赖容易错过直播窗口的系统 HLS 会话。
- HTTP 直播会先处理 `Transfer-Encoding: chunked`，再剥离 ICY 元数据；不会再把分块长度和 CRLF 当 MP3/AAC 数据送入解码器。
- FFmpeg PCM 队列只保留最新 1 秒音频，暂停或音频中断时清空队列与 Renderer 缓冲；线路故障切换会等旧 AudioRenderer 完全释放后再启动新线路。
- 蜻蜓 MP3 地址统一使用其可用的 HTTP 原始流并交给 FFmpeg，避开 HarmonyOS 的 4 秒 TLS 超时和流式 HTTP 写流错误；两广之声音乐台公开源为 MP3 64 kbps，服务端没有更高码率版本。
- 官方线路查询转到后台执行，旧 MP3 兼容层预热约 0.25 秒；首次起播保持电台名称，不再显示“正在缓冲”提示，仅播放中的二次缓冲超过 800 毫秒才提示。
- 兼容 Android 备份中的多线路地址；主线路失败时按备份顺序切换到后续线路，不把线路倒序。
- 允许传统电台使用的 HTTP 明文流，并可按 station 名称从 radio.cn 刷新官方直播线路；旧新西兰 936 域名会自动迁移，无扩展名的 `/fm994` 会按 AAC 96 kbps 识别并交给 FFmpeg。
- B3 清晨音乐台保留连续 64k MP3 直播，减少 7 秒 HLS 分片带来的等待；Icecast 元数据由兼容层清理后再解码。
- 旧 MP3 直播地址若携带 Icecast `icy-metaint` 元数据，会先剥离内嵌曲目信息再交给 HarmonyOS 原生解码器；“旧 MP3 兼容解码”可在高级设置中手动关闭并回退系统直连。
- `/stream?.mp3` 这类扩展名位于查询参数中的 Icecast 地址也会识别；美国纽约中文广播使用已验证可连接的 HTTP 端点进入清理流程。
- 高级设置可启用独立 FFmpeg MP3/AAC 解码引擎：内置完整 FFmpeg 组件与 ARM64 NEON 优化，原生 `libavcodec`/`libswresample` 输出 48 kHz 双声道 F32 PCM，再由 `AudioRenderer` 播放，不调用 AVPlayer 解码。
- FFmpeg 解码器按服务器 `Content-Type` 自动选择 MP3、AAC ADTS 或 AAC-LATM，并在解码队列满时重试数据包，避免丢帧造成爆音和杂音。
- 直播从任意帧中间接入时，FFmpeg 会跳过无效同步包并继续解码后续正常音频，不再因首个坏包退回系统播放器造成连续缓冲。
- 锁屏媒体台标超过系统元数据上限时自动省略，不会再把大尺寸 Base64 台标误判为播放失败。
- 睡眠定时显示具体结束时刻，锁屏播控、断开耳机暂停和可配置窗口内重连续播。
- 蓝牙设置可分别开启“断开立即停止”和“连接自动播放”；断开时不再保留静音等待任务，同一设备在续播窗口内重连时仍可选择自动续播。
- 应用内优先下载 GitHub 签名 `.app` 安装包并调起系统安装页面；系统要求时选择手机中已有的应用安装器，并在系统安全提示中确认。
- 在线升级会在解压签名 APP 前创建独立目标目录，避免系统错误 `900002`。
- 播放页与设置页使用原生虚拟化列表和弹性滚动。

## 重要系统约束

HarmonyOS 不允许普通第三方应用静默安装自身。在线升级流程负责检测并展示系统升级框，或跳转到 GitHub 发布页下载 HAP；最终安装由 HarmonyOS 系统安装器确认。

原生 A2DP 回调在应用进程存活时可靠工作。蓝牙断开后会释放播放器、后台任务和媒体通知；同一设备在设置窗口内重连时，可按“蓝牙重连自动续播”恢复播放。

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
