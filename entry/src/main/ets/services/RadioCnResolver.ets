import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { Station, StreamLine } from '../models/Station';
import {
  buildOfficialStreamUrls,
  inferRadioCnProvinceCode,
  matchRadioCnStation,
  shouldResolveRadioCnStation
} from '../utils/RadioCnMatch';

const API_BASE: string = 'https://ytmsout.radio.cn/web';
const SIGN_KEY: string = 'f0fc4c668392f9f9a447e48584c214ee';
const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const CACHE_TTL_MS: number = 60 * 60 * 1000;

interface RadioCnBroadcast {
  contentId: string;
  title: string;
  subtitle?: string;
  image?: string;
  mp3PlayUrlHigh?: string;
  mp3PlayUrlLow?: string;
  playUrlLow?: string;
}

interface RadioCnResponse {
  code: number;
  message?: string;
  data?: RadioCnBroadcast[];
}

interface CachedRadioCnStations {
  fetchedAt: number;
  stations: RadioCnBroadcast[];
}

class RadioCnRequestHeaders {
  'Accept': string = 'application/json';
  'User-Agent': string = USER_AGENT;
  'sign': string;
  'timestamp': string;
  'equipmentId': string = '0000';
  'platformCode': string = 'WEB';

  constructor(sign: string, timestamp: string) {
    this.sign = sign;
    this.timestamp = timestamp;
  }
}

export class RadioCnResolver {
  private cache: Map<number, CachedRadioCnStations> = new Map<number, CachedRadioCnStations>();

  async resolve(station: Station): Promise<Station | undefined> {
    if (!shouldResolveRadioCnStation(station.name)) {
      return undefined;
    }
    const provinceCode = inferRadioCnProvinceCode(station.name);
    if (provinceCode === undefined) {
      return undefined;
    }
    try {
      const broadcasts = await this.loadStations(provinceCode);
      const matchedTitle = matchRadioCnStation(
        station.name,
        broadcasts.map((item: RadioCnBroadcast) => item.title)
      );
      if (matchedTitle === undefined) {
        return undefined;
      }
      const matched = broadcasts.find((item: RadioCnBroadcast) => item.title === matchedTitle);
      if (matched === undefined) {
        return undefined;
      }
      const highUrl = (matched.mp3PlayUrlHigh ?? '').trim();
      const lowUrl = (matched.mp3PlayUrlLow ?? '').trim();
      const hlsUrl = (matched.playUrlLow ?? '').trim();
      if (highUrl.length === 0 && lowUrl.length === 0 && hlsUrl.length === 0) {
        return undefined;
      }
      const urls = buildOfficialStreamUrls(highUrl, lowUrl, hlsUrl, station.streamUrl);
      const lines: StreamLine[] = urls.map((url: string, index: number): StreamLine => {
        const names: string[] = ['官方高品质', '官方兼容线', '官方 HLS', '原播放地址'];
        return {
          id: index === 0 ? `radio-cn-${matched.contentId}` : `radio-cn-line-${index + 1}`,
          name: names[Math.min(index, names.length - 1)],
          url: url,
          priority: index + 1,
          isStable: index < 3
        };
      });
      return {
        id: station.id,
        name: station.name,
        streamUrl: urls[0],
        streamLines: lines,
        activeLineIndex: 0,
        iconUrl: station.iconUrl.length > 0 ? station.iconUrl : (matched.image ?? ''),
        tags: station.tags.length > 0 ? station.tags : '官方专线',
        country: station.country,
        state: station.state,
        favorite: station.favorite
      };
    } catch (error) {
      const businessError = error as BusinessError;
      console.info(`官方专线刷新不可用: ${businessError.message ?? '未知错误'}`);
      return undefined;
    }
  }

  private async loadStations(provinceCode: number): Promise<RadioCnBroadcast[]> {
    const cached = this.cache.get(provinceCode);
    if (cached !== undefined && Date.now() - cached.fetchedAt < CACHE_TTL_MS) {
      return cached.stations;
    }
    const timestamp = Date.now().toString();
    const sign = await this.generateSign(provinceCode, timestamp);
    const request = http.createHttp();
    try {
      const url =
        `${API_BASE}/appBroadcast/list?categoryId=0&provinceCode=${provinceCode}`;
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: new RadioCnRequestHeaders(sign, timestamp),
        connectTimeout: 6000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      });
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        return [];
      }
      const parsed = JSON.parse(response.result) as RadioCnResponse;
      const stations = parsed.code === 0 && Array.isArray(parsed.data) ? parsed.data : [];
      this.cache.set(provinceCode, {
        fetchedAt: Date.now(),
        stations: stations
      });
      return stations;
    } finally {
      request.destroy();
    }
  }

  private async generateSign(provinceCode: number, timestamp: string): Promise<string> {
    const raw =
      `categoryId=0&provinceCode=${provinceCode}&timestamp=${timestamp}&key=${SIGN_KEY}`;
    const md = cryptoFramework.createMd('MD5');
    const encoder = new util.TextEncoder();
    await md.update({ data: encoder.encodeInto(raw) });
    const digest = await md.digest();
    let result = '';
    digest.data.forEach((value: number) => {
      result += value.toString(16).padStart(2, '0');
    });
    return result.toUpperCase();
  }
}
