#import "MitaFloatingHudManager.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import <spawn.h>
#import <notify.h>
#import <signal.h>
#import <errno.h>
#import <dlfcn.h>
#import <sys/wait.h>
#import <sys/stat.h>

extern char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
typedef int (*MitaSetPersonaFn)(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
typedef int (*MitaSetPersonaUidFn)(const posix_spawnattr_t * __restrict, uid_t);

static void MitaApplyRootPersonaAttr(posix_spawnattr_t *attr) {
    MitaSetPersonaFn fnPersona = (MitaSetPersonaFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    MitaSetPersonaUidFn fnUid  = (MitaSetPersonaUidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    MitaSetPersonaUidFn fnGid  = (MitaSetPersonaUidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (fnPersona) fnPersona(attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (fnUid) fnUid(attr, 0);
    if (fnGid) fnGid(attr, 0);
}

#define MITA_NOTIFY_EDGE_CHANGED "com.mita.phoneagent.edge.changed"
#define MITA_NOTIFY_EDGE_EXIT    "com.mita.phoneagent.edge.exit"

@interface MitaFloatingHudManager ()
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, assign) BOOL curRunning;
@property (nonatomic, assign) NSTimeInterval curStartedAtTs;
@property (nonatomic, assign) NSTimeInterval pulseUntilTs;
@property (nonatomic, copy) NSString *curPhase;
@property (nonatomic, copy) NSString *curModel;
@property (nonatomic, assign) NSInteger curRepliedCount;
@property (nonatomic, copy) NSString *curStatusLine;
@property (nonatomic, strong) dispatch_source_t keepSyncSource;
- (void)ensureKeepSyncTimerStarted;
@end

@implementation MitaFloatingHudManager

+ (instancetype)shared {
    static MitaFloatingHudManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[MitaFloatingHudManager alloc] init];
    });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _stateLock = [[NSLock alloc] init];
        _curRunning = NO;
        _curStartedAtTs = 0.0;
        _pulseUntilTs = 0.0;
        _curPhase = @"idle";
        _curModel = @"gemini-4-neon-xhigh";
        _curRepliedCount = 0;
        _curStatusLine = @"点击「立即启动」开启全局屏幕边缘蓝色波浪控制";
        [self ensureKeepSyncTimerStarted];
    }
    return self;
}

- (NSString *)sharedIpcDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject ?: NSTemporaryDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];
    chmod([doc UTF8String], 0777);
    return doc;
}

- (NSString *)stateFilePath {
    return [[self sharedIpcDirectory] stringByAppendingPathComponent:@"mita_edge_state.json"];
}

- (NSString *)pidFilePath {
    return [[self sharedIpcDirectory] stringByAppendingPathComponent:@"mita_edge_overlay.pid"];
}

- (NSString *)diagFilePath {
    return [[self sharedIpcDirectory] stringByAppendingPathComponent:@"mita_edge_diag.json"];
}

- (NSString *)helperBinaryPath {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    return [bundlePath stringByAppendingPathComponent:@"MitaEdgeOverlay"];
}

- (BOOL)isSupported {
    return [[NSFileManager defaultManager] isExecutableFileAtPath:[self helperBinaryPath]] || YES;
}

- (BOOL)isDaemonAlive {
    NSString *pidStr = [NSString stringWithContentsOfFile:[self pidFilePath] encoding:NSUTF8StringEncoding error:nil];
    if (pidStr.length == 0) return NO;
    pid_t pid = (pid_t)[pidStr intValue];
    if (pid <= 1) return NO;
    // 主进程可能是 mobile(501)，守护进程是 root(0)：kill(pid, 0) 返回 -1 且 errno == EPERM 代表进程 100% 存活！
    int rc = kill(pid, 0);
    if (rc == 0 || errno == EPERM) {
        return YES;
    }
    return NO;
}

- (BOOL)isActive {
    BOOL remoteOn = [MitaConfigStore shared].remoteControlEnabled;
    return [MitaConfigStore shared].floatingHudEnabled && remoteOn && [self isDaemonAlive];
}

