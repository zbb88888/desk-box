// Desk Box guest C parser fuzz harness（M4，本机 Clang ASAN+UBSAN）。
//
// 与 macos/scripts/guest-bootstrap.c 同语义（为避免拖上 Linux-only 头/sodium，
// 此处复制同型号的纯字符串解析函数；发现偏差时两边同步修复）。
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

static int parse_small_int(const char *json, const char *field, unsigned fallback) {
    const char *p = strstr(json, field);
    if (!p) return fallback;
    const char *c = strchr(p, ':');
    if (!c) return fallback;
    c++;
    while (*c == ' ' || *c == '\t') c++;
    unsigned long value = 0;
    int digits = 0;
    while (*c >= '0' && *c <= '9' && digits < 5) { value = value * 10 + (unsigned)(*c - '0'); c++; digits++; }
    if (digits == 0) return fallback;
    return (unsigned)value;
}

static int hex_to_bin(const char *hex, size_t hex_digits, uint8_t *out, size_t out_cap) {
    if (hex_digits % 2 != 0 || out_cap < hex_digits / 2) return -1;
    for (size_t i = 0; i < hex_digits / 2; i++) {
        char buf[3] = {hex[i * 2], hex[i * 2 + 1], 0};
        char *end = NULL;
        uint16_t v = (uint16_t)strtoul(buf, &end, 16);
        if (end == buf || *end != 0 || v > 255) return -2;
        out[i] = (uint8_t)v;
    }
    return 0;
}

static int extract_hex_field(const char *json, const char *field, uint8_t *out, size_t cap) {
    const char *p = strstr(json, field);
    if (!p) return -1;
    const char *c = strchr(p, ':');
    if (!c) return -2;
    c++;
    while (*c == ' ' || *c == '\t') c++;
    if (*c != '"') return -3;
    c++;
    size_t span = strcspn(c, "\"");
    if (span % 2 != 0) return -4;
    if (span / 2 > cap) return -5;
    if (hex_to_bin(c, span, out, cap) != 0) return -6;
    return (int)(span / 2);
}

static int ws_extract_string(const char *json, const char *field, char *out, size_t cap) {
    const char *p = strstr(json, field);
    if (!p) return -1;
    const char *c = strchr(p, ':');
    if (!c) return -2;
    c++;
    while (*c == ' ' || *c == '\t') c++;
    if (*c != '"') return -3;
    c++;
    size_t w = 0;
    while (*c && *c != '"') {
        char v = *c;
        if (v == '\\' && c[1] != 0) { c++; v = *c; }
        if (w + 1 >= cap) return -4;
        out[w++] = v;
        c++;
    }
    if (*c != '"') return -5;
    if (w == 0) return -6;
    out[w] = 0;
    return (int)w;
}

static unsigned long long ws_extract_u64(const char *json, const char *field, unsigned long long fallback) {
    const char *p = strstr(json, field);
    if (!p) return fallback;
    const char *c = strchr(p, ':');
    if (!c) return fallback;
    c++;
    while (*c == ' ' || *c == '\t') c++;
    unsigned long long value = 0;
    int digits = 0;
    while (*c >= '0' && *c <= '9' && digits < 20) { value = value * 10 + (unsigned long long)(*c - '0'); c++; digits++; }
    if (digits == 0) return fallback;
    return value;
}

