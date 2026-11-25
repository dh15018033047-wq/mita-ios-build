#import "MainViewController.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import "MitaAiGroupEngine.h"
#import "MitaLanServer.h"
#import "MitaFloatingHudManager.h"
#import <WebKit/WebKit.h>

@interface MainViewController () <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation MainViewController

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return UIStatusBarStyleDarkContent;
    }
    return UIStatusBarStyleDefault;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.949 green:0.949 blue:0.969 alpha:1.0];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"mitaAsync"];

    NSString *bridgeJs =
        @"window.MikaBridge = {\n"
        @"  _sync: function(op, arg) {\n"
        @"    try { return window.prompt('__MITA_SYNC__:' + JSON.stringify({op: op, arg: arg || ''})) || ''; } catch(e) { return ''; }\n"
        @"  },\n"
        @"  getStateJson: function() { return this._sync('getStateJson', ''); },\n"
        @"  saveConfig: function(jsonStr) { return this._sync('saveConfig', jsonStr); },\n"
        @"  clearLogs: function() { return this._sync('clearLogs', ''); },\n"
        @"  openPermission: function(kind) { return this._sync('openPermission', kind); },\n"
        @"  controlFloatingHud: function(mode) { return this._sync('controlFloatingHud', mode || 'toggle'); },\n"
        @"  toggleRemoteControl: function(reqId, enabled) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'toggleRemoteControl', reqId:reqId, args:[Boolean(enabled)]});\n"
        @"  },\n"
        @"  updateAntiBurnin: function(reqId, enabled, intervalSec) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'updateAntiBurnin', reqId:reqId, args:[Boolean(enabled), Number(intervalSec || 180)]});\n"
        @"  },\n"
        @"  triggerAntiBurninNow: function(reqId) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'triggerAntiBurninNow', reqId:reqId, args:[]});\n"
        @"  },\n"
        @"  launchNativeApp: function(reqId, bundleId) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'launchNativeApp', reqId:reqId, args:[bundleId || '']});\n"
        @"  },\n"
        @"  toggleAutoReply: function(reqId, running, launchWechat) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'toggleAutoReply', reqId:reqId, args:[Boolean(running), Boolean(launchWechat)]});\n"
        @"  },\n"
        @"  sendAgentMessage: function(reqId, text) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'sendAgentMessage', reqId:reqId, args:[text || '']});\n"
        @"  },\n"
        @"  testWeChatReply: function(reqId, contact, sampleMsg, isGroup, sender) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'testWeChatReply', reqId:reqId, args:[contact || '', sampleMsg || '', Boolean(isGroup), sender || '']});\n"
        @"  },\n"
        @"  fetchModels: function(reqId, baseUrl, apiKey) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'fetchModels', reqId:reqId, args:[baseUrl || '', apiKey || '']});\n"
        @"  },\n"
        @"  syncWithPc: function(reqId, dir) {\n"
        @"    window.webkit.messageHandlers.mitaAsync.postMessage({method:'syncWithPc', reqId:reqId, args:[dir || 'pull']});\n"
        @"  }\n"
        @"};\n";

    WKUserScript *script = [[WKUserScript alloc] initWithSource:bridgeJs
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES];
    [ucc addUserScript:script];
    cfg.userContentController = ucc;

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.UIDelegate = self;
    self.webView.navigationDelegate = self;
    self.webView.scrollView.bounces = YES;
    self.webView.opaque = YES;
    self.webView.backgroundColor = self.view.backgroundColor;
    [self.view addSubview:self.webView];

    // 挂载 iOS 15 跨应用画中画全局悬浮框底层宿主层（位于 WebView 底下，零视觉干扰）
    [[MitaFloatingHudManager shared] attachToHostView:self.view];

    NSURL *htmlUrl = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html"];
    if (htmlUrl) {
        [self.webView loadFileURL:htmlUrl allowingReadAccessToURL:[htmlUrl URLByDeletingLastPathComponent]];
    }
}

- (void)notifyHostResume {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:@"window.__onMikaHostResume && window.__onMikaHostResume()" completionHandler:nil];
    });
}

