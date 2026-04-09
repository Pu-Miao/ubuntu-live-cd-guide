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

理解封装逻辑，首先要理解 Live CD **从开机到桌面**经历了哪几个阶段：

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

---

### Step 2：制作 squashfs —— 打包系统快照

这一步是把运行中的根文件系统 `/` 压缩成一个只读的镜像文件。

**两个核心问题需要处理：**

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

解决方案是用 `mksquashfs` 的 `-p` 参数，**在 squashfs 中强制创建空目录作为挂载点**，即使这些目录在打包时被排除了：

```bash
mksquashfs / output.squashfs \
    -e /proc -e /sys -e /dev ...   # 排除真实内容
    -p "/proc d 755 0 0"            # 但保留目录条目
    -p "/dev  d 755 0 0"
    -p "/tmp  d 1777 0 0"
    ...
```

---

### Step 3：filesystem.size —— 一个小但不能少的文件

```bash
unsquashfs -stat filesystem.squashfs | grep "Filesystem size"
```

这个文件记录的是 squashfs **解压后**的字节数。`live-boot` 在 `toram`（加载到内存）模式下用它判断内存是否够用，也用于显示加载进度条。文件不存在不会报错，但会影响用户体验和 toram 功能。

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

---

### Step 5：grub-mkrescue —— 把目录变成可引导 ISO

这一步解决的是：**一个 ISO 文件如何同时被 BIOS 和 UEFI 的机器识别为可引导设备？**

```
grub-mkrescue 内部做的事：

iso/ 目录
    │
    ├── 写入 El Torito 引导记录    → BIOS 机器从这里找到引导程序
    │   (来自 grub-pc-bin)
    │
    ├── 创建 EFI 系统分区 (FAT)    → UEFI 机器从这里找到 EFI 程序
    │   (来自 grub-efi-amd64-bin)
    │   (mtools/mformat 用于创建 FAT 镜像)
    │
    └── 用 xorriso 封装为标准 ISO 9660 格式
```

**为什么需要 `mtools`？** UEFI 要求 EFI 分区是 FAT 格式，`grub-mkrescue` 需要在不 root 挂载的情况下创建 FAT 镜像，`mformat` 可以在普通文件上格式化出 FAT，无需挂载循环设备。

---

## 五、整体数据流

```
运行中的系统 /
│
├─── /boot/vmlinuz-*  ──────────────────────────────→ iso/boot/vmlinuz
│
├─── /boot/initrd.img-* (系统原装，可能无 live 钩子)
│         或
│    update-initramfs 重新生成 (含 live-boot 钩子)  → iso/boot/initrd.img
│
└─── / (根文件系统，排除虚拟目录和生成物)
          │
          mksquashfs 压缩                            → iso/live/filesystem.squashfs
          unsquashfs -stat 提取大小                  → iso/live/filesystem.size
          手动写入                                   → iso/boot/grub/grub.cfg
                                                              │
                                                   grub-mkrescue 封装
                                                              │
                                                              ▼
                                                   custom-live-YYYYMMDD.iso
```

---

## 六、Live 系统启动后的文件系统结构

了解启动后的结构有助于理解为什么修改不会持久化：

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

这就是 Live CD 每次启动都是"全新"状态的根本原因。

---

## 七、依赖关系汇总

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

## 八、常见问题

**Q：生成的 ISO 能否在 VMware/VirtualBox 中测试？**
在虚拟机中挂载 ISO 作为光驱即可启动，建议先用虚拟机验证后再写入 U 盘。

**Q：toram 模式需要多少内存？**
内存需求 ≈ squashfs 解压后大小（即 `filesystem.size` 的值），通常是压缩包体积的 2~3 倍，建议 ≥ 4GB。

**Q：Live 环境中的修改如何持久化？**
默认修改在重启后丢失。若需持久化，可在 U 盘上创建 `persistence` 分区并在内核参数中添加 `persistence`，由 live-boot 自动挂载。

**Q：`update-initramfs` 回退到系统 initrd 有什么风险？**
若系统原装 initrd 未包含 live-boot 钩子，Live 启动会失败并卡在 initramfs shell。建议确保 `live-boot` 安装后再运行脚本。