#import "MitaAiGroupEngine.h"
#import "MitaConfigStore.h"
#import "MitaKeepAliveAndControl.h"
#import "MitaFloatingHudManager.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

@interface MitaAiGroupEngine ()
@property (nonatomic, strong) NSMutableArray<NSNumber *> *recentReplyTimestamps;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *groupWindows;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupMutedUntil;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lastRepliedSignatures;
@property (nonatomic, strong) NSLock *guardLock;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) dispatch_source_t patrolTimer;
@property (nonatomic, assign, readwrite) BOOL isAutoReplyRunning;
@property (nonatomic, assign) BOOL patrolBusy;
@property (nonatomic, assign) NSTimeInterval startedAtTs;
@property (nonatomic, assign) NSInteger totalRepliedCount;
@property (nonatomic, copy) NSString *monitorPhase;
@property (nonatomic, copy) NSString *monitorEngineMode;
@property (nonatomic, copy) NSString *monitorLastContact;
@property (nonatomic, copy) NSString *monitorStatusLine;
@end

@implementation MitaAiGroupEngine

+ (instancetype)shared {
    static MitaAiGroupEngine *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[MitaAiGroupEngine alloc] init];
    });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _recentReplyTimestamps = [NSMutableArray array];
        _groupWindows = [NSMutableDictionary dictionary];
        _groupMutedUntil = [NSMutableDictionary dictionary];
        _lastRepliedSignatures = [NSMutableDictionary dictionary];
        _guardLock = [[NSLock alloc] init];
        _isAutoReplyRunning = NO;
        _patrolBusy = NO;
        _startedAtTs = 0;
        _totalRepliedCount = 0;
        _monitorPhase = @"idle";
        _monitorEngineMode = @"待命未启动";
        _monitorLastContact = @"";
        _monitorStatusLine = @"点击下方「立即启动微信自动回复」开始运行";
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 25.0;
        cfg.timeoutIntervalForResource = 40.0;
        _urlSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (NSInteger)hourlyUsedCount {
    [self.guardLock lock];
    NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - 3600.0;
    while (self.recentReplyTimestamps.count > 0 && self.recentReplyTimestamps.firstObject.doubleValue < cutoff) {
        [self.recentReplyTimestamps removeObjectAtIndex:0];
    }
    NSInteger c = (NSInteger)self.recentReplyTimestamps.count;
    [self.guardLock unlock];
    return c;
}

- (void)recordReplyUsage {
    [self.guardLock lock];
    [self.recentReplyTimestamps addObject:@([[NSDate date] timeIntervalSince1970])];
    [self.guardLock unlock];
}

#pragma mark - Helpers

- (BOOL)list:(NSArray<NSString *> *)list containsNormalized:(NSString *)target {
    NSString *nt = [MitaConfigStore normalizeName:target];
    if (nt.length == 0) return NO;
    for (NSString *item in list) {
        if ([[MitaConfigStore normalizeName:item] isEqualToString:nt]) return YES;
    }
    return NO;
}

