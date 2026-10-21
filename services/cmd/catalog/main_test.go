package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"llmstack/services/internal/server"
)

func TestCatalog(t *testing.T) {
	mux := server.NewMux()
	newHandler(mux)

	tests := []struct {
		path string
		want int
	}{
		{"/healthz", http.StatusOK},
		{"/items", http.StatusOK},
		{"/items/item-1", http.StatusOK},
		{"/items/does-not-exist", http.StatusNotFound},
	}
	for _, tc := range tests {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))
		if rec.Code != tc.want {
			t.Errorf("GET %s = %d, want %d", tc.path, rec.Code, tc.want)
		}
	}
}

func TestListReturnsSeededItems(t *testing.T) {
	mux := server.NewMux()
	newHandler(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/items", nil))

	var body struct {
		Items []struct{ ID string } `json:"items"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if len(body.Items) == 0 || body.Items[0].ID != "item-1" {
		t.Fatalf("unexpected items: %+v", body.Items)
	}
}
