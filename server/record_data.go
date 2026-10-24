package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

const maxRecordDataDepth = 32

// Decode only to validate. Record.Data itself is persisted unchanged, preserving
// unknown fields, numeric precision and future client-owned business schemas.
func decodeRecordData(raw json.RawMessage) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	value, err := readRecordValue(dec, 0)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("invalid data")
	}
	data, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("data must be an object")
	}
	return data, nil
}

func readRecordValue(dec *json.Decoder, depth int) (any, error) {
	if depth > maxRecordDataDepth {
		return nil, errors.New("data nesting limit exceeded")
	}
	token, err := dec.Token()
	if err != nil {
		return nil, errors.New("invalid data")
	}
	switch token {
	case json.Delim('{'):
		object := make(map[string]any)
		for dec.More() {
			keyToken, err := dec.Token()
			key, ok := keyToken.(string)
			if err != nil || !ok {
				return nil, errors.New("invalid data")
			}
			if _, exists := object[key]; exists {
				// Otherwise an overwritten value could hide private fields from
				// validation while still being stored in the original JSON.
				return nil, errors.New("duplicate data field")
			}
			value, err := readRecordValue(dec, depth+1)
			if err != nil {
				return nil, err
			}
			object[key] = value
		}
		if _, err := dec.Token(); err != nil {
			return nil, errors.New("invalid data")
		}
		return object, nil
	case json.Delim('['):
		items := make([]any, 0)
		for dec.More() {
			value, err := readRecordValue(dec, depth+1)
			if err != nil {
				return nil, err
			}
			items = append(items, value)
		}
		if _, err := dec.Token(); err != nil {
			return nil, errors.New("invalid data")
		}
		return items, nil
	default:
		return token, nil
	}
}

func recordNumber(value any) (float64, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	n, err := number.Float64()
	return n, err == nil
}

func publicFieldName(key string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, strings.ToLower(key))
}

func privatePublicField(key string) bool {
	switch key {
	case "auth", "authorization", "cookie", "cookies", "headers", "username", "host", "hostname", "address", "location", "endpoint", "url", "uri":
		return true
	}
	for _, suffix := range []string{"apikey", "token", "password", "secret", "credential", "credentials", "path"} {
		if strings.HasSuffix(key, suffix) {
			return true
		}
	}
	return false
}

// This catches accidental plaintext credentials and local paths in extension
// objects too. It is not a substitute for the client's privacy boundary: new
// private data belongs inside vault ciphertext, never an arbitrary public key.
func validatePublicData(value any) error {
	switch value := value.(type) {
	case map[string]any:
		for key, item := range value {
			name := publicFieldName(key)
			if privatePublicField(name) {
				return errors.New("private fields require encrypted vault data")
			}
			if name == "filename" {
				fileName, ok := item.(string)
				if !ok || strings.ContainsAny(fileName, "/\\") {
					return errors.New("fileName must not contain a path")
				}
			}
			if err := validatePublicData(item); err != nil {
				return err
			}
		}
	case []any:
		for _, item := range value {
			if err := validatePublicData(item); err != nil {
				return err
			}
		}
	}
	return nil
}
