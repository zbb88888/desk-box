#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/resource.h>
#endif
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#ifdef __linux__
#include <linux/vm_sockets.h>
#endif
#include <sodium.h>
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

/**
 * Apply the exec child hardening contract used by the M1-3 guest agent:
 * - no_new_privs so exec can't regain rights;
 * - tight rlimits (CPU seconds, resident memory, processes, fds, output size);
 * - drop supplementary groups + setuid/setgid to the nobody uid/gid (65534);
 * - environment whitelist: PATH and HOME only;
 * - cwd is forced to a workspace root that the runtime mounts read-write;
 * Symbol returns 0 in the child when all steps succeeded; on host/test
 * builds there is no privilege boundary to establish (best effort).
 */
static int install_exec_hardening(int timeout_seconds) {
#ifdef __linux__
    enum { SVC_UID = 65534, SVC_GID = 65534 };
    // rlimits survive setuid; install before dropping privileges.
    const struct rlimit no_lfile = {0, 0};
    if (setrlimit(RLIMIT_FSIZE, &(struct rlimit){65536, 65536}) != 0) return -1; // 64KiB per file
    (void)no_lfile;
    if (setrlimit(RLIMIT_NOFILE, &(struct rlimit){32, 32}) != 0) return -2;
    if (setrlimit(RLIMIT_NPROC, &(struct rlimit){32, 32}) != 0) return -3;
    if (setrlimit(RLIMIT_AS, &(struct rlimit){(256UL << 20), (256UL << 20)}) != 0) return -4; // 256MiB
    if (setrlimit(RLIMIT_CPU, &(struct rlimit){(rlim_t)(timeout_seconds + 1), (rlim_t)(timeout_seconds + 1)}) != 0) return -5;
    // Losing privs: nobody (65534) is a well-known anonymous account; init
    // must own the filesystem paths needed for workspace writes later.
    if (setgroups(0, NULL) != 0) return -6;
    if (setregid(SVC_GID, SVC_GID) != 0) return -7;
    if (setreuid(SVC_UID, SVC_UID) != 0) return -8;
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -9;
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) return -10;
    // Environment: forced whitelist, later requests only get these defaults.
    static char *const default_env[] = {
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME=/workspace",
        "USER=sandbox",
        NULL
    };
    extern char **environ;
    environ = (char **)default_env;
    // Working dir workspace; safe because /workspace exists in the guest rootfs.
    if (chdir("/workspace") != 0)
        chdir("/");
#endif
    return 0;
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
        // Child hardening (M1-3): non-privileged execution with resource
        // ceilings. Order is important: limits are installed before privilege
        // drop so rlimit survives setuid.
        setpgid(0, 0);
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        if (install_exec_hardening(timeout_seconds) != 0) _exit(126);
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

/* ---- Record protection (X25519 + HKDF-SHA256 + ChaChaPoly AEAD) ---- */
/* This mirrors the CryptoKit session on the host:
 *   - X25519 ephemeral key agreement (32-byte Montgomery keys)
 *   - HKDF-SHA256 with salt "deskbox-m1-tls-v1" and info "record-protection-v1"
 *   - ChaCha20-Poly1305 AEAD; nonce = direction(4) || u64be counter
 *   - record = u32be(record_length) || nonce(12) || ct_and_tag
 */
static uint8_t host_pub[32], guest_sk[32], guest_pk[32], record_key[32];
static int record_mode = 0;
static uint64_t out_ctr = 0;

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

static int hkdf_sha256(uint8_t *okm, size_t okm_len,
                    const uint8_t *salt, size_t salt_len,
                    const uint8_t *ikm, size_t ikm_len,
                    const uint8_t *info, size_t info_len) {
    uint8_t prk[32];
    uint8_t t1[32];
    crypto_auth_hmacsha256_state st;
    crypto_auth_hmacsha256_init(&st, salt, salt_len);
    crypto_auth_hmacsha256_update(&st, ikm, ikm_len);
    crypto_auth_hmacsha256_final(&st, prk);
    crypto_auth_hmacsha256_init(&st, prk, sizeof(prk));
    crypto_auth_hmacsha256_update(&st, info, info_len);
    { uint8_t ctr = 1; crypto_auth_hmacsha256_update(&st, &ctr, 1); }
    crypto_auth_hmacsha256_final(&st, t1);
    if (okm_len > sizeof(t1)) return -1;
    memcpy(okm, t1, okm_len);
    sodium_memzero(prk, sizeof(prk));
    sodium_memzero(t1, sizeof(t1));
    return 0;
}

