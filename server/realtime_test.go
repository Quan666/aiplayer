package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func pollAsync(t *testing.T, s *Server, path string) (<-chan *httptest.ResponseRecorder, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	r := httptest.NewRequest("GET", path, nil).WithContext(ctx)
	r.Header.Set("Authorization", "Bearer "+testToken)
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		result <- w
	}()
	return result, cancel
}

func pollResult(t *testing.T, result <-chan *httptest.ResponseRecorder) *httptest.ResponseRecorder {
	t.Helper()
	select {
	case response := <-result:
		return response
	case <-time.After(2 * time.Second):
		t.Fatal("long poll did not wake")
		return nil
	}
}

func assertPending(t *testing.T, result <-chan *httptest.ResponseRecorder) {
	t.Helper()
	select {
	case response := <-result:
		t.Fatal("long poll returned without a change", response.Code, response.Body.String())
	case <-time.After(20 * time.Millisecond):
	}
}

func TestChangesLongPollBroadcastAndCommitVisibility(t *testing.T) {
	s := fixture(t)
	const count = 12
	waiters := make([]<-chan *httptest.ResponseRecorder, count)
	for i := range waiters {
		waiters[i], _ = pollAsync(t, s, "/v1/changes?after=0&wait=25")
	}
	assertPending(t, waiters[0])
	if response := call(s, "PUT", "/v1/records", `{"id":"playing","kind":"progress","version":0,"data":{"position":12}}`, testToken); response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	for _, waiter := range waiters {
		response := pollResult(t, waiter)
		var page struct {
			Changes []Change
			Cursor  int64
			HasMore bool
		}
		if err := json.Unmarshal(response.Body.Bytes(), &page); err != nil || response.Code != 200 || len(page.Changes) != 1 || page.Cursor != 1 || page.HasMore || page.Changes[0].ID != "playing" {
			t.Fatal(response.Code, response.Body.String(), err)
		}
	}
	if s.db.Stats().InUse != 0 {
		t.Fatal("long polls retained database connections")
	}
}

func TestChangesSubscribeWriteRaceAndConflictDoesNotNotify(t *testing.T) {
	s := fixture(t)
	for i := 0; i < 30; i++ {
		result, _ := pollAsync(t, s, fmt.Sprintf("/v1/changes?after=%d&wait=25", i))
		body := fmt.Sprintf(`{"id":"race-%d","kind":"progress","version":0,"data":{"position":0}}`, i)
		if response := call(s, "PUT", "/v1/records", body, testToken); response.Code != 200 {
			t.Fatal(response.Code, response.Body.String())
		}
		response := pollResult(t, result)
		if response.Code != 200 || !strings.Contains(response.Body.String(), fmt.Sprintf(`"cursor":%d`, i+1)) {
			t.Fatal(response.Code, response.Body.String())
		}
		ready := s.changeSignal()
		if response := call(s, "PUT", "/v1/records", body, testToken); response.Code != 409 {
			t.Fatal(response.Code, response.Body.String())
		}
		select {
		case <-ready:
			t.Fatal("a conflict notified clients without a commit")
		default:
		}
	}
}

func TestChangesWaitTimeoutAndCancellation(t *testing.T) {
	s := fixture(t)
	started := time.Now()
	result, _ := pollAsync(t, s, "/v1/changes?after=99&wait=1")
	assertPending(t, result)
	// An unrelated sequence below the requested cursor must not reset the wait.
	call(s, "PUT", "/v1/records", `{"id":"older","kind":"progress","version":0,"data":{"position":0}}`, testToken)
	response := pollResult(t, result)
	if time.Since(started) < 900*time.Millisecond || response.Code != 200 || !strings.Contains(response.Body.String(), `"changes":[]`) || !strings.Contains(response.Body.String(), `"cursor":99`) {
		t.Fatal(response.Code, response.Body.String(), time.Since(started))
	}
	result, cancel := pollAsync(t, s, "/v1/changes?after=1&wait=25")
	assertPending(t, result)
	cancel()
	if response := pollResult(t, result); response.Body.Len() != 0 {
		t.Fatal("canceled request wrote a response", response.Body.String())
	}
}

func TestRealtimeQueryValidationAndAuthentication(t *testing.T) {
	s := fixture(t)
	for _, endpoint := range []string{"/v1/changes"} {
		for _, query := range []string{"?wait=-1", "?wait=26", "?wait=1.5", "?wait=no", "?after=-1&wait=25", "?after=no&wait=25"} {
			if response := call(s, "GET", endpoint+query, "", testToken); response.Code != 400 {
				t.Fatal(endpoint, query, response.Code, response.Body.String())
			}
		}
		if response := call(s, "GET", endpoint+"?wait=25", "", "wrong-token"); response.Code != 401 {
			t.Fatal(endpoint, response.Code)
		}
		if response := call(s, "GET", endpoint+"?wait=0", "", testToken); response.Code != 200 {
			t.Fatal(endpoint, response.Code)
		}
	}
}

func TestRemovedPlaybackEndpoints(t *testing.T) {
	s := fixture(t)
	for _, method := range []string{"GET", "PUT", "DELETE"} {
		response := call(s, method, "/v1/playback", "", testToken)
		if response.Code != 404 {
			t.Fatal(method, response.Code, response.Body.String())
		}
	}
}
