package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ArcStatus is a snapshot of the Intel Arc GPU stack health.
type ArcStatus struct {
	Detected    bool   `json:"detected"`
	PCIAddr     string `json:"pci_addr"`
	DriverOK    bool   `json:"driver_ok"`
	DriverName  string `json:"driver_name"`
	RenderOK    bool   `json:"render_ok"`
	GroupsOK    bool   `json:"groups_ok"`
	OpenCLOK    bool   `json:"opencl_ok"`
	LevelZeroOK bool   `json:"level_zero_ok"`
	SYCLOK      bool   `json:"sycl_ok"`
	Summary     string `json:"summary"`
}

var arcPCIIDs = []string{
	"56a0", "56a1", "56a5", "56a6",
	"5690", "5691", "5692",
	"56b0", "56b1", "56c0", "56c1",
}

func queryArcStatus() ArcStatus {
	st := ArcStatus{}

	// GPU detection via lspci
	out, _ := exec.Command("lspci", "-nn").Output()
	for _, id := range arcPCIIDs {
		for _, line := range strings.Split(string(out), "\n") {
			if strings.Contains(strings.ToLower(line), "8086:"+id) {
				st.Detected = true
				if parts := strings.Fields(line); len(parts) > 0 {
					st.PCIAddr = parts[0]
				}
				break
			}
		}
		if st.Detected {
			break
		}
	}
	if !st.Detected {
		st.Summary = "Arc GPU not detected"
		return st
	}

	// Kernel driver
	lsmod, _ := exec.Command("lsmod").Output()
	for _, drv := range []string{"xe", "i915"} {
		if strings.Contains(string(lsmod), drv+" ") {
			st.DriverOK = true
			st.DriverName = drv
			break
		}
	}

	// Render node access
	matches, _ := filepath.Glob("/dev/dri/renderD*")
	if len(matches) > 0 {
		f, err := os.OpenFile(matches[0], os.O_RDWR, 0)
		if err == nil {
			f.Close()
			st.RenderOK = true
		}
	}

	// Group membership
	user := os.Getenv("USER")
	for _, grp := range []string{"render", "video"} {
		out, err := exec.Command("id", "-nG", user).Output()
		if err == nil && strings.Contains(string(out), grp) {
			st.GroupsOK = true
		}
	}

	// OpenCL — use -E flag for portable alternation
	if clout, err := exec.Command("clinfo").Output(); err == nil {
		for _, line := range strings.Split(string(clout), "\n") {
			if strings.Contains(strings.ToLower(line), "device name") &&
				(strings.Contains(strings.ToLower(line), "intel") ||
					strings.Contains(strings.ToLower(line), "arc")) {
				st.OpenCLOK = true
				break
			}
		}
	}

	// Level Zero: apt package OR oneAPI-bundled
	dpkgOut, _ := exec.Command("dpkg", "-l", "libze-intel-gpu1").Output()
	st.LevelZeroOK = strings.Contains(string(dpkgOut), "ii")
	if !st.LevelZeroOK {
		// Check via oneAPI
		for _, root := range []string{"/opt/intel/oneapi", "/opt/intel/inteloneapi"} {
			if _, err := os.Stat(filepath.Join(root, "setvars.sh")); err == nil {
				st.LevelZeroOK = true
				break
			}
		}
	}

	// SYCL (best-effort: check if sycl-ls is reachable via oneAPI)
	for _, root := range []string{"/opt/intel/oneapi", "/opt/intel/inteloneapi"} {
		sv := filepath.Join(root, "setvars.sh")
		if _, err := os.Stat(sv); err != nil {
			continue
		}
		syclOut, err := exec.Command("bash", "-c",
			fmt.Sprintf("source '%s' --force &>/dev/null && ONEAPI_DEVICE_SELECTOR='level_zero:*' sycl-ls 2>/dev/null", sv),
		).Output()
		if err == nil {
			lower := strings.ToLower(string(syclOut))
			if strings.Contains(lower, "intel") || strings.Contains(lower, "arc") {
				st.SYCLOK = true
			}
		}
		break
	}

	issues := 0
	if !st.DriverOK {
		issues++
	}
	if !st.RenderOK {
		issues++
	}
	if !st.GroupsOK {
		issues++
	}
	if issues == 0 {
		st.Summary = fmt.Sprintf("OK — driver=%s", st.DriverName)
	} else {
		st.Summary = fmt.Sprintf("%d issue(s) — run Arc Fix from menu", issues)
	}
	return st
}