- (NSString *)stripMentionPrefix:(NSString *)body {
    NSString *s = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *pre = [NSRegularExpression regularExpressionWithPattern:@"^(?:\\[\\d+条\\]\\s*)?(?:\\[有人@我\\]\\s*)?(?:\\[@所有人\\]\\s*)?" options:0 error:nil];
    s = [pre stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSMutableArray<NSString *> *names = [@[@"豆奶", @"米塔"] mutableCopy];
    for (NSString *k in [MitaConfigStore splitCsvList:[MitaConfigStore shared].groupKeywords]) {
        NSString *ck = [k stringByReplacingOccurrencesOfString:@"@" withString:@""];
        if (ck.length > 0 && ![names containsObject:ck]) [names addObject:ck];
    }
    for (int pass = 0; pass < 2; pass++) {
        for (NSString *n in names) {
            NSString *esc = [NSRegularExpression escapedPatternForString:n];
            NSString *pat = [NSString stringWithFormat:@"^(?:@%@|%@)[\\u2005\\s,，:：!！~～、]*", esc, esc];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:NSRegularExpressionCaseInsensitive error:nil];
            NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
            if (m && m.range.location == 0 && m.range.length > 0) {
                s = [[s substringFromIndex:m.range.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }
    }
    return s;
}

- (NSString *)cleanMemberArg:(NSString *)raw {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[@＠\\s]+|[\\u2005\\s,，。！!~～]+$" options:0 error:nil];
    return [[re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)splitGroupText:(NSString *)rawText
         defaultSender:(NSString *)defaultSender
             outSender:(NSString **)outSender
               outBody:(NSString **)outBody
               outAtMe:(BOOL *)outAtMe {
    NSString *s = [rawText ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL atMe = [s containsString:@"[有人@我]"];
    NSString *sender = [defaultSender ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *body = s;

    if (sender.length == 0) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(?:\\[\\d+条\\]\\s*)?(?:\\[有人@我\\]\\s*)?([^:：\\n]{1,22})[:：]\\s*(.+)$" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (m && m.numberOfRanges >= 3) {
            sender = [[s substringWithRange:[m rangeAtIndex:1]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            body = [[s substringWithRange:[m rangeAtIndex:2]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    if (outSender) *outSender = sender;
    if (outBody) *outBody = body;
    if (outAtMe) *outAtMe = atMe;
}

- (NSDictionary *)resolveGroupRoleForSender:(NSString *)sender body:(NSString *)body {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSString *cleanBody = [body ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (store.recognizeAdminInGroup) {
        if ([self list:store.adminContacts containsNormalized:sender] || [self list:store.adminWxids containsNormalized:sender]) {
            return @{@"role": @"owner", @"is_owner": @(YES), @"is_admin": @(YES), @"pin_ok": @(YES), @"clean_body": cleanBody};
        }
        if ([self list:store.groupSubAdmins containsNormalized:sender]) {
            return @{@"role": @"sub_admin", @"is_owner": @(NO), @"is_admin": @(YES), @"pin_ok": @(YES), @"clean_body": cleanBody};
        }
    }
    if ([self list:store.groupMutedMembers containsNormalized:sender]) {
        return @{@"role": @"muted", @"is_owner": @(NO), @"is_admin": @(NO), @"pin_ok": @(NO), @"clean_body": cleanBody};
    }
    if ([self list:store.groupAuthorizedMembers containsNormalized:sender]) {
        return @{@"role": @"authorized", @"is_owner": @(NO), @"is_admin": @(NO), @"pin_ok": @(NO), @"clean_body": cleanBody};
    }
    return @{@"role": @"member", @"is_owner": @(NO), @"is_admin": @(NO), @"pin_ok": @(NO), @"clean_body": cleanBody};
}

- (BOOL)isNewFriendOrMarketing:(NSString *)text checkNewFriend:(BOOL)chkNew checkMarketing:(BOOL)chkMkt outReason:(NSString **)reason {
    if (chkNew) {
        NSRegularExpression *nf = [NSRegularExpression regularExpressionWithPattern:@"(以上是打招呼的内容|通过了你的朋友验证|你已添加了|现在我们可以开始聊天了|请求添加你为朋友|前往验证|添加到通讯录|对方账号存在异常|谨防诈骗)" options:0 error:nil];
        if ([nf firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) {
            if (reason) *reason = @"拦截新加好友/陌生人打招呼验证（哪怕同名也严禁回复）";
            return YES;
        }
    }
    if (chkMkt) {
        NSRegularExpression *mk = [NSRegularExpression regularExpressionWithPattern:@"(砍一刀|帮我助力|淘口令|京东口令|回\\s*[TDNR]\\s*退订|限时秒杀|兼职刷单|验证码|取件码|消费提醒)" options:NSRegularExpressionCaseInsensitive error:nil];
        if ([mk firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) {
            if (reason) *reason = @"拦截营销推广/砍一刀/验证码通知";
            return YES;
        }
    }
    return NO;
}

- (BOOL)isPhoneControlAttempt:(NSString *)text {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(?:#控机|@米塔|米塔[,，：:\\s]+|控机[,，：:\\s]+)|(?:打开|启动|切换到|切去)\\s*(?:抖音|小红书|淘宝|支付宝|美团|浏览器|safari|设置|相册|QQ)|(?:返回|回到)\\s*(?:主屏幕|桌面)" options:NSRegularExpressionCaseInsensitive error:nil];
    return [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

#pragma mark - Evaluation & Group Admin Commands

- (NSDictionary *)evaluateIncomingForContact:(NSString *)contact
                                     isGroup:(BOOL)isGroup
                                 groupSender:(NSString *)groupSender
                                     rawText:(NSString *)rawText {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSString *title = [contact ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *text = [rawText ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0 || text.length == 0) {
        return @{@"allowed": @(NO), @"reason": @"空会话或空消息"};
    }

    NSString *spamReason = nil;
    if ([self isNewFriendOrMarketing:text checkNewFriend:store.blockNewFriends checkMarketing:store.blockMarketing outReason:&spamReason]) {
        return @{@"allowed": @(NO), @"is_group": @(isGroup), @"is_admin": @(NO), @"reason": spamReason};
    }

    if (isGroup) {
        NSString *sender = nil;
        NSString *body = nil;
        BOOL atMe = NO;
        [self splitGroupText:text defaultSender:groupSender outSender:&sender outBody:&body outAtMe:&atMe];
        NSString *stripped = [self stripMentionPrefix:body];
        NSDictionary *roleInfo = [self resolveGroupRoleForSender:sender body:stripped];
        BOOL isOwner = [roleInfo[@"is_owner"] boolValue];
        BOOL isAdmin = [roleInfo[@"is_admin"] boolValue];
        BOOL pinOk = [roleInfo[@"pin_ok"] boolValue];
        NSString *role = roleInfo[@"role"] ?: @"member";
        NSString *gKey = [MitaConfigStore normalizeName:title];

        // 检查本群是否处于闭麦期
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        [self.guardLock lock];
        NSTimeInterval mutedUntil = [self.groupMutedUntil[gKey] doubleValue];
        [self.guardLock unlock];
        if (mutedUntil > now) {
            BOOL isUnmute = [@[@"开麦", @"出来聊", @"出来吧", @"恢复说话", @"开启本群"] containsObject:roleInfo[@"clean_body"]];
            if (!(isAdmin && pinOk && isUnmute)) {
                return @{@"allowed": @(NO), @"is_group": @(YES), @"is_admin": @(isAdmin), @"group_sender": sender, @"group_role": role,
                         @"reason": @"本群当前处于闭麦期，安静潜水中（管理员发「开麦」可随时唤醒）"};
            }
        }

        // 检查群白名单（管理员在群内发「开启本群」可直接破冰开启）
        BOOL inGroupWl = [self list:store.allowedGroups containsNormalized:title];
        if (!inGroupWl) {
            if (isAdmin && pinOk && [@[@"开启本群", @"激活本群", @"本群加白"] containsObject:roleInfo[@"clean_body"]]) {
                return @{@"allowed": @(YES), @"is_group": @(YES), @"is_owner": @(isOwner), @"is_admin": @(YES),
                         @"group_sender": sender, @"group_role": role, @"clean_body": roleInfo[@"clean_body"],
                         @"reason": [NSString stringWithFormat:@"识别到管理员「%@」开启本群指令，立即放行", sender]};
            }
            return @{@"allowed": @(NO), @"is_group": @(YES), @"is_admin": @(isAdmin), @"group_sender": sender, @"group_role": role,
                     @"reason": [NSString stringWithFormat:@"群聊「%@」未在允许群列表中（可在 App 添加或由管理员群内发「@豆奶 开启本群」）", title]};
        }

        // 群成员权限校验
        if ([role isEqualToString:@"muted"]) {
            return @{@"allowed": @(NO), @"is_group": @(YES), @"is_admin": @(NO), @"group_sender": sender, @"group_role": role,
                     @"reason": [NSString stringWithFormat:@"群友「%@」已被管理员设为屏蔽不理", sender]};
        }
        NSString *permMode = store.groupPermMode;
        if ([permMode isEqualToString:@"admin_only"] && !isAdmin) {
            return @{@"allowed": @(NO), @"is_group": @(YES), @"is_admin": @(NO), @"group_sender": sender, @"group_role": role,
                     @"reason": @"本群当前设为仅管理员可聊"};
        }
        if ([permMode isEqualToString:@"authorized_only"] && !(isAdmin || [role isEqualToString:@"authorized"])) {
            return @{@"allowed": @(NO), @"is_group": @(YES), @"is_admin": @(NO), @"group_sender": sender, @"group_role": role,
                     @"reason": [NSString stringWithFormat:@"本群当前仅限授权群友互动，「%@」尚未授权", sender.length ? sender : @"该群友"]};
        }

        // 判断是否 @机器人 或呼唤名字
        NSArray<NSString *> *kws = [MitaConfigStore splitCsvList:store.groupKeywords];
        NSString *bodyLow = [body lowercaseString];
        BOOL hasWake = atMe;
        for (NSString *kw in kws) {
            NSString *kl = [[kw stringByReplacingOccurrencesOfString:@"@" withString:@""] lowercaseString];
            if (kl.length > 0 && [bodyLow containsString:kl]) { hasWake = YES; break; }
        }
        if ([bodyLow containsString:@"@豆奶"] || [bodyLow containsString:@"@米塔"]) hasWake = YES;

        // 判断是否在专门 @其他群友（有眼力见不乱插嘴）
        NSRegularExpression *atRe = [NSRegularExpression regularExpressionWithPattern:@"[@＠]([^\\u2005\\s,，:：@＠]{1,20})" options:0 error:nil];
        NSArray<NSTextCheckingResult *> *ats = [atRe matchesInString:body options:0 range:NSMakeRange(0, body.length)];
        BOOL talkingToOthers = (ats.count > 0 && !hasWake);

        // 拟人自然跟聊轮数窗口计算
        NSInteger minT = store.groupBurstMin;
        NSInteger maxT = store.groupBurstMax;
        NSString *vibe = store.groupVibeMode;
        if ([vibe isEqualToString:@"at_only"]) { minT = 1; maxT = 1; }
        else if ([vibe isEqualToString:@"light"]) { minT = 2; maxT = 3; }
        else if ([vibe isEqualToString:@"lively"]) { minT = 4; maxT = 5; }

        [self.guardLock lock];
        NSMutableDictionary *win = self.groupWindows[gKey];
        NSTimeInterval started = [win[@"started_at"] doubleValue];
        NSTimeInterval lastAt = [win[@"last_at"] doubleValue];
        NSInteger curCnt = [win[@"count"] integerValue];
        NSInteger targetT = [win[@"target"] integerValue];
        BOOL winAlive = (started > 0 && (now - started) <= 180.0 && (now - lastAt) <= 90.0 && curCnt < targetT);

        NSString *why = @"";
        BOOL allowed = NO;
        NSInteger outCur = 0;
        NSInteger outTarget = targetT;

        if (hasWake) {
            NSInteger span = MAX(1, maxT - minT + 1);
            outTarget = minT + (NSInteger)(arc4random_uniform((uint32_t)span));
            outCur = 1;
            self.groupWindows[gKey] = [@{@"started_at": @(now), @"last_at": @(now), @"count": @(1), @"target": @(outTarget)} mutableCopy];
            allowed = YES;
            why = [NSString stringWithFormat:@"被@或呼唤唤醒，开启自然跟聊（本波预计互动 %ld 轮）", (long)outTarget];
        } else if (talkingToOthers) {
            allowed = NO;
            why = @"群友正在 @其他人 交流，模拟真人分寸感不抢话";
        } else if (winAlive) {
            outCur = curCnt + 1;
            win[@"last_at"] = @(now);
            win[@"count"] = @(outCur);
            allowed = YES;
            why = [NSString stringWithFormat:@"被@后顺势自然跟聊（第 %ld/%ld 轮）", (long)outCur, (long)outTarget];
        } else {
            allowed = NO;
            why = (started > 0 && curCnt >= targetT)
                ? [NSString stringWithFormat:@"刚已顺着话题自然聊完 %ld 轮，收住潜水不刷屏", (long)targetT]
                : @"平时安静潜水不乱插嘴（被 @ 或喊名字随时开聊）";
        }
        [self.guardLock unlock];

        return @{
            @"allowed": @(allowed),
            @"is_group": @(YES),
            @"is_owner": @(isOwner),
            @"is_admin": @(isAdmin),
            @"group_sender": sender,
            @"group_role": role,
            @"clean_body": body,
            @"current_turn": @(outCur),
            @"target_turns": @(outTarget),
            @"reason": why
        };
    }

    // 私聊校验
    BOOL isAdmin = [self list:store.adminContacts containsNormalized:title];
    BOOL inWl = isAdmin || [self list:store.allowedContacts containsNormalized:title];
    if (store.whitelistOnly && !inWl) {
        return @{@"allowed": @(NO), @"is_group": @(NO), @"is_admin": @(NO), @"clean_body": text,
                 @"reason": [NSString stringWithFormat:@"私聊联系人「%@」不在白名单中，严禁回复", title]};
    }
    return @{@"allowed": @(YES), @"is_group": @(NO), @"is_owner": @(isAdmin), @"is_admin": @(isAdmin),
             @"group_sender": title, @"group_role": isAdmin ? @"owner" : @"member", @"clean_body": text,
             @"reason": isAdmin ? @"命中唯一管理员权限核验通过" : @"命中私聊白名单（仅限纯聊天）"};
}

- (NSDictionary *)tryExecuteAdminCommandForContact:(NSString *)contact
                                           isGroup:(BOOL)isGroup
                                       groupSender:(NSString *)groupSender
                                           rawText:(NSString *)rawText {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSString *sender = groupSender ?: @"";
    NSString *body = rawText ?: @"";
    if (isGroup) {
        [self splitGroupText:rawText defaultSender:groupSender outSender:&sender outBody:&body outAtMe:nil];
    }
    NSString *cmd = [self stripMentionPrefix:body];
    NSDictionary *roleInfo = isGroup
        ? [self resolveGroupRoleForSender:sender body:cmd]
        : @{@"role": (([self list:store.adminContacts containsNormalized:contact] || [self list:store.adminWxids containsNormalized:contact]) ? @"owner" : @"member"),
            @"is_owner": @([self list:store.adminContacts containsNormalized:contact] || [self list:store.adminWxids containsNormalized:contact]),
            @"is_admin": @([self list:store.adminContacts containsNormalized:contact] || [self list:store.adminWxids containsNormalized:contact]),
            @"pin_ok": @(YES),
            @"clean_body": cmd};

    BOOL isOwner = [roleInfo[@"is_owner"] boolValue] && [roleInfo[@"pin_ok"] boolValue];
    BOOL isAdmin = [roleInfo[@"is_admin"] boolValue] && [roleInfo[@"pin_ok"] boolValue];
    NSString *raw = [roleInfo[@"clean_body"] ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return @{@"matched": @(NO)};

    // 检测是否是群管理/调权限指令
    NSRegularExpression *cmdCheck = [NSRegularExpression regularExpressionWithPattern:
        @"^(?:开启本群|激活本群|本群加白|关闭本群|停用本群|闭麦|安静|开麦|出来聊|恢复说话|"
        @"(?:给|授予|开放|加).*权限|(?:允许|授权)\\s*@?\\S+|(?:取消|收回|撤|移除).*权限|"
        @"(?:屏蔽|拉黑|不理|别理)\\s*@?\\S+|(?:解除屏蔽|取消屏蔽|恢复|理一下)\\s*@?\\S+|"
        @"(?:设|加|给)(?:副管|管理|协管)\\s*@?\\S+|(?:撤|取消|移除)(?:副管|管理|协管)\\s*@?\\S+|"
        @"全群可聊|全员可聊|开放群聊|仅授权可聊|仅管理(?:员)?可聊|只理管理员|"
        @"活跃点|多聊几句|热闹点|低调点|少聊两句|自然模式|正常聊|仅艾特回|潜水模式|"
        @"本群权限|群权限|本群状态|查看群权限|查看权限|(?:换|切换)?人设)" options:0 error:nil];

    if (![cmdCheck firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)]) {
        return @{@"matched": @(NO)};
    }

    if (!isAdmin) {
        return @{@"matched": @(YES), @"modified": @(NO), @"action": @"auth_rejected",
                 @"reply": @"哈哈调权限得我们群管理发话才算数哈～"};
    }

    NSString *reply = nil;
    NSString *action = @"group_admin_cmd";
    BOOL modified = NO;
    NSString *gKey = [MitaConfigStore normalizeName:contact];

    if ([@[@"开启本群", @"激活本群", @"本群加白"] containsObject:raw]) {
        NSMutableArray *grps = [store.allowedGroups mutableCopy];
        if (![self list:grps containsNormalized:contact]) [grps addObject:contact];
        store.allowedGroups = grps;
        [self.guardLock lock]; [self.groupMutedUntil removeObjectForKey:gKey]; [self.guardLock unlock];
        reply = [NSString stringWithFormat:@"收到老大，本群「%@」已开启聊天权限，随时 @我 开聊～", contact];
        action = @"enable_current_group";
        modified = YES;
    } else if ([@[@"关闭本群", @"停用本群"] containsObject:raw]) {
        NSMutableArray *grps = [NSMutableArray array];
        for (NSString *g in store.allowedGroups) {
            if (![[MitaConfigStore normalizeName:g] isEqualToString:gKey]) [grps addObject:g];
        }
        store.allowedGroups = grps;
        reply = [NSString stringWithFormat:@"好嘞，已关闭本群「%@」的自动聊天，需要再叫我开启就行", contact];
        action = @"disable_current_group";
        modified = YES;
    } else if ([raw hasPrefix:@"闭麦"] || [raw hasPrefix:@"安静"]) {
        NSInteger mins = 30;
        NSRegularExpression *numRe = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)" options:0 error:nil];
        NSTextCheckingResult *nm = [numRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (nm) mins = MAX(1, [[raw substringWithRange:[nm rangeAtIndex:1]] integerValue]);
        [self.guardLock lock];
        self.groupMutedUntil[gKey] = @([[NSDate date] timeIntervalSince1970] + mins * 60.0);
        [self.groupWindows removeObjectForKey:gKey];
        [self.guardLock unlock];
        reply = [NSString stringWithFormat:@"好嘞，我先在群里安静潜水 %ld 分钟，有事随时喊我「开麦」", (long)mins];
        action = @"mute_group";
    } else if ([@[@"开麦", @"出来聊", @"恢复说话"] containsObject:raw]) {
        [self.guardLock lock]; [self.groupMutedUntil removeObjectForKey:gKey]; [self.guardLock unlock];
        reply = @"来啦来啦，随时开聊～";
        action = @"unmute_group";
    } else if ([@[@"全群可聊", @"全员可聊", @"开放群聊"] containsObject:raw]) {
        store.groupPermMode = @"all";
        reply = @"已切为【全群可聊】模式：除屏蔽名单外，大家 @我 都能一起聊";
        modified = YES;
    } else if ([@[@"仅授权可聊"] containsObject:raw]) {
        store.groupPermMode = @"authorized_only";
        reply = @"已切为【仅授权群友可聊】：只有管理员与已授权群友 @我 才会回应";
        modified = YES;
    } else if ([@[@"仅管理员可聊", @"仅管理可聊", @"只理管理员"] containsObject:raw]) {
        store.groupPermMode = @"admin_only";
        reply = @"已切为【仅管理员可聊】：群里目前只回应管理员发话";
        modified = YES;
    } else if ([@[@"活跃点", @"多聊几句", @"热闹点"] containsObject:raw]) {
        store.groupVibeMode = @"lively"; store.groupBurstMin = 4; store.groupBurstMax = 5;
        reply = @"好嘞！已切到热聊气氛组节奏，被 @ 聊开后会顺着大家多聊四五轮～";
        modified = YES;
    } else if ([@[@"低调点", @"少聊两句"] containsObject:raw]) {
        store.groupVibeMode = @"light"; store.groupBurstMin = 2; store.groupBurstMax = 3;
        reply = @"明白，已切到轻度搭话节奏，被 @ 后聊两三句就安静听大家聊";
        modified = YES;
    } else if ([@[@"自然模式", @"正常聊"] containsObject:raw]) {
        store.groupVibeMode = @"natural"; store.groupBurstMin = 2; store.groupBurstMax = 5;
        reply = @"已恢复默认拟人节奏：平时不刷屏，被 @ 后像真人一样自然跟聊几句";
        modified = YES;
    } else if ([@[@"仅艾特回", @"潜水模式"] containsObject:raw]) {
        store.groupVibeMode = @"at_only"; store.groupBurstMin = 1; store.groupBurstMax = 1;
        reply = @"好嘞，已切到深度潜水模式，只有明确 @我 那一下才回";
        modified = YES;
    } else if ([@[@"本群权限", @"群权限", @"本群状态", @"查看群权限", @"查看权限"] containsObject:raw]) {
        NSDictionary *pMap = @{@"all": @"全群可聊(屏蔽除外)", @"authorized_only": @"仅授权群友可聊", @"admin_only": @"仅管理员可聊"};
        NSDictionary *vMap = @{@"natural": @"拟人自然(2~5轮)", @"light": @"轻度搭话(2~3轮)", @"lively": @"活跃热聊(4~5轮)", @"at_only": @"潜水仅@回"};
        NSString *subs = store.groupSubAdmins.count ? [store.groupSubAdmins componentsJoinedByString:@"、"] : @"无";
        NSString *auths = store.groupAuthorizedMembers.count ? [store.groupAuthorizedMembers componentsJoinedByString:@"、"] : @"无";
        NSString *mutes = store.groupMutedMembers.count ? [store.groupMutedMembers componentsJoinedByString:@"、"] : @"无";
        reply = [NSString stringWithFormat:@"【本群权限状态】\n· 管理员：%@ | 协管：%@\n· 互动范围：%@ | 节奏：%@\n· 已授权群友：%@ | 已屏蔽：%@",
                 [store.adminContacts componentsJoinedByString:@"、"], subs,
                 pMap[store.groupPermMode] ?: @"全群可聊", vMap[store.groupVibeMode] ?: @"拟人自然", auths, mutes];
        action = @"show_group_permissions";
    } else {
        // 成员增删与人设切换解析
        NSRegularExpression *grantRe = [NSRegularExpression regularExpressionWithPattern:@"^(?:(?:给|授予|开放|加)\\s*(.+?)\\s*权限|(?:给|授予|开放|加)权限[：:\\s]*(.+)|(?:允许|授权)[：:\\s]*(.+))$" options:0 error:nil];
        NSRegularExpression *revokeRe = [NSRegularExpression regularExpressionWithPattern:@"^(?:(?:取消|收回|撤|移除)\\s*(.+?)\\s*权限|(?:取消|收回|撤|移除)权限[：:\\s]*(.+))$" options:0 error:nil];
        NSRegularExpression *muteRe = [NSRegularExpression regularExpressionWithPattern:@"^(?:屏蔽|拉黑|不理|别理)[：:\\s]*(.+)$" options:0 error:nil];
        NSRegularExpression *unmuteRe = [NSRegularExpression regularExpressionWithPattern:@"^(?:解除屏蔽|取消屏蔽|恢复|理一下)[：:\\s]*(.+)$" options:0 error:nil];
        NSRegularExpression *addSubRe = [NSRegularExpression regularExpressionWithPattern:@"^(?:设|加|给)(?:副管|管理|协管)[：:\\s]*(.+)$" options:0 error:nil];
        NSRegularExpression *delSubRe = [NSRegularExpression regularExpressionWithPattern:@"^(?:撤|取消|移除)(?:副管|管理|协管)[：:\\s]*(.+)$" options:0 error:nil];
        NSRegularExpression *persRe = [NSRegularExpression regularExpressionWithPattern:@"^(?:换|切换)?人设[：:\\s]*(.+)$" options:0 error:nil];

        NSTextCheckingResult *m = nil;
        if ((m = [grantRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)])) {
            NSString *t = nil;
            for (NSUInteger i = 1; i < m.numberOfRanges; i++) {
                NSRange r = [m rangeAtIndex:i];
                if (r.location != NSNotFound) { t = [self cleanMemberArg:[raw substringWithRange:r]]; break; }
            }
            if (t.length > 0) {
                NSMutableArray *auth = [store.groupAuthorizedMembers mutableCopy];
                if (![self list:auth containsNormalized:t]) [auth addObject:t];
                store.groupAuthorizedMembers = auth;
                NSMutableArray *mut = [NSMutableArray array];
                for (NSString *x in store.groupMutedMembers) if (![[MitaConfigStore normalizeName:x] isEqualToString:[MitaConfigStore normalizeName:t]]) [mut addObject:x];
                store.groupMutedMembers = mut;
                reply = [NSString stringWithFormat:@"已给「%@」开通群聊互动权限啦，欢迎随时 @我 聊天", t];
                modified = YES;
            }
        } else if ((m = [revokeRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)])) {
            NSString *t = nil;
            for (NSUInteger i = 1; i < m.numberOfRanges; i++) {
                NSRange r = [m rangeAtIndex:i];
                if (r.location != NSNotFound) { t = [self cleanMemberArg:[raw substringWithRange:r]]; break; }
            }
            if (t.length > 0) {
                NSMutableArray *auth = [NSMutableArray array];
                for (NSString *x in store.groupAuthorizedMembers) if (![[MitaConfigStore normalizeName:x] isEqualToString:[MitaConfigStore normalizeName:t]]) [auth addObject:x];
                store.groupAuthorizedMembers = auth;
                reply = [NSString stringWithFormat:@"好嘞，已收回「%@」的群聊单独授权", t];
                modified = YES;
            }
        } else if ((m = [muteRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)])) {
            NSString *t = [self cleanMemberArg:[raw substringWithRange:[m rangeAtIndex:1]]];
            if (t.length > 0) {
                if ([self list:store.adminContacts containsNormalized:t]) {
                    reply = @"哈哈不能屏蔽最高管理员本尊哈～";
                } else {
                    NSMutableArray *mut = [store.groupMutedMembers mutableCopy];
                    if (![self list:mut containsNormalized:t]) [mut addObject:t];
                    store.groupMutedMembers = mut;
                    reply = [NSString stringWithFormat:@"收到，已把「%@」加入本群免打扰屏蔽，后面TA @我 就不搭理了", t];
                    modified = YES;
                }
            }
        } else if ((m = [unmuteRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)])) {
            NSString *t = [self cleanMemberArg:[raw substringWithRange:[m rangeAtIndex:1]]];
            if (t.length > 0) {
                NSMutableArray *mut = [NSMutableArray array];
                for (NSString *x in store.groupMutedMembers) if (![[MitaConfigStore normalizeName:x] isEqualToString:[MitaConfigStore normalizeName:t]]) [mut addObject:x];
                store.groupMutedMembers = mut;
                reply = [NSString stringWithFormat:@"好嘞，已解除对「%@」的屏蔽，恢复正常互动", t];
                modified = YES;
            }
        } else if ((m = [addSubRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)])) {
            if (!isOwner) {
                reply = @"只有最高管理员才能任命副管理员哈～";
            } else {
                NSString *t = [self cleanMemberArg:[raw substringWithRange:[m rangeAtIndex:1]]];
                NSMutableArray *subs = [store.groupSubAdmins mutableCopy];
                if (t.length > 0 && ![self list:subs containsNormalized:t]) [subs addObject:t];
                store.groupSubAdmins = subs;
                reply = [NSString stringWithFormat:@"已任命「%@」为群协管员，可帮忙管理群聊天权限与开关麦", t];
                modified = YES;
            }
        } else if ((m = [delSubRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)])) {
            if (!isOwner) {
                reply = @"只有最高管理员才能撤销副管理员哈～";
            } else {
                NSString *t = [self cleanMemberArg:[raw substringWithRange:[m rangeAtIndex:1]]];
                NSMutableArray *subs = [NSMutableArray array];
                for (NSString *x in store.groupSubAdmins) if (![[MitaConfigStore normalizeName:x] isEqualToString:[MitaConfigStore normalizeName:t]]) [subs addObject:x];
                store.groupSubAdmins = subs;
                reply = [NSString stringWithFormat:@"已取消「%@」的群协管员权限", t];
                modified = YES;
            }
        } else if ((m = [persRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)])) {
            NSString *target = [self cleanMemberArg:[raw substringWithRange:[m rangeAtIndex:1]]];
            for (NSDictionary *p in [store personaPresets]) {
                if ([p[@"name"] isEqualToString:target] || [p[@"id"] isEqualToString:[target lowercaseString]]) {
                    store.personaId = p[@"id"];
                    store.customPrompt = p[@"prompt"];
                    reply = [NSString stringWithFormat:@"收到，人设已切换为「%@」（%@）啦～", p[@"name"], p[@"badge"]];
                    modified = YES;
                    break;
                }
            }
            if (!reply) reply = @"未找到该预设人设，可选：晚风、豆奶、陆离、姜姜、阿泽、沈言";
        }
    }

    if (!reply) return @{@"matched": @(NO)};
    if (modified) [self pushConfigToPcQuietly];
    [store addEventLogKind:@"replied" contact:contact incoming:rawText detail:[NSString stringWithFormat:@"[群管调权限] %@", reply] costMs:2];
    return @{@"matched": @(YES), @"modified": @(modified), @"action": action, @"reply": reply};
}

#pragma mark - OpenAI-Compatible Fast API Client

- (void)chatCompletionWithMessages:(NSArray<NSDictionary *> *)messages
                          jsonMode:(BOOL)jsonMode
                        completion:(void (^)(BOOL ok, NSString *content, NSString *model, NSInteger costMs, NSString *error))completion {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSString *base = store.apiBaseUrl;
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSString *apiKey = [store effectiveApiKey];
    NSString *model = store.apiModel.length ? store.apiModel : @"gemini-3.5-flash-lite";
    if (base.length == 0 || apiKey.length == 0) {
        completion(NO, @"", model, 0, @"请先在「API 与双控」页填写 API 地址与密钥");
        return;
    }

    BOOL isGrok = [[model lowercaseString] containsString:@"grok"];
    NSArray<NSDictionary *> *sendMsgs = messages;
    if (isGrok) {
        NSMutableString *sysBuf = [NSMutableString string];
        NSMutableArray *rest = [NSMutableArray array];
        for (NSDictionary *item in messages) {
            if ([item[@"role"] isEqualToString:@"system"]) {
                if (sysBuf.length > 0) [sysBuf appendString:@"\n\n"];
                [sysBuf appendString:(item[@"content"] ?: @"")];
            } else {
                [rest addObject:[item mutableCopy]];
            }
        }
        if (sysBuf.length > 0) {
            NSString *prefix = [NSString stringWithFormat:@"【请直接遵守以下设定并快速给出自然回复】\n%@\n\n---\n", sysBuf];
            if (rest.count > 0 && [rest[0][@"role"] isEqualToString:@"user"]) {
                rest[0][@"content"] = [prefix stringByAppendingString:(rest[0][@"content"] ?: @"")];
            } else {
                [rest insertObject:[@{@"role": @"user", @"content": prefix} mutableCopy] atIndex:0];
            }
            sendMsgs = rest;
        }
    }

    NSMutableDictionary *payload = [@{
        @"model": model,
        @"messages": sendMsgs,
        @"stream": @(NO),
        @"max_tokens": @(jsonMode ? 480 : 320)
    } mutableCopy];
    if (isGrok) payload[@"reasoning_effort"] = @"minimal";
    if (jsonMode) payload[@"response_format"] = @{@"type": @"json_object"};

    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];
    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger costMs = (NSInteger)llround(([[NSDate date] timeIntervalSince1970] - t0) * 1000.0);
        if (err || !data) {
            completion(NO, @"", model, costMs, err.localizedDescription ?: @"网络连接失败");
            return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
        NSInteger code = httpResp.statusCode;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (code < 200 || code >= 300 || ![obj isKindOfClass:[NSDictionary class]]) {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            if (raw.length > 140) raw = [[raw substringToIndex:140] stringByAppendingString:@"..."];
            completion(NO, @"", model, costMs, [NSString stringWithFormat:@"HTTP %ld: %@", (long)code, raw]);
            return;
        }
        NSArray *choices = obj[@"choices"];
        NSString *txt = (choices.count > 0) ? (choices[0][@"message"][@"content"] ?: @"") : @"";
        txt = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (jsonMode && [txt hasPrefix:@"```"]) {
            NSRegularExpression *fence1 = [NSRegularExpression regularExpressionWithPattern:@"^```(?:json)?\\s*" options:0 error:nil];
            NSRegularExpression *fence2 = [NSRegularExpression regularExpressionWithPattern:@"\\s*```$" options:0 error:nil];
            txt = [fence1 stringByReplacingMatchesInString:txt options:0 range:NSMakeRange(0, txt.length) withTemplate:@""];
            txt = [fence2 stringByReplacingMatchesInString:txt options:0 range:NSMakeRange(0, txt.length) withTemplate:@""];
        }
        NSString *usedModel = obj[@"model"] ?: model;
        if (txt.length == 0) {
            completion(NO, @"", usedModel, costMs, @"模型返回内容为空");
            return;
        }
        completion(YES, txt, usedModel, costMs, @"");
    }] resume];
}

- (void)generateWeChatReplyForContact:(NSString *)contact
                              isGroup:(BOOL)isGroup
                          groupSender:(NSString *)groupSender
                             incoming:(NSString *)incoming
                           completion:(void (^)(NSDictionary *result))completion {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSDictionary *guard = [self evaluateIncomingForContact:contact isGroup:isGroup groupSender:groupSender rawText:incoming];
    BOOL allowed = [guard[@"allowed"] boolValue];
    BOOL isAdmin = [guard[@"is_admin"] boolValue];
    NSString *effSender = guard[@"group_sender"] ?: groupSender ?: @"";
    NSString *effRole = guard[@"group_role"] ?: @"member";
    NSString *cleanBody = guard[@"clean_body"] ?: incoming;

    if (!allowed) {
        [store addEventLogKind:@"blocked" contact:contact incoming:incoming detail:(guard[@"reason"] ?: @"已拦截") costMs:1];
        completion(@{
            @"ok": @(YES),
            @"blocked": @(YES),
            @"guard_allowed": @(NO),
            @"is_admin": @(isAdmin),
            @"guard_reason": guard[@"reason"] ?: @"",
            @"reply": [NSString stringWithFormat:@"【未回复 · 原因】%@", guard[@"reason"] ?: @""],
            @"cost_ms": @(1)
        });
        return;
    }

    // 优先检查是否为群内管理员调权限/管群口令
    NSDictionary *cmdRes = [self tryExecuteAdminCommandForContact:contact isGroup:isGroup groupSender:effSender rawText:incoming];
    if ([cmdRes[@"matched"] boolValue]) {
        completion(@{
            @"ok": @(YES),
            @"blocked": @([cmdRes[@"action"] isEqualToString:@"auth_rejected"]),
            @"is_command": @(YES),
            @"is_admin": @(isAdmin),
            @"guard_reason": guard[@"reason"] ?: @"",
            @"reply": cmdRes[@"reply"] ?: @"",
            @"cost_ms": @(2)
        });
        return;
    }

    // 非管理员严禁跨应用控机
    if (!isAdmin && [self isPhoneControlAttempt:cleanBody]) {
        NSString *deny = @"哈哈我只在这陪大家聊天哈，手机里的其他软件只有管理员自己才能动～";
        [store addEventLogKind:@"blocked" contact:contact incoming:incoming detail:@"权限硬隔离：拦截非管理员跨软件控机" costMs:1];
        completion(@{@"ok": @(YES), @"blocked": @(YES), @"is_admin": @(NO), @"reply": deny, @"cost_ms": @(1)});
        return;
    }

    NSString *sysPrompt = [store effectivePromptForContact:contact isGroup:isGroup groupSender:effSender groupRole:effRole];
    NSMutableArray *msgs = [NSMutableArray array];
    [msgs addObject:@{@"role": @"system", @"content": sysPrompt}];
    [msgs addObjectsFromArray:[store memoryForContact:contact]];
    NSString *userLine = (isGroup && effSender.length > 0)
        ? [NSString stringWithFormat:@"%@: %@", effSender, cleanBody]
        : cleanBody;
    [msgs addObject:@{@"role": @"user", @"content": userLine}];

    [self chatCompletionWithMessages:msgs jsonMode:NO completion:^(BOOL ok, NSString *content, NSString *model, NSInteger costMs, NSString *error) {
        if (!ok) {
            completion(@{@"ok": @(NO), @"error": error, @"model": model, @"cost_ms": @(costMs)});
            return;
        }
        NSRegularExpression *keyRed = [NSRegularExpression regularExpressionWithPattern:@"\\bsk-[A-Za-z0-9_-]{14,}\\b" options:0 error:nil];
        NSString *clean = [keyRed stringByReplacingMatchesInString:content options:0 range:NSMakeRange(0, content.length) withTemplate:@"[密钥已隐藏]"];
        [self recordReplyUsage];
        [store appendMemoryForContact:contact userMsg:userLine botReply:clean];
        [store addEventLogKind:@"replied" contact:contact incoming:userLine detail:clean costMs:costMs];
        completion(@{
            @"ok": @(YES),
            @"blocked": @(NO),
            @"is_admin": @(isAdmin),
            @"group_role": effRole,
            @"guard_reason": guard[@"reason"] ?: @"",
            @"reply": clean,
            @"model": model,
            @"cost_ms": @(costMs)
        });
    }];
}

- (void)planPhoneControlOrChat:(NSString *)userText completion:(void (^)(NSDictionary *result))completion {
    NSString *sysPrompt =
        @"你是运行在用户巨魔版 iPhone 内的「米塔 手机智能体」。请根据用户输入直接输出一个合法 JSON 对象，不写多余说明：\n"
        @"{\"reply\": \"自然简短的中文答复\", \"actions\": [ ... ]}\n"
        @"规则：\n"
        @"1. 若用户只是日常聊天提问（不需要操作手机），actions 返回空数组 []。\n"
        @"2. 若用户要求操控苹果手机（如打开微信、Safari、抖音、小红书、设置、滑屏、回主屏幕等），规划简洁动作放进 actions 数组（最多 5 步）：\n"
        @"   - {\"type\":\"launch_app\", \"app\":\"微信|设置|浏览器|抖音|小红书|淘宝|支付宝|QQ|巨魔\"}\n"
        @"   - {\"type\":\"open_url\", \"url\":\"https://...\"}\n"
        @"   - {\"type\":\"tap\", \"x\":0.5, \"y\":0.5}\n"
        @"   - {\"type\":\"swipe\", \"dir\":\"up|down|left|right\"}\n"
        @"   - {\"type\":\"home\"}\n"
        @"   - {\"type\":\"input_text\", \"text\":\"要写入剪贴板的文字\"}\n"
        @"   - {\"type\":\"wait\", \"ms\":500}";

    NSArray *msgs = @[
        @{@"role": @"system", @"content": sysPrompt},
        @{@"role": @"user", @"content": userText ?: @""}
    ];
    [self chatCompletionWithMessages:msgs jsonMode:YES completion:^(BOOL ok, NSString *content, NSString *model, NSInteger costMs, NSString *error) {
        if (!ok) {
            completion(@{@"ok": @(NO), @"error": error, @"model": model, @"cost_ms": @(costMs)});
            return;
        }
        NSString *reply = content;
        NSArray *actions = @[];
        NSData *jdata = [content dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = jdata ? [NSJSONSerialization JSONObjectWithData:jdata options:0 error:nil] : nil;
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            if ([parsed[@"reply"] isKindOfClass:[NSString class]]) reply = parsed[@"reply"];
            if ([parsed[@"actions"] isKindOfClass:[NSArray class]]) actions = parsed[@"actions"];
        }
        NSArray *steps = @[];
        if (actions.count > 0) {
            [[MitaFloatingHudManager shared] triggerControlPulseSeconds:8.0 phase:@"controlling"];
            steps = [[MitaKeepAliveAndControl shared] executeActionBatch:actions];
        }
        [[MitaConfigStore shared] addEventLogKind:@"agent" contact:@"苹果对话控机" incoming:userText detail:reply costMs:costMs];
        completion(@{
            @"ok": @(YES),
            @"reply": reply,
            @"model": model,
            @"cost_ms": @(costMs),
            @"steps": steps
        });
    }];
}

- (void)fetchModelsWithBaseUrl:(NSString *)baseUrl apiKey:(NSString *)apiKey completion:(void (^)(NSDictionary *result))completion {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSString *base = [(baseUrl.length > 0 ? baseUrl : store.apiBaseUrl) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    if (base.length == 0) {
        completion(@{@"ok": @(NO), @"error": @"请先填写 API 接口地址"});
        return;
    }

    // 整理需要请求的 Key 列表：若用户手动填了新 Key 则仅用该 Key；否则同时尝试主 Key 与备用 Gemini Key 合并该中转站全部可用模型
    NSMutableArray<NSString *> *keysToTry = [NSMutableArray array];
    NSString *manualKey = [apiKey ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (manualKey.length > 0 && ![manualKey containsString:@"****"]) {
        [keysToTry addObject:manualKey];
    } else {
        if (store.apiKey.length > 0) [keysToTry addObject:store.apiKey];
        if (store.geminiApiKey.length > 0 && ![keysToTry containsObject:store.geminiApiKey]) [keysToTry addObject:store.geminiApiKey];
        if (keysToTry.count == 0) [keysToTry addObject:@""];
    }

    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/models"]];
    if (!url) {
        completion(@{@"ok": @(NO), @"error": @"API 地址格式不正确"});
        return;
    }

    dispatch_group_t grp = dispatch_group_create();
    NSMutableOrderedSet<NSString *> *merged = [NSMutableOrderedSet orderedSet];
    __block NSString *lastErr = @"";
    __block BOOL anySuccess = NO;
    NSLock *mergeLock = [[NSLock alloc] init];

    for (NSString *k in keysToTry) {
        dispatch_group_enter(grp);
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"GET";
        req.timeoutInterval = 12.0;
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
        if (k.length > 0) {
            [req setValue:[NSString stringWithFormat:@"Bearer %@", k] forHTTPHeaderField:@"Authorization"];
        }
        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
            NSInteger code = httpResp ? httpResp.statusCode : 0;
            [mergeLock lock];
            if (err || !data) {
                lastErr = err.localizedDescription ?: @"无法连接上游接口";
            } else if (code < 200 || code >= 300) {
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                if (raw.length > 90) raw = [[raw substringToIndex:90] stringByAppendingString:@"..."];
                lastErr = [NSString stringWithFormat:@"HTTP %ld %@", (long)code, raw];
            } else {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *rows = nil;
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    if ([obj[@"data"] isKindOfClass:[NSArray class]]) rows = obj[@"data"];
                    else if ([obj[@"models"] isKindOfClass:[NSArray class]]) rows = obj[@"models"];
                } else if ([obj isKindOfClass:[NSArray class]]) {
                    rows = (NSArray *)obj;
                }
                if (rows) {
                    anySuccess = YES;
                    for (id row in rows) {
                        NSString *mid = nil;
                        if ([row isKindOfClass:[NSDictionary class]]) {
                            mid = [row[@"id"] isKindOfClass:[NSString class]] ? row[@"id"] : ([row[@"name"] isKindOfClass:[NSString class]] ? row[@"name"] : nil);
                        } else if ([row isKindOfClass:[NSString class]]) {
                            mid = (NSString *)row;
                        }
                        mid = [mid ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        NSString *low = [mid lowercaseString];
                        if (mid.length > 0 && ![low containsString:@"embedding"] && ![low containsString:@"whisper"] && ![low containsString:@"tts-"] && ![low containsString:@"dall-e"] && ![low containsString:@"flux"] && ![low containsString:@"moderation"]) {
                            [merged addObject:mid];
                        }
                    }
                } else {
                    lastErr = @"上游返回格式非标准 OpenAI 模型列表";
                }
            }
            [mergeLock unlock];
            dispatch_group_leave(grp);
        }] resume];
    }

    dispatch_group_notify(grp, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *list = [merged array];
        if (list.count > 0) {
            store.fetchedModels = list;
            completion(@{@"ok": @(YES), @"models": list, @"count": @(list.count)});
        } else if (anySuccess) {
            completion(@{@"ok": @(NO), @"error": @"上游接口连通但未返回可用对话模型"});
        } else {
            completion(@{@"ok": @(NO), @"error": lastErr.length ? lastErr : @"拉取模型列表失败"});
        }
    });
}

#pragma mark - Two-Way PC Sync

- (void)syncWithPcDirection:(NSString *)direction completion:(void (^)(NSDictionary *result))completion {
    MitaConfigStore *store = [MitaConfigStore shared];
    NSString *pc = store.pcSyncUrl;
    while ([pc hasSuffix:@"/"]) pc = [pc substringToIndex:pc.length - 1];
    if (pc.length == 0) {
        completion(@{@"ok": @(NO), @"error": @"请先填写电脑控制台地址"});
        return;
    }
    NSURL *url = [NSURL URLWithString:[pc stringByAppendingString:@"/api/phone_agent/config"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 5.0;

    if ([[direction lowercaseString] isEqualToString:@"pull"]) {
        req.HTTPMethod = @"GET";
        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err || !data) {
                completion(@{@"ok": @(NO), @"error": @"未连上电脑端（手机独立运行不受影响）"});
                return;
            }
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *cfg = [obj[@"config"] isKindOfClass:[NSDictionary class]] ? obj[@"config"] : obj;
                [store updateFromDictionary:cfg];
                completion(@{@"ok": @(YES), @"message": @"已从电脑端同步最新 API、人设、白名单与群聊权限配置"});
            } else {
                completion(@{@"ok": @(NO), @"error": @"电脑端返回格式异常"});
            }
        }] resume];
    } else {
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        NSMutableDictionary *payload = [[store toDictionaryRedactingKey:NO] mutableCopy];
        payload[@"platform"] = @"ios";
        payload[@"device_ip"] = [MitaKeepAliveAndControl deviceLanIPv4];
        payload[@"lan_port"] = @(19080);
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                completion(@{@"ok": @(NO), @"error": @"推送失败（电脑端未开启，手机本地已保存）"});
                return;
            }
            completion(@{@"ok": @(YES), @"message": @"已将苹果端最新微信/群聊权限配置推送同步到电脑"});
        }] resume];
    }
}

