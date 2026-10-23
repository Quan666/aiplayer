package main

import (
	"encoding/json"
	"testing"
)

func TestAndroidProgressDevicePlatformSync(t *testing.T) {
	s := fixture(t)
	body := `{"id":"video:123","kind":"progress","version":0,"data":{"position":12.5,"duration":300,"updatedAt":"2026-10-23T04:00:00Z","devicePlatform":"android"}}`
	response := call(s, "PUT", "/v1/records", body, testToken)
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	response = call(s, "GET", "/v1/changes?after=0", "", testToken)
	var page struct{ Changes []Change }
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &page) != nil || len(page.Changes) != 1 {
		t.Fatal(response.Code, response.Body.String())
	}
	var data map[string]any
	if json.Unmarshal(page.Changes[0].Data, &data) != nil || data["devicePlatform"] != "android" || data["position"] != 12.5 {
		t.Fatal("device platform or progress lost")
	}
	for _, value := range []string{`null`, `123`, `{"token":"private"}`} {
		body = `{"id":"invalid","kind":"progress","version":0,"data":{"devicePlatform":` + value + `}}`
		if response = call(s, "PUT", "/v1/records", body, testToken); response.Code != 400 {
			t.Fatal(response.Code, response.Body.String())
		}
	}
}
