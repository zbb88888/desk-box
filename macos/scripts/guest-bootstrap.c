#include <errno.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint16_t be16(uint16_t x) { return (uint16_t)((x >> 8) | (x << 8)); }
static uint32_t be32(uint32_t x) { return __builtin_bswap32(x); }
static uint64_t be64(uint64_t x) { return __builtin_bswap64(x); }

static const char *arg(const char *cmd, const char *key) {
    static char value[256];
    const char *p = strstr(cmd, key);
    if (!p) return NULL;
    p += strlen(key);
    size_t n = strcspn(p, " \n\r\t");
    if (n >= sizeof(value)) return NULL;
    memcpy(value, p, n); value[n] = 0;
    return value;
}

int main(void) {
    char cmd[4096] = {0};
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f || !fgets(cmd, sizeof(cmd), f)) return 2;
    if (f) fclose(f);
    const char *sandbox = arg(cmd, "dbx.sandbox=");
    const char *boot = arg(cmd, "dbx.boot=");
    const char *nonce = arg(cmd, "dbx.nonce=");
    const char *manifest = arg(cmd, "dbx.manifest=");
    const char *port_s = arg(cmd, "dbx.port=");
    if (!sandbox || !boot || !nonce || !manifest) return 3;
    int port = port_s ? atoi(port_s) : 1024;
    char json[2048];
    int len = snprintf(json, sizeof(json),
        "{\"sandboxID\":{\"raw\":\"%s\"},\"bootID\":{\"raw\":\"%s\"},\"bootNonce\":\"%s\",\"protocolMajor\":1,\"guestManifestDigest\":\"%s\"}",
        sandbox, boot, nonce, manifest);
    if (len <= 0 || (size_t)len >= sizeof(json)) return 4;

    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) return 5;
    struct sockaddr_vm address = {0};
    address.svm_family = AF_VSOCK;
    address.svm_cid = VMADDR_CID_HOST;
    address.svm_port = (unsigned int)port;
    for (int attempt = 0; attempt < 30; attempt++) {
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) break;
        if (attempt == 29) { close(fd); return 6; }
        sleep(1);
    }
    uint8_t frame[4096] = {0};
    size_t total = 40 + (size_t)len;
    uint32_t magic = be32(0x44425831); memcpy(frame, &magic, 4);
    uint16_t version = be16(1), kind = be16(1); memcpy(frame + 4, &version, 2); memcpy(frame + 6, &kind, 2);
    uint64_t sequence = be64(1); memcpy(frame + 8, &sequence, 8);
    uint32_t plen = be32((uint32_t)len); memcpy(frame + 36, &plen, 4);
    memcpy(frame + 40, json, (size_t)len);
    size_t sent = 0;
    while (sent < total) { ssize_t n = write(fd, frame + sent, total - sent); if (n <= 0) { close(fd); return 7; } sent += (size_t)n; }
    uint8_t response[4096]; (void)read(fd, response, sizeof(response));
    close(fd);
    return 0;
}
