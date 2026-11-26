#import "MitaLanServer.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import "MitaAiGroupEngine.h"
#import "MitaFloatingHudManager.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <signal.h>
#import <unistd.h>

@interface MitaLanServer ()
@property (nonatomic, assign, readwrite) int listenPort;
@property (nonatomic, assign, readwrite) BOOL isRunning;
@property (nonatomic, assign) int serverFd;
@property (nonatomic, assign) BOOL needRebind;
@property (nonatomic, assign) int cachedWidth;
@property (nonatomic, assign) int cachedHeight;
@property (nonatomic, copy) NSString *cachedIosVersion;
@property (nonatomic, copy) NSString *lastBoundIp;
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, strong) dispatch_source_t heartbeatTimer;
@end

@implementation MitaLanServer

+ (instancetype)shared {
    static MitaLanServer *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[MitaLanServer alloc] init];
    });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        signal(SIGPIPE, SIG_IGN);
        _serverFd = -1;
        _listenPort = 19080;
        _needRebind = NO;
        _serverQueue = dispatch_queue_create("com.mita.phoneagent.lanserver", DISPATCH_QUEUE_CONCURRENT);
        CGRect nb = [UIScreen mainScreen].nativeBounds;
        _cachedWidth = (int)nb.size.width;
        _cachedHeight = (int)nb.size.height;
        _cachedIosVersion = [[UIDevice currentDevice].systemVersion copy] ?: @"15.8.2";
        _lastBoundIp = [[MitaKeepAliveAndControl deviceLanIPv4] copy] ?: @"";
    }
    return self;
}

- (void)restartListenerIfNeeded {
    if (!self.isRunning) {
        [self startOnPort:self.listenPort > 0 ? self.listenPort : 19080];
        return;
    }
    self.needRebind = YES;
}

- (void)startOnPort:(int)port {
    if (self.isRunning) return;
    signal(SIGPIPE, SIG_IGN);
    self.listenPort = port > 0 ? port : 19080;
    self.isRunning = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self acceptLoop];
    });
    if ([MitaConfigStore shared].remoteControlEnabled) {
        [self startHeartbeatLoop];
    }
}

- (void)pauseBackgroundHeartbeat {
    if (self.heartbeatTimer) {
        dispatch_source_cancel(self.heartbeatTimer);
        self.heartbeatTimer = nil;
    }
}

- (void)resumeBackgroundHeartbeat {
    if ([MitaConfigStore shared].remoteControlEnabled) {
        [self startHeartbeatLoop];
    }
}

- (void)stop {
    self.isRunning = NO;
    int fd = self.serverFd;
    self.serverFd = -1;
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
    [self pauseBackgroundHeartbeat];
}

- (NSDictionary *)buildPingPayload {
    MitaConfigStore *store = [MitaConfigStore shared];
    return @{
        @"ok": @(YES),
        @"platform": @"ios",
        @"app": @"MitaPhoneAgent",
        @"app_title": @"米塔 手机智能体 (巨魔版)",
        @"version": @"5.5.0",
        @"model": [MitaKeepAliveAndControl deviceModelName],
        @"ios_version": self.cachedIosVersion ?: @"15.8.2",
        @"width": @(self.cachedWidth > 0 ? self.cachedWidth : 1242),
        @"height": @(self.cachedHeight > 0 ? self.cachedHeight : 2208),
        @"ip": [MitaKeepAliveAndControl deviceLanIPv4],
        @"port": @(self.listenPort),
        @"remote_control_enabled": @(store.remoteControlEnabled),
        @"anti_burnin_enabled": @(store.antiBurninEnabled),
        @"anti_burnin_interval_sec": @(store.antiBurninIntervalSec),
        @"anti_burnin_count": @(store.antiBurninCount),
        @"last_burnin_at": @(store.lastBurninAt),
        @"keep_alive": @([MitaKeepAliveAndControl shared].isKeepAliveRunning),
        @"acc_ready": @(YES),
        @"notif_ready": @(YES),
        @"bot_enabled": @(store.botEnabled),
        @"bot_running": @([MitaAiGroupEngine shared].isAutoReplyRunning),
        @"floating_hud_enabled": @(store.floatingHudEnabled),
        @"edge_overlay": [[MitaFloatingHudManager shared] overlayDiagnostics],
        @"runtime_monitor": [[MitaAiGroupEngine shared] runtimeStatusSnapshot],
        @"whitelist_only": @(store.whitelistOnly),
        @"persona_id": store.personaId,
        @"api_model": store.apiModel,
        @"reasoning_effort": store.reasoningEffort,
        @"hourly_used": @([[MitaAiGroupEngine shared] hourlyUsedCount])
    };
}

