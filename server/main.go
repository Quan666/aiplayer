package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Record struct {
	ModifiedAt string          `json:"modifiedAt,omitempty"`
	DeviceID   string          `json:"deviceId,omitempty"`
	DeviceName string          `json:"deviceName,omitempty"`
	ID         string          `json:"id"`
	Kind       string          `json:"kind"`
	Version    int64           `json:"version"`
	Deleted    bool            `json:"deleted"`
	Data       json.RawMessage `json:"data"`
}
type Change struct {
	Sequence int64 `json:"sequence"`
	Record
}
type Server struct {
	db           *sql.DB
	token        [32]byte
	changesMu    sync.Mutex
	changesReady chan struct{}
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,200}$`)
var fields = map[string]map[string]bool{
	"media":    allowed("title", "series", "season", "episode", "bangumiId", "poster", "summary", "fileName", "size", "duration", "metadataProvider", "tmdbId", "metadataTitle", "rating", "ratingCount", "airDate", "totalEpisodes", "totalSeasons", "genres", "metadataType"),
	"progress": allowed("position", "duration", "updatedAt"),
	"watched":  allowed("watched"),
	"match":    allowed("provider", "episodeId", "label", "shift", "offset"),
	"vault":    allowed("algorithm", "nonce", "ciphertext", "mac"),
}

const maxVaultCiphertext = 180 * 1024

func allowed(names ...string) map[string]bool {
	m := map[string]bool{}
	for _, n := range names {
		m[n] = true
	}
	return m
}

func openServer(path, token string) (*Server, error) {
	if len(token) < 24 {
		return nil, errors.New("SYNC_TOKEN must contain at least 24 characters")
	}
	db, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=on")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS records (id TEXT NOT NULL, kind TEXT NOT NULL, version INTEGER NOT NULL, deleted INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(kind,id));
 CREATE TABLE IF NOT EXISTS changes (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, kind TEXT NOT NULL, version INTEGER NOT NULL, deleted INTEGER NOT NULL, data BLOB NOT NULL);`)
	if err != nil {
		db.Close()
		return nil, err
	}
	// Upgrade existing databases without rewriting records or the change cursor.
	for _, table := range []string{"records", "changes"} {
		rows, err := db.Query("PRAGMA table_info(" + table + ")")
		if err != nil {
			db.Close()
			return nil, err
		}
		columns := map[string]bool{}
		for rows.Next() {
			var index, required, primary int
			var name, kind string
			var defaultValue any
			if err = rows.Scan(&index, &name, &kind, &required, &defaultValue, &primary); err != nil {
				rows.Close()
				db.Close()
				return nil, err
			}
			columns[name] = true
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			db.Close()
			return nil, err
		}
		for _, column := range []string{"modified_at", "device_id", "device_name"} {
			if columns[column] {
				continue
			}
			if _, err = db.Exec("ALTER TABLE " + table + " ADD COLUMN " + column + " TEXT NOT NULL DEFAULT ''"); err != nil {
				db.Close()
				return nil, err
			}
		}
	}
	return &Server{db: db, token: sha256.Sum256([]byte(token)), changesReady: make(chan struct{})}, nil
}
func send(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, status int, message string) {
	send(w, status, map[string]string{"error": message})
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/healthz" && r.Method == "GET" {
		send(w, 200, map[string]bool{"ok": true})
		return
	}
	supplied := sha256.Sum256([]byte(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")))
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || subtle.ConstantTimeCompare(s.token[:], supplied[:]) != 1 {
		fail(w, 401, "unauthorized")
		return
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/v1/changes":
		s.changes(w, r)
	case r.Method == "PUT" && r.URL.Path == "/v1/records":
		s.put(w, r)
	default:
		fail(w, 404, "not found")
	}
}
func (s *Server) changes(w http.ResponseWriter, r *http.Request) {
	after := int64(0)
	var err error
	if v := r.URL.Query().Get("after"); v != "" {
		after, err = strconv.ParseInt(v, 10, 64)
	}
	if err != nil || after < 0 {
		fail(w, 400, "invalid cursor")
		return
	}
	wait := 0
	if value := r.URL.Query().Get("wait"); value != "" {
		wait, err = strconv.Atoi(value)
	}
	if err != nil || wait < 0 || wait > 25 {
		fail(w, 400, "invalid wait")
		return
	}
	var timeout <-chan time.Time
	if wait > 0 {
		timer := time.NewTimer(time.Duration(wait) * time.Second)
		defer timer.Stop()
		timeout = timer.C
	}
	for {
		// Subscribe before reading: a write between the read and select closes
		// this channel, so it cannot be missed. No database connection is held
		// while waiting, allowing concurrent writers and other readers to run.
		ready := s.changeSignal()
		items, err := s.readChanges(r.Context(), after)
		if r.Context().Err() != nil {
			return
		}
		if err != nil {
			fail(w, 500, "database unavailable")
			return
		}
		if len(items) > 0 || wait == 0 {
			more := len(items) > 200
			if more {
				items = items[:200]
			}
			cursor := after
			if len(items) > 0 {
				cursor = items[len(items)-1].Sequence
			}
			send(w, 200, map[string]any{"changes": items, "cursor": cursor, "hasMore": more})
			return
		}
		select {
		case <-ready:
		case <-timeout:
			// One final read includes a commit racing with the deadline.
			wait = 0
		case <-r.Context().Done():
			return
		}
	}
}

func (s *Server) changeSignal() <-chan struct{} {
	s.changesMu.Lock()
	defer s.changesMu.Unlock()
	return s.changesReady
}

func (s *Server) notifyChanges() {
	s.changesMu.Lock()
	defer s.changesMu.Unlock()
	close(s.changesReady)
	s.changesReady = make(chan struct{})
}

func (s *Server) readChanges(ctx context.Context, after int64) ([]Change, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT sequence,id,kind,version,deleted,data,modified_at,device_id,device_name FROM changes WHERE sequence>? ORDER BY sequence LIMIT 201`, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]Change, 0)
	for rows.Next() {
		var c Change
		if err = rows.Scan(&c.Sequence, &c.ID, &c.Kind, &c.Version, &c.Deleted, &c.Data, &c.ModifiedAt, &c.DeviceID, &c.DeviceName); err != nil {
			return nil, err
		}
		items = append(items, c)
	}
	return items, rows.Err()
}
func validate(rec Record) error {
	if rec.ModifiedAt != "" {
		if _, err := time.Parse(time.RFC3339Nano, rec.ModifiedAt); err != nil {
			return errors.New("invalid modification timestamp")
		}
	}
	if len(rec.DeviceName) > 300 || (rec.DeviceID != "" && !identifier.MatchString(rec.DeviceID)) {
		return errors.New("invalid device identity")
	}

	if !identifier.MatchString(rec.ID) || fields[rec.Kind] == nil || rec.Version < 0 {
		return errors.New("invalid record")
	}
	var data map[string]any
	if json.Unmarshal(rec.Data, &data) != nil || data == nil {
		return errors.New("data must be an object")
	}
	if rec.Kind == "vault" {
		return validateVault(rec, data)
	}
	for key, value := range data {
		if !fields[rec.Kind][key] {
			return fmt.Errorf("unsupported field: %s", key)
		}
		if key == "genres" {
			items, ok := value.([]any)
			if !ok || len(items) > 32 {
				return errors.New("invalid genres")
			}
			for _, item := range items {
				text, ok := item.(string)
				if !ok || len(text) > 300 {
					return errors.New("invalid genre")
				}
			}
			continue
		}
		metadataNumber := key == "rating" || key == "ratingCount" || key == "totalEpisodes" || key == "totalSeasons"
		if metadataNumber {
			if value == nil {
				continue
			}
			n, ok := value.(float64)
			if !ok || math.IsNaN(n) || math.IsInf(n, 0) || n < 0 || (key == "rating" && n > 10) || (key != "rating" && n != math.Trunc(n)) {
				return errors.New("invalid metadata number")
			}
			continue
		}
		switch value.(type) {
		case string, float64, bool, nil:
		default:
			return errors.New("nested data is not accepted")
		}
		numeric := key == "size" || key == "duration" || key == "position" || key == "shift" || key == "offset"
		if numeric {
			n, ok := value.(float64)
			if !ok || math.IsNaN(n) || math.IsInf(n, 0) || ((key == "size" || key == "duration" || key == "position") && n < 0) {
				return errors.New("invalid numeric field")
			}
		} else if key == "watched" {
			if _, ok := value.(bool); !ok {
				return errors.New("watched must be boolean")
			}
		} else if _, ok := value.(string); !ok {
			return errors.New("invalid text field")
		}
	}
	if rec.Kind == "media" {
		if provider, ok := data["metadataProvider"].(string); ok && provider != "bangumi" && provider != "tmdb" {
			return errors.New("invalid metadata provider")
		}
		if kind, ok := data["metadataType"].(string); ok && kind != "tv" && kind != "movie" {
			return errors.New("invalid metadata type")
		}
		if name, ok := data["fileName"].(string); ok && strings.ContainsAny(name, "/\\") {
			return errors.New("fileName must not contain a path")
		}
	}
	if rec.Kind == "match" {
		if p, ok := data["provider"].(string); ok {
			u, err := url.Parse(p)
			if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
				return errors.New("provider must be an HTTPS origin")
			}
		}
	}
	return nil
}

func validateVault(rec Record, data map[string]any) error {
	if rec.Deleted {
		if len(data) != 0 {
			return errors.New("vault tombstones must have empty data")
		}
		return nil
	}
	if len(data) != len(fields["vault"]) || data["algorithm"] != "AES-GCM-256" {
		return errors.New("invalid encrypted record")
	}
	for key, size := range map[string]int{"nonce": 12, "mac": 16, "ciphertext": maxVaultCiphertext} {
		value, ok := data[key].(string)
		if !ok || len(value) == 0 || len(value) > base64.StdEncoding.EncodedLen(size) {
			return errors.New("invalid encrypted field")
		}
		decoded, err := base64.StdEncoding.Strict().DecodeString(value)
		if err != nil || base64.StdEncoding.EncodeToString(decoded) != value {
			return errors.New("invalid encrypted field encoding")
		}
		if (key == "ciphertext" && (len(decoded) == 0 || len(decoded) > size)) || (key != "ciphertext" && len(decoded) != size) {
			return errors.New("invalid encrypted field size")
		}
	}
	return nil
}

func (s *Server) put(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 256*1024)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var rec Record
	if dec.Decode(&rec) != nil {
		fail(w, 400, "invalid record")
		return
	}
	var tail any
	if dec.Decode(&tail) != io.EOF {
		fail(w, 400, "trailing data")
		return
	}
	if err := validate(rec); err != nil {
		fail(w, 400, err.Error())
		return
	}
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		fail(w, 500, "database unavailable")
		return
	}
	defer tx.Rollback()
	current := Record{ID: rec.ID, Kind: rec.Kind, Data: json.RawMessage(`{}`)}
	err = tx.QueryRowContext(r.Context(), `SELECT version,deleted,data,modified_at,device_id,device_name FROM records WHERE kind=? AND id=?`, rec.Kind, rec.ID).Scan(&current.Version, &current.Deleted, &current.Data, &current.ModifiedAt, &current.DeviceID, &current.DeviceName)
	if err != nil && err != sql.ErrNoRows {
		fail(w, 500, "read failed")
		return
	}
	if current.Version != rec.Version {
		send(w, 409, map[string]any{"error": "version conflict", "current": current})
		return
	}
	rec.Version++
	_, err = tx.ExecContext(r.Context(), `INSERT INTO records(id,kind,version,deleted,data,modified_at,device_id,device_name) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET version=excluded.version,deleted=excluded.deleted,data=excluded.data,modified_at=excluded.modified_at,device_id=excluded.device_id,device_name=excluded.device_name`, rec.ID, rec.Kind, rec.Version, rec.Deleted, []byte(rec.Data), rec.ModifiedAt, rec.DeviceID, rec.DeviceName)
	if err == nil {
		_, err = tx.ExecContext(r.Context(), `INSERT INTO changes(id,kind,version,deleted,data,modified_at,device_id,device_name) VALUES(?,?,?,?,?,?,?,?)`, rec.ID, rec.Kind, rec.Version, rec.Deleted, []byte(rec.Data), rec.ModifiedAt, rec.DeviceID, rec.DeviceName)
	}
	if err != nil || tx.Commit() != nil {
		fail(w, 500, "write failed")
		return
	}
	s.notifyChanges()
	send(w, 200, rec)
}
func main() {
	path := os.Getenv("SYNC_DB")
	if path == "" {
		path = "aiplayer.db"
	}
	addr := os.Getenv("SYNC_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	app, err := openServer(path, os.Getenv("SYNC_TOKEN"))
	if err != nil {
		log.Fatal(err)
	}
	defer app.db.Close()
	srv := &http.Server{Addr: addr, Handler: app, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 90 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		closeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(closeCtx)
	}()
	log.Printf("sync service listening on %s", addr)
	if err = srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
