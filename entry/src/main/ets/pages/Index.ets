import { abilityAccessCtrl, autoStartupManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AppSettings,
  copyStation,
  copySettings,
  createDefaultSettings,
  Station,
  StreamLine
} from '../models/Station';
import { StationRepository } from '../data/StationRepository';
import { RadioController, RadioSnapshot, RadioStateListener } from '../services/RadioController';
import { WebDavBackupService, WebDavConfig } from '../services/WebDavBackupService';
import { isZipBackupFileName, orderStationsByBackup, WebDavBackupEntry } from '../utils/BackupModel';
import { isSearchStationAdded, shouldShowSearchResults } from '../utils/SearchModel';
import { AppUpdateService, NativeUpdateInfo } from '../services/AppUpdateService';
import { StationIconPicker } from '../services/StationIconPicker';
import { AndroidBackupArchiveFiles, LocalFileService } from '../services/LocalFileService';
import { AndroidBackupSettingsPatch, parseAndroidV108Backup } from '../utils/AndroidBackupModel';
import { M3uPlaylistService, M3uEntry } from '../services/M3uPlaylistService';
import { StationSearchService } from '../services/StationSearchService';
import { findTheme, THEME_PRESETS, ThemePreset } from '../models/ThemePreset';
import { formatSleepTimerEnd, normalizeResumeWindowMinutes } from '../utils/TimeSettings';
import { moveListItem } from '../utils/ListOrdering';
import { BackupArchiveService, QyfmBackupArchivePackage } from '../services/BackupArchiveService';
import { isQyfmBackupPlaylist, parseQyfmBackupArchive } from '../utils/QyfmBackupArchive';
import {
  BluetoothBinding,
  replaceBluetoothBinding
} from '../utils/BluetoothBindings';
import {
  StationSwipeAction,
  stationRowTapAction,
  stationSwipeActions
} from '../utils/StationInteraction';

const COLOR_DANGER_BG: string = '#E9B7B3';
const COLOR_DANGER: string = '#B3261E';
const STATION_SWIPE_ACTION_WIDTH: number = 136;

@Entry
@Component
struct Index {
  @State stations: Station[] = [];
  @State currentStation: Station | undefined = undefined;
  @State isPlaying: boolean = false;
  @State waitingForBluetooth: boolean = false;
  @State playbackStatus: string = '选择电台后开始播放';
  @State diagnostics: string = '蓝牙监听尚未启动';
  @State autoStartupStatus: string = '正在检查系统自动启动状态';
  @State pendingBluetoothBinding: BluetoothBinding | undefined = undefined;
  @State sleepTimerMinutes: number = 0;
  @State sleepTimerEndAt: number = 0;
  @State showSleepPanel: boolean = false;
  @State showSettings: boolean = false;
  @State showEditor: boolean = false;
  @State showWebDav: boolean = false;
  @State showTheme: boolean = false;
  @State showResumeWindow: boolean = false;
  @State pendingDelete: Station | undefined = undefined;
  @State swipedStationId: string = '';
  @State swipingStationId: string = '';
  @State stationSwipeDistance: number = 0;
  @State searchQuery: string = '';
  @State searchResults: Station[] = [];
  @State searching: boolean = false;
  @State palette: ThemePreset = findTheme('lunar_light');
  @State editorIsNew: boolean = true;
  @State editorId: string = '';
  @State editorName: string = '';
  @State editorUrl: string = '';
  @State editorIcon: string = '';
  @State editorTags: string = '';
  @State settings: AppSettings = createDefaultSettings();
  @State settingsStatus: string = '';
  @State updateInfo: NativeUpdateInfo | undefined = undefined;
  @State downloadingUpdate: boolean = false;
  @State updateDownloadPath: string = '';
  @State updateStatus: string = '';
  @State busy: boolean = false;
  @State webDavBackups: WebDavBackupEntry[] = [];
  @State selectedWebDavFile: string = '';
  @State loadingWebDavVersions: boolean = false;
  @State webDavZipFile: string = 'quyang_backup_20261112_102536.zip';

  private repository: StationRepository = new StationRepository();
  private radio: RadioController = RadioController.getInstance();
  private webDav: WebDavBackupService = new WebDavBackupService();
  private updateService: AppUpdateService = new AppUpdateService();
  private iconPicker: StationIconPicker = new StationIconPicker();
  private localFiles: LocalFileService = new LocalFileService();
  private m3u: M3uPlaylistService = new M3uPlaylistService();
  private searchService: StationSearchService = new StationSearchService();
  private backupArchives: BackupArchiveService = new BackupArchiveService();
  private abilityContext: common.UIAbilityContext | undefined = undefined;

  private readonly snapshotListener: RadioStateListener = (snapshot: RadioSnapshot): void => {
    if (snapshot.currentStation !== undefined) {
      this.currentStation = snapshot.currentStation;
    }
    this.isPlaying = snapshot.isPlaying;
    this.waitingForBluetooth = snapshot.waitingForBluetooth;
    this.playbackStatus = snapshot.statusText;
    this.diagnostics = snapshot.diagnostics;
    this.sleepTimerMinutes = snapshot.sleepTimerMinutes;
    this.sleepTimerEndAt = snapshot.sleepTimerEndAt;
    this.pendingBluetoothBinding = snapshot.pendingBluetoothBinding;
    if (JSON.stringify(this.settings.bluetoothBindings) !==
      JSON.stringify(snapshot.bluetoothBindings)) {
      const settings = copySettings(this.settings);
      settings.bluetoothBindings = snapshot.bluetoothBindings.map(
        (binding: BluetoothBinding): BluetoothBinding => {
          return {
            deviceId: binding.deviceId,
            deviceName: binding.deviceName,
            autoPlay: binding.autoPlay,
            lastConnectedAt: binding.lastConnectedAt
          };
        }
      );
      this.settings = settings;
      this.repository.saveSettings(settings).catch((error: BusinessError) => {
        console.error(`保存蓝牙绑定失败: ${error.message}`);
      });
    }
  };

  aboutToAppear(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.radio.unsubscribe(this.snapshotListener);
  }

  private async bootstrap(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.abilityContext = context;
    try {
      await this.repository.init(context);
      this.stations = await this.repository.loadStations();
      this.settings = await this.repository.loadSettings();
      await this.requestBluetoothPermission(context);
      await this.refreshAutoStartupStatus();
      await this.radio.init(context, this.settings);
      this.radio.subscribe(this.snapshotListener);
      this.palette = findTheme(this.settings.themeId);
      const remembered = this.stations.find((station: Station) => station.id === this.settings.lastStationId);
      if (remembered !== undefined) {
        this.currentStation = remembered;
      } else if (this.stations.length > 0) {
        this.currentStation = this.stations[0];
      }
      if (this.currentStation !== undefined) {
        this.radio.setDefaultStation(this.currentStation);
      }
      if (this.settings.autoPlayOnLaunch && this.currentStation !== undefined) {
        await this.playStation(this.currentStation);
      }
      if (this.settings.autoUpdate) {
        await this.checkForUpdates(false);
      }
    } catch (error) {
      const businessError = error as BusinessError;
      this.playbackStatus = `初始化失败：${businessError.message ?? '未知错误'}`;
    }
  }

