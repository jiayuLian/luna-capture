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
#include <stdarg.h>
#include <ctype.h>
#include <errno.h>
#include <mach/vm_region.h>
#include <mach/mach_vm.h>

void LCHookSSL(void);

static volatile int gSslHooked = 0;
static volatile int gSslSeen = 0;

int  LCSslHooked(void) { return gSslHooked; }
int  LCSslSeen(void) { return gSslSeen; }

#pragma mark - 连接包装

// 每个 SSL* 一条连接,双向各自累积字节。
// pending 用来把响应配回对应的请求记录。
@interface LCConnWrap : NSObject
@property (nonatomic, assign) hp_conn_t *hp;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, LCRecord *> *pending;
@property (nonatomic, assign) BOOL sniLogged;
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

#pragma mark - 诊断

static NSString *lc_doc_dir(void) {
    static NSString *dir = nil;
    static dispatch_once_t arOnce;
    dispatch_once(&arOnce, ^{
        NSArray *ps = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES);
        if (ps.count) dir = ps.firstObject;
    });
    return dir;
}

static pthread_mutex_t gDiagLock = PTHREAD_MUTEX_INITIALIZER;

// 每一步的结果都落盘。TrollFools 注入的进程拿不到控制台,
// 这个文件是唯一能在出问题后确认走到哪一步的东西。
static void lc_diag(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[LC] %@", s);

    NSString *dir = lc_doc_dir();
    if (dir.length == 0) return;
    NSString *path = [dir stringByAppendingPathComponent:@"lc_ssl.txt"];

    pthread_mutex_lock(&gDiagLock);
    static NSFileHandle *fh = nil;
    static BOOL stop = NO;
    if (!fh && !stop) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:[NSData data] attributes:nil];
        }
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            @try { [fh seekToEndOfFile]; } @catch (NSException *e) { fh = nil; }
        }
    }
    if (fh) {
        @try {
            NSData *d = [[s stringByAppendingString:@"\n"]
                         dataUsingEncoding:NSUTF8StringEncoding];
            [fh writeData:d];
            if ([fh offsetInFile] > (4u << 20)) { [fh closeFile]; fh = nil; stop = YES; }
        } @catch (NSException *e) {
            fh = nil;
            stop = YES;
        }
    }
    pthread_mutex_unlock(&gDiagLock);
}

#pragma mark - 符号定位

// 只接受"已定义在某个 section 里"的符号。
// v1.5.0 就死在这一步:SSL_read 在主二进制里是 N_UNDF,n_value 为 0,
// 加上 slide 之后得到一个非 NULL 的野指针,后面 memcpy 直接 EXC_BAD_ACCESS。
static void *lc_sym_defined(const struct mach_header_64 *mh, intptr_t slide,
                            const char *want) {
    if (!mh || mh->magic != MH_MAGIC_64) return NULL;

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
                if (syms[k].n_type & N_STAB) continue;
                if ((syms[k].n_type & N_TYPE) != N_SECT) continue;   // 必须是已定义
                if (syms[k].n_value == 0) continue;
                const char *nm = strs + syms[k].n_un.n_strx;
                if (strcmp(nm, want) == 0) {
                    return (void *)(uintptr_t)(syms[k].n_value + slide);
                }
            }
        }
        p += lc->cmdsize;
    }
    return NULL;
}

static void *lc_lookup(const char *sym, const char *dsym) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img) continue;
        if (!strstr(img, "boringssl") && !strstr(img, "BoringSSL")) continue;
        void *r = lc_sym_defined(
            (const struct mach_header_64 *)_dyld_get_image_header(i),
            _dyld_get_image_vmaddr_slide(i), sym);
        if (r) return r;
    }
    return dlsym(RTLD_DEFAULT, dsym);
}

#pragma mark - 数据槽重绑

static const char *kLCDataSegs[] = {
    "__DATA", "__DATA_CONST", "__DATA_DIRTY", "__AUTH", "__AUTH_CONST", NULL
};

static vm_prot_t lc_page_prot(void *addr) {
    vm_address_t region = (vm_address_t)((uintptr_t)addr & ~(uintptr_t)0xFFF);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &size,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &cnt, &obj);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    if (kr != KERN_SUCCESS) return 0;
    return info.protection;
}

