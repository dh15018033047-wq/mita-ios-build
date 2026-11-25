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
    if (store.remoteControlEnabled || store.keepAliveEnabled || store.botRunning) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
    [[MitaLanServer shared] startOnPort:19080];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.rootVC = [[MainViewController alloc] init];
    self.window.rootViewController = self.rootVC;
    [self.window makeKeyAndVisible];

    // 同步全局远程控制边缘流光状态（不再绑死微信自动回复！）
    [[MitaFloatingHudManager shared] syncPlaybackState];
    // 仅当远程总控与微信模块均开启时，恢复微信自动回复模块守护
    if (store.remoteControlEnabled) {
        [[MitaAiGroupEngine shared] bootstrapRuntimeIfNeeded];
    }
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    MitaConfigStore *store = [MitaConfigStore shared];
    if (store.remoteControlEnabled || store.keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
    [[MitaLanServer shared] restartListenerIfNeeded];
    [[MitaFloatingHudManager shared] syncPlaybackState];
    [self.rootVC notifyHostResume];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    MitaConfigStore *store = [MitaConfigStore shared];
    if ((store.remoteControlEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning) && store.floatingHudEnabled) {
        [[MitaFloatingHudManager shared] syncPlaybackState];
    }
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    MitaConfigStore *store = [MitaConfigStore shared];
    if (store.remoteControlEnabled || store.keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
}

@end
