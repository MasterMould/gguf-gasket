package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// PathsConfig is the single source of truth for model and binary search dirs.
// Shared with manager.sh via ~/ai_stack/paths.json.
type PathsConfig struct {
	ModelSearchDirs  []string `json:"model_search_dirs"`
	BinarySearchDirs []string `json:"binary_search_dirs"`
}

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
			"/opt/models", "/opt/ai/models", "/var/lib/models", "/srv/models",
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
			"/opt/llama.cpp/bin", "/opt/llama.cpp",
			"/usr/local/bin", "/usr/bin",
		},
	}
}

// pathsFile returns ~/ai_stack/paths.json when inside gguf-gasket,
// otherwise falls back to the directory beside the binary.
func pathsFile() string {
	home, herr := os.UserHomeDir()
	if herr == nil {
		if _, err := os.Stat(filepath.Join(home, "ai_stack")); err == nil {
			return filepath.Join(home, "ai_stack", "paths.json")
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
