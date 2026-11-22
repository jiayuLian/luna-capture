//
//  http_parse.c
//  TLS 明文的 HTTP/1.1 与 HTTP/2 解析。
//
//  SSL_read/SSL_write 给出的是应用层原始字节,协议形态未知:
//   - HTTP/1.1:  "GET /path HTTP/1.1\r\nHost: ...\r\n\r\n"
//   - HTTP/2:    "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" 前言 + 二进制帧
//  这里两种都解,首包自动判别并锁定。
//
//  HTTP/2 的头是 HPACK 编码(静态表 + 动态表 + Huffman),必须完整解码,
//  否则拿不到 :path 和 cookie/x-argus 这些关键头。
//

#include "http_parse.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

#include "hpack_tables.inc"      // kHuffCode / kHuffBits

// ---------------------------------------------------------------- 静态表
// RFC 7541 附录 A,索引 1..61(索引 0 保留)
static const char *kHpName[62] = {
    NULL,   // 0
    ":authority", ":method", ":method", ":path",   // 1-4
    ":path", ":scheme", ":scheme", ":status",   // 5-8
    ":status", ":status", ":status", ":status",   // 9-12
    ":status", ":status", "accept-charset", "accept-encoding",   // 13-16
    "accept-language", "accept-ranges", "accept", "access-control-allow-origin",   // 17-20
    "age", "allow", "authorization", "cache-control",   // 21-24
    "content-disposition", "content-encoding", "content-language", "content-length",   // 25-28
    "content-location", "content-range", "content-type", "cookie",   // 29-32
    "date", "etag", "expect", "expires",   // 33-36
    "from", "host", "if-match", "if-modified-since",   // 37-40
    "if-none-match", "if-range", "if-unmodified-since", "last-modified",   // 41-44
    "link", "location", "max-forwards", "proxy-authenticate",   // 45-48
    "proxy-authorization", "range", "referer", "refresh",   // 49-52
    "retry-after", "server", "set-cookie", "strict-transport-security",   // 53-56
    "transfer-encoding", "user-agent", "vary", "via",   // 57-60
    "www-authenticate",   // 61-61
};

static const char *kHpVal[62] = {
    NULL,   // 0
    "", "GET", "POST", "/",   // 1-4
    "/index.html", "http", "https", "200",   // 5-8
    "204", "206", "304", "400",   // 9-12
    "404", "500", "", "gzip, deflate",   // 13-16
    "", "", "", "",   // 17-20
    "", "", "", "",   // 21-24
    "", "", "", "",   // 25-28
    "", "", "", "",   // 29-32
    "", "", "", "",   // 33-36
    "", "", "", "",   // 37-40
    "", "", "", "",   // 41-44
    "", "", "", "",   // 45-48
    "", "", "", "",   // 49-52
    "", "", "", "",   // 53-56
    "", "", "", "",   // 57-60
    "",   // 61-61
};

// ---------------------------------------------------------------- Huffman
// 13 位前缀查表:覆盖 5~13 位的码(占绝大多数),更长的走线性慢路径。
// 表项 = (码长 << 16) | 符号, 0 表示需要更多位。
static uint32_t gHuffLUT[1 << 13];
static int gHuffReady = 0;

static void huff_init(void) {
    if (gHuffReady) return;
    for (int sym = 0; sym < 257; sym++) {
        int b = kHuffBits[sym];
        if (b > 13) continue;
        uint32_t code = kHuffCode[sym];
        int shift = 13 - b;
        uint32_t base = (code << shift) & 0x1FFF;
        uint32_t fill = 1u << shift;
        for (uint32_t i = 0; i < fill; i++) {
            gHuffLUT[base | i] = ((uint32_t)b << 16) | (uint32_t)sym;
        }
    }
    gHuffReady = 1;
}

