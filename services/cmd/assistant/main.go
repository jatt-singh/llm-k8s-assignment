// Assistant service: answers a question, optionally grounded on a catalog
// item, by calling the internal LLM (llama.cpp, OpenAI-compatible API).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"llmstack/services/internal/catalog"
	"llmstack/services/internal/server"
)

const maxQuestionLen = 1000

const systemPrompt = "You are a concise shopping assistant. Answer in at most three sentences. " +
	"If product context is given, base your answer only on it."

var errItemNotFound = errors.New("item not found")

type assistant struct {
	catalogURL string
	llmURL     string
	llmAPIKey  string // from a Kubernetes Secret; never logged
	model      string
	maxTokens  int
	client     *http.Client
	log        *slog.Logger
}

type answerRequest struct {
	Question string `json:"question"`
	ItemID   string `json:"item_id,omitempty"`
}

type answerResponse struct {
	Answer string `json:"answer"`
	ItemID string `json:"item_id,omitempty"`
	Model  string `json:"model,omitempty"`
}

func (a *assistant) fetchItem(ctx context.Context, id string) (catalog.Item, error) {
	var item catalog.Item
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.catalogURL+"/items/"+id, nil)
	if err != nil {
		return item, err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return item, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		return item, json.NewDecoder(resp.Body).Decode(&item)
	case http.StatusNotFound:
		return item, errItemNotFound
	default:
		return item, fmt.Errorf("catalog returned %d", resp.StatusCode)
	}
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func (a *assistant) complete(ctx context.Context, msgs []chatMessage) (string, error) {
	payload, _ := json.Marshal(map[string]any{
		"model":       a.model,
		"messages":    msgs,
		"max_tokens":  a.maxTokens,
		"temperature": 0.2,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.llmURL+"/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if a.llmAPIKey != "" {
		req.Header.Set("Authorization", "Bearer "+a.llmAPIKey)
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("llm returned %d", resp.StatusCode)
	}
	var out struct {
		Choices []struct {
			Message chatMessage `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if len(out.Choices) == 0 {
		return "", errors.New("llm returned no choices")
	}
	return strings.TrimSpace(out.Choices[0].Message.Content), nil
}

func (a *assistant) answer(w http.ResponseWriter, r *http.Request) {
	var req answerRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		server.WriteError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	req.Question = strings.TrimSpace(req.Question)
	if req.Question == "" || len(req.Question) > maxQuestionLen {
		server.WriteError(w, http.StatusBadRequest, "question is required and must be at most 1000 characters")
		return
	}

	ctx := r.Context()
	user := req.Question
	if req.ItemID != "" {
		item, err := a.fetchItem(ctx, req.ItemID)
		if errors.Is(err, errItemNotFound) {
			server.WriteError(w, http.StatusNotFound, "item not found")
			return
		}
		if err != nil {
			a.log.Warn("catalog lookup failed", "item_id", req.ItemID, "err", err)
			server.WriteError(w, http.StatusBadGateway, "catalog unavailable")
			return
		}
		user = fmt.Sprintf("Product: %s (%s, $%.2f)\nDescription: %s\n\nQuestion: %s",
			item.Name, item.Category, item.Price, item.Description, req.Question)
	}

	start := time.Now()
	text, err := a.complete(ctx, []chatMessage{
		{Role: "system", Content: systemPrompt},
		{Role: "user", Content: user},
	})
	if err != nil {
		a.log.Warn("llm call failed", "err", err)
		if errors.Is(err, context.DeadlineExceeded) {
			server.WriteError(w, http.StatusGatewayTimeout, "model timed out")
			return
		}
		server.WriteError(w, http.StatusBadGateway, "model unavailable")
		return
	}
	a.log.Info("llm answered", "item_id", req.ItemID, "llm_ms", time.Since(start).Milliseconds())
	server.WriteJSON(w, http.StatusOK, answerResponse{Answer: text, ItemID: req.ItemID, Model: a.model})
}

func main() {
	log := server.NewLogger("assistant")
	timeout, err := time.ParseDuration(server.Env("LLM_TIMEOUT", "110s"))
	if err != nil {
		log.Error("invalid LLM_TIMEOUT", "err", err)
		return
	}
	maxTokens, err := strconv.Atoi(server.Env("LLM_MAX_TOKENS", "128"))
	if err != nil {
		log.Error("invalid LLM_MAX_TOKENS", "err", err)
		return
	}
	a := &assistant{
		catalogURL: server.Env("CATALOG_URL", "http://catalog:8080"),
		llmURL:     server.Env("LLM_URL", "http://llm:8080"),
		llmAPIKey:  server.Env("LLM_API_KEY", ""),
		model:      server.Env("LLM_MODEL", "qwen2.5-0.5b-instruct"),
		maxTokens:  maxTokens,
		client:     &http.Client{Timeout: timeout},
		log:        log,
	}
	mux := server.NewMux()
	mux.HandleFunc("POST /answer", a.answer)
	server.Run(log, ":"+server.Env("PORT", "8080"), server.Instrument("assistant", log, mux), timeout+10*time.Second)
}
