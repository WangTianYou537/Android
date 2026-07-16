# git

交叉编译 **官方 git** 到 Android（非 Termux 包）。

- 源码：https://www.kernel.org/pub/software/scm/git/
- HTTPS：官方 libcurl + OpenSSL + zlib（**静态**链入）
- 链接：git 本体 **dynamic PIE**（只依赖系统 `libc.so` / `libdl.so` / `libm.so`）

## 构建

```bash
source common/env-ndk.sh
./git/build.sh                    # 默认 arm64，git 2.49.0
./git/build.sh arm64
./git/build.sh all

GIT_VER=2.49.0 CURL_VER=8.21.0 OPENSSL_VER=3.3.3 ./git/build.sh arm64
```

若本机已编过 `curl/`，会复用 `/tmp/curl-android-build/prefix-<ABI>/` 的 OpenSSL/zlib，并补装静态 `libcurl.a`。

产物：

```
git/out/<abi>/bin/git
git/out/<abi>/bin/git-remote-http
git/out/<abi>/bin/git-remote-https
git/out/<abi>/bin/git-daemon
git/out/<abi>/libexec/git-core/...
git/out/<abi>/BUILD_INFO.txt
```

## 推到手机

```bash
adb push git/out/arm64-v8a/bin/git /data/local/tmp/git
adb push git/out/arm64-v8a/bin/git-remote-http /data/local/tmp/git-remote-http
adb push git/out/arm64-v8a/bin/git-remote-https /data/local/tmp/git-remote-https
adb shell chmod 755 /data/local/tmp/git /data/local/tmp/git-remote-http /data/local/tmp/git-remote-https

# 让 git 找到 remote helpers（同目录或 PATH）
adb shell 'export PATH=/data/local/tmp:$PATH; git --version'
adb shell 'export PATH=/data/local/tmp:$PATH; git clone https://example.com/repo.git /data/local/tmp/repo'
```

更完整布局（含 `libexec/git-core`）：

```bash
adb push git/out/arm64-v8a /data/local/tmp/git-root
adb shell 'export PATH=/data/local/tmp/git-root/bin:$PATH
export GIT_EXEC_PATH=/data/local/tmp/git-root/libexec/git-core
git --version'
```

## 编译选项

| 项 | 值 | 说明 |
|----|-----|------|
| 源码 | 官方 kernel.org | git tarball |
| OpenSSL/zlib/libcurl | 静态 | 单文件推送，无设备共享库依赖 |
| `NO_GETTEXT` | 开 | 无 libintl |
| `NO_PERL` / `NO_PYTHON` | 开 | 无脚本扩展（`git svn` 等不可用） |
| `NO_ICONV` | 开 | 路径编码简化 |
| `NO_EXPAT` | 开 | 无 `git http-push`（smart HTTPS fetch 仍可用） |
| pthreads | 保留 | 用 stub 补 `pthread_setcancelstate` |
| `HAVE_SYNC_FILE_RANGE` | 关 | API &lt; 26 头文件不声明 |

### 环境变量

| 变量 | 默认 |
|------|------|
| `GIT_VER` | `2.49.0` |
| `CURL_VER` | `8.21.0` |
| `OPENSSL_VER` | `3.3.3` |
| `ZLIB_VER` | `1.3.1` |
| `API` | `24` |
| `BUILD_ROOT` | `/tmp/git-android-build` |

## GitHub Actions

`.github/workflows/build-git.yml`（手动触发）

Release 资产示例：`git-2.49.0-arm64`、`git-remote-http-2.49.0-arm64`。

## 目录

```
git/
├── build.sh
├── compat/android_compat.h
├── out/
└── README.md
```
