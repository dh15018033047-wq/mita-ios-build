#import "MitaKeepAliveAndControl.h"
#import "MitaFloatingHudManager.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/utsname.h>
#import <dlfcn.h>
#import <unistd.h>
#import <zlib.h>

typedef struct {
    int32_t priority;
    uint64_t user_data;
} mita_main_memstatus_props_t;

static void MitaRelaxMainJetsam(void) {
    typedef int (*MemCtlFn)(uint32_t, int32_t, uint32_t, void *, size_t);
    MemCtlFn fn = (MemCtlFn)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (!fn) return;
    pid_t pid = getpid();
    mita_main_memstatus_props_t props = { 17, 0 };
    fn(1, pid, 0, &props, sizeof(props));
    fn(5, pid, (uint32_t)-1, NULL, 0);
}

@interface MitaKeepAliveAndControl ()
@property (nonatomic, strong) AVAudioPlayer *silentPlayer;
@property (nonatomic, assign, readwrite) BOOL isKeepAliveRunning;
@property (nonatomic, assign) BOOL audioObserversAdded;
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
    // 2 秒 8000Hz 16-bit 单声道人耳完全不可闻超微底噪 (-84dBFS ±2 LSB)，防止 iOS 15 mediaserverd 静音挂起进程
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
    NSMutableData *pcm = [NSMutableData dataWithLength:dataBytes];
    int16_t *samples = (int16_t *)pcm.mutableBytes;
    for (uint32_t i = 0; i < numSamples; i++) {
        samples[i] = (i & 1) ? 2 : -2;
    }
    [wav appendData:pcm];
    return wav;
}

- (void)handleAudioSessionInterruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeEnded && self.isKeepAliveRunning) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.isKeepAliveRunning = NO;
            [self startSilentKeepAlive];
        });
    }
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    if (self.isKeepAliveRunning) {
        self.silentPlayer = nil;
        self.isKeepAliveRunning = NO;
        [self startSilentKeepAlive];
    }
}

- (void)startSilentKeepAlive {
    MitaRelaxMainJetsam();
    if (!self.audioObserversAdded) {
        self.audioObserversAdded = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAudioSessionInterruption:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMediaServicesReset:)
                                                     name:AVAudioSessionMediaServicesWereResetNotification
                                                   object:nil];
    }
    if (self.isKeepAliveRunning && self.silentPlayer.isPlaying) return;
    NSError *err = nil;
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    // Playback + MixWithOthers：不打断、不压低音乐/游戏，同时确保后台不被 iOS 冻结挂起
    [sess setCategory:AVAudioSessionCategoryPlayback
          withOptions:AVAudioSessionCategoryOptionMixWithOthers
                error:&err];
    [sess setActive:YES error:&err];

    if (!self.silentPlayer) {
        NSData *wav = [self buildSilentWavData];
        self.silentPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&err];
        self.silentPlayer.numberOfLoops = -1;
        self.silentPlayer.volume = 0.015;
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

