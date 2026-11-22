#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MitaKeepAliveAndControl : NSObject

+ (instancetype)shared;

// 1. 无打扰混音静音后台保活（绝不抢占游戏/音乐外放声音）
@property (nonatomic, readonly) BOOL isKeepAliveRunning;
- (void)startSilentKeepAlive;
- (void)stopSilentKeepAlive;

// 2. 巨魔高权限应用秒开 (LSApplicationWorkspace + URL Scheme 兜底)
- (BOOL)launchAppByNameOrBundleId:(NSString *)appSpec;
- (BOOL)openUrlString:(NSString *)urlStr;
- (void)copyTextToPasteboard:(NSString *)text;

// 3. 本机回环连接 TrollVNC (127.0.0.1:5901) 实现脱离电脑独立控机
- (BOOL)probeLocalTrollVnc;
- (BOOL)vncTapNormX:(double)nx normY:(double)ny;
- (BOOL)vncSwipeFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2 durationSec:(double)dur;
- (BOOL)vncHomeKey;
- (BOOL)vncSendClipboardText:(NSString *)text;

// 4. 批量执行 AI 规划动作
- (NSArray<NSDictionary *> *)executeActionBatch:(NSArray<NSDictionary *> *)actions;

// 5. 获取本机局域网 Wi-Fi IP
+ (NSString *)deviceLanIPv4;
+ (NSString *)deviceModelName;

@end

NS_ASSUME_NONNULL_END
