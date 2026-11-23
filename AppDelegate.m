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
    [MitaConfigStore shared];
    if ([MitaConfigStore shared].keepAliveEnabled || [MitaConfigStore shared].botRunning) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
    [[MitaLanServer shared] startOnPort:19080];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.rootVC = [[MainViewController alloc] init];
    self.window.rootViewController = self.rootVC;
    [self.window makeKeyAndVisible];

    // 恢复上次已启动的微信自动回复巡检守护
    [[MitaAiGroupEngine shared] bootstrapRuntimeIfNeeded];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    if ([MitaConfigStore shared].keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
    [self.rootVC notifyHostResume];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    if ([MitaAiGroupEngine shared].isAutoReplyRunning && [MitaConfigStore shared].floatingHudEnabled) {
        [[MitaFloatingHudManager shared] syncPlaybackState];
    }
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    if ([MitaConfigStore shared].keepAliveEnabled || [MitaAiGroupEngine shared].isAutoReplyRunning) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
}

@end
