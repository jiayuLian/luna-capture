//
//  HookSSL.m
//  BoringSSL 层的明文抓取。
//
//  ── 为什么必须下沉到这一层 ──
//  汽水音乐的 iOS 版用 Cronet(Chromium 网络栈),业务请求:
//    · 不经过 NSURLSession(resume 只被 StoreKit 的 bag.xml 调过一次)
//    · 不经过 NSURLProtocol
//    · TTNet 的 ObjC 门面方法名在二进制里存在,但签名与 grep 到的对不上
//  唯一剩下的地方就是 TLS 本身。
//
//  主二进制里 _SSL_read / _SSL_write 是 undefined 符号,由 boringssl.framework
//  提供,说明所有 TLS 明文都从这里进出。这两个函数的 prologue 是纯栈操作
//  (stp/sub/add,无 PC 相对指令),可以安全地 inline hook。
//

#import "LunaCapture.h"
#import "http_parse.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <zlib.h>
#include <stdio.h>

void LCHookSSL(void);

static volatile int gSslHooked = 0;
static volatile int gSslSeen = 0;
static char gSslInfo[192] = "ssl:init";

int  LCSslHooked(void) { return gSslHooked; }
int  LCSslSeen(void) { return gSslSeen; }
const char *LCSslInfo(void) { return gSslInfo; }

#pragma mark - 连接包装

// 每个 SSL* 一条连接,双向各自累积字节。
// pending 用来把响应配回对应的请求记录。
@interface LCConnWrap : NSObject
@property (nonatomic, assign) hp_conn_t *hp;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, LCRecord *> *pending;
@end

@implementation LCConnWrap
- (instancetype)initWithHP:(hp_conn_t *)hp {
    if ((self = [super init])) {
        _hp = hp;
        _pending = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)dealloc {
    if (_hp) { hp_conn_free(_hp); _hp = NULL; }
}
@end

#define LC_MAX_CONN 48

// 用 NSMapTable:key 是 ssl 裸指针(opaque,不 retain),value 强引用 wrapper。
// 用 C 数组存 ObjC 对象指针在 ARC 下不会 retain,离开作用域就悬空了。
static NSMapTable *gConnMap = nil;
static pthread_mutex_t gConnLock = PTHREAD_MUTEX_INITIALIZER;

static LCConnWrap *conn_get(void *ssl) {
    if (!ssl) return nil;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gConnMap = [NSMapTable mapTableWithKeyOptions:
                    (NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality)
                                            valueOptions:NSPointerFunctionsStrongMemory];
    });

    LCConnWrap *w = nil;
    pthread_mutex_lock(&gConnLock);
    w = [gConnMap objectForKey:(__bridge id)ssl];
    if (!w) {
        if (gConnMap.count >= LC_MAX_CONN) [gConnMap removeAllObjects];
        hp_conn_t *hp = hp_conn_new();
        if (hp) {
            w = [[LCConnWrap alloc] initWithHP:hp];
            [gConnMap setObject:w forKey:(__bridge id)ssl];
        }
    }
    pthread_mutex_unlock(&gConnLock);
    return w;
}

#pragma mark - 记录转换

static BOOL lc_skip_url(NSString *u) {
    if (u.length == 0) return YES;
    NSString *s = u.lowercaseString;
    static NSArray *ext = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ext = @[@".mp3", @".m4a", @".aac", @".flac", @".wav", @".ogg",
                @".mp4", @".m4v", @".ts", @".m4s", @".mov", @".flv",
                @".webp", @".png", @".jpg", @".jpeg", @".gif", @".heic",
                @".ttf", @".otf", @".zip", @".dylib", @".bundle"];
    });
    NSRange q = [s rangeOfString:@"?"];
    NSString *path = (q.location == NSNotFound) ? s : [s substringToIndex:q.location];
    for (NSString *e in ext) {
        if ([path hasSuffix:e]) return YES;
    }
    if ([s containsString:@"/video/tos/"] || [s containsString:@"/audio/tos/"]) return YES;
    if ([s containsString:@"bytestart="] || [s containsString:@"byteend="]) return YES;
    return NO;
}

static NSDictionary *lc_parse_headers(const char *h) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!h) return d;
    NSString *s = [NSString stringWithUTF8String:h];
    if (!s) return d;
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        NSRange c = [line rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        NSString *k = [line substringToIndex:c.location];
        NSString *v = [line substringFromIndex:c.location + 1];
        v = [v stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceCharacterSet]];
        if (k.length && v.length) d[k] = v;
    }
    return d;
}

