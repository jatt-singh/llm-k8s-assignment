// API gateway: the only service exposed through the ingress. It forwards
// /api/v1/items to the catalog and /api/v1/ask to the assistant.
package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"time"

	"llmstack/services/internal/server"
)

const maxBodyBytes = 16 << 10

type gateway struct {
	catalogURL   string
	assistantURL string
	client       *http.Client
	log          *slog.Logger
}

// forward proxies one request to an upstream and copies status and body back.
func (g *gateway) forward(w http.ResponseWriter, r *http.Request, method, url string, timeout time.Duration) {
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	var body io.Reader
	if r.Body != nil {
		body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		server.WriteError(w, http.StatusInternalServerError, "bad upstream request")
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := g.client.Do(req)
	if err != nil {
		g.log.Warn("upstream failed", "url", url, "err", err)
		if ctx.Err() == context.DeadlineExceeded {
			server.WriteError(w, http.StatusGatewayTimeout, "upstream timed out")
			return
		}
		server.WriteError(w, http.StatusBadGateway, "upstream unavailable")
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (g *gateway) routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/items", func(w http.ResponseWriter, r *http.Request) {
		g.forward(w, r, http.MethodGet, g.catalogURL+"/items", 5*time.Second)
	})
	mux.HandleFunc("GET /api/v1/items/{id}", func(w http.ResponseWriter, r *http.Request) {
		g.forward(w, r, http.MethodGet, g.catalogURL+"/items/"+r.PathValue("id"), 5*time.Second)
	})
	mux.HandleFunc("POST /api/v1/ask", func(w http.ResponseWriter, r *http.Request) {
		g.forward(w, r, http.MethodPost, g.assistantURL+"/answer", 120*time.Second)
	})
}

func main() {
	log := server.NewLogger("gateway")
	g := &gateway{
		catalogURL:   server.Env("CATALOG_URL", "http://catalog:8080"),
		assistantURL: server.Env("ASSISTANT_URL", "http://assistant:8080"),
		client:       &http.Client{},
		log:          log,
	}
	mux := server.NewMux()
	g.routes(mux)
	server.Run(log, ":"+server.Env("PORT", "8080"), server.Instrument("gateway", log, mux), 130*time.Second)
}