// 慢路径:找码长 > 13 的符号
static int huff_find_long(uint32_t prefix, int bits) {
    for (int sym = 0; sym < 257; sym++) {
        int b = kHuffBits[sym];
        if (b <= 13 || b > bits) continue;
        uint32_t code = kHuffCode[sym];
        if (((prefix >> (bits - b)) & ((1u << b) - 1)) == code) return sym;
    }
    return -1;
}

// 返回 0 成功。out 由 malloc 分配,调用方 free。
static int huff_decode(const uint8_t *s, size_t n, char **out, size_t *olen) {
    huff_init();
    size_t cap = n * 2 + 16;
    char *o = (char *)malloc(cap);
    if (!o) return -1;
    size_t ol = 0;

    uint64_t acc = 0;
    int nbits = 0;

    for (size_t i = 0; i < n; i++) {
        acc = ((acc << 8) | s[i]) & 0xFFFFFFFFFFULL;
        nbits += 8;

        while (nbits >= 13) {
            uint32_t idx = (uint32_t)((acc >> (nbits - 13)) & 0x1FFF);
            uint32_t e = gHuffLUT[idx];
            int used = 0;
            if (e) {
                used = (int)(e >> 16);
                int sym = (int)(e & 0xFFFF);
                if (sym != 256) {
                    if (ol + 1 >= cap) { cap *= 2; o = (char *)realloc(o, cap); }
                    o[ol++] = (char)sym;
                }
            } else {
                int sym = huff_find_long((uint32_t)(acc & 0xFFFFFFFFFFULL), nbits > 40 ? 40 : nbits);
                if (sym < 0) { free(o); return -1; }
                used = kHuffBits[sym];
                if (sym != 256) {
                    if (ol + 1 >= cap) { cap *= 2; o = (char *)realloc(o, cap); }
                    o[ol++] = (char)sym;
                }
            }
            if (used <= 0) break;          // 码长异常,直接收尾,防死循环
            nbits -= used;
            if (nbits <= 0) { nbits = 0; acc = 0; break; }
            acc &= ((1ULL << nbits) - 1);
        }
    }

    // 结尾剩余位里可能还压着一到两个短码。
    // 原来只解得了一个,导致每个 Huffman 字符串丢尾部字符 ——
    // 表现就是 "application/json" 变成 "application/jso"、
    // content-encoding 变成 "gzi",gzip 响应全部解不开。
    while (nbits > 0) {
        uint32_t room = 13u - (uint32_t)nbits;
        uint32_t pat = (uint32_t)((acc << room) & 0x1FFF);
        if (room) pat |= (uint32_t)((1u << room) - 1u);   // 补 1,与 EOB 填充一致
        uint32_t e = gHuffLUT[pat & 0x1FFF];
        if (!e) break;
        int used = (int)(e >> 16);
        int sym  = (int)(e & 0xFFFF);
        if (used > nbits) break;      // 超出剩余位数 = 纯填充
        if (sym == 256) break;        // EOB
        if (ol + 1 >= cap) {
            cap *= 2;
            char *np = (char *)realloc(o, cap);
            if (!np) { free(o); return -1; }
            o = np;
        }
        o[ol++] = (char)sym;
        nbits -= used;
        acc &= ((1ULL << nbits) - 1);
    }

    o[ol] = 0;
    *out = o;
    *olen = ol;
    return 0;
}

// ---------------------------------------------------------------- 连接状态

#define HP_DYN_MAX 64
#define HP_PEND_MAX 16

typedef struct {
    char  *n;
    char  *v;
    size_t sz;
} hp_ent;

typedef struct {
    hp_ent e[HP_DYN_MAX];
    int    cnt;
    size_t sz;
    size_t max;
} hp_dyntable;

// h2 的 HEADERS 与 DATA 可能分帧,且多条流可能交错。
// 每个流单独挂一个 header block,等 DATA 或 END_STREAM 到了再发。
typedef struct {
    uint32_t sid;
    uint8_t *buf;
    size_t   len, cap;
    int      used;
    int      dir;
} hp_pend;