  private async requestBluetoothPermission(context: common.UIAbilityContext): Promise<void> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      await manager.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
    } catch (error) {
      const businessError = error as BusinessError;
      this.diagnostics = `蓝牙权限申请返回：${businessError.code}`;
    }
  }

  private async refreshAutoStartupStatus(): Promise<void> {
    try {
      if (!autoStartupManager.isAutoStartupSupported()) {
        this.autoStartupStatus = '当前设备不支持应用自动启动';
        return;
      }
      const enabled = await autoStartupManager.getAutoStartupStatusForSelf();
      this.autoStartupStatus = enabled
        ? '系统自动启动已开启'
        : '系统未开启自动启动；请在系统设置中允许 QYFM 自启动';
    } catch (error) {
      const businessError = error as BusinessError;
      this.autoStartupStatus = `自动启动状态读取失败：${businessError.code}`;
    }
  }

  private async playStation(station: Station): Promise<void> {
    this.currentStation = station;
    const playbackTask = this.radio.playStation(station);
    if (this.settings.playbackMemory) {
      const settings = copySettings(this.settings);
      settings.lastStationId = station.id;
      this.settings = settings;
      this.repository.saveSettings(settings).catch((error: BusinessError) => {
        console.error(`保存最后电台失败: ${error.message ?? '未知错误'}`);
      });
    }
    await playbackTask;
  }

  private activateStation(station: Station): void {
    if (this.swipedStationId.length > 0) {
      this.swipedStationId = '';
      return;
    }
    if (this.settings.clickStationToPlay) {
      if (this.currentStation?.id === station.id) {
        this.togglePlayback();
      } else {
        this.playStation(station);
      }
    }
  }

  private async togglePlayback(): Promise<void> {
    if (this.currentStation === undefined) {
      this.playbackStatus = '请先选择一个电台';
      return;
    }
    if (!this.isPlaying) {
      await this.playStation(this.currentStation);
      return;
    }
    await this.radio.pause('已暂停', true);
  }

  private openNewStation(): void {
    this.editorIsNew = true;
    this.editorId = `station-${Date.now()}`;
    this.editorName = '';
    this.editorUrl = '';
    this.editorIcon = '';
    this.editorTags = '';
    this.showEditor = true;
  }

  private openStationEditor(station: Station): void {
    this.editorIsNew = false;
    this.editorId = station.id;
    this.editorName = station.name;
    this.editorUrl = station.streamUrl;
    this.editorIcon = station.iconUrl;
    this.editorTags = station.tags;
    this.showEditor = true;
  }

  private async saveStation(): Promise<void> {
    const name = this.editorName.trim();
    const url = this.editorUrl.trim();
    if (name.length === 0 || (!url.startsWith('http://') && !url.startsWith('https://'))) {
      this.playbackStatus = '电台名称不能为空，播放地址必须以 http:// 或 https:// 开头';
      return;
    }
    const existing = this.stations.find((station: Station) => station.id === this.editorId);
    const existingLines = existing?.streamLines?.map((line: StreamLine): StreamLine => {
      return {
        id: line.id,
        name: line.name,
        url: line.url,
        priority: line.priority,
        isStable: line.isStable
      };
    }) ?? [];
    const requestedLineIndex = existing?.activeLineIndex ?? 0;
    const activeLineIndex = existingLines.length > 0
      ? Math.max(0, Math.min(requestedLineIndex, existingLines.length - 1))
      : 0;
    if (existingLines.length === 0) {
      existingLines.push({
        id: 'default',
        name: '自定义主线',
        url: url,
        priority: 1,
        isStable: false
      });
    } else {
      existingLines[activeLineIndex].url = url;
    }
    const nextStation: Station = {
      id: this.editorId,
      name: name,
      streamUrl: url,
      streamLines: existingLines,
      activeLineIndex: activeLineIndex,
      iconUrl: this.editorIcon,
      tags: this.editorTags.trim(),
      country: existing?.country ?? '自定义',
      state: existing?.state ?? '',
      favorite: true
    };
    const nextStations = this.stations.map((station: Station) => {
      if (station.id === nextStation.id) {
        return nextStation;
      }
      return station;
    });
    if (!nextStations.some((station: Station) => station.id === nextStation.id)) {
      nextStations.push(nextStation);
    }
    this.stations = nextStations;
    this.currentStation = nextStation;
    await this.repository.saveStations(this.stations);
    this.showEditor = false;
    this.playbackStatus = '电台已保存';
  }

  private async deleteStation(id: string): Promise<void> {
    if (!this.settings.editMode) {
      return;
    }
    this.stations = this.stations.filter((station: Station) => station.id !== id);
    if (this.currentStation?.id === id) {
      await this.radio.stop();
      this.currentStation = this.stations.length > 0 ? this.stations[0] : undefined;
    }
    await this.repository.saveStations(this.stations);
    this.playbackStatus = '电台已删除';
  }

  private moveStationByIndex(from: number, to: number): void {
    if (from === to || from < 0 || to < 0 || from >= this.stations.length ||
      to >= this.stations.length) {
      return;
    }
    this.closeStationSwipe();
    this.stations = moveListItem(this.stations, from, to);
    this.repository.saveStations(this.stations).then(() => {
      this.playbackStatus = '电台顺序已保存';
    });
  }

  private async pickStationIcon(): Promise<void> {
    try {
      const icon = await this.iconPicker.pick();
      if (icon.length > 0) {
        this.editorIcon = icon;
      }
    } catch (error) {
      const businessError = error as BusinessError;
      this.playbackStatus = businessError.message;
    }
  }

  private async persistSettings(): Promise<void> {
    const settings = copySettings(this.settings);
    this.settings = settings;
    await this.repository.saveSettings(settings);
    await this.radio.applySettings(settings);
    this.settingsStatus = '设置已保存';
  }

  private updateWebDavUrl(value: string): void {
    const settings = copySettings(this.settings);
    settings.webdavUrl = value;
    this.settings = settings;
  }

  private updateWebDavUser(value: string): void {
    const settings = copySettings(this.settings);
    settings.webdavUser = value;
    this.settings = settings;
  }

  private updateWebDavPassword(value: string): void {
    const settings = copySettings(this.settings);
    settings.webdavPassword = value;
    this.settings = settings;
  }

  private updateWebDavFile(value: string): void {
    const settings = copySettings(this.settings);
    settings.webdavFile = value;
    this.settings = settings;
  }

  private webDavConfig(): WebDavConfig {
    return {
      baseUrl: this.settings.webdavUrl,
      user: this.settings.webdavUser,
      password: this.settings.webdavPassword,
      fileName: this.settings.webdavFile
    };
  }

  private async testWebDav(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.settingsStatus = '正在连接 WebDAV…';
    try {
      await this.webDav.testConnection(this.webDavConfig());
      this.settingsStatus = 'WebDAV 连接成功';
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    } finally {
      this.busy = false;
    }
  }

  private async backupToWebDav(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.settingsStatus = '正在上传电台、台标和顺序…';
    try {
      await this.repository.saveSettings(this.settings);
      if (this.abilityContext === undefined) {
        throw new Error('应用上下文尚未初始化');
      }
      const archive = await this.backupArchives.createArchive(
        this.abilityContext,
        this.stations,
        this.settings,
        this.settings.webdavFile
      );
      const entry = await this.webDav.uploadBackup(
        this.webDavConfig(),
        archive.data,
        archive.exportedAt,
        archive.stationCount,
        archive.appVersion
      );
      this.webDavBackups = await this.webDav.listBackups(this.webDavConfig());
      this.selectedWebDavFile = entry.fileName;
      this.settingsStatus = `备份完成：已生成 ${entry.fileName}`;
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    } finally {
      this.busy = false;
    }
  }

  private async restoreFromWebDav(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.selectedWebDavFile.length === 0) {
      this.settingsStatus = '请先从云端版本列表选择一个备份';
      return;
    }
    this.busy = true;
    this.settingsStatus = `正在恢复 ${this.selectedWebDavFile}…`;
    try {
      if (isZipBackupFileName(this.selectedWebDavFile)) {
        if (this.abilityContext === undefined) {
          throw new Error('应用上下文尚未初始化');
        }
        const data = await this.webDav.downloadBackupBytes(
          this.webDavConfig(),
          this.selectedWebDavFile
        );
        const archive = await this.localFiles.extractAndroidBackupZipBytes(
          this.abilityContext,
          data
        );
        await this.applyBackupArchive(archive, false);
        return;
      }
      const json = await this.webDav.downloadBackup(this.webDavConfig(), this.selectedWebDavFile);
      const result = this.repository.parseBackup(json);
      this.stations = result.stations;
      this.currentStation = this.stations.length > 0 ? this.stations[0] : undefined;
      result.settings.webdavPassword = this.settings.webdavPassword;
      this.settings = result.settings;
      await this.repository.saveStations(this.stations);
      await this.repository.saveSettings(this.settings);
      await this.radio.applySettings(this.settings);
      await this.radio.stop();
      this.settingsStatus = '恢复完成：所选版本、台标与播放顺序均已恢复';
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    } finally {
      this.busy = false;
    }
  }

  private async refreshWebDavBackups(): Promise<void> {
    if (this.loadingWebDavVersions || this.settings.webdavUrl.trim().length === 0) {
      return;
    }
    this.loadingWebDavVersions = true;
    this.settingsStatus = '正在读取云端备份版本…';
    try {
      this.webDavBackups = await this.webDav.listBackups(this.webDavConfig());
      const zipName = this.webDavZipFile.trim();
      if (isZipBackupFileName(zipName) &&
        await this.webDav.fileExists(this.webDavConfig(), zipName)) {
        const zipEntry: WebDavBackupEntry = {
          fileName: zipName,
          exportedAt: '',
          stationCount: 0,
          appVersion: 'Android v1.0.8 ZIP'
        };
        this.webDavBackups = [zipEntry].concat(this.webDavBackups);
      }
      if (!this.webDavBackups.some((entry: WebDavBackupEntry) =>
        entry.fileName === this.selectedWebDavFile)) {
        this.selectedWebDavFile = this.webDavBackups.length > 0 ? this.webDavBackups[0].fileName : '';
      }
      this.settingsStatus = this.webDavBackups.length > 0
        ? `找到 ${this.webDavBackups.length} 个云端备份`
        : '云端暂无备份版本';
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    } finally {
      this.loadingWebDavVersions = false;
    }
  }

  private webDavVersionLabel(entry: WebDavBackupEntry): string {
    if (entry.exportedAt.length === 0) {
      return entry.fileName;
    }
    const date = new Date(entry.exportedAt);
    if (Number.isNaN(date.getTime())) {
      return entry.fileName;
    }
    const year = date.getFullYear();
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hour = date.getHours().toString().padStart(2, '0');
    const minute = date.getMinutes().toString().padStart(2, '0');
    const second = date.getSeconds().toString().padStart(2, '0');
    return `${year}-${month}-${day} ${hour}:${minute}:${second}`;
  }

  private webDavEntryDetail(entry: WebDavBackupEntry): string {
    if (isZipBackupFileName(entry.fileName)) {
      if (entry.appVersion.includes('Android')) {
        return `旧版 Android v1.0.8 ZIP · ${entry.fileName}`;
      }
      return `${entry.stationCount} 个电台 · ZIP · ${entry.fileName}`;
    }
    return `${entry.stationCount} 个电台 · ${entry.fileName}`;
  }

  private async checkForUpdates(manual: boolean): Promise<void> {
    if (manual) {
      this.settingsStatus = '正在检查新版本…';
    }
    const release = await this.updateService.checkNativeRelease();
    if (release !== undefined) {
      this.updateInfo = release;
      this.updateDownloadPath = '';
      this.updateStatus = '';
      if (manual) {
        this.settingsStatus = `发现原生鸿蒙新版本 ${release.version}`;
      } else if (this.settings.autoUpdate) {
        await this.downloadUpdatePackage();
      }
      return;
    }
    if (this.abilityContext !== undefined) {
      const systemUpdate = await this.updateService.checkAppGallery(this.abilityContext);
      if (systemUpdate) {
        this.settingsStatus = '发现应用市场新版本';
        return;
      }
    }
    if (manual) {
      this.settingsStatus = '当前已是最新版本';
    }
  }

  private async openReleasePage(): Promise<void> {
    if (this.abilityContext === undefined || this.updateInfo === undefined) {
      return;
    }
    await this.updateService.openReleasePage(this.abilityContext, this.updateInfo.pageUrl);
    this.updateInfo = undefined;
  }

  private async downloadUpdatePackage(): Promise<boolean> {
    if (this.abilityContext === undefined || this.updateInfo === undefined) {
      return false;
    }
    if (this.downloadingUpdate) {
      return this.updateDownloadPath.length > 0;
    }
    this.downloadingUpdate = true;
    this.updateStatus = '正在从 GitHub 下载更新…';
    try {
      this.updateDownloadPath = await this.updateService.downloadHap(
        this.abilityContext,
        this.updateInfo
      );
      this.updateStatus = '更新已下载，可立即安装';
      return true;
    } catch (error) {
      const businessError = error as BusinessError;
      this.updateDownloadPath = '';
      this.updateStatus = businessError.message;
      return false;
    } finally {
      this.downloadingUpdate = false;
    }
  }

  private async installDownloadedUpdate(): Promise<void> {
    if (this.abilityContext === undefined || this.updateInfo === undefined) {
      return;
    }
    if (this.updateDownloadPath.length === 0 && !(await this.downloadUpdatePackage())) {
      return;
    }
    try {
      this.updateStatus = '正在打开系统安装页面…';
      await this.updateService.installHap(this.abilityContext, this.updateDownloadPath);
      this.updateStatus = '已打开安装方式选择页，请选择应用安装器并确认安装';
    } catch (error) {
      const businessError = error as BusinessError;
      this.updateStatus =
        `系统未开放直接安装入口：${businessError.message ?? '未知错误'}。请保存安装包后手动打开。`;
      await this.saveUpdateForManualInstall();
    }
  }

  private async saveUpdateForManualInstall(): Promise<void> {
    if (this.abilityContext === undefined || this.updateDownloadPath.length === 0 ||
      this.updateInfo === undefined) {
      return;
    }
    const separator = Math.max(
      this.updateDownloadPath.lastIndexOf('/'),
      this.updateDownloadPath.lastIndexOf('\\')
    );
    const fileName = separator >= 0
      ? this.updateDownloadPath.substring(separator + 1)
      : this.updateInfo.assetName;
    let savedUri = '';
    try {
      savedUri = await this.localFiles.saveFileFromPath(
        this.abilityContext,
        fileName,
        this.updateDownloadPath
      );
      if (savedUri.length === 0) {
        this.updateStatus = '已取消保存安装包';
        return;
      }
      this.updateStatus = '安装包已保存，正在打开系统安装器…';
      await this.updateService.installUri(this.abilityContext, savedUri, fileName);
      this.updateStatus = '已打开安装方式选择页，请选择应用安装器并确认安装';
    } catch (error) {
      const businessError = error as BusinessError;
      if (savedUri.length === 0) {
        this.updateStatus =
          `保存安装包失败：${businessError.message ?? '未知错误'}`;
        return;
      }
      try {
        await this.updateService.openFileManager(this.abilityContext, savedUri);
        this.updateStatus = '安装包已保存，已打开所在文件夹；请点击安装包并在系统中确认';
      } catch (fileManagerError) {
        const managerError = fileManagerError as BusinessError;
        this.updateStatus =
          `安装包已保存，但安装器和文件管理器均无法打开：${businessError.message ?? '未知错误'}；` +
          `${managerError.message ?? '未知错误'}`;
      }
    }
  }

  private async downloadAndInstallUpdate(): Promise<void> {
    if (await this.downloadUpdatePackage()) {
      await this.installDownloadedUpdate();
    }
  }

  private updateEditMode(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.editMode = value;
    this.settings = settings;
    if (!value) {
      this.closeStationSwipe();
    }
    this.persistSettings();
  }

  private beginStationSwipe(stationId: string): void {
    if (!this.settings.editMode) {
      return;
    }
    if (this.swipedStationId.length > 0 && this.swipedStationId !== stationId) {
      this.swipedStationId = '';
    }
    this.swipingStationId = stationId;
    this.stationSwipeDistance = 0;
  }

  private updateStationSwipe(stationId: string, offset: number): void {
    if (!this.settings.editMode) {
      return;
    }
    this.swipingStationId = stationId;
    this.stationSwipeDistance = Math.max(-STATION_SWIPE_ACTION_WIDTH, Math.min(0, offset));
    if (this.stationSwipeDistance <= -32) {
      this.swipedStationId = stationId;
    }
  }

  private finishStationSwipe(stationId: string, offset: number): void {
    if (!this.settings.editMode) {
      this.closeStationSwipe();
      return;
    }
    const finalOffset = Math.min(offset, this.stationSwipeDistance);
    this.swipedStationId = finalOffset <= -32 ? stationId : '';
    this.swipingStationId = '';
    this.stationSwipeDistance = 0;
  }

  private cancelStationSwipe(): void {
    this.swipingStationId = '';
    this.stationSwipeDistance = 0;
  }

  private closeStationSwipe(): void {
    this.swipedStationId = '';
    this.cancelStationSwipe();
  }

  private stationSwipeOffset(stationId: string): number {
    if (!this.settings.editMode) {
      return 0;
    }
    if (this.swipedStationId === stationId) {
      return -STATION_SWIPE_ACTION_WIDTH;
    }
    if (this.swipingStationId === stationId) {
      return this.stationSwipeDistance;
    }
    return 0;
  }

  private updateAutoUpdate(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.autoUpdate = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updateAutoResume(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.autoResume = value;
    this.settings = settings;
    this.radio.applySettings(settings);
    this.persistSettings();
  }

  private async updateResumeWindowMinutes(minutes: number): Promise<void> {
    const settings = copySettings(this.settings);
    settings.resumeWindowMinutes = normalizeResumeWindowMinutes(minutes);
    this.settings = settings;
    this.showResumeWindow = false;
    await this.radio.applySettings(this.settings);
    await this.persistSettings();
    this.settingsStatus = `蓝牙续播窗口已设为 ${this.settings.resumeWindowMinutes} 分钟`;
  }

  private updateBluetoothBindingAutoPlay(deviceId: string, value: boolean): void {
    const settings = copySettings(this.settings);
    settings.bluetoothBindings = settings.bluetoothBindings.map(
      (binding: BluetoothBinding): BluetoothBinding => {
        return {
          deviceId: binding.deviceId,
          deviceName: binding.deviceName,
          autoPlay: binding.deviceId === deviceId ? value : binding.autoPlay,
          lastConnectedAt: binding.lastConnectedAt
        };
      }
    );
    this.settings = settings;
    this.persistSettings();
    this.settingsStatus = value
      ? (this.settings.autoPlayOnBluetoothConnect
        ? '该蓝牙设备已设为连接后自动播放'
        : '该设备已勾选；打开下方“蓝牙自动播放总开关”后生效')
      : '该蓝牙设备已设为连接后不自动播放';
  }

  private deleteBluetoothBinding(deviceId: string): void {
    const settings = copySettings(this.settings);
    const pending = this.pendingBluetoothBinding;
    const bindings = replaceBluetoothBinding(settings.bluetoothBindings, deviceId, pending);
    if (pending !== undefined) {
      this.radio.clearPendingBluetoothBinding();
      this.pendingBluetoothBinding = undefined;
    }
    settings.bluetoothBindings = bindings;
    this.settings = settings;
    this.persistSettings();
    this.settingsStatus = pending === undefined
      ? '已删除该蓝牙设备记录；下次连接时会重新绑定'
      : `已用 ${pending.deviceName} 替换该绑定，可设置是否自动连接播放`;
  }

  private updateDynamicColor(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.dynamicColor = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updateTransparentUi(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.transparentUi = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updateClickStation(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.clickStationToPlay = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updateAutoPlayOnLaunch(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.autoPlayOnLaunch = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updatePlaybackMemory(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.playbackMemory = value;
    if (!value) {
      settings.lastStationId = '';
    }
    this.settings = settings;
    this.persistSettings();
  }

  private updateFastStart(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.fastStart = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updateLargeBuffer(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.largeBuffer = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updateEditStreamUrl(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.editStreamUrl = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updatePauseOnUnplug(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.pauseOnUnplug = value;
    this.settings = settings;
    this.persistSettings();
  }

  private updatePauseOnBluetoothDisconnect(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.pauseOnBluetoothDisconnect = value;
    this.settings = settings;
    this.radio.applySettings(settings);
    this.persistSettings();
  }

  private updateAutoPlayOnBluetoothConnect(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.autoPlayOnBluetoothConnect = value;
    this.settings = settings;
    this.radio.applySettings(settings);
    this.persistSettings();
  }

  private updateIcecastCompatibility(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.icecastCompatibility = value;
    this.settings = settings;
    this.radio.applySettings(settings);
    this.persistSettings();
  }

  private updateFfmpegDecoder(value: boolean): void {
    const settings = copySettings(this.settings);
    settings.ffmpegDecoder = value;
    this.settings = settings;
    this.radio.applySettings(settings);
    this.persistSettings();
  }

  private async selectTheme(theme: ThemePreset): Promise<void> {
    const settings = copySettings(this.settings);
    settings.themeId = theme.id;
    this.settings = settings;
    this.palette = theme;
    this.showTheme = false;
    await this.persistSettings();
  }

  private async searchStations(): Promise<void> {
    if (this.searchQuery.trim().length === 0) {
      this.searchResults = [];
      return;
    }
    if (this.searching) {
      return;
    }
    this.searching = true;
    this.settingsStatus = '正在搜索电台…';
    try {
      this.searchResults = await this.searchService.search(this.searchQuery);
      this.settingsStatus = this.searchResults.length > 0 ? `找到 ${this.searchResults.length} 个电台` : '没有找到电台';
    } finally {
      this.searching = false;
    }
  }

  private async addSearchStation(station: Station): Promise<void> {
    if (isSearchStationAdded(this.stations, station)) {
      this.settingsStatus = '该电台已在播放列表中';
      return;
    }
    this.stations = [station].concat(this.stations);
    await this.repository.saveStations(this.stations);
    this.settingsStatus = `已添加：${station.name}`;
  }

  private updateSearchQuery(value: string): void {
    this.searchQuery = value;
    this.searchResults = [];
    if (value.trim().length === 0) {
      this.settingsStatus = '';
    }
  }

  private isStationSaved(station: Station): boolean {
    return isSearchStationAdded(this.stations, station);
  }

  private async importM3uFile(): Promise<void> {
    if (this.abilityContext === undefined) {
      return;
    }
    try {
      const text = await this.localFiles.pickText(this.abilityContext, 'M3U 播放列表|.m3u,.m3u8,.txt');
      if (text.length === 0) {
        return;
      }
      const entries = this.m3u.parse(text);
      let added = 0;
      entries.forEach((entry: M3uEntry) => {
        if (this.stations.some((station: Station) => station.streamUrl === entry.url)) {
          return;
        }
        const importedStation: Station = {
          id: `m3u-${Date.now()}-${added}`,
          name: entry.name,
          streamUrl: entry.url,
          iconUrl: entry.iconUrl,
          tags: 'M3U',
          country: 'M3U导入',
          state: 'M3U',
          favorite: false
        };
        this.stations = [importedStation].concat(this.stations);
        added++;
      });
      await this.repository.saveStations(this.stations);
      this.settingsStatus = added > 0 ? `已导入 ${added} 个电台` : '没有新的可导入电台';
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    }
  }

  private async exportM3uFile(): Promise<void> {
    if (this.abilityContext === undefined) {
      return;
    }
    try {
      await this.localFiles.saveText(
        this.abilityContext,
        'QYFM_电台列表.m3u',
        this.m3u.build(this.stations)
      );
      this.settingsStatus = 'M3U 已导出';
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    }
  }

  private async backupLocalFile(): Promise<void> {
    if (this.abilityContext === undefined) {
      return;
    }
    try {
      const archive: QyfmBackupArchivePackage = await this.backupArchives.createArchive(
        this.abilityContext,
        this.stations,
        this.settings,
        'qyfm-backup.zip'
      );
      const uri = await this.localFiles.saveFileFromPath(
        this.abilityContext,
        archive.fileName,
        archive.path
      );
      this.settingsStatus = uri.length > 0 ? '本地 ZIP 备份已保存' : '已取消保存备份';
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    }
  }

  private async restoreLocalFile(): Promise<void> {
    if (this.abilityContext === undefined) {
      return;
    }
    try {
      const picked = await this.localFiles.pickBackup(this.abilityContext);
      if (picked === undefined) {
        return;
      }
      if (picked.isZip) {
        if (picked.archive === undefined) {
          throw new Error('无法读取备份压缩包');
        }
        await this.applyBackupArchive(picked.archive, true);
        return;
      }
      const result = this.repository.parseBackup(picked.text);
      this.stations = result.stations;
      result.settings.webdavPassword = this.settings.webdavPassword;
      this.settings = result.settings;
      this.palette = findTheme(this.settings.themeId);
      this.currentStation = this.stations.length > 0 ? this.stations[0] : undefined;
      await this.repository.saveStations(this.stations);
      await this.repository.saveSettings(this.settings);
      await this.radio.stop();
      await this.radio.applySettings(this.settings);
      this.settingsStatus = `已恢复 ${this.stations.length} 个电台`;
    } catch (error) {
      const businessError = error as BusinessError;
      this.settingsStatus = businessError.message;
    }
  }

  private async applyBackupArchive(archive: AndroidBackupArchiveFiles, local: boolean): Promise<void> {
    if (isQyfmBackupPlaylist(archive.qyfmPlaylistText)) {
      const restored = parseQyfmBackupArchive(
        archive.qyfmPlaylistText,
        archive.qyfmOrderText,
        archive.qyfmSettingsText,
        archive.logos
      );
      this.stations = restored.stations.map((station): Station => {
        return {
          id: station.id,
          name: station.name,
          streamUrl: station.streamUrl,
          streamLines: station.streamLines,
          activeLineIndex: station.activeLineIndex,
          iconUrl: station.iconUrl,
          tags: station.tags,
          country: station.country,
          state: station.state,
          favorite: station.favorite
        };
      });
      const settings = copySettings(this.settings);
      settings.autoUpdate = restored.settings.autoUpdate;
      settings.autoResume = restored.settings.autoResume;
      settings.resumeWindowMinutes = restored.settings.resumeWindowMinutes;
      settings.editMode = restored.settings.editMode;
      settings.editStreamUrl = restored.settings.editStreamUrl;
      settings.themeId = restored.settings.themeId;
      settings.dynamicColor = restored.settings.dynamicColor;
      settings.transparentUi = restored.settings.transparentUi;
      settings.clickStationToPlay = restored.settings.clickStationToPlay;
      settings.autoPlayOnLaunch = restored.settings.autoPlayOnLaunch;
      settings.playbackMemory = restored.settings.playbackMemory;
      settings.fastStart = restored.settings.fastStart;
      settings.largeBuffer = restored.settings.largeBuffer;
      settings.pauseOnUnplug = restored.settings.pauseOnUnplug;
      settings.pauseOnBluetoothDisconnect = restored.settings.pauseOnBluetoothDisconnect;
      settings.autoPlayOnBluetoothConnect = restored.settings.autoPlayOnBluetoothConnect;
      settings.icecastCompatibility = restored.settings.icecastCompatibility;
      settings.ffmpegDecoder = restored.settings.ffmpegDecoder;
      settings.lastStationId = restored.settings.lastStationId;
      settings.webdavUrl = restored.settings.webdavUrl;
      settings.webdavUser = restored.settings.webdavUser;
      settings.webdavFile = restored.settings.webdavFile;
      settings.bluetoothBindings = restored.settings.bluetoothBindings.map(
        (binding): BluetoothBinding => {
          return {
            deviceId: binding.deviceId,
            deviceName: binding.deviceName,
            autoPlay: binding.autoPlay,
            lastConnectedAt: binding.lastConnectedAt
          };
        }
      );
      this.settings = settings;
      this.palette = findTheme(this.settings.themeId);
      this.currentStation = this.stations.length > 0 ? this.stations[0] : undefined;
      await this.repository.saveStations(this.stations);
      await this.repository.saveSettings(this.settings);
      await this.radio.stop();
      await this.radio.applySettings(this.settings);
      this.settingsStatus =
        `${local ? '本地' : '云端'} ZIP 已恢复 ${this.stations.length} 个电台、台标和原顺序`;
      return;
    }
    await this.applyAndroidBackupArchive(archive);
    this.settingsStatus =
      `${local ? '本地' : '云端'} v1.0.8 ZIP 已恢复 ${this.stations.length} 个电台、台标和原顺序`;
  }

  private async applyAndroidBackupArchive(archive: AndroidBackupArchiveFiles): Promise<void> {
    const restored = parseAndroidV108Backup(
      archive.manifestText,
      archive.playlistText,
      archive.playlistM3uText,
      archive.settingsText,
      archive.logos
    );
    const ordered = orderStationsByBackup(restored.stations, restored.stationOrder);
    this.stations = ordered.map((station): Station => {
      return {
        id: station.id,
        name: station.name,
        streamUrl: station.streamUrl,
        streamLines: station.streamLines,
        activeLineIndex: station.activeLineIndex,
        iconUrl: station.iconUrl,
        tags: station.tags,
        country: station.country,
        state: station.state,
        favorite: station.favorite
      };
    });
    const settings = copySettings(this.settings);
    settings.webdavPassword = this.settings.webdavPassword;
    this.applyAndroidBackupSettings(settings, restored.settings);
    this.settings = settings;
    this.palette = findTheme(this.settings.themeId);
    this.currentStation = this.stations.length > 0 ? this.stations[0] : undefined;
    await this.repository.saveStations(this.stations);
    await this.repository.saveSettings(this.settings);
    await this.radio.stop();
    await this.radio.applySettings(this.settings);
  }

  private applyAndroidBackupSettings(settings: AppSettings, patch: AndroidBackupSettingsPatch): void {
    if (patch.dynamicColor !== undefined) {
      settings.dynamicColor = patch.dynamicColor;
    }
    if (patch.transparentUi !== undefined) {
      settings.transparentUi = patch.transparentUi;
    }
    if (patch.clickStationToPlay !== undefined) {
      settings.clickStationToPlay = patch.clickStationToPlay;
    }
    if (patch.editMode !== undefined) {
      settings.editMode = patch.editMode;
    }
    if (patch.editStreamUrl !== undefined) {
      settings.editStreamUrl = patch.editStreamUrl;
    }
    if (patch.autoPlayOnLaunch !== undefined) {
      settings.autoPlayOnLaunch = patch.autoPlayOnLaunch;
    }
    if (patch.playbackMemory !== undefined) {
      settings.playbackMemory = patch.playbackMemory;
    }
    if (patch.fastStart !== undefined) {
      settings.fastStart = patch.fastStart;
    }
    if (patch.largeBuffer !== undefined) {
      settings.largeBuffer = patch.largeBuffer;
    }
    if (patch.pauseOnUnplug !== undefined) {
      settings.pauseOnUnplug = patch.pauseOnUnplug;
    }
    if (patch.autoUpdate !== undefined) {
      settings.autoUpdate = patch.autoUpdate;
    }
    if (patch.webdavUrl !== undefined) {
      settings.webdavUrl = patch.webdavUrl;
    }
    if (patch.webdavUser !== undefined) {
      settings.webdavUser = patch.webdavUser;
    }
    if (patch.webdavFile !== undefined) {
      settings.webdavFile = patch.webdavFile;
    }
  }

  private async openGithubPage(): Promise<void> {
    if (this.abilityContext !== undefined) {
      await this.abilityContext.openLink('https://github.com/zzg341125/QYFM-HM');
    }
  }

  private primaryColor(): string {
    return this.settings.dynamicColor ? this.palette.primary : '#56698C';
  }

  private settingValue(key: string): boolean {
    switch (key) {
      case 'dynamicColor':
        return this.settings.dynamicColor;
      case 'transparentUi':
        return this.settings.transparentUi;
      case 'clickStation':
        return this.settings.clickStationToPlay;
      case 'autoPlay':
        return this.settings.autoPlayOnLaunch;
      case 'playbackMemory':
        return this.settings.playbackMemory;
      case 'fastStart':
        return this.settings.fastStart;
      case 'largeBuffer':
        return this.settings.largeBuffer;
      case 'editMode':
        return this.settings.editMode;
      case 'editStreamUrl':
        return this.settings.editStreamUrl;
      case 'pauseOnUnplug':
        return this.settings.pauseOnUnplug;
      case 'pauseOnBluetoothDisconnect':
        return this.settings.pauseOnBluetoothDisconnect;
      case 'autoPlayOnBluetoothConnect':
        return this.settings.autoPlayOnBluetoothConnect;
      case 'icecastCompatibility':
        return this.settings.icecastCompatibility;
      case 'ffmpegDecoder':
        return this.settings.ffmpegDecoder;
      case 'autoResume':
        return this.settings.autoResume;
      case 'autoUpdate':
        return this.settings.autoUpdate;
      default:
        return false;
    }
  }

  private updateSettingSwitch(key: string, value: boolean): void {
    switch (key) {
      case 'dynamicColor':
        this.updateDynamicColor(value);
        break;
      case 'transparentUi':
        this.updateTransparentUi(value);
        break;
      case 'clickStation':
        this.updateClickStation(value);
        break;
      case 'autoPlay':
        this.updateAutoPlayOnLaunch(value);
        break;
      case 'playbackMemory':
        this.updatePlaybackMemory(value);
        break;
      case 'fastStart':
        this.updateFastStart(value);
        break;
      case 'largeBuffer':
        this.updateLargeBuffer(value);
        break;
      case 'editMode':
        this.updateEditMode(value);
        break;
      case 'editStreamUrl':
        this.updateEditStreamUrl(value);
        break;
      case 'pauseOnUnplug':
        this.updatePauseOnUnplug(value);
        break;
      case 'pauseOnBluetoothDisconnect':
        this.updatePauseOnBluetoothDisconnect(value);
        break;
      case 'autoPlayOnBluetoothConnect':
        this.updateAutoPlayOnBluetoothConnect(value);
        break;
      case 'icecastCompatibility':
        this.updateIcecastCompatibility(value);
        break;
      case 'ffmpegDecoder':
        this.updateFfmpegDecoder(value);
        break;
      case 'autoResume':
        this.updateAutoResume(value);
        break;
      case 'autoUpdate':
        this.updateAutoUpdate(value);
        break;
      default:
        break;
    }
  }

  private async runSettingAction(action: string): Promise<void> {
    switch (action) {
      case 'theme':
        this.showTheme = true;
        break;
      case 'exportM3u':
        await this.exportM3uFile();
        break;
      case 'importM3u':
        await this.importM3uFile();
        break;
      case 'backupLocal':
        await this.backupLocalFile();
        break;
      case 'restoreLocal':
        await this.restoreLocalFile();
        break;
      case 'webdav':
        this.showWebDav = true;
        this.refreshWebDavBackups();
        break;
      case 'resumeWindow':
        this.showResumeWindow = true;
        break;
      case 'checkUpdate':
        await this.checkForUpdates(true);
        break;
      case 'github':
        await this.openGithubPage();
        break;
      case 'bluetoothPermission':
        if (this.abilityContext !== undefined) {
          await this.requestBluetoothPermission(this.abilityContext);
          this.settingsStatus = '蓝牙设备识别权限已请求';
        }
        break;
      case 'autoStartup':
        await this.refreshAutoStartupStatus();
        this.settingsStatus = this.autoStartupStatus;
        break;
      default:
        break;
    }
  }

  @Builder
  StationSwipeActions(station: Station) {
    Row({ space: 6 }) {
      ForEach(stationSwipeActions(this.settings.editMode), (action: StationSwipeAction) => {
        if (action === 'edit') {
          Text('编辑')
            .width(58)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontColor(this.primaryColor())
            .backgroundColor(this.palette.surface)
            .borderRadius(14)
            .border({ width: 1, color: this.primaryColor() })
            .onClick(() => {
              this.closeStationSwipe();
              this.openStationEditor(station);
            })
        } else {
          Text('删除')
            .width(58)
            .height(44)
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontColor(COLOR_DANGER)
            .backgroundColor(COLOR_DANGER_BG)
            .borderRadius(14)
            .border({ width: 1, color: COLOR_DANGER })
            .onClick(() => {
              this.pendingDelete = station;
            })
        }
      }, (action: StationSwipeAction) => action)
    }
    .width(STATION_SWIPE_ACTION_WIDTH)
    .height(64)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 18 })
  }

  @Builder
  StationRow(station: Station, index: number) {
    Row({ space: 18 }) {
      if (station.iconUrl.length > 0) {
        Image(station.iconUrl)
          .width(56)
          .height(56)
          .borderRadius(28)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.palette.surfaceVariant)
      } else {
        Stack() {
          Text('FM')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.palette.textSecondary)
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor(this.palette.surfaceVariant)
      }

      Text(station.name)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          if (stationRowTapAction(this.settings.editMode) === 'play') {
            this.activateStation(station);
          }
        })

      Text(this.currentStation?.id === station.id && this.isPlaying ? '■' : '▶︎')
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .fontSize(this.currentStation?.id === station.id ? 18 : 22)
        .fontColor(this.currentStation?.id === station.id
          ? this.primaryColor()
          : this.palette.textPrimary)
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          if (this.currentStation?.id === station.id) {
            this.togglePlayback();
          } else {
            this.playStation(station);
          }
        })

    }
    .width('100%')
    .height(100)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.palette.background)
  }

  @Builder
  StationListItemContent(station: Station, index: number) {
    Column() {
      this.StationRow(station, index)
      Divider()
        .strokeWidth(1)
        .color(this.palette.divider)
        .margin({ left: 16, right: 16 })
    }
  }

  @Builder
  SwipeableStationItem(station: Station, index: number) {
    Stack({ alignContent: Alignment.End }) {
      if (this.settings.editMode && this.swipedStationId === station.id) {
        this.StationSwipeActions(station)
      }
      Column() {
        this.StationListItemContent(station, index)
      }
      .width('100%')
      .translate({ x: this.stationSwipeOffset(station.id) })
    }
    .width('100%')
    .clip(true)
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 10 })
        .onActionStart(() => {
          this.beginStationSwipe(station.id);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.updateStationSwipe(station.id, event.offsetX);
        })
        .onActionEnd((event: GestureEvent) => {
          this.finishStationSwipe(station.id, event.offsetX);
        })
        .onActionCancel(() => {
          this.cancelStationSwipe();
        })
    )
  }

  @Builder
  HomeActions() {
    Column() {
      Row({ space: 10 }) {
        Button('＋  添加新电台')
          .layoutWeight(3)
          .height(52)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette.textPrimary)
          .backgroundColor(this.palette.surfaceVariant)
          .border({ width: 1, color: this.palette.divider })
          .borderRadius(26)
          .onClick(() => {
            this.openNewStation();
          })
        Button('⚙  设置')
          .layoutWeight(2)
          .height(52)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette.textPrimary)
          .backgroundColor(this.palette.surfaceVariant)
          .border({ width: 1, color: this.palette.divider })
          .borderRadius(26)
          .onClick(() => {
            this.showSettings = true;
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    }
    .width('100%')
  }

  @Builder
  SleepPanel() {
    Column({ space: 14 }) {
      Row() {
        Text('睡眠定时')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryColor())
        Blank()
        Text('收起')
          .fontSize(13)
          .fontColor(this.palette.textSecondary)
          .onClick(() => {
            this.showSleepPanel = false;
          })
      }
      .width('100%')
      Row({ space: 8 }) {
        this.SleepTimerButton('关闭', 0)
        this.SleepTimerButton('15 分', 15)
        this.SleepTimerButton('30 分', 30)
      }
      .width('100%')
      Row({ space: 8 }) {
        this.SleepTimerButton('45 分', 45)
        this.SleepTimerButton('60 分', 60)
      }
      .width('100%')
      if (this.sleepTimerMinutes > 0 && this.sleepTimerEndAt > 0) {
        Text(formatSleepTimerEnd(new Date(this.sleepTimerEndAt), 0))
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryColor())
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(26)
    .backgroundColor(this.palette.nowPlaying)
    .margin({ left: 14, right: 14, bottom: 8 })
  }

  @Builder
  SleepTimerButton(label: string, minutes: number) {
    Button(label)
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontColor(this.sleepTimerMinutes === minutes ? Color.White : this.palette.textPrimary)
      .backgroundColor(this.sleepTimerMinutes === minutes
        ? this.primaryColor()
        : this.palette.surfaceVariant)
      .borderRadius(22)
      .onClick(() => {
        this.radio.setSleepTimer(minutes);
        this.showSleepPanel = false;
      })
  }

  @Builder
  NowPlayingBar() {
    Row({ space: 14 }) {
      if (this.currentStation !== undefined && this.currentStation.iconUrl.length > 0) {
        Image(this.currentStation.iconUrl)
          .width(58)
          .height(58)
          .borderRadius(29)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.palette.surface)
      } else {
        Stack() {
          Text('FM')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryColor())
        }
        .width(58)
        .height(58)
        .borderRadius(29)
        .backgroundColor(this.palette.surface)
      }

      Column({ space: 2 }) {
        Text(this.currentStation?.name ?? '暂未选择电台')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.waitingForBluetooth ? '等待同一蓝牙设备重连' : this.playbackStatus)
          .fontSize(13)
          .fontColor(this.primaryColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.isPlaying ? 'Ⅱ' : '▶')
        .width(56)
        .height(56)
        .textAlign(TextAlign.Center)
        .fontSize(24)
        .fontColor(Color.White)
        .backgroundColor(this.primaryColor())
        .borderRadius(28)
        .onClick(() => {
          this.togglePlayback();
        })
    }
    .width('100%')
    .height(84)
    .padding({ left: 12, right: 8 })
    .borderRadius(30)
    .backgroundColor(this.palette.nowPlaying)
    .opacity(this.settings.transparentUi ? 0.88 : 1)
    .margin({ left: 14, right: 14, bottom: 10 })
    .onClick(() => {
      this.togglePlayback();
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.showSleepPanel = !this.showSleepPanel;
        })
    )
  }

  @Builder
  HomePage() {
    Column() {
      List() {
        ForEach(this.stations, (station: Station, index: number) => {
          ListItem() {
            this.SwipeableStationItem(station, index)
          }
          .onClick(() => {
            this.activateStation(station);
          })
        }, (station: Station) => station.id)
          .onMove((from: number, to: number) => {
            this.moveStationByIndex(from, to);
          }, {
            onLongPress: (index: number) => {
              const pressed = this.stations[index];
              if (pressed !== undefined && this.isPlaying &&
                this.currentStation?.id === pressed.id) {
                this.closeStationSwipe();
                this.showSleepPanel = !this.showSleepPanel;
              }
            }
          })

        ListItem() {
          this.HomeActions()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(10)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)

      if (this.showSleepPanel) {
        this.SleepPanel()
      }
      this.NowPlayingBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.background)
  }

  @Builder
  BluetoothBindingRow(binding: BluetoothBinding | undefined, slot: number) {
    Row({ space: 12 }) {
      Text(`${slot + 1}`)
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryColor())
        .backgroundColor(this.palette.surfaceVariant)
        .borderRadius(16)
      Column({ space: 3 }) {
        Text(binding === undefined ? `蓝牙设备 ${slot + 1}` : binding.deviceName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(binding === undefined ? this.palette.textSecondary : this.palette.textPrimary)
        Text(binding === undefined ? '连接一次蓝牙音频设备后自动记录' : binding.deviceId)
          .fontSize(11)
          .fontColor(this.palette.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (binding !== undefined) {
        Column({ space: 6 }) {
          Text('连接后自动播放')
            .fontSize(11)
            .fontColor(this.palette.textSecondary)
          Row() {
            Text(binding.autoPlay ? '开' : '关')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(binding.autoPlay ? this.palette.textPrimary : this.palette.textSecondary)
          }
          .width(72)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .borderRadius(16)
          .backgroundColor(binding.autoPlay ? this.primaryColor() : this.palette.surfaceVariant)
          .id(`bluetooth-auto-play-${slot}`)
          .onClick(() => {
            this.updateBluetoothBindingAutoPlay(binding.deviceId, !binding.autoPlay);
          })
          Text('删除记录')
            .fontSize(11)
            .fontColor('#FF8A80')
            .id(`bluetooth-delete-${slot}`)
            .onClick(() => {
              this.deleteBluetoothBinding(binding.deviceId);
            })
        }
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
  }

  @Builder
  SettingsSectionTitle(title: string) {
    Text(title)
      .width('100%')
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.palette.textSecondary)
      .padding({ left: 20, right: 20, top: 14, bottom: 4 })
  }

  @Builder
  SettingsDivider() {
    Divider()
      .strokeWidth(0.7)
      .color(this.palette.divider)
      .margin({ left: 20, right: 20, top: 8, bottom: 8 })
  }

  @Builder
  SettingsSwitchRow(icon: string, title: string, subtitle: string, key: string) {
    Row({ space: 16 }) {
      Text(icon)
        .width(36)
        .fontSize(21)
        .fontColor(this.palette.textPrimary)
      Column({ space: 4 }) {
        Text(title)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .onClick(() => {
            this.updateSettingSwitch(key, !this.settingValue(key));
          })
        Text(subtitle)
          .fontSize(15)
          .fontColor(this.palette.textSecondary)
          .lineHeight(21)
          .onClick(() => {
            this.updateSettingSwitch(key, !this.settingValue(key));
          })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.settingValue(key) })
        .selectedColor(this.primaryColor())
        .onChange((value: boolean) => {
          this.updateSettingSwitch(key, value);
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
  }

  @Builder
  SettingsActionRow(icon: string, title: string, subtitle: string, action: string) {
    Row({ space: 16 }) {
      Text(icon)
        .width(36)
        .fontSize(21)
        .fontColor(this.palette.textPrimary)
      Column({ space: 4 }) {
        Text(title)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
        Text(subtitle)
          .fontSize(15)
          .fontColor(this.palette.textSecondary)
          .lineHeight(21)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .onClick(() => {
      this.runSettingAction(action);
    })
  }

  @Builder
  ThemeSettingsRow() {
    Row({ space: 16 }) {
      Text('◈')
        .width(36)
        .fontSize(21)
        .fontColor(this.palette.textPrimary)
      Column({ space: 4 }) {
        Text('应用主题')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
        Text(`当前主题：${this.palette.title}`)
          .fontSize(15)
          .fontColor(this.palette.textSecondary)
          .lineHeight(21)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .onClick(() => {
      this.runSettingAction('theme');
    })
  }

  @Builder
  SettingsPage() {
    Column() {
      Row({ space: 10 }) {
        Text('←')
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .fontSize(28)
          .fontColor(this.palette.textPrimary)
          .onClick(() => {
            this.showSettings = false;
          })
        Text('设置')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
      }
      .width('100%')
      .padding({ left: 10, right: 20, top: 8, bottom: 4 })

      List() {
        ListItem() {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text('⌕')
                .fontSize(22)
                .fontColor(this.palette.textSecondary)
              TextInput({ text: this.searchQuery, placeholder: '搜索电台' })
                .layoutWeight(1)
                .height(44)
                .fontSize(15)
                .backgroundColor(this.palette.surfaceVariant)
                .borderRadius(22)
                .onChange((value: string) => {
                  this.updateSearchQuery(value);
                })
                .onSubmit(() => {
                  this.searchStations();
                })
              Button('搜索')
                .height(40)
                .backgroundColor(this.primaryColor())
                .fontColor(Color.White)
                .borderRadius(20)
                .enabled(!this.searching)
                .onClick(() => {
                  this.searchStations();
                })
            }
            .width('100%')
            if (shouldShowSearchResults(this.searchQuery, this.searchResults.length)) {
              Column({ space: 2 }) {
                ForEach(this.searchResults.slice(0, 8), (station: Station) => {
                  Row({ space: 8 }) {
                    Text(station.name)
                      .fontSize(15)
                      .fontColor(this.palette.textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(this.isStationSaved(station) ? '已添加' : '添加')
                      .fontSize(14)
                      .fontColor(this.isStationSaved(station)
                        ? this.palette.textSecondary
                        : this.primaryColor())
                      .onClick(() => {
                        if (!this.isStationSaved(station)) {
                          this.addSearchStation(station);
                        }
                      })
                  }
                  .width('100%')
                  .height(40)
                }, (station: Station) => station.id)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 10 })
        }

        ListItem() {
          this.SettingsSectionTitle('外观')
        }
        ListItem() { this.ThemeSettingsRow() }
        ListItem() {
          this.SettingsSwitchRow('◉', '动态颜色', '用户界面元素使用当前主题强调色。', 'dynamicColor')
        }
        ListItem() {
          this.SettingsSwitchRow('◐', '透明效果', '播放控件采用半透明背景。', 'transparentUi')
        }

        ListItem() {
          this.SettingsDivider()
        }
        ListItem() {
          this.SettingsSectionTitle('播放与操作')
        }
        ListItem() {
          this.SettingsSwitchRow('▶', '点击广播电台', '点击电台任意部位开始收听。', 'clickStation')
        }
        ListItem() {
          this.SettingsSwitchRow('◎', '启动时自动播放', '打开应用后自动播放上次收听的电台。', 'autoPlay')
        }
        ListItem() {
          this.SettingsSwitchRow('↺', '记忆播放列表与进度', '保存当前列表和最后收听的电台。', 'playbackMemory')
        }
        ListItem() {
          this.SettingsSwitchRow(
            'ϟ',
            '0.25s 极速起播优化',
            '采用低水位快速起播，下次切台立即生效。',
            'fastStart'
          )
        }
        ListItem() {
          this.SettingsSwitchRow('✎', '编辑电台', '开启后左滑显示编辑和删除，长按拖动排序。', 'editMode')
        }
        ListItem() {
          this.SettingsSwitchRow('↗', '编辑流媒体链接', '允许在编辑电台时修改流媒体链接。', 'editStreamUrl')
        }
        ListItem() {
          this.SettingsSwitchRow(
            '♫',
            '旧 MP3 兼容解码',
            '剥离 Icecast 内嵌元数据后再交给解码器；特殊电台异常时可关闭。',
            'icecastCompatibility'
          )
        }

        ListItem() {
          this.SettingsDivider()
        }
        ListItem() {
          this.SettingsSectionTitle('蓝牙与耳机')
        }
        ListItem() {
          this.SettingsActionRow('⌁', '系统自动启动', this.autoStartupStatus, 'autoStartup')
        }
        ListItem() {
          Text('已绑定蓝牙设备（最多 3 个）')
            .width('100%')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.palette.textSecondary)
            .padding({ left: 20, right: 20, top: 10, bottom: 2 })
        }
        if (this.pendingBluetoothBinding !== undefined) {
          ListItem() {
            Column({ space: 4 }) {
              Text(`待绑定：${this.pendingBluetoothBinding.deviceName}`)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFCC80')
              Text('已有 3 个绑定；删除下方任意一条记录后，此设备会立即补入并可设置自动连接播放。')
                .fontSize(12)
                .fontColor(this.palette.textSecondary)
                .lineHeight(18)
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          }
        }
        ForEach([0, 1, 2], (slot: number) => {
          ListItem() {
            this.BluetoothBindingRow(this.settings.bluetoothBindings[slot], slot)
          }
        }, (slot: number) => {
          const binding = this.settings.bluetoothBindings[slot];
          return `${slot}:${binding?.deviceId ?? ''}:${binding?.autoPlay ? 1 : 0}`;
        })
        ListItem() {
          this.SettingsActionRow('⌁', '蓝牙设备识别权限', this.diagnostics, 'bluetoothPermission')
        }
        ListItem() {
          this.SettingsSwitchRow('⇄', '有线耳机断开自动暂停', '有线耳机拔出时自动暂停，避免突然外放。', 'pauseOnUnplug')
        }
        ListItem() {
          this.SettingsSwitchRow(
            '⇠',
            '蓝牙断开立即停止',
            '蓝牙音频断开时停止播放并移除锁屏暂停卡片。',
            'pauseOnBluetoothDisconnect'
          )
        }
        ListItem() {
          this.SettingsSwitchRow(
            '▶',
            '蓝牙自动播放总开关',
            '总开关打开后，仅勾选了“连接后自动播放”的已绑定设备会启动播放。',
            'autoPlayOnBluetoothConnect'
          )
        }
        ListItem() {
          this.SettingsSwitchRow(
            '✓',
            '蓝牙重连自动续播',
            `同一设备 ${this.settings.resumeWindowMinutes} 分钟内重连时自动续播。`,
            'autoResume'
          )
        }
        ListItem() {
          this.SettingsActionRow(
            '⏱',
            '蓝牙续播窗口',
            `${this.settings.resumeWindowMinutes} 分钟 · 点击修改`,
            'resumeWindow'
          )
        }

        ListItem() {
          this.SettingsDivider()
        }
        ListItem() {
          this.SettingsSectionTitle('备份与更新')
        }
        ListItem() { this.SettingsActionRow('↗', '导出 M3U', '保存为可被其它播放器导入的 M3U 列表。', 'exportM3u') }
        ListItem() { this.SettingsActionRow('↙', '导入 M3U', '从 M3U / M3U8 播放列表追加电台。', 'importM3u') }
        ListItem() {
          this.SettingsActionRow('⇩', '备份到本地', '生成含 M3U、台标、顺序和设置的 ZIP。', 'backupLocal')
        }
        ListItem() {
          this.SettingsActionRow('⇧', '从本地恢复', '恢复 QYFM ZIP 或旧版 v1.0.8 ZIP。', 'restoreLocal')
        }
        ListItem() {
          this.SettingsActionRow('☁', '在线备份 (WebDAV)', 'ZIP 版本备份，可选择任意云端版本恢复。', 'webdav')
        }
        ListItem() { this.SettingsActionRow('↻', '检查更新', '当前版本 1.0.46 · GitHub Releases', 'checkUpdate') }
        ListItem() {
          this.SettingsSwitchRow('⟳', '自动检查并下载更新', '启动后自动检查新版本，安装由系统确认。', 'autoUpdate')
        }
        ListItem() { this.SettingsActionRow('⌘', 'GitHub 开源项目', 'github.com/zzg341125/QYFM-HM', 'github') }
        if (this.settingsStatus.length > 0) {
          ListItem() {
            Text(this.settingsStatus)
              .width('100%')
              .fontSize(13)
              .fontColor(this.palette.textSecondary)
              .padding({ left: 20, right: 20, top: 8, bottom: 16 })
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)

      this.NowPlayingBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.background)
  }

  @Builder
  DialogInput(label: string, value: string) {
    Row({ space: 10 }) {
      Text(label)
        .width(68)
        .fontSize(14)
        .fontColor(this.palette.textSecondary)
      TextInput({ text: value })
        .layoutWeight(1)
        .height(44)
        .fontSize(14)
        .fontColor(this.palette.textPrimary)
        .backgroundColor(this.palette.surface)
        .borderRadius(12)
        .border({ width: 1, color: this.palette.divider })
    }
    .width('100%')
  }

  @Builder
  ResumeWindowDialog() {
    Column({ space: 10 }) {
      Row() {
        Text('蓝牙续播窗口')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
        Text('×')
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .fontSize(24)
          .fontColor(this.palette.textSecondary)
          .onClick(() => {
            this.showResumeWindow = false;
          })
      }
      .width('100%')
      Text('耳机断开后，同一设备在所选时间内重连会自动继续播放。')
        .width('100%')
        .fontSize(13)
        .fontColor(this.palette.textSecondary)
      List({ space: 4 }) {
        ForEach([15, 30, 60, 120, 240, 480], (minutes: number) => {
          ListItem() {
            Row() {
              Text(`${minutes} 分钟`)
                .fontSize(16)
                .fontColor(this.palette.textPrimary)
                .layoutWeight(1)
              if (this.settings.resumeWindowMinutes === minutes) {
                Text('✓')
                  .fontSize(18)
                  .fontColor(this.primaryColor())
              }
            }
            .width('100%')
            .height(52)
            .padding({ left: 12, right: 12 })
            .borderRadius(12)
            .backgroundColor(this.settings.resumeWindowMinutes === minutes
              ? this.palette.nowPlaying
              : this.palette.surface)
            .onClick(() => {
              this.updateResumeWindowMinutes(minutes);
            })
          }
        }, (minutes: number) => minutes.toString())
      }
      .width('100%')
      .height(320)
      .scrollBar(BarState.Off)
    }
    .width('88%')
    .padding(18)
    .borderRadius(24)
    .backgroundColor(this.palette.background)
    .shadow({ radius: 26, color: '#33000000', offsetY: 8 })
  }

  @Builder
  ThemeDialog() {
    Column({ space: 10 }) {
      Row() {
        Text('应用主题')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
        Text('×')
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .fontSize(24)
          .fontColor(this.palette.textSecondary)
          .onClick(() => {
            this.showTheme = false;
          })
      }
      .width('100%')

      List({ space: 4 }) {
        ForEach(THEME_PRESETS, (theme: ThemePreset) => {
          ListItem() {
            Row({ space: 12 }) {
              Text('●')
                .fontSize(18)
                .fontColor(theme.primary)
              Column({ space: 2 }) {
                Text(theme.title)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.palette.textPrimary)
                Text(theme.subtitle)
                  .fontSize(12)
                  .fontColor(this.palette.textSecondary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              if (this.settings.themeId === theme.id) {
                Text('✓')
                  .fontSize(18)
                  .fontColor(this.primaryColor())
              }
            }
            .width('100%')
            .height(58)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.selectTheme(theme);
            })
          }
        }, (theme: ThemePreset) => theme.id)
      }
      .width('100%')
      .height(360)
      .scrollBar(BarState.Off)
    }
    .width('92%')
    .padding(18)
    .borderRadius(24)
    .backgroundColor(this.palette.background)
    .shadow({ radius: 26, color: '#33000000', offsetY: 8 })
  }

  @Builder
  DeleteDialog() {
    if (this.pendingDelete !== undefined) {
      Column({ space: 14 }) {
        Text('移除电台')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .width('100%')
        Text(`确定从播放列表移除“${this.pendingDelete.name}”吗？`)
          .fontSize(15)
          .fontColor(this.palette.textSecondary)
          .width('100%')
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .backgroundColor(this.palette.surfaceVariant)
            .fontColor(this.palette.textSecondary)
            .borderRadius(22)
            .onClick(() => {
              this.pendingDelete = undefined;
            })
          Button('移除')
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#B3261E')
            .fontColor(Color.White)
            .borderRadius(22)
            .onClick(() => {
              if (this.pendingDelete !== undefined) {
                const id = this.pendingDelete.id;
                this.pendingDelete = undefined;
                this.deleteStation(id);
              }
            })
        }
        .width('100%')
      }
      .width('88%')
      .padding(18)
      .borderRadius(24)
      .backgroundColor(this.palette.background)
      .shadow({ radius: 26, color: '#33000000', offsetY: 8 })
    }
  }

  @Builder
  WebDavDialog() {
    Column() {
      Row() {
        Text('在线备份 (WebDAV)')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
        Text('×')
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .fontSize(24)
          .fontColor(this.palette.textSecondary)
          .onClick(() => {
            this.showWebDav = false;
          })
      }
      .width('100%')
      Scroll() {
        Column({ space: 12 }) {

      Row({ space: 10 }) {
        Text('服务器')
          .width(68)
          .fontSize(14)
          .fontColor(this.palette.textSecondary)
        TextInput({ text: this.settings.webdavUrl, placeholder: 'https://dav.example.com/radio/' })
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .backgroundColor(this.palette.surface)
          .borderRadius(12)
          .border({ width: 1, color: this.palette.divider })
          .onChange((value: string) => {
            this.updateWebDavUrl(value);
          })
      }
      .width('100%')
      Row({ space: 10 }) {
        Text('用户名')
          .width(68)
          .fontSize(14)
          .fontColor(this.palette.textSecondary)
        TextInput({ text: this.settings.webdavUser })
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .backgroundColor(this.palette.surface)
          .borderRadius(12)
          .border({ width: 1, color: this.palette.divider })
          .onChange((value: string) => {
            this.updateWebDavUser(value);
          })
      }
      .width('100%')
      Row({ space: 10 }) {
        Text('密码')
          .width(68)
          .fontSize(14)
          .fontColor(this.palette.textSecondary)
        TextInput({ text: this.settings.webdavPassword })
          .type(InputType.Normal)
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .backgroundColor(this.palette.surface)
          .borderRadius(12)
          .border({ width: 1, color: this.palette.divider })
          .onChange((value: string) => {
            this.updateWebDavPassword(value);
          })
      }
      .width('100%')
      Row({ space: 10 }) {
        Text('备份前缀')
          .width(68)
          .fontSize(14)
          .fontColor(this.palette.textSecondary)
        TextInput({ text: this.settings.webdavFile })
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .backgroundColor(this.palette.surface)
          .borderRadius(12)
          .border({ width: 1, color: this.palette.divider })
          .onChange((value: string) => {
            this.updateWebDavFile(value);
          })
      }
      .width('100%')
      Row({ space: 10 }) {
        Text('ZIP 文件')
          .width(68)
          .fontSize(14)
          .fontColor(this.palette.textSecondary)
        TextInput({
          text: this.webDavZipFile,
          placeholder: 'quyang_backup_20261112_102536.zip'
        })
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .backgroundColor(this.palette.surface)
          .borderRadius(12)
          .border({ width: 1, color: this.palette.divider })
          .onChange((value: string) => {
            this.webDavZipFile = value;
          })
      }
      .width('100%')
      Row({ space: 8 }) {
        Button('保存')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.palette.surfaceVariant)
          .fontColor(this.palette.textPrimary)
          .borderRadius(22)
          .onClick(() => {
            this.persistSettings();
          })
        Button('测试连接')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.palette.surfaceVariant)
          .fontColor(this.palette.textPrimary)
          .borderRadius(22)
          .enabled(!this.busy)
          .onClick(() => {
            this.testWebDav();
          })
      }
      .width('100%')
      Row({ space: 8 }) {
        Button('上传备份')
          .layoutWeight(1)
          .height(46)
          .backgroundColor(this.primaryColor())
          .fontColor(Color.White)
          .borderRadius(23)
          .enabled(!this.busy)
          .onClick(() => {
            this.backupToWebDav();
          })
        Button('刷新版本')
          .layoutWeight(1)
          .height(46)
          .backgroundColor(this.palette.surfaceVariant)
          .fontColor(this.palette.textPrimary)
          .borderRadius(23)
          .enabled(!this.loadingWebDavVersions)
          .onClick(() => {
            this.refreshWebDavBackups();
          })
      }
      .width('100%')
      Text('云端备份版本')
        .width('100%')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette.textPrimary)
      if (this.loadingWebDavVersions) {
        Text('正在读取版本列表…')
          .width('100%')
          .fontSize(13)
          .fontColor(this.palette.textSecondary)
      } else if (this.webDavBackups.length === 0) {
        Text('暂无备份，请上传一次或点击“刷新版本”。')
          .width('100%')
          .fontSize(13)
          .fontColor(this.palette.textSecondary)
      } else {
        List({ space: 6 }) {
          ForEach(this.webDavBackups, (entry: WebDavBackupEntry) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text(this.webDavVersionLabel(entry))
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.palette.textPrimary)
                  Text(this.webDavEntryDetail(entry))
                    .fontSize(11)
                    .fontColor(this.palette.textSecondary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(this.selectedWebDavFile === entry.fileName ? '✓' : '')
                  .width(24)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.primaryColor())
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .borderRadius(12)
              .backgroundColor(this.selectedWebDavFile === entry.fileName
                ? this.palette.nowPlaying
                : this.palette.surface)
              .border({
                width: 1,
                color: this.selectedWebDavFile === entry.fileName
                  ? this.primaryColor()
                  : this.palette.divider
              })
              .onClick(() => {
                this.selectedWebDavFile = entry.fileName;
              })
            }
          }, (entry: WebDavBackupEntry) => entry.fileName)
        }
        .width('100%')
        .height(132)
        .scrollBar(BarState.Auto)
      }
      Button('恢复所选版本')
        .width('100%')
        .height(46)
        .backgroundColor(this.primaryColor())
        .fontColor(Color.White)
        .borderRadius(23)
        .enabled(!this.busy && this.selectedWebDavFile.length > 0)
        .onClick(() => {
          this.restoreFromWebDav();
        })
      if (this.settingsStatus.length > 0) {
        Text(this.settingsStatus)
          .width('100%')
          .fontSize(13)
          .fontColor(this.palette.textSecondary)
      }
      Text('每次上传都会生成独立时间戳 ZIP，内含 M3U、实际台标、显式播放顺序和非敏感设置；WebDAV 密码不会写入备份。')
        .width('100%')
        .fontSize(12)
        .fontColor(this.palette.textSecondary)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('92%')
    .constraintSize({ maxHeight: '92%' })
    .padding(18)
    .borderRadius(24)
    .backgroundColor(this.palette.background)
    .shadow({ radius: 26, color: '#33000000', offsetY: 8 })
  }

  @Builder
  StationEditor() {
    Column({ space: 12 }) {
      Row() {
        Text(this.editorIsNew ? '添加新电台' : '编辑电台')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .layoutWeight(1)
        Text('×')
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .fontSize(24)
          .fontColor(this.palette.textSecondary)
          .onClick(() => {
            this.showEditor = false;
          })
      }
      .width('100%')

      TextInput({ text: this.editorName, placeholder: '电台名称' })
        .height(44)
        .fontSize(15)
        .backgroundColor(this.palette.surface)
        .borderRadius(12)
        .border({ width: 1, color: this.palette.divider })
        .onChange((value: string) => {
          this.editorName = value;
        })
      if (this.editorIsNew || this.settings.editStreamUrl) {
        TextInput({ text: this.editorUrl, placeholder: '播放地址（m3u8 / mp3 / aac）' })
          .height(44)
          .fontSize(15)
          .backgroundColor(this.palette.surface)
          .borderRadius(12)
          .border({ width: 1, color: this.palette.divider })
          .onChange((value: string) => {
            this.editorUrl = value;
          })
      }
      TextInput({ text: this.editorTags, placeholder: '标签，例如：新闻、音乐、交通' })
        .height(44)
        .fontSize(15)
        .backgroundColor(this.palette.surface)
        .borderRadius(12)
        .border({ width: 1, color: this.palette.divider })
        .onChange((value: string) => {
          this.editorTags = value;
        })
      Row({ space: 12 }) {
        if (this.editorIcon.length > 0) {
          Image(this.editorIcon)
            .width(56)
            .height(56)
            .borderRadius(28)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            Text('FM')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.palette.textSecondary)
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(this.palette.surfaceVariant)
        }
        Button('更换台标')
          .layoutWeight(1)
          .height(42)
          .backgroundColor(this.palette.surfaceVariant)
          .fontColor(this.palette.textPrimary)
          .borderRadius(21)
          .onClick(() => {
            this.pickStationIcon();
          })
        Button('清除')
          .width(74)
          .height(42)
          .backgroundColor(this.palette.surfaceVariant)
          .fontColor(this.palette.textSecondary)
          .borderRadius(21)
          .onClick(() => {
            this.editorIcon = '';
          })
      }
      .width('100%')
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.palette.surfaceVariant)
          .fontColor(this.palette.textSecondary)
          .borderRadius(22)
          .onClick(() => {
            this.showEditor = false;
          })
        Button('保存更改')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.primaryColor())
          .fontColor(Color.White)
          .borderRadius(22)
          .onClick(() => {
            this.saveStation();
          })
      }
      .width('100%')
      if (!this.editorIsNew && this.settings.editMode) {
        Button('删除电台')
          .width('100%')
          .height(42)
          .fontSize(15)
          .fontColor(COLOR_DANGER)
          .backgroundColor(COLOR_DANGER_BG)
          .borderRadius(21)
          .onClick(() => {
            const station = this.stations.find((item: Station) => item.id === this.editorId);
            if (station !== undefined) {
              this.showEditor = false;
              this.pendingDelete = station;
            }
          })
      }
    }
    .width('92%')
    .padding(18)
    .borderRadius(24)
    .backgroundColor(this.palette.background)
    .shadow({ radius: 26, color: '#33000000', offsetY: 8 })
  }

  @Builder
  UpdateDialog() {
    if (this.updateInfo !== undefined) {
      Column({ space: 13 }) {
        Text('发现新版本')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.palette.textPrimary)
          .width('100%')
        Text(this.updateInfo.title)
          .fontSize(16)
          .fontColor(this.primaryColor())
          .width('100%')
        Text(this.updateInfo.notes.length > 0 ? this.updateInfo.notes : '请前往发布页下载最新 HAP。')
          .fontSize(14)
          .fontColor(this.palette.textSecondary)
          .maxLines(5)
          .width('100%')
        if (this.updateStatus.length > 0) {
          Text(this.updateStatus)
            .width('100%')
            .fontSize(13)
            .fontColor(this.updateDownloadPath.length > 0
              ? this.primaryColor()
              : this.palette.textSecondary)
        }
        Row({ space: 10 }) {
          Button('稍后')
            .layoutWeight(1)
            .height(44)
            .backgroundColor(this.palette.surfaceVariant)
            .fontColor(this.palette.textSecondary)
            .borderRadius(22)
            .onClick(() => {
              this.updateInfo = undefined;
              this.updateStatus = '';
            })
          Button(this.downloadingUpdate
            ? '下载中…'
            : (this.updateDownloadPath.length > 0 ? '立即安装' : '下载并安装'))
            .layoutWeight(1)
            .height(44)
            .backgroundColor(this.primaryColor())
            .fontColor(Color.White)
            .borderRadius(22)
            .enabled(!this.downloadingUpdate)
            .onClick(() => {
              if (this.updateDownloadPath.length > 0) {
                this.installDownloadedUpdate();
              } else {
                this.downloadAndInstallUpdate();
              }
            })
        }
        Button('前往 GitHub 发布页')
          .width('100%')
          .height(40)
          .backgroundColor(this.palette.surfaceVariant)
          .fontColor(this.palette.textPrimary)
          .borderRadius(20)
          .onClick(() => {
            this.openReleasePage();
          })
      }
      .width('88%')
      .padding(18)
      .borderRadius(24)
      .backgroundColor(this.palette.background)
      .shadow({ radius: 26, color: '#33000000', offsetY: 8 })
    }
  }

  build() {
    Stack() {
      if (this.showSettings) {
        this.SettingsPage()
      } else {
        this.HomePage()
      }

      if (this.showWebDav) {
        Column() {
          this.WebDavDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
      }

      if (this.showTheme) {
        Column() {
          this.ThemeDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
      }

      if (this.showResumeWindow) {
        Column() {
          this.ResumeWindowDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
      }

      if (this.pendingDelete !== undefined) {
        Column() {
          this.DeleteDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
      }

      if (this.showEditor) {
        Column() {
          this.StationEditor()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
      }

      if (this.updateInfo !== undefined) {
        Column() {
          this.UpdateDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#66000000')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.background)
  }
}
