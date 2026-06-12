package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// DownloadJob tracks an active or completed file download.
type DownloadJob struct {
	ID       string  `json:"id"`
	URL      string  `json:"url"`
	Filename string  `json:"filename"`
	DestDir  string  `json:"dest_dir"`
	Total    int64   `json:"total"`
	Done     int64   `json:"done"`
	Pct      float64 `json:"pct"`
	Status   string  `json:"status"` // pending | downloading | done | error
	Error    string  `json:"error,omitempty"`
}

var (
	dlMu   sync.RWMutex
	dlJobs = map[string]*DownloadJob{}
	dlSeq  int
)

// resolveHFURL converts HuggingFace /blob/ URLs to the downloadable /resolve/ form.
func resolveHFURL(url string) string {
	return strings.Replace(url, "/blob/", "/resolve/", 1)
}

// startDownload kicks off an async download and returns the job.
func startDownload(rawURL, destDir string) (*DownloadJob, error) {
	if destDir == "" {
		cfg := loadPaths()
		if len(cfg.ModelSearchDirs) > 0 {
			destDir = expandHome(cfg.ModelSearchDirs[0])
		}
	}
	if err := os.MkdirAll(destDir, 0755); err != nil {
		return nil, err
	}

	url := resolveHFURL(rawURL)

	// Derive filename from URL tail
	parts := strings.Split(strings.TrimRight(url, "/"), "/")
	filename := parts[len(parts)-1]
	if filename == "" || !strings.Contains(filename, ".") {
		filename = "model.gguf"
	}

	dlMu.Lock()
	dlSeq++
	id := fmt.Sprintf("dl%d", dlSeq)
	job := &DownloadJob{
		ID: id, URL: url, Filename: filename,
		DestDir: destDir, Status: "pending",
	}
	dlJobs[id] = job
	dlMu.Unlock()

	go runDownload(job)
	return job, nil
}

func runDownload(job *DownloadJob) {
	job.Status = "downloading"
	destPath := filepath.Join(job.DestDir, job.Filename)

	resp, err := http.Get(job.URL)
	if err != nil {
		job.Status = "error"
		job.Error = err.Error()
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		job.Status = "error"
		job.Error = fmt.Sprintf("HTTP %d from server", resp.StatusCode)
		return
	}

	job.Total = resp.ContentLength
	f, err := os.Create(destPath)
	if err != nil {
		job.Status = "error"
		job.Error = err.Error()
		return
	}
	defer f.Close()

	buf := make([]byte, 32*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			f.Write(buf[:n])
			job.Done += int64(n)
			if job.Total > 0 {
				job.Pct = float64(job.Done) / float64(job.Total) * 100
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			job.Status = "error"
			job.Error = err.Error()
			return
		}
	}
	job.Status = "done"
	job.Pct = 100
}

// sseDownloadProgress streams job progress as SSE events until done or
// the client disconnects. Uses request context for clean cancellation.
func sseDownloadProgress(w http.ResponseWriter, r *http.Request, id string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		return
	}

	ctx := r.Context()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			dlMu.RLock()
			job := dlJobs[id]
			dlMu.RUnlock()

			if job == nil {
				fmt.Fprintf(w, "event: error\ndata: job not found\n\n")
				flusher.Flush()
				return
			}
			out, _ := json.Marshal(job)
			fmt.Fprintf(w, "event: progress\ndata: %s\n\n", out)
			flusher.Flush()

			if job.Status == "done" || job.Status == "error" {
				return
			}
		}
	}
}
