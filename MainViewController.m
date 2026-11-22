#import "MainViewController.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import "MitaAiGroupEngine.h"
#import "MitaLanServer.h"
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
    self.view.backgroundColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.976 alpha:1.0];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"mitaAsync"];

    // 在页面加载前注入与前端 100% 兼容的原生 window.MikaBridge 对象
    NSString *bridgeJs =
        @"window.MikaBridge = {\n"
        @"  _sync: function(op, arg) {\n"
        @"    try { return window.prompt('__MITA_SYNC__:' + JSON.stringify({op: op, arg: arg || ''})) || ''; } catch(e) { return ''; }\n"
        @"  },\n"
        @"  getStateJson: function() { return this._sync('getStateJson', ''); },\n"
        @"  saveConfig: function(jsonStr) { return this._sync('saveConfig', jsonStr); },\n"
        @"  clearLogs: function() { return this._sync('clearLogs', ''); },\n"
        @"  openPermission: function(kind) { return this._sync('openPermission', kind); },\n"
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
    self.webView.opaque = NO;
    self.webView.backgroundColor = self.view.backgroundColor;
    [self.view addSubview:self.webView];

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
    d[@"device_ip"] = ip;
    d[@"lan_endpoint"] = [NSString stringWithFormat:@"http://%@:%d", ip, [MitaLanServer shared].listenPort];
    d[@"device_model"] = [MitaKeepAliveAndControl deviceModelName];
    d[@"ios_version"] = [UIDevice currentDevice].systemVersion ?: @"15.7.9";
    d[@"keep_alive_running"] = @([MitaKeepAliveAndControl shared].isKeepAliveRunning);
    d[@"troll_signed"] = @(YES);
    d[@"hourly_used"] = @([[MitaAiGroupEngine shared] hourlyUsedCount]);
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
                if ([MitaConfigStore shared].keepAliveEnabled) {
                    [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
                } else {
                    [[MitaKeepAliveAndControl shared] stopSilentKeepAlive];
                }
                [[MitaAiGroupEngine shared] pushConfigToPcQuietly];
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
        if ([method isEqualToString:@"sendAgentMessage"]) {
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
