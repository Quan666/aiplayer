package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const testToken = "test-token-with-more-than-24-characters"

func fixture(t *testing.T) *Server {
	t.Helper()
	s, e := openServer(filepath.Join(t.TempDir(), "sync.db"), testToken)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.db.Close() })
	return s
}
func call(s *Server, method, path, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func TestVersionConflictsTombstonesAndIsolation(t *testing.T) {
	s := fixture(t)
	if w := call(s, "GET", "/v1/changes", "", ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	body := `{"id":"video1","kind":"media","version":0,"deleted":false,"data":{"title":"第一集","fileName":"第一集.mkv"}}`
	if w := call(s, "PUT", "/v1/records", body, testToken); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := call(s, "PUT", "/v1/records", body, testToken); w.Code != 409 {
		t.Fatal(w.Code)
	}
	if w := call(s, "PUT", "/v1/records", `{"id":"video1","kind":"media","version":1,"deleted":true,"data":{}}`, testToken); w.Code != 200 {
		t.Fatal(w.Code)
	}
	w := call(s, "GET", "/v1/changes?after=0", "", testToken)
	var result struct {
		Changes []Change
		Cursor  int64
	}
	if e := json.Unmarshal(w.Body.Bytes(), &result); e != nil {
		t.Fatal(e)
	}
	if len(result.Changes) != 2 || !result.Changes[1].Deleted || result.Cursor != 2 {
		t.Fatal(w.Body.String())
	}
	w = call(s, "PUT", "/v1/records", `{"id":"video2","kind":"media","version":0,"data":{"token":"secret"}}`, testToken)
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
	w = call(s, "PUT", "/v1/records", `{"id":"video2","kind":"media","version":0,"data":{"fileName":"/private/file.mkv"}}`, testToken)
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
}
func TestConcurrentWritersCannotBothWin(t *testing.T) {
	s := fixture(t)
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := call(s, "PUT", "/v1/records", `{"id":"v","kind":"progress","version":0,"data":{"position":10}}`, testToken)
			codes <- w.Code
		}()
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for c := range codes {
		counts[c]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatal(counts)
	}
}
func TestPaginationAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync.db")
	s, e := openServer(path, testToken)
	if e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 205; i++ {
		kind, data := "progress", map[string]any{"position": 1}
		if i%2 == 1 {
			kind, data = "vault", encryptedData(t)
		}
		w := call(s, "PUT", "/v1/records", recordBody(t, fmt.Sprintf("v%d", i), kind, 0, false, data), testToken)
		if w.Code != 200 {
			t.Fatal(w.Body.String())
		}
	}
	s.db.Close()
	s, e = openServer(path, testToken)
	if e != nil {
		t.Fatal(e)
	}
	defer s.db.Close()
	var page struct {
		Changes []Change
		Cursor  int64
		HasMore bool
	}
	w := call(s, "GET", "/v1/changes", "", testToken)
	if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil || len(page.Changes) != 200 || !page.HasMore || page.Cursor != 200 {
		t.Fatal(w.Body.String())
	}
	for i, change := range page.Changes {
		kind := "progress"
		if i%2 == 1 {
			kind = "vault"
		}
		if change.ID != fmt.Sprintf("v%d", i) || change.Sequence != int64(i+1) || change.Kind != kind {
			t.Fatal("mixed history changed after restart", change)
		}
	}
	w = call(s, "GET", fmt.Sprintf("/v1/changes?after=%d", page.Cursor), "", testToken)
	if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil || len(page.Changes) != 5 || page.HasMore || page.Cursor != 205 || page.Changes[0].Sequence != 201 {
		t.Fatal(w.Body.String())
	}
}

func TestPublicMetadataRoundTripAndPrivateFieldsRejected(t *testing.T) {
	s := fixture(t)
	body := `{"id":"tv-1","kind":"media","version":0,"data":{"title":"第一集","fileName":"第一集.mkv","metadataProvider":"tmdb","tmdbId":"tv:100","metadataTitle":"作品","rating":8.5,"ratingCount":100,"totalEpisodes":12,"totalSeasons":null,"airDate":"2026-01-01","genres":["动画","喜剧"],"metadataType":"tv"}}`
	if w := call(s, "PUT", "/v1/records", body, testToken); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	w := call(s, "GET", "/v1/changes?after=0", "", testToken)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"rating":8.5`) || !strings.Contains(w.Body.String(), `"动画"`) {
		t.Fatal(w.Body.String())
	}
	for _, data := range []string{`{"tmdbApiKey":"private"}`, `{"apiKey":"private"}`, `{"path":"/private/video.mkv"}`, `{"genres":[{"path":"private"}]}`, `{"rating":11}`, `{"totalEpisodes":1.5}`, `{"metadataProvider":"unknown"}`} {
		body := fmt.Sprintf(`{"id":"bad-metadata","kind":"media","version":0,"data":%s}`, data)
		if w := call(s, "PUT", "/v1/records", body, testToken); w.Code != 400 {
			t.Fatalf("accepted %s: %d", data, w.Code)
		}
	}
}
