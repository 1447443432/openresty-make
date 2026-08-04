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
│   └── openresty-version.conf
├── examples/status.conf
├── output/.gitkeep
├── scripts/
│   ├── resolve-deps.sh
│   ├── resolve-version.sh
│   └── self-check.sh
├── sources/.gitkeep
├── Dockerfile
├── build-openresty.sh
├── build.sh
└── README.md
```

## 版本策略

`config/openresty-version.conf` 默认配置：

```bash
OPENRESTY_VERSION=${OPENRESTY_VERSION:-latest}
OPENRESTY_FALLBACK_VERSION=${OPENRESTY_FALLBACK_VERSION:-1.31.1.1}
ALLOW_LATEST_FALLBACK=${ALLOW_LATEST_FALLBACK:-true}
```

`latest` 会从以下页面动态解析最高正式版本：

```text
https://openresty.org/en/download.html
```

因此将来发布 `1.31.1.2`、`1.33.x.x` 等新版本后，不需要改构建脚本，可以直接手动执行 Workflow，或继续使用 `latest`。

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