- (BOOL)ensureOverlayDaemonLaunched {
    if (![MitaConfigStore shared].floatingHudEnabled || ![MitaConfigStore shared].remoteControlEnabled) return NO;
    if ([self isDaemonAlive]) return YES;

    NSString *binPath = [self helperBinaryPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:binPath]) {
        return NO;
    }

    NSString *ipcDir = [self sharedIpcDirectory];
    const char *exe = [binPath UTF8String];
    const char *dirArg = [ipcDir UTF8String];
    const char *args[] = { exe, "-hud", dirArg, NULL };

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    MitaApplyRootPersonaAttr(&attr);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    pid_t childPid = 0;
    int rc = posix_spawn(&childPid, exe, NULL, &attr, (char * const *)args, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        // 兜底：若当前环境未授予 persona-mgmt，尝试直接普通 spawn
        posix_spawnattr_t fbAttr;
        posix_spawnattr_init(&fbAttr);
        posix_spawnattr_setpgroup(&fbAttr, 0);
        posix_spawnattr_setflags(&fbAttr, POSIX_SPAWN_SETPGROUP);
        rc = posix_spawn(&childPid, exe, NULL, &fbAttr, (char * const *)args, environ);
        posix_spawnattr_destroy(&fbAttr);
    }

    if (rc == 0 && childPid > 0) {
        int unused = 0;
        waitpid(childPid, &unused, WNOHANG);
        return YES;
    }
    return NO;
}

- (void)terminateOverlayDaemon {
    notify_post(MITA_NOTIFY_EDGE_EXIT);
    NSString *binPath = [self helperBinaryPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:binPath]) return;

    NSString *ipcDir = [self sharedIpcDirectory];
    const char *exe = [binPath UTF8String];
    const char *dirArg = [ipcDir UTF8String];
    const char *args[] = { exe, "-exit", dirArg, NULL };

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    MitaApplyRootPersonaAttr(&attr);
    pid_t pid = 0;
    if (posix_spawn(&pid, exe, NULL, &attr, (char * const *)args, environ) == 0 && pid > 0) {
        int st = 0;
        waitpid(pid, &st, WNOHANG);
    }
    posix_spawnattr_destroy(&attr);
}

- (void)writeAndNotifyEdgeState {
    [self.stateLock lock];
    BOOL running = self.curRunning;
    NSTimeInterval startTs = self.curStartedAtTs;
    NSTimeInterval pulseTs = self.pulseUntilTs;
    NSString *phase = self.curPhase ?: @"idle";
    NSString *model = self.curModel ?: @"gemini-4-neon-xhigh";
    NSInteger repCnt = self.curRepliedCount;
    NSString *line = self.curStatusLine ?: @"";
    [self.stateLock unlock];

    BOOL edgeEn = [MitaConfigStore shared].floatingHudEnabled;
    BOOL remoteOn = [MitaConfigStore shared].remoteControlEnabled;
    BOOL effectiveRunning = remoteOn ? (remoteOn || running) : NO;
    NSString *effectivePhase = phase;
    if (!remoteOn) {
        effectiveRunning = NO;
        pulseTs = 0.0;
        effectivePhase = @"idle";
    } else if (remoteOn && !running) {
        if ([effectivePhase isEqualToString:@"idle"] || effectivePhase.length == 0) {
            effectivePhase = @"remote";
        }
        if (startTs <= 0) {
            startTs = [[NSDate date] timeIntervalSince1970];
            [self.stateLock lock];
            if (_curStartedAtTs <= 0) _curStartedAtTs = startTs;
            startTs = _curStartedAtTs;
            [self.stateLock unlock];
        }
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (edgeEn && remoteOn) {
        [self ensureOverlayDaemonLaunched];
    }

    NSDictionary *payload = @{
        @"edge_enabled": @(edgeEn),
        @"running": @(effectiveRunning),
        @"remote_enabled": @(remoteOn),
        @"started_at": @(startTs),
        @"pulse_until": @(pulseTs),
        @"phase": effectivePhase,
        @"model": model,
        @"replied_count": @(repCnt),
        @"status_line": line,
        @"updated_at": @(now)
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (json) {
        NSString *fp = [self stateFilePath];
        [json writeToFile:fp atomically:YES];
        chmod([fp UTF8String], 0666);
    }
    notify_post(MITA_NOTIFY_EDGE_CHANGED);
}

- (void)ensureKeepSyncTimerStarted {
    [self.stateLock lock];
    if (self.keepSyncSource != nil) {
        [self.stateLock unlock];
        return;
    }
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                              (uint64_t)(3.0 * NSEC_PER_SEC),
                              (uint64_t)(0.2 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        [weakSelf onHeartbeatRefresh];
    });
    self.keepSyncSource = src;
    [self.stateLock unlock];
    dispatch_resume(src);
}

- (void)attachToHostView:(UIView *)hostView {
    [self ensureKeepSyncTimerStarted];
    // 仅在悬浮层与远程总控同时开启时预热守护进程；若远程总控关闭则确保守护进程停止
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if ([MitaConfigStore shared].floatingHudEnabled && [MitaConfigStore shared].remoteControlEnabled) {
            [self ensureOverlayDaemonLaunched];
            [self writeAndNotifyEdgeState];
        } else {
            [self stopFloatingWindow];
        }
    });
}

