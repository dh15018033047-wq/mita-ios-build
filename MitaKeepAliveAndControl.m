#import "MitaKeepAliveAndControl.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/utsname.h>
#import <unistd.h>

@interface MitaKeepAliveAndControl ()
@property (nonatomic, strong) AVAudioPlayer *silentPlayer;
@property (nonatomic, assign, readwrite) BOOL isKeepAliveRunning;
@property (nonatomic, assign) int vncWidth;
@property (nonatomic, assign) int vncHeight;
@property (nonatomic, strong) NSLock *vncLock;
@end

@implementation MitaKeepAliveAndControl

+ (instancetype)shared {
    static MitaKeepAliveAndControl *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[MitaKeepAliveAndControl alloc] init];
    });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _vncLock = [[NSLock alloc] init];
        CGRect bounds = [UIScreen mainScreen].nativeBounds;
        _vncWidth = (int)bounds.size.width;
        _vncHeight = (int)bounds.size.height;
    }
    return self;
}

#pragma mark - Silent Background Keep-Alive (MixWithOthers, Zero Audio Interference)

- (NSData *)buildSilentWavData {
    // 2 秒 8000Hz 16-bit 单声道纯静音 PCM WAV
    uint32_t sampleRate = 8000;
    uint16_t numChannels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t numSamples = sampleRate * 2;
    uint32_t dataBytes = numSamples * numChannels * (bitsPerSample / 8);
    uint32_t chunkSize = 36 + dataBytes;
    uint32_t byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    uint16_t blockAlign = numChannels * (bitsPerSample / 8);
    uint32_t fmtChunkSize = 16;
    uint16_t audioFormat = 1;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    [wav appendBytes:&fmtChunkSize length:4];
    [wav appendBytes:&audioFormat length:2];
    [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataBytes length:4];
    [wav increaseLengthBy:dataBytes]; // 全 0 静音
    return wav;
}

- (void)startSilentKeepAlive {
    if (self.isKeepAliveRunning && self.silentPlayer.isPlaying) return;
    NSError *err = nil;
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    // 关键：Playback + MixWithOthers，保证绝不中断、绝不压低用户听歌或打游戏的声音
    [sess setCategory:AVAudioSessionCategoryPlayback
          withOptions:AVAudioSessionCategoryOptionMixWithOthers
                error:&err];
    [sess setActive:YES error:&err];

    if (!self.silentPlayer) {
        NSData *wav = [self buildSilentWavData];
        self.silentPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&err];
        self.silentPlayer.numberOfLoops = -1;
        self.silentPlayer.volume = 0.0;
        [self.silentPlayer prepareToPlay];
    }
    if ([self.silentPlayer play]) {
        self.isKeepAliveRunning = YES;
    }
}

- (void)stopSilentKeepAlive {
    if (self.silentPlayer) {
        [self.silentPlayer stop];
    }
    self.isKeepAliveRunning = NO;
}

#pragma mark - TrollStore Native App Launcher (LSApplicationWorkspace)

- (NSString *)resolveBundleId:(NSString *)appSpec {
    NSString *s = [[appSpec ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([s containsString:@"."]) return appSpec;
    NSDictionary *map = @{
        @"微信": @"com.tencent.xin",
        @"wechat": @"com.tencent.xin",
        @"巨魔": @"com.opa334.TrollStore",
        @"trollstore": @"com.opa334.TrollStore",
        @"trollvnc": @"com.82flex.TrollVNCApp",
        @"设置": @"com.apple.Preferences",
        @"系统设置": @"com.apple.Preferences",
        @"safari": @"com.apple.mobilesafari",
        @"浏览器": @"com.apple.mobilesafari",
        @"抖音": @"com.ss.iphone.ugc.Aweme",
        @"小红书": @"com.xingin.discover",
        @"淘宝": @"com.taobao.taobao4iphone",
        @"手机淘宝": @"com.taobao.taobao4iphone",
        @"支付宝": @"com.alipay.iphoneclient",
        @"qq": @"com.tencent.mqq",
        @"美团": @"com.meituan.imeituan",
        @"拼多多": @"com.xunmeng.pinduoduo",
        @"闲鱼": @"com.taobao.fleamarket",
        @"b站": @"tv.danmaku.bilianime",
        @"哔哩哔哩": @"tv.danmaku.bilianime",
        @"相册": @"com.apple.mobileslideshow",
        @"短信": @"com.apple.MobileSMS",
        @"信息": @"com.apple.MobileSMS"
    };
    for (NSString *k in map) {
        if ([s isEqualToString:k] || [s containsString:k]) {
            return map[k];
        }
    }
    return appSpec;
}

- (BOOL)launchAppByNameOrBundleId:(NSString *)appSpec {
    NSString *bid = [self resolveBundleId:appSpec];
    if (bid.length == 0) return NO;
    // 优先使用巨魔特权 LSApplicationWorkspace.defaultWorkspace openApplicationWithBundleID:
    @try {
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        if (wsCls) {
            SEL defSel = NSSelectorFromString(@"defaultWorkspace");
            SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
            if ([wsCls respondsToSelector:defSel]) {
                id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel);
                if (ws && [ws respondsToSelector:openSel]) {
                    BOOL ok = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(ws, openSel, bid);
                    if (ok) return YES;
                }
            }
        }
    } @catch (NSException *ex) {}

    // 兜底 URL Scheme
    NSDictionary *schemes = @{
        @"com.tencent.xin": @"weixin://",
        @"com.apple.Preferences": @"App-Prefs://",
        @"com.apple.mobilesafari": @"https://www.baidu.com",
        @"com.opa334.TrollStore": @"apple-magnifier://",
        @"com.tencent.mqq": @"mqq://"
    };
    NSString *sc = schemes[bid];
    if (sc) return [self openUrlString:sc];
    return NO;
}

- (BOOL)openUrlString:(NSString *)urlStr {
    if (urlStr.length == 0) return NO;
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u) return NO;
    __block BOOL opened = NO;
    dispatch_block_t blk = ^{
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        opened = YES;
    };
    if ([NSThread isMainThread]) {
        blk();
    } else {
        dispatch_sync(dispatch_get_main_queue(), blk);
    }
    return opened;
}

