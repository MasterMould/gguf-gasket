package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ─── Data Structures ────────────────────────────────────────────────────────

// IniSection represents a named section in an INI file.
type IniSection struct {
	Name   string
	Keys   []IniKey
}

// IniKey is a single key=value pair (with optional inline comment).
type IniKey struct {
	Key     string
	Value   string
	Comment string // inline comment after value
}

// IniFile is the full in-memory representation of a .ini file.
type IniFile struct {
	Name     string       // filename without path
	Sections []IniSection // ordered sections; section "" = top-level (no heading)
}

// ─── INI Parser ─────────────────────────────────────────────────────────────

func parseINI(data string) IniFile {
	file := IniFile{}
	current := IniSection{Name: ""}

	for _, raw := range strings.Split(data, "\n") {
		line := strings.TrimSpace(raw)

		// blank line or comment-only line
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		// section header
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			file.Sections = append(file.Sections, current)
			current = IniSection{Name: line[1 : len(line)-1]}
			continue
		}
		// key = value
		if idx := strings.IndexRune(line, '='); idx > 0 {
			k := strings.TrimSpace(line[:idx])
			rest := strings.TrimSpace(line[idx+1:])
			val, comment := splitComment(rest)
			current.Keys = append(current.Keys, IniKey{Key: k, Value: val, Comment: comment})
		}
	}
	file.Sections = append(file.Sections, current)
	return file
}

// splitComment splits "value  # comment" → ("value", "comment").
// The separator itself (space + # or ;) is consumed.
func splitComment(s string) (string, string) {
	for _, sep := range []string{" #", "\t#", " ;"} {
		if i := strings.Index(s, sep); i >= 0 {
			return strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+len(sep):])
		}
	}
	return strings.TrimSpace(s), ""
}

// ─── INI Serialiser ─────────────────────────────────────────────────────────

func serialiseINI(f IniFile) string {
	var b strings.Builder
	for i, sec := range f.Sections {
		if len(sec.Keys) == 0 {
			continue
		}
		if sec.Name != "" {
			if i > 0 {
				b.WriteString("\n")
			}
			fmt.Fprintf(&b, "[%s]\n", sec.Name)
		}
		for _, kv := range sec.Keys {
			if kv.Comment != "" {
				fmt.Fprintf(&b, "%s = %s  # %s\n", kv.Key, kv.Value, kv.Comment)
			} else {
				fmt.Fprintf(&b, "%s = %s\n", kv.Key, kv.Value)
			}
		}
	}
	return b.String()
}

// ─── File Store ─────────────────────────────────────────────────────────────

type Store struct {
	dir string
}

func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

func (s *Store) List() ([]string, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".ini") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

func (s *Store) Read(name string) (IniFile, error) {
	data, err := os.ReadFile(s.path(name))
	if err != nil {
		return IniFile{}, err
	}
	f := parseINI(string(data))
	f.Name = name
	return f, nil
}

func (s *Store) Write(name string, f IniFile) error {
	return os.WriteFile(s.path(name), []byte(serialiseINI(f)), 0644)
}

func (s *Store) Delete(name string) error {
	return os.Remove(s.path(name))
}

func (s *Store) Exists(name string) bool {
	_, err := os.Stat(s.path(name))
	return err == nil
}

func (s *Store) path(name string) string {
	return filepath.Join(s.dir, filepath.Base(name))
}

// ─── HTTP Handlers ──────────────────────────────────────────────────────────

type Handler struct {
	store *Store
	tmpl  *template.Template
}

// wire returns JSON; any error becomes {"error": "…"}.
func wire(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func errJSON(w http.ResponseWriter, code int, msg string) {
	wire(w, code, map[string]string{"error": msg})
}

// GET /api/files  → list filenames
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

// GET /api/files/{name}  → IniFile JSON
func (h *Handler) getFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	f, err := h.store.Read(name)
	if err != nil {
		errJSON(w, 404, "file not found: "+name)
		return
	}
	wire(w, 200, f)
}

