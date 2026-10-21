// Catalog service: serves the seeded item list. Cluster-internal only.
package main

import (
	"net/http"
	"time"

	"llmstack/services/internal/catalog"
	"llmstack/services/internal/server"
)

func newHandler(mux *http.ServeMux) {
	mux.HandleFunc("GET /items", func(w http.ResponseWriter, _ *http.Request) {
		server.WriteJSON(w, http.StatusOK, map[string]any{"items": catalog.Items})
	})
	mux.HandleFunc("GET /items/{id}", func(w http.ResponseWriter, r *http.Request) {
		item, ok := catalog.Find(r.PathValue("id"))
		if !ok {
			server.WriteError(w, http.StatusNotFound, "item not found")
			return
		}
		server.WriteJSON(w, http.StatusOK, item)
	})
}

func main() {
	log := server.NewLogger("catalog")
	mux := server.NewMux()
	newHandler(mux)
	server.Run(log, ":"+server.Env("PORT", "8080"), server.Instrument("catalog", log, mux), 10*time.Second)
}
