ARG BUILDER_IMAGE
FROM ${BUILDER_IMAGE}
WORKDIR /data/openresty-make
COPY sources ./sources
COPY build.sh ./build.sh
RUN chmod +x ./build.sh
USER root
ENTRYPOINT ["./build.sh"]
