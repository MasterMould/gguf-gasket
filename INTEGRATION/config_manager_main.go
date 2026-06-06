package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// ─── Paths config — single source of truth shared with manager.sh ────────────

type PathsConfig struct {
	ModelSearchDirs  []string `json:"model_search_dirs"`
	BinarySearchDirs []string `json:"binary_search_dirs"`
}

// defaultPaths returns paths identical to the MODEL_SEARCH_DIRS and
// LLAMA_BINARY_SEARCH arrays in manager.sh.  Keep both in sync here.
func defaultPaths() PathsConfig {
	home, _ := os.UserHomeDir()
	j := func(parts ...string) string { return filepath.Join(parts...) }
	return PathsConfig{
		ModelSearchDirs: []string{
			"/home/first/ai_stack/models",
			j(home, "ai_stack/models"),
			j(home, "models"),
			j(home, "Downloads"),
			j(home, ".cache/huggingface/hub"),
			j(home, ".cache/lm-studio/models"),
			j(home, ".lmstudio/models"),
			j(home, ".cache/llama.cpp"),
			j(home, ".ollama/models/blobs"),
			j(home, "llama.cpp/models"),
			j(home, "llama/models"),
			"/opt/models",
			"/opt/ai/models",
			"/var/lib/models",
			"/srv/models",
		},
		BinarySearchDirs: []string{
			"/home/first/ai_stack",
			"/home/first/ai_stack/llama.cpp",
			"/home/first/ai_stack/llama.cpp/build/bin",
			j(home, "llama.cpp/build/bin"),
			j(home, "llama.cpp/build"),
			j(home, "llama.cpp"),
			j(home, "llama/build/bin"),
			j(home, "llama/build"),
			"/opt/llama.cpp/bin",
			"/opt/llama.cpp",
			"/usr/local/bin",
			"/usr/bin",
		},
	}
}

// pathsFile returns the canonical location of paths.json.
// Priority: ~/ai_stack/paths.json (gguf-gasket install) → binary directory → cwd.
func pathsFile() string {
	home, herr := os.UserHomeDir()
	if herr == nil {
		gasketDir := filepath.Join(home, "ai_stack")
		if _, serr := os.Stat(gasketDir); serr == nil {
			// Running inside gguf-gasket: share paths.json with manager.sh and
			// the rest of the gasket toolchain (alongside settings.env).
			return filepath.Join(gasketDir, "paths.json")
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return "paths.json"
	}
	return filepath.Join(filepath.Dir(exe), "paths.json")
}

func loadPaths() PathsConfig {
	data, err := os.ReadFile(pathsFile())
	if err != nil {
		return defaultPaths()
	}
	var cfg PathsConfig
	if json.Unmarshal(data, &cfg) != nil {
		return defaultPaths()
	}
	return cfg
}

func savePaths(cfg PathsConfig) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(pathsFile(), data, 0644)
}

// ─── Model scanning ───────────────────────────────────────────────────────────

type ModelInfo struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	SizeHuman string `json:"size_human"`
	Quant     string `json:"quant"`
	Dir       string `json:"dir"`
	ModTime   string `json:"mod_time"`
}

var quantRe = regexp.MustCompile(`(?i)(IQ[0-9]_[A-Z_]+|Q[0-9]+_[A-Z0-9_]+|BF16|F16|F32)`)

func parseQuant(name string) string {
	m := quantRe.FindString(filepath.Base(name))
	if m == "" {
		return "unknown"
	}
	return strings.ToUpper(m)
}

func humanSize(bytes int64) string {
	switch {
	case bytes >= 1<<30:
		return fmt.Sprintf("%.1fG", float64(bytes)/float64(1<<30))
	case bytes >= 1<<20:
		return fmt.Sprintf("%.0fM", float64(bytes)/float64(1<<20))
	case bytes >= 1<<10:
		return fmt.Sprintf("%.0fK", float64(bytes)/float64(1<<10))
	default:
		return fmt.Sprintf("%dB", bytes)
	}
}

func expandHome(path string) string {
	if !strings.HasPrefix(path, "~/") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	return filepath.Join(home, path[2:])
}

const maxScanDepth = 6

func scanModels(dirs []string) []ModelInfo {
	// If launched by menu_config_manager.sh, the module exports
	// GASKET_MODEL_DIR so the gasket's canonical model directory is
	// always the first place we look, regardless of paths.json contents.
	if extra := os.Getenv("GASKET_MODEL_DIR"); extra != "" {
		// Prepend without duplicating
		has := false
		for _, d := range dirs {
			if d == extra {
				has = true
				break
			}
		}
		if !has {
			dirs = append([]string{extra}, dirs...)
		}
	}
	var models []ModelInfo
	seen := map[string]bool{}

	for _, root := range dirs {
		root = expandHome(root)
		if _, err := os.Stat(root); err != nil {
			continue
		}
		depth := 0
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(root, path)
			depth = strings.Count(rel, string(os.PathSeparator))
			if d.IsDir() {
				if depth >= maxScanDepth {
					return fs.SkipDir
				}
				// skip .git but allow .cache, .lmstudio etc.
				if d.Name() == ".git" {
					return fs.SkipDir
				}
				return nil
			}
			lower := strings.ToLower(d.Name())
			if !strings.HasSuffix(lower, ".gguf") {
				return nil
			}
			real, _ := filepath.EvalSymlinks(path)
			if real == "" {
				real = path
			}
			if seen[real] {
				return nil
			}
			seen[real] = true
			info, _ := d.Info()
			var size int64
			modTime := ""
			if info != nil {
				size = info.Size()
				modTime = info.ModTime().Format("2006-01-02")
			}
			models = append(models, ModelInfo{
				Name:      d.Name(),
				Path:      path,
				Size:      size,
				SizeHuman: humanSize(size),
				Quant:     parseQuant(d.Name()),
				Dir:       filepath.Dir(path),
				ModTime:   modTime,
			})
			return nil
		})
	}
	sort.Slice(models, func(i, j int) bool {
		return strings.ToLower(models[i].Name) < strings.ToLower(models[j].Name)
	})
	return models
}

// ─── Binary scanning ──────────────────────────────────────────────────────────

type BinaryInfo struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

var llamaBinNames = []string{"llama-server", "llama-cli", "llama-bench", "server", "main"}

func scanBinaries(dirs []string) []BinaryInfo {
	var bins []BinaryInfo
	seen := map[string]bool{}
	for _, dir := range dirs {
		dir = expandHome(dir)
		for _, name := range llamaBinNames {
			p := filepath.Join(dir, name)
			info, err := os.Stat(p)
			if err != nil || info.IsDir() {
				continue
			}
			if info.Mode()&0o111 == 0 {
				continue
			}
			real, _ := filepath.EvalSymlinks(p)
			if real == "" {
				real = p
			}
			if seen[real] {
				continue
			}
			seen[real] = true
			bins = append(bins, BinaryInfo{Name: name, Path: p})
		}
	}
	return bins
}

// ─── INI parser / serialiser (unchanged) ─────────────────────────────────────

type IniSection struct {
	Name string
	Keys []IniKey
}

type IniKey struct {
	Key     string
	Value   string
	Comment string
}

