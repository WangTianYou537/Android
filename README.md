# Android

用 Android NDK 交叉编译常用用户态工具（动态 PIE，适配 Bionic）。  
每个软件一个子目录，后续可继续加 `coreutils/`、`toybox/` 等。

## 目录结构

```
.
├── bash/                      # GNU bash 包（静态 ncurses + readline）
├── coreutils/                 # 官方 GNU coreutils（single-binary）
├── curl/                      # 官方 curl（OpenSSL 静态）
├── openssh/                   # 官方 OpenSSH portable
├── git/                       # 官方 git（HTTPS/OpenSSL 静态）
│   ├── build.sh
│   ├── compat/android_compat.c
│   ├── out/<abi>/…            # gitignore
│   └── README.md
├── jdk/
│   └── jdk17/                 # OpenJDK 17 (headless JRE/JDK)
│       ├── build.sh
│       ├── patches/
│       ├── jre_override/
│       ├── out/<abi>/…        # gitignore
│       └── README.md
├── common/
│   ├── env-ndk.sh             # 各包共用的 NDK 环境
│   └── deps/                  # 共享 .so（zlib/openssl/libcurl）
├── build-all-dynamic.sh       # 动态链接一键编 curl+openssh+git
├── .github/workflows/
│   ├── build-bash.yml
│   └── build-jdk17.yml
├── .gitignore
└── README.md
```

约定（后续新包照此加）：

| 路径 | 含义 |
|------|------|
| `<pkg>/build.sh` | 该包的构建脚本 |
| `<pkg>/out/<abi>/…` | 该包产出 |
| `<pkg>/compat/` | 包私有垫片 / 补丁（可选） |
| `common/` | 跨包共享（NDK env、通用脚本） |
| `.github/workflows/build-<pkg>.yml` | 该包 CI |

## NDK 环境

推荐永久安装：

```bash
# 已解压到 /opt 时
source common/env-ndk.sh
echo $NDK
```

也支持：

- 环境变量 `NDK` / `ANDROID_NDK_HOME`
- 仓库根目录下的 `android-ndk-r27d` 符号链接
- `$HOME/Android/Sdk/ndk/*`

## 包列表

| 包 | 说明 | 本地构建 | CI |
|----|------|----------|-----|
| [bash](bash/) | GNU bash（动态 PIE + 静态 ncurses/readline） | `./bash/build.sh arm64` | [Build Android bash](.github/workflows/build-bash.yml) |
| [coreutils](coreutils/) | 官方 GNU coreutils（multicall） | `./coreutils/build.sh arm64` | [Build Android coreutils](.github/workflows/build-coreutils.yml) |
| [curl](curl/) | 官方 curl 8.x（HTTPS / OpenSSL 静态） | `./curl/build.sh arm64` | [Build Android curl](.github/workflows/build-curl.yml) |
| [openssh](openssh/) | 官方 OpenSSH portable（ssh/sshd） | `./openssh/build.sh arm64` | [Build Android OpenSSH](.github/workflows/build-openssh.yml) |
| [git](git/) | 官方 git（HTTPS via 静态 libcurl/OpenSSL） | `./git/build.sh arm64` | [Build Android git](.github/workflows/build-git.yml) |
| [jdk/jdk17](jdk/jdk17/) | OpenJDK 17 headless JRE/JDK | `./jdk/jdk17/build.sh arm64` | [Build Android JDK 17](.github/workflows/build-jdk17.yml) |



## Release 打包约定

所有 package workflow 的 Release / Artifact 统一为：

```
<pkg>-<version>-<abi>.tar.gz
```

包内是该 ABI **实际产出的全部文件**（不再只传裸二进制）。例如：

