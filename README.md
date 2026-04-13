# Ubuntu Live CD 封装逻辑与原理详解

## 一、核心思想

Live CD 的本质是一个**只读的系统快照 + 启动时动态叠加可写层**。

```
你的硬盘系统 (可读写)
      │
      │  mksquashfs 压缩打包
      ▼
filesystem.squashfs (只读快照)
      │
      │  启动时 live-boot 挂载
      ▼
squashfs(只读) + tmpfs(可写) = overlayfs
      │
      ▼
用户看到的 Live 系统 (看起来可读写，重启后还原)
```

---

## 二、Live CD 启动的完整链条

```
① 固件 (BIOS/UEFI)
        │ 找到可引导设备
        ▼
② GRUB 引导器
        │ 加载内核 + initrd，传递内核参数
        ▼
③ Linux 内核启动
        │ 解压并执行 initrd 中的 init 脚本
        ▼
④ live-boot 钩子 (在 initrd 内执行)
        │ 找到 squashfs → 挂载 → 叠加 overlayfs
        ▼
⑤ switch_root
        │ 把根切换到 overlayfs 构建的新根
        ▼
⑥ systemd 启动
        │ 正常的用户空间初始化
        ▼
⑦ 用户登录界面
```

**封装工作就是为这条链的每一环准备好对应的文件。**

---

## 三、ISO 内部的文件结构

```
iso/
├── boot/
│   ├── grub/
│   │   └── grub.cfg    ← 给第②环：GRUB 读取的启动菜单
│   ├── vmlinuz         ← 给第③环：Linux 内核
│   └── initrd.img      ← 给第④环：含 live-boot 钩子的内存盘
└── live/
    ├── filesystem.squashfs  ← 给第④环：系统主体压缩包
    └── filesystem.size      ← live-boot 读取，用于显示进度
```

**一句话总结：** 封装过程就是把这五个文件准备好，再用 `grub-mkrescue` 包成可引导的 ISO。

---

## 四、各步骤逻辑详解

### Step 0：准备工作目录

```bash
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{iso/{boot/grub,live},initrd-tmp}
```

每次运行前清空工作目录，避免上次残留文件污染本次生成结果。

---

### Step 1：重建 initrd —— 为什么不能直接用系统的？

这是最容易被忽略、也最关键的一步。

**系统原装 initrd 的逻辑：**
```
启动 → 读取 /etc/fstab 中的 UUID → 找到对应磁盘分区 → 挂载为根
```

**Live initrd 需要的逻辑：**
```
启动 → 扫描所有设备 → 找到有 filesystem.squashfs 的那个 → 挂载 → 叠加 overlayfs → 切换根
```

这两套逻辑完全不同，Live 场景的逻辑由 **`live-boot`** 包提供。

`update-initramfs` 在生成 initrd 时，会自动扫描系统中已安装的钩子脚本，把 `live-boot` 的逻辑打包进去。所以 **`live-boot` 必须在生成 initrd 之前安装好**。

```
安装 live-boot → update-initramfs → 生成包含 live 钩子的 initrd
```

生成结果写到工作目录，**不覆盖系统原件**，保证脚本对真实系统无副作用。

---

### Step 2：制作 squashfs —— 打包系统快照

这一步是把运行中的根文件系统 `/` 压缩成一个只读的镜像文件。

**三个核心问题需要处理：**

**问题一：哪些目录不能打包？**

| 类型 | 目录 | 原因 |
|------|------|------|
| 虚拟文件系统 | `/proc` `/sys` `/dev` `/run` | 内核运行时动态生成，打包无意义且会出错 |
| 临时内容 | `/tmp` `/var/log` | 不需要保留 |
| 重复内容 | `/boot` | 内核已单独放入 `iso/boot/`，不重复打包 |
| 生成物本身 | `$WORK_DIR` `$OUTPUT_DIR` | 避免把正在写入的文件打包进去 |

**问题二：排除的目录连目录条目都没了怎么办？**

这是一个容易造成 **kernel panic** 的陷阱：

```
squashfs 中没有 /proc 目录条目
        │
        ▼
switch_root 后 systemd 尝试 mount /proc
        │
        ▼
找不到挂载点 → kernel panic
```

解决方案是用 `mksquashfs` 的 `-p` 参数，**在 squashfs 中强制创建空目录作为挂载点**：