- (void)pushConfigToPcQuietly {
    NSString *pc = [MitaConfigStore shared].pcSyncUrl;
    if (pc.length < 8) return;
    [self syncWithPcDirection:@"push" completion:^(NSDictionary *result) {}];
}

#pragma mark - Auto-Reply Master Runtime & Standalone Vision Patrol Engine

- (void)bootstrapRuntimeIfNeeded {
    [self ensurePatrolTimerStarted];
    MitaConfigStore *store = [MitaConfigStore shared];
    if (store.botRunning) {
        [self setAutoReplyRunning:YES launchWeChat:NO triggerSource:@"bootstrap"];
    } else {
        [[MitaFloatingHudManager shared] updateWithRunning:NO
                                               startedAtTs:0
                                                     phase:@"idle"
                                                     model:store.apiModel
                                              repliedCount:self.totalRepliedCount
                                                statusLine:self.monitorStatusLine];
    }
}

- (void)ensurePatrolTimerStarted {
    if (self.patrolTimer) return;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    self.patrolTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(self.patrolTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                              (uint64_t)(2.4 * NSEC_PER_SEC),
                              (uint64_t)(0.3 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.patrolTimer, ^{
        [weakSelf patrolLoopTick];
    });
    dispatch_resume(self.patrolTimer);
}

- (void)updateRuntimePhase:(NSString *)phase
                engineMode:(NSString *)engineMode
               lastContact:(NSString *)contact
                statusLine:(NSString *)line
              repliedCount:(NSInteger)repCnt {
    [self.guardLock lock];
    if (phase.length > 0) self.monitorPhase = phase;
    if (engineMode.length > 0) self.monitorEngineMode = engineMode;
    if (contact != nil) self.monitorLastContact = contact;
    if (line.length > 0) self.monitorStatusLine = line;
    if (repCnt >= 0) self.totalRepliedCount = repCnt;
    BOOL running = self.isAutoReplyRunning;
    NSTimeInterval stTs = self.startedAtTs;
    NSString *pCopy = self.monitorPhase ?: @"idle";
    NSString *sCopy = self.monitorStatusLine ?: @"";
    NSInteger cCopy = self.totalRepliedCount;
    [self.guardLock unlock];

    NSString *model = [MitaConfigStore shared].apiModel ?: @"grok-4.7";
    [[MitaFloatingHudManager shared] updateWithRunning:running
                                           startedAtTs:stTs
                                                 phase:pCopy
                                                 model:model
                                          repliedCount:cCopy
                                            statusLine:sCopy];
}

- (NSDictionary *)runtimeStatusSnapshot {
    [self.guardLock lock];
    BOOL running = self.isAutoReplyRunning;
    NSTimeInterval upSec = (running && self.startedAtTs > 0) ? MAX(0, [[NSDate date] timeIntervalSince1970] - self.startedAtTs) : 0;
    NSDictionary *snap = @{
        @"running": @(running),
        @"started_at": @((NSInteger)llround(self.startedAtTs)),
        @"uptime_sec": @((NSInteger)llround(upSec)),
        @"phase": self.monitorPhase ?: @"idle",
        @"engine_mode": self.monitorEngineMode ?: (running ? @"正在连接引擎" : @"待命未启动"),
        @"last_contact": self.monitorLastContact ?: @"",
        @"last_message": self.monitorStatusLine ?: @"",
        @"replied_count": @(self.totalRepliedCount),
        @"model": [MitaConfigStore shared].apiModel ?: @"grok-4.7"
    };
    [self.guardLock unlock];
    return snap;
}

- (NSDictionary *)setAutoReplyRunning:(BOOL)running
                         launchWeChat:(BOOL)launchWx
                        triggerSource:(NSString *)source {
    [self ensurePatrolTimerStarted];
    MitaConfigStore *store = [MitaConfigStore shared];
    store.botRunning = running;
    if (running) {
        store.botEnabled = YES;
        [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    }

    [self.guardLock lock];
    self.isAutoReplyRunning = running;
    if (running && self.startedAtTs <= 0) {
        self.startedAtTs = [[NSDate date] timeIntervalSince1970];
    } else if (!running) {
        self.startedAtTs = 0;
    }
    [self.guardLock unlock];

    if (running) {
        [self updateRuntimePhase:@"patrolling"
                      engineMode:@"正在启动巡检"
                     lastContact:self.monitorLastContact ?: @""
                      statusLine:@"已启动！正在连接 API 并监听微信白名单未读消息…"
                    repliedCount:self.totalRepliedCount];
        if (store.floatingHudEnabled) {
            [[MitaFloatingHudManager shared] syncPlaybackState];
        }
    } else {
        [self updateRuntimePhase:@"idle"
                      engineMode:@"已停止"
                     lastContact:self.monitorLastContact ?: @""
                      statusLine:@"已停止自动回复，点击主按钮可随时重新启动"
                    repliedCount:self.totalRepliedCount];
    }

    // 同步通知电脑端开启或停止高速巡检守护（除非本次调用本身就是电脑端反向推过来的）
    if (![source isEqualToString:@"pc_remote"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self notifyPcToggleRunning:running];
            [self pushConfigToPcQuietly];
        });
    }

    if (running && launchWx) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (store.floatingHudEnabled) {
                [[MitaFloatingHudManager shared] startFloatingWindow];
            }
            [[MitaKeepAliveAndControl shared] launchAppByNameOrBundleId:@"com.tencent.xin"];
        });
    }

    return @{
        @"ok": @(YES),
        @"bot_running": @(running),
        @"runtime_monitor": [self runtimeStatusSnapshot],
        @"message": running ? @"微信自动回复已启动运行" : @"微信自动回复已停止"
    };
}

