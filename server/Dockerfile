FROM golang:1.27.3-bookworm@sha256:d9b6a1beb9474adc2a1ce842573639b44b2a0dd49b6669f51d3821baf9ec37c9 AS source
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
RUN go mod verify
COPY *.go ./

FROM source AS test
RUN CGO_ENABLED=1 go test -race ./...

FROM source AS build
# SQLite needs CGO. Static linking also makes the exported binary usable on a NAS
# without requiring the host's libc or a separate SQLite installation.
RUN CGO_ENABLED=1 go build -trimpath \
    -tags netgo,osusergo,sqlite_omit_load_extension \
    -ldflags '-s -w -linkmode external -extldflags "-static"' \
    -o /out/aiplayer-sync .

FROM scratch AS binary
COPY --from=build /out/aiplayer-sync /aiplayer-sync

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS runtime
RUN groupadd -g 10001 syncuser && useradd -u 10001 -g syncuser syncuser && mkdir /data && chown syncuser:syncuser /data
COPY --from=build /out/aiplayer-sync /usr/local/bin/aiplayer-sync
USER syncuser
ENV SYNC_DB=/data/aiplayer.db SYNC_ADDR=:8080
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["aiplayer-sync"]
