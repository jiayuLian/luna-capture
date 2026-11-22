//
//  http_parse.h
//  TLS 明文流的 HTTP/1.1 与 HTTP/2 解析。
//
//  SSL_read / SSL_write 给到的是应用层字节,协议未知:
//  可能是 HTTP/1.1,也可能是 HTTP/2(前面有 "PRI * HTTP/2.0" 前言)。
//  这里两条都解,自动判别。
//
#ifndef HTTP_PARSE_H
#define HTTP_PARSE_H

#include <stdint.h>
#include <stddef.h>

typedef struct hp_conn hp_conn_t;

// 一条完整消息(请求或响应)
typedef struct {
    int      is_request;
    char    *method;      // 请求方法,响应为 NULL
    char    *path;        // 含 query
    char    *host;        // :authority 或 Host 头
    int      status;      // 响应状态码,请求为 0
    char    *headers;     // 每行 "name: value\n",已拼好
    uint8_t *body;        // malloc 出来的,调用方负责 free
    size_t   body_len;
    uint32_t stream_id;   // h2 流号;h1 用自增序号
    int      proto;       // 1=HTTP/1.1  2=HTTP/2
} hp_msg_t;

// 完整消息回调
typedef void (*hp_cb)(void *ctx, const hp_msg_t *msg);

hp_conn_t *hp_conn_new(void);
void       hp_conn_free(hp_conn_t *c);

// dir: 0 = 请求方向(SSL_write),1 = 响应方向(SSL_read)
// 内部会累积不足一条消息的残余字节
void hp_feed(hp_conn_t *c, int dir, const uint8_t *data, size_t len,
             void *ctx, hp_cb cb);

void hp_msg_free(hp_msg_t *m);

#endif