- (void)notifyPcToggleRunning:(BOOL)running {
    NSString *pc = [MitaConfigStore shared].pcSyncUrl;
    while ([pc hasSuffix:@"/"]) pc = [pc substringToIndex:pc.length - 1];
    if (pc.length < 8) return;
    NSURL *u = [NSURL URLWithString:[pc stringByAppendingString:@"/api/wechat/bot/toggle"]];
    if (!u) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 2.5;
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"running": @(running), @"from_phone": @(YES)};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
}

- (BOOL)syncFromPcActiveMonitorIfOnline {
    NSString *pc = [MitaConfigStore shared].pcSyncUrl;
    while ([pc hasSuffix:@"/"]) pc = [pc substringToIndex:pc.length - 1];
    if (pc.length < 8) return NO;
    NSURL *u = [NSURL URLWithString:[pc stringByAppendingString:@"/api/wechat/bot/state"]];
    if (!u) return NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 1.6;

    __block NSDictionary *respDict = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) respDict = (NSDictionary *)obj;
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)));

    if (!respDict || ![respDict[@"ok"] boolValue] || ![respDict[@"phone_connected"] boolValue]) {
        return NO;
    }

    BOOL pcRunning = [respDict[@"running"] boolValue];
    if (!pcRunning && self.isAutoReplyRunning) {
        [self notifyPcToggleRunning:YES];
    }

    NSDictionary *mon = [respDict[@"monitor"] isKindOfClass:[NSDictionary class]] ? respDict[@"monitor"] : @{};
    if ([respDict[@"started_at"] integerValue] > 0) {
        [self.guardLock lock];
        self.startedAtTs = [respDict[@"started_at"] doubleValue];
        [self.guardLock unlock];
    }
    NSString *phase = [mon[@"phase"] isKindOfClass:[NSString class]] ? mon[@"phase"] : @"patrolling";
    NSString *lastMsg = [mon[@"last_message"] isKindOfClass:[NSString class]] ? mon[@"last_message"] : @"正在监听微信白名单消息…";
    NSString *lastContact = [mon[@"last_contact"] isKindOfClass:[NSString class]] ? mon[@"last_contact"] : @"";
    NSInteger repCnt = mon[@"replied_count"] ? [mon[@"replied_count"] integerValue] : self.totalRepliedCount;

    [self updateRuntimePhase:phase
                  engineMode:@"双端协同高速引擎"
                 lastContact:lastContact
                  statusLine:lastMsg
                repliedCount:MAX(self.totalRepliedCount, repCnt)];
    return YES;
}

