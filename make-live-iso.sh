#!/bin/bash
# ============================================================
# make-live-iso.sh
# 将当前运行的 Ubuntu 22.04 系统打包为可引导的 Live CD ISO
# 用法: sudo bash make-live-iso.sh [输出目录]
# ============================================================
set -e

# ---------- 可调整参数 ----------
OUTPUT_DIR="${1:-/root/live-output}"
ISO_NAME="custom-live-
$(date +%Y%m%d).iso"
WORK_DIR="/tmp/live-iso-work"
SQUASHFS_COMP="xz"          # 压缩算法: xz / gzip / lz4
# --------------------------------

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# 必须以 root 运行
[[ $EUID -ne 0 ]] && error "请以 root 权限运行: sudo bash $0"

# 检查并安装依赖
PKGS_NEEDED=()
dpkg -s mtools &>/dev/null || PKGS_NEEDED+=(mtools)
dpkg -s grub-efi-amd64-bin &>/dev/null || PKGS_NEEDED+=(grub-efi-amd64-bin)
dpkg -s grub-pc-bin &>/dev/null || PKGS_NEEDED+=(grub-pc-bin)
if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
    info "安装缺失依赖: ${PKGS_NEEDED[*]}"
    apt-get install -y "${PKGS_NEEDED[@]}"
fi

for cmd in mksquashfs xorriso grub-mkimage grub-mkstandalone mformat update-initramfs; do
    command -v "$cmd" &>/dev/null || error "缺少命令: $cmd，请先安装对应包"
done

info "======== 开始制作 Live ISO ========"
info "输出路径: ${OUTPUT_DIR}/${ISO_NAME}"
info "工作目录: ${WORK_DIR}"

# ── 0. 清理并建立目录 ──────────────────────────────────────
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{iso/{boot/grub,live},initrd-tmp}
mkdir -p "$OUTPUT_DIR"

# ── 1. 重建 initrd ────────────────────────────────────────
info "[1/5] 重建 initrd（包含 live-boot 钩子）..."

if ! dpkg -l live-boot 2>/dev/null | grep -q '^ii'; then
    warn "live-boot 未安装，正在安装..."
    apt-get install -y live-boot live-boot-initramfs-tools
fi

KERNEL_VER=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
info "  内核版本: ${KERNEL_VER}"

update-initramfs -c -k "$KERNEL_VER" -b "$WORK_DIR/initrd-tmp" 2>&1 | tail -5
INITRD_SRC="$WORK_DIR/initrd-tmp/initrd.img-${KERNEL_VER}"

[[ -f "$INITRD_SRC" ]] || {
    warn "update-initramfs 未在工作目录生成文件，回退使用系统 /boot/initrd.img"
    INITRD_SRC="/boot/initrd.img-${KERNEL_VER}"
}

cp "/boot/vmlinuz-${KERNEL_VER}" "$WORK_DIR/iso/boot/vmlinuz"
cp "$INITRD_SRC"                  "$WORK_DIR/iso/boot/initrd.img"
info "  内核 & initrd 已复制到 iso/boot/"

# ── 2. 创建系统 squashfs ──────────────────────────────────
info "[2/5] 创建 squashfs（压缩算法: ${SQUASHFS_COMP}，可能耗时较长）..."
SQUASHFS_OUT="$WORK_DIR/iso/live/filesystem.squashfs"

EXCLUDES=(
    /proc /sys /dev /run /tmp /media /mnt
    /snap /var/snap
    /lost+found
    /swapfile /swap.img
    "$WORK_DIR"
    "$OUTPUT_DIR"
    /root/make-live-iso.sh
    /boot
    /var/cache/apt/archives
    /var/log
)

EXCL_ARGS=()
for ex in "${EXCLUDES[@]}"; do EXCL_ARGS+=(-e "$ex"); done

PSEUDO_MOUNTPOINTS=(
    "/dev d 755 0 0"  "/proc d 755 0 0"  "/sys d 755 0 0"  
    "/run d 755 0 0"  "/tmp d 1777 0 0"  "/media d 755 0 0"  
    "/mnt d 755 0 0"  "/snap d 755 0 0"  "/boot d 755 0 0"
)
PSEUDO_ARGS=()
for pd in "${PSEUDO_MOUNTPOINTS[@]}"; do PSEUDO_ARGS+=(-p "$pd"); done

mksquashfs / "$SQUASHFS_OUT" \
    -comp "$SQUASHFS_COMP" -noappend -no-recovery \
    "${PSEUDO_ARGS[@]}" "${EXCL_ARGS[@]}" \
    2>&1 | tee /tmp/mksquashfs.log | grep -E "^(Parallel|Exportable|squashfs|info|[0-9])" || true

[[ -f "$SQUASHFS_OUT" ]] || error "squashfs 生成失败，请查看 /tmp/mksquashfs.log"
SQ_SIZE=$(du -sh "$SQUASHFS_OUT" | cut -f1)
info "  squashfs 生成完成，大小: ${SQ_SIZE}"

# ── 3. 写入 filesystem.size ───────────────────────────────
unsquashfs -stat "$SQUASHFS_OUT" 2>/dev/null | grep "Filesystem size" \
    | awk '{print $3}' > "$WORK_DIR/iso/live/filesystem.size" || true

# ── 4. 写入 GRUB 配置 ─────────────────────────────────────
info "[3/5] 写入 GRUB 配置..."

GRUB_CFG="$WORK_DIR/iso/boot/grub/grub.cfg"
cat > "$GRUB_CFG" << 'GRUBCFG'
set timeout=30
set default=0