struct hp_conn {
    int decided;        // 0 未定 1 h1 2 h2
    uint8_t *wbuf; size_t wlen, wcap;   // 请求方向残留
    uint8_t *rbuf; size_t rlen, rcap;   // 响应方向残留
    hp_dyntable preq;   // 请求头动态表
    hp_dyntable presp;  // 响应头动态表
    uint32_t next_sid;  // h1 用的自增流号
    hp_pend pend[HP_PEND_MAX];
};

static void dynt_init(hp_dyntable *d) {
    memset(d, 0, sizeof(*d));
    d->max = 4096;
}

static void dynt_clear(hp_dyntable *d) {
    for (int i = 0; i < d->cnt; i++) {
        free(d->e[i].n);
        free(d->e[i].v);
    }
    d->cnt = 0;
    d->sz = 0;
}

static void dynt_add(hp_dyntable *d, const char *n, const char *v) {
    if (!n) n = "";
    if (!v) v = "";
    size_t sz = strlen(n) + strlen(v) + 32;
    // 超出上限时按 RFC 逐出最旧的
    while (d->cnt > 0 && d->sz + sz > d->max) {
        d->cnt--;
        d->sz -= d->e[d->cnt].sz;
        free(d->e[d->cnt].n);
        free(d->e[d->cnt].v);
        d->e[d->cnt].n = d->e[d->cnt].v = NULL;
    }
    if (sz > d->max) return;
    if (d->cnt >= HP_DYN_MAX) {
        d->cnt--;
        d->sz -= d->e[d->cnt].sz;
        free(d->e[d->cnt].n);
        free(d->e[d->cnt].v);
    }
    // 队首插入(索引 0 是最新)
    memmove(&d->e[1], &d->e[0], sizeof(hp_ent) * (size_t)d->cnt);
    d->e[0].n = strdup(n);
    d->e[0].v = strdup(v);
    d->e[0].sz = sz;
    d->cnt++;
    d->sz += sz;
}

static const char *hp_lookup_name(hp_dyntable *d, uint32_t idx) {
    if (idx == 0) return NULL;
    if (idx <= 61) return kHpName[idx];
    uint32_t i = idx - 62;
    if ((int)i < d->cnt) return d->e[i].n;
    return NULL;
}

static const char *hp_lookup_val(hp_dyntable *d, uint32_t idx) {
    if (idx == 0) return NULL;
    if (idx <= 61) return kHpVal[idx];
    uint32_t i = idx - 62;
    if ((int)i < d->cnt) return d->e[i].v;
    return NULL;
}

// ---------------------------------------------------------------- HPACK

static int hp_int(const uint8_t *b, size_t n, size_t *pos, int prefix, uint32_t *out) {
    if (*pos >= n) return -1;
    uint32_t mask = (1u << prefix) - 1;
    uint32_t v = b[*pos] & mask;
    (*pos)++;
    if (v < mask) { *out = v; return 0; }

    int shift = 0;
    while (*pos < n) {
        uint8_t c = b[*pos];
        (*pos)++;
        v += (uint32_t)(c & 0x7F) << shift;
        shift += 7;
        if (!(c & 0x80)) { *out = v; return 0; }
        if (shift > 28) return -1;
    }
    return -1;
}

static int hp_str(const uint8_t *b, size_t n, size_t *pos, char **out) {
    if (*pos >= n) return -1;
    int huff = (b[*pos] & 0x80) != 0;
    uint32_t len = 0;
    if (hp_int(b, n, pos, 7, &len) < 0) return -1;
    if (len > n || *pos + len > n) return -1;

    if (huff) {
        size_t ol = 0;
        if (huff_decode(b + *pos, len, out, &ol) < 0) {
            // Huffman 解不出来时退化成原字节
            char *p = (char *)malloc(len + 1);
            if (!p) return -1;
            memcpy(p, b + *pos, len);
            p[len] = 0;
            *out = p;
        }
    } else {
        char *p = (char *)malloc(len + 1);
        if (!p) return -1;
        memcpy(p, b + *pos, len);
        p[len] = 0;
        *out = p;
    }
    *pos += len;
    return 0;
}

