ARG BUILDER_IMAGE=registry.cn-shanghai.aliyuncs.com/jing-images/linux_amd64_centos_builder:7.9-openresty-1.0.0
FROM ${BUILDER_IMAGE}

WORKDIR /data/openresty-make

COPY sources ./sources
COPY build.sh ./build.sh

RUN chmod +x ./build.sh

RUN curl -fsSL https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0.tar.gz \
    | tar xz \
    && cd patchelf-0.18.0 \
    && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" \
    && make install \
    && cd /data/openresty-make \
    && rm -rf patchelf-0.18.0

USER root

ENTRYPOINT ["./build.sh"]