- (NSString *)extractTextFromActionDict:(NSDictionary *)act {
    if (![act isKindOfClass:[NSDictionary class]]) return @"";
    id b64Val = act[@"text_b64"];
    if ([b64Val isKindOfClass:[NSString class]]) {
        NSString *b64Str = [(NSString *)b64Val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (b64Str.length > 0) {
            NSData *decoded = [[NSData alloc] initWithBase64EncodedString:b64Str
                                                                  options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (decoded.length > 0) {
                NSString *utf8Str = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
                if (utf8Str != nil) {
                    return utf8Str;
                }
            }
        }
    }
    id rawTxt = act[@"text"];
    if ([rawTxt isKindOfClass:[NSString class]]) {
        return (NSString *)rawTxt;
    }
    if (rawTxt && rawTxt != [NSNull null]) {
        return [rawTxt description];
    }
    return @"";
}

- (void)copyTextToPasteboard:(NSString *)text {
    NSString *cleanText = text ?: @"";
    dispatch_block_t writeBlk = ^{
        [UIPasteboard generalPasteboard].string = cleanText;
    };
    if ([NSThread isMainThread]) {
        writeBlk();
    } else {
        dispatch_sync(dispatch_get_main_queue(), writeBlk);
    }
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
    // 严格通过巨魔原生权限在主线程同步写入系统 UIPasteboard，严禁发送 VNC Latin-1 ClientCutText 造成乱码回写！
    [self copyTextToPasteboard:(text ?: @"")];
    return YES;
}

// 检测微信软键盘是否已弹起（键盘弹起时 y≈0.595 存在白色输入条且底部为键盘面板）
static BOOL MitaDetectKeyboardOpenInImage(CGImageRef cgImg) {
    if (!cgImg) return NO;
    const int sw = 120, sh = 220;
    uint8_t *px = (uint8_t *)calloc(1, sw * sh * 4);
    if (!px) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, sw, sh, 8, sw * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), cgImg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    int iy0 = (int)(sh * 0.575), iy1 = (int)(sh * 0.615);
    int ix0 = (int)(sw * 0.22),  ix1 = (int)(sw * 0.66);
    int whiteCnt = 0, totalInput = 0;
    for (int y = iy0; y <= iy1; y++) {
        for (int x = ix0; x <= ix1; x++) {
            int off = (y * sw + x) * 4;
            int r = px[off], g = px[off + 1], b = px[off + 2];
            totalInput++;
            if (r >= 238 && g >= 238 && b >= 238) whiteCnt++;
        }
    }

    int ky0 = (int)(sh * 0.70), ky1 = (int)(sh * 0.88);
    int kx0 = (int)(sw * 0.10), kx1 = (int)(sw * 0.90);
    int grayBandCnt = 0, totalKb = 0;
    for (int y = ky0; y <= ky1; y++) {
        for (int x = kx0; x <= kx1; x++) {
            int off = (y * sw + x) * 4;
            int r = px[off], g = px[off + 1], b = px[off + 2];
            totalKb++;
            if (r >= 185 && r <= 226 && g >= 188 && g <= 228 && b >= 192 && b <= 234 && abs(r - b) <= 16) {
                grayBandCnt++;
            }
        }
    }
    free(px);
    double whiteRatio = totalInput > 0 ? ((double)whiteCnt / (double)totalInput) : 0.0;
    double kbGrayRatio = totalKb > 0 ? ((double)grayBandCnt / (double)totalKb) : 0.0;
    return (whiteRatio >= 0.48 && kbGrayRatio >= 0.22);
}

// 像素级极速定位 iOS 黑色气泡菜单「粘贴」(y ∈ [0.475, 0.575], x ∈ [0.09, 0.58])，耗时 < 2ms
static BOOL MitaLocatePasteCalloutInImage(CGImageRef cgImg, double *outNormX, double *outNormY) {
    if (!cgImg) return NO;
    const int sw = 207, sh = 368;
    uint8_t *px = (uint8_t *)calloc(1, sw * sh * 4);
    if (!px) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, sw, sh, 8, sw * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), cgImg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    int y0 = (int)(sh * 0.475), y1 = (int)(sh * 0.575);
    int x0 = (int)(sw * 0.09),  x1 = (int)(sw * 0.58);
    double sumX = 0.0, sumY = 0.0;
    int darkHits = 0, brightTextInDark = 0;

    for (int y = y0; y <= y1; y++) {
        for (int x = x0; x <= x1; x++) {
            int off = (y * sw + x) * 4;
            int r = px[off], g = px[off + 1], b = px[off + 2];
            if (r <= 58 && g <= 58 && b <= 64) {
                darkHits++;
                sumX += x;
                sumY += y;
            } else if (r >= 215 && g >= 215 && b >= 215 && x > x0 + 2 && x < x1 - 2) {
                int leftOff = (y * sw + (x - 3)) * 4;
                int rightOff = (y * sw + (x + 3)) * 4;
                if ((px[leftOff] <= 65 && px[leftOff + 1] <= 65) || (px[rightOff] <= 65 && px[rightOff + 1] <= 65)) {
                    brightTextInDark++;
                }
            }
        }
    }
    free(px);

    if (darkHits >= 42 && brightTextInDark >= 4) {
        if (outNormX) *outNormX = (sumX / (double)darkHits) / (double)sw;
        if (outNormY) *outNormY = (sumY / (double)darkHits) / (double)sh;
        return YES;
    }
    return NO;
}

