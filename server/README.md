# 可选资料同步服务

单用户 Go + SQLite。同步影视库资料、弹幕匹配、已看和播放记录，以及客户端加密后的设置、API Key、远程来源及其凭证、媒体位置关联、收藏、海报与视频封面截图。客户端还可通过加密记录同步已有的单集标题、资料与字幕翻译缓存、目录资料、视频时长及有效技术参数。服务不接收视频文件，不访问客户端来源。

## 启动

```bash
export SYNC_TOKEN="$(openssl rand -hex 32)"
docker compose up -d --build
curl --fail http://127.0.0.1:8080/healthz
```

数据库位于 `sync-data` 卷。容器以 UID 10001 运行；宿主映射默认仅回环地址。跨设备使用自己的 HTTPS 反向代理；客户端填服务根地址和同一 Token。

发布包中的 `aiplayer-sync-linux-amd64` 是 Linux x86-64 静态二进制，无需安装 Go 或 SQLite。设置好上述 `SYNC_TOKEN` 后可直接运行：

```bash
chmod +x aiplayer-sync-linux-amd64
SYNC_ADDR=127.0.0.1:8080 SYNC_DB=./aiplayer.db ./aiplayer-sync-linux-amd64
```

升级现有实例时先停止旧进程，替换二进制，再用原来的 Token、数据库路径和监听配置启动；Docker 实例则重新构建并保留 `sync-data` 卷。单纯升级程序无需更换 Token。

本机开发：

```bash
go test -race ./...
go build -o aiplayer-sync .
SYNC_ADDR=127.0.0.1:8080 SYNC_DB=./aiplayer.db ./aiplayer-sync
```

`SYNC_TOKEN` 必填且至少 24 字符；`SYNC_ADDR` 默认 `:8080`；`SYNC_DB` 默认 `aiplayer.db`。不记录请求头或凭证。备份可先停止容器再复制完整数据库目录；不要在 WAL 活跃时仅复制主 .db 文件。

## API /v1

除 `GET /healthz` 外均要求 `Authorization: Bearer <Token>`。JSON 请求体上限 256 KiB。

### PUT /v1/records

```json
{"id":"media-uuid","kind":"media","version":0,"deleted":false,"data":{"series":"作品","season":"1","episode":"2","fileName":"作品 S01E02.mkv","size":123456}}
```

新建 version=0，后续携带最后已知版本。成功返回 200 和版本递增后的完整记录；过期返回 409 及 current。删除用 deleted=true 墓碑。记录可携带 `modifiedAt`（UTC RFC3339）、`deviceId` 与 `deviceName`。客户端按实际修改时间自动选择较新记录并重试；时间相同时删除优先，再按稳定设备 ID 排序，无需逐条选择。设置、来源、收藏等按项保留修改时间，不把同步时间当作修改时间。

新版客户端需要配套更新服务端以接受上述字段。启动时自动为旧 SQLite 数据库添加字段，保留原有记录和 Token；未携带这些字段的旧客户端仍可使用版本接口。

| kind | data 允许字段 |
| --- | --- |
| media | title、series、season、episode、bangumiId、poster、summary、fileName、size、duration、metadataProvider、tmdbId、metadataTitle、rating、ratingCount、airDate、totalEpisodes、totalSeasons、genres、metadataType |
| match | provider、episodeId、label、shift、offset |
| progress | position、duration、updatedAt |
| watched | watched |
| vault | algorithm、nonce、ciphertext、mac |

季度、集数及服务集数 ID 均为字符串；size、duration、position、shift、offset 为数字；watched 为布尔。fileName 不接受路径；match.provider 为 HTTPS origin。genres 为最多 32 项的字符串数组；rating 为 0–10 的数字，ratingCount、totalEpisodes、totalSeasons 为非负整数，以上资料数字也允许 null。metadataProvider 为 bangumi 或 tmdb，metadataType 为 tv 或 movie。未知字段、嵌套对象被拒绝，公开资料记录仍不接受 API Key、来源地址、密码或文件路径。

### 加密记录 vault

设置、私密数据与图片等扩展资料使用单独的 vault 记录，每个设置、来源、关联、收藏或图片独立更新，沿用版本冲突和删除墓碑。data 必须包含且仅包含以下字段：

| 字段 | 要求 |
| --- | --- |
| algorithm | 固定字符串 AES-GCM-256 |
| nonce | 标准 Base64，解码后 12 字节；每次加密重新生成 |
| ciphertext | 标准 Base64，解码后 1–184320 字节（180 KiB） |
| mac | 标准 Base64，解码后 16 字节的认证标签 |