type IniFile struct {
	Name     string
	Sections []IniSection
}

func parseINI(data string) IniFile {
	file := IniFile{}
	current := IniSection{Name: ""}
	for _, raw := range strings.Split(data, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			file.Sections = append(file.Sections, current)
			current = IniSection{Name: line[1 : len(line)-1]}
			continue
		}
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

func splitComment(s string) (string, string) {
	for _, sep := range []string{" #", "\t#", " ;"} {
		if i := strings.Index(s, sep); i >= 0 {
			return strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+len(sep):])
		}
	}
	return strings.TrimSpace(s), ""
}

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

// ─── File store (unchanged) ───────────────────────────────────────────────────

type Store struct{ dir string }

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

func (s *Store) Delete(name string) error { return os.Remove(s.path(name)) }

func (s *Store) Exists(name string) bool {
	_, err := os.Stat(s.path(name))
	return err == nil
}

func (s *Store) path(name string) string {
	return filepath.Join(s.dir, filepath.Base(name))
}

// ─── HTTP handler ─────────────────────────────────────────────────────────────

type Handler struct {
	store *Store
	tmpl  *template.Template
}

func wire(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func errJSON(w http.ResponseWriter, code int, msg string) {
	wire(w, code, map[string]string{"error": msg})
}

// GET /api/files
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

// GET /api/files/{name}
func (h *Handler) getFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	f, err := h.store.Read(name)
	if err != nil {
		errJSON(w, 404, "file not found: "+name)
		return
	}
	wire(w, 200, f)
}

// POST /api/files
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

// PUT /api/files/{name}
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

// DELETE /api/files/{name}
func (h *Handler) deleteFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if err := h.store.Delete(name); err != nil {
		errJSON(w, 404, "file not found: "+name)
		return
	}
	wire(w, 200, map[string]string{"deleted": name})
}

// GET /api/models — scan and return model list
func (h *Handler) listModels(w http.ResponseWriter, r *http.Request) {
	cfg := loadPaths()
	models := scanModels(cfg.ModelSearchDirs)
	if models == nil {
		models = []ModelInfo{}
	}
	wire(w, 200, models)
}

// GET /api/binaries — scan and return llama binary list
func (h *Handler) listBinaries(w http.ResponseWriter, r *http.Request) {
	cfg := loadPaths()
	bins := scanBinaries(cfg.BinarySearchDirs)
	if bins == nil {
		bins = []BinaryInfo{}
	}
	wire(w, 200, bins)
}

// GET /api/paths — return current paths config
func (h *Handler) getPaths(w http.ResponseWriter, r *http.Request) {
	wire(w, 200, loadPaths())
}

// PUT /api/paths — save new paths config (writes paths.json)
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

// GET / → SPA
func (h *Handler) index(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	h.tmpl.Execute(w, nil)
}

// ─── Helpers (unchanged) ──────────────────────────────────────────────────────

func sanitiseName(s string) string {
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, " ", "-")
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

