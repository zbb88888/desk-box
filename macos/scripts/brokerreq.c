// Desk Box broker request client（M2-3b）。
// Usage: brokerreq <url>
// 将 "GET <url>\n" 通过 AF_UNIX socket /run/deskbox-broker.sock 请求宿主 broker，
// 文件落在 /workspace/inbound/<url 的最后一段>。
//
// M43：等到拉取**结束**才返回，退出码反映真实结果：
//   0  成功（stdout 一行：saved <字节数> bytes (HTTP <状态码>)）
//   8  被拒绝或失败（stderr 是原因，例如不在 allowlist、上游非 2xx）
//   7  没有应答 / 等待超时
// 对旧的 guest bootstrap（受理即答 "OK"）同样可用：那时 0 只表示「已受理」。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <errno.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("usage: brokerreq <url>\n", stderr);
        return 2;
    }
    const char *url = argv[1];
    if (strncmp(url, "http", 4) != 0 || strlen(url) > 460) {
        fputs("bad url\n", stderr);
        return 3;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 4; }
    struct sockaddr_un su;
    memset(&su, 0, sizeof(su));
    su.sun_family = AF_UNIX;
    strncpy(su.sun_path, "/run/deskbox-broker.sock", sizeof(su.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&su, sizeof(su)) != 0) { perror("connect"); return 5; }
    char req[768];
    int n = snprintf(req, sizeof(req), "GET %s\n", url);
    if (n <= 0 || write(fd, req, (size_t)n) != n) { perror("write"); close(fd); return 6; }
    /* 应答在拉取结束时才到；宿主一直不应答时不能永远挂着。 */
    struct timeval tv = { .tv_sec = 120, .tv_usec = 0 };
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char resp[400];
    size_t got = 0;
    while (got < sizeof(resp) - 1) {
        ssize_t r = read(fd, resp + got, sizeof(resp) - 1 - got);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) {
            if (got == 0) {
                fputs(r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? "timed out waiting for the broker\n" : "no reply\n", stderr);
                close(fd);
                return 7;
            }
            break;
        }
        got += (size_t)r;
        if (memchr(resp, '\n', got)) break;
    }
    close(fd);
    resp[got] = 0;
    char *nl = strchr(resp, '\n');
    if (nl) *nl = 0;
    if (strncmp(resp, "OK", 2) == 0) {
        long status = 0; unsigned long bytes = 0;
        if (sscanf(resp, "OK %ld %lu", &status, &bytes) == 2) printf("saved %lu bytes (HTTP %ld)\n", bytes, status);
        return 0;
    }
    fprintf(stderr, "%s\n", strncmp(resp, "ERR ", 4) == 0 ? resp + 4 : resp);
    return 8;
}