Base64 必须包含标准填充且不含空白。整个请求仍限制 256 KiB，足够容纳上限密文的 Base64 和记录外壳。vault 删除墓碑必须使用 `deleted=true,data={}`，存活记录不接受空 data。服务仅校验加密外壳并原样存储，不执行解密；客户端负责 AES-GCM 认证及解密后内容校验。

客户端记录 ID 统一使用 `<类型>:<条目键的SHA256>`，例如 `setting:<hash>`、`secret:<hash>`、`source:<hash>`、`binding:<hash>`、`favorite:<hash>`、`local:<hash>`、`artwork:<hash>`；条目原始键只存在于加密内容中。AES-GCM 的附加认证数据为 UTF-8 编码的 `aiplayer:vault:1:<记录ID>`，避免不同记录之间的密文被直接替换。加密密钥由同步 Token 通过 HKDF-SHA256 派生。

图片记录解密后使用 `type=artwork`：海报键为 `poster:<海报URL>`，值包含 `image`；截图键为 `preview:<mediaId>`，值包含 `image`、`mediaId`、`size`、可选 `modified`、`requestedPosition` 与 `capturedPosition`。`image` 为 JPEG、PNG 或 WebP 的 Base64 data URL，最多 180000 字符；客户端按需缩小图片，以满足现有单项密文和请求大小限制。仅同步远程影视库条目使用的已有图片，视频内容、本地缓存文件路径均不进入图片记录。接收设备校验图片及视频版本后，写入本机缓存；缺失或清理本机图片缓存不会被当作共享图片删除。

API Key、来源密码及图片等扩展资料以密文进入同步数据库。服务也持有同步 Token，因此这里提供的是密文存储，并非对服务运营者保密的端到端加密；仍应使用信任的服务与 HTTPS。同一个服务、Token 的设备共享同一套同步资料。本地视频文件、设备文件路径、下载、运行日志、临时任务，以及未列入同步范围的缓存保留在本机；同步服务地址及其 Token 保留为设备加入同步所需的本地配置。

### GET /v1/changes?after=0

返回 `{"changes":[{"sequence":1,...记录}],"cursor":1,"hasMore":false}`。每页最多 200 条，用 cursor 请求下一页直到 hasMore=false。客户端原子保存应用结果与游标；离线修改保留在 SQLite 待上传记录中。服务端版本和变化序列事务性递增。

可增加 `wait=20` 启用长轮询（整数秒，范围 0–25）。存在新记录时立即返回；没有新记录时等待下一次成功写入或超时，再返回同样的分页结构。超时空响应保留原游标；每次写入会唤醒所有等待设备，请求取消立即结束等待。不带 `wait` 或使用 `wait=0` 时保留原有立即查询行为。等待期间不占用 SQLite 连接，也不创建额外历史记录。

同一历史流可以同时包含旧版公开记录和新版 vault。客户端应先完成所有页的拉取，将每个 `(kind,id)` 合并为最新版本，再解密最终 vault 内容；历史版本可能使用轮换前的 Token。升级无需数据库迁移，保留原 SQLite 数据目录即可。新增图片和扩展资料沿用现有 vault 协议，已经支持 vault 的服务无需升级。各设备需使用支持这些子类型的新版客户端；旧客户端可能拒绝无法识别的解密内容，不能完整参与新增资料同步。

数据卷被清空、恢复旧备份或更换服务器时，客户端执行「重置同步关联」，保留本机资料后重新合并。更换服务不会静默复用旧游标。

### 轮换同步 Token

Token 同时用于服务认证和客户端密钥派生，轮换时必须同步重加密，不能只修改服务环境变量后丢弃旧 Token。

1. 使用旧 Token 完成各设备同步，并确保一台已连接设备已取得需要保留的全部设置、凭证和来源。
2. 保留该设备的本地数据及旧 Token，修改服务的 `SYNC_TOKEN` 并重启服务。
3. 在这台资料完整的设备上更新 Token 并同步，重新加密、上传全部 vault 记录；确认同步成功后，其他设备再更新 Token 并同步。
4. 保管旧 Token，直至确认所有需要恢复的旧数据库备份均不再使用；旧备份的密文仍需要旧 Token。

未取得的旧密文不能由新 Token 恢复。历史 changes 仍保留旧版本，新 Token 也不会改变已存在备份的密钥。

冲突在客户端自动解决；当前没有多用户、历史压缩、视频接口或管理后台。本地视频和临时外部播放不参与同步。