#pragma mark - Standalone Local Vision WeChat Patrol (Runs Even When PC Is Off)

- (NSArray<NSNumber *> *)scanRedBadgesInImage:(CGImageRef)cgImg
                                           x0:(double)x0 x1:(double)x1
                                           y0:(double)y0 y1:(double)y1 {
    if (!cgImg) return @[];
    const int sw = 180, sh = 320;
    uint8_t *px = (uint8_t *)calloc(1, sw * sh * 4);
    if (!px) return @[];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, sw, sh, 8, sw * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), cgImg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    int xa = MAX(0, (int)(sw * x0)), xb = MIN(sw - 1, (int)(sw * x1));
    int ya = MAX(0, (int)(sh * y0)), yb = MIN(sh - 1, (int)(sh * y1));
    NSMutableArray<NSNumber *> *redRows = [NSMutableArray array];
    for (int y = ya; y <= yb; y++) {
        int cnt = 0;
        for (int x = xa; x <= xb; x++) {
            int off = (y * sw + x) * 4;
            int r = px[off], g = px[off + 1], b = px[off + 2];
            if (r >= 205 && g <= 100 && b <= 100 && (r - g) >= 115 && (r - b) >= 115) cnt++;
        }
        if (cnt >= 2) [redRows addObject:@(y)];
    }
    free(px);
    if (redRows.count == 0) return @[];

    NSMutableArray<NSNumber *> *centers = [NSMutableArray array];
    int startY = redRows[0].intValue, prevY = startY;
    for (NSUInteger i = 1; i < redRows.count; i++) {
        int curY = redRows[i].intValue;
        if (curY - prevY <= 3) {
            prevY = curY;
        } else {
            if (prevY - startY + 1 >= 2) [centers addObject:@(((startY + prevY) * 0.5) / sh)];
            startY = prevY = curY;
        }
    }
    if (prevY - startY + 1 >= 2) [centers addObject:@(((startY + prevY) * 0.5) / sh)];
    return centers;
}

