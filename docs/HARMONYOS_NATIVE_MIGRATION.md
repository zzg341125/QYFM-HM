# QY·FM 原生鸿蒙迁移说明

## 目标

保留 Android APK 项目、标签和发布资产，新增独立 HarmonyOS 原生工程。原生版必须解决 APK 兼容层在 HarmonyOS 7 上无法感知 A2DP 重连的问题。

## 架构

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| 主界面 | `entry/src/main/ets/pages/Index.ets` | 播放、电台编辑、排序、设置、备份和升级 UI |
| 电台仓库 | `entry/src/main/ets/data/StationRepository.ets` | Preferences 持久化、顺序恢复、JSON 备份 |
| 播放控制 | `entry/src/main/ets/services/RadioController.ets` | AVPlayer、AVSession、睡眠定时和蓝牙续播调度 |
| 蓝牙策略 | `entry/src/main/ets/services/BluetoothResumeManager.ets` | A2DP 状态、设备身份、可配置续播窗口 |
| 后台任务 | `entry/src/main/ets/services/BackgroundTaskService.ets` | 音频长时任务 |
| 静音保持 | `entry/src/main/ets/services/SilentAudioKeepAlive.ets` | 断开等待期间维持音频任务有效 |
| WebDAV | `entry/src/main/ets/services/WebDavBackupService.ets` | Basic Auth、时间戳多版本上传、版本索引与任意版本恢复 |
| 备份模型 | `entry/src/main/ets/utils/BackupModel.ts` | 时间戳文件名、版本索引、显式顺序恢复 |
| 直播恢复 | `entry/src/main/ets/utils/PlaybackRecovery.ts` | HLS 缓冲水位与退避重连策略 |
| 在线升级 | `entry/src/main/ets/services/AppUpdateService.ets` | `harmony-v*` GitHub Release 与 AppGallery 更新 |
| 本地文件 | `entry/src/main/ets/services/LocalFileService.ets` | M3U 和 JSON 的选择、读取与保存 |
| 电台搜索 | `entry/src/main/ets/services/StationSearchService.ets` | 内置电台和 Radio Browser 在线搜索 |

## 蓝牙续播规则

1. 用户开始播放，且 A2DP 设备处于连接状态时，记录当前设备地址。
2. 当前设备断开或音频输出回落到扬声器时，立即暂停真实电台。
3. 保存断开设备身份与时间戳，开始静音音频保持流。
4. 只有同一设备地址重新进入 `STATE_CONNECTED` 且间隔不超过用户设置的窗口才续播。
5. 手动暂停、停止、切换电台、睡眠定时停止都会取消待续播状态。
6. 普通启动是否播放由“启动时自动播放”设置控制；蓝牙重连续播只接受断开前正在播放的同一设备。

设备地址使用 HarmonyOS 返回的虚拟 MAC。文档说明已配对设备在蓝牙开关不重启时地址保持稳定，适合本次重连窗口。

## 为什么保留静音音频流

官方 FAQ 明确说明：

- 音频长时任务在暂停且没有实际播放时会被系统管控。
- 蓝牙长时任务在蓝牙断开后要求一分钟内重连，否则自动结束。

因此，仅创建蓝牙长时任务无法满足长窗口等待。项目只申请音频长时任务来避免“蓝牙断开一分钟即结束”的限制，并在真实电台暂停后启动 8 kHz 单声道静音 PCM，保持音频任务有实际渲染活动，以便锁屏状态下继续接收 A2DP 回调。超过设置窗口、手动停止或关闭自动续播时会立即释放。

## 备份格式

WebDAV 保存 `application/json` 文件，备份数据 `schemaVersion` 为 `2`：

```json
{
  "schemaVersion": 2,
  "app": "QYFM HarmonyOS",
  "appVersion": "1.0.3",
  "exportedAt": "ISO-8601",
  "stationOrder": ["id-2", "id-1"],
  "stations": [
    {
      "id": "id-2",
      "name": "电台名称",
      "streamUrl": "https://example/stream.m3u8",
      "iconUrl": "data:image/png;base64,...",
      "tags": "新闻",
      "country": "中国",
      "state": "河北",
      "favorite": true
    }
  ],
  "settings": {
    "autoUpdate": true,
    "autoResume": true,
    "resumeWindowMinutes": 120,
    "editMode": true,
    "themeId": "lunar_light",
    "autoPlayOnLaunch": true,
    "playbackMemory": true,
    "webdavUrl": "https://dav.example/radio/",
    "webdavUser": "user",
    "webdavFile": "qyfm-backup.json"
  }
}
```

用户选择的本地台标会转换为 Base64 data URL，因此不会因设备路径不同而丢失。`stationOrder` 是恢复顺序的唯一来源；缺失或新增的电台会去重后追加，避免恢复时顺序错乱。WebDAV 密码不会写入备份。

WebDAV 密码输入框使用普通键盘与明文显示，方便用户校对；密码仍只保存在本机 Preferences 中。

每次上传都会生成独立文件，例如：

```text
qyfm-backup-20261114-010203-004.json
```

