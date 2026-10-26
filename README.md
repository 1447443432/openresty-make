> 修正版：Dockerfile 已为 `BUILDER_IMAGE` 设置合法默认值，消除 `InvalidDefaultArgInFrom` 构建检查错误。

# openresty-make

用于通过 GitHub Actions 或本地 Docker，构建 amd64、arm64 两种架构的 OpenResty 可移植安装包，并自动发布到 GitHub Release。

默认行为：

- 自动读取 OpenResty 官方下载页中的最新正式版本；当前回退版本为 `1.31.1.1`。
- 自动从 `openresty/docker-openresty` 官方 Dockerfile 解析当前 OpenSSL、OpenSSL 补丁、PCRE2 版本。
- 构建 `ngx_http_stub_status_module`。
- 默认尝试构建 `nginx_upstream_check_module`。
- 构建 `ngx_http_substitutions_filter_module`。
- 同时生成 amd64、arm64 安装包、SHA256 和构建信息。
- 创建或覆盖同版本 GitHub Release。
- 配置 `HAP_WEBHOOK_URL` 后，将 Release 信息同步到 HAP。

## 项目结构

```text
openresty-make/
├── .github/workflows/build-openresty.yml
├── config/
│   ├── build.conf
│   ├── openresty-version.conf
│   ├── openresty-1.25.conf
│   └── openresty-1.31.conf
├── examples/status.conf
├── output/.gitkeep
├── scripts/
│   ├── resolve-deps.sh
│   ├── resolve-version.sh
│   └── self-check.sh
├── sources/
│   ├── 1.25/
│   └── 1.31/
├── Dockerfile
├── build-openresty.sh
├── build.sh
└── README.md
```

## 版本策略

`config/openresty-version.conf` 负责默认版本和 latest 回退；具体兼容参数按 `主版本.次版本` 配置。例如：

```text
1.25.x -> config/openresty-1.25.conf -> sources/1.25/
1.31.x -> config/openresty-1.31.conf -> sources/1.31/
```

因此 `1.31.2` 会自动复用 `1.31.x` 的 OpenSSL、PCRE2 和模块策略，只需将：

```text
sources/1.31/openresty-1.31.2.tar.gz
```

放入仓库即可。

默认配置：

```bash
OPENRESTY_VERSION=${OPENRESTY_VERSION:-latest}
OPENRESTY_FALLBACK_VERSION=${OPENRESTY_FALLBACK_VERSION:-1.31.1.1}
ALLOW_LATEST_FALLBACK=${ALLOW_LATEST_FALLBACK:-true}
```

`latest` 会从以下页面动态解析最高正式版本：

```text
https://openresty.org/en/download.html
```

因此同一兼容系列发布新版本后，不需要新增配置文件或修改构建脚本；只需补充对应的 OpenResty 源码包。若新版本需要不同依赖或补丁，再新增对应的 `config/openresty-X.Y.conf` 系列配置。

### 源码包归类

源码包按 OpenResty 的 `主版本.次版本` 归类，不能把所有包直接混放在 `sources/` 根目录：

```text
sources/
├── 1.25/
│   ├── openresty-1.25.3.1.tar.gz
│   ├── openssl-1.1.1w.tar.gz
│   └── ngx_http_substitutions_filter_module-0.6.4.tar.gz
└── 1.31/
    ├── openresty-1.31.1.1.tar.gz
    ├── openssl-3.5.6.tar.gz
    ├── pcre2-10.47.tar.bz2
    └── ngx_http_substitutions_filter_module-e12e965ac1837ca709709f9a26f572a54d83430e.tar.gz
```

构建时会根据 OpenResty 版本选择对应目录和配置：

```text
1.25.3.1 -> config/openresty-1.25.conf -> sources/1.25/
1.31.1.1 -> config/openresty-1.31.conf -> sources/1.31/
```

依赖包的文件名必须与配置和构建脚本解析出的名称一致。包已提交到 `sources/` 后，构建会优先使用本地缓存；缺少的模块包才会尝试从远程下载。

固定版本构建：

```bash
./build-openresty.sh amd64 1.31.1.1
```

自动构建最新版本：

```bash
./build-openresty.sh amd64 latest
```

## 依赖版本策略

默认从 OpenResty 官方 Docker 项目中解析：

```text
https://github.com/openresty/docker-openresty/blob/master/noble/Dockerfile
```

自动获取：

```text
RESTY_OPENSSL_VERSION
RESTY_OPENSSL_PATCH_VERSION
RESTY_PCRE_VERSION
RESTY_PCRE_SHA256
```

当前回退值：

```text
OpenSSL: 3.5.7
OpenSSL patch: 3.5.5
PCRE2: 10.47
```

需要完全可重复构建时，把 `config/build.conf` 中的 `auto` 改成固定值：

```bash
OPENSSL_VERSION=${OPENSSL_VERSION:-3.5.7}
OPENSSL_PATCH_VERSION=${OPENSSL_PATCH_VERSION:-3.5.5}
PCRE2_VERSION=${PCRE2_VERSION:-10.47}
PCRE2_SHA256=${PCRE2_SHA256:-c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16}
```

