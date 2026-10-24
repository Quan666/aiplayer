FROM golang:1.27.3-bookworm AS source
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
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

FROM debian:bookworm-slim AS runtime
RUN groupadd -g 10001 syncuser && useradd -u 10001 -g syncuser syncuser && mkdir /data && chown syncuser:syncuser /data
COPY --from=build /out/aiplayer-sync /usr/local/bin/aiplayer-sync
USER syncuser
ENV SYNC_DB=/data/aiplayer.db SYNC_ADDR=:8080
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["aiplayer-sync"]