static NSString *lc_gzip(NSData *in) {
    if (in.length == 0) return nil;
    z_stream st;
    memset(&st, 0, sizeof(st));
    // 15+32:自动识别 gzip 与 zlib 头
    if (inflateInit2(&st, 15 + 32) != Z_OK) return nil;

    NSMutableData *out = [NSMutableData dataWithLength:in.length * 4 + 4096];
    st.next_in = (Bytef *)in.bytes;
    st.avail_in = (uInt)in.length;
    st.next_out = (Bytef *)out.mutableBytes;
    st.avail_out = (uInt)out.length;

    int rc = inflate(&st, Z_NO_FLUSH);
    if (rc != Z_OK && rc != Z_STREAM_END) {
        inflateEnd(&st);
        return nil;
    }
    NSUInteger produced = out.length - st.avail_out;
    inflateEnd(&st);

    NSString *s = [[NSString alloc] initWithData:[out subdataWithRange:NSMakeRange(0, produced)]
                                        encoding:NSUTF8StringEncoding];
    return s;
}

static NSString *lc_body_str(const uint8_t *b, size_t n) {
    if (!b || n == 0) return nil;
    NSData *d = [NSData dataWithBytes:b length:n];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;
    return [NSString stringWithFormat:@"base64:%@",
            [d base64EncodedStringWithOptions:0]];
}

static NSString *lc_resp_body(NSDictionary *hdr, const uint8_t *b, size_t n) {
    if (!b || n == 0) return nil;
    NSString *enc = nil;
    for (NSString *k in hdr) {
        if ([k.lowercaseString isEqualToString:@"content-encoding"]) { enc = hdr[k]; break; }
    }
    if (enc) {
        NSString *e = enc.lowercaseString;
        NSData *raw = [NSData dataWithBytes:b length:n];
        if ([e containsString:@"gzip"] || [e containsString:@"deflate"]) {
            NSString *s = lc_gzip(raw);
            if (s) return s;
            return [NSString stringWithFormat:@"base64:%@",
                    [raw base64EncodedStringWithOptions:0]];
        }
        if ([e containsString:@"br"]) {
            // brotli 没链接,原样标记
            return [NSString stringWithFormat:@"base64:%@",
                    [raw base64EncodedStringWithOptions:0]];
        }
    }
    return lc_body_str(b, n);
}

static void lc_on_msg(void *ctx, const hp_msg_t *msg) {
    if (!ctx || !msg) return;
    LCConnWrap *w = (__bridge LCConnWrap *)ctx;

    @autoreleasepool {
        if (msg->is_request) {
            NSString *host = msg->host ? [NSString stringWithUTF8String:msg->host] : nil;
            NSString *path = msg->path ? [NSString stringWithUTF8String:msg->path] : nil;
            if (path.length == 0) return;

            NSString *url = nil;
            if ([path hasPrefix:@"http://"] || [path hasPrefix:@"https://"]) {
                url = path;
            } else if (host.length) {
                url = [NSString stringWithFormat:@"https://%@%@", host, path];
            } else {
                return;
            }
            if (lc_skip_url(url)) return;

            LCRecord *r = [LCRecord new];
            r.url = url;
            NSString *m = msg->method ? [NSString stringWithUTF8String:msg->method] : nil;
            r.method = m.length ? m.uppercaseString : @"GET";
            r.reqHeaders = lc_parse_headers(msg->headers);
            r.reqBody = lc_body_str(msg->body, msg->body_len);
            r.source = @"ssl";
            r.start = [NSDate date];
            r.end = r.start;

            [[LCCapture shared] addRecord:r];
            gSslSeen++;

            NSNumber *key = @(msg->stream_id);
            @synchronized (w.pending) {
                // pending 有上限,防止长连接累积过多
                if (w.pending.count > 64) [w.pending removeAllObjects];
                w.pending[key] = r;
            }
        } else {
            LCRecord *r = nil;
            NSNumber *key = @(msg->stream_id);
            @synchronized (w.pending) {
                if (msg->proto == 2) {
                    r = w.pending[key];
                    if (r) [w.pending removeObjectForKey:key];
                } else {
                    // HTTP/1.1 严格一问一答,取最早挂着的
                    NSArray *ks = [w.pending allKeys];
                    if (ks.count) {
                        NSNumber *k0 = ks.firstObject;
                        r = w.pending[k0];
                        [w.pending removeObjectForKey:k0];
                    }
                }
            }
            if (!r) return;

            r.status = msg->status;
            r.respHeaders = lc_parse_headers(msg->headers);
            r.respBody = lc_resp_body(r.respHeaders, msg->body, msg->body_len);
            r.end = [NSDate date];
        }
    }
}

#pragma mark - inline hook

static int lc_is_pc_relative(uint32_t ins) {
    if ((ins & 0x9F000000u) == 0x90000000u) return 1;   // ADRP
    if ((ins & 0xFC000000u) == 0x14000000u) return 1;   // B
    if ((ins & 0xFC000000u) == 0x94000000u) return 1;   // BL
    if ((ins & 0x7E000000u) == 0x34000000u) return 1;   // CBZ / CBNZ
    if ((ins & 0x7E000000u) == 0x36000000u) return 1;   // TBZ / TBNZ
    if ((ins & 0x9F000000u) == 0x10000000u) return 1;   // ADR
    if ((ins & 0x3B000000u) == 0x18000000u) return 1;   // LDR (literal)
    return 0;
}