// 追加 "name: value\n" 到头字符串
static void hdr_append(char **acc, const char *n, const char *v) {
    size_t an = *acc ? strlen(*acc) : 0;
    size_t nn = n ? strlen(n) : 0;
    size_t vn = v ? strlen(v) : 0;
    char *p = (char *)realloc(*acc, an + nn + vn + 4);
    if (!p) return;
    if (!*acc) p[0] = 0;
    memcpy(p + an, n ? n : "", nn);
    p[an + nn] = ':';
    p[an + nn + 1] = ' ';
    memcpy(p + an + nn + 2, v ? v : "", vn);
    p[an + nn + 2 + vn] = '\n';
    p[an + nn + 3 + vn] = 0;
    *acc = p;
}

// 解码一个 HPACK 头块。req=true 用请求动态表。
static int hpack_decode(hp_dyntable *d, const uint8_t *b, size_t n,
                        char **headers, char **method, char **path, char **host,
                        int *status) {
    size_t pos = 0;
    while (pos < n) {
        uint8_t c = b[pos];

        if (c & 0x80) {                       // 索引
            uint32_t idx = 0;
            if (hp_int(b, n, &pos, 7, &idx) < 0) return -1;
            const char *nm = hp_lookup_name(d, idx);
            const char *vl = hp_lookup_val(d, idx);
            if (!nm) continue;
            if (nm[0] == ':') {
                if (!strcmp(nm, ":method") && method) { free(*method); *method = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":path") && path) { free(*path); *path = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":authority") && host) { free(*host); *host = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":status") && status) { *status = vl ? atoi(vl) : 0; }
            } else {
                hdr_append(headers, nm, vl);
            }
        } else if ((c & 0xC0) == 0x40) {       // 字面量,增量索引
            uint32_t idx = 0;
            if (hp_int(b, n, &pos, 6, &idx) < 0) return -1;
            char *nm = NULL, *vl = NULL;
            const char *nmr = hp_lookup_name(d, idx);
            if (nmr) nm = strdup(nmr);
            else if (hp_str(b, n, &pos, &nm) < 0) return -1;
            if (hp_str(b, n, &pos, &vl) < 0) { free(nm); return -1; }
            dynt_add(d, nm, vl);
            if (nm && nm[0] == ':') {
                if (!strcmp(nm, ":method") && method) { free(*method); *method = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":path") && path) { free(*path); *path = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":authority") && host) { free(*host); *host = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":status") && status) { *status = vl ? atoi(vl) : 0; }
            } else if (nm) {
                hdr_append(headers, nm, vl);
            }
            free(nm); free(vl);
        } else if ((c & 0xE0) == 0x20) {       // 动态表大小更新
            uint32_t sz = 0;
            if (hp_int(b, n, &pos, 5, &sz) < 0) return -1;
            d->max = sz;
        } else {                                // 字面量不索引 / 从不索引
            uint32_t idx = 0;
            if (hp_int(b, n, &pos, 4, &idx) < 0) return -1;
            char *nm = NULL, *vl = NULL;
            const char *nmr = hp_lookup_name(d, idx);
            if (nmr) nm = strdup(nmr);
            else if (hp_str(b, n, &pos, &nm) < 0) return -1;
            if (hp_str(b, n, &pos, &vl) < 0) { free(nm); return -1; }
            if (nm && nm[0] == ':') {
                if (!strcmp(nm, ":method") && method) { free(*method); *method = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":path") && path) { free(*path); *path = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":authority") && host) { free(*host); *host = strdup(vl ? vl : ""); }
                else if (!strcmp(nm, ":status") && status) { *status = vl ? atoi(vl) : 0; }
            } else if (nm) {
                hdr_append(headers, nm, vl);
            }
            free(nm); free(vl);
        }
    }
    return 0;
}