## 默认编译模块

OpenResty 自带模块之外，额外启用：

```text
ngx_http_stub_status_module
ngx_http_substitutions_filter_module 0.6.4
nginx_upstream_check_module
```

构建参数中包含：

```text
--with-http_stub_status_module
--add-module=ngx_http_substitutions_filter_module
--add-module=nginx_upstream_check_module
```

## nginx_upstream_check_module 的兼容策略

该模块需要修改 Nginx Core 源码，不是只增加 `--add-module` 即可。

项目会在 OpenResty 执行 `./configure` 后：

1. 自动识别当前 OpenResty 内置的 Nginx Core 版本。
2. 扫描模块源码中的 `check_*.patch`。
3. 按版本从高到低执行 `patch --dry-run`。
4. 只应用能够完整通过 dry-run 的补丁。
5. 没有兼容补丁时终止构建，避免生成存在隐患的二进制。

指定补丁：

```bash
UPSTREAM_CHECK_PATCH=check_1.20.1+.patch ./build-openresty.sh amd64 latest
```

不构建该模块：

```bash
ENABLE_UPSTREAM_CHECK=false ./build-openresty.sh amd64 latest
```

GitHub Actions 手动执行时，也可以在 `enable_upstream_check` 中选择 `false`。

重要限制：OpenResty 或 Nginx Core 未来发生源码结构变化时，旧补丁可能不再兼容。项目能够自动检测并明确失败，但不能在没有新补丁的情况下自动生成正确的 C 源码补丁。

## Builder 镜像

默认继续使用与 `nginx-make` 相同类型的 CentOS 7 Builder，从而生成 glibc 2.17 基线包：

```text
registry.cn-shanghai.aliyuncs.com/jing-images/linux_amd64_centos_builder:7.9.2009
registry.cn-shanghai.aliyuncs.com/jing-images/linux_arm64_centos_builder:7.9.2009
```

临时覆盖：

```bash
BUILDER_IMAGE=my-builder:latest ./build-openresty.sh amd64 latest
```

未来 OpenResty、OpenSSL 或编译器要求高于 CentOS 7 Builder 能力时，需要升级 Builder 镜像。构建脚本和 Workflow 不需要改，只需覆盖 `BUILDER_IMAGE` 或修改 `config/build.conf`。

Builder 至少需要：

```text
gcc
make
perl
patch
tar
sha256sum
```

## 本地构建

准备：

```bash
chmod +x build-openresty.sh build.sh scripts/*.sh
scripts/self-check.sh
```

amd64：

```bash
./build-openresty.sh amd64 latest
```

arm64：

```bash
./build-openresty.sh arm64 latest
```

固定版本：

```bash
./build-openresty.sh amd64 1.31.1.1
```

输出：

```text
output/openresty-1.31.1.1-glibc2.17-amd64.tar.gz
output/openresty-1.31.1.1-glibc2.17-amd64.tar.gz.sha256
output/build-info.txt
```

源码和依赖缓存保存在：

```text
sources/
```

清理缓存：

```bash
find sources -type f ! -name .gitkeep -delete
```

## GitHub Actions

手动执行：

```text
Actions
→ Build OpenResty
→ Run workflow
```

参数：

```text
openresty_version: 留空、latest 或具体版本
选择 enable_upstream_check: true/false
upstream_check_ref: 可选，模块分支、Tag 或 Commit
```

要构建指定版本，应使用手动触发：

```text
Actions
→ Build OpenResty
→ Run workflow
→ Branch: master
→ OpenResty version: 1.25.3.1
→ enable_upstream_check: false
→ Run workflow
```

`OpenResty version` 也可以填写 `1.31.1.1` 或 `latest`。留空时使用 `config/openresty-version.conf` 中的默认版本。普通 `git push` 使用默认版本，不会自动切换到 1.25 系列。

### Actions 运行记录清理

`build-openresty.yml` 的 `cleanup-runs` Job 在构建、Release 和 HAP 同步成功后执行：

- `push` 或手动 `Run workflow` 触发的构建成功后，删除本 Workflow 早于当前运行的已完成记录；
- 保留当前成功运行、更新的运行以及排队或运行中的任务；
- 构建、Release 或 HAP 同步失败时，不清理旧记录；
- 删除旧运行时会同时删除其关联 Artifact；
- 不删除 GitHub Release 及 Release 附件。

本项目没有定时清理任务；首次清理会在下一次成功构建后执行。清理运行记录和日志不可恢复。

构建流程：

```text
Resolve versions
Build OpenResty amd64
Build OpenResty arm64
Create Release
Sync Release to HAP
```

Workflow 使用支持 Node.js 24 的 Action：

```text
actions/checkout@v5
actions/upload-artifact@v6
actions/download-artifact@v7
softprops/action-gh-release@v3
```

## Release

Release Tag：

```text
openresty-1.31.1.1
```

附件：

```text
openresty-1.31.1.1-glibc2.17-amd64.tar.gz
openresty-1.31.1.1-glibc2.17-amd64.tar.gz.sha256
openresty-1.31.1.1-glibc2.17-arm64.tar.gz
openresty-1.31.1.1-glibc2.17-arm64.tar.gz.sha256
build-info-amd64.txt
build-info-arm64.txt
```

