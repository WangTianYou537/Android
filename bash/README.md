# bash

用 Android NDK 交叉编译 **GNU bash**，产出 **PIE 动态链接** 可执行文件（只依赖系统 `libc.so` / `libdl.so`），并**静态嵌入** ncurses + readline，提供行编辑 / 历史 / Tab 补全。

## 构建

```bash
# 在仓库根目录
source common/env-ndk.sh

./bash/build.sh                 # 默认 arm64，API 24，带 readline
./bash/build.sh arm64
./bash/build.sh arm64 arm       # 多 ABI
./bash/build.sh all

API=28 ./bash/build.sh arm64
BASH_VER=5.3 ./bash/build.sh all
NCURSES_VER=6.5 READLINE_VER=8.3 ./bash/build.sh arm64
NDK=/path/to/ndk ./bash/build.sh arm64
```

产物：

```
bash/out/<abi>/bash
bash/out/<abi>/bash.unstripped
bash/out/<abi>/BUILD_INFO.txt
bash/out/<abi>/terminfo/        # 若 ncurses 安装了 terminfo（通常无，因 --disable-database）
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
adb shell 'export TERM=xterm-256color; /data/local/tmp/bash -i'
```

> ncurses 编入了常用 fallback（xterm / linux / vt100 / screen / tmux / ansi / dumb 等），一般无需设备上的 terminfo 数据库。仍可通过 `TERM` / `TERMINFO` / `TERMINFO_DIRS` 覆盖。

## 编译选项

| 选项 | 值 | 原因 |
|------|-----|------|
| 链接 | **dynamic PIE** | 全静态在 arm64 Bionic 会因 TLS 对齐 abort |
| readline | **静态嵌入** | 行编辑 / 历史 / 补全；不依赖设备共享库 |
| ncurses | **静态 libncursesw + libtinfo(w)** | readline 的 curses/termcap 后端（wide-char） |
| `--without-bash-malloc` | 开 | 使用系统 malloc，在 Bionic 上更稳 |
| `--disable-nls` | 开 | 减小体积 |
| `compat/android_compat.*` | mblen / getgrent / strchrnul | Bionic 缺符号或 API 门控 |
| API | 默认 24 | Android 7.0+ |

### 依赖版本（可覆盖）

| 变量 | 默认 | 说明 |
|------|------|------|
| `BASH_VER` | `5.3` | GNU bash |
| `NCURSES_VER` | `6.5` | GNU ncurses（wide-char，静态） |
| `READLINE_VER` | `8.3` | GNU readline（静态；**bash 5.3 需要 ≥ 8.3**） |
| `API` | `24` | min Android API |
| `BUILD_ROOT` | `/tmp/bash4droid-build` | 源码与 deps 缓存目录 |

中间产物：`$BUILD_ROOT/prefix-<ABI>/`（ncurses + readline 安装前缀）。

### 为何不用全静态 bash？

```
executable's TLS segment is underaligned: alignment is 8, needs to be at least 64 for ARM64 Bionic
Aborted
```

bash 本体仍动态链接 Bionic；仅把 ncurses/readline 以 `.a` 链进二进制。

### Android 兼容说明

- **API &lt; 26**：`getgrent` / `getpwent` 系列不可用 → weak stub，组/用户名补全为空（路径/命令补全正常）
- **mblen**：Bionic 不导出 → `mbrlen` 垫片
- **strchrnul**：强制声明，避免隐式声明错误

## GitHub Actions

Workflow：`.github/workflows/build-bash.yml`（手动触发）

| 参数 | 说明 | 默认 |
|------|------|------|
| `bash_version` | 如 `5.2.37` / `5.3` | `5.3` |
| `readline_version` | 如 `8.2` / `8.3` | `8.3` |
| `ncurses_version` | 如 `6.5` | `6.5` |
| `api` | 最低 API 21–35 | `24` |
| `abi_arm64` / `abi_arm` / `abi_x86_64` / `abi_x86` | 勾选要编的 ABI | 全 true |
| `ndk_version` | 如 `r27d` | `r27d` |
| `create_release` | 是否发 Release | `false` |

**Release 资产（不打 zip，逐个上传）：**

| 文件 | 说明 |
|------|------|
| `bash-5.3-arm64` | aarch64 裸二进制（含 readline） |
| `bash-5.3-arm` | armv7 |
| `bash-5.3-x86_64` | x86_64 |
| `bash-5.3-x86` | x86 |

Tag：`bash-<version>`。同版本重跑会覆盖同名资产。

```bash
gh workflow run build-bash.yml \
  -f bash_version=5.3 \
  -f readline_version=8.3 \
  -f ncurses_version=6.5 \
  -f abi_arm64=true \
  -f abi_arm=false \
  -f abi_x86_64=false \
  -f abi_x86=false \
  -f create_release=true

gh release download bash-5.3 -p 'bash-5.3-arm64'
```

## 目录

```
bash/
├── build.sh
├── compat/
│   ├── android_compat.c
│   └── android_compat.h
├── out/                 # gitignore
└── README.md
```
