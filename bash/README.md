# bash

用 Android NDK 交叉编译 **GNU bash**，产出 **PIE 动态链接** 可执行文件（只依赖系统 `libc.so` / `libdl.so`）。

## 构建

```bash
# 在仓库根目录
source common/env-ndk.sh

./bash/build.sh                 # 默认 arm64，API 24
./bash/build.sh arm64
./bash/build.sh arm64 arm       # 多 ABI
./bash/build.sh all

API=28 ./bash/build.sh arm64
BASH_VER=5.2.37 ./bash/build.sh all
NDK=/path/to/ndk ./bash/build.sh arm64
```

产物：

```
bash/out/<abi>/bash
bash/out/<abi>/bash.unstripped
bash/out/<abi>/BUILD_INFO.txt
```

| ABI 参数 | 输出目录 |
|----------|----------|
| `arm64` | `bash/out/arm64-v8a/` |
| `arm` | `bash/out/armeabi-v7a/` |
| `x86_64` | `bash/out/x86_64/` |
| `x86` | `bash/out/x86/` |

## 推到手机

```bash
adb push bash/out/arm64-v8a/bash /data/local/tmp/bash
adb shell chmod 755 /data/local/tmp/bash
adb shell /data/local/tmp/bash --version
adb shell /data/local/tmp/bash -i
```

## 编译选项

| 选项 | 值 | 原因 |
|------|-----|------|
| 链接 | **dynamic PIE** | 全静态在 arm64 Bionic 会因 TLS 对齐 abort |
| `--disable-readline` | 关 | 避免再编 ncurses/readline |
| `--without-bash-malloc` | 开 | 使用系统 malloc，在 Bionic 上更稳 |
| `--disable-nls` | 开 | 减小体积 |
| `compat/android_compat.c` | `mblen` | Bionic 不导出 `mblen`，用 `mbrlen` 垫片 |
| API | 默认 24 | Android 7.0+ |

### 为何不用全静态？

```
executable's TLS segment is underaligned: alignment is 8, needs to be at least 64 for ARM64 Bionic
Aborted
```

## GitHub Actions

Workflow：`.github/workflows/build-bash.yml`（手动触发）

| 参数 | 说明 | 默认 |
|------|------|------|
| `bash_version` | 如 `5.2.37` / `5.3` | `5.2.37` |
| `api` | 最低 API 21–35 | `24` |
| `abi_arm64` / `abi_arm` / `abi_x86_64` / `abi_x86` | 勾选要编的 ABI | 全 true |
| `ndk_version` | 如 `r27d` | `r27d` |
| `create_release` | 是否发 Release | `false` |

**Release 资产（不打 zip，逐个上传）：**

| 文件 | 说明 |
|------|------|
| `bash-5.2.37-arm64` | aarch64 裸二进制 |
| `bash-5.2.37-arm` | armv7 |
| `bash-5.2.37-x86_64` | x86_64 |
| `bash-5.2.37-x86` | x86 |

Tag：`bash-<version>`。同版本重跑会覆盖同名资产。

```bash
gh workflow run build-bash.yml \
  -f bash_version=5.2.37 \
  -f abi_arm64=true \
  -f abi_arm=false \
  -f abi_x86_64=false \
  -f abi_x86=false \
  -f create_release=true

gh release download bash-5.2.37 -p 'bash-5.2.37-arm64'
```

## 目录

```
bash/
├── build.sh
├── compat/android_compat.c
├── out/                 # gitignore
└── README.md
```
