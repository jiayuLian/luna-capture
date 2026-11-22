#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 版本标记,workflow 用来断言产物版本
#define LC_VER @"v3.5.0"

@interface LCRecord : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *reqBody;
@property (nonatomic, copy) NSString *respBody;
@property (nonatomic, copy) NSString *mime;
@property (nonatomic, assign) BOOL respIsBase64;
@property (nonatomic, strong) NSDictionary *reqHeaders;
@property (nonatomic, strong) NSDictionary *respHeaders;
@property (nonatomic, assign) NSInteger status;
@property (nonatomic, assign) NSInteger seq;      // 全局递增序号,按操作顺序排查用
@property (nonatomic, strong) NSDate *start;
@property (nonatomic, strong) NSDate *end;
@property (nonatomic, copy) NSString *source;   // nsurlsession / boringssl
@end

@interface LCCapture : NSObject
+ (instancetype)shared;
- (void)addRecord:(LCRecord *)rec;
- (NSUInteger)count;
- (void)clear;
- (NSArray<LCRecord *> *)snapshot;
- (void)recordRequest:(NSURLRequest *)req
             response:(NSURLResponse *)resp
                 data:(NSData *)data
                start:(NSDate *)start
                  end:(NSDate *)end
              reqBody:(NSData *)reqBody
               source:(NSString *)source
                error:(NSError *)err;
- (NSDictionary *)buildHAR;
- (NSString *)exportHAR;                 // 返回落盘路径
- (NSString *)exportJSON;
@end

void LCSetupUI(void);
void LCHookAll(void);

// TTNet(Cronet)门面层旁路。iOS 版汽水业务请求全走这里,NSURLSession 只承载少量 CDN JSON。
void LCHookTTNet(void);

// NSURLSession 层旁路:hook -[NSURLSessionTask resume] 与 TTNet 的 session delegate。
// 这是主通道,覆盖 delegate 模式的请求。
void LCHookSession(void);

// 跨通道去重:同一请求被两条通道各碰一次时只放一条过
BOOL LCTryClaimURL(NSString *url, NSString *method);

// BoringSSL 层:inline hook SSL_read / SSL_write,拿 TLS 明文。
// 业务请求不经 NSURLSession 时,这是唯一能拿到内容的地方。
void LCHookSSL(void);
void LCSetSSLMode(BOOL allowPatch);   // NO = 安全模式,只做数据段重绑
void LCDiagLine(NSString *line);       // 往 Documents/lc_ssl.txt 追加一行

// 任务自动化:用 App 自己的 TTNetworkManager 发 do_action,
// 签名与设备指纹由 App 生成(PC 端 Python 会被判 1000043 设备异常)。
BOOL LCAutoPrepare(void);              // 从已抓流量里取 base 与请求头;NO 表示还没抓过金币页
void LCAutoRun(void);                  // 异步跑一轮,日志写 Documents/lc_auto.txt
BOOL LCAutoBusy(void);
NSString *LCAutoLogText(void);
NSString *LCAutoExportLog(void);       // 合并 lc_auto/lc_ssl/lc_hooked/lc_state 成一个文件并返回路径
void LCAutoLog(NSString *fmt, ...);    // 供其它模块写同一条日志流

// 激励视频自动化:在进程内调 Lynx 的 jsb bridge,等价于用户点了「看广告」。
// 广告由 App 自己拉自己播自己上报,签名与设备指纹全部由 App 生成。
void LCAdHookInstall(void);
BOOL LCAdHasTemplate(void);            // 是否已录到 paramModel(需手动点过一次广告)
NSString *LCAdTemplateText(void);
void LCAdRun(NSInteger times);         // 全自动循环:开→播16s→自动关→下一轮
BOOL LCAdBusy(void);
void LCAdStop(void);  // 立刻停掉循环,当前这一轮广告不强制关
NSDictionary *LCAdEffectiveExtra(void);
// 任务页响应进来时调一次,从中解出最新的 music_incentive_ad token。
// 任务页每次刷新都会重新生成 token(Capture.m 在记录 /luna/treasure/task/page/v2 时调)。
void LCAdNotePageResponse(NSString *body);
void LCAdNoteTaskPage(NSString *body, BOOL isBase64);  // addRecord 侧入口,只计数
void LCAdTaskPageStats(void);                          // 导出日志时打一行汇总
int  LCAdTaskPageSeen(void);
int  LCAdTaskPageParsed(void);
void LCDumpAdViewTree(void);        // 把当前界面结构写到 lc_view.txt
void LCAutoLog(NSString *fmt, ...);
// preload 响应进来时调一次,里面带 effective_inspire_time(本次要播多少秒)。
// 写死时长会提前关广告,攒几次就触发风控。
void LCAdNotePreloadResponse(NSString *body);
NSString *LCAdCurrentToken(void);
int  LCSslHooked(void);
int  LCSslSeen(void);
const char *LCSslInfo(void);

// hook 诊断信息,导出 HAR 时写进 creator.comment,便于判断通道是否生效
extern NSString *LCHookInfo;
extern NSString *LCStatString(void);   // 通道状态 + 命中计数,写进 HAR 的 creator.comment
extern NSString *LCCrashTail(void);    // 上次未捕获异常摘要,同样写进 comment
