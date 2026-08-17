ARG BUILDER_IMAGE=registry.cn-shanghai.aliyuncs.com/jing-images/linux_amd64_centos_builder:7.9-openresty-1.0.0
FROM ${BUILDER_IMAGE}

WORKDIR /data/openresty-make

COPY sources ./sources
COPY build.sh ./build.sh

RUN chmod +x ./build.sh

USER root

ENTRYPOINT ["./build.sh"]
