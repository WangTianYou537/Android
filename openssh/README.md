# openssh

交叉编译 **官方 OpenSSH Portable** 到 Android（非 Termux 包）。

- 源码：https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/
- TLS：官方 OpenSSL（静态链入）
- zlib：官方 zlib（静态链入）
- 链接：客户端/服务端 **dynamic PIE**（只依赖系统 `libc.so` / `libdl.so`）

## 构建

```bash
source common/env-ndk.sh
./openssh/build.sh                 # 默认 arm64，OpenSSH 9.9p2
./openssh/build.sh arm64
./openssh/build.sh all

OPENSSH_VER=9.9p2 OPENSSL_VER=3.3.3 ZLIB_VER=1.3.1 ./openssh/build.sh arm64
```

若本机已编过 `curl/`，脚本会自动复用 `/tmp/curl-android-build/prefix-<ABI>/` 的 OpenSSL/zlib。

产物：

```
openssh/out/<abi>/ssh
openssh/out/<abi>/scp
openssh/out/<abi>/sftp
openssh/out/<abi>/sshd
openssh/out/<abi>/ssh-keygen
...
openssh/out/<abi>/BUILD_INFO.txt
```

## 推到手机

```bash
adb push openssh/out/arm64-v8a/ssh /data/local/tmp/ssh
adb push openssh/out/arm64-v8a/ssh-keygen /data/local/tmp/ssh-keygen
adb shell chmod 755 /data/local/tmp/ssh /data/local/tmp/ssh-keygen
adb shell /data/local/tmp/ssh -V
# 生成密钥 / 连接示例
adb shell /data/local/tmp/ssh-keygen -t ed25519 -f /data/local/tmp/id_ed25519 -N ''
adb shell /data/local/tmp/ssh -i /data/local/tmp/id_ed25519 user@host
```

`sshd` 可推送使用，但 privsep chroot 默认 `/data/local/tmp/ssh/empty`，需自备配置与权限，非 root 设备上通常只能当客户端。

## Android 适配

| 问题 | 处理 |
|------|------|
| 全静态 TLS | dynamic PIE |
| `mblen` 宏与 Bionic 冲突 | 补丁禁用 Android 上空宏 |
| `bzero` 为 Bionic 宏 | `explicit_bzero` 改用 memset |
| `getrrsetbyname` / resolver | stub 始终失败（DNSSEC 路径不可用） |
| API&lt;26 `getpwent` | compat stub |
| `__sentinel__` | 强制 `HAVE_ATTRIBUTE__SENTINEL__` |
| 无 `_PATH_MAILDIR` | `MAIL_DIRECTORY=/data/local/tmp/ssh/mail` |

## GitHub Actions

`.github/workflows/build-openssh.yml`（手动触发）

Release 资产按二进制命名：`ssh-<ver>-<abi>`、`sshd-<ver>-<abi>` 等。

## 目录

```
openssh/
├── build.sh
├── compat/android_compat.c
├── patches/
├── out/
└── README.md
```
