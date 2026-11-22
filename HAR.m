#import "LunaCapture.h"

static NSString *LCISO(NSDate *d) {
    if (!d) return @"";
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
        f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [f stringFromDate:d];
}

static NSArray *LCHdr(NSDictionary *h) {
    NSMutableArray *a = [NSMutableArray array];
    [h enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        [a addObject:@{@"name": [k description], @"value": [v description]}];
    }];
    return a;
}

static NSArray *LCQuery(NSURL *u) {
    NSMutableArray *a = [NSMutableArray array];
    if (!u) return a;
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *q in c.queryItems) {
        [a addObject:@{@"name": q.name ?: @"", @"value": q.value ?: @""}];
    }
    return a;
}

@implementation LCCapture (HAR)

- (NSDictionary *)buildHAR {
    NSArray<LCRecord *> *recs = [self snapshot];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:recs.count];

    for (LCRecord *r in recs) {
        double ms = [r.end timeIntervalSinceDate:r.start] * 1000.0;
        if (ms < 0) ms = 0;

        NSUInteger reqLen = r.reqBody.length
            ? [r.reqBody dataUsingEncoding:NSUTF8StringEncoding].length : 0;

        NSMutableDictionary *req = [@{
            @"method": r.method ?: @"GET",
            @"url": r.url ?: @"",
            @"httpVersion": @"HTTP/1.1",
            @"headers": LCHdr(r.reqHeaders),
            @"queryString": LCQuery([NSURL URLWithString:r.url ?: @""]),
            @"cookies": @[],
            @"headersSize": @(-1),
            @"bodySize": @(reqLen)
        } mutableCopy];
        if (r.reqBody.length) {
            req[@"postData"] = @{
                @"mimeType": @"application/x-www-form-urlencoded",
                @"text": r.reqBody
            };
        }

        NSMutableDictionary *content = [@{
            @"size": @(r.respBody.length),
            @"mimeType": r.mime ?: @"application/json"
        } mutableCopy];
        if (r.respBody.length) {
            content[@"text"] = r.respBody;
            if (r.respIsBase64) content[@"encoding"] = @"base64";
        }

        NSDictionary *resp = @{
            @"status": @(r.status),
            @"statusText": @"",
            @"httpVersion": @"HTTP/1.1",
            @"headers": LCHdr(r.respHeaders),
            @"cookies": @[],
            @"content": content,
            @"redirectURL": @"",
            @"headersSize": @(-1),
            @"bodySize": @(r.respBody.length)
        };

        [entries addObject:@{
            @"startedDateTime": LCISO(r.start),
            @"time": @(ms),
            @"request": req,
            @"response": resp,
            @"cache": @{},
            @"timings": @{@"send": @0, @"wait": @(ms), @"receive": @0},
            @"_source": r.source ?: @""
        }];
    }

    return @{
        @"log": @{
            @"version": @"1.2",
            @"creator": @{@"name": @"LunaCapture", @"version": LC_VER},
            @"entries": entries
        }
    };
}

- (NSString *)docPath:(NSString *)name {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    return [doc stringByAppendingPathComponent:name];
}

- (NSString *)exportHAR {
    NSDictionary *har = [self buildHAR];
    NSData *d = [NSJSONSerialization dataWithJSONObject:har
                                                options:NSJSONWritingPrettyPrinted
                                                  error:nil];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"luna_%@.har",
                      [f stringFromDate:[NSDate date]]];
    NSString *p = [self docPath:name];
    [d writeToFile:p atomically:YES];
    NSLog(@"[LC] HAR -> %@ (%lu bytes)", p, (unsigned long)d.length);
    return p;
}

- (NSString *)exportJSON {
    NSDictionary *har = [self buildHAR];
    NSData *d = [NSJSONSerialization dataWithJSONObject:har
                                                options:NSJSONWritingPrettyPrinted
                                                  error:nil];
    NSString *name = [NSString stringWithFormat:@"luna_%lu.json",
                      (unsigned long)[[NSDate date] timeIntervalSince1970]];
    NSString *p = [self docPath:name];
    [d writeToFile:p atomically:YES];
    return p;
}

@end
