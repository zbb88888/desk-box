# M10：可复构建（bit-for-bit reproducibility）

状态：已完成（同一 commit 双跑构建三次资产 sha256 完全一致，REPRO-OK；CI repro-check job 已加入）；关联 `docs/design/m3-supply-chain.md`、`docs/design/m6-ci-pipeline.md`、`docs/security/security-verification-matrix.md` INV-09。

## 1. 目标

DETERMINISTIC：同一 git commit 多次复跑 `scripts/build-alpine-guest.sh`，客资产 sha256（vmlinuz-virt、initrd-deskbox.img、root-disk.raw）必须一致（M3 SBOM 因此才可外部复核）。

- `SOURCE_DATE_EPOCH` 作为所有时间戳的统一来源：
  - 默认 `$(git log -1 --format=%ct)`（git commit 时间戳）；
  - 所有下载文件的 mtime 改为此、cpio/gzip 均无本地时间戳、ext4 image 贝纳可配置；
- initramfs 压缩：`gzip -n9`（无 mtime；`cpio -H newc` 的文件顺序用 `LC_ALL=C sort` 固定；cpio 若支持 `--reproducible` 则启用）；；
- ext4 image：`mke2fs -E hash_seed=...`（固定 UUID）以及 `-U clear`（inode 跨机器一致）；
- builtAtUtc 改为 commit 时间戳（不再内嵌 `date -u` 头顶电阻中文）；

非目标：步骤内的的一些绕 rm 家里的去剩还性平变化（本阶段只承认在复 program 本上能达到的复用零、不会负 bit 的动能）。

## 进度

- ✅ `SOURCE_DATE_EPOCH` 驱动（默认 `git log -1 --format=%ct`）：下载 mtime、initrd/rootfs 文件 time、内置 sbom/release 时间戳全部同步；
  - cpio：`LC_ALL=C sort` 排序 + `gzip -n9`；busybox `touch -h -t "$TS_TOUCH"`（host 侧预计算 `-t` 格式，避开 busybox touch -d 兼容性差异）；
- ✅ ext4 image：`-O ^has_journal,^metadata_csum -E test_fs -U 0...` + dd-zero 主/备 SB 的 journal-salt 与短暂 timestamps；
- ✅ 真机验证：在同 commit 两次完整构建下，三项客资产 SHA-256 完全一致（REPRO-OK）；journal-removed rootfs 仍可正常作为客盘挂载（guest boot / exec / ws 流不受影响）；
- ✅ CI：`repro-check` job 已加入 `ci.yml`（double build + 比对）；
- 不宣称的后续物：下载工件自身的 bit-for-bit（受远程上游不灭以，本阶段以 URL+sha256 provenance 进 SBOM 覆盖）；包管理 determinism 的版本化是 CI 后续访谈。

## 2. 实施参考

### 2.1 `scripts/build-alpine-guest.sh` 变化
```sh:
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || echo 1700000000)
fi
export SOURCE_DATE_EPOCH

# mtime normalization：(下载后、渠道后）
touch -d "@$SOURCE_DATE_EPOCH" "$OUT_DIR/vmlinuz-virt" "$OUT_DIR/debian-initrd.gz" ...

# docker run 附加 -e SOURCE_DATE_EPOCH
docker run --rm ... -e SOURCE_DATE_EPOCH
# docker 内部统一 touch -d "@$SOURCE_DATE_EPOCH" 后才 mke2fs/gen-cpio

# cpio invariant：cd /tmp/initrd && find . -print | LC_ALL=C sort | cpio -H newc -o --reproducible 2>/dev/null || ... 找到支持的非则设 （dpkg/apt 含 GNU cpio newc 支持 $INFILE_ORDER?)
# gzip -n9

# mke2fs：mke2fs -q -t ext4 -F -d /tmp/rootfs -U 0e2ff16d-64d1-4fff-a8e3-9cfb09e07372 -E hash_seed=00000000-0000-0000-0000-000000000000 -E nowait /out/root-disk.raw
# (（e2fsprogs ≥1.47 同样尊重 SOURCE_DATE_EPOCH））
```

### 2.2 CI 的 `repro-check` job
- 运行两次：ubuntu x86 去 build-alpine-guest.sh 守同 SOURCE_DATE_EPOCH 推出；比对三个输出 sha256 任差；
- 不上传（只是一致性话务，不再附加消费）。

## 3. 验证
1. 本机一次推git tag 后的 bash 循环：`for i in 1 2; do SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) ./scripts/build-alpine-guest.sh ./guest-repro-$i; done` → sha256 输入一致；
2. CI 推出两个 build-artifact，不同 commit 出绿了；sha256 一致；
3. 不同 commit → sha256 侵称不同（指出）（证明 SOURCE_DATE_EPOCH 仅 控制回应）；
4. `swift test` 仍绿；`scripts/run-fuzz.sh` 选制不需要复跑 repro；保安的安排不影响效率。

## 4. 安全决策
- 复构为 supply-chain 的装弹语言：同的 commit、同的 machine 必出同的文件；差异不代表应被许可进正规验证；
- builtAtUtc 与 commit 时间关联；CI/复跑一致的结果才是可信状态。