// ---------------------------------------------------------------- 缓冲工具

static void buf_append(uint8_t **buf, size_t *len, size_t *cap,
                       const uint8_t *data, size_t n) {
    if (*len + n > *cap) {
        size_t nc = *cap ? *cap : 4096;
        while (nc < *len + n) nc *= 2;
        uint8_t *p = (uint8_t *)realloc(*buf, nc);
        if (!p) return;
        *buf = p;
        *cap = nc;
    }
    memcpy(*buf + *len, data, n);
    *len += n;
}

static void buf_consume(uint8_t **buf, size_t *len, size_t n) {
    if (n >= *len) { *len = 0; return; }
    memmove(*buf, *buf + n, *len - n);
    *len -= n;
}

void hp_msg_free(hp_msg_t *m) {
    if (!m) return;
    free(m->method);
    free(m->path);
    free(m->host);
    free(m->headers);
    free(m->body);
    memset(m, 0, sizeof(*m));
}

// ---------------------------------------------------------------- HTTP/1.1

// 找 "\r\n\r\n",返回头部结束位置(含),找不到返回 0
static size_t find_hdr_end(const uint8_t *b, size_t n) {
    for (size_t i = 0; i + 3 < n; i++) {
        if (b[i] == '\r' && b[i+1] == '\n' && b[i+2] == '\r' && b[i+3] == '\n')
            return i + 4;
    }
    return 0;
}

static long hdr_get_long(const char *h, const char *name) {
    // 简单不区分大小写查找
    size_t nl = strlen(name);
    const char *p = h;
    while (p && *p) {
        const char *e = strchr(p, '\n');
        if (!e) break;
        int match = 1;
        for (size_t i = 0; i < nl; i++) {
            char c = p[i];
            if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            char d = name[i];
            if (d >= 'A' && d <= 'Z') d = (char)(d - 'A' + 'a');
            if (c != d) { match = 0; break; }
        }
        if (match && p[nl] == ':') {
            const char *v = p + nl + 1;
            while (*v == ' ') v++;
            return strtol(v, NULL, 10);
        }
        p = e + 1;
    }
    return -1;
}

static char *hdr_get_str(const char *h, const char *name) {
    size_t nl = strlen(name);
    const char *p = h;
    while (p && *p) {
        const char *e = strchr(p, '\n');
        if (!e) break;
        int match = 1;
        for (size_t i = 0; i < nl; i++) {
            char c = p[i];
            if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            char d = name[i];
            if (d >= 'A' && d <= 'Z') d = (char)(d - 'A' + 'a');
            if (c != d) { match = 0; break; }
        }
        if (match && p[nl] == ':') {
            const char *v = p + nl + 1;
            while (*v == ' ') v++;
            size_t vn = (size_t)(e - v);
            while (vn > 0 && (v[vn-1] == '\r' || v[vn-1] == ' ')) vn--;
            char *r = (char *)malloc(vn + 1);
            if (!r) return NULL;
            memcpy(r, v, vn);
            r[vn] = 0;
            return r;
        }
        p = e + 1;
    }
    return NULL;
}