```bash
mksquashfs / output.squashfs \
    -e /proc -e /sys -e /dev ...   # 排除真实内容
    -p "/proc d 755 0 0"           # 但保留目录条目
    -p "/dev  d 755 0 0"
    -p "/tmp  d 1777 0 0"
    ...
```

**问题三：fstab 冲突导致 emergency mode（重要！）**

这是从真实系统打包时最容易遇到的问题。

真实系统的 `/etc/fstab` 包含硬盘 UUID 挂载条目：
```
/dev/disk/by-uuid/xxxx  /           ext4  defaults 0 1
/dev/disk/by-uuid/yyyy  /boot/efi   vfat  defaults 0 1
/swap.img               none        swap  sw       0 0
```

Live 启动时，`live-boot` 会额外向 fstab 追加一条 overlayfs 根挂载：
```
overlay / overlay rw 0 0
```

于是 systemd 的 `systemd-fstab-generator` 看到**两条 `/` 挂载条目**，生成重复的 `-.mount` unit，导致：
```
graphical.target 事务冲突 → emergency mode
```

**解决方案：打包前临时将 fstab 替换为 live 专用版本**

```bash
cp /etc/fstab "$FSTAB_BAK"
trap 'cp "$FSTAB_BAK" /etc/fstab' EXIT   # 任何情况退出都自动还原

cat > /etc/fstab << 'EOF'
# live environment - no persistent mounts
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

# ... mksquashfs 打包 ...

cp "$FSTAB_BAK" /etc/fstab   # 打包完立即还原
trap - EXIT
```

> **注意：** `mksquashfs -p` 伪文件选项**无法覆盖已存在的真实文件**，只能创建不存在的路径。因此必须在打包前直接修改真实 fstab，让 mksquashfs 读到的就是 live 版本。`trap EXIT` 双重保险保证 fstab 一定会被还原。

---

### Step 3：filesystem.size —— 一个小但不能少的文件

```bash
unsquashfs -stat filesystem.squashfs | grep "Filesystem size"
```

这个文件记录的是 squashfs **解压后**的字节数。`live-boot` 在 `toram`（加载到内存）模式下用它判断内存是否够用，也用于显示加载进度条。

---

### Step 4：GRUB 配置 —— 连接引导器与 live-boot

`grub.cfg` 中最关键的是传给内核的参数：

```bash
linux /boot/vmlinuz boot=live components quiet splash
```

| 参数 | 作用 | 传递给谁 |
|------|------|---------|
| `boot=live` | 告知 initrd 进入 live 流程而非普通启动 | live-boot |
| `components` | 启用 live-boot 的各个功能组件 | live-boot |
| `quiet splash` | 隐藏日志，显示开机动画 | 内核 + Plymouth |
| `toram` | 将 squashfs 完整加载进内存 | live-boot |
| `systemd.unit=multi-user.target` | 启动到文本模式（不加载桌面） | systemd |

**`boot=live` 是最核心的参数**，没有它 initrd 会尝试普通的磁盘挂载流程，找不到根分区后进入 emergency shell。

脚本提供三个启动菜单项：

| 菜单项 | 适用场景 |
|--------|----------|
| 文本模式（推荐） | 排查问题，可看完整启动日志 |
| 图形模式 | 正常使用，加载桌面环境 |
| toram | 内存 ≥ 4GB 时，加载完成后运行更快 |

---

### Step 5：grub-mkrescue + xorriso —— 把目录变成可引导 ISO

**grub-mkrescue 内部做的事：**

```
iso/ 目录
    │
    ├── 写入 El Torito 引导记录    → BIOS 机器从这里找到引导程序
    │   (来自 grub-pc-bin)
    │
    ├── 创建 EFI 系统分区 (FAT)    → UEFI 机器从这里找到 EFI 程序
    │   (来自 grub-efi-amd64-bin)
    │   (mtools/mformat 用于创建 FAT 镜像)
    │
    └── 调用 xorriso 封装为标准 ISO 9660 格式
```

**grub-mkrescue 本质是一个 Shell 封装脚本**，最终调用的是 `xorriso -as mkisofs`。

**4GB 限制处理：**