- (void)onHeartbeatRefresh {
    BOOL hudOn = [MitaConfigStore shared].floatingHudEnabled;
    BOOL remoteOn = [MitaConfigStore shared].remoteControlEnabled;
    if (!hudOn || !remoteOn) {
        if ([self isDaemonAlive]) {
            [self stopFloatingWindow];
        }
        return;
    }

    [self.stateLock lock];
    BOOL running = self.curRunning;
    NSTimeInterval pulseTs = self.pulseUntilTs;
    [self.stateLock unlock];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL shouldKeepWave = (remoteOn || running || pulseTs > now);

    // 每 3.0 秒检查守护进程存活，仅在 hudOn && remoteOn 为真时自动拉起并同步最新状态
    if (![self isDaemonAlive]) {
        if ([self ensureOverlayDaemonLaunched]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [self writeAndNotifyEdgeState];
            });
        }
    }
    if (shouldKeepWave) {
        [self writeAndNotifyEdgeState];
    }
}

- (void)updateWithRunning:(BOOL)running
              startedAtTs:(NSTimeInterval)startedAtTs
                    phase:(NSString *)phase
                    model:(NSString *)model
             repliedCount:(NSInteger)repliedCount
               statusLine:(NSString *)statusLine {
    [self.stateLock lock];
    _curRunning = running;
    if (running) {
        if (startedAtTs > 0) _curStartedAtTs = startedAtTs;
        else if (_curStartedAtTs <= 0) _curStartedAtTs = [[NSDate date] timeIntervalSince1970];
    } else {
        _curStartedAtTs = 0.0;
    }
    _curPhase = [phase ?: @"idle" copy];
    if (model.length > 0) _curModel = [model copy];
    _curRepliedCount = repliedCount;
    if (statusLine.length > 0) _curStatusLine = [statusLine copy];
    [self.stateLock unlock];

    [self writeAndNotifyEdgeState];
}

- (void)triggerControlPulseSeconds:(NSTimeInterval)seconds phase:(NSString *)phase {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval dur = MAX(2.0, MIN(30.0, seconds));
    [self.stateLock lock];
    if (now + dur > _pulseUntilTs) {
        _pulseUntilTs = now + dur;
    }
    if (!_curRunning && _curStartedAtTs <= 0) {
        _curStartedAtTs = now;
    }
    if (phase.length > 0) {
        _curPhase = [phase copy];
    }
    [self.stateLock unlock];

    [self writeAndNotifyEdgeState];
}

- (void)syncPlaybackState {
    [self writeAndNotifyEdgeState];
}

- (BOOL)startFloatingWindow {
    [MitaConfigStore shared].floatingHudEnabled = YES;
    [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    BOOL ok = [self ensureOverlayDaemonLaunched];
    // 点亮一次 5 秒蓝色波浪预览脉冲（若已在控制运行中则常驻流淌）
    [self triggerControlPulseSeconds:5.0 phase:(self.curRunning ? self.curPhase : @"controlling")];
    return ok;
}

- (void)stopFloatingWindow {
    [self.stateLock lock];
    _pulseUntilTs = 0.0;
    [self.stateLock unlock];

    // 1. 先向本机 :19081/action 短超时 POST 立即隐藏悬浮胶囊与释放窗口
    NSURL *u = [NSURL URLWithString:@"http://127.0.0.1:19081/action"];
    if (u) {
        NSDictionary *offPayload = @{
            @"action": @"set_control_mode",
            @"mode": @"off",
            @"remote_enabled": @(NO)
        };
        NSData *body = [NSJSONSerialization dataWithJSONObject:offPayload options:0 error:nil];
        if (body) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
            req.HTTPMethod = @"POST";
            req.timeoutInterval = 0.30;
            [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
            req.HTTPBody = body;
            [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                dispatch_semaphore_signal(sem);
            }] resume];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)));
        }
    }

    // 2. 写入最新 mita_edge_state.json 并广播
    [self writeAndNotifyEdgeState];

    // 3. 只要关闭了悬浮框或关闭了远程总控，立即彻底终止 :19081 守护进程！
    if (![MitaConfigStore shared].floatingHudEnabled || ![MitaConfigStore shared].remoteControlEnabled) {
        [self terminateOverlayDaemon];
    }
}

- (NSDictionary *)overlayDiagnostics {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"daemon_alive"] = @([self isDaemonAlive]);
    out[@"helper_exists"] = @([[NSFileManager defaultManager] fileExistsAtPath:[self helperBinaryPath]]);
    NSData *d = [NSData dataWithContentsOfFile:[self diagFilePath]];
    if (d.length > 0) {
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            out[@"diag"] = obj;
        }
    }
    return out;
}

@end
