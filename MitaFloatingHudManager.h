#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MitaFloatingHudManager : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isSupported;
@property (nonatomic, readonly) BOOL isActive;

- (void)attachToHostView:(UIView *)hostView;
- (void)updateWithRunning:(BOOL)running
                    phase:(NSString *)phase
                    model:(NSString *)model
             repliedCount:(NSInteger)repliedCount
               statusLine:(NSString *)statusLine;

- (void)syncPlaybackState;
- (BOOL)startFloatingWindow;
- (void)stopFloatingWindow;

@end

NS_ASSUME_NONNULL_END
