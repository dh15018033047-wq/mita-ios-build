#import "MitaLanServer.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import "MitaAiGroupEngine.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface MitaLanServer ()
@property (nonatomic, assign, readwrite) int listenPort;
@property (nonatomic, assign, readwrite) BOOL isRunning;
@property (nonatomic, assign) int serverFd;
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
        _serverFd = -1;
        _listenPort = 19080;
        _serverQueue = dispatch_queue_create("com.mita.phoneagent.lanserver", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)startOnPort:(int)port {
    if (self.isRunning) return;
    self.listenPort = port > 0 ? port : 19080;
    self.isRunning = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self acceptLoop];
    });
    [self startHeartbeatLoop];
}

- (void)stop {
    self.isRunning = NO;
    if (self.serverFd >= 0) {
        close(self.serverFd);
        self.serverFd = -1;
    }
    if (self.heartbeatTimer) {
        dispatch_source_cancel(self.heartbeatTimer);
        self.heartbeatTimer = nil;
    }
}

- (NSDictionary *)buildPingPayload {
    MitaConfigStore *store = [MitaConfigStore shared];
    CGRect nb = [UIScreen mainScreen].nativeBounds;
    return @{
        @"ok": @(YES),
        @"platform": @"ios",
        @"app": @"MitaPhoneAgent",
        @"app_title": @"米塔 手机智能体 (巨魔版)",
        @"version": @"2.5.0",
        @"model": [MitaKeepAliveAndControl deviceModelName],
        @"ios_version": [UIDevice currentDevice].systemVersion ?: @"15.7.9",
        @"width": @((int)nb.size.width),
        @"height": @((int)nb.size.height),
        @"ip": [MitaKeepAliveAndControl deviceLanIPv4],
        @"port": @(self.listenPort),
        @"keep_alive": @([MitaKeepAliveAndControl shared].isKeepAliveRunning),
        @"acc_ready": @(YES),
        @"notif_ready": @(YES),
        @"bot_enabled": @(store.botEnabled),
        @"whitelist_only": @(store.whitelistOnly),
        @"persona_id": store.personaId,
        @"api_model": store.apiModel,
        @"hourly_used": @([[MitaAiGroupEngine shared] hourlyUsedCount])
    };
}

- (void)startHeartbeatLoop {
    if (self.heartbeatTimer) return;
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
        if (fd < 0) { sleep(2); continue; }
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)self.listenPort);
        addr.sin_addr.s_addr = INADDR_ANY;

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
            close(fd);
            sleep(2);
            continue;
        }
        self.serverFd = fd;
        while (self.isRunning) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) break;
            dispatch_async(self.serverQueue, ^{
                [self handleClientFd:client];
            });
        }
        close(fd);
        self.serverFd = -1;
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
                NSString *hStr = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
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
    NSString *hStr = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
    NSArray *lines = [hStr componentsSeparatedByString:@"\r\n"];
    NSArray *parts = lines.count ? [lines[0] componentsSeparatedByString:@" "] : @[];
    NSString *method = parts.count > 0 ? [parts[0] uppercaseString] : @"GET";
    NSString *fullPath = parts.count > 1 ? parts[1] : @"/";
    NSString *path = [[fullPath componentsSeparatedByString:@"?"] firstObject] ?: @"/";
    NSString *query = ([fullPath containsString:@"?"]) ? [[fullPath componentsSeparatedByString:@"?"] lastObject] : @"";

    NSData *bodyData = (buf.length > hdrEnd.location + 4)
        ? [buf subdataWithRange:NSMakeRange(hdrEnd.location + 4, buf.length - hdrEnd.location - 4)]
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
    } else if ([path isEqualToString:@"/action"] && [method isEqualToString:@"POST"]) {
        id inObj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : @{};
        NSDictionary *act = [inObj isKindOfClass:[NSDictionary class]] ? inObj : @{};
        NSArray *steps = [[MitaKeepAliveAndControl shared] executeActionBatch:@[act]];
        respObj = @{@"ok": @(YES), @"steps": steps};
    } else {
        code = 404;
        respObj = @{@"ok": @(NO), @"error": [NSString stringWithFormat:@"Not found: %@", path]};
    }

    NSData *jsonOut = [NSJSONSerialization dataWithJSONObject:respObj options:0 error:nil] ?: [NSData data];
    [self writeHttpResponseFd:fd code:code contentType:@"application/json; charset=utf-8" body:jsonOut];
    close(fd);
}

@end
