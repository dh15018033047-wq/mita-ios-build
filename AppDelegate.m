#import <UIKit/UIKit.h>
#import "MainViewController.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import "MitaLanServer.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) MainViewController *rootVC;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [MitaConfigStore shared];
    if ([MitaConfigStore shared].keepAliveEnabled) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
    [[MitaLanServer shared] startOnPort:19080];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.rootVC = [[MainViewController alloc] init];
    self.window.rootViewController = self.rootVC;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    if ([MitaConfigStore shared].keepAliveEnabled) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
    [self.rootVC notifyHostResume];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    if ([MitaConfigStore shared].keepAliveEnabled) {
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }
}

@end
