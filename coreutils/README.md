# coreutils

交叉编译 **官方 GNU coreutils**（非 Termux 包）到 Android。

- 源码：`https://ftp.gnu.org/gnu/coreutils/coreutils-<ver>.tar.xz`
- 链接：**dynamic PIE**（仅依赖系统 `libc.so`）
- 形态：`--enable-single-binary=symlinks`（一个 `coreutils` + 一堆 applet 符号链接）

## 构建

```bash
# 仓库根目录
source common/env-ndk.sh

./coreutils/build.sh              # 默认 arm64，coreutils 9.5，API 24
./coreutils/build.sh arm64
./coreutils/build.sh arm64 arm
./coreutils/build.sh all

COREUTILS_VER=9.5 API=28 ./coreutils/build.sh arm64
NDK=/opt/android-ndk-r27d ./coreutils/build.sh arm64
```

产物：

```
coreutils/out/<abi>/bin/coreutils
coreutils/out/<abi>/bin/ls -> coreutils
coreutils/out/<abi>/bin/cp -> coreutils
...
coreutils/out/<abi>/BUILD_INFO.txt
```

## 推到手机

```bash
adb push coreutils/out/arm64-v8a/bin /data/local/tmp/coreutils
adb shell chmod -R 755 /data/local/tmp/coreutils
adb shell /data/local/tmp/coreutils/ls --version
adb shell /data/local/tmp/coreutils/coreutils --help

# 或只推 multicall 本体，用 argv0 / 子命令调用：
adb push coreutils/out/arm64-v8a/bin/coreutils /data/local/tmp/coreutils
adb shell /data/local/tmp/coreutils --coreutils-prog=ls -la /
```

## 编译选项

| 项 | 值 | 说明 |
|----|-----|------|
| 源码 | **GNU 官方 tarball** | mirrors.kernel.org / ftp.gnu.org |
| 链接 | dynamic PIE | 避免 arm64 静态 TLS abort |
| single-binary | symlinks | 单文件 + 符号链接 applet |
| 跳过 | pinky, users, who, stdbuf | 无用 / 需 LD_PRELOAD |
| 无 | gmp / openssl / selinux / acl / xattr / libcap | 减少依赖，纯 Bionic |
| 垫片 | `gethostid` | Bionic 无此符号 |
| 补丁 | `timezone_t` shadow | API &lt; 35 的 Bionic 类型不完整 |

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `COREUTILS_VER` | `9.5` | GNU coreutils 版本 |
| `API` | `24` | min Android API |
| `NO_INSTALL_PROGRAM` | `pinky,users,who,stdbuf` | 不安装的程序列表 |
| `BUILD_ROOT` | `/tmp/coreutils-android-build` | 构建缓存 |
| `NDK` | 自动探测 | NDK 路径 |

## GitHub Actions

`.github/workflows/build-coreutils.yml`（手动触发）

| 参数 | 默认 |
|------|------|
| `coreutils_version` | `9.5` |
| `api` | `24` |
| `abi_*` 勾选 | 全 true |
| `ndk_version` | `r27d` |
| `create_release` | false |

Release 资产（每个 ABI 单独一个 multicall，不打 zip）：

- `coreutils-9.5-arm64`
- `coreutils-9.5-arm`
- …

## 目录

```
coreutils/
├── build.sh
├── compat/android_compat.c
├── patches/
│   ├── 0001-android-timezone_t-shadow.patch
│   └── 0002-android-gethostid-decl.patch
├── out/                    # gitignore
└── README.md
```
