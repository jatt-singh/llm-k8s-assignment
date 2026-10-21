package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"llmstack/services/internal/catalog"
	"llmstack/services/internal/server"
)

// fakeLLM mimics llama.cpp's /v1/chat/completions and records the prompt.
func fakeLLM(t *testing.T, wantKey string, gotPrompt *string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+wantKey {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		var body struct {
			Messages []chatMessage `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		*gotPrompt = body.Messages[len(body.Messages)-1].Content
		_, _ = io.WriteString(w, `{"choices":[{"message":{"role":"assistant","content":" A fine item. "}}]}`)
	}))
}

func fakeCatalog() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		item, ok := catalog.Find(strings.TrimPrefix(r.URL.Path, "/items/"))
		if !ok {
			server.WriteError(w, http.StatusNotFound, "item not found")
			return
		}
		server.WriteJSON(w, http.StatusOK, item)
	}))
}

func newTestAssistant(catalogURL, llmURL string) *assistant {
	return &assistant{
		catalogURL: catalogURL, llmURL: llmURL, llmAPIKey: "test-key",
		model: "test", maxTokens: 16, client: &http.Client{},
		log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

func post(a *assistant, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	a.answer(rec, httptest.NewRequest(http.MethodPost, "/answer", strings.NewReader(body)))
	return rec
}

func TestAnswerWithItemContext(t *testing.T) {
	var prompt string
	llm := fakeLLM(t, "test-key", &prompt)
	defer llm.Close()
	cat := fakeCatalog()
	defer cat.Close()

	rec := post(newTestAssistant(cat.URL, llm.URL), `{"question":"Summarize this item","item_id":"item-1"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d: %s", rec.Code, rec.Body)
	}
	var resp answerResponse
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	if resp.Answer != "A fine item." {
		t.Errorf("answer = %q", resp.Answer)
	}
	if !strings.Contains(prompt, "Trail Running Shoes") {
		t.Errorf("catalog context missing from prompt: %q", prompt)
	}
}

func TestAnswerWithoutItem(t *testing.T) {
	var prompt string
	llm := fakeLLM(t, "test-key", &prompt)
	defer llm.Close()
	rec := post(newTestAssistant("http://unused", llm.URL), `{"question":"What is merino?"}`)
	if rec.Code != http.StatusOK || prompt != "What is merino?" {
		t.Fatalf("got %d prompt=%q", rec.Code, prompt)
	}
}

func TestValidationAndErrors(t *testing.T) {
	var prompt string
	llm := fakeLLM(t, "test-key", &prompt)
	defer llm.Close()
	cat := fakeCatalog()
	defer cat.Close()
	a := newTestAssistant(cat.URL, llm.URL)

	cases := map[string]struct {
		body string
		want int
	}{
		"bad json":       {`{`, http.StatusBadRequest},
		"empty question": {`{"question":"  "}`, http.StatusBadRequest},
		"too long":       {`{"question":"` + strings.Repeat("a", 1001) + `"}`, http.StatusBadRequest},
		"unknown item":   {`{"question":"hi","item_id":"nope"}`, http.StatusNotFound},
	}
	for name, tc := range cases {
		if rec := post(a, tc.body); rec.Code != tc.want {
			t.Errorf("%s: got %d, want %d", name, rec.Code, tc.want)
		}
	}

	a.llmAPIKey = "wrong"
	if rec := post(a, `{"question":"hi"}`); rec.Code != http.StatusBadGateway {
		t.Errorf("llm auth failure: got %d, want 502", rec.Code)
	}
}
