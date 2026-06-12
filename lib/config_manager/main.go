package main

import (
	_ "embed"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"strconv"
)

//go:embed app.html
var appHTML string

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
	}).Parse(appHTML))

	h := &Handler{store: store}

	mux := http.NewServeMux()

	// SPA
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		tmpl.Execute(w, nil)
	})

	// Config CRUD
	mux.HandleFunc("GET /api/files",          h.listFiles)
	mux.HandleFunc("GET /api/files/{name}",   h.getFile)
	mux.HandleFunc("POST /api/files",         h.createFile)
	mux.HandleFunc("PUT /api/files/{name}",   h.updateFile)
	mux.HandleFunc("DELETE /api/files/{name}", h.deleteFile)

	// Models & binaries
	mux.HandleFunc("GET /api/models",    h.listModels)
	mux.HandleFunc("GET /api/binaries",  h.listBinaries)

	// Paths
	mux.HandleFunc("GET /api/paths", h.getPaths)
	mux.HandleFunc("PUT /api/paths", h.putPaths)

	// Shared gasket state
	mux.HandleFunc("GET /api/state", h.getState)
	mux.HandleFunc("PUT /api/state", h.putState)

	// Gasket settings
	mux.HandleFunc("GET /api/settings", h.getSettings)
	mux.HandleFunc("PUT /api/settings", h.putSettings)

	// Arc GPU
	mux.HandleFunc("GET /api/arc/status",  h.arcStatus)
	mux.HandleFunc("POST /api/arc/fix",    h.arcFix)

	// llama-server lifecycle
	mux.HandleFunc("GET /api/server/status",  h.serverStatusHandler)
	mux.HandleFunc("POST /api/server/start",  h.serverStart)
	mux.HandleFunc("POST /api/server/stop",   h.serverStop)
	mux.HandleFunc("GET /api/server/log",     h.serverLog)

	// Chat (SSE streaming)
	mux.HandleFunc("POST /api/chat",        h.chatStream)
	mux.HandleFunc("GET /api/chat/models",  h.chatModels)

	// Build (SSE streaming)
	mux.HandleFunc("POST /api/build/start",   h.buildStart)
	mux.HandleFunc("GET /api/build/status",   h.buildStatusHandler)

	// Logs (SSE + tail + clear)
	mux.HandleFunc("GET /api/logs/{name}",        h.logTail)
	mux.HandleFunc("GET /api/logs/{name}/stream", h.logStream)
	mux.HandleFunc("DELETE /api/logs/{name}",     h.logClear)

	// Downloads
	mux.HandleFunc("POST /api/downloads",                h.downloadStart)
	mux.HandleFunc("GET /api/downloads",                 h.listDownloads)
	mux.HandleFunc("GET /api/downloads/{id}",            h.downloadStatus)
	mux.HandleFunc("GET /api/downloads/{id}/stream",     h.downloadStream)

	addr := ":" + port
	fmt.Printf("gguf-gasket config manager  →  http://localhost%s\n", addr)
	fmt.Printf("configs dir   →  %s\n", dir)
	fmt.Printf("paths.json    →  %s\n", pathsFile())
	fmt.Printf("state file    →  %s\n", gasketStateFile())
	log.Fatal(http.ListenAndServe(addr, mux))
}
