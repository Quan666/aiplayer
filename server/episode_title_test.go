package main

import (
	"encoding/json"
	"testing"
)

func TestAndroidMovieEpisodeTitleSync(t *testing.T) {
	s := fixture(t)
	body := `{"id":"movie","kind":"media","version":0,"data":{"metadataProvider":"tmdb","metadataType":"movie","tmdbId":"123","season":"","episode":"","episodeTitle":""}}`
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
	if json.Unmarshal(page.Changes[0].Data, &data) != nil || data["episodeTitle"] != "" {
		t.Fatal("episode title not preserved")
	}
	for _, value := range []string{`null`, `123`, `{"token":"private"}`} {
		body = `{"id":"invalid","kind":"media","version":0,"data":{"episodeTitle":` + value + `}}`
		if response = call(s, "PUT", "/v1/records", body, testToken); response.Code != 400 {
			t.Fatal(response.Code, response.Body.String())
		}
	}
}