ISO 9660 标准（Level 1/2）对单个文件有 4GB 大小限制。当 squashfs 超过 4GB 时，需要使用 ISO 9660 Level 3（`-iso-level 3`）解除此限制。

`grub-mkrescue` 通过 `--` 透传参数给 xorriso 时，`-iso-level` 是 `xorriso -as mkisofs` 子模式的参数，直接传递会报错：
```
xorriso : FAILURE : Not a known command: '-iso-level'
```

**解决方案：PATH 优先注入 xorriso 包装脚本**

```bash
# 创建包装脚本，拦截 grub-mkrescue 对 xorriso 的调用
cat > "$FAKE_BIN/xorriso" << 'EOF'
#!/bin/bash
ARGS=()
for arg in "$@"; do
    ARGS+=("$arg")
    [[ "$arg" == "mkisofs" ]] && ARGS+=("-iso-level" "3")
done
exec /usr/bin/xorriso "${ARGS[@]}"
EOF

# 让 grub-mkrescue 优先找到包装脚本
PATH="$FAKE_BIN:$PATH" grub-mkrescue --output="$ISO_PATH" "$WORK_DIR/iso"
```

包装脚本检测到 `-as mkisofs` 参数后，紧跟注入 `-iso-level 3`，再转发给真实 xorriso。

---

## 五、整体数据流

```
运行中的系统 /
│
├─── /boot/vmlinuz-*  ──────────────────────────────→ iso/boot/vmlinuz
│
├─── update-initramfs 重新生成 (含 live-boot 钩子)  → iso/boot/initrd.img
│
├─── /etc/fstab (临时替换为 live 版本后打包)
│         │
└─── / (根文件系统，排除虚拟目录和生成物)
          │
          mksquashfs 压缩                            → iso/live/filesystem.squashfs
          unsquashfs -stat 提取大小                  → iso/live/filesystem.size
          手动写入                                   → iso/boot/grub/grub.cfg
                                                               │
                                          grub-mkrescue 封装（squashfs ≤ 4GB）
                                          或 xorriso 包装注入 -iso-level 3（> 4GB）
                                                               │
                                                               ▼
                                                    custom-live-YYYYMMDD.iso
```

---

## 六、Live 系统启动后的文件系统结构

```
overlayfs (用户看到的根 /)
    │
    ├── upperdir = tmpfs (内存，可写，重启清空)   ← 所有写操作落这里
    └── lowerdir = squashfs (只读，不变)          ← 原始系统内容
```

**写操作的实际路径：**
- 用户修改 `/etc/hostname` → 实际写入 tmpfs upperdir
- 用户读取 `/usr/bin/python3` → 从 squashfs lowerdir 读取
- 重启后 → tmpfs 消失，squashfs 不变，系统完全还原

---

## 七、制作启动 U 盘

### 方法 1：dd（最通用）

```bash
# 确认 U 盘设备名（重要！写错会覆盖硬盘数据）
lsblk

# 写入（/dev/sdX 替换为实际 U 盘，不要加分区号）
sudo dd if="/root/live-output/custom-live-$(date +%Y%m%d).iso" \
        of=/dev/sdX \
        bs=4M \
        status=progress \
        oflag=sync
sync
```

### 方法 2：Ventoy（推荐，支持多 ISO）

```bash
# 安装 Ventoy 到 U 盘（只需一次）
bash Ventoy2Disk.sh -i /dev/sdX

# 之后把 ISO 文件复制到 U 盘的 Ventoy 分区即可
cp /root/live-output/custom-live-*.iso /media/$USER/Ventoy/
```

### 方法 3：udev rule 自动写入

适用于批量、自动化生产场景：插入指定型号 U 盘自动触发写入。

```bash
# /etc/udev/rules.d/99-make-live-usb.rules
ACTION=="add", \
SUBSYSTEM=="block", \
ENV{ID_BUS}=="usb", \
ENV{DEVTYPE}=="disk", \
ENV{ID_VENDOR_ID}=="厂商ID", \
ENV{ID_MODEL_ID}=="型号ID", \
RUN+="/usr/local/bin/flash-live-iso.sh %k"
```

```bash
# /usr/local/bin/flash-live-iso.sh
#!/bin/bash
DEVICE="/dev/$1"
ISO=$(ls /root/live-output/custom-live-*.iso | sort -V | tail -1)
sleep 2
dd if="$ISO" of="$DEVICE" bs=4M oflag=sync >> /var/log/flash-live-iso.log 2>&1
```