- (NSString *)buildFullStateJsonString {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSMutableDictionary *d = [[store toDictionaryRedactingKey:YES] mutableCopy];
    NSString *ip = [MitaKeepAliveAndControl deviceLanIPv4];
    d[@"platform"] = @"ios";
    d[@"version"] = @"5.1.0";
    d[@"device_ip"] = ip;
    d[@"lan_endpoint"] = [NSString stringWithFormat:@"http://%@:%d", ip, [MitaLanServer shared].listenPort];
    d[@"device_model"] = [MitaKeepAliveAndControl deviceModelName];
    d[@"ios_version"] = [UIDevice currentDevice].systemVersion ?: @"15.8.2";
    d[@"remote_control_enabled"] = @(store.remoteControlEnabled);
    d[@"anti_burnin_enabled"] = @(store.antiBurninEnabled);
    d[@"anti_burnin_interval_sec"] = @(store.antiBurninIntervalSec);
    d[@"anti_burnin_count"] = @(store.antiBurninCount);
    d[@"last_burnin_at"] = @(store.lastBurninAt);
    d[@"keep_alive_running"] = @([MitaKeepAliveAndControl shared].isKeepAliveRunning);
    d[@"troll_signed"] = @(YES);
    d[@"hourly_used"] = @([[MitaAiGroupEngine shared] hourlyUsedCount]);
    d[@"bot_running"] = @([MitaAiGroupEngine shared].isAutoReplyRunning);
    d[@"floating_hud_supported"] = @([MitaFloatingHudManager shared].isSupported);
    d[@"floating_hud_active"] = @([MitaFloatingHudManager shared].isActive);
    d[@"edge_overlay"] = [[MitaFloatingHudManager shared] overlayDiagnostics];
    d[@"runtime_monitor"] = [[MitaAiGroupEngine shared] runtimeStatusSnapshot];
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    return j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
}

- (void)emitAsyncCallback:(NSString *)reqId payload:(NSDictionary *)payload {
    NSData *j = [NSJSONSerialization dataWithJSONObject:(payload ?: @{}) options:0 error:nil];
    NSString *jStr = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
    NSString *safeId = [reqId stringByReplacingOccurrencesOfString:@"'" withString:@""];
    NSString *js = [NSString stringWithFormat:@"window.__onMikaAsync && window.__onMikaAsync('%@', %@)", safeId, jStr];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:js completionHandler:nil];
    });
}

#pragma mark - Synchronous Bridge via WKUIDelegate prompt