// 8 字节对齐写入,必要时临时放开写权限,写完恢复原权限。
static int lc_write_slot(void *slot, uint64_t val) {
    vm_prot_t old = lc_page_prot(slot);
    if (old == 0) return -1;

    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0xFFF;
    BOOL needRestore = !(old & VM_PROT_WRITE);

    if (needRestore) {
        kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                                      false, old | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) {
            // __DATA_CONST 带 SG_READ_ONLY,先做私有拷贝再写
            kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x4000, false,
                            old | VM_PROT_WRITE | VM_PROT_COPY);
        }
        if (kr != KERN_SUCCESS) return -2;
    }
    *(volatile uint64_t *)slot = val;
    if (needRestore) {
        vm_protect(mach_task_self(), (vm_address_t)page, 0x4000, false, old);
    }
    return 0;
}

// 把主镜像数据段里所有等于 real 的 8 字节槽改成 hook。
// 这是纯数据段写,不碰代码页、不需要可执行权限,任何情况下都不会让进程崩。
static int lc_rebind_main(uint64_t real, void *hook, int *failOut) {
    int hits = 0, fails = 0;
    const struct mach_header_64 *mh =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh || mh->magic != MH_MAGIC_64) { if (failOut) *failOut = -1; return 0; }
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);

    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            BOOL want = NO;
            for (int i = 0; kLCDataSegs[i]; i++) {
                if (strncmp(sg->segname, kLCDataSegs[i], 16) == 0) { want = YES; break; }
            }
            if (want && sg->filesize > 0) {
                uint8_t *base = (uint8_t *)(uintptr_t)(slide + sg->vmaddr);
                size_t n = (size_t)sg->filesize;
                if (sg->vmsize < n) n = (size_t)sg->vmsize;
                n &= ~(size_t)7;
                for (size_t o = 0; o < n; o += 8) {
                    uint64_t v = *(volatile uint64_t *)(base + o);
                    if (v != real) continue;
                    if (lc_write_slot(base + o, (uint64_t)(uintptr_t)hook) == 0) hits++;
                    else fails++;
                }
            }
        }
        p += lc->cmdsize;
    }
    if (failOut) *failOut = fails;
    return hits;
}

#pragma mark - inline hook(兜底)

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

// 先确认 target 落在一个已映射的可执行区里,再动手。
// 少了这一步,v1.5.0 就是拿一个野指针去 memcpy。
static BOOL lc_exec_region(void *target, uintptr_t *baseOut, vm_size_t *sizeOut) {
    vm_address_t region = (vm_address_t)target;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &size,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &cnt, &obj);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    if (kr != KERN_SUCCESS) return NO;
    if (!(info.protection & VM_PROT_EXECUTE)) return NO;
    if ((uintptr_t)target < (uintptr_t)region) return NO;
    if ((uintptr_t)target >= (uintptr_t)region + (uintptr_t)size) return NO;
    if (baseOut) *baseOut = (uintptr_t)region;
    if (sizeOut) *sizeOut = size;
    return YES;
}

static int lc_patch(void *target, void *replace, void **trampoline_out) {
    if (!target || !replace) return -1;
    if (!lc_exec_region(target, NULL, NULL)) return -5;

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
    tp[1] = 0xD61F0200u;   // br  x16
    *(uint64_t *)(tr + 24) = (uint64_t)((uint8_t *)target + 16);

    if (mprotect(tr, 4096, PROT_READ | PROT_EXEC) != 0) {
        munmap(tr, 4096);
        return -3;
    }
    sys_icache_invalidate(tr, 32);

    uintptr_t page = (uintptr_t)target & ~(uintptr_t)0xFFF;
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                                  false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        munmap(tr, 4096);
        return -4;
    }

    code[0] = 0x58000050u;
    code[1] = 0xD61F0200u;
    *(uint64_t *)&code[2] = (uint64_t)replace;
    sys_icache_invalidate(target, 16);

    vm_protect(mach_task_self(), (vm_address_t)page, 0x4000, false,
               VM_PROT_READ | VM_PROT_EXECUTE);

    if (trampoline_out) *trampoline_out = tr;
    return 0;
}

#pragma mark - SSL hook

static int (*gOrigWrite)(void *, const void *, int) = NULL;
static int (*gOrigRead)(void *, void *, int) = NULL;
static const char *(*gOrigSNI)(void *, int) = NULL;

static volatile unsigned long long gRawW = 0;
static volatile unsigned long long gRawR = 0;
static char gHookMode[96] = "ssl:init";
static BOOL gAllowPatch = YES;   // 安全模式下只允许数据段重绑,不做 inline hook

void LCSetSSLMode(BOOL allowPatch) { gAllowPatch = allowPatch; }
void LCDiagLine(NSString *line) { lc_diag(@"%@", line); }