| 包 | 示例压缩包 | 包内典型内容 |
|----|------------|--------------|
| bash | `bash-5.3-arm64.tar.gz` | `bash`, `BUILD_INFO.txt`（+ terminfo/ 若有） |
| coreutils | `coreutils-9.11-arm64.tar.gz` | `bin/*`（multicall+symlinks）, `BUILD_INFO.txt` |
| curl | `curl-8.21.0-arm64.tar.gz` | `curl`, `cacert.pem`, `curl.sh`, `BUILD_INFO.txt`（+ `lib/`） |
| openssh | `openssh-9.9p2-arm64.tar.gz` | `ssh`/`scp`/`sshd`/…, `BUILD_INFO.txt`（+ `lib/`） |
| git | `git-2.49.0-arm64.tar.gz` | `bin/`, `libexec/`, `BUILD_INFO.txt`（+ `lib/`） |
| jdk17 | `jdk17-<tag>-arm64.tar.gz` | `out/<ABI>/` 下全部（含 jre/jdk 的 tar.xz 与 BUILD_INFO） |

实现：`common/package-release.sh`。本地也可：

```bash
source common/package-release.sh
package_abi_releases bash 5.3 bash/out
```

## 动态链接模式（共享 OpenSSL / libcurl）

默认各包仍是 **静态嵌入** 依赖（单文件推送）。若要共享 `.so`、减小体积：

```bash
# 1) 编共享库
./common/deps/build.sh arm64

# 2) 各包动态链接（或一键）
LINK_MODE=dynamic ./curl/build.sh arm64
LINK_MODE=dynamic ./openssh/build.sh arm64
LINK_MODE=dynamic ./git/build.sh arm64
# 等价于：
./build-all-dynamic.sh arm64
```

CI：Actions → **Build all dynamic**（产出 `android-dynamic-<abi>.tar.gz`）。

| 模式 | 体积 | 推送 |
|------|------|------|
| static（默认） | 大（OpenSSL 打进每个二进制） | 单文件即可 |
| dynamic | 小（`.so` 共享） | 需带 `lib/` 目录 |

## 快速开始

### git

```bash
source common/env-ndk.sh
./git/build.sh arm64
adb push git/out/arm64-v8a/bin/git /data/local/tmp/git
adb shell /data/local/tmp/git --version
```

详见 [git/README.md](git/README.md)。

### openssh

```bash
source common/env-ndk.sh
./openssh/build.sh arm64
adb push openssh/out/arm64-v8a/ssh /data/local/tmp/ssh
adb shell /data/local/tmp/ssh -V
```

详见 [openssh/README.md](openssh/README.md)。

### curl

```bash
source common/env-ndk.sh
./curl/build.sh arm64          # 官方 curl 8.21.0 + OpenSSL + zlib
adb push curl/out/arm64-v8a/curl /data/local/tmp/curl
adb shell /data/local/tmp/curl --version
```

详见 [curl/README.md](curl/README.md)。

### coreutils

```bash
source common/env-ndk.sh
./coreutils/build.sh arm64
adb push coreutils/out/arm64-v8a/bin /data/local/tmp/coreutils
adb shell /data/local/tmp/coreutils/ls --version
```

源码为 **GNU 官方** tarball（非 Termux）。详见 [coreutils/README.md](coreutils/README.md)。

### bash

```bash
source common/env-ndk.sh
./bash/build.sh arm64          # 或多 ABI: arm64 arm / all
adb push bash/out/arm64-v8a/bash /data/local/tmp/bash
adb shell chmod 755 /data/local/tmp/bash
adb shell /data/local/tmp/bash --version
```

CI 产物命名：`bash-<version>-<abi>`（每个 ABI 单独文件，不打 zip）。  
详见 [bash/README.md](bash/README.md)。

### jdk17

```bash
source common/env-ndk.sh
./jdk/jdk17/build.sh arm64          # 约 1–3 小时
adb push jdk/jdk17/out/arm64-v8a/jre17-arm64.tar.xz /data/local/tmp/
adb shell 'mkdir -p /data/local/tmp/jre17 && tar -xJf /data/local/tmp/jre17-arm64.tar.xz -C /data/local/tmp/jre17'
adb shell /data/local/tmp/jre17/bin/java -version
```

CI 产物：`jre17-<abi>.tar.xz` / `jdk17-<abi>.tar.xz`（每个 ABI 单独文件）。  
详见 [jdk/jdk17/README.md](jdk/jdk17/README.md)。
