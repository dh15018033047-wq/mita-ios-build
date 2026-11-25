#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MitaLanServer : NSObject

+ (instancetype)shared;
- (void)startOnPort:(int)port;
- (void)restartListenerIfNeeded;
- (void)stop;
@property (nonatomic, readonly) int listenPort;
@property (nonatomic, readonly) BOOL isRunning;

@end

NS_ASSUME_NONNULL_END