static int session_establish(const char *host_pub_hex) {
    if (sodium_init() < 0) return -1;
    if (hex_to_bin(host_pub_hex, 64, host_pub, sizeof(host_pub)) != 0) return -2;
    crypto_box_keypair(guest_pk, guest_sk); // X25519 ephemeral per boot
    uint8_t ikm[32];
    if (crypto_scalarmult(ikm, guest_sk, host_pub) != 0) return -3;
    static const uint8_t SALT[] = "deskbox-m1-tls-v1";
    static const uint8_t INFO[] = "record-protection-v1";
    if (hkdf_sha256(record_key, sizeof(record_key),
                    SALT, sizeof(SALT) - 1,
                    ikm, sizeof(ikm),
                    INFO, sizeof(INFO) - 1) != 0) return -4;
    sodium_memzero(ikm, sizeof(ikm));
    return 0;
}

static size_t record_encrypt(int dir, uint8_t *out, size_t out_cap,
                             const uint8_t *plaintext, size_t plaintext_len) {
    if (out_cap < 4 + 12 + plaintext_len + 16) return 0;
    uint8_t nonce[12];
    nonce[0] = dir == 1 ? 0x01 : 0x02; nonce[1] = 0; nonce[2] = 0; nonce[3] = 0;
    uint64_t ctr_be = be64(out_ctr++);
    memcpy(nonce + 4, &ctr_be, 8);
    uint32_t total = (uint32_t)(12 + plaintext_len + 16);
    uint32_t total_be = be32(total);
    memcpy(out, &total_be, 4);
    memcpy(out + 4, nonce, 12);
    size_t offset = 4 + 12;
    uint8_t mac[16];
    if (crypto_aead_chacha20poly1305_ietf_encrypt_detached(
            out + offset, mac, NULL,
            plaintext, plaintext_len, NULL, 0, NULL, nonce, record_key) != 0) return 0;
    memcpy(out + offset + plaintext_len, mac, 16);
    return offset + plaintext_len + 16;
}