- (BOOL)hasGreenBubbleInImage:(CGImageRef)cgImg y0:(double)y0 y1:(double)y1 {
    if (!cgImg || y1 <= y0) return NO;
    const int sw = 160, sh = 320;
    uint8_t *px = (uint8_t *)calloc(1, sw * sh * 4);
    if (!px) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, sw, sh, 8, sw * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), cgImg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    int xa = (int)(sw * 0.36), xb = (int)(sw * 0.87);
    int ya = MAX(0, (int)(sh * MAX(0.12, y0))), yb = MIN(sh - 1, (int)(sh * MIN(0.91, y1)));
    int greenPx = 0;
    for (int y = ya; y <= yb; y++) {
        for (int x = xa; x <= xb; x++) {
            int off = (y * sw + x) * 4;
            int r = px[off], g = px[off + 1], b = px[off + 2];
            BOOL lightG = (g >= 195 && r >= 110 && r <= 185 && b >= 70 && b <= 145 && (g - r) >= 35 && (g - b) >= 65);
            BOOL darkG = (g >= 135 && r <= 95 && b <= 135 && (g - r) >= 55 && (g - b) >= 25);
            if (lightG || darkG) greenPx++;
        }
    }
    free(px);
    int area = MAX(1, (yb - ya + 1) * (xb - xa));
    return (greenPx >= 14) && ((double)greenPx / (double)area >= 0.035);
}

