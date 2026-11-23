#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MitaAiGroupEngine : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isAutoReplyRunning;

- (void)bootstrapRuntimeIfNeeded;
- (NSDictionary *)runtimeStatusSnapshot;
- (NSDictionary *)setAutoReplyRunning:(BOOL)running
                         launchWeChat:(BOOL)launchWx
                        triggerSource:(NSString *)source;

- (NSInteger)hourlyUsedCount;

// 核心校验：私聊防乱回 + 群聊真人自然跟聊 + 群内管理员身份识别
- (NSDictionary *)evaluateIncomingForContact:(NSString *)contact
                                     isGroup:(BOOL)isGroup
                                 groupSender:(NSString *)groupSender
                                     rawText:(NSString *)rawText;

// 核心群管：识别并执行群聊内管理员调权限与群配置口令
- (NSDictionary *)tryExecuteAdminCommandForContact:(NSString *)contact
                                           isGroup:(BOOL)isGroup
                                       groupSender:(NSString *)groupSender
                                           rawText:(NSString *)rawText;

// 异步调用本机 API 生成回复或规划手机控制动作
- (void)generateWeChatReplyForContact:(NSString *)contact
                              isGroup:(BOOL)isGroup
                          groupSender:(NSString *)groupSender
                             incoming:(NSString *)incoming
                           completion:(void (^)(NSDictionary *result))completion;

- (void)planPhoneControlOrChat:(NSString *)userText
                    completion:(void (^)(NSDictionary *result))completion;

- (void)fetchModelsWithBaseUrl:(NSString *)baseUrl
                        apiKey:(NSString *)apiKey
                    completion:(void (^)(NSDictionary *result))completion;

- (void)syncWithPcDirection:(NSString *)direction
                 completion:(void (^)(NSDictionary *result))completion;

- (void)pushConfigToPcQuietly;

@end

NS_ASSUME_NONNULL_END
