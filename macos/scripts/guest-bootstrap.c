#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#ifdef __linux__
#include <linux/vm_sockets.h>
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint16_t be16(uint16_t x) { return (uint16_t)((x >> 8) | (x << 8)); }
static uint32_t be32(uint32_t x) { return __builtin_bswap32(x); }
static uint64_t be64(uint64_t x) { return __builtin_bswap64(x); }

static const char *arg(const char *cmd, const char *key) {
    // Each caller keeps its own static slot; a single shared value buffer makes
    // later parameters overwrite earlier identity fields.
    enum { SLOT_COUNT = 8, SLOT_SIZE = 256 };
    static char slots[SLOT_COUNT][SLOT_SIZE];
    static int next_slot;
    char *value = slots[next_slot++ % SLOT_COUNT];
    const char *p = strstr(cmd, key);
    if (!p) return NULL;
    p += strlen(key);
    size_t n = strcspn(p, " \n\r\t");
    if (n >= SLOT_SIZE) return NULL;
    memcpy(value, p, n); value[n] = 0;
    return value;
}

/** Escape a byte buffer into a JSON string literal (without the quotes). */
static size_t json_escape(const char *in, size_t in_len, char *out, size_t out_cap) {
    size_t o = 0;
    for (size_t i = 0; i < in_len && o + 8 < out_cap; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = (char)c; }
        else if (c == '\n') { out[o++] = '\\'; out[o++] = 'n'; }
        else if (c == '\r') { out[o++] = '\\'; out[o++] = 'r'; }
        else if (c == '\t') { out[o++] = '\\'; out[o++] = 't'; }
        else if (c < 0x20) { o += (size_t)snprintf(out + o, out_cap - o, "\\u%04x", c); }
        else { out[o++] = (char)c; }
    }
    out[o] = 0;
    return o;
}

/**
 * Minimal argv extraction from a ControlRequest JSON payload. Only reads the
 * `argv` array of simple JSON strings; anything unusual yields an error so
 * callers can respond failed instead of guessing.
 * Returns argument count >= 0, or < 0 on parse failure.
 */
static int parse_argv(const char *json, char **argv, int max_argv, char *storage, size_t storage_cap) {
    const char *key = strstr(json, "\"argv\"");
    if (!key) return -1;
    const char *open = strchr(key, '[');
    if (!open) return -1;
    const char *close = strchr(open, ']');
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
        p++; // consume closing quote; whitespace skip covers the comma next
        *dst = 0;
        used += len + 1;
        argv[argc++] = storage + used - len - 1;
    }
    if (argc == 0) return -3;
    argv[argc] = NULL;
    return argc;
}

enum { EXEC_MAX_OUTPUT = 1024 };

/** Best-effort integer extraction for `"timeoutSeconds":N` from request JSON. */
static int parse_timeout_seconds(const char *json) {
    const char *key = strstr(json, "\"timeoutSeconds\"");
    if (!key) return 10;
    const char *p = strchr(key, ':');
    if (!p) return 10;
    p++;
    while (*p == ' ') p++;
    int value = 0;
    while (*p >= '0' && *p <= '9') { value = value * 10 + (*p - '0'); p++; }
    if (value <= 0 || value > 3600) return 10;
    return value;
}

