# Android

用 Android NDK 交叉编译常用用户态工具（动态 PIE，适配 Bionic）。  
每个软件一个子目录，后续可继续加 `coreutils/`、`toybox/` 等。

## 目录结构

```
.
├── bash/                      # GNU bash 包
│   ├── build.sh               # 交叉编译入口
│   ├── compat/android_compat.c
│   ├── out/<abi>/bash         # 本地构建产物（gitignore）
│   └── README.md
├── common/
│   └── env-ndk.sh             # 各包共用的 NDK 环境
├── .github/workflows/
│   └── build-bash.yml         # bash 手动触发 CI
├── .gitignore
└── README.md                  # 本文件
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
| [bash](bash/) | GNU bash（动态 PIE） | `./bash/build.sh arm64` | [Build Android bash](.github/workflows/build-bash.yml) |

## 快速开始（bash）

```bash
source common/env-ndk.sh
./bash/build.sh arm64          # 或多 ABI: arm64 arm / all
adb push bash/out/arm64-v8a/bash /data/local/tmp/bash
adb shell chmod 755 /data/local/tmp/bash
adb shell /data/local/tmp/bash --version
```

CI 产物命名：`bash-<version>-<abi>`（每个 ABI 单独文件，不打 zip）。  
详见 [bash/README.md](bash/README.md)。
