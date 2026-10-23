package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
)

func encryptedData(t *testing.T) map[string]any {
	t.Helper()
	block, err := aes.NewCipher(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	nonce := bytes.Repeat([]byte{1}, gcm.NonceSize())
	sealed := gcm.Seal(nil, nonce, []byte(`{"apiKey":"private-test-key","address":"https://private.example"}`), []byte("aiplayer:vault:1:secret:aiApiKey"))
	return map[string]any{
		"algorithm":  "AES-GCM-256",
		"nonce":      base64.StdEncoding.EncodeToString(nonce),
		"ciphertext": base64.StdEncoding.EncodeToString(sealed[:len(sealed)-gcm.Overhead()]),
		"mac":        base64.StdEncoding.EncodeToString(sealed[len(sealed)-gcm.Overhead():]),
	}
}

func recordBody(t *testing.T, id, kind string, version int64, deleted bool, data any) string {
	t.Helper()
	body, err := json.Marshal(map[string]any{"id": id, "kind": kind, "version": version, "deleted": deleted, "data": data})
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func TestEncryptedVaultRoundTripConflictAndTombstone(t *testing.T) {
	s := fixture(t)
	data := encryptedData(t)
	body := recordBody(t, "secret:aiApiKey", "vault", 0, false, data)
	w := call(s, "PUT", "/v1/records", body, testToken)
	if w.Code != 200 || strings.Contains(w.Body.String(), "private-test-key") || strings.Contains(w.Body.String(), "private.example") {
		t.Fatal(w.Code, w.Body.String())
	}
	var accepted Record
	if err := json.Unmarshal(w.Body.Bytes(), &accepted); err != nil || accepted.Version != 1 {
		t.Fatal(err, w.Body.String())
	}
	w = call(s, "PUT", "/v1/records", body, testToken)
	var conflict struct{ Current Record }
	if err := json.Unmarshal(w.Body.Bytes(), &conflict); err != nil || w.Code != 409 || conflict.Current.Version != 1 || !bytes.Equal(conflict.Current.Data, accepted.Data) {
		t.Fatal(err, w.Code, w.Body.String())
	}
	w = call(s, "PUT", "/v1/records", recordBody(t, "secret:aiApiKey", "vault", 1, true, map[string]any{}), testToken)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	w = call(s, "GET", "/v1/changes", "", testToken)
	var page struct {
		Changes []Change
		Cursor  int64
	}
	if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil || len(page.Changes) != 2 || page.Cursor != 2 {
		t.Fatal(err, w.Body.String())
	}
	if !bytes.Equal(page.Changes[0].Data, accepted.Data) || !page.Changes[1].Deleted || page.Changes[1].Version != 2 || string(page.Changes[1].Data) != "{}" {
		t.Fatal(w.Body.String())
	}
}

func TestVaultRejectsMalformedEnvelopesAndPlaintext(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"algorithm", func(d map[string]any) { d["algorithm"] = "AES-CBC" }},
		{"missing algorithm", func(d map[string]any) { delete(d, "algorithm") }},
		{"missing ciphertext", func(d map[string]any) { delete(d, "ciphertext") }},
		{"empty ciphertext", func(d map[string]any) { d["ciphertext"] = "" }},
		{"invalid base64", func(d map[string]any) { d["ciphertext"] = "not-base64!" }},
		{"noncanonical base64", func(d map[string]any) { d["ciphertext"] = "YR==" }},
		{"base64 newline", func(d map[string]any) { d["nonce"] = "AQEBAQEB\nAQEBAQEB" }},
		{"short nonce", func(d map[string]any) { d["nonce"] = base64.StdEncoding.EncodeToString(make([]byte, 11)) }},
		{"long nonce", func(d map[string]any) { d["nonce"] = base64.StdEncoding.EncodeToString(make([]byte, 13)) }},
		{"short mac", func(d map[string]any) { d["mac"] = base64.StdEncoding.EncodeToString(make([]byte, 15)) }},
		{"long mac", func(d map[string]any) { d["mac"] = base64.StdEncoding.EncodeToString(make([]byte, 17)) }},
		{"nested payload", func(d map[string]any) { d["ciphertext"] = map[string]any{"apiKey": "private"} }},
		{"numeric nonce", func(d map[string]any) { d["nonce"] = 123 }},
		{"plaintext field", func(d map[string]any) { d["apiKey"] = "private" }},
		{"unknown replacement", func(d map[string]any) { delete(d, "mac"); d["password"] = "private" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := fixture(t)
			data := encryptedData(t)
			tc.mutate(data)
			w := call(s, "PUT", "/v1/records", recordBody(t, "secret:test", "vault", 0, false, data), testToken)
			if w.Code != 400 {
				t.Fatal(w.Code, w.Body.String())
			}
			var count int
			if err := s.db.QueryRow("SELECT COUNT(*) FROM changes").Scan(&count); err != nil || count != 0 {
				t.Fatal("invalid record changed history", count, err)
			}
		})
	}
	for _, data := range []any{nil, []any{}, map[string]any{}, map[string]any{"apiKey": "private"}} {
		s := fixture(t)
		w := call(s, "PUT", "/v1/records", recordBody(t, "secret:test", "vault", 0, false, data), testToken)
		if w.Code != 400 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	s := fixture(t)
	w := call(s, "PUT", "/v1/records", recordBody(t, "secret:test", "vault", 0, true, encryptedData(t)), testToken)
	if w.Code != 400 {
		t.Fatal("nonempty tombstone accepted", w.Code, w.Body.String())
	}
}

func TestVaultPayloadAndRequestBounds(t *testing.T) {
	s := fixture(t)
	for _, size := range []int{maxVaultCiphertext, maxVaultCiphertext + 1, 256 * 1024} {
		data := encryptedData(t)
		data["ciphertext"] = base64.StdEncoding.EncodeToString(make([]byte, size))
		w := call(s, "PUT", "/v1/records", recordBody(t, fmt.Sprintf("source:%d", size), "vault", 0, false, data), testToken)
		want := 400
		if size == maxVaultCiphertext {
			want = 200
		}
		if w.Code != want {
			t.Fatal(size, w.Code, w.Body.String())
		}
	}
}

func TestConcurrentEncryptedWritersCannotBothWin(t *testing.T) {
	s := fixture(t)
	body := recordBody(t, "setting:test", "vault", 0, false, encryptedData(t))
	codes := make(chan int, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes <- call(s, "PUT", "/v1/records", body, testToken).Code
		}()
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatal(counts)
	}
}
