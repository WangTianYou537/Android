# jdk17

用 **Android NDK r27d + clang** 交叉编译 **OpenJDK 17**（headless JRE/JDK），产出可推到 Android 设备的运行时。

基于 [FCL-Team/Android-OpenJDK-Build](https://github.com/FCL-Team/Android-OpenJDK-Build) 的 `Build_JRE_17` Android 补丁，**不依赖 NDK r21 / GCC standalone toolchain**。

## 环境

| 项 | 值 |
|----|-----|
| NDK | `/opt/android-ndk-r27d`（或 `source common/env-ndk.sh`） |
| Boot JDK | 主机 OpenJDK 17（`openjdk-17-jdk-headless`） |
| 默认目标 | `arm64-v8a` / API 24 |
| 中间目录 | `BUILD_ROOT` 默认 `/tmp/android-jdk-build` |

```bash
sudo apt install -y openjdk-17-jdk-headless autoconf python3 python-is-python3 \
  unzip zip libxtst-dev libasound2-dev libelf-dev libfontconfig1-dev \
  libx11-dev libxext-dev libxrandr-dev libxrender-dev libxt-dev file clang

# 仓库根目录
source common/env-ndk.sh
```

## 编译

```bash
# 在仓库根目录
./jdk/jdk17/build.sh                 # 默认 arm64, API 24
./jdk/jdk17/build.sh arm64
./jdk/jdk17/build.sh arm64 x86_64    # 多 ABI
./jdk/jdk17/build.sh all

API=28 JOBS=2 ./jdk/jdk17/build.sh arm64
JDK_TAG=jdk-17.0.10-ga ./jdk/jdk17/build.sh arm64
```

完整 OpenJDK 交叉编译在 4 核机器上通常 **1–3 小时 / ABI**。日志：

```
$BUILD_ROOT/configure-<ABI>.log
$BUILD_ROOT/make-<ABI>.log
```

## 产物

```
jdk/jdk17/out/<ABI>/
  jre/                              # 可运行 JRE 树
  jdk/                              # 完整 JDK 树
  jre17-<abi>-YYYYMMDD-release.tar.xz
  jdk17-<abi>-YYYYMMDD-release.tar.xz
  jre17-<abi>.tar.xz                # 稳定名（CI / Release）
  jdk17-<abi>.tar.xz
  BUILD_INFO.txt
```

### 推到手机

```bash
adb push jdk/jdk17/out/arm64-v8a/jre17-arm64.tar.xz /data/local/tmp/
adb shell 'mkdir -p /data/local/tmp/jre17 && tar -xJf /data/local/tmp/jre17-arm64.tar.xz -C /data/local/tmp/jre17 && chmod -R 755 /data/local/tmp/jre17'
adb shell /data/local/tmp/jre17/bin/java -version
```

无 root 时推荐 `/data/local/tmp/`（`/sdcard` 常 `noexec`）。

## GitHub Actions

Workflow：`.github/workflows/build-jdk17.yml`（手动触发）

| 参数 | 说明 | 默认 |
|------|------|------|
| `jdk_tag` | OpenJDK 17u 标签，如 `jdk-17.0.10-ga` | `jdk-17.0.10-ga` |
| `api` | 最低 API 21–35 | `24` |
| `abi_arm64` | 编 arm64 | ✅ true |
| `abi_arm` / `abi_x86_64` / `abi_x86` | 其它 ABI | false（太慢） |
| `ndk_version` | 如 `r27d` | `r27d` |
| `jobs` | `make -j` | `2` |
| `create_release` | 是否发 Release | `false` |

**Release 资产（每个 ABI 单独 tar.xz，不打总包）：**

| 文件 | 说明 |
|------|------|
| `jre17-arm64.tar.xz` | arm64 JRE |
| `jdk17-arm64.tar.xz` | arm64 完整 JDK |
| `jre17-arm.tar.xz` / … | 其它 ABI 同理 |

Tag：`jdk17-<jdk_tag>`，例如 `jdk17-jdk-17.0.10-ga`。

```bash
gh workflow run build-jdk17.yml \
  -f jdk_tag=jdk-17.0.10-ga \
  -f abi_arm64=true \
  -f create_release=true

gh release download jdk17-jdk-17.0.10-ga -p 'jre17-arm64.tar.xz'
```

> 免费 GitHub runner 磁盘与时间有限；默认只编 arm64，`timeout` 设为 8 小时。

## 目录

```
jdk/jdk17/
├── build.sh
├── patches/jdk17u_android.diff
├── jre_override/          # 字体/fontconfig 覆盖（可选）
├── out/                   # gitignore
└── README.md
```

## 参考

- OpenJDK Mobile / Android: http://openjdk.java.net/projects/mobile/android.html
- FCL Android-OpenJDK-Build: https://github.com/FCL-Team/Android-OpenJDK-Build

## 已知问题 / 修复

### `posix_spawn` undeclared (API &lt; 28)

Bionic 从 **API 28** 才导出 `posix_spawn`。默认 `API=24` 时，系统 `<spawn.h>` 无原型，编译 `ProcessImpl_md.c` 会失败：

```
error: call to undeclared function 'posix_spawn'
```

处理：主补丁提供 `libjava/posix_spawn.{c,h}`（dhcpcd 兼容实现），`build.sh` 会把 `ProcessImpl_md.c` 的 `#include <spawn.h>` 改成 `#include "posix_spawn.h"`。