// chunked 解码。返回解出的 body(malloc),失败返回 NULL
static uint8_t *dechunk(const uint8_t *b, size_t n, size_t *outlen) {
    size_t cap = n + 16, ol = 0;
    uint8_t *o = (uint8_t *)malloc(cap);
    if (!o) return NULL;
    size_t pos = 0;
    while (pos < n) {
        size_t e = pos;
        while (e + 1 < n && !(b[e] == '\r' && b[e+1] == '\n')) e++;
        if (e + 1 >= n) break;
        char tmp[16] = {0};
        size_t tl = e - pos < 15 ? e - pos : 15;
        memcpy(tmp, b + pos, tl);
        long sz = strtol(tmp, NULL, 16);
        pos = e + 2;
        if (sz <= 0) break;
        if (pos + (size_t)sz > n) break;
        if (ol + (size_t)sz > cap) { cap = ol + (size_t)sz + 16; o = (uint8_t *)realloc(o, cap); }
        memcpy(o + ol, b + pos, (size_t)sz);
        ol += (size_t)sz;
        pos += (size_t)sz;
        if (pos + 1 < n && b[pos] == '\r' && b[pos+1] == '\n') pos += 2;
    }
    *outlen = ol;
    return o;
}

// 解析 h1。返回消费字节数,0 表示数据不够
static size_t parse_h1(hp_conn_t *c, int dir, const uint8_t *b, size_t n,
                       void *ctx, hp_cb cb) {
    size_t hend = find_hdr_end(b, n);
    if (!hend) return 0;

    char *heads = (char *)malloc(hend + 1);
    if (!heads) return 0;
    memcpy(heads, b, hend);
    heads[hend] = 0;

    // 首行
    char *nl = strchr(heads, '\n');
    if (!nl) { free(heads); return 0; }
    char *first = heads;
    char saved = *nl;
    *nl = 0;

    hp_msg_t m;
    memset(&m, 0, sizeof(m));
    m.is_request = dir == 0;
    m.proto = 1;

    if (dir == 0) {
        // METHOD SP path SP version
        char *sp1 = strchr(first, ' ');
        if (!sp1) { *nl = saved; free(heads); return 0; }
        *sp1 = 0;
        m.method = strdup(first);
        char *sp2 = strchr(sp1 + 1, ' ');
        if (sp2) *sp2 = 0;
        m.path = strdup(sp1 + 1);
    } else {
        // HTTP/1.1 200 OK
        char *sp1 = strchr(first, ' ');
        if (sp1) m.status = atoi(sp1 + 1);
    }
    *nl = saved;

    // 头
    char *rest = nl + 1;
    char *acc = NULL;
    char *p = rest;
    while (p && *p) {
        char *e = strchr(p, '\n');
        if (!e) break;
        char sv = *e;
        *e = 0;
        size_t ln = strlen(p);
        if (ln > 0 && p[ln-1] == '\r') p[ln-1] = 0;
        if (*p) {
            char *colon = strchr(p, ':');
            if (colon) {
                *colon = 0;
                const char *v = colon + 1;
                while (*v == ' ') v++;
                hdr_append(&acc, p, v);
                *colon = ':';
            }
        }
        *e = sv;
        p = e + 1;
        if (p && (*p == '\r' || *p == 0)) break;
    }
    m.headers = acc;

    if (dir == 0) {
        m.host = hdr_get_str(heads, "host");
        if (!m.host) m.host = hdr_get_str(heads, ":authority");
    }

    // body
    size_t consumed = hend;
    long clen = hdr_get_long(heads, "content-length");
    char *te = hdr_get_str(heads, "transfer-encoding");
    int chunked = te && strstr(te, "chunked");
    free(te);

    if (chunked) {
        // 找 0\r\n\r\n 结尾
        size_t i = hend;
        while (i + 4 < n) {
            if (b[i] == '0' && b[i+1] == '\r' && b[i+2] == '\n' && b[i+3] == '\r') {
                size_t total = i + 5;
                if (total <= n) {
                    size_t ol = 0;
                    m.body = dechunk(b + hend, total - hend, &ol);
                    m.body_len = ol;
                    consumed = total;
                }
                break;
            }
            i++;
        }
    } else if (clen > 0) {
        if (hend + (size_t)clen <= n) {
            m.body = (uint8_t *)malloc((size_t)clen);
            if (m.body) {
                memcpy(m.body, b + hend, (size_t)clen);
                m.body_len = (size_t)clen;
            }
            consumed = hend + (size_t)clen;
        }
    }

    m.stream_id = c->next_sid++;
    if (cb) cb(ctx, &m);
    hp_msg_free(&m);
    free(heads);
    return consumed;
}

