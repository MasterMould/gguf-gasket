package main

import (
	"encoding/json"
	"html/template"
)

// ParamMeta describes a known llama.cpp CLI parameter for the form editor.
type ParamMeta struct {
	Key, Label, Description, Type, Min, Max, Step string
}

// knownParams is the master list of supported llama.cpp parameters.
var knownParams = []ParamMeta{
	// ── Model ──
	{Key: "model", Label: "Model Path", Description: "Path to the .gguf model file", Type: "path"},
	// ── Context ──
	{Key: "ctx-size", Label: "Context Size", Description: "Token context window. Larger = more VRAM.", Type: "number", Min: "128", Max: "131072", Step: "128"},
	{Key: "batch-size", Label: "Batch Size", Description: "Prompt processing batch size.", Type: "number", Min: "1", Max: "4096", Step: "1"},
	{Key: "ubatch-size", Label: "Micro-batch Size", Description: "Physical max batch size.", Type: "number", Min: "1", Max: "4096", Step: "1"},
	// ── GPU ──
	{Key: "n-gpu-layers", Label: "GPU Layers", Description: "Layers offloaded to GPU. 0=CPU only, -1=all.", Type: "number", Min: "-1", Max: "200", Step: "1"},
	{Key: "main-gpu", Label: "Main GPU", Description: "Primary GPU index for multi-GPU.", Type: "number", Min: "0", Max: "16", Step: "1"},
	{Key: "tensor-split", Label: "Tensor Split", Description: "Comma-separated GPU split ratios.", Type: "text"},
	// ── CPU ──
	{Key: "threads", Label: "CPU Threads", Description: "Threads for generation.", Type: "number", Min: "1", Max: "256", Step: "1"},
	{Key: "threads-batch", Label: "Batch Threads", Description: "Threads for prompt evaluation.", Type: "number", Min: "1", Max: "256", Step: "1"},
	// ── Sampling ──
	{Key: "temperature", Label: "Temperature", Description: "Randomness. Lower=focused, higher=creative.", Type: "number", Min: "0.0", Max: "2.0", Step: "0.01"},
	{Key: "top-p", Label: "Top-P", Description: "Nucleus sampling probability threshold.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "top-k", Label: "Top-K", Description: "Limit to top K most likely tokens.", Type: "number", Min: "0", Max: "200", Step: "1"},
	{Key: "min-p", Label: "Min-P", Description: "Minimum probability relative to top token.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "repeat-penalty", Label: "Repeat Penalty", Description: "Penalise repetition. 1.0=off.", Type: "number", Min: "1.0", Max: "2.0", Step: "0.01"},
	{Key: "repeat-last-n", Label: "Repeat Last N", Description: "Window for repeat penalty. 0=disabled.", Type: "number", Min: "0", Max: "512", Step: "1"},
	{Key: "tfs-z", Label: "TFS Z", Description: "Tail free sampling. 1.0=disabled.", Type: "number", Min: "1.0", Max: "2.0", Step: "0.01"},
	{Key: "typical-p", Label: "Typical-P", Description: "Locally typical sampling. 1.0=disabled.", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "mirostat", Label: "Mirostat Mode", Description: "0=off, 1=v1, 2=v2.", Type: "number", Min: "0", Max: "2", Step: "1"},
	{Key: "mirostat-lr", Label: "Mirostat LR", Description: "Mirostat learning rate (eta).", Type: "number", Min: "0.0", Max: "1.0", Step: "0.01"},
	{Key: "mirostat-ent", Label: "Mirostat Entropy", Description: "Mirostat target entropy (tau).", Type: "number", Min: "0.0", Max: "10.0", Step: "0.1"},
	// ── Generation ──
	{Key: "n-predict", Label: "Max Tokens", Description: "Max tokens to generate. -1=unlimited.", Type: "number", Min: "-1", Max: "32768", Step: "1"},
	{Key: "seed", Label: "Seed", Description: "RNG seed. -1=random.", Type: "number", Min: "-1", Max: "2147483647", Step: "1"},
	// ── Server ──
	{Key: "host", Label: "Host", Description: "Server bind address.", Type: "text"},
	{Key: "port", Label: "Port", Description: "Server listen port.", Type: "number", Min: "1", Max: "65535", Step: "1"},
	{Key: "timeout", Label: "Timeout (s)", Description: "Request timeout in seconds.", Type: "number", Min: "1", Max: "600", Step: "1"},
	{Key: "parallel", Label: "Parallel Slots", Description: "Number of parallel request slots.", Type: "number", Min: "1", Max: "64", Step: "1"},
	{Key: "cont-batching", Label: "Continuous Batching", Description: "Enable continuous batching for throughput.", Type: "bool"},
	{Key: "slots-endpoint", Label: "Slots Endpoint", Description: "Enable /slots monitoring endpoint.", Type: "bool"},
	// ── Features ──
	{Key: "embedding", Label: "Embedding Mode", Description: "Enable embedding endpoint.", Type: "bool"},
	{Key: "reranking", Label: "Reranking", Description: "Enable reranking endpoint.", Type: "bool"},
	{Key: "flash-attn", Label: "Flash Attention", Description: "Enable Flash Attention (SYCL/CUDA).", Type: "bool"},
	{Key: "no-mmap", Label: "No Memory Map", Description: "Disable memory-mapped loading.", Type: "bool"},
	{Key: "mlock", Label: "Memory Lock", Description: "Lock model in RAM (prevents swapping).", Type: "bool"},
	{Key: "numa", Label: "NUMA", Description: "Enable NUMA-aware memory allocation.", Type: "bool"},
	{Key: "cache-type-k", Label: "KV Cache Type K", Description: "Key cache quantisation: f16, q8_0, q4_0.", Type: "text"},
	{Key: "cache-type-v", Label: "KV Cache Type V", Description: "Value cache quantisation: f16, q8_0, q4_0.", Type: "text"},
	{Key: "defrag-thold", Label: "Defrag Threshold", Description: "KV cache defrag threshold. -1=disabled.", Type: "number", Min: "-1", Max: "1", Step: "0.01"},
	// ── Logging ──
	{Key: "log-disable", Label: "Disable Log", Description: "Suppress log output.", Type: "bool"},
	{Key: "verbose", Label: "Verbose", Description: "Enable verbose output.", Type: "bool"},
	{Key: "log-format", Label: "Log Format", Description: "Log output format: text or json.", Type: "text"},
}

func paramMetaJSON() template.JS {
	b, _ := json.Marshal(knownParams)
	return template.JS(b)
}

// templateFile returns a pre-filled IniFile for the named starter template.
func templateFile(name, tmpl string) IniFile {
	switch tmpl {
	case "server":
		return IniFile{Name: name, Sections: []IniSection{{Keys: []IniKey{
			{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
			{Key: "host", Value: "127.0.0.1", Comment: "listen address"},
			{Key: "port", Value: "8080", Comment: "listen port"},
			{Key: "ctx-size", Value: "4096", Comment: "context window tokens"},
			{Key: "n-gpu-layers", Value: "0", Comment: "layers offloaded to GPU"},
			{Key: "threads", Value: "4", Comment: "CPU threads"},
			{Key: "batch-size", Value: "512", Comment: "prompt batch size"},
			{Key: "cont-batching", Value: "true", Comment: "continuous batching"},
			{Key: "parallel", Value: "4", Comment: "parallel request slots"},
		}}}}
	case "chat":
		return IniFile{Name: name, Sections: []IniSection{{Keys: []IniKey{
			{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
			{Key: "ctx-size", Value: "4096"},
			{Key: "n-gpu-layers", Value: "0"},
			{Key: "threads", Value: "4"},
			{Key: "temperature", Value: "0.8"},
			{Key: "top-p", Value: "0.9"},
			{Key: "top-k", Value: "40"},
			{Key: "repeat-penalty", Value: "1.1"},
			{Key: "n-predict", Value: "-1"},
			{Key: "seed", Value: "-1"},
		}}}}
	case "embedding":
		return IniFile{Name: name, Sections: []IniSection{{Keys: []IniKey{
			{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
			{Key: "ctx-size", Value: "2048"},
			{Key: "n-gpu-layers", Value: "0"},
			{Key: "threads", Value: "4"},
			{Key: "embedding", Value: "true"},
			{Key: "batch-size", Value: "512"},
		}}}}
	case "arc-a770":
		return IniFile{Name: name, Sections: []IniSection{{Keys: []IniKey{
			{Key: "model", Value: "/home/first/ai_stack/models/your-model.gguf", Comment: "path to GGUF model file"},
			{Key: "n-gpu-layers", Value: "85", Comment: "85/99 — keeps ~2GB for SYCL scratch (prevents OOM)"},
			{Key: "ctx-size", Value: "4096", Comment: "safe KV footprint on Arc A770 16GB"},
			{Key: "batch-size", Value: "256", Comment: "lower peak alloc during prompt processing"},
			{Key: "threads", Value: "4"},
			{Key: "flash-attn", Value: "true", Comment: "faster on Arc SYCL"},
			{Key: "cont-batching", Value: "true"},
			{Key: "temperature", Value: "0.7"},
			{Key: "top-p", Value: "0.9"},
			{Key: "repeat-penalty", Value: "1.1"},
			{Key: "n-predict", Value: "-1"},
			{Key: "seed", Value: "-1"},
		}}}}
	default:
		return IniFile{Name: name, Sections: []IniSection{{Keys: []IniKey{
			{Key: "model", Value: "/path/to/model.gguf", Comment: "path to GGUF model file"},
		}}}}
	}
}