- (void)patrolLoopTick {
    if (!self.isAutoReplyRunning || self.patrolBusy) return;
    self.patrolBusy = YES;

    @try {
        // 1. 若同一 Wi-Fi 下电脑端在线且已连手机，优先单主协同并实时镜像状态到手机与悬浮框
        if ([self syncFromPcActiveMonitorIfOnline]) {
            self.patrolBusy = NO;
            return;
        }

        // 2. 电脑端未开或离线：手机本机独立通过 TrollVNC(127.0.0.1:5901) + Vision 中文 OCR 巡检微信
        UIImage *screen = [[MitaKeepAliveAndControl shared] captureLocalVncScreenImage];
        if (!screen || !screen.CGImage) {
            [self updateRuntimePhase:@"waiting_frame"
                          engineMode:@"巨魔本机独立引擎"
                         lastContact:self.monitorLastContact ?: @""
                          statusLine:@"等待本机 TrollVNC (5901) 屏幕通道就绪…"
                        repliedCount:self.totalRepliedCount];
            self.patrolBusy = NO;
            return;
        }

        CGImageRef cgImg = screen.CGImage;
        NSMutableArray<NSDictionary *> *ocrLines = [NSMutableArray array];
        if (@available(iOS 15.0, *)) {
            VNRecognizeTextRequest *ocrReq = [[VNRecognizeTextRequest alloc] init];
            ocrReq.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            ocrReq.recognitionLanguages = @[@"zh-Hans", @"en-US"];
            ocrReq.usesLanguageCorrection = NO;
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImg options:@{}];
            [handler performRequests:@[ocrReq] error:nil];
            for (VNRecognizedTextObservation *obs in ocrReq.results) {
                VNRecognizedText *cand = [[obs topCandidates:1] firstObject];
                if (!cand || cand.string.length == 0) continue;
                CGRect bb = obs.boundingBox; // 原点在左下角
                double x0 = bb.origin.x;
                double x1 = bb.origin.x + bb.size.width;
                double y0 = 1.0 - (bb.origin.y + bb.size.height);
                double y1 = 1.0 - bb.origin.y;
                [ocrLines addObject:@{
                    @"t": [cand.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]],
                    @"x0": @(x0), @"x1": @(x1), @"y0": @(y0), @"y1": @(y1),
                    @"cx": @((x0 + x1) * 0.5), @"cy": @((y0 + y1) * 0.5)
                }];
            }
        }

        [ocrLines sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ya = [a[@"cy"] doubleValue], yb = [b[@"cy"] doubleValue];
            if (fabs(ya - yb) > 0.015) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
            return [a[@"x0"] doubleValue] < [b[@"x0"] doubleValue] ? NSOrderedAscending : NSOrderedDescending;
        }];

        NSMutableString *fullTxt = [NSMutableString string];
        NSMutableString *bottomTxt = [NSMutableString string];
        NSMutableArray<NSDictionary *> *topLines = [NSMutableArray array];
        for (NSDictionary *ln in ocrLines) {
            NSString *t = ln[@"t"];
            double cy = [ln[@"cy"] doubleValue], x0 = [ln[@"x0"] doubleValue];
            [fullTxt appendFormat:@"%@\n", t];
            if (cy >= 0.89) [bottomTxt appendFormat:@"%@ ", t];
            if (cy >= 0.038 && cy <= 0.118 && x0 >= 0.04 && x0 <= 0.76) [topLines addObject:ln];
        }

        int navHits = 0;
        for (NSString *kw in @[@"微信", @"通讯录", @"发现", @"我"]) {
            if ([bottomTxt containsString:kw]) navHits++;
        }
        NSString *topJoined = [[topLines valueForKey:@"t"] componentsJoinedByString:@" "];

        // 情况 A：存在微信底部四栏
        if (navHits >= 2) {
            BOOL onHomeList = ([topJoined containsString:@"微信"] || (![topJoined containsString:@"通讯录"] && ![topJoined containsString:@"发现"]));
            if (!onHomeList) {
                NSArray<NSNumber *> *tabBadge = [self scanRedBadgesInImage:cgImg x0:0.06 x1:0.24 y0:0.89 y1:0.96];
                if (tabBadge.count > 0) {
                    [[MitaKeepAliveAndControl shared] vncTapNormX:0.125 normY:0.955];
                    [self updateRuntimePhase:@"patrolling" engineMode:@"巨魔本机独立引擎" lastContact:@"" statusLine:@"发现微信图标未读红点，已自动切回微信消息列表" repliedCount:self.totalRepliedCount];
                } else {
                    [self updateRuntimePhase:@"watching" engineMode:@"巨魔本机独立引擎" lastContact:@"" statusLine:@"当前在微信子标签页，静默监听未读红点…" repliedCount:self.totalRepliedCount];
                }
                self.patrolBusy = NO;
                return;
            }

            // 扫描首页列表未读红点
            NSArray<NSNumber *> *redYs = [self scanRedBadgesInImage:cgImg x0:0.08 x1:0.25 y0:0.135 y1:0.865];
            for (NSNumber *ryNum in redYs) {
                double ry = ryNum.doubleValue;
                NSMutableArray<NSDictionary *> *rowLns = [NSMutableArray array];
                for (NSDictionary *ln in ocrLines) {
                    double cy = [ln[@"cy"] doubleValue], x0 = [ln[@"x0"] doubleValue];
                    if (x0 >= 0.16 && x0 <= 0.72 && cy >= (ry - 0.022) && cy <= (ry + 0.072)) {
                        [rowLns addObject:ln];
                    }
                }
                if (rowLns.count == 0) continue;
                NSString *cTitle = rowLns[0][@"t"];
                NSRegularExpression *tmRe = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\d{1,2}:\\d{2}\\s*$" options:0 error:nil];
                cTitle = [[tmRe stringByReplacingMatchesInString:cTitle options:0 range:NSMakeRange(0, cTitle.length) withTemplate:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (cTitle.length == 0) continue;
                BOOL isGrp = ([cTitle containsString:@"("] || [cTitle containsString:@"（"]);
                NSString *preview = rowLns.count > 1 ? rowLns[1][@"t"] : @"你好";
                NSDictionary *ev = [self evaluateIncomingForContact:cTitle isGroup:isGrp groupSender:@"" rawText:preview];
                if ([ev[@"allowed"] boolValue]) {
                    double tapY = MIN(0.84, MAX(0.16, ry + 0.018));
                    [[MitaKeepAliveAndControl shared] vncTapNormX:0.48 normY:tapY];
                    [self updateRuntimePhase:@"entering"
                                  engineMode:@"巨魔本机独立引擎"
                                 lastContact:cTitle
                                  statusLine:[NSString stringWithFormat:@"发现白名单「%@」未读消息，正在进入会话…", cTitle]
                                repliedCount:self.totalRepliedCount];
                    self.patrolBusy = NO;
                    return;
                }
            }
            [self updateRuntimePhase:@"patrolling"
                          engineMode:@"巨魔本机独立引擎"
                         lastContact:@""
                          statusLine:@"正在微信首页实时监听白名单未读消息…"
                        repliedCount:self.totalRepliedCount];
            self.patrolBusy = NO;
            return;
        }

        // 情况 B：具体微信聊天窗口
        NSMutableArray<NSString *> *tParts = [NSMutableArray array];
        for (NSDictionary *ln in topLines) {
            NSString *t = ln[@"t"];
            t = [t stringByReplacingOccurrencesOfString:@"<" withString:@""];
            t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length > 0 && [ln[@"x0"] doubleValue] <= 0.70 && ![t containsString:@":"]) {
                [tParts addObject:t];
            }
        }
        NSString *contactTitle = [tParts componentsJoinedByString:@" "];
        if (contactTitle.length == 0) {
            [self updateRuntimePhase:@"watching" engineMode:@"巨魔本机独立引擎" lastContact:@"" statusLine:@"当前不在微信聊天窗口，后台静默守护中…" repliedCount:self.totalRepliedCount];
            self.patrolBusy = NO;
            return;
        }

        NSString *spamReason = nil;
        if ([self isNewFriendOrMarketing:fullTxt checkNewFriend:[MitaConfigStore shared].blockNewFriends checkMarketing:NO outReason:&spamReason]) {
            [self updateRuntimePhase:@"watching" engineMode:@"巨魔本机独立引擎" lastContact:contactTitle statusLine:spamReason repliedCount:self.totalRepliedCount];
            self.patrolBusy = NO;
            return;
        }

        BOOL isGrp = ([contactTitle containsString:@"("] || [contactTitle containsString:@"（"]);
        NSMutableArray<NSDictionary *> *msgLines = [NSMutableArray array];
        for (NSDictionary *ln in ocrLines) {
            double cy = [ln[@"cy"] doubleValue];
            NSString *t = ln[@"t"];
            if (cy >= 0.13 && cy <= 0.895 && ![t containsString:@"撤回了一条消息"]) {
                BOOL inGreen = [self hasGreenBubbleInImage:cgImg y0:([ln[@"y0"] doubleValue] - 0.008) y1:([ln[@"y1"] doubleValue] + 0.008)];
                double x0 = [ln[@"x0"] doubleValue], x1 = [ln[@"x1"] doubleValue];
                NSString *role = @"peer";
                if (inGreen || (x0 > 0.44 && x1 > 0.74)) role = @"self";
                else if (x0 >= 0.26 && x1 <= 0.74 && fabs((x0 + x1) * 0.5 - 0.5) < 0.07) role = @"system";
                else if (x0 <= 0.38) role = @"peer";
                else role = ([ln[@"cx"] doubleValue] > 0.54) ? @"self" : @"peer";
                if (![role isEqualToString:@"system"]) {
                    [msgLines addObject:@{@"t": t, @"role": role, @"y0": ln[@"y0"], @"y1": ln[@"y1"]}];
                }
            }
        }

        if (msgLines.count == 0 || ![msgLines.lastObject[@"role"] isEqualToString:@"peer"]) {
            if (msgLines.count > 0 && [msgLines.lastObject[@"role"] isEqualToString:@"self"]) {
                [self.guardLock lock];
                [self.lastRepliedSignatures removeObjectForKey:contactTitle];
                [self.guardLock unlock];
            }
            [self updateRuntimePhase:@"watching"
                          engineMode:@"巨魔本机独立引擎"
                         lastContact:contactTitle
                          statusLine:[NSString stringWithFormat:@"正在守候「%@」会话，等待对方新消息…", contactTitle]
                        repliedCount:self.totalRepliedCount];
            self.patrolBusy = NO;
            return;
        }

        if ([self hasGreenBubbleInImage:cgImg y0:([msgLines.lastObject[@"y1"] doubleValue] + 0.012) y1:0.90]) {
            self.patrolBusy = NO;
            return;
        }

        NSString *incoming = msgLines.lastObject[@"t"];
        NSString *sig = [NSString stringWithFormat:@"%@|%@", contactTitle, incoming];
        [self.guardLock lock];
        NSString *prevSig = self.lastRepliedSignatures[contactTitle];
        [self.guardLock unlock];
        if ([prevSig isEqualToString:sig]) {
            [self updateRuntimePhase:@"watching" engineMode:@"巨魔本机独立引擎" lastContact:contactTitle statusLine:[NSString stringWithFormat:@"「%@」最新消息已回复，持续监听中…", contactTitle] repliedCount:self.totalRepliedCount];
            self.patrolBusy = NO;
            return;
        }

        NSDictionary *adm = [self evaluateIncomingForContact:contactTitle isGroup:isGrp groupSender:@"" rawText:incoming];
        if (![adm[@"allowed"] boolValue]) {
            [self updateRuntimePhase:@"watching" engineMode:@"巨魔本机独立引擎" lastContact:contactTitle statusLine:(adm[@"reason"] ?: @"未命中白名单，保持沉默") repliedCount:self.totalRepliedCount];
            self.patrolBusy = NO;
            return;
        }

        [self updateRuntimePhase:@"replying"
                      engineMode:@"巨魔本机独立引擎"
                     lastContact:contactTitle
                      statusLine:[NSString stringWithFormat:@"收到「%@」：%@ → 正在调用 API 生成回复…", contactTitle, incoming]
                    repliedCount:self.totalRepliedCount];

        __block NSDictionary *genRes = nil;
        dispatch_semaphore_t genSem = dispatch_semaphore_create(0);
        [self generateWeChatReplyForContact:contactTitle isGroup:isGrp groupSender:@"" incoming:incoming completion:^(NSDictionary *result) {
            genRes = result;
            dispatch_semaphore_signal(genSem);
        }];
        dispatch_semaphore_wait(genSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(28.0 * NSEC_PER_SEC)));

        NSString *replyTxt = [genRes[@"reply"] isKindOfClass:[NSString class]] ? genRes[@"reply"] : @"";
        if ([genRes[@"ok"] boolValue] && ![genRes[@"blocked"] boolValue] && replyTxt.length > 0 && self.isAutoReplyRunning) {
            usleep(1100000); // 1.1s 拟人打字停顿
            BOOL sent = [[MitaKeepAliveAndControl shared] vncTypeAndSendWeChatText:replyTxt autoSend:YES];
            if (sent) {
                [self.guardLock lock];
                self.lastRepliedSignatures[contactTitle] = sig;
                NSInteger nextCnt = self.totalRepliedCount + 1;
                [self.guardLock unlock];
                [self updateRuntimePhase:@"replied"
                              engineMode:@"巨魔本机独立引擎"
                             lastContact:contactTitle
                              statusLine:[NSString stringWithFormat:@"已回复「%@」：%@", contactTitle, replyTxt]
                            repliedCount:nextCnt];
            }
        }
    } @catch (NSException *ex) {
    }
    self.patrolBusy = NO;
}

@end