同版本重复执行时，同名 Release 文件会被覆盖。

## HAP 同步

GitHub 仓库配置 Secret：

```text
HAP_WEBHOOK_URL
```

未配置时自动跳过 HAP，不影响构建和 Release。

Webhook 字段：

```text
repository
version
tag
release_url
amd64_name
amd64_url
amd64_sha256
arm64_name
arm64_url
arm64_sha256
attachment_urls
commit_sha
run_id
run_url
build_status
```

`attachment_urls` 仍以字符串形式发送：

```json
"[\"url1\",\"url2\"]"
```

## 安装

```bash
tar zxf openresty-1.31.1.1-glibc2.17-amd64.tar.gz -C /usr/local
/usr/local/openresty/nginx/sbin/nginx -V
```

验证模块：

```bash
/usr/local/openresty/nginx/sbin/nginx -V 2>&1 \
| grep -E -- 'stub_status|substitutions_filter|upstream_check'
```

检查动态库：

```bash
ldd /usr/local/openresty/nginx/sbin/nginx | grep 'not found' || true
```

## 动态库相对路径与 CentOS 7 兼容

安装包以 CentOS 7 Builder 构建，运行时基线为 glibc 2.17。OpenResty 使用的 LuaJIT、PCRE2、OpenSSL 动态库随安装包一起提供：

```text
openresty/
├── nginx/sbin/nginx
├── luajit/lib/libluajit-5.1.so.2
├── pcre2/lib/libpcre2-8.so.0
└── openssl3/lib/libssl.so.3
                  libcrypto.so.3
```

安装完成后，构建脚本使用 Builder 镜像中已有的 `patchelf`，给 nginx 写入 ELF 相对 RPATH：

```bash
patchelf --set-rpath \
  '$ORIGIN/../../luajit/lib:$ORIGIN/../../openssl3/lib:$ORIGIN/../../pcre2/lib' \
  /usr/local/openresty/nginx/sbin/nginx
```

这里的 `$ORIGIN` 表示当前可执行文件所在目录。以 `nginx/sbin/nginx` 为起点：

```text
$ORIGIN/../../luajit/lib  -> openresty/luajit/lib
$ORIGIN/../../openssl3/lib -> openresty/openssl3/lib
$ORIGIN/../../pcre2/lib   -> openresty/pcre2/lib
```

因此运行时不依赖 `LD_LIBRARY_PATH`，也不需要把库复制到 `/lib64` 或 `/usr/local/lib`；解压到其他目录也能找到依赖。

验证方式：

```bash
ldd openresty/nginx/sbin/nginx
openresty/nginx/sbin/nginx -V
```

`ldd` 中应能看到类似以下相对路径解析结果，并且不能出现 `not found`：

```text
libluajit-5.1.so.2 => .../openresty/nginx/sbin/../../luajit/lib/...
libpcre2-8.so.0    => .../openresty/nginx/sbin/../../pcre2/lib/...
libssl.so.3        => .../openresty/nginx/sbin/../../openssl3/lib/...
libcrypto.so.3     => .../openresty/nginx/sbin/../../openssl3/lib/...
```

`nginx -V` 中出现的 `/usr/local/openresty`、编译目录或 Builder 路径主要是编译时参数；动态库实际位置由 ELF RPATH 决定。

## 状态配置示例

项目内提供：

```text
examples/status.conf
```

核心配置：

```nginx
upstream app_backend {
    server 192.168.1.101:8080;
    server 192.168.1.102:8080;

    check interval=3000 rise=2 fall=3 timeout=1000 type=http;
    check_http_send "GET /health HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    check_http_expect_alive http_2xx http_3xx;
}

server {
    listen 127.0.0.1:8088;

    location = /nginx_status {
        stub_status;
        access_log off;
    }

    location = /upstream_status {
        check_status json;
        access_log off;
    }
}
```

检查：

```bash
/usr/local/openresty/nginx/sbin/nginx -t
curl http://127.0.0.1:8088/nginx_status
curl -s http://127.0.0.1:8088/upstream_status | jq .
```

## 创建仓库

```bash
git init
git branch -M master
git add .
git commit -m "init universal OpenResty build"
gh repo create 1447443432/openresty-make \
  --public \
  --source=. \
  --remote=origin \
  --push
```

## 构建可靠性说明

项目对以下环节进行了失败保护：

```text
版本格式校验
依赖版本自动解析与回退
PCRE2 SHA256 校验
源码压缩包完整性检查
OpenSSL 补丁 dry-run
upstream-check 补丁自动匹配与 dry-run
nginx -V 编译参数检查
nginx 配置指令检查
动态库 not found 检查
安装包 SHA256 生成与 GitHub Actions 校验
```

源码构建项目无法承诺所有未来版本都能在旧 glibc 2.17 Builder 上无修改编译成功。最容易变化的两处是编译工具链要求和 `nginx_upstream_check_module` 的 Nginx Core 补丁；脚本会明确终止并输出原因，不会静默生成不可靠产物。
