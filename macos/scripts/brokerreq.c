// Desk Box broker request client（M2-3b）。
// Usage: brokerreq <url>
// 将 "GET <url>\n" 通过 AF_UNIX socket /run/deskbox-broker.sock 请求宿主 broker。
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
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
    /* 等价同步；socket 写完就读取结果（fork 提供多连接可能只需要摊商）。 */
    char resp[64];
    ssize_t r = read(fd, resp, sizeof(resp) - 1);
    close(fd);
    if (r <= 0) { fputs("no reply\n", stderr); return 7; }
    resp[r] = 0;
    if (strncmp(resp, "OK", 2) == 0) {
        return 0;
    }
    fputs(resp, stderr);
    return 8;
}