static ssize_t read_full(int fd, uint8_t *buf, size_t want) {
    size_t got = 0;
    while (got < want) {
        ssize_t n = read(fd, buf + got, want - got);
        if (n <= 0) return n;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

/* Receive one plaintext ControlFrame. Returns payload length or < 0. */
static ssize_t recv_frame(int fd, uint8_t *buf, size_t cap) {
    uint8_t header[36];
    ssize_t h = read_full(fd, header, sizeof(header));
    if (h != (ssize_t)sizeof(header)) return -1;
    if (be32(*(uint32_t *)(header + 0)) != 0x44425831u) return -2;
    uint32_t plen_be; memcpy(&plen_be, header + 32, 4);
    size_t paylen = be32(plen_be);
    if (paylen + 36 > cap) return -3;
    memcpy(buf, header, 36);
    ssize_t p = read_full(fd, buf + 36, paylen);
    if (p != (ssize_t)paylen) return -4;
    return (ssize_t)(36 + paylen);
}

/* Receive one record-protected ControlFrame. Returns payload length or < 0. */
static ssize_t recv_record(int fd, uint8_t *buf, size_t cap) {
    uint8_t lenbuf[4];
    ssize_t h = read_full(fd, lenbuf, 4);
    if (h != 4) return -1;
    uint32_t len_be; memcpy(&len_be, lenbuf, 4);
    size_t record_len = be32(len_be);
    if (record_len < 28 || record_len > (1 << 20) || 4 + record_len > cap) return -2;
    uint8_t *record = (uint8_t *)(buf);
    memcpy(record, lenbuf, 4);
    ssize_t p = read_full(fd, record + 4, record_len);
    if (p != (ssize_t)record_len) return -3;
    uint8_t *nonce = record + 4;
    uint8_t *ct = nonce + 12;
    size_t ct_len = record_len - 12;
    uint8_t plaintext[4096];
    if (ct_len > sizeof(plaintext)) return -4;
    if (crypto_aead_chacha20poly1305_ietf_decrypt(
            plaintext, NULL, NULL,
            ct, ct_len, NULL, 0, nonce, record_key) != 0) return -5;
    memcpy(buf, plaintext, ct_len - 16);
    return (ssize_t)(ct_len - 16);
}

/* Extract "hostKeyPublicHex":"<64 hex>" from HelloAck payload. */
static int extract_host_public_hex(const char *ack_payload, char *out_hex /* 65 */) {
    const char *key = strstr(ack_payload, "\"hostKeyPublicHex\"");
    if (!key) return -1;
    const char *colon = strchr(key, ':');
    if (!colon) return -2;
    colon++;
    while (*colon == ' ' || *colon == '\t') colon++;
    if (*colon != '"') return -3;
    colon++;
    size_t span = strcspn(colon, "\"");
    if (span != 64) return -4;
    memcpy(out_hex, colon, 64); out_hex[64] = 0;
    return 0;
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
    /* Read BootstrapHelloAck as a full frame. If the host armed the TLS
     * upgrade, its payload contains "hostKeyPublicHex" and we must reply with a
     * keyExchange frame and switch the channel to AEAD records. */
    uint8_t ack_frame[4096];
    ssize_t ack_len = recv_frame(fd, ack_frame, sizeof(ack_frame));
    if (ack_len <= 0) { close(fd); return 8; }
    uint32_t ack_plen_be; memcpy(&ack_plen_be, ack_frame + 32, 4);
    size_t ack_plen = be32(ack_plen_be);
    ack_frame[36 + ack_plen] = 0;

    char host_pub_hex[65];
    uint64_t response_sequence = 2; // hello consumed sequence 1
    if (extract_host_public_hex((const char *)(ack_frame + 36), host_pub_hex) == 0) {
        if (session_establish(host_pub_hex) != 0) { close(fd); return 9; }
        // Reply with our ephemeral X25519 public key as a plaintext keyExchange
        // frame, then upgrade the transport to AEAD records.
        if (send_frame_ex(fd, 8, response_sequence++, NULL,
                          (const char *)guest_pk, 32) != 0) { close(fd); return 10; }
        record_mode = 1;
        const char *up = "Desk Box bootstrap: secure channel up\n";
        write(STDOUT_FILENO, up, strlen(up)); fsync(STDOUT_FILENO);
    } else {
        const char *up = "Desk Box bootstrap: plaintext channel (TLS upgrade disabled on host)\n";
        write(STDOUT_FILENO, up, strlen(up)); fsync(STDOUT_FILENO);
    }
    const char *done = "Desk Box bootstrap: hello sent\n";
    write(STDOUT_FILENO, done, strlen(done));
    fsync(STDOUT_FILENO);
    // Mark a successful bootstrap for the handoff rootfs. This avoids opening
    // a second control connection while still running the full init chain.
    (void)mkdir("/run", 0755);
    int marker = open("/run/deskbox-bootstrap-ok", O_CREAT | O_WRONLY, 0644);
    if (marker >= 0) close(marker);
    uint8_t incoming[4096];
    for (;;) {
        ssize_t got = (record_mode ? recv_record(fd, incoming, sizeof(incoming))
                                   : recv_frame(fd, incoming, sizeof(incoming)));
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
        if (rlen <= 0) continue;
        if (!record_mode) {
            (void)send_frame_ex(fd, 5, response_sequence++, request_id, rjson, (size_t)rlen);
        } else {
            uint8_t frame[4096] = {0};
            size_t total = 36 + (size_t)rlen;
            uint32_t magic = be32(0x44425831); memcpy(frame, &magic, 4);
            uint16_t version = be16(1), k5 = be16(5);
            memcpy(frame + 4, &version, 2); memcpy(frame + 6, &k5, 2);
            uint64_t seq = be64(response_sequence++); memcpy(frame + 8, &seq, 8);
            memcpy(frame + 16, request_id, 16);
            uint32_t plen = be32((uint32_t)rlen); memcpy(frame + 32, &plen, 4);
            memcpy(frame + 36, rjson, (size_t)rlen);
            uint8_t record[4096 + 36];
            size_t record_len = record_encrypt(2, record, sizeof(record), frame, total);
            if (record_len == 0) continue;
            size_t sent = 0;
            while (sent < record_len) {
                ssize_t n = write(fd, record + sent, record_len - sent);
                if (n <= 0) { close(fd); return 11; }
                sent += (size_t)n;
            }
        }
    }
    close(fd);
    return 0;
}
#endif // DBX_TEST_NO_MAIN