// ---------------------------------------------------------------- HTTP/2

#define H2_HEADERS 0x1
#define H2_DATA    0x0
#define H2_CONT    0x9

static void h2_emit(hp_conn_t *c, int dir, uint32_t sid,
                    const uint8_t *hblk, size_t hblen,
                    const uint8_t *body, size_t blen,
                    void *ctx, hp_cb cb) {
    hp_msg_t m;
    memset(&m, 0, sizeof(m));
    m.is_request = dir == 0;
    m.stream_id = sid;
    m.proto = 2;

    char *hdrs = NULL;
    hpack_decode(dir == 0 ? &c->preq : &c->presp, hblk, hblen, &hdrs,
                 &m.method, &m.path, &m.host,
                 dir == 1 ? &m.status : NULL);
    m.headers = hdrs;

    if (blen) {
        m.body = (uint8_t *)malloc(blen);
        if (m.body) { memcpy(m.body, body, blen); m.body_len = blen; }
    }

    if (cb) cb(ctx, &m);
    hp_msg_free(&m);
}

static hp_pend *pend_find(hp_conn_t *c, uint32_t sid, int dir) {
    for (int i = 0; i < HP_PEND_MAX; i++) {
        if (c->pend[i].used && c->pend[i].sid == sid && c->pend[i].dir == dir)
            return &c->pend[i];
    }
    return NULL;
}

static hp_pend *pend_new(hp_conn_t *c, uint32_t sid, int dir) {
    hp_pend *p = pend_find(c, sid, dir);
    if (p) { p->len = 0; return p; }
    for (int i = 0; i < HP_PEND_MAX; i++) {
        if (!c->pend[i].used) {
            memset(&c->pend[i], 0, sizeof(hp_pend));
            c->pend[i].used = 1;
            c->pend[i].sid = sid;
            c->pend[i].dir = dir;
            return &c->pend[i];
        }
    }
    // 槽满了,复用第 0 个
    memset(&c->pend[0], 0, sizeof(hp_pend));
    c->pend[0].used = 1;
    c->pend[0].sid = sid;
    c->pend[0].dir = dir;
    return &c->pend[0];
}

static void pend_release(hp_pend *p) {
    if (!p) return;
    p->used = 0;
    p->len = 0;
}

