#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 版本标记,workflow 用来断言产物版本
#define LC_VER @"v1.7.0"

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
int  LCSslHooked(void);
int  LCSslSeen(void);
const char *LCSslInfo(void);

// hook 诊断信息,导出 HAR 时写进 creator.comment,便于判断通道是否生效
extern NSString *LCHookInfo;
extern NSString *LCStatString(void);   // 通道状态 + 命中计数,写进 HAR 的 creator.comment
extern NSString *LCCrashTail(void);    // 上次未捕获异常摘要,同样写进 comment
