package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Handler holds shared dependencies for all HTTP handlers.
type Handler struct{ store *Store }

// ── wire helpers ──────────────────────────────────────────────────────────────

func wire(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func errJSON(w http.ResponseWriter, code int, msg string) {
	wire(w, code, map[string]string{"error": msg})
}

// ── Config CRUD ───────────────────────────────────────────────────────────────

func (h *Handler) listFiles(w http.ResponseWriter, r *http.Request) {
	names, err := h.store.List()
	if err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	if names == nil {
		names = []string{}
	}
	wire(w, 200, names)
}

func (h *Handler) getFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	f, err := h.store.Read(name)
	if err != nil {
		errJSON(w, 404, "not found: "+name)
		return
	}
	wire(w, 200, f)
}

func (h *Handler) createFile(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name     string `json:"name"`
		Template string `json:"template"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	name := sanitiseName(req.Name)
	if name == "" {
		errJSON(w, 400, "invalid name")
		return
	}
	if h.store.Exists(name) {
		errJSON(w, 409, "already exists")
		return
	}
	f := templateFile(name, req.Template)
	if err := h.store.Write(name, f); err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	wire(w, 201, map[string]string{"name": name})
}

func (h *Handler) updateFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	var f IniFile
	if json.NewDecoder(r.Body).Decode(&f) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	f.Name = name
	if err := h.store.Write(name, f); err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	wire(w, 200, map[string]string{"name": name})
}

func (h *Handler) deleteFile(w http.ResponseWriter, r *http.Request) {
	if err := h.store.Delete(r.PathValue("name")); err != nil {
		errJSON(w, 404, "not found")
		return
	}
	wire(w, 200, map[string]string{"deleted": r.PathValue("name")})
}

// ── Models ────────────────────────────────────────────────────────────────────

func (h *Handler) listModels(w http.ResponseWriter, r *http.Request) {
	cfg := loadPaths()
	models := scanModels(cfg.ModelSearchDirs)
	if models == nil {
		models = []ModelInfo{}
	}
	wire(w, 200, models)
}

func (h *Handler) listBinaries(w http.ResponseWriter, r *http.Request) {
	cfg := loadPaths()
	bins := scanBinaries(cfg.BinarySearchDirs)
	if bins == nil {
		bins = []BinaryInfo{}
	}
	wire(w, 200, bins)
}

// ── Paths ─────────────────────────────────────────────────────────────────────

func (h *Handler) getPaths(w http.ResponseWriter, r *http.Request) {
	wire(w, 200, loadPaths())
}

func (h *Handler) putPaths(w http.ResponseWriter, r *http.Request) {
	var cfg PathsConfig
	if json.NewDecoder(r.Body).Decode(&cfg) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	if err := savePaths(cfg); err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	wire(w, 200, map[string]string{"saved": pathsFile()})
}

// ── Shared state ──────────────────────────────────────────────────────────────

func (h *Handler) getState(w http.ResponseWriter, r *http.Request)  { wire(w, 200, loadGasketState()) }
func (h *Handler) putState(w http.ResponseWriter, r *http.Request) {
	var st GasketState
	if json.NewDecoder(r.Body).Decode(&st) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	if err := saveGasketState(st); err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	wire(w, 200, st)
}

// ── Settings ──────────────────────────────────────────────────────────────────

func (h *Handler) getSettings(w http.ResponseWriter, r *http.Request) {
	wire(w, 200, loadGasketSettings())
}

func (h *Handler) putSettings(w http.ResponseWriter, r *http.Request) {
	var s GasketSettings
	if json.NewDecoder(r.Body).Decode(&s) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	if err := saveGasketSettings(s); err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	wire(w, 200, s)
}

// ── Arc GPU ───────────────────────────────────────────────────────────────────

func (h *Handler) arcStatus(w http.ResponseWriter, r *http.Request) {
	wire(w, 200, queryArcStatus())
}

// POST /api/arc/fix — runs arc_quick_fix via arc_check.sh
func (h *Handler) arcFix(w http.ResponseWriter, r *http.Request) {
	lib := filepath.Join(filepath.Dir(os.Args[0]), "..", "lib", "arc_check.sh")
	if _, err := os.Stat(lib); err != nil {
		// Try relative to binary for standalone use
		exe, _ := os.Executable()
		lib = filepath.Join(filepath.Dir(exe), "arc_check.sh")
	}
	if _, err := os.Stat(lib); err != nil {
		errJSON(w, 404, "arc_check.sh not found")
		return
	}
	out, err := exec.Command("bash", "-c",
		fmt.Sprintf("source '%s' && arc_quick_fix", lib)).CombinedOutput()
	wire(w, 200, map[string]string{"output": string(out), "error": errStr(err)})
}

// ── llama-server lifecycle ────────────────────────────────────────────────────

func (h *Handler) serverStatusHandler(w http.ResponseWriter, r *http.Request) {
	wire(w, 200, serverStatus())
}

func (h *Handler) serverStart(w http.ResponseWriter, r *http.Request) {
	var req ServerStartReq
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	if serverStatus().Running {
		errJSON(w, 409, "server already running")
		return
	}

	bin := req.Binary
	if bin == "" {
		bin = loadGasketState().Binary
	}
	if bin == "" {
		bin = findBinary()
	}
	if bin == "" {
		errJSON(w, 422, "no llama-server binary found — configure in Paths tab")
		return
	}

	model := req.Model
	if model == "" {
		model = loadGasketState().Model
	}
	if model == "" {
		errJSON(w, 422, "no model selected — pick one in the Models tab")
		return
	}

	args := []string{"--model", model}
	if req.Config != "" {
		if f, err := h.store.Read(req.Config); err == nil {
			args = append(args, iniToArgs(f)...)
		}
	}

	port := req.Port
	if port == "" {
		port = loadGasketState().Port
	}
	if port == "" {
		port = "8080"
	}
	hasPort := false
	for _, a := range args {
		if a == "--port" {
			hasPort = true
			break
		}
	}
	if !hasPort {
		args = append(args, "--port", port)
	}
	if req.Extra != "" {
		for _, p := range strings.Fields(req.Extra) {
			args = append(args, p)
		}
	}

	logF, err := os.OpenFile(serverLogFile(),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		errJSON(w, 500, "cannot open log: "+err.Error())
		return
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdout, cmd.Stderr = logF, logF
	if err := cmd.Start(); err != nil {
		logF.Close()
		errJSON(w, 500, "start failed: "+err.Error())
		return
	}
	logF.Close()

	os.WriteFile(serverPIDFile(), []byte(strconv.Itoa(cmd.Process.Pid)), 0644)
	gs := loadGasketState()
	gs.Model, gs.Config, gs.Port = model, req.Config, port
	saveGasketState(gs)

	wire(w, 200, map[string]any{"pid": cmd.Process.Pid, "port": port, "log": serverLogFile()})
}

func (h *Handler) serverStop(w http.ResponseWriter, r *http.Request) {
	st := serverStatus()
	if !st.Running {
		errJSON(w, 409, "not running")
		return
	}
	proc, err := os.FindProcess(st.PID)
	if err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	proc.Signal(os.Interrupt)
	time.Sleep(500 * time.Millisecond)
	os.Remove(serverPIDFile())
	wire(w, 200, map[string]string{"stopped": strconv.Itoa(st.PID)})
}

func (h *Handler) serverLog(w http.ResponseWriter, r *http.Request) {
	n := 100
	if v := r.URL.Query().Get("n"); v != "" {
		if i, err := strconv.Atoi(v); err == nil && i > 0 {
			n = i
		}
	}
	lines := tailLog(serverLogFile(), n)
	wire(w, 200, map[string]any{"lines": lines, "file": serverLogFile()})
}

// ── Chat ──────────────────────────────────────────────────────────────────────

func (h *Handler) chatStream(w http.ResponseWriter, r *http.Request) {
	var req ChatRequest
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	streamChat(w, req.Messages)
}

func (h *Handler) chatModels(w http.ResponseWriter, r *http.Request) {
	ids, err := fetchServerModels()
	if err != nil {
		wire(w, 200, map[string]any{"models": []string{}, "error": err.Error()})
		return
	}
	wire(w, 200, map[string]any{"models": ids})
}

// ── Build ─────────────────────────────────────────────────────────────────────

func (h *Handler) buildStart(w http.ResponseWriter, r *http.Request) {
	var cfg BuildConfig
	if json.NewDecoder(r.Body).Decode(&cfg) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	if cfg.SourceDir == "" {
		home, _ := os.UserHomeDir()
		cfg.SourceDir = filepath.Join(home, "ai_stack", "llama.cpp")
	}
	streamBuild(w, cfg)
}

func (h *Handler) buildStatusHandler(w http.ResponseWriter, r *http.Request) {
	wire(w, 200, buildStatus())
}

// ── Logs ──────────────────────────────────────────────────────────────────────

func (h *Handler) logTail(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	logs := knownLogs()
	path, ok := logs[name]
	if !ok {
		errJSON(w, 404, "unknown log: "+name)
		return
	}
	n := 200
	if v := r.URL.Query().Get("n"); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			n = i
		}
	}
	lines := tailLog(path, n)
	wire(w, 200, map[string]any{"lines": lines, "file": path})
}

func (h *Handler) logStream(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	logs := knownLogs()
	path, ok := logs[name]
	if !ok {
		http.Error(w, "unknown log", 404)
		return
	}
	streamLog(w, r, path)
}

func (h *Handler) logClear(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	logs := knownLogs()
	path, ok := logs[name]
	if !ok {
		errJSON(w, 404, "unknown log")
		return
	}
	os.WriteFile(path, []byte{}, 0644)
	wire(w, 200, map[string]string{"cleared": path})
}

// ── Downloads ─────────────────────────────────────────────────────────────────

func (h *Handler) downloadStart(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL     string `json:"url"`
		DestDir string `json:"dest_dir"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	job, err := startDownload(req.URL, req.DestDir)
	if err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	wire(w, 200, job)
}

func (h *Handler) downloadStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	dlMu.RLock()
	job := dlJobs[id]
	dlMu.RUnlock()
	if job == nil {
		errJSON(w, 404, "job not found")
		return
	}
	wire(w, 200, job)
}

func (h *Handler) downloadStream(w http.ResponseWriter, r *http.Request) {
	sseDownloadProgress(w, r, r.PathValue("id"))
}

func (h *Handler) listDownloads(w http.ResponseWriter, r *http.Request) {
	dlMu.RLock()
	defer dlMu.RUnlock()
	jobs := make([]*DownloadJob, 0, len(dlJobs))
	for _, j := range dlJobs {
		jobs = append(jobs, j)
	}
	wire(w, 200, jobs)
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func errStr(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
