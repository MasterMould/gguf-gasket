package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// GasketState mirrors ~/ai_stack/selected.env.
// Written by shared_state.sh, manager.sh and this web app; read by all.
type GasketState struct {
	Model  string `json:"model"`
	Config string `json:"config"`
	Binary string `json:"binary"`
	Port   string `json:"port"`
}

func gasketStateFile() string {
	if f := os.Getenv("GASKET_STATE_FILE"); f != "" {
		return f
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "ai_stack", "selected.env")
}

func loadGasketState() GasketState {
	st := GasketState{Port: "8080"}
	f, err := os.Open(gasketStateFile())
	if err != nil {
		return st
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		k, v := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
		switch k {
		case "STATE_MODEL":
			st.Model = v
		case "STATE_CONFIG":
			st.Config = v
		case "STATE_BINARY":
			st.Binary = v
		case "STATE_PORT":
			st.Port = v
		}
	}
	return st
}

func saveGasketState(st GasketState) error {
	home, _ := os.UserHomeDir()
	os.MkdirAll(filepath.Join(home, "ai_stack"), 0755)
	content := fmt.Sprintf(
		"# gguf-gasket state\nSTATE_MODEL=%s\nSTATE_CONFIG=%s\nSTATE_BINARY=%s\nSTATE_PORT=%s\n",
		st.Model, st.Config, st.Binary, st.Port,
	)
	return os.WriteFile(gasketStateFile(), []byte(content), 0644)
}