- (BOOL)vncTypeAndSendWeChatText:(NSString *)text autoSend:(BOOL)autoSend {
    NSString *clean = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0) return NO;

    // 1. 主线程同步写入系统 UIPasteboard（100% 原生 UTF-8/UTF-16，绝不走 VNC Latin-1，绝不敲 26 键拼音！）
    [self copyTextToPasteboard:clean];

    // 2. 检查当前软键盘是否已打开，若已打开则直接复用免重开
    UIImage *preImg = [self captureLocalVncScreenImage];
    BOOL kbOpen = (preImg && preImg.CGImage) ? MitaDetectKeyboardOpenInImage(preImg.CGImage) : NO;

    if (!kbOpen) {
        if (![self vncTapNormX:0.447 normY:0.960]) {
            return NO;
        }
        usleep(290000);
    }

    // 3. 在软键盘上方已聚焦输入框左侧光标区 (0.246, 0.595) 呼出 iOS 黑色「粘贴」气泡菜单
    [self vncTapNormX:0.246 normY:0.595];
    usleep(140000);

    double pasteX = 0.250, pasteY = 0.535;
    UIImage *menuImg = [self captureLocalVncScreenImage];
    BOOL foundMenu = (menuImg && menuImg.CGImage) ? MitaLocatePasteCalloutInImage(menuImg.CGImage, &pasteX, &pasteY) : NO;

    if (!foundMenu) {
        [self.vncLock lock];
        int w = 0, h = 0;
        int fd = [self connectLocalRfbAndHandshake:&w height:&h];
        if (fd >= 0) {
            uint16_t lx = (uint16_t)MAX(1, MIN(w - 2, (int)llround(0.246 * w)));
            uint16_t ly = (uint16_t)MAX(1, MIN(h - 2, (int)llround(0.595 * h)));
            sendPointer(fd, 0, lx, ly);
            usleep(6000);
            sendPointer(fd, 1, lx, ly);
            usleep(420000);
            sendPointer(fd, 0, lx, ly);
            usleep(15000);
            close(fd);
        }
        [self.vncLock unlock];
        usleep(95000);

        UIImage *menuImg2 = [self captureLocalVncScreenImage];
        if (menuImg2 && menuImg2.CGImage) {
            MitaLocatePasteCalloutInImage(menuImg2.CGImage, &pasteX, &pasteY);
        }
    }

    // 4. 秒点「粘贴」气泡菜单将剪贴板完整 UTF-8 文本整句上屏
    BOOL pasted = [self vncTapNormX:pasteX normY:pasteY];
    usleep(85000);

    // 5. 若开启自动发送，立即点击软键盘右下角绿色/蓝色「发送」按钮 (0.884, 0.970)
    BOOL ok = pasted;
    if (autoSend) {
        ok = [self vncTapNormX:0.884 normY:0.970];
        usleep(45000);
    }
    return ok;
}

static void releaseVncFbBytes(void *info, const void *data, size_t size) {
    if (data) free((void *)data);
}