/** Run argv via fork/exec with pipes; fill an exitCode/stdout/stderr JSON. */
static int run_exec_request(const char *request_json, char *response, size_t response_cap) {
    enum { MAX_ARGV = 32 };
    char storage[1024];
    char *argv[MAX_ARGV];
    int argc = parse_argv(request_json, argv, MAX_ARGV, storage, sizeof(storage));
    if (argc <= 0) {
        return snprintf(response, response_cap,
            "{\"exitCode\":-1,\"stdout\":\"\",\"stderr\":\"exec request argv parse failed\"}");
    }

    int out_pipe[2] = {-1, -1}, err_pipe[2] = {-1, -1};
    if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
        return snprintf(response, response_cap,
            "{\"exitCode\":-1,\"stdout\":\"\",\"stderr\":\"pipe failed\"}");
    }
    int timeout_seconds = parse_timeout_seconds(request_json);
    pid_t pid = fork();
    if (pid < 0) {
        return snprintf(response, response_cap,
            "{\"exitCode\":-1,\"stdout\":\"\",\"stderr\":\"fork failed\"}");
    }
    if (pid == 0) {
        // Child: own process group so the parent can kill the whole tree.
        setpgid(0, 0);
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(out_pipe[1]); out_pipe[1] = -1;
    close(err_pipe[1]); err_pipe[1] = -1;

    char out_buf[EXEC_MAX_OUTPUT] = {0};
    char err_buf[EXEC_MAX_OUTPUT] = {0};
    size_t out_len = 0;

    // Bounded wait: check child completion once per 100ms; after the deadline
    // kill the entire process group and reap deterministically.
    int status = 0;
    int timed_out = 1;
    pid_t reaped = 0;
    for (int i = 0; i < timeout_seconds * 10; i++) {
        reaped = waitpid(pid, &status, WNOHANG);
        if (reaped == pid) { timed_out = 0; break; }
        usleep(100000);
    }
    if (timed_out) {
        kill(-pid, SIGKILL);
        (void)waitpid(pid, &status, 0);
    }

    for (;;) {
        ssize_t n = read(out_pipe[0], out_buf + out_len, sizeof(out_buf) - out_len - 1);
        if (n <= 0) break;
        out_len += (size_t)n;
        if (out_len >= sizeof(out_buf) - 1) break;
    }
    out_buf[out_len] = 0;
    char discard[256];
    while (read(out_pipe[0], discard, sizeof(discard)) > 0) {}
    ssize_t n = read(err_pipe[0], err_buf, sizeof(err_buf) - 1);
    if (n > 0) err_buf[n] = 0;
    close(out_pipe[0]); close(err_pipe[0]);

    int exit_code = 0;
    if (timed_out) exit_code = -2;
    else if (WIFEXITED(status)) exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) exit_code = 128 + WTERMSIG(status);
    else exit_code = -1;

    char esc_out[EXEC_MAX_OUTPUT * 3];
    char esc_err[EXEC_MAX_OUTPUT * 3];
    json_escape(out_buf, out_len, esc_out, sizeof(esc_out));
    size_t err_len = err_buf[0] ? strlen(err_buf) : 0;
    json_escape(err_buf, err_len, esc_err, sizeof(esc_err));
    if (timed_out) {
        return snprintf(response, response_cap,
            "{\"exitCode\":%d,\"stdout\":\"%s\",\"stderr\":\"exec timed out; process group killed\"}",
            exit_code, esc_out);
    }
    return snprintf(response, response_cap,
        "{\"exitCode\":%d,\"stdout\":\"%s\",\"stderr\":\"%s\"}",
        exit_code, esc_out, esc_err);
}

static int send_frame_ex(int fd, uint16_t kind, uint64_t sequence,
                         const uint8_t *request_id,
                         const char *payload, size_t len) {
    uint8_t frame[4096] = {0};
    size_t total = 36 + len;
    uint32_t magic = be32(0x44425831); memcpy(frame, &magic, 4);
    uint16_t version = be16(1), k = be16(kind);
    memcpy(frame + 4, &version, 2); memcpy(frame + 6, &k, 2);
    uint64_t seq = be64(sequence); memcpy(frame + 8, &seq, 8);
    if (request_id) memcpy(frame + 16, request_id, 16);
    uint32_t plen = be32((uint32_t)len); memcpy(frame + 32, &plen, 4);
    memcpy(frame + 36, payload, len);
    size_t sent = 0;
    while (sent < total) { ssize_t n = write(fd, frame + sent, total - sent); if (n <= 0) return 7; sent += (size_t)n; }
    return 0;
}

static int send_frame(int fd, uint16_t kind, uint64_t sequence, const char *payload, size_t len) {
    return send_frame_ex(fd, kind, sequence, NULL, payload, len);
}

