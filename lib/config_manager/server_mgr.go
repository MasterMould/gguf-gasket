package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ServerStatus is the current state of a running (or stopped) llama-server.
type ServerStatus struct {
	Running bool   `json:"running"`
	PID     int    `json:"pid"`
	Port    string `json:"port"`
	Model   string `json:"model_name"`
	Config  string `json:"config_name"`
	Uptime  string `json:"uptime"`
	LogFile string `json:"log_file"`
}

// ServerStartReq carries the parameters for starting llama-server.
type ServerStartReq struct {
	Config string `json:"config"` // .ini filename in store dir
	Model  string `json:"model"`  // override model path
	Binary string `json:"binary"` // override binary path
	Port   string `json:"port"`
	Extra  string `json:"extra"` // additional raw CLI args
}

func serverPIDFile() string {
	if f := os.Getenv("GASKET_SERVER_PID_FILE"); f != "" {
		return f
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "ai_stack", "server.pid")
}

func serverLogFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "ai_stack", "server.log")
}

func serverStatus() ServerStatus {
	st := ServerStatus{LogFile: serverLogFile()}
	data, err := os.ReadFile(serverPIDFile())
	if err != nil {
		return st
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return st
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return st
	}
	if err := proc.Signal(nil); err != nil {
		os.Remove(serverPIDFile())
		return st
	}
	st.Running = true
	st.PID = pid
	if info, err := os.Stat(serverPIDFile()); err == nil {
		st.Uptime = time.Since(info.ModTime()).Round(time.Second).String()
	}
	gs := loadGasketState()
	st.Port = gs.Port
	st.Model = filepath.Base(gs.Model)
	st.Config = filepath.Base(gs.Config)
	return st
}

// iniToArgs converts an IniFile to llama-server CLI flags.
// The model key is excluded; callers pass --model separately.
func iniToArgs(f IniFile) []string {
	var args []string
	for _, sec := range f.Sections {
		for _, kv := range sec.Keys {
			if kv.Key == "model" {
				continue
			}
			switch strings.ToLower(kv.Value) {
			case "true", "1":
				args = append(args, "--"+kv.Key)
			case "false", "0", "":
				// omit
			default:
				args = append(args, "--"+kv.Key, kv.Value)
			}
		}
	}
	return args
}

// findBinary searches default locations for llama-server.
func findBinary() string {
	cfg := loadPaths()
	for _, dir := range cfg.BinarySearchDirs {
		p := filepath.Join(expandHome(dir), "llama-server")
		if info, err := os.Stat(p); err == nil && info.Mode()&0o111 != 0 {
			return p
		}
	}
	// PATH search
	if p, err := exec.LookPath("llama-server"); err == nil {
		return p
	}
	return ""
}