// 每条连接只记一次 SNI,用来确认到底连了哪些域名
static void lc_log_sni(LCConnWrap *w, void *ssl) {
    if (!w || w.sniLogged || !gOrigSNI) return;
    w.sniLogged = YES;
    const char *s = NULL;
    @try { s = gOrigSNI(ssl, 0); } @catch (NSException *e) { s = NULL; }
    if (s && s[0]) lc_diag(@"tls sni=%s", s);
}

static int lc_ssl_write(void *ssl, const void *buf, int num) {
    int r = gOrigWrite ? gOrigWrite(ssl, buf, num) : -1;
    if (r > 0) {
        gRawW++;
        LCConnWrap *w = conn_get(ssl);
        lc_log_sni(w, ssl);
        if (w && w.hp) {
            hp_feed(w.hp, 0, (const uint8_t *)buf, (size_t)r,
                    (__bridge void *)w, lc_on_msg);
        }
    }
    return r;
}

static int lc_ssl_read(void *ssl, void *buf, int num) {
    int r = gOrigRead ? gOrigRead(ssl, buf, num) : -1;
    if (r > 0) {
        gRawR++;
        LCConnWrap *w = conn_get(ssl);
        lc_log_sni(w, ssl);
        if (w && w.hp) {
            hp_feed(w.hp, 1, (const uint8_t *)buf, (size_t)r,
                    (__bridge void *)w, lc_on_msg);
        }
    }
    return r;
}

void LCHookSSL(void) {
    if (gSslHooked) return;

    static int tries = 0;
    if (tries >= 4) return;      // 符号一启动就在,重复扫 60MB 没意义
    tries++;

    void *rw = lc_lookup("_SSL_write", "SSL_write");
    void *rr = lc_lookup("_SSL_read",  "SSL_read");
    lc_diag(@"lookup write=%p read=%p", rw, rr);
    if (!rw || !rr) {
        snprintf(gHookMode, sizeof(gHookMode), "ssl:not-found w=%p r=%p", rw, rr);
        return;
    }

    gOrigSNI = (const char *(*)(void *, int))lc_lookup("_SSL_get_servername",
                                                       "SSL_get_servername");

    // 第一优先:数据段槽位重绑。所有经过 PLT 的调用都会命中,
    // 且不修改任何代码页,不会因为代码签名保护崩掉。
    int fw = 0, fr = 0;
    int slotW = lc_rebind_main((uint64_t)(uintptr_t)rw, (void *)lc_ssl_write, &fw);
    int slotR = lc_rebind_main((uint64_t)(uintptr_t)rr, (void *)lc_ssl_read,  &fr);
    lc_diag(@"rebind write slots=%d fail=%d | read slots=%d fail=%d",
            slotW, fw, slotR, fr);

    // 兜底:槽位没找到(例如调用来自 dlsym)才做 inline hook
    int pw = -100, pr = -100;
    void *tw = NULL, *tr = NULL;
    if (slotW == 0 && gAllowPatch) {
        pw = lc_patch(rw, (void *)lc_ssl_write, &tw);
        lc_diag(@"patch write => %d tramp=%p", pw, tw);
    }
    if (slotR == 0 && gAllowPatch) {
        pr = lc_patch(rr, (void *)lc_ssl_read, &tr);
        lc_diag(@"patch read => %d tramp=%p", pr, tr);
    }
    if (!gAllowPatch) lc_diag(@"patch disabled (safe mode)");

    // 原函数来源:patch 成功时必须走 trampoline,否则递归到死
    gOrigWrite = (pw == 0) ? (int (*)(void *, const void *, int))tw
                           : (int (*)(void *, const void *, int))rw;
    gOrigRead  = (pr == 0) ? (int (*)(void *, void *, int))tr
                           : (int (*)(void *, void *, int))rr;

    if (slotW || slotR || pw == 0 || pr == 0) {
        gSslHooked = 1;
        snprintf(gHookMode, sizeof(gHookMode),
                 "ssl:ok slot(w%d,r%d) patch(w%d,r%d)",
                 slotW, slotR, pw, pr);
        NSLog(@"[LC] %s", gHookMode);
        lc_diag(@"hook ready: %s", gHookMode);
    } else {
        snprintf(gHookMode, sizeof(gHookMode),
                 "ssl:fail slot(w%d,r%d) patch(w%d,r%d)",
                 slotW, slotR, pw, pr);
        NSLog(@"[LC] %s", gHookMode);
    }
}

const char *LCSslInfo(void) {
    static char buf[192];
    snprintf(buf, sizeof(buf), "%s rw=%llu rd=%llu sslrec=%d",
             gHookMode, gRawW, gRawR, gSslSeen);
    return buf;
}