// 解析 h2 帧流。返回消费字节数。
static size_t parse_h2(hp_conn_t *c, int dir, const uint8_t *b, size_t n,
                       void *ctx, hp_cb cb) {
    static const char PREFACE[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    size_t off = 0;
    if (n >= 24 && !memcmp(b, PREFACE, 24)) off = 24;

    size_t consumed = off;
    while (n - off >= 9) {
        uint32_t len = ((uint32_t)b[off] << 16) | ((uint32_t)b[off+1] << 8) | b[off+2];
        uint8_t type = b[off+3];
        uint8_t flags = b[off+4];
        uint32_t sid = (((uint32_t)b[off+5] & 0x7F) << 24) |
                       ((uint32_t)b[off+6] << 16) |
                       ((uint32_t)b[off+7] << 8) | b[off+8];
        if (off + 9 + len > n) break;

        const uint8_t *pl = b + off + 9;

        if (type == H2_HEADERS) {
            size_t p = 0;
            size_t blen = len;
            if (flags & 0x8) {            // PADDED
                size_t pad = pl[0];
                p = 1;
                if (blen > pad + 1) blen -= pad + 1; else blen = 0;
            }
            if (flags & 0x20) { p += 5; if (blen > 5) blen -= 5; else blen = 0; }

            hp_pend *pd = pend_new(c, sid, dir);
            if (pd && p + blen <= len) {
                buf_append(&pd->buf, &pd->len, &pd->cap, pl + p, blen);
            }

            if (flags & 0x4) {            // END_HEADERS
                if ((flags & 0x1) && pd) {   // 同时 END_STREAM:没有 body
                    h2_emit(c, dir, sid, pd->buf, pd->len, NULL, 0, ctx, cb);
                    pend_release(pd);
                }
                // 否则等 DATA 帧一起发
            }
        } else if (type == H2_CONT) {
            hp_pend *pd = pend_find(c, sid, dir);
            if (pd) buf_append(&pd->buf, &pd->len, &pd->cap, pl, len);
            if ((flags & 0x4) && pd && (flags & 0x1)) {
                h2_emit(c, dir, sid, pd->buf, pd->len, NULL, 0, ctx, cb);
                pend_release(pd);
            }
        } else if (type == H2_DATA) {
            size_t p = 0;
            size_t blen = len;
            if (flags & 0x8) { p = 1 + pl[0]; if (p > len) p = len; blen = len - p; }

            hp_pend *pd = pend_find(c, sid, dir);
            if (pd) {
                h2_emit(c, dir, sid, pd->buf, pd->len, pl + p, blen, ctx, cb);
                pend_release(pd);
            } else if (blen > 0) {
                // 没有对应 HEADERS(已发过),单发 body
                h2_emit(c, dir, sid, NULL, 0, pl + p, blen, ctx, cb);
            }
        } else if (type == 0x3) {         // RST_STREAM
            hp_pend *pd = pend_find(c, sid, dir);
            if (pd) pend_release(pd);
        }

        off += 9 + len;
        consumed = off;
    }
    return consumed;
}

// ---------------------------------------------------------------- 对外

hp_conn_t *hp_conn_new(void) {
    hp_conn_t *c = (hp_conn_t *)calloc(1, sizeof(hp_conn_t));
    if (!c) return NULL;
    dynt_init(&c->preq);
    dynt_init(&c->presp);
    return c;
}

void hp_conn_free(hp_conn_t *c) {
    if (!c) return;
    free(c->wbuf);
    free(c->rbuf);
    for (int i = 0; i < HP_PEND_MAX; i++) free(c->pend[i].buf);
    dynt_clear(&c->preq);
    dynt_clear(&c->presp);
    free(c);
}

void hp_feed(hp_conn_t *c, int dir, const uint8_t *data, size_t len,
             void *ctx, hp_cb cb) {
    if (!c || !data || !len) return;

    uint8_t **buf = dir ? &c->rbuf : &c->wbuf;
    size_t *blen = dir ? &c->rlen : &c->wlen;
    size_t *bcap = dir ? &c->rcap : &c->wcap;

    buf_append(buf, blen, bcap, data, len);
    if (!*buf) return;

    // 首包判协议
    if (!c->decided && *blen >= 4) {
        if (*blen >= 24 && !memcmp(*buf, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 24)) {
            c->decided = 2;
        } else if (!memcmp(*buf, "HTTP", 4) ||
                   (isalpha((*buf)[0]) && (*buf)[1] == ' ')) {
            c->decided = 1;
        } else {
            // 数据不足或未知,先按 h2 试(有 9 字节帧头就当 h2)
            if (*blen >= 9) c->decided = 2;
        }
    }
    if (!c->decided) return;

    if (c->decided == 1) {
        while (*blen > 0) {
            size_t u = parse_h1(c, dir, *buf, *blen, ctx, cb);
            if (!u) break;
            buf_consume(buf, blen, u);
        }
    } else {
        size_t u = parse_h2(c, dir, *buf, *blen, ctx, cb);
        if (u) buf_consume(buf, blen, u);
    }

    // 缓冲上限保护:长时间收不到完整消息就丢弃,防止内存无限涨
    if (*blen > (2u << 20)) buf_consume(buf, blen, *blen);
}