menuentry "Ubuntu Live (toram，需 4GB+ 内存)" {
    linux  /boot/vmlinuz boot=live components toram
    initrd /boot/initrd.img
}
GRUBCFG

# ── 5. 根据 squashfs 大小选择 ISO 生成方式 ────────────────
info "[4/5] 生成可引导 ISO..."

ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"
ISO9660_MAX=4294967295
SQ_BYTES=$(stat -c%s "$SQUASHFS_OUT")

if [[ "$SQ_BYTES" -le "$ISO9660_MAX" ]]; then
    info "  squashfs <= 4GB（${SQ_SIZE}），使用 grub-mkrescue 生成 ISO..."
    grub-mkrescue --output="$ISO_PATH" "$WORK_DIR/iso" 2>&1 | tail -10
else
    info "  squashfs > 4GB（${SQ_SIZE}），使用 xorriso -iso-level 3 生成 ISO（支持大文件）..."

    BIOS_CORE="$WORK_DIR/iso/boot/grub/core.img"
    BIOS_ELTORITO="$WORK_DIR/iso/boot/grub/eltorito.img"
    EFI_EXE="$WORK_DIR/iso/EFI/BOOT/BOOTx64.EFI"
    EFI_IMG="$WORK_DIR/iso/boot/grub/efi.img"

    # ── BIOS 引导 ──────────────────────────────────────────
    # grub-mkimage 只内嵌最小模块，不打包 grub.cfg 进 memdisk
    # 避免 grub-mkstandalone 将 grub.cfg 打包进 memdisk 导致 core.img 超出 480KB 限制
    info "  生成 BIOS core.img（grub-mkimage）..."
    grub-mkimage \
        --format=i386-pc \
        --output="$BIOS_CORE" \
        --prefix='/boot/grub' \
        biosdisk part_msdos iso9660 \
        2>&1 | tee /tmp/grub-bios.log | tail -5
    [[ -s "$BIOS_CORE" ]] || error "BIOS core.img 生成失败，请查看 /tmp/grub-bios.log"

    # 拼接 cdboot.img + core.img = El Torito BIOS 引导镜像
    cat /usr/lib/grub/i386-pc/cdboot.img "$BIOS_CORE" > "$BIOS_ELTORITO"
    [[ -s "$BIOS_ELTORITO" ]] || error "BIOS eltorito.img 合并失败"
    info "  BIOS 引导镜像生成完成（$(du -sh "$BIOS_ELTORITO" | cut -f1)）"

    # 复制 GRUB i386-pc 模块目录到 ISO
    # GRUB 启动后通过 --prefix='/boot/grub' 从此目录加载 normal.mod 等完整模块
    info "  复制 GRUB i386-pc 模块到 ISO..."
    mkdir -p "$WORK_DIR/iso/boot/grub/i386-pc"
    cp /usr/lib/grub/i386-pc/*.mod "$WORK_DIR/iso/boot/grub/i386-pc/"
    cp /usr/lib/grub/i386-pc/*.lst "$WORK_DIR/iso/boot/grub/i386-pc/" 2>/dev/null || true
    info "  GRUB 模块复制完成（$(du -sh "$WORK_DIR/iso/boot/grub/i386-pc" | cut -f1)）"

    # ── UEFI 引导 ──────────────────────────────────────────
    # grub-mkstandalone 生成独立 EFI 可执行文件（含所有模块+grub.cfg，无大小限制）
    info "  生成 UEFI BOOTx64.EFI..."
    mkdir -p "$(dirname "$EFI_EXE")"
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$EFI_EXE" \
        "boot/grub/grub.cfg=${GRUB_CFG}" \
        2>&1 | tee /tmp/grub-efi.log | tail -5
    [[ -s "$EFI_EXE" ]] || error "UEFI BOOTx64.EFI 生成失败，请查看 /tmp/grub-efi.log"
    info "  UEFI BOOTx64.EFI 生成完成（$(du -sh "$EFI_EXE" | cut -f1)）"

    # EFI FAT 镜像：64MB 满足 FAT32 最低 65525 簇要求
    info "  创建 EFI FAT 镜像（64MB）..."
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=64 2>/dev/null
    mformat -i "$EFI_IMG" -F ::
    mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
    mcopy -i "$EFI_IMG" "$EFI_EXE" ::/EFI/BOOT/
    info "  EFI FAT 镜像创建完成"

    # xorriso 封装 ISO，-iso-level 3 取消 4GB 单文件限制
    info "  调用 xorriso 封装 ISO..."
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -R -J \
        -b boot/grub/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$EFI_IMG" \
        -appended_part_as_gpt \
        -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$ISO_PATH" \
        "$WORK_DIR/iso" \
        2>&1 | tail -15
fi

[[ -f "$ISO_PATH" ]] || error "ISO 生成失败"

ISO_SIZE=$(du -sh "$ISO_PATH" | cut -f1)
info "[5/5] 完成！"
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN} ISO 路径: ${ISO_PATH}${NC}"
echo -e "${GREEN} ISO 大小: ${ISO_SIZE}${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "  写入 U 盘示例（替换 /dev/sdX）:"
echo "    sudo dd if=\"${ISO_PATH}\" of=/dev/sdX bs=4M status=progress oflag=sync"
echo ""
echo "  或用 Ventoy / Rufus 直接加载该 ISO 文件。"

# ── 清理工作目录 ──────────────────────────────────────────
info "清理工作目录 ${WORK_DIR} ..."
rm -rf "$WORK_DIR"
info "全部完成。"