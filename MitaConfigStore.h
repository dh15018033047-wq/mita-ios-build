#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MitaConfigStore : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL remoteControlEnabled;
@property (nonatomic, assign) BOOL antiBurninEnabled;
@property (nonatomic, assign) NSInteger antiBurninIntervalSec;
@property (nonatomic, assign) NSInteger antiBurninCount;
@property (nonatomic, assign) double lastBurninAt;
@property (nonatomic, assign) BOOL botEnabled;
@property (nonatomic, assign) BOOL botRunning;
@property (nonatomic, assign) BOOL floatingHudEnabled;
@property (nonatomic, assign) BOOL keepAliveEnabled;
@property (nonatomic, assign) BOOL whitelistOnly;
@property (nonatomic, assign) BOOL blockNewFriends;
@property (nonatomic, assign) BOOL blockMarketing;
@property (nonatomic, assign) BOOL adminWeChatControl;
@property (nonatomic, assign) BOOL recognizeAdminInGroup;
@property (nonatomic, assign) BOOL verifyAdminAvatarWxid;
@property (nonatomic, assign) BOOL groupSplitBubbles;
@property (nonatomic, assign) BOOL adGuardEnabled;
@property (nonatomic, assign) BOOL autoKickEnabled;
@property (nonatomic, assign) BOOL autoApproveJoinEnabled;

@property (nonatomic, copy) NSString *apiBaseUrl;
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *geminiApiKey;
@property (nonatomic, copy) NSString *apiModel;
@property (nonatomic, copy) NSString *reasoningEffort;  // auto | none | minimal | low | medium | high | xhigh
@property (nonatomic, copy) NSString *pcSyncUrl;
@property (nonatomic, copy) NSString *personaId;
@property (nonatomic, copy) NSString *customPrompt;
@property (nonatomic, copy) NSString *groupKeywords;
@property (nonatomic, copy) NSString *groupVibeMode;    // natural | light | lively | at_only
@property (nonatomic, copy) NSString *groupPermMode;    // all | authorized_only | admin_only
@property (nonatomic, copy) NSString *adKeywords;
@property (nonatomic, copy) NSString *adWarnTemplate;
@property (nonatomic, copy) NSString *adKickTemplate;

@property (nonatomic, assign) NSInteger groupBurstMin;
@property (nonatomic, assign) NSInteger groupBurstMax;
@property (nonatomic, assign) NSInteger maxRepliesPerHour;
@property (nonatomic, assign) NSInteger cooldownSec;
@property (nonatomic, assign) NSInteger warnKickThreshold;
@property (nonatomic, assign) NSInteger approveIntervalMin;
@property (nonatomic, assign) NSInteger approveMaxPerBatch;

@property (nonatomic, copy) NSArray<NSString *> *adminContacts;
@property (nonatomic, copy) NSArray<NSString *> *adminWxids;
@property (nonatomic, copy) NSArray<NSString *> *fetchedModels;
@property (nonatomic, copy) NSArray<NSString *> *allowedContacts;
@property (nonatomic, copy) NSArray<NSString *> *allowedGroups;
@property (nonatomic, copy) NSArray<NSString *> *groupSubAdmins;
@property (nonatomic, copy) NSArray<NSString *> *groupAuthorizedMembers;
@property (nonatomic, copy) NSArray<NSString *> *groupMutedMembers;

- (NSString *)effectiveApiKey;
- (NSArray<NSDictionary *> *)personaPresets;
- (NSString *)effectivePromptForContact:(NSString *)contact
                                isGroup:(BOOL)isGroup
                            groupSender:(NSString *)groupSender
                              groupRole:(NSString *)groupRole;

- (void)updateFromDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionaryRedactingKey:(BOOL)redact;

- (NSArray<NSDictionary *> *)memoryForContact:(NSString *)contact;
- (void)appendMemoryForContact:(NSString *)contact userMsg:(NSString *)uMsg botReply:(NSString *)bReply;
- (void)clearMemoryForContact:(NSString *)contact;

- (void)addEventLogKind:(NSString *)kind
                contact:(NSString *)contact
               incoming:(NSString *)incoming
                 detail:(NSString *)detail
                 costMs:(NSInteger)costMs;
- (NSArray<NSDictionary *> *)eventLogs;
- (void)clearLogs;

+ (NSString *)normalizeName:(NSString *)raw;
+ (NSArray<NSString *> *)splitCsvList:(id)val;

@end

NS_ASSUME_NONNULL_END
