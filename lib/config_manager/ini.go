package main

import (
	"fmt"
	"strings"
)

// IniSection represents a named section in an INI file.
type IniSection struct {
	Name string
	Keys []IniKey
}

// IniKey is a single key=value pair.
type IniKey struct {
	Key     string
	Value   string
	Comment string
}

// IniFile is the full in-memory representation of a .ini file.
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