- (void)copyTextToPasteboard:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = text ?: @"";
    });
}

#pragma mark - Loopback RFB / TrollVNC Client (127.0.0.1:5901)

static ssize_t readExact(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, p + got, n - got, 0);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return (ssize_t)got;
}

static BOOL writeExact(int fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = send(fd, p + sent, n - sent, 0);
        if (w <= 0) return NO;
        sent += (size_t)w;
    }
    return YES;
}

- (int)connectLocalRfbAndHandshake:(int *)outW height:(int *)outH {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct timeval tv;
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(5901);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    char ver[12];
    if (readExact(fd, ver, 12) != 12) { close(fd); return -1; }
    if (!writeExact(fd, "RFB 003.008\n", 12)) { close(fd); return -1; }

    uint8_t nTypes = 0;
    if (readExact(fd, &nTypes, 1) != 1 || nTypes == 0) { close(fd); return -1; }
    uint8_t types[64];
    size_t toRead = nTypes < 64 ? nTypes : 64;
    if (readExact(fd, types, toRead) != (ssize_t)toRead) { close(fd); return -1; }

    BOOL hasNone = NO;
    for (size_t i = 0; i < toRead; i++) {
        if (types[i] == 1) { hasNone = YES; break; }
    }
    if (!hasNone) { close(fd); return -1; }
    uint8_t chosen = 1;
    if (!writeExact(fd, &chosen, 1)) { close(fd); return -1; }

    uint32_t secResult = 1;
    if (readExact(fd, &secResult, 4) != 4 || ntohl(secResult) != 0) { close(fd); return -1; }

    uint8_t sharedFlag = 1;
    if (!writeExact(fd, &sharedFlag, 1)) { close(fd); return -1; }

    uint8_t srvInit[24];
    if (readExact(fd, srvInit, 24) != 24) { close(fd); return -1; }
    uint16_t fbW = ((uint16_t)srvInit[0] << 8) | srvInit[1];
    uint16_t fbH = ((uint16_t)srvInit[2] << 8) | srvInit[3];
    uint32_t nameLen = ((uint32_t)srvInit[20] << 24) | ((uint32_t)srvInit[21] << 16) | ((uint32_t)srvInit[22] << 8) | srvInit[23];
    if (nameLen > 0 && nameLen < 4096) {
        char tmp[4096];
        readExact(fd, tmp, nameLen);
    }
    if (outW) *outW = fbW;
    if (outH) *outH = fbH;
    self.vncWidth = fbW;
    self.vncHeight = fbH;
    return fd;
}

- (BOOL)probeLocalTrollVnc {
    [self.vncLock lock];
    int w = 0, h = 0;
    int fd = [self connectLocalRfbAndHandshake:&w height:&h];
    if (fd >= 0) close(fd);
    [self.vncLock unlock];
    return fd >= 0;
}

static BOOL sendPointer(int fd, uint8_t mask, uint16_t x, uint16_t y) {
    uint8_t pkt[6];
    pkt[0] = 5;
    pkt[1] = mask;
    pkt[2] = (x >> 8) & 0xFF;
    pkt[3] = x & 0xFF;
    pkt[4] = (y >> 8) & 0xFF;
    pkt[5] = y & 0xFF;
    return writeExact(fd, pkt, 6);
}

