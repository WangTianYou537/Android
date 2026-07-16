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
adb push curl/out/arm64-v8a/curl /data/local/tmp/curl
adb shell chmod 755 /data/local/tmp/curl
adb shell /data/local/tmp/curl --version
adb shell /data/local/tmp/curl -I https://example.com
```

## 编译选项

| 项 | 值 | 说明 |
|----|-----|------|
| curl | 官方 tarball | curl.se |
| OpenSSL | 静态 `libssl.a` + `libcrypto.a` | android-* OpenSSL targets |
| zlib | 静态 `libz.a` | 官方 madler/zlib |
| curl 链接 | dynamic PIE | 避免 arm64 静态 TLS abort |
| HTTP/2 | 关 | 未编 nghttp2（可后续加） |
| CA | `--with-ca-fallback` | 可用系统/内置回退；也可用 `--cacert` |

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

Release 资产（每个 ABI 单独文件，不打 zip）：

- `curl-8.21.0-arm64`
- `curl-8.21.0-arm`
- …

## 目录

```
curl/
├── build.sh
├── out/                 # gitignore
└── README.md
```
