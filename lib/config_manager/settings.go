package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// GasketSettings mirrors the gasket's settings.env file (Context, Port, etc.)
type GasketSettings struct {
	ContextSize    string `json:"context_size"`
	NetworkPort    string `json:"network_port"`
	VisibleNetwork string `json:"visible_to_network"` // "0.0.0.0" or "127.0.0.1"
	APIKeyMode     string `json:"api_key_mode"`
	NGPULayers     string `json:"n_gpu_layers"`
}

func gasketSettingsFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "ai_stack", "settings.env")
}

func loadGasketSettings() GasketSettings {
	s := GasketSettings{
		ContextSize:    "8192",
		NetworkPort:    "8080",
		VisibleNetwork: "127.0.0.1",
		NGPULayers:     "99",
	}
	f, err := os.Open(gasketSettingsFile())
	if err != nil {
		return s
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
		case "context_size":
			s.ContextSize = v
		case "network_port":
			s.NetworkPort = v
		case "visible2network":
			s.VisibleNetwork = v
		case "api_key_mode":
			s.APIKeyMode = v
		case "ngl":
			s.NGPULayers = v
		}
	}
	return s
}

func saveGasketSettings(s GasketSettings) error {
	existing := loadGasketSettings()

	// Merge — only overwrite known fields, preserve everything else in file
	lines := []string{}
	f, err := os.Open(gasketSettingsFile())
	if err == nil {
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			lines = append(lines, scanner.Text())
		}
		f.Close()
	}
	_ = existing

	updates := map[string]string{
		"context_size":   s.ContextSize,
		"network_port":   s.NetworkPort,
		"visible2network": s.VisibleNetwork,
		"api_key_mode":   s.APIKeyMode,
		"ngl":            s.NGPULayers,
	}

	newLines := []string{}
	seen := map[string]bool{}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") || trimmed == "" {
			newLines = append(newLines, line)
			continue
		}
		parts := strings.SplitN(trimmed, "=", 2)
		if len(parts) == 2 {
			k := strings.TrimSpace(parts[0])
			if val, ok := updates[k]; ok {
				newLines = append(newLines, k+"="+val)
				seen[k] = true
				continue
			}
		}
		newLines = append(newLines, line)
	}
	// Append any keys not already in file
	for k, v := range updates {
		if !seen[k] && v != "" {
			newLines = append(newLines, k+"="+v)
		}
	}

	content := strings.Join(newLines, "\n") + "\n"
	return os.WriteFile(gasketSettingsFile(), []byte(content), 0644)
}
