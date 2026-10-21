package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"llmstack/services/internal/server"
)

func newTestGateway(catalogURL, assistantURL string) *http.ServeMux {
	g := &gateway{
		catalogURL:   catalogURL,
		assistantURL: assistantURL,
		client:       &http.Client{},
		log:          slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	mux := server.NewMux()
	g.routes(mux)
	return mux
}

func TestForwardsToUpstreams(t *testing.T) {
	catalog := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/items" {
			t.Errorf("catalog got path %s", r.URL.Path)
		}
		_, _ = io.WriteString(w, `{"items":[]}`)
	}))
	defer catalog.Close()
	assistant := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/answer" {
			t.Errorf("assistant got %s %s", r.Method, r.URL.Path)
		}
		b, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(b), "hello") {
			t.Errorf("body not forwarded: %s", b)
		}
		_, _ = io.WriteString(w, `{"answer":"hi"}`)
	}))
	defer assistant.Close()

	mux := newTestGateway(catalog.URL, assistant.URL)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/items", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "items") {
		t.Fatalf("items: %d %s", rec.Code, rec.Body)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/ask", strings.NewReader(`{"question":"hello"}`)))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "hi") {
		t.Fatalf("ask: %d %s", rec.Code, rec.Body)
	}
}

func TestUpstreamDownReturns502(t *testing.T) {
	mux := newTestGateway("http://127.0.0.1:1", "http://127.0.0.1:1")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/items", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502", rec.Code)
	}
}

func TestUpstreamStatusPassedThrough(t *testing.T) {
	catalog := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		server.WriteError(w, http.StatusNotFound, "item not found")
	}))
	defer catalog.Close()
	mux := newTestGateway(catalog.URL, "")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/items/nope", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("got %d, want 404", rec.Code)
	}
}