- (void)startHeartbeatLoop {
    if (self.heartbeatTimer) return;
    if (![MitaConfigStore shared].remoteControlEnabled) return;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
    self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(self.heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 12 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.heartbeatTimer, ^{
        [weakSelf sendHeartbeatOnce];
    });
    dispatch_resume(self.heartbeatTimer);
}

- (void)sendHeartbeatOnce {
    if (![MitaConfigStore shared].remoteControlEnabled) {
        [self pauseBackgroundHeartbeat];
        return;
    }
    NSString *pc = [MitaConfigStore shared].pcSyncUrl;
    while ([pc hasSuffix:@"/"]) pc = [pc substringToIndex:pc.length - 1];
    if (pc.length < 8) return;
    NSURL *u = [NSURL URLWithString:[pc stringByAppendingString:@"/api/phone_agent/heartbeat"]];
    if (!u) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 3.0;
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:[self buildPingPayload] options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
}

- (void)acceptLoop {
    while (self.isRunning) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { sleep(1); continue; }
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)self.listenPort);
        addr.sin_addr.s_addr = INADDR_ANY;

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 32) != 0) {
            close(fd);
            sleep(1);
            continue;
        }
        self.serverFd = fd;
        self.needRebind = NO;
        self.lastBoundIp = [[MitaKeepAliveAndControl deviceLanIPv4] copy] ?: @"";
        int idleTicks = 0;

        while (self.isRunning && !self.needRebind) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(fd, &rfds);
            struct timeval tv;
            tv.tv_sec = 2;
            tv.tv_usec = 0;
            int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
            if (sel < 0) {
                break;
            }
            if (sel == 0) {
                idleTicks += 1;
                // 每 10 秒检查 Wi-Fi IP 是否变化，断网重连后立即重建监听 socket 彻底杜绝 19080 假死！
                if (idleTicks >= 5) {
                    idleTicks = 0;
                    NSString *curIp = [MitaKeepAliveAndControl deviceLanIPv4] ?: @"";
                    if (curIp.length > 6 && ![curIp isEqualToString:(self.lastBoundIp ?: @"")]) {
                        self.lastBoundIp = [curIp copy];
                        break;
                    }
                }
                continue;
            }
            idleTicks = 0;
            int client = accept(fd, NULL, NULL);
            if (client < 0) break;
            int noSig = 1;
#ifdef SO_NOSIGPIPE
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSig, sizeof(noSig));
#endif
            dispatch_async(self.serverQueue, ^{
                [self handleClientFd:client];
            });
        }
        close(fd);
        if (self.serverFd == fd) {
            self.serverFd = -1;
        }
    }
}

- (void)writeHttpResponseFd:(int)fd code:(int)code contentType:(NSString *)ct body:(NSData *)body {
    NSString *st = (code == 200) ? @"OK" : (code == 404 ? @"Not Found" : @"Error");
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"Cache-Control: no-store, no-cache, must-revalidate\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        @"Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        @"Connection: close\r\n\r\n",
        code, st, ct, (unsigned long)body.length];
    NSData *hData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, hData.bytes, hData.length, 0);
    if (body.length > 0) send(fd, body.bytes, body.length, 0);
}