// POST /api/files  → create; body = { "name": "...", "template": "..." }
func (h *Handler) createFile(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name     string `json:"name"`
		Template string `json:"template"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		errJSON(w, 400, "bad JSON")
		return
	}
	name := sanitiseName(req.Name)
	if name == "" {
		errJSON(w, 400, "invalid file name")
		return
	}
	if h.store.Exists(name) {
		errJSON(w, 409, "file already exists")
		return
	}
	f := templateFile(name, req.Template)
	if err := h.store.Write(name, f); err != nil {
		errJSON(w, 500, err.Error())
		return
	}
	wire(w, 201, map[string]string{"name": name})
}

// PUT /api/files/{name}  → replace entire file; body = IniFile JSON
func (h *Handler) updateFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	var f IniFile
	if err := json.NewDecoder(r.Body).Decode(&f); err != nil {
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

// DELETE /api/files/{name}
func (h *Handler) deleteFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if err := h.store.Delete(name); err != nil {
		errJSON(w, 404, "file not found: "+name)
		return
	}
	wire(w, 200, map[string]string{"deleted": name})
}

// GET / → serve the SPA
func (h *Handler) index(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	h.tmpl.Execute(w, nil)
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

func sanitiseName(s string) string {
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, " ", "-")
	// strip anything that's not alphanumeric, dash, underscore, dot
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
			b.WriteRune(r)
		}
	}
	name := b.String()
	if !strings.HasSuffix(name, ".ini") {
		name += ".ini"
	}
	return name
}

// templateFile returns a pre-filled IniFile for the given template name.
func templateFile(name, tmpl string) IniFile {
	switch tmpl {
	case "server":
		return IniFile{Name: name, Sections: []IniSection{
			{Name: "", Keys: []IniKey{
				{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
				{Key: "host", Value: "127.0.0.1", Comment: "listen address"},
				{Key: "port", Value: "8080", Comment: "listen port"},
				{Key: "ctx-size", Value: "4096", Comment: "context window tokens"},
				{Key: "n-gpu-layers", Value: "0", Comment: "layers offloaded to GPU (0 = CPU only)"},
				{Key: "threads", Value: "4", Comment: "CPU threads"},
				{Key: "batch-size", Value: "512", Comment: "prompt batch size"},
			}},
		}}
	case "chat":
		return IniFile{Name: name, Sections: []IniSection{
			{Name: "", Keys: []IniKey{
				{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
				{Key: "ctx-size", Value: "4096", Comment: "context window tokens"},
				{Key: "n-gpu-layers", Value: "0", Comment: "layers offloaded to GPU"},
				{Key: "threads", Value: "4", Comment: "CPU threads"},
				{Key: "temperature", Value: "0.8", Comment: "sampling temperature"},
				{Key: "top-p", Value: "0.9", Comment: "nucleus sampling threshold"},
				{Key: "top-k", Value: "40", Comment: "top-k sampling"},
				{Key: "repeat-penalty", Value: "1.1", Comment: "repeat penalty"},
				{Key: "n-predict", Value: "-1", Comment: "max tokens to generate (-1 = unlimited)"},
				{Key: "seed", Value: "-1", Comment: "RNG seed (-1 = random)"},
			}},
		}}
	case "embedding":
		return IniFile{Name: name, Sections: []IniSection{
			{Name: "", Keys: []IniKey{
				{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
				{Key: "ctx-size", Value: "2048", Comment: "context window tokens"},
				{Key: "n-gpu-layers", Value: "0", Comment: "layers offloaded to GPU"},
				{Key: "threads", Value: "4", Comment: "CPU threads"},
				{Key: "embedding", Value: "true", Comment: "enable embedding mode"},
				{Key: "batch-size", Value: "512", Comment: "batch size"},
			}},
		}}
	default: // blank
		return IniFile{Name: name, Sections: []IniSection{
			{Name: "", Keys: []IniKey{
				{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
			}},
		}}
	}
}

// ─── Parameter metadata (for the UI) ────────────────────────────────────────

type ParamMeta struct {
	Key         string
	Label       string
	Description string
	Type        string // text | number | bool | path
	Min         string
	Max         string
	Step        string
}

var knownParams = []ParamMeta{
	// Model
	{Key: "model", Label: "Model Path", Description: "Path to the .gguf model file", Type: "path"},
	// Context
	{Key: "ctx-size", Label: "Context Size", Description: "Number of tokens in the context window. Larger = more memory.", Type: "number", Min: "128", Max: "131072", Step: "128"},
	{Key: "batch-size", Label: "Batch Size", Description: "Prompt processing batch size. Affects speed.", Type: "number", Min: "1", Max: "4096", Step: "1"},
	// GPU
	{Key: "n-gpu-layers", Label: "GPU Layers", Description: "Number of model layers to offload to GPU. 0 = CPU only. -1 = all layers.", Type: "number", Min: "-1", Max: "200", Step: "1"},
	{Key: "main-gpu", Label: "Main GPU", Description: "GPU index to use as the primary GPU", Type: "number", Min: "0", Max: "16", Step: "1"},
	// CPU
	{Key: "threads", Label: "CPU Threads", Description: "Number of threads for generation", Type: "number", Min: "1", Max: "256", Step: "1"},
	{Key: "threads-batch", Label: "Batch Threads", Description: "Threads used for prompt evaluation", Type: "number", Min: "1", Max: "256", Step: "1"},
	// Sampling
	{Key: "temperature", Label: "Temperature", Description: "Controls randomness. Lower = more focused; higher = more creative.", Type: "number", Min: "0.0", Max: "2.0", Step: "0.01"},
	{Key: "top-p", Label: "Top-P", Description: "Nucleus sampling. Keeps tokens whose cumulative probability reaches this value.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "top-k", Label: "Top-K", Description: "Limits sampling to the K most likely tokens.", Type: "number", Min: "0", Max: "200", Step: "1"},
	{Key: "min-p", Label: "Min-P", Description: "Minimum probability threshold relative to the most likely token.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "repeat-penalty", Label: "Repeat Penalty", Description: "Penalises repetition. 1.0 = no penalty.", Type: "number", Min: "1.0", Max: "2.0", Step: "0.01"},
	{Key: "repeat-last-n", Label: "Repeat Last N", Description: "Tokens to look back for repeat penalty. 0 = disabled.", Type: "number", Min: "0", Max: "512", Step: "1"},
	{Key: "tfs-z", Label: "TFS Z", Description: "Tail free sampling parameter. 1.0 = disabled.", Type: "number", Min: "1.0", Max: "2.0", Step: "0.01"},
	{Key: "typical-p", Label: "Typical-P", Description: "Locally typical sampling. 1.0 = disabled.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "mirostat", Label: "Mirostat Mode", Description: "0 = disabled, 1 = Mirostat v1, 2 = Mirostat v2", Type: "number", Min: "0", Max: "2", Step: "1"},
	{Key: "mirostat-lr", Label: "Mirostat LR", Description: "Mirostat learning rate (eta)", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "mirostat-ent", Label: "Mirostat Entropy", Description: "Mirostat target entropy (tau)", Type: "number", Min: "0.0", Max: "10.0", Step: "0.1"},
	// Generation
	{Key: "n-predict", Label: "Max Tokens", Description: "Maximum tokens to generate. -1 = unlimited.", Type: "number", Min: "-1", Max: "32768", Step: "1"},
	{Key: "seed", Label: "Seed", Description: "RNG seed. -1 = random.", Type: "number", Min: "-1", Max: "2147483647", Step: "1"},
	// Server
	{Key: "host", Label: "Host", Description: "Server bind address", Type: "text"},
	{Key: "port", Label: "Port", Description: "Server port number", Type: "number", Min: "1", Max: "65535", Step: "1"},
	{Key: "timeout", Label: "Timeout (s)", Description: "Server request timeout in seconds", Type: "number", Min: "1", Max: "600", Step: "1"},
	{Key: "parallel", Label: "Parallel Slots", Description: "Number of parallel request slots", Type: "number", Min: "1", Max: "64", Step: "1"},
	{Key: "cont-batching", Label: "Continuous Batching", Description: "Enable continuous batching for throughput", Type: "bool"},
	// Features
	{Key: "embedding", Label: "Embedding Mode", Description: "Enable embedding endpoint", Type: "bool"},
	{Key: "flash-attn", Label: "Flash Attention", Description: "Enable Flash Attention (requires compatible build)", Type: "bool"},
	{Key: "no-mmap", Label: "No Memory Map", Description: "Disable memory-mapped model loading", Type: "bool"},
	{Key: "mlock", Label: "Memory Lock", Description: "Lock model in RAM (prevents swapping)", Type: "bool"},
	{Key: "numa", Label: "NUMA", Description: "Enable NUMA-aware memory allocation", Type: "bool"},
	// Logging
	{Key: "log-disable", Label: "Disable Logging", Description: "Suppress log output", Type: "bool"},
	{Key: "verbose", Label: "Verbose", Description: "Enable verbose output", Type: "bool"},
}

func paramMetaJSON() template.JS {
	b, _ := json.Marshal(knownParams)
	return template.JS(b)
}

// ─── Entrypoint ──────────────────────────────────────────────────────────────

func main() {
	dir := "configs"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	port := "7070"
	if len(os.Args) > 2 {
		if _, err := strconv.Atoi(os.Args[2]); err == nil {
			port = os.Args[2]
		}
	}

	store, err := NewStore(dir)
	if err != nil {
		log.Fatalf("cannot open config dir %q: %v", dir, err)
	}

	tmpl := template.Must(template.New("app").Funcs(template.FuncMap{
		"paramMetaJSON": paramMetaJSON,
	}).Parse(htmlTemplate))

	h := &Handler{store: store, tmpl: tmpl}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", h.index)
	mux.HandleFunc("GET /api/files", h.listFiles)
	mux.HandleFunc("GET /api/files/{name}", h.getFile)
	mux.HandleFunc("POST /api/files", h.createFile)
	mux.HandleFunc("PUT /api/files/{name}", h.updateFile)
	mux.HandleFunc("DELETE /api/files/{name}", h.deleteFile)

	addr := ":" + port
	fmt.Printf("llama.cpp config manager  →  http://localhost%s\n", addr)
	fmt.Printf("configs directory         →  %s\n", dir)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// ─── Embedded HTML/CSS/JS ────────────────────────────────────────────────────

const htmlTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>llama.cpp Config Manager</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Syne:wght@400;600;700;800&display=swap" rel="stylesheet">
<style>
:root {
  --bg:         #0d0f14;
  --bg2:        #13161e;
  --bg3:        #1a1e28;
  --border:     #252936;
  --border2:    #2e3347;
  --accent:     #c9f55a;
  --accent2:    #4ef0c0;
  --accent3:    #f5a623;
  --text:       #e2e6f0;
  --text2:      #8a92a8;
  --text3:      #555f7a;
  --danger:     #ff5f6d;
  --mono:       'IBM Plex Mono', monospace;
  --sans:       'Syne', sans-serif;
  --radius:     6px;
  --shadow:     0 4px 24px rgba(0,0,0,.5);
}

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
html, body { height: 100%; overflow: hidden; }
body { background: var(--bg); color: var(--text); font-family: var(--mono); font-size: 13px; display: flex; flex-direction: column; }

/* ── scrollbars ── */
::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border2); border-radius: 3px; }

/* ── top bar ── */
header {
  height: 52px; min-height: 52px;
  display: flex; align-items: center; gap: 14px;
  padding: 0 20px;
  border-bottom: 1px solid var(--border);
  background: var(--bg2);
  position: relative; z-index: 10;
}
.logo {
  font-family: var(--sans); font-weight: 800; font-size: 17px;
  letter-spacing: -.3px; color: var(--accent);
  display: flex; align-items: center; gap: 8px;
}
.logo-badge {
  background: var(--accent); color: var(--bg); font-size: 9px;
  font-weight: 700; padding: 2px 5px; border-radius: 3px; letter-spacing: .5px;
}
.header-right {
  margin-left: auto; display: flex; align-items: center; gap: 10px;
}
.dir-badge {
  font-size: 11px; color: var(--text3); background: var(--bg3);
  border: 1px solid var(--border); border-radius: 4px; padding: 3px 8px;
}

/* ── layout ── */
.workspace {
  display: flex; flex: 1; overflow: hidden;
}

/* ── sidebar ── */
aside {
  width: 240px; min-width: 240px;
  border-right: 1px solid var(--border);
  background: var(--bg2);
  display: flex; flex-direction: column;
  overflow: hidden;
}
.sidebar-head {
  padding: 14px 14px 10px;
  border-bottom: 1px solid var(--border);
  display: flex; align-items: center; gap: 6px;
}
.sidebar-head h2 {
  font-family: var(--sans); font-size: 11px; font-weight: 700;
  text-transform: uppercase; letter-spacing: 1.5px; color: var(--text2);
  flex: 1;
}
.btn-new {
  background: var(--accent); color: var(--bg);
  border: none; border-radius: var(--radius);
  font-family: var(--mono); font-size: 12px; font-weight: 600;
  padding: 4px 10px; cursor: pointer;
  transition: opacity .15s;
}
.btn-new:hover { opacity: .85; }

.file-list { flex: 1; overflow-y: auto; padding: 6px 0; }
.file-item {
  display: flex; align-items: center;
  padding: 8px 14px 8px 16px;
  cursor: pointer;
  border-left: 3px solid transparent;
  transition: background .12s, border-color .12s;
  gap: 6px; position: relative;
}
.file-item:hover { background: var(--bg3); }
.file-item.active {
  background: var(--bg3); border-left-color: var(--accent);
  color: var(--accent);
}
.file-name {
  flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  font-size: 12px;
}
.file-ext { color: var(--text3); font-size: 10px; }
.btn-del {
  background: none; border: none; color: var(--text3); cursor: pointer;
  font-size: 14px; line-height: 1; padding: 0 2px; opacity: 0;
  transition: opacity .12s, color .12s;
}
.file-item:hover .btn-del { opacity: 1; }
.btn-del:hover { color: var(--danger); }

.sidebar-empty {
  padding: 24px 14px; color: var(--text3); font-size: 11px; line-height: 1.7;
  text-align: center;
}

/* ── main panel ── */
main {
  flex: 1; display: flex; flex-direction: column; overflow: hidden;
}

/* ── empty state ── */
.empty-state {
  flex: 1; display: flex; flex-direction: column;
  align-items: center; justify-content: center; gap: 16px;
  color: var(--text3);
}
.empty-icon {
  font-size: 48px; opacity: .3;
}
.empty-state h3 { font-family: var(--sans); font-size: 18px; color: var(--text2); }
.empty-state p { font-size: 12px; line-height: 1.7; text-align: center; max-width: 300px; }

/* ── editor area ── */
.editor { flex: 1; display: flex; flex-direction: column; overflow: hidden; }

.editor-topbar {
  display: flex; align-items: center; gap: 10px;
  padding: 10px 20px;
  border-bottom: 1px solid var(--border);
  background: var(--bg2);
}
.file-title {
  font-family: var(--sans); font-size: 15px; font-weight: 700;
  flex: 1; color: var(--text);
}
.file-title span { color: var(--text3); font-weight: 400; }

.tab-bar {
  display: flex; gap: 0;
  border-bottom: 1px solid var(--border);
  background: var(--bg2); padding: 0 20px;
}
.tab {
  padding: 9px 18px; font-size: 11px; font-weight: 600;
  letter-spacing: .6px; text-transform: uppercase; cursor: pointer;
  border-bottom: 2px solid transparent; color: var(--text3);
  transition: color .12s, border-color .12s;
}
.tab:hover { color: var(--text); }
.tab.active { color: var(--accent); border-bottom-color: var(--accent); }

.editor-body { flex: 1; overflow-y: auto; padding: 24px 28px; }

/* ── form editor ── */
.section-block {
  margin-bottom: 28px;
  background: var(--bg2);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow: hidden;
}
.section-header {
  display: flex; align-items: center; justify-content: space-between;
  padding: 8px 14px;
  background: var(--bg3);
  border-bottom: 1px solid var(--border);
  font-size: 11px; font-weight: 600; letter-spacing: 1px;
  text-transform: uppercase; color: var(--text2);
}
.section-header .section-label { color: var(--accent2); }
.section-name-input {
  background: var(--bg); border: 1px solid var(--border);
  color: var(--text); font-family: var(--mono); font-size: 11px;
  padding: 3px 8px; border-radius: 4px;
}

.kv-row {
  display: grid;
  grid-template-columns: 220px 1fr auto;
  align-items: center; gap: 0;
  border-bottom: 1px solid var(--border);
  min-height: 44px;
  transition: background .1s;
}
.kv-row:last-child { border-bottom: none; }
.kv-row:hover { background: var(--bg3); }

.kv-key-cell {
  padding: 6px 12px; border-right: 1px solid var(--border);
  display: flex; flex-direction: column; gap: 1px;
}
.kv-key {
  font-size: 12px; color: var(--accent2); font-weight: 500;
}
.kv-desc { font-size: 10px; color: var(--text3); line-height: 1.4; }

.kv-val-cell { padding: 6px 12px; display: flex; align-items: center; gap: 8px; }
.kv-val-cell input[type=text],
.kv-val-cell input[type=number] {
  flex: 1; background: transparent; border: none;
  border-bottom: 1px solid var(--border2);
  color: var(--text); font-family: var(--mono); font-size: 12px;
  padding: 4px 2px; outline: none;
  transition: border-color .15s;
}
.kv-val-cell input:focus { border-bottom-color: var(--accent); }
.kv-toggle { display: flex; align-items: center; gap: 6px; }
.kv-toggle input[type=checkbox] { width: 14px; height: 14px; accent-color: var(--accent); cursor: pointer; }
.kv-comment { font-size: 10px; color: var(--text3); white-space: nowrap; }

.kv-actions-cell { padding: 6px 10px; display: flex; gap: 4px; }
.btn-icon {
  background: none; border: 1px solid transparent; border-radius: 4px;
  color: var(--text3); cursor: pointer; font-size: 13px;
  padding: 3px 6px; transition: all .12s;
}
.btn-icon:hover { border-color: var(--border2); color: var(--text); }
.btn-icon.danger:hover { border-color: var(--danger); color: var(--danger); }

.add-row-bar {
  padding: 6px 12px; border-top: 1px solid var(--border);
}

/* ── raw view ── */
.raw-view { padding: 0; flex: 1; }
.raw-textarea {
  width: 100%; height: 100%; min-height: 400px;
  background: var(--bg); color: var(--accent2);
  border: none; font-family: var(--mono); font-size: 12px;
  padding: 20px; outline: none; resize: vertical; line-height: 1.7;
}
.raw-note { padding: 8px 20px; font-size: 11px; color: var(--text3); background: var(--bg2); border-bottom: 1px solid var(--border); }

/* ── section + key add panel ── */
.add-panel {
  border: 1px dashed var(--border2); border-radius: var(--radius);
  padding: 10px 14px; margin-bottom: 14px;
  background: var(--bg2);
}
.add-panel h4 { font-size: 10px; text-transform: uppercase; letter-spacing: 1px; color: var(--text3); margin-bottom: 8px; }
.add-row { display: flex; gap: 8px; align-items: center; }
.add-row input, .add-row select {
  background: var(--bg3); border: 1px solid var(--border2);
  color: var(--text); font-family: var(--mono); font-size: 12px;
  padding: 5px 8px; border-radius: 4px; outline: none;
  transition: border-color .12s;
}
.add-row input:focus, .add-row select:focus { border-color: var(--accent2); }
.add-row select { min-width: 200px; }
.btn-primary {
  background: var(--accent); color: var(--bg);
  border: none; border-radius: var(--radius);
  font-family: var(--mono); font-size: 12px; font-weight: 600;
  padding: 5px 14px; cursor: pointer; white-space: nowrap;
  transition: opacity .15s;
}
.btn-primary:hover { opacity: .85; }
.btn-secondary {
  background: transparent; color: var(--text2);
  border: 1px solid var(--border2); border-radius: var(--radius);
  font-family: var(--mono); font-size: 12px;
  padding: 5px 14px; cursor: pointer;
  transition: all .12s;
}
.btn-secondary:hover { border-color: var(--accent); color: var(--accent); }

/* ── toasts ── */
#toast-area { position: fixed; bottom: 20px; right: 20px; display: flex; flex-direction: column; gap: 8px; z-index: 999; pointer-events: none; }
.toast {
  background: var(--bg3); border: 1px solid var(--border2);
  border-radius: var(--radius); padding: 10px 16px;
  font-size: 12px; color: var(--text);
  display: flex; align-items: center; gap: 8px;
  animation: slideIn .2s ease; pointer-events: none;
  box-shadow: var(--shadow);
}
.toast.ok { border-left: 3px solid var(--accent); }
.toast.err { border-left: 3px solid var(--danger); }
@keyframes slideIn { from { opacity:0; transform: translateX(20px); } to { opacity:1; transform: none; } }

/* ── modal ── */
.modal-overlay {
  position: fixed; inset: 0; background: rgba(0,0,0,.7);
  display: flex; align-items: center; justify-content: center;
  z-index: 100; backdrop-filter: blur(4px);
}
.modal {
  background: var(--bg2); border: 1px solid var(--border2);
  border-radius: 10px; padding: 28px 30px;
  width: 420px; box-shadow: var(--shadow);
}
.modal h2 { font-family: var(--sans); font-size: 17px; font-weight: 700; margin-bottom: 20px; }
.modal label { font-size: 11px; color: var(--text2); display: block; margin-bottom: 4px; text-transform: uppercase; letter-spacing: .8px; }
.modal input, .modal select {
  width: 100%; background: var(--bg); border: 1px solid var(--border2);
  color: var(--text); font-family: var(--mono); font-size: 13px;
  padding: 8px 10px; border-radius: 5px; outline: none; margin-bottom: 16px;
  transition: border-color .12s;
}
.modal input:focus, .modal select:focus { border-color: var(--accent); }
.modal-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 8px; }

.confirm-text { font-size: 13px; color: var(--text2); line-height: 1.6; margin-bottom: 20px; }
.confirm-text strong { color: var(--text); }
.btn-danger { background: var(--danger); color: #fff; border: none; border-radius: var(--radius); font-family: var(--mono); font-size: 12px; font-weight: 600; padding: 7px 16px; cursor: pointer; }
.btn-danger:hover { opacity: .85; }
</style>
</head>
<body>

<header>
  <div class="logo">
    <span>🦙 llama.cpp</span>
    <span class="logo-badge">CONFIG</span>
  </div>
  <div class="header-right">
    <span class="dir-badge" id="dir-badge">configs/</span>
  </div>
</header>

<div class="workspace">
  <aside>
    <div class="sidebar-head">
      <h2>Files</h2>
      <button class="btn-new" onclick="openNewModal()">+ New</button>
    </div>
    <div class="file-list" id="file-list"></div>
  </aside>
  <main id="main-panel">
    <div class="empty-state" id="empty-state">
      <div class="empty-icon">⚙️</div>
      <h3>No file selected</h3>
      <p>Create a new <code>.ini</code> file or select one from the sidebar to start editing.</p>
    </div>
    <div class="editor" id="editor" style="display:none">
      <div class="editor-topbar">
        <div class="file-title" id="editor-title">—</div>
        <button class="btn-secondary" onclick="saveFile()">Save</button>
      </div>
      <div class="tab-bar">
        <div class="tab active" onclick="showTab('form')">Form</div>
        <div class="tab" onclick="showTab('raw')">Raw</div>
      </div>
      <div class="editor-body" id="tab-form"></div>
      <div class="editor-body raw-view" id="tab-raw" style="display:none">
        <div class="raw-note">Editing raw .ini text. Switch to Form view to use guided fields.</div>
        <textarea class="raw-textarea" id="raw-textarea" spellcheck="false"></textarea>
      </div>
    </div>
  </main>
</div>

<div id="toast-area"></div>

<!-- New file modal -->
<div class="modal-overlay" id="new-modal" style="display:none" onclick="e=>e.target===this&&closeNewModal()">
  <div class="modal" onclick="event.stopPropagation()">
    <h2>New Config File</h2>
    <label>File Name</label>
    <input type="text" id="new-name" placeholder="e.g. server-config" />
    <label>Starter Template</label>
    <select id="new-template">
      <option value="blank">Blank</option>
      <option value="chat" selected>Chat / CLI</option>
      <option value="server">Server</option>
      <option value="embedding">Embedding</option>
    </select>
    <div class="modal-actions">
      <button class="btn-secondary" onclick="closeNewModal()">Cancel</button>
      <button class="btn-primary" onclick="createFile()">Create</button>
    </div>
  </div>
</div>

<!-- Delete confirm modal -->
<div class="modal-overlay" id="del-modal" style="display:none">
  <div class="modal" onclick="event.stopPropagation()">
    <h2>Delete File</h2>
    <p class="confirm-text">Permanently delete <strong id="del-name-label"></strong>?<br>This cannot be undone.</p>
    <div class="modal-actions">
      <button class="btn-secondary" onclick="closeDelModal()">Cancel</button>
      <button class="btn-danger" onclick="confirmDelete()">Delete</button>
    </div>
  </div>
</div>

<!-- Add key modal -->
<div class="modal-overlay" id="key-modal" style="display:none">
  <div class="modal" onclick="event.stopPropagation()">
    <h2>Add Parameter</h2>
    <label>Known Parameters</label>
    <select id="key-known" onchange="fillKnown()">
      <option value="">— pick a known param —</option>
    </select>
    <label>Key</label>
    <input type="text" id="key-new-key" placeholder="e.g. ctx-size" />
    <label>Value</label>
    <input type="text" id="key-new-val" placeholder="" />
    <div class="modal-actions">
      <button class="btn-secondary" onclick="closeKeyModal()">Cancel</button>
      <button class="btn-primary" onclick="confirmAddKey()">Add</button>
    </div>
  </div>
</div>

<script>
// ── Parameter metadata from server ──────────────────────────────────────────
const PARAM_META = {{ paramMetaJSON }};
const META_MAP = {};
PARAM_META.forEach(p => META_MAP[p.Key] = p);

// ── State ────────────────────────────────────────────────────────────────────
let files = [];        // filenames
let current = null;   // IniFile object being edited
let activeTab = 'form';
let pendingSection = 0; // which section to add a key to
let deleteTarget = null;

// ── Bootstrap ────────────────────────────────────────────────────────────────
loadFiles();

// ── API ──────────────────────────────────────────────────────────────────────
async function api(method, path, body) {
  const opts = { method, headers: {'Content-Type':'application/json'} };
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch('/api' + path, opts);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

// ── File list ────────────────────────────────────────────────────────────────
async function loadFiles() {
  files = await api('GET', '/files');
  renderSidebar();
}

function renderSidebar() {
  const el = document.getElementById('file-list');
  if (!files.length) {
    el.innerHTML = '<div class="sidebar-empty">No .ini files yet.<br>Click <b>+ New</b> to create one.</div>';
    return;
  }
  el.innerHTML = files.map(f => {
    const base = f.replace('.ini','');
    const active = current && current.Name === f ? 'active' : '';
    return ` + "`" + `
      <div class="file-item ${active}" onclick="openFile('${f}')" data-name="${f}">
        <span class="file-name">${base}<span class="file-ext">.ini</span></span>
        <button class="btn-del" title="Delete" onclick="event.stopPropagation();openDelModal('${f}')">✕</button>
      </div>
    ` + "`" + `;
  }).join('');
}

// ── Open / edit ───────────────────────────────────────────────────────────────
async function openFile(name) {
  current = await api('GET', '/files/' + name);
  document.getElementById('empty-state').style.display = 'none';
  document.getElementById('editor').style.display = 'flex';
  document.getElementById('editor-title').textContent = name;
  renderSidebar();
  renderForm();
  if (activeTab === 'raw') syncRaw();
}

function showTab(tab) {
  activeTab = tab;
  document.querySelectorAll('.tab').forEach((t,i) => t.classList.toggle('active', ['form','raw'][i]===tab));
  document.getElementById('tab-form').style.display = tab==='form' ? '' : 'none';
  document.getElementById('tab-raw').style.display  = tab==='raw'  ? '' : 'none';
  if (tab === 'raw') syncRaw();
  if (tab === 'form') { parseRaw(); renderForm(); }
}

// ── Form renderer ─────────────────────────────────────────────────────────────
function renderForm() {
  const container = document.getElementById('tab-form');
  if (!current) { container.innerHTML=''; return; }

  let html = '';
  current.Sections.forEach((sec, si) => {
    const secLabel = sec.Name ? sec.Name : '(root)';
    html += ` + "`" + `
    <div class="section-block">
      <div class="section-header">
        <span>${si===0&&!sec.Name?'<span style="color:var(--text3)">root level keys</span>'
               : '<span class="section-label">['+sec.Name+']</span>'}</span>
        <div style="display:flex;gap:6px;align-items:center">
          ${si>0 ? '<input class="section-name-input" value="'+escHtml(sec.Name)+'" oninput="renameSec('+si+',this.value)" title="Section name">' : ''}
          <button class="btn-icon" title="Add parameter" onclick="openKeyModal(${si})">＋ param</button>
          ${si>0 ? '<button class="btn-icon danger" title="Remove section" onclick="removeSec('+si+')">✕</button>' : ''}
        </div>
      </div>
    ` + "`" + `;

    if (!sec.Keys || !sec.Keys.length) {
      html += '<div style="padding:12px 14px;color:var(--text3);font-size:11px">No keys in this section.</div>';
    } else {
      sec.Keys.forEach((kv, ki) => {
        const meta = META_MAP[kv.Key];
        const desc = meta ? meta.Description : (kv.Comment || '');
        const type = meta ? meta.Type : 'text';
        let valHtml;
        if (type === 'bool') {
          const chk = (kv.Value === 'true' || kv.Value === '1') ? 'checked' : '';
          valHtml = ` + "`" + `<div class="kv-toggle"><input type="checkbox" ${chk} onchange="setVal(${si},${ki},this.checked?'true':'false')"></div>` + "`" + `;
        } else if (type === 'number') {
          const min = meta&&meta.Min ? 'min="'+meta.Min+'"' : '';
          const max = meta&&meta.Max ? 'max="'+meta.Max+'"' : '';
          const step = meta&&meta.Step ? 'step="'+meta.Step+'"' : '';
          valHtml = ` + "`" + `<input type="number" value="${escHtml(kv.Value)}" ${min} ${max} ${step} oninput="setVal(${si},${ki},this.value)">` + "`" + `;
        } else {
          valHtml = ` + "`" + `<input type="text" value="${escHtml(kv.Value)}" oninput="setVal(${si},${ki},this.value)">` + "`" + `;
        }
        html += ` + "`" + `
        <div class="kv-row">
          <div class="kv-key-cell">
            <span class="kv-key">${escHtml(kv.Key)}</span>
            ${desc ? '<span class="kv-desc">'+escHtml(desc)+'</span>' : ''}
          </div>
          <div class="kv-val-cell">${valHtml}</div>
          <div class="kv-actions-cell">
            <button class="btn-icon danger" title="Remove" onclick="removeKey(${si},${ki})">✕</button>
          </div>
        </div>
        ` + "`" + `;
      });
    }
    html += '</div>';
  });

  html += ` + "`" + `
    <div style="margin-top:6px">
      <button class="btn-secondary" onclick="addSection()">＋ Add Section</button>
    </div>
  ` + "`" + `;

  container.innerHTML = html;
}

// ── Mutations ─────────────────────────────────────────────────────────────────
function setVal(si, ki, v) { current.Sections[si].Keys[ki].Value = v; }
function renameSec(si, v) { current.Sections[si].Name = v; }

function removeKey(si, ki) {
  current.Sections[si].Keys.splice(ki, 1);
  renderForm();
}

function removeSec(si) {
  current.Sections.splice(si, 1);
  renderForm();
}

function addSection() {
  current.Sections.push({ Name: 'section', Keys: [] });
  renderForm();
}

// ── Add key modal ─────────────────────────────────────────────────────────────
function openKeyModal(si) {
  pendingSection = si;
  // populate known params dropdown
  const sel = document.getElementById('key-known');
  sel.innerHTML = '<option value="">— pick a known param —</option>'
    + PARAM_META.map(p => ` + "`" + `<option value="${p.Key}">${p.Key} — ${p.Label}</option>` + "`" + `).join('');
  document.getElementById('key-new-key').value = '';
  document.getElementById('key-new-val').value = '';
  document.getElementById('key-modal').style.display = 'flex';
}

function fillKnown() {
  const key = document.getElementById('key-known').value;
  if (!key) return;
  document.getElementById('key-new-key').value = key;
  const m = META_MAP[key];
  document.getElementById('key-new-val').value = m ? (m.Type==='bool'?'false': m.Min||'') : '';
}

function closeKeyModal() { document.getElementById('key-modal').style.display = 'none'; }

function confirmAddKey() {
  const k = document.getElementById('key-new-key').value.trim();
  const v = document.getElementById('key-new-val').value.trim();
  if (!k) { toast('Enter a key name', true); return; }
  if (!current.Sections[pendingSection].Keys) current.Sections[pendingSection].Keys = [];
  current.Sections[pendingSection].Keys.push({ Key: k, Value: v, Comment: '' });
  closeKeyModal();
  renderForm();
}

// ── Raw sync ──────────────────────────────────────────────────────────────────
function iniToString(file) {
  let out = '';
  file.Sections.forEach(sec => {
    if (!sec.Keys || !sec.Keys.length) return;
    if (sec.Name) out += '[' + sec.Name + ']\n';
    sec.Keys.forEach(kv => {
      out += kv.Key + ' = ' + kv.Value;
      if (kv.Comment) out += '  # ' + kv.Comment;
      out += '\n';
    });
    out += '\n';
  });
  return out.trim();
}

function stringToIni(text) {
  const sections = [{ Name: '', Keys: [] }];
  let cur = sections[0];
  text.split('\n').forEach(raw => {
    const line = raw.trim();
    if (!line || line.startsWith('#') || line.startsWith(';')) return;
    if (line.startsWith('[') && line.endsWith(']')) {
      cur = { Name: line.slice(1,-1), Keys: [] };
      sections.push(cur);
      return;
    }
    const eq = line.indexOf('=');
    if (eq > 0) {
      const k = line.slice(0, eq).trim();
      const rest = line.slice(eq+1).trim();
      let val = rest, comment = '';
      for (const sep of [' #', '\t#', ' ;']) {
        const i = rest.indexOf(sep);
        if (i >= 0) { val = rest.slice(0,i).trim(); comment = rest.slice(i+1).trim(); break; }
      }
      cur.Keys.push({ Key: k, Value: val, Comment: comment });
    }
  });
  return sections;
}

function syncRaw() {
  document.getElementById('raw-textarea').value = iniToString(current);
}

function parseRaw() {
  const text = document.getElementById('raw-textarea').value;
  if (text.trim()) current.Sections = stringToIni(text);
}

// ── Save ──────────────────────────────────────────────────────────────────────
async function saveFile() {
  if (!current) return;
  if (activeTab === 'raw') parseRaw();
  try {
    await api('PUT', '/files/' + current.Name, current);
    toast('Saved ' + current.Name);
  } catch(e) { toast(e.message, true); }
}

// ── New file modal ────────────────────────────────────────────────────────────
function openNewModal() {
  document.getElementById('new-name').value = '';
  document.getElementById('new-modal').style.display = 'flex';
  setTimeout(() => document.getElementById('new-name').focus(), 50);
}
function closeNewModal() { document.getElementById('new-modal').style.display = 'none'; }

document.getElementById('new-modal').addEventListener('click', e => {
  if (e.target === document.getElementById('new-modal')) closeNewModal();
});

async function createFile() {
  const name = document.getElementById('new-name').value.trim();
  const tmpl = document.getElementById('new-template').value;
  if (!name) { toast('Enter a file name', true); return; }
  try {
    const r = await api('POST', '/files', { name, template: tmpl });
    closeNewModal();
    await loadFiles();
    await openFile(r.name);
    toast('Created ' + r.name);
  } catch(e) { toast(e.message, true); }
}

// ── Delete modal ──────────────────────────────────────────────────────────────
function openDelModal(name) {
  deleteTarget = name;
  document.getElementById('del-name-label').textContent = name;
  document.getElementById('del-modal').style.display = 'flex';
}
function closeDelModal() { document.getElementById('del-modal').style.display = 'none'; deleteTarget = null; }

document.getElementById('del-modal').addEventListener('click', e => {
  if (e.target === document.getElementById('del-modal')) closeDelModal();
});

async function confirmDelete() {
  if (!deleteTarget) return;
  try {
    await api('DELETE', '/files/' + deleteTarget);
    closeDelModal();
    if (current && current.Name === deleteTarget) {
      current = null;
      document.getElementById('empty-state').style.display = '';
      document.getElementById('editor').style.display = 'none';
    }
    await loadFiles();
    toast('Deleted');
  } catch(e) { toast(e.message, true); }
}

// ── Keyboard shortcuts ────────────────────────────────────────────────────────
document.addEventListener('keydown', e => {
  if ((e.ctrlKey || e.metaKey) && e.key === 's') { e.preventDefault(); saveFile(); }
  if (e.key === 'Escape') { closeNewModal(); closeDelModal(); closeKeyModal(); }
  if ((e.ctrlKey || e.metaKey) && e.key === 'n') { e.preventDefault(); openNewModal(); }
});

// ── Enter key in new modal ────────────────────────────────────────────────────
document.getElementById('new-name').addEventListener('keydown', e => {
  if (e.key === 'Enter') createFile();
});

// ── Toast ──────────────────────────────────────────────────────────────────────
function toast(msg, err=false) {
  const el = document.createElement('div');
  el.className = 'toast ' + (err ? 'err' : 'ok');
  el.textContent = (err ? '✗ ' : '✓ ') + msg;
  document.getElementById('toast-area').appendChild(el);
  setTimeout(() => el.remove(), 3000);
}

// ── Utility ───────────────────────────────────────────────────────────────────
function escHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
</script>
</body>
</html>
`
