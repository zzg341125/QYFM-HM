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
| WebDAV | `entry/src/main/ets/services/WebDavBackupService.ets` | Basic Auth、时间戳多版本上传、版本索引与任意版本恢复 |
| 备份模型 | `entry/src/main/ets/utils/BackupModel.ts` | 时间戳文件名、版本索引、显式顺序恢复 |
| 直播恢复 | `entry/src/main/ets/utils/PlaybackRecovery.ts` | HLS 缓冲水位与退避重连策略 |
| 在线升级 | `entry/src/main/ets/services/AppUpdateService.ets` | `harmony-v*` GitHub Release 与 AppGallery 更新 |
| 本地文件 | `entry/src/main/ets/services/LocalFileService.ets` | M3U 和 JSON 的选择、读取与保存 |
| 电台搜索 | `entry/src/main/ets/services/StationSearchService.ets` | 内置电台和 Radio Browser 在线搜索 |

## 蓝牙续播规则

1. 用户开始播放，且 A2DP 设备处于连接状态时，记录当前设备地址。
2. 当前设备断开或音频输出回落到扬声器时，立即停止真实电台并释放后台任务。
3. 保存断开设备身份与时间戳，同时隐藏 AVSession 和锁屏暂停卡片。
4. 只有同一设备地址重新进入 `STATE_CONNECTED` 且间隔不超过用户设置的窗口才自动续播。
5. 手动暂停、停止、切换电台、睡眠定时停止都会取消待续播状态。
6. 普通启动是否播放由“启动时自动播放”设置控制；蓝牙重连续播只接受断开前正在播放的同一设备。

设备地址使用 HarmonyOS 返回的虚拟 MAC。文档说明已配对设备在蓝牙开关不重启时地址保持稳定，适合本次重连窗口。

## 为什么改为立即停止

官方 FAQ 明确说明：

- 音频长时任务在暂停且没有实际播放时会被系统管控。
- 蓝牙长时任务在蓝牙断开后要求一分钟内重连，否则自动结束。

当前版本不再用静音音频维持蓝牙等待。蓝牙断开后使用平台仍开放的普通应用回调记录设备与时间；应用进程存活且同一设备在窗口内重连时自动恢复。应用被系统彻底终止后，普通第三方应用无法保证收到重连广播，此时需要在应用内重新开始播放。

## 备份格式

WebDAV 保存 `application/json` 文件，备份数据 `schemaVersion` 为 `2`：