- (void)handleClientFd:(int)fd {
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    NSRange hdrEnd = NSMakeRange(NSNotFound, 0);
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSInteger contentLen = 0;

    while (buf.length < 262144) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buf appendBytes:chunk length:(NSUInteger)n];
        if (hdrEnd.location == NSNotFound) {
            hdrEnd = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
            if (hdrEnd.location != NSNotFound) {
                NSData *hdrSlice = [buf subdataWithRange:NSMakeRange(0, hdrEnd.location)];
                NSString *hStr = [[NSString alloc] initWithData:hdrSlice encoding:NSUTF8StringEncoding]
                              ?: [[NSString alloc] initWithData:hdrSlice encoding:NSISOLatin1StringEncoding]
                              ?: @"";
                for (NSString *ln in [hStr componentsSeparatedByString:@"\r\n"]) {
                    if ([[ln lowercaseString] hasPrefix:@"content-length:"]) {
                        contentLen = [[[ln substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] integerValue];
                    }
                }
            }
        }
        if (hdrEnd.location != NSNotFound && buf.length >= hdrEnd.location + 4 + (NSUInteger)MAX(0, contentLen)) {
            break;
        }
    }

    if (hdrEnd.location == NSNotFound) { close(fd); return; }
    NSData *hdrSlice = [buf subdataWithRange:NSMakeRange(0, hdrEnd.location)];
    NSString *hStr = [[NSString alloc] initWithData:hdrSlice encoding:NSUTF8StringEncoding]
                  ?: [[NSString alloc] initWithData:hdrSlice encoding:NSISOLatin1StringEncoding]
                  ?: @"";
    NSArray *lines = [hStr componentsSeparatedByString:@"\r\n"];
    NSArray *parts = lines.count ? [lines[0] componentsSeparatedByString:@" "] : @[];
    NSString *method = parts.count > 0 ? [parts[0] uppercaseString] : @"GET";
    NSString *fullPath = parts.count > 1 ? parts[1] : @"/";
    NSString *path = [[fullPath componentsSeparatedByString:@"?"] firstObject] ?: @"/";
    NSString *query = ([fullPath containsString:@"?"]) ? [[fullPath componentsSeparatedByString:@"?"] lastObject] : @"";

    NSUInteger availBody = (buf.length > hdrEnd.location + 4) ? (buf.length - hdrEnd.location - 4) : 0;
    NSUInteger takeBody = (contentLen > 0 && (NSUInteger)contentLen < availBody) ? (NSUInteger)contentLen : availBody;
    NSData *bodyData = (takeBody > 0)
        ? [buf subdataWithRange:NSMakeRange(hdrEnd.location + 4, takeBody)]
        : [NSData data];

    if ([method isEqualToString:@"OPTIONS"]) {
        [self writeHttpResponseFd:fd code:200 contentType:@"text/plain" body:[NSData data]];
        close(fd);
        return;
    }

    NSDictionary *respObj = nil;
    int code = 200;

    if ([path isEqualToString:@"/ping"] || [path isEqualToString:@"/status"]) {
        respObj = [self buildPingPayload];
    } else if ([path isEqualToString:@"/config"]) {
        MitaConfigStore *store = [MitaConfigStore shared];
        if ([method isEqualToString:@"POST"] && bodyData.length > 0) {
            id inObj = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
            if ([inObj isKindOfClass:[NSDictionary class]]) {
                [store updateFromDictionary:(NSDictionary *)inObj];
            }
        }
        BOOL redact = ![query containsString:@"raw=1"];
        NSMutableDictionary *d = [[store toDictionaryRedactingKey:redact] mutableCopy];
        d[@"ok"] = @(YES);
        d[@"status"] = [self buildPingPayload];
        respObj = d;
    } else if ([path isEqualToString:@"/toggle_remote"] && [method isEqualToString:@"POST"]) {
        id inObj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : @{};
        NSDictionary *dict = [inObj isKindOfClass:[NSDictionary class]] ? inObj : @{};
        MitaConfigStore *store = [MitaConfigStore shared];
        if (dict[@"remote_control_enabled"] != nil || dict[@"enabled"] != nil) {
            BOOL wantRc = dict[@"remote_control_enabled"] != nil ? [dict[@"remote_control_enabled"] boolValue] : [dict[@"enabled"] boolValue];
            store.remoteControlEnabled = wantRc;
            if (wantRc) {
                if (store.keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning) {
                    [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
                }
                [self resumeBackgroundHeartbeat];
                [[MitaFloatingHudManager shared] ensureOverlayDaemonLaunched];
                [[MitaFloatingHudManager shared] syncPlaybackState];
            } else {
                if ([MitaAiGroupEngine shared].isAutoReplyRunning || store.botRunning) {
                    [[MitaAiGroupEngine shared] setAutoReplyRunning:NO launchWeChat:NO triggerSource:@"remote_off"];
                }
                [[MitaFloatingHudManager shared] stopFloatingWindow];
                [[MitaKeepAliveAndControl shared] stopSilentKeepAlive];
                [self pauseBackgroundHeartbeat];
            }
        }
        if (dict[@"anti_burnin_enabled"] != nil) store.antiBurninEnabled = [dict[@"anti_burnin_enabled"] boolValue];
        if (dict[@"anti_burnin_interval_sec"] != nil) store.antiBurninIntervalSec = [dict[@"anti_burnin_interval_sec"] integerValue];
        if (dict[@"anti_burnin_count"] != nil) store.antiBurninCount = [dict[@"anti_burnin_count"] integerValue];
        if (dict[@"last_burnin_at"] != nil) store.lastBurninAt = [dict[@"last_burnin_at"] doubleValue];
        respObj = [self buildPingPayload];
    } else if ([path isEqualToString:@"/toggle_bot"] && [method isEqualToString:@"POST"]) {
        id inObj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : @{};
        NSDictionary *dict = [inObj isKindOfClass:[NSDictionary class]] ? inObj : @{};
        BOOL wantRun = dict[@"running"] ? [dict[@"running"] boolValue] : YES;
        respObj = [[MitaAiGroupEngine shared] setAutoReplyRunning:wantRun launchWeChat:NO triggerSource:@"pc_remote"];
    } else if ([path isEqualToString:@"/action"] && [method isEqualToString:@"POST"]) {
        id inObj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : @{};
        NSDictionary *act = [inObj isKindOfClass:[NSDictionary class]] ? inObj : @{};
        if ([MitaConfigStore shared].remoteControlEnabled) {
            [[MitaFloatingHudManager shared] triggerControlPulseSeconds:6.5 phase:@"controlling"];
        }
        NSArray *batch = [act[@"actions"] isKindOfClass:[NSArray class]] ? act[@"actions"] : @[act];
        NSArray *steps = [[MitaKeepAliveAndControl shared] executeActionBatch:batch];
        respObj = @{@"ok": @(YES), @"steps": steps, @"version": @"5.5.0"};
    } else if ([path isEqualToString:@"/edge_pulse"]) {
        id inObj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : @{};
        NSDictionary *dict = [inObj isKindOfClass:[NSDictionary class]] ? inObj : @{};
        double sec = dict[@"seconds"] ? [dict[@"seconds"] doubleValue] : 6.0;
        NSString *ph = [dict[@"phase"] isKindOfClass:[NSString class]] ? dict[@"phase"] : @"controlling";
        [[MitaFloatingHudManager shared] triggerControlPulseSeconds:sec phase:ph];
        respObj = @{@"ok": @(YES), @"edge_overlay": [[MitaFloatingHudManager shared] overlayDiagnostics]};
    } else {
        code = 404;
        respObj = @{@"ok": @(NO), @"error": [NSString stringWithFormat:@"Not found: %@", path]};
    }

    NSData *jsonOut = [NSJSONSerialization dataWithJSONObject:respObj options:0 error:nil] ?: [NSData data];
    [self writeHttpResponseFd:fd code:code contentType:@"application/json; charset=utf-8" body:jsonOut];
    close(fd);
}

@end