- (nullable UIImage *)captureLocalVncScreenImage {
    [self.vncLock lock];
    int w = 0, h = 0;
    int fd = [self connectLocalRfbAndHandshake:&w height:&h];
    if (fd < 0 || w <= 0 || h <= 0 || w > 3000 || h > 4000) {
        if (fd >= 0) close(fd);
        [self.vncLock unlock];
        return nil;
    }

    // 1. SetPixelFormat: 32bpp little-endian BGRX (与 CGBitmapByteOrder32Little | NoneSkipFirst 完美对应)
    uint8_t pf[20] = {
        0, 0, 0, 0,
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    };
    // 2. SetEncodings: 仅请求 Raw (0)，本机回环零压缩最快
    uint8_t enc[8] = { 2, 0, 0, 1, 0, 0, 0, 0 };
    // 3. FramebufferUpdateRequest (incremental=0, 0, 0, w, h)
    uint8_t req[10] = {
        3, 0,
        0, 0, 0, 0,
        (uint8_t)((w >> 8) & 0xFF), (uint8_t)(w & 0xFF),
        (uint8_t)((h >> 8) & 0xFF), (uint8_t)(h & 0xFF)
    };
    if (!writeExact(fd, pf, 20) || !writeExact(fd, enc, 8) || !writeExact(fd, req, 10)) {
        close(fd);
        [self.vncLock unlock];
        return nil;
    }

    size_t stride = (size_t)w * 4;
    size_t bufSize = stride * (size_t)h;
    uint8_t *fb = (uint8_t *)calloc(1, bufSize);
    if (!fb) {
        close(fd);
        [self.vncLock unlock];
        return nil;
    }

    BOOL gotFrame = NO;
    for (int msgGuard = 0; msgGuard < 8 && !gotFrame; msgGuard++) {
        uint8_t msgType = 255;
        if (readExact(fd, &msgType, 1) != 1) break;
        if (msgType == 0) { // FramebufferUpdate
            uint8_t padAndCnt[3];
            if (readExact(fd, padAndCnt, 3) != 3) break;
            uint16_t nRects = ((uint16_t)padAndCnt[1] << 8) | padAndCnt[2];
            BOOL rectOk = YES;
            for (uint16_t i = 0; i < nRects; i++) {
                uint8_t rh[12];
                if (readExact(fd, rh, 12) != 12) { rectOk = NO; break; }
                uint16_t rx = ((uint16_t)rh[0] << 8) | rh[1];
                uint16_t ry = ((uint16_t)rh[2] << 8) | rh[3];
                uint16_t rw = ((uint16_t)rh[4] << 8) | rh[5];
                uint16_t rhgt = ((uint16_t)rh[6] << 8) | rh[7];
                int32_t rEnc = (int32_t)(((uint32_t)rh[8] << 24) | ((uint32_t)rh[9] << 16) | ((uint32_t)rh[10] << 8) | rh[11]);
                if (rEnc != 0 || rx + rw > w || ry + rhgt > h) { rectOk = NO; break; }
                if (rx == 0 && rw == w) {
                    if (readExact(fd, fb + (size_t)ry * stride, (size_t)rhgt * stride) != (ssize_t)((size_t)rhgt * stride)) {
                        rectOk = NO; break;
                    }
                } else {
                    size_t rowBytes = (size_t)rw * 4;
                    for (uint16_t row = 0; row < rhgt; row++) {
                        uint8_t *dst = fb + ((size_t)(ry + row) * stride) + ((size_t)rx * 4);
                        if (readExact(fd, dst, rowBytes) != (ssize_t)rowBytes) { rectOk = NO; break; }
                    }
                }
            }
            gotFrame = rectOk;
        } else if (msgType == 2) { // Bell
            continue;
        } else if (msgType == 3) { // ServerCutText
            uint8_t pad[3];
            int32_t netLen = 0;
            if (readExact(fd, pad, 3) != 3 || readExact(fd, &netLen, 4) != 4) break;
            int32_t clen = (int32_t)ntohl((uint32_t)netLen);
            size_t skip = (size_t)(clen < 0 ? -clen : clen);
            uint8_t dump[1024];
            while (skip > 0) {
                size_t chunk = skip < sizeof(dump) ? skip : sizeof(dump);
                if (readExact(fd, dump, chunk) != (ssize_t)chunk) { skip = 1; break; }
                skip -= chunk;
            }
            if (skip != 0) break;
        } else {
            break;
        }
    }
    close(fd);
    [self.vncLock unlock];

    if (!gotFrame) {
        free(fb);
        return nil;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, fb, bufSize, releaseVncFbBytes);
    CGImageRef cgImg = CGImageCreate(
        w, h, 8, 32, stride, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
        provider, NULL, false, kCGRenderingIntentDefault
    );
    UIImage *img = cgImg ? [UIImage imageWithCGImage:cgImg] : nil;
    if (cgImg) CGImageRelease(cgImg);
    if (provider) CGDataProviderRelease(provider);
    if (cs) CGColorSpaceRelease(cs);
    return img;
}

- (NSArray<NSDictionary *> *)executeActionBatch:(NSArray<NSDictionary *> *)actions {
    NSMutableArray *results = [NSMutableArray array];
    if (![actions isKindOfClass:[NSArray class]] || actions.count == 0) return results;
    [[MitaFloatingHudManager shared] triggerControlPulseSeconds:6.5 phase:@"controlling"];
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
            NSString *txt = [self extractTextFromActionDict:act];
            [self copyTextToPasteboard:txt];
            ok = YES;
            desc = [NSString stringWithFormat:@"写入剪贴板(%lu字)：%@", (unsigned long)txt.length, txt];
        } else if ([tp isEqualToString:@"wechat_send"]) {
            NSString *txt = [self extractTextFromActionDict:act];
            BOOL autoSnd = act[@"auto_send"] ? [act[@"auto_send"] boolValue] : YES;
            ok = [self vncTypeAndSendWeChatText:txt autoSend:autoSnd];
            desc = [NSString stringWithFormat:@"微信粘贴发送(%lu字)：%@", (unsigned long)txt.length, txt];
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
