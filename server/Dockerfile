FROM golang:1.27.3-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -trimpath -o /sync .
FROM debian:bookworm-slim
RUN groupadd -g 10001 syncuser && useradd -u 10001 -g syncuser syncuser && mkdir /data && chown syncuser:syncuser /data
COPY --from=build /sync /usr/local/bin/aiplayer-sync
USER syncuser
ENV SYNC_DB=/data/aiplayer.db SYNC_ADDR=:8080
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["aiplayer-sync"]
