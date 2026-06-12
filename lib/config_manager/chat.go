package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// ChatMessage is a single turn in a conversation.
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest is the body sent to POST /api/chat.
type ChatRequest struct {
	Messages []ChatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
}

// openAIRequest is the body forwarded to llama-server's OpenAI endpoint.
type openAIRequest struct {
	Model    string        `json:"model"`
	Messages []ChatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
}

// openAIDelta is a single streamed token from the server.
type openAIDelta struct {
	Choices []struct {
		Delta struct {
			Content      string `json:"content"`
			ReasoningContent string `json:"reasoning_content"`
		} `json:"delta"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
}

// streamChat proxies a streaming chat request to llama-server and writes
// SSE events to the ResponseWriter.
func streamChat(w http.ResponseWriter, msgs []ChatMessage) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		fmt.Fprintf(w, "data: {\"error\":\"SSE not supported\"}\n\n")
		return
	}

	gs := loadGasketState()
	port := gs.Port
	if port == "" {
		port = "8080"
	}
	serverURL := fmt.Sprintf("http://127.0.0.1:%s/v1/chat/completions", port)

	body, _ := json.Marshal(openAIRequest{
		Model:    "local",
		Messages: msgs,
		Stream:   true,
	})

	resp, err := http.Post(serverURL, "application/json", bytes.NewReader(body))
	if err != nil {
		fmt.Fprintf(w, "data: {\"error\":\"cannot reach llama-server at port %s\"}\n\n", port)
		flusher.Flush()
		return
	}
	defer resp.Body.Close()

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := strings.TrimPrefix(line, "data: ")
		if payload == "[DONE]" {
			fmt.Fprintf(w, "data: [DONE]\n\n")
			flusher.Flush()
			break
		}
		var delta openAIDelta
		if err := json.Unmarshal([]byte(payload), &delta); err != nil {
			continue
		}
		if len(delta.Choices) == 0 {
			continue
		}
		token := delta.Choices[0].Delta.Content
		thinking := delta.Choices[0].Delta.ReasoningContent
		if token == "" && thinking == "" {
			if delta.Choices[0].FinishReason != "" {
				fmt.Fprintf(w, "data: [DONE]\n\n")
				flusher.Flush()
			}
			continue
		}
		out, _ := json.Marshal(map[string]string{
			"token":   token,
			"think":   thinking,
			"role":    "assistant",
		})
		fmt.Fprintf(w, "data: %s\n\n", out)
		flusher.Flush()
	}
}

// fetchModels queries /v1/models from the running llama-server.
func fetchServerModels() ([]string, error) {
	gs := loadGasketState()
	port := gs.Port
	if port == "" {
		port = "8080"
	}
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%s/v1/models", port))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var result struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	body, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}
	var ids []string
	for _, m := range result.Data {
		ids = append(ids, m.ID)
	}
	return ids, nil
}