func templateFile(name, tmpl string) IniFile {
	switch tmpl {
	case "server":
		return IniFile{Name: name, Sections: []IniSection{{Name: "", Keys: []IniKey{
			{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
			{Key: "host", Value: "127.0.0.1", Comment: "listen address"},
			{Key: "port", Value: "8080", Comment: "listen port"},
			{Key: "ctx-size", Value: "4096", Comment: "context window tokens"},
			{Key: "n-gpu-layers", Value: "0", Comment: "layers offloaded to GPU (0 = CPU only)"},
			{Key: "threads", Value: "4", Comment: "CPU threads"},
			{Key: "batch-size", Value: "512", Comment: "prompt batch size"},
		}}}}
	case "chat":
		return IniFile{Name: name, Sections: []IniSection{{Name: "", Keys: []IniKey{
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
		}}}}
	case "embedding":
		return IniFile{Name: name, Sections: []IniSection{{Name: "", Keys: []IniKey{
			{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
			{Key: "ctx-size", Value: "2048", Comment: "context window tokens"},
			{Key: "n-gpu-layers", Value: "0", Comment: "layers offloaded to GPU"},
			{Key: "threads", Value: "4", Comment: "CPU threads"},
			{Key: "embedding", Value: "true", Comment: "enable embedding mode"},
			{Key: "batch-size", Value: "512", Comment: "batch size"},
		}}}}
	default:
		return IniFile{Name: name, Sections: []IniSection{{Name: "", Keys: []IniKey{
			{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
		}}}}
	}
}

// ─── Parameter metadata (unchanged) ──────────────────────────────────────────

type ParamMeta struct {
	Key, Label, Description, Type, Min, Max, Step string
}

var knownParams = []ParamMeta{
	{Key: "model", Label: "Model Path", Description: "Path to the .gguf model file", Type: "path"},
	{Key: "ctx-size", Label: "Context Size", Description: "Context window tokens. Larger = more memory.", Type: "number", Min: "128", Max: "131072", Step: "128"},
	{Key: "batch-size", Label: "Batch Size", Description: "Prompt processing batch size.", Type: "number", Min: "1", Max: "4096", Step: "1"},
	{Key: "n-gpu-layers", Label: "GPU Layers", Description: "Layers offloaded to GPU. 0 = CPU only. -1 = all.", Type: "number", Min: "-1", Max: "200", Step: "1"},
	{Key: "main-gpu", Label: "Main GPU", Description: "Primary GPU index.", Type: "number", Min: "0", Max: "16", Step: "1"},
	{Key: "threads", Label: "CPU Threads", Description: "Threads for generation.", Type: "number", Min: "1", Max: "256", Step: "1"},
	{Key: "threads-batch", Label: "Batch Threads", Description: "Threads for prompt evaluation.", Type: "number", Min: "1", Max: "256", Step: "1"},
	{Key: "temperature", Label: "Temperature", Description: "Randomness. Lower = focused; higher = creative.", Type: "number", Min: "0.0", Max: "2.0", Step: "0.01"},
	{Key: "top-p", Label: "Top-P", Description: "Nucleus sampling threshold.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "top-k", Label: "Top-K", Description: "Limit sampling to K most likely tokens.", Type: "number", Min: "0", Max: "200", Step: "1"},
	{Key: "min-p", Label: "Min-P", Description: "Minimum probability relative to top token.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "repeat-penalty", Label: "Repeat Penalty", Description: "Penalises repetition. 1.0 = none.", Type: "number", Min: "1.0", Max: "2.0", Step: "0.01"},
	{Key: "repeat-last-n", Label: "Repeat Last N", Description: "Tokens to look back for repeat penalty.", Type: "number", Min: "0", Max: "512", Step: "1"},
	{Key: "tfs-z", Label: "TFS Z", Description: "Tail free sampling. 1.0 = disabled.", Type: "number", Min: "1.0", Max: "2.0", Step: "0.01"},
	{Key: "typical-p", Label: "Typical-P", Description: "Locally typical sampling. 1.0 = disabled.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "mirostat", Label: "Mirostat Mode", Description: "0 = off, 1 = v1, 2 = v2.", Type: "number", Min: "0", Max: "2", Step: "1"},
	{Key: "mirostat-lr", Label: "Mirostat LR", Description: "Mirostat learning rate (eta).", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "mirostat-ent", Label: "Mirostat Entropy", Description: "Mirostat target entropy (tau).", Type: "number", Min: "0.0", Max: "10.0", Step: "0.1"},
	{Key: "n-predict", Label: "Max Tokens", Description: "Max tokens to generate. -1 = unlimited.", Type: "number", Min: "-1", Max: "32768", Step: "1"},
	{Key: "seed", Label: "Seed", Description: "RNG seed. -1 = random.", Type: "number", Min: "-1", Max: "2147483647", Step: "1"},
	{Key: "host", Label: "Host", Description: "Server bind address.", Type: "text"},
	{Key: "port", Label: "Port", Description: "Server port.", Type: "number", Min: "1", Max: "65535", Step: "1"},
	{Key: "timeout", Label: "Timeout (s)", Description: "Request timeout in seconds.", Type: "number", Min: "1", Max: "600", Step: "1"},
	{Key: "parallel", Label: "Parallel Slots", Description: "Number of parallel request slots.", Type: "number", Min: "1", Max: "64", Step: "1"},
	{Key: "cont-batching", Label: "Continuous Batching", Description: "Enable continuous batching.", Type: "bool"},
	{Key: "embedding", Label: "Embedding Mode", Description: "Enable embedding endpoint.", Type: "bool"},
	{Key: "flash-attn", Label: "Flash Attention", Description: "Enable Flash Attention.", Type: "bool"},
	{Key: "no-mmap", Label: "No Memory Map", Description: "Disable memory-mapped model loading.", Type: "bool"},
	{Key: "mlock", Label: "Memory Lock", Description: "Lock model in RAM.", Type: "bool"},
	{Key: "numa", Label: "NUMA", Description: "Enable NUMA-aware allocation.", Type: "bool"},
	{Key: "log-disable", Label: "Disable Logging", Description: "Suppress log output.", Type: "bool"},
	{Key: "verbose", Label: "Verbose", Description: "Enable verbose output.", Type: "bool"},
}

func paramMetaJSON() template.JS {
	b, _ := json.Marshal(knownParams)
	return template.JS(b)
}

// ─── Entrypoint ───────────────────────────────────────────────────────────────

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
	// Config CRUD
	mux.HandleFunc("GET /", h.index)
	mux.HandleFunc("GET /api/files", h.listFiles)
	mux.HandleFunc("GET /api/files/{name}", h.getFile)
	mux.HandleFunc("POST /api/files", h.createFile)
	mux.HandleFunc("PUT /api/files/{name}", h.updateFile)
	mux.HandleFunc("DELETE /api/files/{name}", h.deleteFile)
	// Models & binaries
	mux.HandleFunc("GET /api/models", h.listModels)
	mux.HandleFunc("GET /api/binaries", h.listBinaries)
	// Shared paths config
	mux.HandleFunc("GET /api/paths", h.getPaths)
	mux.HandleFunc("PUT /api/paths", h.putPaths)

	addr := ":" + port
	fmt.Printf("llama.cpp config manager  →  http://localhost%s\n", addr)
	fmt.Printf("configs directory         →  %s\n", dir)
	fmt.Printf("paths.json                →  %s\n", pathsFile())
	log.Fatal(http.ListenAndServe(addr, mux))
}

// ─── Embedded HTML/CSS/JS ─────────────────────────────────────────────────────

const htmlTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>gguf-gasket · Config Manager</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Syne:wght@400;600;700;800&display=swap" rel="stylesheet">
<style>
:root {
  --bg:      #0d0f14; --bg2: #13161e; --bg3: #1a1e28;
  --border:  #252936; --border2: #2e3347;
  --accent:  #c9f55a; --accent2: #4ef0c0; --accent3: #f5a623;
  --text:    #e2e6f0; --text2: #8a92a8; --text3: #555f7a;
  --danger:  #ff5f6d;
  --q-low:   #ff5f6d; --q-mid: #f5a623; --q-std: #4ef0c0;
  --q-hi:    #c9f55a; --q-fp: #c084fc;
  --mono: 'IBM Plex Mono', monospace;
  --sans: 'Syne', sans-serif;
  --radius: 6px; --shadow: 0 4px 24px rgba(0,0,0,.5);
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
html, body { height: 100%; overflow: hidden; }
body { background: var(--bg); color: var(--text); font-family: var(--mono); font-size: 13px; display: flex; flex-direction: column; }
::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border2); border-radius: 3px; }

/* ── header ── */
header {
  height: 52px; min-height: 52px; display: flex; align-items: center; gap: 0;
  border-bottom: 1px solid var(--border); background: var(--bg2); z-index: 10;
}
.logo {
  font-family: var(--sans); font-weight: 800; font-size: 16px;
  letter-spacing: -.3px; color: var(--accent);
  display: flex; align-items: center; gap: 8px; padding: 0 18px;
  border-right: 1px solid var(--border); height: 100%;
}
.logo-badge {
  background: var(--accent); color: var(--bg); font-size: 9px;
  font-weight: 700; padding: 2px 5px; border-radius: 3px; letter-spacing: .5px;
}
/* top-level nav tabs */
.nav-tabs { display: flex; height: 100%; margin-left: 4px; }
.nav-tab {
  display: flex; align-items: center; gap: 6px;
  padding: 0 20px; font-size: 12px; font-weight: 600;
  letter-spacing: .8px; text-transform: uppercase;
  color: var(--text3); cursor: pointer; border-bottom: 2px solid transparent;
  transition: color .15s, border-color .15s; user-select: none;
}
.nav-tab:hover { color: var(--text); }
.nav-tab.active { color: var(--accent); border-bottom-color: var(--accent); }
.nav-tab .tab-icon { font-size: 14px; }
.header-right { margin-left: auto; display: flex; align-items: center; gap: 10px; padding-right: 16px; }
.dir-badge { font-size: 11px; color: var(--text3); background: var(--bg3); border: 1px solid var(--border); border-radius: 4px; padding: 3px 8px; }

/* ── views ── */
.view { display: none; flex: 1; overflow: hidden; }
.view.active { display: flex; }

/* ═══════════════════════ CONFIGS VIEW ═══════════════════════ */
.configs-view { flex-direction: row; }
aside {
  width: 230px; min-width: 230px; border-right: 1px solid var(--border);
  background: var(--bg2); display: flex; flex-direction: column; overflow: hidden;
}
.sidebar-head {
  padding: 12px 12px 10px; border-bottom: 1px solid var(--border);
  display: flex; align-items: center; gap: 6px;
}
.sidebar-head h2 { font-family: var(--sans); font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 1.5px; color: var(--text2); flex: 1; }
.btn-new { background: var(--accent); color: var(--bg); border: none; border-radius: var(--radius); font-family: var(--mono); font-size: 12px; font-weight: 600; padding: 4px 10px; cursor: pointer; transition: opacity .15s; }
.btn-new:hover { opacity: .85; }
.file-list { flex: 1; overflow-y: auto; padding: 4px 0; }
.file-item {
  display: flex; align-items: center; padding: 7px 12px 7px 14px;
  cursor: pointer; border-left: 3px solid transparent; gap: 6px;
  transition: background .12s, border-color .12s;
}
.file-item:hover { background: var(--bg3); }
.file-item.active { background: var(--bg3); border-left-color: var(--accent); color: var(--accent); }
.file-name { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 12px; }
.file-ext { color: var(--text3); font-size: 10px; }
.btn-del { background: none; border: none; color: var(--text3); cursor: pointer; font-size: 13px; padding: 0 2px; opacity: 0; transition: opacity .12s, color .12s; }
.file-item:hover .btn-del { opacity: 1; }
.btn-del:hover { color: var(--danger); }
.sidebar-empty { padding: 20px 12px; color: var(--text3); font-size: 11px; line-height: 1.7; text-align: center; }
.configs-main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.empty-state { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; color: var(--text3); }
.empty-icon { font-size: 44px; opacity: .3; }
.empty-state h3 { font-family: var(--sans); font-size: 17px; color: var(--text2); }
.empty-state p { font-size: 12px; line-height: 1.7; text-align: center; max-width: 280px; }
.editor { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.editor-topbar { display: flex; align-items: center; gap: 10px; padding: 10px 18px; border-bottom: 1px solid var(--border); background: var(--bg2); }
.file-title { font-family: var(--sans); font-size: 14px; font-weight: 700; flex: 1; }
.tab-bar { display: flex; border-bottom: 1px solid var(--border); background: var(--bg2); padding: 0 18px; }
.tab { padding: 8px 16px; font-size: 11px; font-weight: 600; letter-spacing: .6px; text-transform: uppercase; cursor: pointer; border-bottom: 2px solid transparent; color: var(--text3); transition: color .12s, border-color .12s; }
.tab:hover { color: var(--text); }
.tab.active { color: var(--accent); border-bottom-color: var(--accent); }
.editor-body { flex: 1; overflow-y: auto; padding: 20px 24px; }
.section-block { margin-bottom: 24px; background: var(--bg2); border: 1px solid var(--border); border-radius: var(--radius); overflow: hidden; }
.section-header { display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; background: var(--bg3); border-bottom: 1px solid var(--border); font-size: 11px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase; color: var(--text2); }
.section-label { color: var(--accent2); }
.section-name-input { background: var(--bg); border: 1px solid var(--border); color: var(--text); font-family: var(--mono); font-size: 11px; padding: 3px 7px; border-radius: 4px; }
.kv-row { display: grid; grid-template-columns: 210px 1fr auto; align-items: center; border-bottom: 1px solid var(--border); min-height: 42px; transition: background .1s; }
.kv-row:last-child { border-bottom: none; }
.kv-row:hover { background: var(--bg3); }
.kv-key-cell { padding: 5px 10px; border-right: 1px solid var(--border); display: flex; flex-direction: column; gap: 1px; }
.kv-key { font-size: 12px; color: var(--accent2); font-weight: 500; }
.kv-desc { font-size: 10px; color: var(--text3); line-height: 1.4; }
.kv-val-cell { padding: 5px 10px; display: flex; align-items: center; gap: 6px; }
.kv-val-cell input[type=text], .kv-val-cell input[type=number] { flex: 1; background: transparent; border: none; border-bottom: 1px solid var(--border2); color: var(--text); font-family: var(--mono); font-size: 12px; padding: 3px 2px; outline: none; transition: border-color .15s; }
.kv-val-cell input:focus { border-bottom-color: var(--accent); }
.kv-toggle { display: flex; align-items: center; gap: 5px; }
.kv-toggle input[type=checkbox] { width: 13px; height: 13px; accent-color: var(--accent); cursor: pointer; }
.kv-actions-cell { padding: 5px 8px; display: flex; gap: 3px; }
.btn-icon { background: none; border: 1px solid transparent; border-radius: 4px; color: var(--text3); cursor: pointer; font-size: 12px; padding: 2px 5px; transition: all .12s; }
.btn-icon:hover { border-color: var(--border2); color: var(--text); }
.btn-icon.danger:hover { border-color: var(--danger); color: var(--danger); }
.raw-view { padding: 0; flex: 1; }
.raw-textarea { width: 100%; height: 100%; min-height: 400px; background: var(--bg); color: var(--accent2); border: none; font-family: var(--mono); font-size: 12px; padding: 18px; outline: none; resize: vertical; line-height: 1.7; }
.raw-note { padding: 7px 18px; font-size: 11px; color: var(--text3); background: var(--bg2); border-bottom: 1px solid var(--border); }

/* ═══════════════════════ MODELS VIEW ═══════════════════════ */
.models-view { flex-direction: column; }
.models-toolbar {
  display: flex; align-items: center; gap: 10px;
  padding: 12px 20px; border-bottom: 1px solid var(--border);
  background: var(--bg2); flex-shrink: 0;
}
.models-toolbar h2 { font-family: var(--sans); font-weight: 700; font-size: 14px; margin-right: 4px; }
.search-box {
  flex: 1; max-width: 320px;
  background: var(--bg3); border: 1px solid var(--border2);
  color: var(--text); font-family: var(--mono); font-size: 12px;
  padding: 6px 10px; border-radius: var(--radius); outline: none;
  transition: border-color .15s;
}
.search-box:focus { border-color: var(--accent2); }
.sort-sel {
  background: var(--bg3); border: 1px solid var(--border2);
  color: var(--text2); font-family: var(--mono); font-size: 11px;
  padding: 5px 8px; border-radius: var(--radius); cursor: pointer; outline: none;
}
.model-count { font-size: 11px; color: var(--text3); margin-left: auto; }
.models-body { flex: 1; overflow-y: auto; padding: 16px 20px; }
.models-scanning { display: flex; align-items: center; justify-content: center; flex: 1; color: var(--text3); font-size: 13px; gap: 10px; }
.models-empty { text-align: center; padding: 60px 20px; color: var(--text3); }
.models-empty h3 { font-family: var(--sans); font-size: 16px; color: var(--text2); margin-bottom: 8px; }
/* model table */
.model-table { width: 100%; border-collapse: collapse; }
.model-table thead th {
  text-align: left; padding: 6px 12px;
  font-size: 10px; letter-spacing: 1px; text-transform: uppercase;
  color: var(--text3); border-bottom: 1px solid var(--border);
  position: sticky; top: 0; background: var(--bg); z-index: 1;
}
.model-table tbody tr { border-bottom: 1px solid var(--border); transition: background .1s; cursor: default; }
.model-table tbody tr:hover { background: var(--bg2); }
.model-table tbody tr:last-child { border-bottom: none; }
.model-table td { padding: 9px 12px; font-size: 12px; vertical-align: middle; }
.model-name-cell { max-width: 340px; }
.model-name { font-weight: 500; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: block; max-width: 330px; }
.model-dir  { font-size: 10px; color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: block; max-width: 330px; }
.quant-badge {
  display: inline-block; padding: 2px 7px; border-radius: 3px;
  font-size: 10px; font-weight: 700; letter-spacing: .5px;
  border: 1px solid currentColor; white-space: nowrap;
}
.q-unk  { color: var(--text3); }
.q-low  { color: var(--q-low); }
.q-mid  { color: var(--q-mid); }
.q-std  { color: var(--q-std); }
.q-hi   { color: var(--q-hi); }
.q-fp   { color: var(--q-fp); }
.model-size { color: var(--text2); text-align: right; white-space: nowrap; }
.model-date { color: var(--text3); font-size: 11px; white-space: nowrap; }
.model-actions { white-space: nowrap; }
.btn-use {
  background: transparent; border: 1px solid var(--accent2); color: var(--accent2);
  border-radius: var(--radius); font-family: var(--mono); font-size: 11px;
  padding: 3px 10px; cursor: pointer; transition: all .15s; white-space: nowrap;
}
.btn-use:hover { background: var(--accent2); color: var(--bg); }
.btn-copy {
  background: transparent; border: 1px solid var(--border2); color: var(--text3);
  border-radius: var(--radius); font-family: var(--mono); font-size: 11px;
  padding: 3px 8px; cursor: pointer; margin-left: 4px; transition: all .15s;
}
.btn-copy:hover { border-color: var(--text2); color: var(--text); }

/* ═══════════════════════ SETTINGS VIEW ═══════════════════════ */
.settings-view { flex-direction: column; }
.settings-body { flex: 1; overflow-y: auto; padding: 28px 32px; max-width: 820px; width: 100%; }
.settings-section { margin-bottom: 36px; }
.settings-section h2 { font-family: var(--sans); font-size: 14px; font-weight: 700; margin-bottom: 4px; }
.settings-section .hint { font-size: 11px; color: var(--text3); margin-bottom: 14px; line-height: 1.6; }
.path-list { display: flex; flex-direction: column; gap: 6px; margin-bottom: 10px; }
.path-row {
  display: flex; align-items: center; gap: 8px;
  background: var(--bg2); border: 1px solid var(--border);
  border-radius: var(--radius); padding: 6px 10px;
  transition: border-color .15s;
}
.path-row:hover { border-color: var(--border2); }
.path-row.missing { opacity: .5; }
.path-exists-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
.dot-ok  { background: var(--accent); }
.dot-no  { background: var(--text3); }
.path-text { flex: 1; font-size: 12px; color: var(--text2); word-break: break-all; }
.path-status { font-size: 10px; color: var(--text3); white-space: nowrap; }
.btn-remove-path { background: none; border: none; color: var(--text3); cursor: pointer; font-size: 14px; padding: 0 3px; transition: color .12s; }
.btn-remove-path:hover { color: var(--danger); }
.add-path-row { display: flex; gap: 8px; }
.add-path-input {
  flex: 1; background: var(--bg3); border: 1px solid var(--border2);
  color: var(--text); font-family: var(--mono); font-size: 12px;
  padding: 7px 10px; border-radius: var(--radius); outline: none;
  transition: border-color .15s;
}
.add-path-input:focus { border-color: var(--accent2); }
.settings-actions { display: flex; gap: 10px; margin-top: 8px; align-items: center; }
.save-status { font-size: 11px; color: var(--text3); }
.save-status.ok  { color: var(--accent); }
.save-status.err { color: var(--danger); }
.paths-json-path { font-size: 11px; color: var(--text3); margin-top: 6px; }
.paths-json-path code { color: var(--accent2); }

/* ── shared buttons ── */
.btn-primary { background: var(--accent); color: var(--bg); border: none; border-radius: var(--radius); font-family: var(--mono); font-size: 12px; font-weight: 600; padding: 6px 14px; cursor: pointer; transition: opacity .15s; }
.btn-primary:hover { opacity: .85; }
.btn-secondary { background: transparent; color: var(--text2); border: 1px solid var(--border2); border-radius: var(--radius); font-family: var(--mono); font-size: 12px; padding: 6px 14px; cursor: pointer; transition: all .12s; }
.btn-secondary:hover { border-color: var(--accent); color: var(--accent); }
/* ── toasts ── */
#toast-area { position: fixed; bottom: 18px; right: 18px; display: flex; flex-direction: column; gap: 7px; z-index: 999; pointer-events: none; }
.toast { background: var(--bg3); border: 1px solid var(--border2); border-radius: var(--radius); padding: 9px 14px; font-size: 12px; color: var(--text); display: flex; align-items: center; gap: 7px; animation: slideIn .2s ease; box-shadow: var(--shadow); }
.toast.ok  { border-left: 3px solid var(--accent); }
.toast.err { border-left: 3px solid var(--danger); }
@keyframes slideIn { from { opacity:0; transform: translateX(20px); } to { opacity:1; transform: none; } }
/* ── modals ── */
.modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,.7); display: flex; align-items: center; justify-content: center; z-index: 100; backdrop-filter: blur(4px); }
.modal { background: var(--bg2); border: 1px solid var(--border2); border-radius: 10px; padding: 26px 28px; width: 400px; box-shadow: var(--shadow); }
.modal h2 { font-family: var(--sans); font-size: 16px; font-weight: 700; margin-bottom: 18px; }
.modal label { font-size: 11px; color: var(--text2); display: block; margin-bottom: 3px; text-transform: uppercase; letter-spacing: .8px; }
.modal input, .modal select { width: 100%; background: var(--bg); border: 1px solid var(--border2); color: var(--text); font-family: var(--mono); font-size: 13px; padding: 7px 9px; border-radius: 5px; outline: none; margin-bottom: 14px; transition: border-color .12s; }
.modal input:focus, .modal select:focus { border-color: var(--accent); }
.modal-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 6px; }
.confirm-text { font-size: 13px; color: var(--text2); line-height: 1.6; margin-bottom: 18px; }
.confirm-text strong { color: var(--text); }
.btn-danger { background: var(--danger); color: #fff; border: none; border-radius: var(--radius); font-family: var(--mono); font-size: 12px; font-weight: 600; padding: 6px 14px; cursor: pointer; }
.btn-danger:hover { opacity: .85; }
/* spinner */
@keyframes spin { to { transform: rotate(360deg); } }
.spinner { width: 16px; height: 16px; border: 2px solid var(--border2); border-top-color: var(--accent2); border-radius: 50%; animation: spin .7s linear infinite; display: inline-block; }
</style>
</head>
<body>

<header>
  <div class="logo">🦙 gguf-gasket <span class="logo-badge">CONFIG</span></div>
  <nav class="nav-tabs">
    <div class="nav-tab active" data-view="configs" onclick="switchView('configs')">
      <span class="tab-icon">⚙</span> Configs
    </div>
    <div class="nav-tab" data-view="models" onclick="switchView('models')">
      <span class="tab-icon">🗃</span> Models
    </div>
    <div class="nav-tab" data-view="settings" onclick="switchView('settings')">
      <span class="tab-icon">⚡</span> Paths
    </div>
  </nav>
  <div class="header-right">
    <span class="dir-badge" id="dir-badge">configs/</span>
  </div>
</header>

<!-- ═══════════════════════ CONFIGS VIEW ═══════════════════════ -->
<div class="view configs-view active" id="view-configs">
  <aside>
    <div class="sidebar-head">
      <h2>Files</h2>
      <button class="btn-new" onclick="openNewModal()">+ New</button>
    </div>
    <div class="file-list" id="file-list"></div>
  </aside>
  <div class="configs-main">
    <div class="empty-state" id="empty-state">
      <div class="empty-icon">⚙️</div>
      <h3>No file selected</h3>
      <p>Create a new .ini file or select one from the sidebar.</p>
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
        <div class="raw-note">Editing raw .ini text — switch to Form for guided fields.</div>
        <textarea class="raw-textarea" id="raw-textarea" spellcheck="false"></textarea>
      </div>
    </div>
  </div>
</div>

<!-- ═══════════════════════ MODELS VIEW ═══════════════════════ -->
<div class="view models-view" id="view-models">
  <div class="models-toolbar">
    <h2>Models</h2>
    <input class="search-box" type="text" id="model-search" placeholder="Filter by name or quant…" oninput="renderModels()">
    <select class="sort-sel" id="model-sort" onchange="renderModels()">
      <option value="name">Sort: Name</option>
      <option value="size-desc">Sort: Size ↓</option>
      <option value="size-asc">Sort: Size ↑</option>
      <option value="quant">Sort: Quant</option>
      <option value="date">Sort: Date</option>
    </select>
    <span class="model-count" id="model-count"></span>
    <button class="btn-secondary" onclick="loadModels(true)">⟳ Rescan</button>
  </div>
  <div class="models-body" id="models-body">
    <div class="models-scanning">
      <span class="spinner"></span> Scanning for models…
    </div>
  </div>
</div>

<!-- ═══════════════════════ SETTINGS / PATHS VIEW ═══════════════════════ -->
<div class="view settings-view" id="view-settings">
  <div class="settings-body">

    <div class="settings-section">
      <h2>Model Search Directories</h2>
      <p class="hint">
        Directories scanned recursively for <code>.gguf</code> files.
        Shared with <code>llama_manager.sh</code> via <code>~/ai_stack/paths.json</code>.
        Changes save immediately on click.
      </p>
      <div class="path-list" id="model-dir-list"></div>
      <div class="add-path-row">
        <input class="add-path-input" id="new-model-dir" placeholder="/path/to/models" onkeydown="if(event.key==='Enter')addModelDir()">
        <button class="btn-primary" onclick="addModelDir()">Add</button>
      </div>
    </div>

    <div class="settings-section">
      <h2>llama Binary Search Directories</h2>
      <p class="hint">
        Directories searched for <code>llama-server</code>, <code>llama-cli</code>, etc.
        Also used by <code>manager.sh</code> when selecting a binary to launch.
      </p>
      <div class="path-list" id="binary-dir-list"></div>
      <div class="add-path-row">
        <input class="add-path-input" id="new-binary-dir" placeholder="/path/to/llama.cpp/build/bin" onkeydown="if(event.key==='Enter')addBinaryDir()">
        <button class="btn-primary" onclick="addBinaryDir()">Add</button>
      </div>
    </div>

    <div class="settings-actions">
      <button class="btn-primary" onclick="savePaths()">Save paths.json</button>
      <button class="btn-secondary" onclick="resetPaths()">Reset to defaults</button>
      <span class="save-status" id="save-status"></span>
    </div>
    <div class="paths-json-path" id="paths-json-info"></div>

  </div>
</div>

<div id="toast-area"></div>

<!-- New file modal -->
<div class="modal-overlay" id="new-modal" style="display:none">
  <div class="modal" onclick="event.stopPropagation()">
    <h2>New Config File</h2>
    <label>File Name</label>
    <input type="text" id="new-name" placeholder="e.g. server-config">
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
    <p class="confirm-text">Permanently delete <strong id="del-name-label"></strong>?</p>
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
    <input type="text" id="key-new-key" placeholder="e.g. ctx-size">
    <label>Value</label>
    <input type="text" id="key-new-val" placeholder="">
    <div class="modal-actions">
      <button class="btn-secondary" onclick="closeKeyModal()">Cancel</button>
      <button class="btn-primary" onclick="confirmAddKey()">Add</button>
    </div>
  </div>
</div>

<script>
// ── Param metadata ────────────────────────────────────────────────────────────
const PARAM_META = {{ paramMetaJSON }};
const META_MAP = {};
PARAM_META.forEach(p => META_MAP[p.Key] = p);

// ── State ─────────────────────────────────────────────────────────────────────
let files = [];
let current = null;
let activeTab = 'form';
let pendingSection = 0;
let deleteTarget = null;
let allModels = [];
let paths = { model_search_dirs: [], binary_search_dirs: [] };

// ── View switching ────────────────────────────────────────────────────────────
function switchView(name) {
  document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
  document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
  document.getElementById('view-' + name).classList.add('active');
  document.querySelector('[data-view="' + name + '"]').classList.add('active');
  if (name === 'models' && allModels.length === 0) loadModels(false);
  if (name === 'settings') loadPathsSettings();
}

// ── API helper ────────────────────────────────────────────────────────────────
async function api(method, path, body) {
  const opts = { method, headers: {'Content-Type':'application/json'} };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const r = await fetch('/api' + path, opts);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────
loadFiles();

// ══════════════════════════════════════════════════════════
//  CONFIGS PANEL
// ══════════════════════════════════════════════════════════

async function loadFiles() {
  files = await api('GET', '/files');
  renderSidebar();
}

function renderSidebar() {
  const el = document.getElementById('file-list');
  if (!files.length) {
    el.innerHTML = '<div class="sidebar-empty">No .ini files.<br>Click <b>+ New</b> to create one.</div>';
    return;
  }
  el.innerHTML = files.map(f => {
    const base = f.replace('.ini','');
    const active = current && current.Name === f ? 'active' : '';
    return ` + "`" + `<div class="file-item ${active}" onclick="openFile('${f}')" data-name="${f}">
      <span class="file-name">${base}<span class="file-ext">.ini</span></span>
      <button class="btn-del" title="Delete" onclick="event.stopPropagation();openDelModal('${f}')">✕</button>
    </div>` + "`" + `;
  }).join('');
}

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

function renderForm() {
  const container = document.getElementById('tab-form');
  if (!current) { container.innerHTML=''; return; }
  let html = '';
  current.Sections.forEach((sec, si) => {
    html += ` + "`" + `<div class="section-block">
      <div class="section-header">
        <span>${si===0&&!sec.Name
          ? '<span style="color:var(--text3)">root level keys</span>'
          : '<span class="section-label">['+sec.Name+']</span>'}</span>
        <div style="display:flex;gap:5px;align-items:center">
          ${si>0 ? '<input class="section-name-input" value="'+escHtml(sec.Name)+'" oninput="renameSec('+si+',this.value)">' : ''}
          <button class="btn-icon" onclick="openKeyModal(${si})">＋ param</button>
          ${si>0 ? '<button class="btn-icon danger" onclick="removeSec('+si+')">✕</button>' : ''}
        </div>
      </div>` + "`" + `;
    if (!sec.Keys || !sec.Keys.length) {
      html += '<div style="padding:10px 12px;color:var(--text3);font-size:11px">No keys.</div>';
    } else {
      sec.Keys.forEach((kv, ki) => {
        const meta = META_MAP[kv.Key];
        const desc = meta ? meta.Description : (kv.Comment || '');
        const type = meta ? meta.Type : 'text';
        let valHtml;
        if (type === 'bool') {
          const chk = (kv.Value==='true'||kv.Value==='1') ? 'checked' : '';
          valHtml = ` + "`" + `<div class="kv-toggle"><input type="checkbox" ${chk} onchange="setVal(${si},${ki},this.checked?'true':'false')"></div>` + "`" + `;
        } else if (type === 'number') {
          const attrs = [
            meta&&meta.Min  ? 'min="'+meta.Min+'"'  : '',
            meta&&meta.Max  ? 'max="'+meta.Max+'"'  : '',
            meta&&meta.Step ? 'step="'+meta.Step+'"': ''
          ].join(' ');
          valHtml = ` + "`" + `<input type="number" value="${escHtml(kv.Value)}" ${attrs} oninput="setVal(${si},${ki},this.value)">` + "`" + `;
        } else {
          valHtml = ` + "`" + `<input type="text" value="${escHtml(kv.Value)}" oninput="setVal(${si},${ki},this.value)">` + "`" + `;
        }
        html += ` + "`" + `<div class="kv-row">
          <div class="kv-key-cell">
            <span class="kv-key">${escHtml(kv.Key)}</span>
            ${desc ? '<span class="kv-desc">'+escHtml(desc)+'</span>' : ''}
          </div>
          <div class="kv-val-cell">${valHtml}</div>
          <div class="kv-actions-cell">
            <button class="btn-icon danger" onclick="removeKey(${si},${ki})">✕</button>
          </div>
        </div>` + "`" + `;
      });
    }
    html += '</div>';
  });
  html += '<div style="margin-top:4px"><button class="btn-secondary" onclick="addSection()">＋ Section</button></div>';
  container.innerHTML = html;
}

function setVal(si, ki, v)    { current.Sections[si].Keys[ki].Value = v; }
function renameSec(si, v)     { current.Sections[si].Name = v; }
function removeKey(si, ki)    { current.Sections[si].Keys.splice(ki,1); renderForm(); }
function removeSec(si)        { current.Sections.splice(si,1); renderForm(); }
function addSection()         { current.Sections.push({Name:'section',Keys:[]}); renderForm(); }

function openKeyModal(si) {
  pendingSection = si;
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
  document.getElementById('key-new-val').value = m ? (m.Type==='bool'?'false':m.Min||'') : '';
}
function closeKeyModal() { document.getElementById('key-modal').style.display = 'none'; }
function confirmAddKey() {
  const k = document.getElementById('key-new-key').value.trim();
  const v = document.getElementById('key-new-val').value.trim();
  if (!k) { toast('Enter a key name', true); return; }
  if (!current.Sections[pendingSection].Keys) current.Sections[pendingSection].Keys = [];
  current.Sections[pendingSection].Keys.push({Key:k,Value:v,Comment:''});
  closeKeyModal(); renderForm();
}

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
  const sections = [{Name:'',Keys:[]}]; let cur = sections[0];
  text.split('\n').forEach(raw => {
    const line = raw.trim();
    if (!line || line.startsWith('#') || line.startsWith(';')) return;
    if (line.startsWith('[') && line.endsWith(']')) { cur={Name:line.slice(1,-1),Keys:[]}; sections.push(cur); return; }
    const eq = line.indexOf('=');
    if (eq > 0) {
      const k = line.slice(0,eq).trim(); const rest = line.slice(eq+1).trim();
      let val=rest, comment='';
      for (const sep of [' #','\t#',' ;']) { const i=rest.indexOf(sep); if(i>=0){val=rest.slice(0,i).trim();comment=rest.slice(i+1).trim();break;} }
      cur.Keys.push({Key:k,Value:val,Comment:comment});
    }
  });
  return sections;
}
function syncRaw()  { document.getElementById('raw-textarea').value = iniToString(current); }
function parseRaw() { const t=document.getElementById('raw-textarea').value; if(t.trim()) current.Sections=stringToIni(t); }

async function saveFile() {
  if (!current) return;
  if (activeTab === 'raw') parseRaw();
  try { await api('PUT', '/files/'+current.Name, current); toast('Saved '+current.Name); }
  catch(e) { toast(e.message, true); }
}

function openNewModal() {
  document.getElementById('new-name').value = '';
  document.getElementById('new-modal').style.display = 'flex';
  setTimeout(() => document.getElementById('new-name').focus(), 50);
}
function closeNewModal() { document.getElementById('new-modal').style.display = 'none'; }
document.getElementById('new-modal').addEventListener('click', e => { if(e.target===document.getElementById('new-modal')) closeNewModal(); });
async function createFile() {
  const name = document.getElementById('new-name').value.trim();
  const tmpl = document.getElementById('new-template').value;
  if (!name) { toast('Enter a file name', true); return; }
  try {
    const r = await api('POST', '/files', {name, template: tmpl});
    closeNewModal(); await loadFiles(); await openFile(r.name); toast('Created '+r.name);
  } catch(e) { toast(e.message, true); }
}

function openDelModal(name) {
  deleteTarget = name;
  document.getElementById('del-name-label').textContent = name;
  document.getElementById('del-modal').style.display = 'flex';
}
function closeDelModal() { document.getElementById('del-modal').style.display='none'; deleteTarget=null; }
document.getElementById('del-modal').addEventListener('click', e => { if(e.target===document.getElementById('del-modal')) closeDelModal(); });
async function confirmDelete() {
  if (!deleteTarget) return;
  try {
    await api('DELETE', '/files/'+deleteTarget);
    closeDelModal();
    if (current && current.Name === deleteTarget) {
      current = null;
      document.getElementById('empty-state').style.display = '';
      document.getElementById('editor').style.display = 'none';
    }
    await loadFiles(); toast('Deleted');
  } catch(e) { toast(e.message, true); }
}

// ══════════════════════════════════════════════════════════
//  MODELS PANEL
// ══════════════════════════════════════════════════════════

async function loadModels(forceRescan) {
  const body = document.getElementById('models-body');
  body.innerHTML = '<div class="models-scanning"><span class="spinner"></span> Scanning…</div>';
  document.getElementById('model-count').textContent = '';
  try {
    allModels = await api('GET', '/models');
    renderModels();
  } catch(e) {
    body.innerHTML = '<div class="models-empty"><h3>Scan failed</h3><p>' + escHtml(e.message) + '</p></div>';
  }
}

// Quant → CSS class
function quantClass(q) {
  const u = q.toUpperCase();
  if (u === 'UNKNOWN') return 'q-unk';
  if (/^(IQ1|IQ2|Q2)/.test(u)) return 'q-low';
  if (/^(IQ3|Q3)/.test(u)) return 'q-mid';
  if (/^(IQ4|Q4)/.test(u)) return 'q-std';
  if (/^(Q5|Q6|Q8)/.test(u)) return 'q-hi';
  if (/^(F16|F32|BF16)/.test(u)) return 'q-fp';
  return 'q-unk';
}

function renderModels() {
  const body = document.getElementById('models-body');
  const q = (document.getElementById('model-search').value || '').toLowerCase();
  const sortBy = document.getElementById('model-sort').value;

  let list = allModels.filter(m =>
    !q || m.name.toLowerCase().includes(q) || m.quant.toLowerCase().includes(q)
  );

  list.sort((a, b) => {
    switch (sortBy) {
      case 'size-desc': return b.size - a.size;
      case 'size-asc':  return a.size - b.size;
      case 'quant':     return a.quant.localeCompare(b.quant);
      case 'date':      return b.mod_time.localeCompare(a.mod_time);
      default:          return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    }
  });

  document.getElementById('model-count').textContent =
    list.length + ' of ' + allModels.length + ' model' + (allModels.length !== 1 ? 's' : '');

  if (!list.length) {
    body.innerHTML = allModels.length
      ? '<div class="models-empty"><h3>No matches</h3><p>Try a different search term.</p></div>'
      : '<div class="models-empty"><h3>No .gguf models found</h3><p>Add model directories in the <b>Paths</b> tab then rescan.</p></div>';
    return;
  }

  const rows = list.map(m => {
    const qc = quantClass(m.quant);
    const useDisabled = !current ? 'title="Open a config file first"' : '';
    const useStyle = !current ? 'opacity:.4;cursor:default' : '';
    return ` + "`" + `<tr>
      <td class="model-name-cell">
        <span class="model-name" title="${escHtml(m.path)}">${escHtml(m.name)}</span>
        <span class="model-dir">${escHtml(m.dir)}</span>
      </td>
      <td><span class="quant-badge ${qc}">${escHtml(m.quant)}</span></td>
      <td class="model-size">${escHtml(m.size_human)}</td>
      <td class="model-date">${escHtml(m.mod_time)}</td>
      <td class="model-actions">
        <button class="btn-use" ${useDisabled} style="${useStyle}"
          onclick="useModel(${JSON.stringify(m.path)})">Use in Config</button>
        <button class="btn-copy" onclick="copyPath(${JSON.stringify(m.path)})" title="Copy path">⎘</button>
      </td>
    </tr>` + "`" + `;
  }).join('');

  body.innerHTML = ` + "`" + `<table class="model-table">
    <thead><tr>
      <th>Model</th><th>Quant</th><th style="text-align:right">Size</th>
      <th>Modified</th><th>Action</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table>` + "`" + `;
}

// Set the model= key in the currently open config
function useModel(path) {
  if (!current) { toast('Open a config file first', true); return; }
  let found = false;
  for (const sec of current.Sections) {
    for (const kv of (sec.Keys || [])) {
      if (kv.Key === 'model') { kv.Value = path; found = true; break; }
    }
    if (found) break;
  }
  if (!found) {
    // Prepend to root section
    if (!current.Sections[0]) current.Sections[0] = {Name:'',Keys:[]};
    current.Sections[0].Keys.unshift({Key:'model',Value:path,Comment:'path to GGUF model file'});
  }
  renderForm();
  switchView('configs');
  toast('Model path set in ' + current.Name);
}

function copyPath(path) {
  navigator.clipboard.writeText(path).then(() => toast('Path copied')).catch(() => toast('Copy failed', true));
}

// ══════════════════════════════════════════════════════════
//  SETTINGS / PATHS PANEL
// ══════════════════════════════════════════════════════════

async function loadPathsSettings() {
  try {
    paths = await api('GET', '/paths');
    renderPathsUI();
  } catch(e) { toast('Could not load paths: ' + e.message, true); }
}

function renderPathsUI() {
  renderPathList('model-dir-list', paths.model_search_dirs || [], 'model');
  renderPathList('binary-dir-list', paths.binary_search_dirs || [], 'binary');
  document.getElementById('save-status').textContent = '';
}

function renderPathList(containerId, dirs, type) {
  const el = document.getElementById(containerId);
  if (!dirs.length) { el.innerHTML = '<div style="color:var(--text3);font-size:11px;padding:6px 0">No directories configured.</div>'; return; }
  el.innerHTML = dirs.map((d, i) => {
    // We can't check existence from JS, so show a neutral dot
    return ` + "`" + `<div class="path-row">
      <span class="path-exists-dot dot-no"></span>
      <span class="path-text">${escHtml(d)}</span>
      <button class="btn-remove-path" onclick="removePath('${type}',${i})" title="Remove">✕</button>
    </div>` + "`" + `;
  }).join('');
}

function addModelDir() {
  const inp = document.getElementById('new-model-dir');
  const v = inp.value.trim();
  if (!v) return;
  if (!paths.model_search_dirs) paths.model_search_dirs = [];
  if (!paths.model_search_dirs.includes(v)) { paths.model_search_dirs.push(v); renderPathsUI(); }
  inp.value = '';
}

function addBinaryDir() {
  const inp = document.getElementById('new-binary-dir');
  const v = inp.value.trim();
  if (!v) return;
  if (!paths.binary_search_dirs) paths.binary_search_dirs = [];
  if (!paths.binary_search_dirs.includes(v)) { paths.binary_search_dirs.push(v); renderPathsUI(); }
  inp.value = '';
}

function removePath(type, idx) {
  if (type === 'model')  paths.model_search_dirs.splice(idx, 1);
  if (type === 'binary') paths.binary_search_dirs.splice(idx, 1);
  renderPathsUI();
}

async function savePaths() {
  const st = document.getElementById('save-status');
  try {
    const r = await api('PUT', '/paths', paths);
    st.className = 'save-status ok';
    st.textContent = '✔ Saved to ' + (r.saved || 'paths.json');
    document.getElementById('paths-json-info').innerHTML =
      'Shared with llama_manager.sh → <code>' + escHtml(r.saved || 'paths.json') + '</code>';
    toast('Paths saved');
  } catch(e) {
    st.className = 'save-status err';
    st.textContent = '✘ ' + e.message;
    toast(e.message, true);
  }
}

async function resetPaths() {
  if (!confirm('Reset to default paths? This will overwrite paths.json.')) return;
  try {
    const defaults = await api('GET', '/paths'); // re-fetch; if no file it returns defaults
    // Actually call reset by saving the server defaults
    paths = defaults;
    renderPathsUI();
    toast('Reset to defaults (not yet saved — click Save)');
  } catch(e) { toast(e.message, true); }
}

// ── Keyboard shortcuts ────────────────────────────────────────────────────────
document.addEventListener('keydown', e => {
  if ((e.ctrlKey||e.metaKey) && e.key==='s') { e.preventDefault(); saveFile(); }
  if (e.key==='Escape') { closeNewModal(); closeDelModal(); closeKeyModal(); }
  if ((e.ctrlKey||e.metaKey) && e.key==='n') { e.preventDefault(); openNewModal(); }
});
document.getElementById('new-name').addEventListener('keydown', e => { if(e.key==='Enter') createFile(); });

// ── Toast ─────────────────────────────────────────────────────────────────────
function toast(msg, err=false) {
  const el = document.createElement('div');
  el.className = 'toast ' + (err ? 'err' : 'ok');
  el.textContent = (err ? '✗ ' : '✓ ') + msg;
  document.getElementById('toast-area').appendChild(el);
  setTimeout(() => el.remove(), 3200);
}

// ── Utility ───────────────────────────────────────────────────────────────────
function escHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
</script>
</body>
</html>
`