// 用 16 字节绝对跳转替换函数头:
//   ldr x16, #8
//   br  x16
//   <8 字节目标地址>
static int lc_patch(void *target, void *replace, void **trampoline_out) {
    if (!target || !replace) return -1;
    uint32_t *code = (uint32_t *)target;
    uint32_t backup[4];
    memcpy(backup, code, 16);

    for (int i = 0; i < 4; i++) {
        if (lc_is_pc_relative(backup[i])) return -2;
    }

    uint8_t *tr = (uint8_t *)mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANON, -1, 0);
    if (tr == MAP_FAILED) return -3;

    memcpy(tr, backup, 16);
    uint32_t *tp = (uint32_t *)(tr + 16);
    tp[0] = 0x58000050u;   // ldr x16, #8
    tp[1] = 0xD61F0200u;   // br x16
    *(uint64_t *)(tr + 24) = (uint64_t)((uint8_t *)target + 16);

    mprotect(tr, 4096, PROT_READ | PROT_EXEC);
    sys_icache_invalidate(tr, 32);

    uintptr_t page = (uintptr_t)target & ~0xFFFULL;
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x2000,
                                  false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        munmap(tr, 4096);
        return -4;
    }

    code[0] = 0x58000050u;
    code[1] = 0xD61F0200u;
    *(uint64_t *)&code[2] = (uint64_t)replace;
    sys_icache_invalidate(target, 16);

    vm_protect(mach_task_self(), (vm_address_t)page, 0x2000, false,
               VM_PROT_READ | VM_PROT_EXECUTE);

    if (trampoline_out) *trampoline_out = tr;
    return 0;
}

// 在已加载的镜像里按名字找符号地址(不依赖全局可见性)
static void *lc_find_sym(const char *want) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img) continue;
        if (!strstr(img, "boringssl") && !strstr(img, "BoringSSL") &&
            !strstr(img, "Luna") && !strstr(img, "Schubert")) continue;

        const struct mach_header_64 *mh =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        const uint8_t *p = (const uint8_t *)(mh + 1);
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_SYMTAB) {
                const struct symtab_command *st = (const struct symtab_command *)lc;
                const struct nlist_64 *syms =
                    (const struct nlist_64 *)((const uint8_t *)mh + st->symoff);
                const char *strs = (const char *)mh + st->stroff;
                for (uint32_t k = 0; k < st->nsyms; k++) {
                    if (syms[k].n_un.n_strx == 0) continue;
                    const char *nm = strs + syms[k].n_un.n_strx;
                    if (strcmp(nm, want) == 0) {
                        return (void *)((uint8_t *)(syms[k].n_value + slide));
                    }
                }
            }
            p += lc->cmdsize;
        }
    }
    return NULL;
}

#pragma mark - SSL hook

static int (*gOrigWrite)(void *, const void *, int) = NULL;
static int (*gOrigRead)(void *, void *, int) = NULL;

static int lc_ssl_write(void *ssl, const void *buf, int num) {
    int r = gOrigWrite ? gOrigWrite(ssl, buf, num) : -1;
    if (r > 0) {
        LCConnWrap *w = conn_get(ssl);
        if (w && w.hp) hp_feed(w.hp, 0, (const uint8_t *)buf, (size_t)r, (__bridge void *)w, lc_on_msg);
    }
    return r;
}

static int lc_ssl_read(void *ssl, void *buf, int num) {
    int r = gOrigRead ? gOrigRead(ssl, buf, num) : -1;
    if (r > 0) {
        LCConnWrap *w = conn_get(ssl);
        if (w && w.hp) hp_feed(w.hp, 1, (const uint8_t *)buf, (size_t)r, (__bridge void *)w, lc_on_msg);
    }
    return r;
}

void LCHookSSL(void) {
    if (gSslHooked) return;

    void *rw = lc_find_sym("_SSL_write");
    void *rr = lc_find_sym("_SSL_read");
    if (!rw || !rr) {
        snprintf(gSslInfo, sizeof(gSslInfo), "ssl:not-found w=%p r=%p", rw, rr);
        return;
    }

    void *tw = NULL, *tr = NULL;
    int e1 = lc_patch(rw, (void *)lc_ssl_write, &tw);
    int e2 = lc_patch(rr, (void *)lc_ssl_read, &tr);

    if (e1 == 0) gOrigWrite = (int (*)(void *, const void *, int))tw;
    if (e2 == 0) gOrigRead  = (int (*)(void *, void *, int))tr;

    if (e1 == 0 || e2 == 0) {
        gSslHooked = 1;
        snprintf(gSslInfo, sizeof(gSslInfo), "ssl:ok write=%d read=%d", e1, e2);
        NSLog(@"[LC] SSL hooked %s", gSslInfo);
    } else {
        snprintf(gSslInfo, sizeof(gSslInfo), "ssl:patch-fail w=%d r=%d", e1, e2);
        NSLog(@"[LC] SSL patch failed %s", gSslInfo);
    }
}