- (void)webView:(WKWebView *)webView
runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSString * _Nullable))completionHandler {
    if ([prompt hasPrefix:@"__MITA_SYNC__:"]) {
        NSString *raw = [prompt substringFromIndex:14];
        NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *req = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSString *op = req[@"op"] ?: @"";
        NSString *arg = req[@"arg"] ?: @"";

        if ([op isEqualToString:@"getStateJson"]) {
            completionHandler([self buildFullStateJsonString]);
            return;
        }
        if ([op isEqualToString:@"saveConfig"]) {
            NSData *ad = [arg dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *patch = ad ? [NSJSONSerialization JSONObjectWithData:ad options:0 error:nil] : nil;
            if ([patch isKindOfClass:[NSDictionary class]]) {
                [[MitaConfigStore shared] updateFromDictionary:patch];
                if ([MitaConfigStore shared].remoteControlEnabled || [MitaConfigStore shared].keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning) {
                    [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
                } else {
                    [[MitaKeepAliveAndControl shared] stopSilentKeepAlive];
                }
                if (patch[@"floating_hud_enabled"] != nil || patch[@"remote_control_enabled"] != nil) {
                    if (![MitaConfigStore shared].floatingHudEnabled || ![MitaConfigStore shared].remoteControlEnabled) {
                        [[MitaFloatingHudManager shared] stopFloatingWindow];
                    } else {
                        [[MitaFloatingHudManager shared] ensureOverlayDaemonLaunched];
                        [[MitaFloatingHudManager shared] syncPlaybackState];
                    }
                }
                [[MitaAiGroupEngine shared] pushConfigToPcQuietly];
            }
            NSString *st = [self buildFullStateJsonString];
            completionHandler([NSString stringWithFormat:@"{\"ok\":true,\"state\":%@}", st]);
            return;
        }
        if ([op isEqualToString:@"controlFloatingHud"]) {
            if ([arg isEqualToString:@"start"]) {
                [MitaConfigStore shared].floatingHudEnabled = YES;
                [[MitaFloatingHudManager shared] startFloatingWindow];
            } else if ([arg isEqualToString:@"stop"]) {
                [MitaConfigStore shared].floatingHudEnabled = NO;
                [[MitaFloatingHudManager shared] stopFloatingWindow];
            } else {
                if ([MitaFloatingHudManager shared].isActive) {
                    [MitaConfigStore shared].floatingHudEnabled = NO;
                    [[MitaFloatingHudManager shared] stopFloatingWindow];
                } else {
                    [MitaConfigStore shared].floatingHudEnabled = YES;
                    [[MitaFloatingHudManager shared] startFloatingWindow];
                }
            }
            NSString *st = [self buildFullStateJsonString];
            completionHandler([NSString stringWithFormat:@"{\"ok\":true,\"state\":%@}", st]);
            return;
        }
        if ([op isEqualToString:@"clearLogs"]) {
            [[MitaConfigStore shared] clearLogs];
            completionHandler(@"{\"ok\":true}");
            return;
        }
        if ([op isEqualToString:@"openPermission"]) {
            if ([arg isEqualToString:@"wechat"]) {
                [[MitaKeepAliveAndControl shared] launchAppByNameOrBundleId:@"com.tencent.xin"];
            } else if ([arg isEqualToString:@"trollvnc"]) {
                [[MitaKeepAliveAndControl shared] launchAppByNameOrBundleId:@"com.82flex.TrollVNCApp"];
            } else if ([arg isEqualToString:@"trollstore"]) {
                [[MitaKeepAliveAndControl shared] launchAppByNameOrBundleId:@"com.opa334.TrollStore"];
            } else if ([arg isEqualToString:@"keepalive"]) {
                [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
            } else {
                [[MitaKeepAliveAndControl shared] launchAppByNameOrBundleId:@"com.apple.Preferences"];
            }
            completionHandler(@"{\"ok\":true}");
            return;
        }
        completionHandler(@"{}");
        return;
    }
    completionHandler(defaultText);
}

#pragma mark - Asynchronous Bridge via WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"mitaAsync"] || ![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = (NSDictionary *)message.body;
    NSString *method = body[@"method"] ?: @"";
    NSString *reqId = body[@"reqId"] ?: @"";
    NSArray *args = [body[@"args"] isKindOfClass:[NSArray class]] ? body[@"args"] : @[];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if ([method isEqualToString:@"toggleRemoteControl"]) {
            BOOL wantRc = args.count > 0 ? [args[0] boolValue] : YES;
            MitaConfigStore *store = [MitaConfigStore shared];
            store.remoteControlEnabled = wantRc;
            if (wantRc) {
                [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
                [[MitaLanServer shared] restartListenerIfNeeded];
                [[MitaFloatingHudManager shared] ensureOverlayDaemonLaunched];
                [[MitaFloatingHudManager shared] syncPlaybackState];
                [store addEventLogKind:@"remote" contact:@"远程总控" incoming:@"" detail:@"已开启全局远程控制（电脑操控/防烧屏/边缘流光就绪，无需开微信）" costMs:0];
            } else {
                if ([MitaAiGroupEngine shared].isAutoReplyRunning) {
                    [[MitaAiGroupEngine shared] setAutoReplyRunning:NO launchWeChat:NO triggerSource:@"remote_master_off"];
                }
                [[MitaFloatingHudManager shared] stopFloatingWindow];
                [store addEventLogKind:@"remote" contact:@"远程总控" incoming:@"" detail:@"已关闭全局远程控制（后台零触控干预）" costMs:0];
            }
            // 双向同步到电脑端 /api/remote_control/toggle
            NSString *pc = [store.pcSyncUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            while ([pc hasSuffix:@"/"]) pc = [pc substringToIndex:pc.length - 1];
            if (pc.length >= 8) {
                NSURL *u = [NSURL URLWithString:[pc stringByAppendingString:@"/api/remote_control/toggle"]];
                if (u) {
                    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
                    req.HTTPMethod = @"POST";
                    req.timeoutInterval = 3.0;
                    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
                    NSDictionary *p = @{
                        @"enabled": @(wantRc),
                        @"ip": [MitaKeepAliveAndControl deviceLanIPv4] ?: @"",
                        @"source": @"phone_app",
                        @"sync_phone": @(NO)
                    };
                    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:p options:0 error:nil];
                    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
                }
            }
            NSMutableDictionary *out = [@{@"ok": @(YES), @"remote_control_enabled": @(wantRc)} mutableCopy];
            NSData *stData = [[self buildFullStateJsonString] dataUsingEncoding:NSUTF8StringEncoding];
            id stObj = stData ? [NSJSONSerialization JSONObjectWithData:stData options:0 error:nil] : nil;
            if (stObj) out[@"state"] = stObj;
            [self emitAsyncCallback:reqId payload:out];
        } else if ([method isEqualToString:@"updateAntiBurnin"]) {
            BOOL wantBi = args.count > 0 ? [args[0] boolValue] : YES;
            NSInteger sec = args.count > 1 ? [args[1] integerValue] : 180;
            MitaConfigStore *store = [MitaConfigStore shared];
            store.antiBurninEnabled = wantBi;
            store.antiBurninIntervalSec = MAX(60, MIN(1800, sec));
            [store addEventLogKind:@"burnin" contact:@"防烧屏护屏" incoming:@"" detail:[NSString stringWithFormat:@"已%@防烧屏自动上下轻滑（每 %ld 秒）", wantBi ? @"开启" : @"关闭", (long)store.antiBurninIntervalSec] costMs:0];
            NSString *pc = [store.pcSyncUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            while ([pc hasSuffix:@"/"]) pc = [pc substringToIndex:pc.length - 1];
            if (pc.length >= 8) {
                NSURL *u = [NSURL URLWithString:[pc stringByAppendingString:@"/api/anti_burnin/config"]];
                if (u) {
                    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
                    req.HTTPMethod = @"POST";
                    req.timeoutInterval = 3.0;
                    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
                    NSDictionary *p = @{
                        @"enabled": @(wantBi),
                        @"interval_sec": @(store.antiBurninIntervalSec),
                        @"ip": [MitaKeepAliveAndControl deviceLanIPv4] ?: @"",
                        @"source": @"phone_app",
                        @"sync_phone": @(NO)
                    };
                    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:p options:0 error:nil];
                    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
                }
            }
            NSMutableDictionary *out = [@{@"ok": @(YES), @"anti_burnin_enabled": @(wantBi), @"anti_burnin_interval_sec": @(store.antiBurninIntervalSec)} mutableCopy];
            NSData *stData = [[self buildFullStateJsonString] dataUsingEncoding:NSUTF8StringEncoding];
            id stObj = stData ? [NSJSONSerialization JSONObjectWithData:stData options:0 error:nil] : nil;
            if (stObj) out[@"state"] = stObj;
            [self emitAsyncCallback:reqId payload:out];
        } else if ([method isEqualToString:@"triggerAntiBurninNow"]) {
            MitaConfigStore *store = [MitaConfigStore shared];
            NSString *pc = [store.pcSyncUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            while ([pc hasSuffix:@"/"]) pc = [pc substringToIndex:pc.length - 1];
            __block BOOL pcOk = NO;
            if (pc.length >= 8) {
                NSURL *u = [NSURL URLWithString:[pc stringByAppendingString:@"/api/anti_burnin/trigger"]];
                if (u) {
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
                    req.HTTPMethod = @"POST";
                    req.timeoutInterval = 4.5;
                    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
                    NSDictionary *p = @{@"ip": [MitaKeepAliveAndControl deviceLanIPv4] ?: @""};
                    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:p options:0 error:nil];
                    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                        if (d.length > 0) {
                            id jo = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                            if ([jo isKindOfClass:[NSDictionary class]] && [jo[@"ok"] boolValue]) {
                                pcOk = YES;
                                if (jo[@"anti_burnin_count"]) store.antiBurninCount = [jo[@"anti_burnin_count"] integerValue];
                                if (jo[@"last_burnin_at"]) store.lastBurninAt = [jo[@"last_burnin_at"] doubleValue];
                            }
                        }
                        dispatch_semaphore_signal(sem);
                    }] resume];
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.8 * NSEC_PER_SEC)));
                }
            }
            if (!pcOk) {
                // 电脑离线时走本机回环轻缓上下滑动并归位兜底
                [[MitaKeepAliveAndControl shared] executeActionBatch:@[
                    @{@"action": @"swipe", @"x1": @(0.51), @"y1": @(0.66), @"x2": @(0.51), @"y2": @(0.44)},
                    @{@"action": @"swipe", @"x1": @(0.51), @"y1": @(0.44), @"x2": @(0.51), @"y2": @(0.66)}
                ]];
                store.antiBurninCount = store.antiBurninCount + 1;
                store.lastBurninAt = [[NSDate date] timeIntervalSince1970];
            }
            [store addEventLogKind:@"burnin" contact:@"防烧屏护屏" incoming:@"" detail:@"已完成一次手动温和上下滑动并归位" costMs:0];
            NSMutableDictionary *out = [@{@"ok": @(YES), @"via_pc": @(pcOk)} mutableCopy];
            NSData *stData = [[self buildFullStateJsonString] dataUsingEncoding:NSUTF8StringEncoding];
            id stObj = stData ? [NSJSONSerialization JSONObjectWithData:stData options:0 error:nil] : nil;
            if (stObj) out[@"state"] = stObj;
            [self emitAsyncCallback:reqId payload:out];
        } else if ([method isEqualToString:@"launchNativeApp"]) {
            NSString *bid = args.count > 0 ? [args[0] description] : @"";
            BOOL ok = [[MitaKeepAliveAndControl shared] launchAppByNameOrBundleId:bid];
            [self emitAsyncCallback:reqId payload:@{@"ok": @(ok), @"bundle_id": bid ?: @""}];
        } else if ([method isEqualToString:@"toggleAutoReply"]) {
            BOOL wantRun = args.count > 0 ? [args[0] boolValue] : YES;
            BOOL openWx = args.count > 1 ? [args[1] boolValue] : NO;
            NSDictionary *res = [[MitaAiGroupEngine shared] setAutoReplyRunning:wantRun launchWeChat:openWx triggerSource:@"app_button"];
            NSMutableDictionary *out = [res mutableCopy];
            NSData *stData = [[self buildFullStateJsonString] dataUsingEncoding:NSUTF8StringEncoding];
            id stObj = stData ? [NSJSONSerialization JSONObjectWithData:stData options:0 error:nil] : nil;
            if (stObj) out[@"state"] = stObj;
            [self emitAsyncCallback:reqId payload:out];
        } else if ([method isEqualToString:@"sendAgentMessage"]) {
            NSString *txt = args.count > 0 ? [args[0] description] : @"";
            [[MitaAiGroupEngine shared] planPhoneControlOrChat:txt completion:^(NSDictionary *res) {
                [self emitAsyncCallback:reqId payload:res];
            }];
        } else if ([method isEqualToString:@"testWeChatReply"]) {
            NSString *contact = args.count > 0 ? [args[0] description] : @"00";
            NSString *sample = args.count > 1 ? [args[1] description] : @"";
            BOOL isGrp = args.count > 2 ? [args[2] boolValue] : NO;
            NSString *sender = args.count > 3 ? [args[3] description] : @"";
            [[MitaAiGroupEngine shared] generateWeChatReplyForContact:contact isGroup:isGrp groupSender:sender incoming:sample completion:^(NSDictionary *res) {
                [self emitAsyncCallback:reqId payload:res];
            }];
        } else if ([method isEqualToString:@"fetchModels"]) {
            NSString *base = args.count > 0 ? [args[0] description] : @"";
            NSString *key = args.count > 1 ? [args[1] description] : @"";
            [[MitaAiGroupEngine shared] fetchModelsWithBaseUrl:base apiKey:key completion:^(NSDictionary *res) {
                [self emitAsyncCallback:reqId payload:res];
            }];
        } else if ([method isEqualToString:@"syncWithPc"]) {
            NSString *dir = args.count > 0 ? [args[0] description] : @"pull";
            [[MitaAiGroupEngine shared] syncWithPcDirection:dir completion:^(NSDictionary *res) {
                NSMutableDictionary *out = [res mutableCopy];
                NSData *stData = [[self buildFullStateJsonString] dataUsingEncoding:NSUTF8StringEncoding];
                id stObj = stData ? [NSJSONSerialization JSONObjectWithData:stData options:0 error:nil] : nil;
                if (stObj) out[@"state"] = stObj;
                [self emitAsyncCallback:reqId payload:out];
            }];
        }
    });
}

@end
