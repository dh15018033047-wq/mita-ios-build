#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MitaFloatingHudManager : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isSupported;
@property (nonatomic, readonly) BOOL isActive;

- (void)attachToHostView:(UIView *)hostView;
- (void)updateWithRunning:(BOOL)running
              startedAtTs:(NSTimeInterval)startedAtTs
                    phase:(NSString *)phase
                    model:(NSString *)model
             repliedCount:(NSInteger)repliedCount
               statusLine:(NSString *)statusLine;

- (void)triggerControlPulseSeconds:(NSTimeInterval)seconds phase:(NSString *)phase;
- (BOOL)ensureOverlayDaemonLaunched;
- (void)syncPlaybackState;
- (BOOL)startFloatingWindow;
- (void)stopFloatingWindow;
- (NSDictionary *)overlayDiagnostics;

@end

NS_ASSUME_NONNULL_END
