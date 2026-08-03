# 默认使用 amd64 Builder。
# arm64 构建时，build-openresty.sh 会通过 --build-arg 覆盖该值。
ARG BUILDER_IMAGE=registry.cn-shanghai.aliyuncs.com/jing-images/linux_amd64_centos_builder:7.9.2009

FROM ${BUILDER_IMAGE}

WORKDIR /data/openresty-make

COPY sources ./sources
COPY build.sh ./build.sh

RUN chmod +x ./build.sh

USER root

ENTRYPOINT ["./build.sh"]