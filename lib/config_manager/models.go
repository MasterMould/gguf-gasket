package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type ModelInfo struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	SizeHuman string `json:"size_human"`
	Quant     string `json:"quant"`
	Dir       string `json:"dir"`
	ModTime   string `json:"mod_time"`
}

type BinaryInfo struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

var quantRe = regexp.MustCompile(`(?i)(IQ[0-9]_[A-Z_]+|Q[0-9]+_[A-Z0-9_]+|BF16|F16|F32)`)

var llamaBinNames = []string{"llama-server", "llama-cli", "llama-bench", "server", "main"}

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
		return "0K"
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
	if extra := os.Getenv("GASKET_MODEL_DIR"); extra != "" {
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
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(root, path)
			depth := strings.Count(rel, string(os.PathSeparator))
			if d.IsDir() {
				if depth >= maxScanDepth || d.Name() == ".git" {
					return fs.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(strings.ToLower(d.Name()), ".gguf") {
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

func scanBinaries(dirs []string) []BinaryInfo {
	var bins []BinaryInfo
	seen := map[string]bool{}
	for _, dir := range dirs {
		dir = expandHome(dir)
		for _, name := range llamaBinNames {
			p := filepath.Join(dir, name)
			info, err := os.Stat(p)
			if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
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
