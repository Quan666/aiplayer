package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestPublicExtensionsSurviveConflictRestartAndDeletion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "extensions.db")
	s, err := openServer(path, testToken)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.db.Close() })
	data := `{"title":"Video","schemaRevision":7,"details":{"chapters":[{"name":"Start","begin":0}],"precision":9007199254740993,"futureNumber":1e1000,"nullable":null},"flags":[true,false]}`
	for _, kind := range []string{"media", "progress", "watched", "match", "collection.v2"} {
		body := fmt.Sprintf(`{"kind":%q,"id":"future","version":0,"data":%s}`, kind, data)
		response := call(s, "PUT", "/v1/records", body, testToken)
		var accepted Record
		if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &accepted) != nil || accepted.Version != 1 || string(accepted.Data) != data {
			t.Fatal(kind, response.Code, response.Body.String())
		}
		response = call(s, "PUT", "/v1/records", body, testToken)
		var conflict struct{ Current Record }
		if response.Code != 409 || json.Unmarshal(response.Body.Bytes(), &conflict) != nil || !bytes.Equal(conflict.Current.Data, accepted.Data) {
			t.Fatal(kind, response.Code, response.Body.String())
		}
		var stored []byte
		if err := s.db.QueryRow("SELECT data FROM records WHERE kind=? AND id='future'", kind).Scan(&stored); err != nil || string(stored) != data {
			t.Fatal("stored extension changed", kind, err, string(stored))
		}
	}
	s.db.Close()
	s, err = openServer(path, testToken)
	if err != nil {
		t.Fatal(err)
	}
	response := call(s, "GET", "/v1/changes", "", testToken)
	var page struct {
		Changes []Change
		Cursor  int64
	}
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &page) != nil || len(page.Changes) != 5 || page.Cursor != 5 {
		t.Fatal(response.Code, response.Body.String())
	}
	for _, change := range page.Changes {
		if string(change.Data) != data || change.Version != 1 {
			t.Fatal("extension lost after restart", change)
		}
	}
	response = call(s, "PUT", "/v1/records", `{"kind":"collection.v2","id":"future","version":1,"deleted":true,"data":{}}`, testToken)
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	response = call(s, "GET", "/v1/changes?after=5", "", testToken)
	if json.Unmarshal(response.Body.Bytes(), &page) != nil || len(page.Changes) != 1 || page.Cursor != 6 || !page.Changes[0].Deleted || page.Changes[0].Version != 2 {
		t.Fatal(response.Body.String())
	}
}

func TestPublicExtensionsCannotHidePrivateFields(t *testing.T) {
	dataCases := []string{
		`{"extensions":{"apiKey":"private"}}`,
		`{"extensions":[{"credentials":{"value":"private"}}]}`,
		`{"extensions":{"tmdb.API_KEY":"private"}}`,
		`{"extensions":{"source-password":"private"}}`,
		`{"extensions":{"Access.Token":"private"}}`,
		`{"extensions":{"remoteFilePath":"/private/video.mkv"}}`,
		`{"extensions":{"URL":"https://private.example"}}`,
		`{"extensions":{"HEADERS":{"X-Auth":"private"}}}`,
		`{"extensions":{"fileName":"/private/video.mkv"}}`,
		`{"extensions":{"FILE_NAME":"C:\\private\\video.mkv"}}`,
		`{"extensions":{"apiKey":"private"},"extensions":{}}`,
		`{"extensions":[{"nested":{"password":"private"},"nested":{}}]}`,
	}
	s := fixture(t)
	for _, kind := range []string{"media", "future.kind"} {
		for _, data := range dataCases {
			body := fmt.Sprintf(`{"kind":%q,"id":"private","version":0,"data":%s}`, kind, data)
			response := call(s, "PUT", "/v1/records", body, testToken)
			if response.Code != 400 {
				t.Fatal(kind, data, response.Code, response.Body.String())
			}
			if strings.Contains(response.Body.String(), "private.example") || strings.Contains(response.Body.String(), "API_KEY") {
				t.Fatal("validation echoed request content", response.Body.String())
			}
		}
	}
	var count int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM changes").Scan(&count); err != nil || count != 0 {
		t.Fatal("rejected data changed history", count, err)
	}
}

func TestExtensionBoundsAndStableEnvelope(t *testing.T) {
	s := fixture(t)
	for _, body := range []string{
		`{"kind":"bad/kind","id":"v","version":0,"data":{}}`,
		`{"kind":"future","id":"v","version":-1,"data":{}}`,
		`{"kind":"future","id":"v","version":9223372036854775807,"data":{}}`,
		`{"kind":"future","id":"v","version":0,"data":[]}`,
		`{"kind":"future","id":"v","version":0,"data":null}`,
		`{"kind":"future","id":"v","version":0,"data":{"details":1,"details":2}}`,
		`{"kind":"future","id":"v","version":0,"unrecognizedEnvelopeField":1,"data":{}}`,
		`{"kind":"future","id":"v","version":0,"data":{}} {}`,
		`{"kind":"future","id":"v","version":0,"data":{"nested":` + strings.Repeat("[", maxRecordDataDepth+1) + "0" + strings.Repeat("]", maxRecordDataDepth+1) + `}}`,
		`{"kind":"future","id":"v","version":0,"data":{"large":"` + strings.Repeat("x", 256*1024) + `"}}`,
	} {
		response := call(s, "PUT", "/v1/records", body, testToken)
		if response.Code != 400 {
			t.Fatal(response.Code, response.Body.String())
		}
	}
	// Changed types of established public fields still need a new client schema;
	// permissive additive fields must not poison current readers.
	for _, body := range []string{
		`{"kind":"progress","id":"v","version":0,"data":{"position":"10"}}`,
		`{"kind":"media","id":"v","version":0,"data":{"title":{"value":"Video"}}}`,
		`{"kind":"watched","id":"v","version":0,"data":{"watched":1}}`,
	} {
		if response := call(s, "PUT", "/v1/records", body, testToken); response.Code != 400 {
			t.Fatal(response.Code, response.Body.String())
		}
	}
}
