# Bash4droid

用 Android NDK **r27d** 交叉编译 **GNU bash 5.2.37**，产出可直接推到手机上的 **PIE 动态链接** 可执行文件（只依赖系统 `libc.so` / `libdl.so`）。

## 已构建产物

| ABI | 路径 | 说明 |
|-----|------|------|
| arm64-v8a (aarch64) | `out/arm64-v8a/bash` | 已 strip，约 755KB，API 24+ |

```
out/arm64-v8a/bash          # 推到设备使用
out/arm64-v8a/bash.unstripped
out/arm64-v8a/BUILD_INFO.txt
```

## 推到手机运行

```bash
adb push out/arm64-v8a/bash /data/local/tmp/bash
adb shell chmod 755 /data/local/tmp/bash
adb shell /data/local/tmp/bash --version
adb shell /data/local/tmp/bash -c 'echo hello; uname -a; id'
# 交互 shell
adb shell /data/local/tmp/bash -i
```

> 无 root 时推荐路径：`/data/local/tmp/`、`/sdcard/`（后者可能 noexec，需拷到可执行目录）。

## NDK 环境（已配置）

NDK 已持久解压到系统盘：

```
/opt/android-ndk-r27d
```

项目内符号链接：`android-ndk-r27d -> /opt/android-ndk-r27d`

用户环境变量已写入 `~/.bashrc`（新开终端自动生效）：

```bash
export ANDROID_NDK_HOME=/opt/android-ndk-r27d
export ANDROID_NDK_ROOT=/opt/android-ndk-r27d
export NDK=/opt/android-ndk-r27d
export PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
```

当前会话可立即加载：

```bash
source ~/.bashrc
# 或仅加载本项目辅助脚本
source ./env-ndk.sh
```

验证：

```bash
echo $NDK
aarch64-linux-android24-clang --version
```

原始压缩包仍保留：`android-ndk-r27d-linux.zip`。

## 重新编译

```bash
./build-android-bash.sh            # 默认 arm64 API 24
./build-android-bash.sh arm64
./build-android-bash.sh arm        # armeabi-v7a
./build-android-bash.sh x86_64
./build-android-bash.sh x86
./build-android-bash.sh all        # 四个 ABI

API=28 ./build-android-bash.sh arm64   # 指定 min API
NDK=/opt/android-ndk-r27d ./build-android-bash.sh arm64
```

构建中间文件默认在 `/tmp/bash4droid-build/`，成品在 `out/<ABI>/bash`。

## 编译选项说明

| 选项 | 值 | 原因 |
|------|-----|------|
| 链接方式 | **dynamic PIE** | 静态链接在 arm64 Bionic 会因 TLS 对齐 abort（见下） |
| `--disable-readline` | 关 | 避免再编 ncurses/readline；行编辑用 bash 内置 |
| `--without-bash-malloc` | 开 | 使用系统 malloc，在 bionic 上更稳 |
| `--disable-nls` | 开 | 减小体积、少依赖 |
| `compat/android_compat.c` | mblen | Bionic 不导出 `mblen`，用 `mbrlen` 垫片 |
| API | 默认 24 | 覆盖 Android 7.0+ 主流设备 |

### 为何不用全静态？

现代 Android arm64 的 Bionic 要求 TLS 段对齐 ≥ 64。NDK 全静态链接出来的 TLS 对齐常为 8，运行时直接：

```
executable's TLS segment is underaligned: alignment is 8, needs to be at least 64 for ARM64 Bionic
Aborted
```

因此改为链接系统 `libc.so`/`libdl.so`（每台设备都有）。

如需 **readline 补全/历史编辑**，需先为同一 ABI 交叉编译 ncurses + readline，再去掉 `--disable-readline` 并加上对应 `CPPFLAGS`/`LDFLAGS`。

## 目录结构

```
Bash4droid/
├── android-ndk-r27d-linux.zip   # 原始 NDK 压缩包
├── android-ndk-r27d -> /opt/android-ndk-r27d
├── build-android-bash.sh        # 一键交叉编译
├── env-ndk.sh                   # source 后设置 NDK/PATH
├── compat/android_compat.c      # Bionic mblen 垫片
├── out/
│   └── arm64-v8a/
│       ├── bash
│       ├── bash.unstripped
│       └── BUILD_INFO.txt
└── README.md
```

## 验证信息（arm64-v8a）

- GNU bash **5.2.37**
- ELF 64-bit LSB **pie executable**, dynamically linked (`/system/bin/linker64`), ARM aarch64, stripped
- NEEDED: `libc.so`, `libdl.so`；无 TLS PHDR
- NDK r27d (27.3.13750724) + clang 18, target `aarch64-linux-android24`

## GitHub Actions（手动触发）

Workflow 文件：`.github/workflows/build-bash.yml`

### 触发方式

1. 打开仓库 **Actions** → **Build Android bash**
2. 点 **Run workflow**
3. 填写参数后运行

| 参数 | 说明 | 默认 |
|------|------|------|
| `bash_version` | GNU bash 版本号，如 `5.2.37` / `5.3` | `5.2.37` |
| `api` | 最低 Android API（21–35） | `24` |
| `abis` | `all` / `arm64` / `arm` / `x86_64` / `x86` | `all` |
| `ndk_version` | NDK 发行名，对应 Google 包名 `android-ndk-<name>-linux.zip` | `r27d` |
| `create_release` | 是否额外打 GitHub Release（tag `bash-<ver>-api<api>`） | `false` |

### 命令行触发

```bash
gh workflow run build-bash.yml \
  -f bash_version=5.2.37 \
  -f api=24 \
  -f abis=arm64 \
  -f ndk_version=r27d \
  -f create_release=false
```

### 产物

- **Artifacts**：`bash-<version>-android-api<api>.zip`（保留 30 天）
- 若勾选 `create_release`：创建同名 tag 的 Release，内含 zip 与各 ABI 的 `bash`

NDK 在 runner 上缓存；第二次同版本 NDK 构建会跳过下载。

