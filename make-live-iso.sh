#!/bin/bash
# ============================================================
# make-live-iso.sh
# 将当前运行的 Ubuntu 22.04 系统打包为可引导的 Live CD ISO
# 用法: sudo bash make-live-iso.sh [输出目录]
# ============================================================
set -e

# ---------- 可调整参数 ----------
OUTPUT_DIR="${1:-/root/live-output}"
ISO_NAME="custom-live-$(date +%Y%m%d).iso"
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

# 检查并安装依赖（mtools 提供 mformat，grub-mkrescue 生成 EFI FAT 时需要）
PKGS_NEEDED=()
dpkg -s mtools &>/dev/null || PKGS_NEEDED+=(mtools)
dpkg -s grub-efi-amd64-bin &>/dev/null || PKGS_NEEDED+=(grub-efi-amd64-bin)
dpkg -s grub-pc-bin &>/dev/null || PKGS_NEEDED+=(grub-pc-bin)
if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
    info "安装缺失依赖: ${PKGS_NEEDED[*]}"
    apt-get install -y "${PKGS_NEEDED[@]}"
fi

for cmd in mksquashfs xorriso grub-mkrescue mformat update-initramfs; do
    command -v "$cmd" &>/dev/null || error "缺少命令: $cmd，请先安装对应包"
done

info "======== 开始制作 Live ISO ========"
info "输出路径: ${OUTPUT_DIR}/${ISO_NAME}"
info "工作目录: ${WORK_DIR}"

# ── 0. 清理并建立目录 ──────────────────────────────────────
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{iso/{boot/grub,live},initrd-tmp}
mkdir -p "$OUTPUT_DIR"

# ── 1. 重建 initrd（确保包含 live-boot 钩子）──────────────
info "[1/5] 重建 initrd（包含 live-boot 钩子）..."

# 确认 live-boot 已安装
if ! dpkg -l live-boot &>/dev/null | grep -q '^ii'; then
    warn "live-boot 未安装，正在安装..."
    apt-get install -y live-boot live-boot-initramfs-tools
fi

KERNEL_VER=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
info "  内核版本: ${KERNEL_VER}"

# 生成包含 live-boot 的 initrd（写到工作目录，不覆盖系统原件）
update-initramfs -c -k "$KERNEL_VER" -b "$WORK_DIR/initrd-tmp" 2>&1 | tail -5
INITRD_SRC="$WORK_DIR/initrd-tmp/initrd.img-${KERNEL_VER}"

[[ -f "$INITRD_SRC" ]] || {
    warn "update-initramfs 未在工作目录生成文件，回退使用系统 /boot/initrd.img"
    INITRD_SRC="/boot/initrd.img-${KERNEL_VER}"
}

# 复制内核和 initrd 到 ISO/boot/
cp "/boot/vmlinuz-${KERNEL_VER}" "$WORK_DIR/iso/boot/vmlinuz"
cp "$INITRD_SRC"                  "$WORK_DIR/iso/boot/initrd.img"
info "  内核 & initrd 已复制到 iso/boot/"

# ── 2. 创建系统 squashfs ───────────────────────────────────
info "[2/5] 创建 squashfs（压缩算法: ${SQUASHFS_COMP}，可能耗时较长）..."

SQUASHFS_OUT="$WORK_DIR/iso/live/filesystem.squashfs"

# 排除清单：不打包临时/虚拟文件系统和本次生成物
EXCLUDES=(
    /proc /sys /dev /run /tmp /media /mnt
    /snap /var/snap
    /lost+found
    /swapfile /swap.img
    "$WORK_DIR"
    "$OUTPUT_DIR"
    /root/make-live-iso.sh
    /boot                        # 内核已单独放到 iso/boot，这里排除
    /var/cache/apt/archives      # 减小体积（不用通配符，避免触发 wildcards 模式）
    /var/log                     # 可选：去掉日志
)

# 构建 mksquashfs 排除参数
EXCL_ARGS=()
for ex in "${EXCLUDES[@]}"; do
    EXCL_ARGS+=(-e "$ex")
done

# 被排除的目录在 squashfs 里连目录条目都没有，init 切换根节点后找不到挂载点会 kernel panic。
# 用 -p 伪文件选项在 squashfs 中强制创建这些空目录作为挂载点。
PSEUDO_MOUNTPOINTS=(
    "/dev d 755 0 0"
    "/proc d 755 0 0"
    "/sys d 755 0 0"
    "/run d 755 0 0"
    "/tmp d 1777 0 0"
    "/media d 755 0 0"
    "/mnt d 755 0 0"
    "/snap d 755 0 0"
    "/boot d 755 0 0"
)
PSEUDO_ARGS=()
for pd in "${PSEUDO_MOUNTPOINTS[@]}"; do
    PSEUDO_ARGS+=(-p "$pd")
done

mksquashfs / "$SQUASHFS_OUT" \
    -comp "$SQUASHFS_COMP" \
    -noappend \
    -no-recovery \
    "${PSEUDO_ARGS[@]}" \
    "${EXCL_ARGS[@]}" \
    2>&1 | tee /tmp/mksquashfs.log | grep -E "^(Parallel|Exportable|squashfs|info|[0-9])" || true

[[ -f "$SQUASHFS_OUT" ]] || error "squashfs 生成失败，请查看 /tmp/mksquashfs.log"
SQ_SIZE=$(du -sh "$SQUASHFS_OUT" | cut -f1)
info "  squashfs 生成完成，大小: ${SQ_SIZE}"

# ── 3. 写入 filesystem.size（live-boot 需要）─────────────
unsquashfs -stat "$SQUASHFS_OUT" 2>/dev/null | grep "Filesystem size" \
    | awk '{print $3}' > "$WORK_DIR/iso/live/filesystem.size" || true

# ── 4. 写入 GRUB 配置 ─────────────────────────────────────
info "[3/5] 写入 GRUB 配置..."

cat > "$WORK_DIR/iso/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=30
set default=0

# 默认项：文本模式，能看到完整启动日志，便于排查问题
menuentry "Ubuntu Live (文本模式，推荐)" {
    linux  /boot/vmlinuz boot=live components systemd.unit=multi-user.target
    initrd /boot/initrd.img
}

# 图形模式（Plymouth splash），系统正常后再用此项
menuentry "Ubuntu Live (图形模式)" {
    linux  /boot/vmlinuz boot=live components quiet splash
    initrd /boot/initrd.img
}

# 加载到内存后运行，速度更快（需要 ≥4GB RAM）
menuentry "Ubuntu Live (toram，需 4GB+ 内存)" {
    linux  /boot/vmlinuz boot=live components toram
    initrd /boot/initrd.img
}
GRUBCFG

# ── 5. 用 grub-mkrescue / xorriso 生成 ISO ────────────────
info "[4/5] 生成可引导 ISO..."

ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"

grub-mkrescue \
    --output="$ISO_PATH" \
    "$WORK_DIR/iso" \
    2>&1 | tail -10

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