#ifndef DBX_TEST_NO_MAIN
int main(void) {
    const char *diag = "Desk Box bootstrap: starting\n";
    write(STDOUT_FILENO, diag, strlen(diag));
    fsync(STDOUT_FILENO);
    char cmd[4096] = {0};
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f || !fgets(cmd, sizeof(cmd), f)) return 2;
    if (f) fclose(f);
    const char *sandbox = arg(cmd, "dbx.sandbox=");
    const char *boot = arg(cmd, "dbx.boot=");
    const char *nonce = arg(cmd, "dbx.nonce=");
    const char *manifest = arg(cmd, "dbx.manifest=");
    const char *port_s = arg(cmd, "dbx.port=");
    if (!sandbox || !boot || !nonce || !manifest) {
        const char *msg = "Desk Box bootstrap: missing cmdline identity\n";
        write(STDOUT_FILENO, msg, strlen(msg));
        fsync(STDOUT_FILENO);
        return 3;
    }
    int port = port_s ? atoi(port_s) : 1024;
    char json[2048];
    int len = snprintf(json, sizeof(json),
        "{\"sandboxID\":{\"raw\":\"%s\"},\"bootID\":{\"raw\":\"%s\"},\"bootNonce\":\"%s\",\"protocolMajor\":1,\"guestManifestDigest\":\"%s\"}",
        sandbox, boot, nonce, manifest);
    if (len <= 0 || (size_t)len >= sizeof(json)) return 4;

    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) {
        char msg[96]; int n = snprintf(msg, sizeof(msg), "Desk Box bootstrap: socket errno=%d\n", errno);
        write(STDOUT_FILENO, msg, (size_t)n); fsync(STDOUT_FILENO); return 5;
    }
    struct sockaddr_vm address = {0};
    address.svm_family = AF_VSOCK;
    address.svm_cid = VMADDR_CID_HOST;
    address.svm_port = (unsigned int)port;
    for (int attempt = 0; attempt < 30; attempt++) {
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) break;
        if (attempt == 29) {
            char msg[96]; int n = snprintf(msg, sizeof(msg), "Desk Box bootstrap: connect errno=%d\n", errno);
            write(STDOUT_FILENO, msg, (size_t)n); fsync(STDOUT_FILENO); close(fd); return 6;
        }
        sleep(1);
    }
    if (send_frame(fd, 1, 1, json, (size_t)len) != 0) { close(fd); return 7; }
    uint8_t response[4096]; (void)read(fd, response, sizeof(response));
    const char *done = "Desk Box bootstrap: hello sent\n";
    write(STDOUT_FILENO, done, strlen(done));
    fsync(STDOUT_FILENO);
    // Mark a successful bootstrap for the handoff rootfs. This avoids opening
    // a second control connection while still running the full init chain.
    (void)mkdir("/run", 0755);
    int marker = open("/run/deskbox-bootstrap-ok", O_CREAT | O_WRONLY, 0644);
    if (marker >= 0) close(marker);
    // MVP exec handling: stay on the authenticated VSOCK session and answer
    // simple request frames. This is not a full execd; TLS/authorization and
    // spawn/sandboxing land in the next phase.
    uint64_t response_sequence = 2; // hello consumed sequence 1
    uint8_t incoming[4096];
    for (;;) {
        ssize_t got = read(fd, incoming, sizeof(incoming));
        if (got <= 0) break;
        if (got < 36) continue;
        uint16_t kind; memcpy(&kind, incoming + 6, 2);
        kind = be16(kind);
        uint32_t paylen_be; memcpy(&paylen_be, incoming + 32, 4);
        size_t paylen = be32(paylen_be);
        if (kind != 4 || paylen + 36 > sizeof(incoming)) continue;
        incoming[36 + paylen] = 0;
        // Echo the request's requestID so the host can correlate responses,
        // and use a per-session strictly increasing sequence for replay checks.
        uint8_t request_id[16];
        memcpy(request_id, incoming + 16, 16);
        char rjson[4096];
        int rlen = run_exec_request((const char *)(incoming + 36), rjson, sizeof(rjson));
        if (rlen > 0) (void)send_frame_ex(fd, 5, response_sequence++, request_id, rjson, (size_t)rlen);
    }
    close(fd);
    return 0;
}
#endif // DBX_TEST_NO_MAIN
