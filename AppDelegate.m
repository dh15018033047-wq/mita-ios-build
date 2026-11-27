#import <UIKit/UIKit.h>
#import "MainViewController.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import "MitaLanServer.h"
#import "MitaAiGroupEngine.h"
#import "MitaFloatingHudManager.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) MainViewController *rootVC;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    MitaConfigStore *store = [MitaConfigStore shared];
    if (store.remoteControlEnabled && (store.keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning || store.botRunning)) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    } else {
        [[MitaKeepAliveAndControl shared] stopSilentKeepAlive];
    }
    [[MitaLanServer shared] startOnPort:19080];
    if (!store.remoteControlEnabled) {
        [[MitaLanServer shared] pauseBackgroundHeartbeat];
    }

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.rootVC = [[MainViewController alloc] init];
    self.window.rootViewController = self.rootVC;
    [self.window makeKeyAndVisible];

    // 同步全局远程控制边缘流光状态（v5.6.0：即便关闭远程总控也保持 :19081 零功耗隐身待命，方便电脑随时自动发现并拉起！）
    [[MitaFloatingHudManager shared] ensureOverlayDaemonLaunched];
    if (store.remoteControlEnabled) {
        [[MitaFloatingHudManager shared] syncPlaybackState];
        [[MitaAiGroupEngine shared] bootstrapRuntimeIfNeeded];
    } else {
        [[MitaFloatingHudManager shared] stopFloatingWindow];
    }
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    MitaConfigStore *store = [MitaConfigStore shared];
    if (store.remoteControlEnabled && (store.keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning)) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    } else {
        [[MitaKeepAliveAndControl shared] stopSilentKeepAlive];
    }
    [[MitaLanServer shared] restartListenerIfNeeded];
    [[MitaFloatingHudManager shared] ensureOverlayDaemonLaunched];
    if (store.remoteControlEnabled) {
        [[MitaLanServer shared] resumeBackgroundHeartbeat];
        [[MitaFloatingHudManager shared] syncPlaybackState];
    } else {
        [[MitaLanServer shared] pauseBackgroundHeartbeat];
        [[MitaFloatingHudManager shared] stopFloatingWindow];
    }
    [self.rootVC notifyHostResume];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    MitaConfigStore *store = [MitaConfigStore shared];
    if (store.remoteControlEnabled && store.floatingHudEnabled) {
        [[MitaFloatingHudManager shared] syncPlaybackState];
    }
    if (!store.remoteControlEnabled) {
        [[MitaKeepAliveAndControl shared] stopSilentKeepAlive];
    }
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    MitaConfigStore *store = [MitaConfigStore shared];
    if (store.remoteControlEnabled && (store.keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning)) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    } else {
        [[MitaKeepAliveAndControl shared] stopSilentKeepAlive];
    }
}

@end
