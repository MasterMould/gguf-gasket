package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// BuildConfig holds the cmake options chosen in the Build panel.
type BuildConfig struct {
	SourceDir  string            `json:"source_dir"`
	BuildDir   string            `json:"build_dir"`
	Flags      map[string]bool   `json:"flags"`
	Parallel   int               `json:"parallel"`
}

// BuildStatus is returned by GET /api/build/status.
type BuildStatus struct {
	Running   bool   `json:"running"`
	Success   *bool  `json:"success,omitempty"`
	StartedAt string `json:"started_at,omitempty"`
	Duration  string `json:"duration,omitempty"`
	LogFile   string `json:"log_file"`
}

var buildLogFile = filepath.Join(os.Getenv("HOME"), "ai_stack", "build.log")

var (
	buildMu      sync.Mutex
	buildRunning bool
	buildSuccess *bool
	buildStart   time.Time
)

func buildStatus() BuildStatus {
	buildMu.Lock()
	defer buildMu.Unlock()
	st := BuildStatus{
		Running: buildRunning,
		Success: buildSuccess,
		LogFile: buildLogFile,
	}
	if !buildStart.IsZero() {
		st.StartedAt = buildStart.Format(time.RFC3339)
		if !buildRunning {
			st.Duration = time.Since(buildStart).Round(time.Second).String()
		}
	}
	return st
}

// streamBuild runs cmake + make and streams stdout/stderr as SSE lines.
func streamBuild(w http.ResponseWriter, cfg BuildConfig) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		return
	}

	buildMu.Lock()
	if buildRunning {
		buildMu.Unlock()
		sseEvent(w, "error", "build already in progress")
		flusher.Flush()
		return
	}
	buildRunning = true
	buildSuccess = nil
	buildStart = time.Now()
	buildMu.Unlock()

	done := func(success bool) {
		buildMu.Lock()
		buildRunning = false
		v := success
		buildSuccess = &v
		buildMu.Unlock()
	}

	// Ensure build log directory exists
	os.MkdirAll(filepath.Dir(buildLogFile), 0755)
	logF, _ := os.OpenFile(buildLogFile, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)

	send := func(line string) {
		sseEvent(w, "log", line)
		flusher.Flush()
		if logF != nil {
			fmt.Fprintln(logF, line)
		}
	}

	src := expandHome(cfg.SourceDir)
	bld := expandHome(cfg.BuildDir)
	if bld == "" {
		bld = filepath.Join(src, "build")
	}

	// Build cmake arguments from flags
	cmakeArgs := []string{"-B", bld, "-S", src, "-DCMAKE_BUILD_TYPE=Release"}
	flagNames := map[string]string{
		"sycl":       "GGML_SYCL",
		"vulkan":     "GGML_VULKAN",
		"opencl":     "GGML_OPENCL",
		"cuda":       "GGML_CUDA",
		"metal":      "GGML_METAL",
		"avx":        "GGML_AVX",
		"avx2":       "GGML_AVX2",
		"avx512":     "GGML_AVX512",
		"f16c":       "GGML_F16C",
		"fma":        "GGML_FMA",
		"flash_attn": "GGML_FLASH_ATTN",
		"sycl_f16":   "GGML_SYCL_F16",
	}
	for key, cmake := range flagNames {
		if cfg.Flags[key] {
			cmakeArgs = append(cmakeArgs, fmt.Sprintf("-D%s=ON", cmake))
		} else if _, explicit := cfg.Flags[key]; explicit {
			cmakeArgs = append(cmakeArgs, fmt.Sprintf("-D%s=OFF", cmake))
		}
	}
	if cfg.Flags["sycl"] {
		cmakeArgs = append(cmakeArgs,
			"-DCMAKE_C_COMPILER=icx",
			"-DCMAKE_CXX_COMPILER=icpx",
		)
	}

	send("=== cmake configure ===")
	send(fmt.Sprintf("cmake %s", strings.Join(cmakeArgs, " ")))

	if err := runStreaming(send, "cmake", cmakeArgs...); err != nil {
		send(fmt.Sprintf("ERROR: cmake failed: %v", err))
		sseEvent(w, "done", `{"success":false}`)
		flusher.Flush()
		done(false)
		if logF != nil {
			logF.Close()
		}
		return
	}

	npar := cfg.Parallel
	if npar <= 0 {
		npar = 4
	}
	send(fmt.Sprintf("\n=== make -j%d ===", npar))

	makeArgs := []string{"-C", bld, fmt.Sprintf("-j%d", npar)}
	if err := runStreaming(send, "make", makeArgs...); err != nil {
		send(fmt.Sprintf("ERROR: make failed: %v", err))
		sseEvent(w, "done", `{"success":false}`)
		flusher.Flush()
		done(false)
		if logF != nil {
			logF.Close()
		}
		return
	}

	send("=== build complete ===")
	out, _ := json.Marshal(map[string]interface{}{"success": true, "bin": filepath.Join(bld, "bin", "llama-server")})
	sseEvent(w, "done", string(out))
	flusher.Flush()
	done(true)
	if logF != nil {
		logF.Close()
	}
}

// runStreaming runs cmd and sends each output line via the send function.
func runStreaming(send func(string), name string, args ...string) error {
	cmd := exec.Command(name, args...)
	stdout, _ := cmd.StdoutPipe()
	cmd.Stderr = cmd.Stdout // merge
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		send(scanner.Text())
	}
	return cmd.Wait()
}

func sseEvent(w http.ResponseWriter, event, data string) {
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
}
