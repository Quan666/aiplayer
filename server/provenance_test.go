package main

import (
	"database/sql"
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestEditClockAndDeviceSurviveUploadConflictAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync.db")
	server, err := openServer(path, testToken)
	if err != nil {
		t.Fatal(err)
	}
	body := `{"kind":"media","id":"video","version":0,"modifiedAt":"2026-10-22T12:00:01.123456Z","deviceId":"device-one","deviceName":"客厅 MacBook · macOS","data":{"title":"Episode"}}`
	assertRecord := func(record Record) {
		t.Helper()
		if record.ModifiedAt != "2026-10-22T12:00:01.123456Z" || record.DeviceID != "device-one" || record.DeviceName != "客厅 MacBook · macOS" {
			t.Fatalf("missing provenance: %+v", record)
		}
	}
	response := call(server, "PUT", "/v1/records", body, testToken)
	var accepted Record
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &accepted) != nil {
		t.Fatal(response.Body.String())
	}
	assertRecord(accepted)
	response = call(server, "PUT", "/v1/records", body, testToken)
	var conflict struct{ Current Record }
	if response.Code != 409 || json.Unmarshal(response.Body.Bytes(), &conflict) != nil {
		t.Fatal(response.Body.String())
	}
	assertRecord(conflict.Current)
	server.db.Close()
	server, err = openServer(path, testToken)
	if err != nil {
		t.Fatal(err)
	}
	defer server.db.Close()
	response = call(server, "GET", "/v1/changes", "", testToken)
	var page struct{ Changes []Change }
	if json.Unmarshal(response.Body.Bytes(), &page) != nil || len(page.Changes) != 1 {
		t.Fatal(response.Body.String())
	}
	assertRecord(page.Changes[0].Record)
}

func TestLegacyDatabaseUpgradePreservesRecordsAndCursor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE records (id TEXT NOT NULL, kind TEXT NOT NULL, version INTEGER NOT NULL, deleted INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(kind,id));
      CREATE TABLE changes (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, kind TEXT NOT NULL, version INTEGER NOT NULL, deleted INTEGER NOT NULL, data BLOB NOT NULL);
      INSERT INTO records VALUES('old','media',2,0,CAST('{"title":"Old"}' AS BLOB));
      INSERT INTO changes VALUES(42,'old','media',2,0,CAST('{"title":"Old"}' AS BLOB));`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	server, err := openServer(path, testToken)
	if err != nil {
		t.Fatal(err)
	}
	defer server.db.Close()
	response := call(server, "GET", "/v1/changes?after=41", "", testToken)
	var page struct {
		Changes []Change
		Cursor  int64
	}
	if json.Unmarshal(response.Body.Bytes(), &page) != nil || page.Cursor != 42 || len(page.Changes) != 1 {
		t.Fatal(response.Body.String())
	}
	if page.Changes[0].ModifiedAt != "" || page.Changes[0].Version != 2 {
		t.Fatal(page.Changes)
	}
	body := `{"kind":"media","id":"old","version":2,"modifiedAt":"2026-10-22T12:00:00Z","deviceId":"device","deviceName":"Pixel","data":{"title":"New"}}`
	if response = call(server, "PUT", "/v1/records", body, testToken); response.Code != 200 {
		t.Fatal(response.Body.String())
	}
}