static BOOL sendKey(int fd, uint8_t down, uint32_t keysym) {
    uint8_t pkt[8];
    pkt[0] = 4;
    pkt[1] = down;
    pkt[2] = 0;
    pkt[3] = 0;
    pkt[4] = (keysym >> 24) & 0xFF;
    pkt[5] = (keysym >> 16) & 0xFF;
    pkt[6] = (keysym >> 8) & 0xFF;
    pkt[7] = keysym & 0xFF;
    return writeExact(fd, pkt, 8);
}

- (BOOL)vncTapNormX:(double)nx normY:(double)ny {
    [self.vncLock lock];
    int w = 0, h = 0;
    int fd = [self connectLocalRfbAndHandshake:&w height:&h];
    if (fd < 0) { [self.vncLock unlock]; return NO; }
    uint16_t px = (uint16_t)MAX(1, MIN(w - 2, (int)llround(nx * w)));
    uint16_t py = (uint16_t)MAX(1, MIN(h - 2, (int)llround(ny * h)));
    BOOL ok = sendPointer(fd, 0, px, py);
    usleep(8000);
    ok = ok && sendPointer(fd, 1, px, py);
    usleep(52000); // 52ms 稳压点击，SpringBoard 图标与应用内控件 100% 稳定触发
    ok = ok && sendPointer(fd, 0, px, py);
    usleep(20000);
    close(fd);
    [self.vncLock unlock];
    return ok;
}

- (BOOL)vncSwipeFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2 durationSec:(double)dur {
    [self.vncLock lock];
    int w = 0, h = 0;
    int fd = [self connectLocalRfbAndHandshake:&w height:&h];
    if (fd < 0) { [self.vncLock unlock]; return NO; }
    double sx = MAX(0.02, MIN(0.98, x1)) * w;
    double sy = MAX(0.02, MIN(0.98, y1)) * h;
    double ex = MAX(0.02, MIN(0.98, x2)) * w;
    double ey = MAX(0.02, MIN(0.98, y2)) * h;
    int steps = 16;
    useconds_t stepUs = (useconds_t)MAX(8000, (int)((MAX(0.18, dur) / steps) * 1000000.0));
    sendPointer(fd, 0, (uint16_t)sx, (uint16_t)sy);
    usleep(10000);
    sendPointer(fd, 1, (uint16_t)sx, (uint16_t)sy);
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        double ease = 1.0 - pow(1.0 - t, 2.0);
        uint16_t cx = (uint16_t)(sx + (ex - sx) * ease);
        uint16_t cy = (uint16_t)(sy + (ey - sy) * ease);
        sendPointer(fd, 1, cx, cy);
        usleep(stepUs);
    }
    // 115ms 终点刹停，杜绝 UIScrollView 惯性回弹飘移
    usleep(115000);
    sendPointer(fd, 0, (uint16_t)ex, (uint16_t)ey);
    usleep(20000);
    close(fd);
    [self.vncLock unlock];
    return YES;
}

- (BOOL)vncHomeKey {
    [self.vncLock lock];
    int w = 0, h = 0;
    int fd = [self connectLocalRfbAndHandshake:&w height:&h];
    if (fd < 0) { [self.vncLock unlock]; return NO; }
    BOOL ok = sendKey(fd, 1, 0xFF50);
    usleep(55000);
    ok = ok && sendKey(fd, 0, 0xFF50);
    usleep(20000);
    close(fd);
    [self.vncLock unlock];
    return ok;
}

- (BOOL)vncSendClipboardText:(NSString *)text {
    [self copyTextToPasteboard:text];
    [self.vncLock lock];
    int w = 0, h = 0;
    int fd = [self connectLocalRfbAndHandshake:&w height:&h];
    if (fd < 0) { [self.vncLock unlock]; return NO; }
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t len = (uint32_t)utf8.length;
    uint8_t hdr[8] = {6, 0, 0, 0, (uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)(len & 0xFF)};
    BOOL ok = writeExact(fd, hdr, 8) && (len == 0 || writeExact(fd, utf8.bytes, len));
    usleep(30000);
    close(fd);
    [self.vncLock unlock];
    return ok;
}

