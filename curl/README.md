# curl

交叉编译 **官方 curl** 到 Android（非 Termux 包）。

- 源码：https://curl.se/download/curl-8.21.0.tar.xz
- TLS：官方 OpenSSL（静态链入）
- 压缩：官方 zlib（静态链入）
- 链接：curl 本体 **dynamic PIE**（只依赖系统 `libc.so` / `libdl.so`）

## 构建

```bash
# 仓库根目录
source common/env-ndk.sh

./curl/build.sh                          # 默认 arm64，curl 8.21.0
./curl/build.sh arm64
./curl/build.sh arm64 arm
./curl/build.sh all

CURL_VER=8.21.0 OPENSSL_VER=3.3.3 ZLIB_VER=1.3.1 ./curl/build.sh arm64
API=28 NDK=/opt/android-ndk-r27d ./curl/build.sh arm64
```

产物：

```
curl/out/<abi>/curl
curl/out/<abi>/curl.unstripped
curl/out/<abi>/BUILD_INFO.txt
```

## 推到手机

```bash
# 推荐：整包推送（含 CA）
adb push curl/out/arm64-v8a /data/local/tmp/curl-root
adb shell chmod 755 /data/local/tmp/curl-root/curl /data/local/tmp/curl-root/curl.sh
adb shell /data/local/tmp/curl-root/curl.sh --version
adb shell /data/local/tmp/curl-root/curl.sh -I https://example.com

# 或手动指定 CA：
adb shell 'CURL_CA_BUNDLE=/data/local/tmp/curl-root/cacert.pem /data/local/tmp/curl-root/curl -I https://example.com'
```

> Android 没有 Linux 那套 `/etc/ssl/certs` PEM 目录。  
> 以前 Release 只传裸二进制时，HTTPS 会因找不到 CA 失败。现在包内自带 `cacert.pem`，并用 `curl.sh` 自动设置 `CURL_CA_BUNDLE`。

## 编译选项

| 项 | 值 | 说明 |
|----|-----|------|
| curl | 官方 tarball | curl.se |
| OpenSSL | 静态 `libssl.a` + `libcrypto.a` | android-* OpenSSL targets |
| zlib | 静态 `libz.a` | 官方 madler/zlib |
| curl 链接 | dynamic PIE | 避免 arm64 静态 TLS abort |
| HTTP/2 | 关 | 未编 nghttp2（可后续加） |
| CA | **Mozilla cacert.pem** | 编译时 `--with-ca-embed` + 包内 `cacert.pem`；推荐用 `curl.sh` |

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `CURL_VER` | `8.21.0` | curl 版本 |
| `OPENSSL_VER` | `3.3.3` | OpenSSL 版本 |
| `ZLIB_VER` | `1.3.1` | zlib 版本 |
| `API` | `24` | min Android API |
| `BUILD_ROOT` | `/tmp/curl-android-build` | 构建缓存 |
| `NDK` | 自动探测 | NDK 路径 |

中间产物：`$BUILD_ROOT/prefix-<ABI>/`（OpenSSL + zlib 安装前缀）。

## GitHub Actions

`.github/workflows/build-curl.yml`（手动触发）

| 参数 | 默认 |
|------|------|
| `curl_version` | `8.21.0` |
| `openssl_version` | `3.3.3` |
| `zlib_version` | `1.3.1` |
| `api` | `24` |
| `abi_*` 勾选 | 全 true |
| `ndk_version` | `r27d` |
| `create_release` | false |

Release 资产（**每个 ABI 一个 tar.gz 包**，含 CA 与可选 lib）：

- `curl-8.21.0-arm64.tar.gz`
- `curl-8.21.0-arm.tar.gz`
- …

包内结构：

```
curl-8.21.0-arm64/
  curl
  cacert.pem      # Mozilla CA，HTTPS 必需
  curl.sh         # 自动设置 CURL_CA_BUNDLE
  README.txt
  lib/            # 仅 dynamic 构建
```

## 目录

```
curl/
├── build.sh
├── out/                 # gitignore
└── README.md
```
