/*
 * M18 hardening probe：在 guest 内验证 Landlock（路径面）与 seccomp-bpf（syscall 面）是否生效。
 *
 * 用法：hardening-probe <case>
 *   输出：case=<name> rc=<rc> errno=<n>
 *
 * 判定标准见 docs/design/m18-guest-kernel-hardening.md §4：
 *   - 正例（应当成功）：writespace / writetmp / readbin
 *   - 负例（应当被拒）：outwrite（Landlock EACCES）/ mount ptrace unshare bpf keyctl（seccomp EPERM）
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/ptrace.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef __NR_keyctl
#define __NR_keyctl 250 /* unused on arm64; guarded below */
#endif

static int write_file(const char *path) {
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return -1;
    ssize_t n = write(fd, "x\n", 2);
    close(fd);
    return n == 2 ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: hardening-probe <case>\n");
        return 2;
    }
    const char *kase = argv[1];
    int rc = -1;
    int saved_errno = 0;

    if (strcmp(kase, "writespace") == 0) {
        rc = write_file("/workspace/probe-ok");
    } else if (strcmp(kase, "writetmp") == 0) {
        rc = write_file("/tmp/probe-ok");
    } else if (strcmp(kase, "readbin") == 0) {
        int fd = open("/bin/busybox", O_RDONLY);
        rc = fd >= 0 ? 0 : -1;
        if (fd >= 0) close(fd);
    } else if (strcmp(kase, "outwrite") == 0) {
        /* /opt/landlock-canary 由镜像创建为 0777：无 Landlock 时 nobody 可写。 */
        rc = write_file("/opt/landlock-canary/probe-x");
    } else if (strcmp(kase, "outwrite_etc") == 0) {
        rc = write_file("/etc/probe-x");
    } else if (strcmp(kase, "mount") == 0) {
        rc = mount("none", "/tmp/probe-mnt", "tmpfs", 0, NULL);
    } else if (strcmp(kase, "ptrace") == 0) {
        rc = ptrace(PTRACE_TRACEME, 0, NULL, NULL);
    } else if (strcmp(kase, "unshare") == 0) {
        rc = unshare(CLONE_NEWUSER);
    } else if (strcmp(kase, "keyctl") == 0) {
#if defined(__NR_add_key)
        rc = (int)syscall(__NR_add_key, "user", "dbxprobe", "v", 1,
                          (unsigned long)-2 /* KEY_SPEC_SESSION_KEYRING */);
#else
        rc = -1;
        saved_errno = ENOSYS;
#endif
    } else if (strcmp(kase, "bpf") == 0) {
#if defined(__NR_bpf)
        /* BPF_MAP_CREATE with an invalid/zeroed attribute: seccomp 前应返回 EPERM。 */
        char attr[64];
        memset(attr, 0, sizeof(attr));
        rc = (int)syscall(__NR_bpf, 0 /* BPF_MAP_CREATE */, attr, sizeof(attr));
#else
        rc = -1;
        saved_errno = ENOSYS;
#endif
    } else {
        fprintf(stderr, "unknown case: %s\n", kase);
        return 2;
    }

    if (rc < 0 && saved_errno == 0) saved_errno = errno;
    printf("case=%s rc=%d errno=%d\n", kase, rc, rc < 0 ? saved_errno : 0);
    return 0;
}