- (NSArray<NSDictionary *> *)executeActionBatch:(NSArray<NSDictionary *> *)actions {
    NSMutableArray *results = [NSMutableArray array];
    if (![actions isKindOfClass:[NSArray class]]) return results;
    for (NSDictionary *act in actions) {
        if (![act isKindOfClass:[NSDictionary class]]) continue;
        NSString *tp = [[act[@"type"] ?: act[@"action"] ?: @"" description] lowercaseString];
        BOOL ok = NO;
        NSString *desc = tp;
        if ([tp isEqualToString:@"launch_app"]) {
            NSString *app = act[@"app"] ?: act[@"bundle_id"] ?: act[@"name"] ?: @"";
            ok = [self launchAppByNameOrBundleId:app];
            desc = [NSString stringWithFormat:@"打开应用：%@", app];
            usleep(650000);
        } else if ([tp isEqualToString:@"open_url"]) {
            NSString *u = act[@"url"] ?: @"";
            ok = [self openUrlString:u];
            desc = [NSString stringWithFormat:@"打开网址：%@", u];
            usleep(500000);
        } else if ([tp isEqualToString:@"tap"]) {
            double x = [act[@"x"] doubleValue];
            double y = [act[@"y"] doubleValue];
            ok = [self vncTapNormX:x normY:y];
            desc = [NSString stringWithFormat:@"点击位置 (%.2f, %.2f)", x, y];
        } else if ([tp isEqualToString:@"swipe"]) {
            NSString *dir = [[act[@"dir"] ?: @"up" description] lowercaseString];
            if ([dir isEqualToString:@"up"]) ok = [self vncSwipeFromX:0.5 y:0.75 toX:0.5 y:0.25 durationSec:0.28];
            else if ([dir isEqualToString:@"down"]) ok = [self vncSwipeFromX:0.5 y:0.28 toX:0.5 y:0.78 durationSec:0.28];
            else if ([dir isEqualToString:@"left"]) ok = [self vncSwipeFromX:0.85 y:0.5 toX:0.15 y:0.5 durationSec:0.26];
            else if ([dir isEqualToString:@"right"]) ok = [self vncSwipeFromX:0.15 y:0.5 toX:0.85 y:0.5 durationSec:0.26];
            else ok = [self vncSwipeFromX:[act[@"x1"] doubleValue] y:[act[@"y1"] doubleValue] toX:[act[@"x2"] doubleValue] y:[act[@"y2"] doubleValue] durationSec:0.28];
            desc = [NSString stringWithFormat:@"滑动屏幕：%@", dir];
        } else if ([tp isEqualToString:@"home"]) {
            ok = [self vncHomeKey];
            desc = @"返回主屏幕";
        } else if ([tp isEqualToString:@"input_text"] || [tp isEqualToString:@"copy_text"]) {
            NSString *txt = act[@"text"] ?: @"";
            ok = [self vncSendClipboardText:txt];
            desc = [NSString stringWithFormat:@"写入剪贴板：%@", txt];
        } else if ([tp isEqualToString:@"wait"]) {
            NSInteger ms = MAX(100, MIN(5000, [act[@"ms"] integerValue]));
            usleep((useconds_t)(ms * 1000));
            ok = YES;
            desc = [NSString stringWithFormat:@"等待 %ldms", (long)ms];
        }
        [results addObject:@{@"step": desc, @"ok": @(ok)}];
    }
    return results;
}

#pragma mark - Network & Device Info

+ (NSString *)deviceLanIPv4 {
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *cur = interfaces;
        while (cur != NULL) {
            if (cur->ifa_addr && cur->ifa_addr->sa_family == AF_INET) {
                NSString *ifName = [NSString stringWithUTF8String:cur->ifa_name];
                if ([ifName isEqualToString:@"en0"] || [ifName hasPrefix:@"en"]) {
                    char buf[INET_ADDRSTRLEN];
                    struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
                    if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                        NSString *ip = [NSString stringWithUTF8String:buf];
                        if (![ip hasPrefix:@"127."] && ![ip hasPrefix:@"169.254."]) {
                            address = ip;
                            if ([ifName isEqualToString:@"en0"]) break;
                        }
                    }
                }
            }
            cur = cur->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return address;
}

+ (NSString *)deviceModelName {
    struct utsname sys;
    uname(&sys);
    NSString *code = [NSString stringWithCString:sys.machine encoding:NSUTF8StringEncoding] ?: @"iPhone";
    NSDictionary *models = @{
        @"iPhone9,2": @"iPhone 7 Plus",
        @"iPhone9,4": @"iPhone 7 Plus",
        @"iPhone9,1": @"iPhone 7",
        @"iPhone9,3": @"iPhone 7",
        @"iPhone10,2": @"iPhone 8 Plus",
        @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,3": @"iPhone X",
        @"iPhone10,6": @"iPhone X",
        @"iPhone11,8": @"iPhone XR",
        @"iPhone12,1": @"iPhone 11",
        @"iPhone13,2": @"iPhone 12",
        @"iPhone14,5": @"iPhone 13",
        @"iPhone15,2": @"iPhone 14 Pro"
    };
    return models[code] ?: [UIDevice currentDevice].model;
}

@end
