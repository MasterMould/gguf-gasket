package main

import (
	"bufio"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// knownLogs maps URL-safe names to absolute log file paths.
func knownLogs() map[string]string {
	home, _ := os.UserHomeDir()
	ai := filepath.Join(home, "ai_stack")
	return map[string]string{
		"server": filepath.Join(ai, "server.log"),
		"build":  filepath.Join(ai, "build.log"),
		"arc":    filepath.Join(ai, "arc_fix.log"),
		"gasket": filepath.Join(ai, "llama_manager.log"),
	}
}

// tailLog returns the last n lines of a file.
func tailLog(path string, n int) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}

// streamLog tails a file and forwards new lines as SSE events.
// Uses request context for clean cancellation when the client disconnects.
func streamLog(w http.ResponseWriter, r *http.Request, path string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", 500)
		return
	}

	// Send last 80 lines as backlog
	for _, line := range tailLog(path, 80) {
		fmt.Fprintf(w, "event: line\ndata: %s\n\n", escSSE(line))
	}
	flusher.Flush()

	// Track file size to detect new content
	info, _ := os.Stat(path)
	var lastSize int64
	if info != nil {
		lastSize = info.Size()
	}

	ticker := time.NewTicker(500 * time.Millisecond)
	kaTimer := time.NewTicker(5 * time.Second) // keepalive
	defer ticker.Stop()
	defer kaTimer.Stop()
	ctx := r.Context()

	for {
		select {
		case <-ctx.Done():
			return
		case <-kaTimer.C:
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		case <-ticker.C:
			info, err := os.Stat(path)
			if err != nil || info.Size() == lastSize {
				continue
			}
			f, err := os.Open(path)
			if err != nil {
				continue
			}
			f.Seek(lastSize, 0)
			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				fmt.Fprintf(w, "event: line\ndata: %s\n\n", escSSE(scanner.Text()))
			}
			lastSize = info.Size()
			f.Close()
			flusher.Flush()
		}
	}
}

func escSSE(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r", ""), "\n", " ")
}