获取 U 盘 VendorID / ModelID：
```bash
udevadm info --query=all --name=/dev/sdX | grep -E "ID_VENDOR_ID|ID_MODEL_ID"
```

---

## 八、依赖关系汇总

| apt 包 | 提供的命令/功能 |
|--------|----------------|
| `squashfs-tools` | `mksquashfs`, `unsquashfs` |
| `xorriso` | `xorriso`（grub-mkrescue 调用） |
| `grub-efi-amd64-bin` | UEFI 引导模块 |
| `grub-pc-bin` | BIOS 引导模块 |
| `mtools` | `mformat`（制作 EFI FAT 镜像） |
| `live-boot` | initrd 内的 live 钩子脚本 |
| `live-boot-initramfs-tools` | 将 live-boot 集成进 initramfs |

---

## 九、实施步骤

### 前置条件

- Ubuntu 22.04，已安装并正常运行
- 以 root 权限运行
- 输出目录有足够空间（建议预留系统体积 × 1.5）

### 执行步骤

```bash
# 1. 下载脚本
curl -O https://raw.githubusercontent.com/Pu-Miao/ubuntu-live-cd-guide/main/make-live-iso.sh

# 2. 赋予执行权限
chmod +x make-live-iso.sh

# 3. 执行（默认输出到 /root/live-output）
sudo bash make-live-iso.sh

# 或指定输出目录
sudo bash make-live-iso.sh /data/iso-output
```

### 预计耗时

| 步骤 | 耗时估算 |
|------|----------|
| 安装依赖 | 1~3 分钟 |
| 重建 initrd | 1~2 分钟 |
| 创建 squashfs（xz 压缩） | **20~60 分钟**（取决于系统体积和 CPU） |
| 生成 ISO | 2~5 分钟 |

> squashfs 压缩阶段耗时最长。如需加快速度，将 `SQUASHFS_COMP` 改为 `gzip` 或 `lz4`，压缩率降低但速度大幅提升。

### 验证生成结果

```bash
# 检查 ISO 内文件结构
mount -o loop /root/live-output/custom-live-*.iso /mnt
ls -lh /mnt/live/filesystem.squashfs
ls -lh /mnt/boot/
cat /mnt/boot/grub/grub.cfg
umount /mnt

# 验证 squashfs 内 fstab 已替换为 live 版本
unsquashfs -cat /root/live-output/custom-live-*.iso etc/fstab
```

---

## 十、常见问题

**Q：生成的 ISO 能否在 VMware/VirtualBox 中测试？**
在虚拟机中挂载 ISO 作为光驱即可启动，建议先用虚拟机验证后再写入 U 盘。

**Q：启动后进入 emergency mode 怎么办？**
最常见原因是 squashfs 内的 fstab 包含了真实硬盘的挂载条目，导致 systemd 事务冲突。当前脚本已通过临时替换 fstab 解决此问题。如仍出现，进入 emergency shell 执行 `cat /etc/fstab` 确认 fstab 内容。

**Q：toram 模式需要多少内存？**
内存需求 ≈ squashfs 解压后大小（即 `filesystem.size` 的值），通常是压缩包体积的 2~3 倍，建议 ≥ 4GB。

**Q：squashfs 超过 4GB 如何处理？**
脚本会自动检测，超过 4GB 时通过 PATH 注入 xorriso 包装脚本，向 `xorriso -as mkisofs` 追加 `-iso-level 3` 参数解除单文件 4GB 限制。

**Q：Live 环境中的修改如何持久化？**
默认修改在重启后丢失。若需持久化，可在 U 盘上创建 `persistence` 分区并在内核参数中添加 `persistence`，由 live-boot 自动挂载。

**Q：`update-initramfs` 回退到系统 initrd 有什么风险？**
若系统原装 initrd 未包含 live-boot 钩子，Live 启动会失败并卡在 initramfs shell。建议确保 `live-boot` 安装后再运行脚本。

**Q：脚本中途失败，fstab 会丢失吗？**
不会。脚本用 `trap EXIT` 注册了自动还原钩子，任何情况下（包括 `set -e` 触发的报错退出）都会执行 `cp fstab.bak /etc/fstab` 还原。