```json
{
  "schemaVersion": 2,
  "app": "QYFM HarmonyOS",
  "appVersion": "1.0.29",
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

WebDAV 对话框中的“ZIP 文件”默认填写 `quyang_backup_20261112_102536.zip`。点击“刷新版本”时，应用对该文件执行 HEAD 检查并加入云端版本列表；选择带 `Android v1.0.8 ZIP` 标记的条目即可从 WebDAV 下载并恢复。

## 直播稳定性

- HarmonyOS 使用 30 秒音频缓冲能力、0.25 秒极速起播水位和 15 秒连接与重缓冲看门狗，以适配常见的 7–10 秒 HLS 分片；Android 备份中的多线路按原顺序优先切换。
- 点击电台直接使用当前已有地址起播，官方线路查询、媒体会话和后台任务不阻塞首帧；官方线路仅在后台准备为备用线路。
- HarmonyOS 使用原生 `AVPlayer`，不是直接打包 AndroidX Media3/ExoPlayer；对齐的是起播、缓冲、HTTP 请求头、音频焦点、线路容灾和恢复行为。
- 台湾电台按 URL 规则迁移，不依赖电台名称：`cast.ner.gov.tw/<频道>` 转到 `wowza1.ner.gov.tw/TPFM/<频道>/playlist.m3u8`；亚洲/飞扬的欧洲区域 Revma 链接转到稳定 HTTP 路由；台北、正声、央广的过期 Wowza 会话地址转到当前动态入口。
- 已验证的台湾 AAC HLS 由独立 FFmpeg 分片读取器处理，支持主列表、滚动分片、相对路径和每片 ID3 头清理，避免系统 HLS 播放器错过两秒直播窗口后请求已过期分片。
- Icecast/MP3 连接支持 HTTP 3xx 跳转，FFmpeg 遇到从帧中间接入产生的无效同步包会跳过并继续解码后续帧，避免退回系统播放路径后反复缓冲。
- HTTP chunked 传输会先解帧再处理 ICY 元数据；PCM 实时队列最多保留 1 秒，暂停时清空队列与 Renderer 缓冲，避免旧节目积压。
- 播放器故障切换会等待旧 FFmpeg/AudioRenderer 完全释放后再启动备用线路，并使用恢复门禁阻止多个播放实例并发出声。
- 应用声明允许传统 HTTP 广播流，并保留 radio.cn 官方专线刷新和旧 NZ 936 域名迁移。
- B3 清晨音乐台保留连续 `64k MP3` 地址，避免 7 秒 HLS 分片的跨片等待；Icecast 元数据由兼容层清理后交给系统解码。
- HTTPS 音频通过 TLS Socket 读取，HTTP 音频通过 TCP Socket 读取；兼容层移除 Icecast 内嵌元数据后，把连续 MP3/AAC 数据送入 FFmpeg。无扩展名的旧新西兰 `/fm994` 按 AAC 96 kbps 识别。
- AVSession 锁屏台标只使用不超过 40960 字符的 URI；恢复备份中的大尺寸 Base64 台标会被省略，但不会影响电台播放。
- 蓝牙断开立即停止和蓝牙连接自动播放分别受设置项控制。连接自动播放可在应用已退到后台但仍保有音频进程时唤起上次电台；应用被系统彻底终止时，普通 HarmonyOS 应用无法仅凭蓝牙广播自行创建后台播放。
- 暂停或停止时 AVSession 会转为 `STOP` 并停用，锁屏不再显示“收音机已暂停”的媒体卡片。
- 快速起播使用 0.25 秒起播水位和 2.25 秒快速播放阈值；关闭快速起播时使用 0.8 秒水位和 2.8 秒阈值，缓冲上限均为 5 秒。
- 播放器报错、直播流完成或连接超时时，先立即切换后续备用线路；没有备用线路时最多刷新重试 2 次，每次间隔 600 毫秒。
- 应用回到前台时，若用户没有手动暂停且直播仍处于中断状态，会立即尝试恢复。

## 播放列表手势

- 长按普通电台后直接上下拖动排序，不再要求开启编辑模式。
- 排序完成后立即保存新的列表顺序。
- 长按当前正在播放的电台会打开睡眠定时，提供关闭、15、30、45、60 分钟选项。
- 编辑模式在每行提供独立编辑按钮，避免长按编辑与长按拖动排序冲突。
- 本地台标根据文件签名识别 PNG、JPEG、WebP、GIF，不再依赖内容 URI 的扩展名。

## 在线升级

- 启动时可自动检查 GitHub 中 `harmony-v*` 标签的最新稳定发布。
- 设置页提供手动检查。
- 自动更新开启时，发现新版本后在应用内优先下载 Release 中的签名 `.app`，没有再回退到 HAP。
- 用户点击“立即安装”后，通过文件 URI 和 `openharmony.package` / `openharmony.hap` UTD 调起 HarmonyOS 系统安装器。
- 若系统返回 `No matching ability is found`，应用自动打开手机文件保存器，把安装包保存到可访问目录并尝试打开文件管理器。
- 普通第三方应用没有系统安装器能力，系统未开放直接调用时，用户可在文件管理器中点击已保存的 APP/HAP 完成安装，无需连接电脑。
- 用户也可点击“前往 GitHub 发布页”手动下载，或继续使用 AppGallery 更新。
- 若应用由 AppGallery 分发，同时调用 `updateManager.checkAppUpdate()` 与系统升级框。
- 普通第三方应用没有静默自安装权限，因此“自动升级”会自动检查并下载；最终安装仍必须由用户在系统页面确认，无需连接电脑。

## 真机验收

设备：HUAWEI Mate 80 Pro Max，HarmonyOS `7.0.0.111 SP12`。

1. 检查“启动时自动播放”开关，分别验证开启和关闭时的启动行为。
2. 连接蓝牙耳机，播放电台，确认 A2DP 状态写入诊断信息。
3. 锁屏，关闭蓝牙耳机。
4. 确认电台立即停止、后台任务释放，锁屏媒体卡片消失。
5. 保持系统尚未回收应用进程，等待至少 2 分钟，再重新打开同一耳机。
6. 应用进程仍存活时，不解锁、不打开应用，确认原电台自动续播；若系统已回收进程则不保证收到重连事件。
7. 修改蓝牙续播窗口，等待超过设置时间后重连，确认不会自动续播。
8. 用设备 B 重连，确认不会误续播设备 A 的内容。
9. 播放时手动暂停再断开/重连，确认不会自动续播。
10. 调整电台顺序，备份到 WebDAV，删除或打乱本地顺序后恢复，确认顺序与台标一致。
11. 关闭编辑模式左滑，确认不出现删除按钮；打开编辑模式后确认可以删除。
12. 在播放页和设置页连续上下滑动，确认无明显掉帧和卡顿。
13. 连续上传两次，确认云端列表出现两个时间戳版本，并能分别恢复。
14. 播放 HLS 直播时中断网络，确认 6.5 秒内触发备用线路切换或最多 2 次刷新重试；恢复网络并切回前台后确认继续播放。
15. 覆盖安装 `1.0.29`，确认桌面图标仍为 Android `v1.0.8` 的红色自适应收音机图标，前景宽度约占 75%。
16. 选择 `quyang_backup_20261112_102536.zip`，确认 M3U 电台、台标和播放顺序完整恢复。
17. 开启编辑模式左滑，确认删除按钮保持行内紧凑尺寸，不覆盖整屏。
18. 设置睡眠定时，确认面板和播放状态显示准确的结束时刻。
19. 在 WebDAV 中填写 `quyang_backup_20261112_102536.zip`，刷新版本并从云端恢复，确认列表、台标和顺序完整。
20. 发布更高版本后打开“检查更新”，确认应用自动下载安装包，并能调起手机安装方式选择页。
21. 更换 PNG/JPG/WebP 台标，确认列表立即显示；长按普通电台拖动排序并重启确认顺序保留。
22. 长按正在播放的电台，确认睡眠定时面板出现；持续播放确认卡顿明显减少。
23. 发布 `1.0.29` 以上版本，验证下载 `.app.zip` 后先创建解压目录，再调起系统安装页面；在安装方式选择页选择手机中已有的应用安装器并确认。
24. 选择带多条线路的 Android 备份，主线路断开后确认按后续线路顺序切换，不回到旧线路且不会倒序。
25. 播放 `臺北總臺FM臺`，确认旧 `cast.ner.gov.tw` 自动迁移并通过 FFmpeg HLS 分片读取器持续播放。
26. 依次播放备份中的 6 个台湾电台，确认亚洲/飞扬不再走欧洲 TLS 节点，台北/正声使用当前动态子列表，且不会请求过期 `chunklist`。
27. 连续播放 B1、B2、B3 等 `Transfer-Encoding: chunked` 且无 `icy-metaint` 的 MP3，确认没有 HTTP 分块字节造成的杂音。
28. 播放电台后暂停 30 秒再恢复，确认先播放当前直播而不是恢复暂停前的 PCM 积压。
29. 快速切换电台并触发备用线路，确认旧台 AudioRenderer 完全释放后才出现新台声音。
30. 播放中关闭蓝牙输出，确认立即停止、后台任务释放、锁屏不再显示暂停媒体卡片；同一设备在窗口内重连时按设置自动续播。

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
| 蓝牙设备识别、断开立即停止、可配置窗口重续播 | 原生 A2DP 实现；v1.0.29 待重新连接手机复核 |
| 自动/手动更新、GitHub、版本信息 | 已实现 |
| 安装后的 App 图标 | 按 `v1.0.8` 自适应图标背景色与前景矢量生成 |
