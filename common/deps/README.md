# common/deps

共享动态库（per-ABI），供 `curl` / `openssh` / `git` 在 `LINK_MODE=dynamic` 下复用，避免各自静态编一份 OpenSSL。

## 构建

```bash
source common/env-ndk.sh
./common/deps/build.sh arm64
./common/deps/build.sh all
```

产物：

```
common/deps/out/<ABI>/lib/
  libz.so*
  libssl.so*
  libcrypto.so*
  libcurl.so*
common/deps/out/<ABI>/include/
```

## 被谁使用

| 包 | 动态依赖 |
|----|----------|
| curl | libcurl, libssl, libcrypto, libz |
| openssh | libssl, libcrypto, libz |
| git | libcurl, libssl, libcrypto, libz |

## 一键动态构建

```bash
./build-all-dynamic.sh arm64
# 或 CI: Actions → "Build all dynamic"
```

设备上保持相对布局：

```
/data/local/tmp/tools/
  lib/*.so
  bin/curl
  openssh/ssh
  git/git
```

二进制 rpath 为 `$ORIGIN/../lib`（或 curl 的 `$ORIGIN/lib`）。
