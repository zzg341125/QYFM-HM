const NATIONAL_KEYWORDS: string[] = [
  '中国之声', '经济之声', '音乐之声', '经典音乐', '神州之声',
  '环球资讯', '中国交通广播', '文艺之声', '台海之声', '香港之声',
  '民族之声', '老年之声', '乡村之声', '大湾区之声'
];

const PROVINCE_CODES: Record<string, number> = {
  '全国': 0,
  '北京': 110000,
  '河北': 130000,
  '山西': 140000,
  '内蒙古': 150000,
  '辽宁': 210000,
  '吉林': 220000,
  '黑龙江': 230000,
  '上海': 310000,
  '江苏': 320000,
  '浙江': 330000,
  '安徽': 340000,
  '福建': 350000,
  '江西': 360000,
  '山东': 370000,
  '河南': 410000,
  '湖北': 420000,
  '湖南': 430000,
  '广东': 440000,
  '广西': 450000,
  '海南': 460000,
  '重庆': 500000,
  '四川': 510000,
  '贵州': 520000,
  '云南': 530000,
  '西藏': 540000,
  '陕西': 610000,
  '甘肃': 620000,
  '青海': 630000,
  '宁夏': 640000,
  '新疆': 650000
};

const CITY_PROVINCE: Record<string, string> = {
  '滁州': '安徽',
  '合肥': '安徽',
  '蚌埠': '安徽',
  '芜湖': '安徽',
  '安庆': '安徽',
  '阜阳': '安徽',
  '毫州': '安徽',
  '池州': '安徽',
  '宣城': '安徽',
  '马鞍山': '安徽',
  '石家庄': '河北',
  '唐山': '河北',
  '南京': '江苏',
  '苏州': '江苏',
  '无锡': '江苏',
  '常州': '江苏',
  '郑州': '河南',
  '洛阳': '河南',
  '成都': '四川',
  '重庆': '重庆',
  '武汉': '湖北',
  '长沙': '湖南',
  '杭州': '浙江',
  '广州': '广东',
  '深圳': '广东',
  '西安': '陕西',
  '济南': '山东',
  '青岛': '山东',
  '沈阳': '辽宁',
  '哈尔滨': '黑龙江',
  '长春': '吉林',
  '太原': '山西'
};

export function normalizeRadioName(value: string): string {
  return value
    .toLowerCase()
    .replace(/^[a-z]\d+\s*[~～\-]/, '')
    .replaceAll('中央', '')
    .replaceAll('人民', '')
    .replaceAll('广播电视台', '')
    .replaceAll('广播电台', '')
    .replaceAll('广播', '')
    .replaceAll('电台', '')
    .replaceAll('频道', '')
    .replace(/[()（）\-—_\s·,.，。]/g, '');
}

export function inferRadioCnProvinceCode(name: string): number | undefined {
  const raw = name.replace(/^[a-z]\d+\s*[~～\-]/i, '').trim();
  if (NATIONAL_KEYWORDS.some((keyword: string) => raw.includes(keyword)) ||
    (raw.includes('经典') && raw.includes('音乐'))) {
    return 0;
  }
  const province = Object.keys(PROVINCE_CODES).find((key: string) =>
    key !== '全国' && raw.includes(key));
  if (province !== undefined) {
    return PROVINCE_CODES[province];
  }
  const city = Object.keys(CITY_PROVINCE).find((key: string) => raw.includes(key));
  return city === undefined ? undefined : PROVINCE_CODES[CITY_PROVINCE[city]];
}

export function shouldResolveRadioCnStation(name: string): boolean {
  return inferRadioCnProvinceCode(name) !== undefined;
}

function matchScore(target: string, candidate: string): number {
  if (target.length === 0 || candidate.length === 0) {
    return 0;
  }
  if (target === candidate) {
    return 100;
  }
  if (target.includes(candidate) || candidate.includes(target)) {
    return 85;
  }
  if ((target.includes('经典') && candidate.includes('经典')) &&
    target.includes('音乐') && candidate.includes('音乐')) {
    return 80;
  }
  const targetCity = target.substring(0, 2);
  const candidateCity = candidate.substring(0, 2);
  if (targetCity === candidateCity &&
    (target.includes('综合') || target.includes('新闻')) &&
    candidate.includes('综合')) {
    return 75;
  }
  return 0;
}

export function matchRadioCnStation(
  targetName: string,
  candidateTitles: string[]
): string | undefined {
  const target = normalizeRadioName(targetName);
  let bestTitle = '';
  let bestScore = 0;
  candidateTitles.forEach((title: string) => {
    const score = matchScore(target, normalizeRadioName(title));
    if (score > bestScore) {
      bestScore = score;
      bestTitle = title;
    }
  });
  return bestScore >= 75 ? bestTitle : undefined;
}

export function mergeOfficialStreamUrls(officialUrl: string, fallbackUrl: string): string[] {
  const urls: string[] = [];
  [officialUrl, fallbackUrl].forEach((url: string) => {
    const trimmed = url.trim();
    if (trimmed.length > 0 && !urls.includes(trimmed)) {
      urls.push(trimmed);
    }
  });
  return urls;
}

export function buildOfficialStreamUrls(
  highUrl: string | undefined,
  lowUrl: string | undefined,
  hlsUrl: string | undefined,
  fallbackUrl: string
): string[] {
  const urls: string[] = [];
  [highUrl ?? '', lowUrl ?? '', hlsUrl ?? '', fallbackUrl].forEach((url: string) => {
    const trimmed = url.trim();
    if (trimmed.length > 0 && !urls.includes(trimmed)) {
      urls.push(trimmed);
    }
  });
  return urls;
}

export interface RadioCnRequestTimeouts {
  connectTimeoutMs: number;
  readTimeoutMs: number;
}

export function radioCnRequestTimeouts(): RadioCnRequestTimeouts {
  return {
    connectTimeoutMs: 6000,
    readTimeoutMs: 8000
  };
}

export function shouldReuseRadioCnCatalog(fetchedAt: number, now: number): boolean {
  const age = now - fetchedAt;
  return age >= 0 && age < 30000;
}
