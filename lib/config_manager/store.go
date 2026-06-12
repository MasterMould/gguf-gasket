package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Store handles config .ini file CRUD in a single directory.
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

// sanitiseName cleans up a user-supplied config name.
func sanitiseName(raw string) string {
	s := strings.TrimSpace(strings.ReplaceAll(raw, " ", "-"))
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