static int parse_argv(const char *json, char **argv, int max_argv, char *storage, size_t storage_cap) {
    const char *key = strstr(json, "\"argv\"");
    if (!key) return -1;
    const char *open = strchr(key, '[');
    if (!open) return -1;
    const char *close = NULL;
    int in_quote = 0;
    for (const char *q = open; *q; q++) {
        if (*q == '\\' && q[1]) { q++; continue; }
        if (*q == '"') { in_quote = !in_quote; continue; }
        if (*q == ']' && !in_quote) { close = q; break; }
    }
    if (!close) return -1;
    int argc = 0;
    size_t used = 0;
    const char *p = open + 1;
    while (p < close && argc < max_argv - 1) {
        while (p < close && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
        if (p >= close || *p != '"') break;
        p++;
        char *dst = storage + used;
        size_t len = 0;
        while (p < close && *p != '"' && len + 1 < storage_cap - used) {
            if (*p == '\\' && p + 1 < close) p++;
            *dst = *p; dst++; len++; p++;
        }
        if (p >= close || *p != '"') return -2;
        p++;
        *dst = 0;
        used += len + 1;
        argv[argc++] = storage + used - len - 1;
    }
    if (argc == 0) return -3;
    argv[argc] = NULL;
    return argc;
}

static void fuzz(const char *input) {
    char storage[1024];
    char *argv[32];
    memset(storage, 0xA5, sizeof(storage));
    (void)parse_argv(input, argv, 32, storage, sizeof(storage));

    uint8_t hexout[2048];
    memset(hexout, 0x5A, sizeof(hexout));
    (void)extract_hex_field(input, "\"dataHex\"", hexout, sizeof(hexout));
    (void)extract_hex_field(input, "\"x\"", hexout, sizeof(hexout));

    char strbuf[256];
    memset(strbuf, 0xFF, sizeof(strbuf));
    (void)ws_extract_string(input, "\"path\"", strbuf, sizeof(strbuf));
    (void)ws_extract_string(input, "\"wsId\"", strbuf, sizeof(strbuf));

    (void)ws_extract_u64(input, "\"totalBytes\"", 0);
    (void)ws_extract_u64(input, "\"offset\"", 0);
    (void)ws_extract_u64(input, "\"reqId\"", 0);
    (void)parse_small_int(input, "\"mode\"", 0644);
    (void)parse_small_int(input, "\"fileCount\"", 0);
    (void)parse_small_int(input, "\"rows\"", 24);
}

int main(void) {
    static const char *corpus[] = {
        "{}", "[]", "\"\"",
        "{\"argv\":[]}", "{\"argv\":[\"x\"]}", "{\"argv\":[\"\\u0000\"]}",
        "{\"argv\":[\"a\\u0001\"]}", "{\"argv\":[\"\\\"/\\\"\"]}",
        "{\"dataHex\":\"zz\"}", "{\"dataHex\":\"0\"}",
        "{\"dataHex\":\"00\"}", "{\"dataHex\":\"0f0fff\"}",
        "{\"path\":\"../x\"}", "{\"path\":\"/etc\"}", "{\"path\":\"a/./b\"}",
        "{\"path\":\"./a\"}", "{\"path\":\"a\"}",
        "{\"wsId\":\"\"}", "{\"wsId\":\"ABC\"}",
        "{\"reqId\":9999999999999}", "{\"reqId\":-1}",
        "{\"totalBytes\":9223372036854775808}",
        "{\"mode\":\"0644\"}", "{\"rows\":\"24\",\"cols\":\"80\"}",
        "{\"offset\":\"abc\"}", "{\"fileCount\":\"-1\"}",
        "{\"curl\":\"https://example.com\"}",
        "{\"argv\":[\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"]}",
        "{\"dataHex\":\"6e65756c6e65756c6e65756c6e65756c6e65756c\"}",
        "{\"\\u0000\":\"x\"}",
        "{\"x\":\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"",
    };
    enum { N = sizeof(corpus) / sizeof(corpus[0]) };
    static char mutation[1024];
    for (int round = 0; round < 20000; round++) {
        unsigned seed = 0x9e3779b9u ^ (unsigned)round * 2654435761u;
        for (int i = 0; i < N; i++) {
            const char *base = corpus[i];
            size_t bl = strlen(base);
            memset(mutation, 0, sizeof(mutation));
            if (bl > sizeof(mutation) - 1) bl = sizeof(mutation) - 1;
            memcpy(mutation, base, bl);
            unsigned long m = seed + (unsigned long)i * 31;
            int flips = 1 + (int)(m % 8);
            for (int f = 0; f < flips; f++) {
                if (bl == 0) break;
                size_t pos = (size_t)(m % bl);
                char v = (char)((m >> 3) & 0xff);
                mutation[pos] = (v == 0) ? ' ' : v;
                m = m * 6364136223846793005UL + 1442695040888963407UL;
            }
            mutation[sizeof(mutation) - 1] = 0;
            fuzz(mutation);
        }
    }
    fprintf(stderr, "fuzz complete (no ASAN/UBSAN taint)\n");
    return 0;
}