目录中的 `qyfm-backup-versions.json` 是版本索引，记录文件名、导出时间、电台数量和 App 版本。应用读取该索引并按时间倒序展示，用户选择任意版本后从对应 URL 恢复。索引缺失时会尝试读取旧版固定文件名 `qyfm-backup.json`；索引损坏时停止更新并报错，避免覆盖已有版本历史。

“恢复电台”同时支持 Android `v1.0.8` Release 生成的 ZIP 包，例如 `quyang_backup_20261112_102536.zip`。恢复流程读取：

- `playlist.json`：Android 电台数据、活动线路地址、收藏和台标引用。
- `manifest.json`：显式 `stationOrder`。
- `settings.json`：Android `pref_*` 设置键。
- `logos/`：本地台标，转换为 Base64 data URL 后写入鸿蒙播放列表。
- `playlist.m3u`：当 `playlist.json` 缺失时作为回退来源。

## 直播稳定性

- HLS 默认保留 8 秒缓冲；开启“更大缓冲”后提升到 30 秒。
- 快速起播使用 1 秒起播水位和 4 秒恢复阈值；稳定模式使用 3 秒起播水位和 6 秒恢复阈值。
- 播放器报错、直播流完成或停止时自动重连，重试间隔依次为 1、2、4、8、16、30 秒，后续保持 30 秒上限。
- 应用回到前台时，若用户没有手动暂停且直播仍处于中断状态，会立即尝试恢复。

## 在线升级

- 启动时可自动检查 GitHub 中 `harmony-v*` 标签的最新稳定发布。
- 设置页提供手动检查。
- GitHub 发布存在时显示版本说明并跳转发布页。
- 若应用由 AppGallery 分发，同时调用 `updateManager.checkAppUpdate()` 与系统升级框。
- 普通第三方应用没有静默自安装权限，HAP 安装必须由系统确认。

## 真机验收

设备：HUAWEI Mate 80 Pro Max，HarmonyOS `7.0.0.111 SP12`。

1. 检查“启动时自动播放”开关，分别验证开启和关闭时的启动行为。
2. 连接蓝牙耳机，播放电台，确认 A2DP 状态写入诊断信息。
3. 锁屏，关闭蓝牙耳机。
4. 确认电台暂停，应用显示“等待同一设备重连”。
5. 等待至少 2 分钟，再重新打开同一耳机。
6. 不解锁、不打开应用，确认原电台自动续播。
7. 修改蓝牙续播窗口，等待超过设置时间后重连，确认不会自动续播。
8. 用设备 B 重连，确认不会误续播设备 A 的内容。
9. 播放时手动暂停再断开/重连，确认不会自动续播。
10. 调整电台顺序，备份到 WebDAV，删除或打乱本地顺序后恢复，确认顺序与台标一致。
11. 关闭编辑模式左滑，确认不出现删除按钮；打开编辑模式后确认可以删除。
12. 在播放页和设置页连续上下滑动，确认无明显掉帧和卡顿。
13. 连续上传两次，确认云端列表出现两个时间戳版本，并能分别恢复。
14. 播放 HLS 直播时中断网络，确认按退避间隔自动重连；恢复网络并切回前台后确认继续播放。
15. 卸载并重新安装 `1.0.3`，确认桌面图标为 Android `v1.0.8` 的红色自适应收音机图标。
16. 选择 `quyang_backup_20261112_102536.zip`，确认 M3U 电台、台标和播放顺序完整恢复。
17. 开启编辑模式左滑，确认删除按钮保持行内紧凑尺寸，不覆盖整屏。
18. 设置睡眠定时，确认面板和播放状态显示准确的结束时刻。

## v1.0.8 兼容说明

可见的 `v1.0.8` 极简版功能均已迁移到 ArkUI。Android 的“将单个电台创建为桌面快捷方式”依赖 Android 专属 ShortcutManager；HarmonyOS 三方应用目前只能声明安装时定义的静态快捷方式，不能按任意电台动态创建桌面快捷方式，因此该项没有伪造等价入口。应用本身的桌面图标已使用 `v1.0.8` 原始资源。

| v1.0.8 功能 | HarmonyOS 原生实现 |
| --- | --- |
| 首页平铺电台列表、圆形台标、圆形播放键 | 已按原版布局和尺寸重做 |
| 电台搜索、新增、长按编辑、拖动排序、左滑删除确认 | 已实现 |
| 点击整行播放开关 | 已实现；关闭后仍可点行尾播放键 |
| 启动自动播放、最后电台记忆 | 已实现 |
| 主题、动态强调色、透明播放条 | 已实现主题与强调色切换 |
| 睡眠定时 15/30/45/60 分钟 | 已对应到实现中 |
| M3U / M3U8 导入、导出与台标 | 已实现 |
| 本地 JSON 备份/恢复 | 已实现 |
| WebDAV 多版本备份、云端列表恢复、台标与顺序 | 已实现 |
| 极速起播、HLS 缓冲、断流自愈与前台续播 | 已实现 |
| 编辑电台、编辑流地址权限 | 已实现 |
| 蓝牙设备识别、断开暂停、可配置窗口重续播 | 原生 A2DP 实现并完成锁屏真机验证 |
| 自动/手动更新、GitHub、版本信息 | 已实现 |
| 安装后的 App 图标 | 按 `v1.0.8` 自适应图标背景色与前景矢量生成 |
