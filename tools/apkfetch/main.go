// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ian Spray

package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const defaultMirror = "https://dl-cdn.alpinelinux.org/alpine"

type Config struct {
	Mirror    string
	Version   string
	Arch      string
	CacheDir  string
	ScanPaths []string
	Verbose   bool
	NoIndex   bool
}

func archDir(cfg *Config) string {
	return filepath.Join(cfg.CacheDir, cfg.Arch)
}

type Package struct {
	Name     string
	Version  string
	Arch     string
	File     string
	Deps     []string // raw dep tokens from D: line, unparsed
	Provides []string // tokens from p: line (e.g. "so:libcap.so.2=2.70")
	Repo     string
	Raw      string
}

// Index maps package name -> Package
type Index map[string]*Package

// parseAPKINDEX parses the stanza-based APKINDEX.
// Preserves raw stanza lines for re-emission.
// Also builds a provides map: virtual name -> Package.
func parseAPKINDEX(r io.Reader, repo string) (idx Index, provides map[string]*Package, err error) {
	idx = make(Index)
	provides = make(map[string]*Package)
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 4<<20), 4<<20)

	var pkg *Package
	var rawLines []string

	flush := func() {
		if pkg != nil && pkg.Name != "" {
			pkg.Raw = strings.Join(rawLines, "\n") + "\n"
			idx[pkg.Name] = pkg
			for _, prov := range pkg.Provides {
				// strip version constraint from provide token
				name := strings.SplitN(prov, "=", 2)[0]
				name = strings.SplitN(name, ">", 2)[0]
				name = strings.SplitN(name, "<", 2)[0]
				if _, exists := provides[name]; !exists {
					provides[name] = pkg
				}
			}
		}
		pkg = nil
		rawLines = nil
	}

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			flush()
			continue
		}
		if len(line) < 3 || line[1] != ':' {
			continue
		}
		rawLines = append(rawLines, line)
		if pkg == nil {
			pkg = &Package{Repo: repo}
		}
		key := line[0]
		val := strings.TrimSpace(line[2:])
		switch key {
		case 'P':
			pkg.Name = val
		case 'V':
			pkg.Version = val
		case 'A':
			pkg.Arch = val
		case 'D':
			pkg.Deps = strings.Fields(val)
		case 'p':
			pkg.Provides = strings.Fields(val)
		}
	}
	flush()

	for _, p := range idx {
		if p.Arch == "" {
			p.Arch = "x86_64"
		}
		p.File = fmt.Sprintf("%s-%s.apk", p.Name, p.Version)
	}
	return idx, provides, scanner.Err()
}

func fetchIndex(cfg *Config, repo string) (Index, map[string]*Package, error) {
	url := fmt.Sprintf("%s/%s/%s/%s/APKINDEX.tar.gz", cfg.Mirror, cfg.Version, repo, cfg.Arch)
	logf(cfg, "fetching index %s", url)

	resp, err := http.Get(url)
	if err != nil {
		return nil, nil, fmt.Errorf("fetch %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, nil, fmt.Errorf("fetch %s: HTTP %d", url, resp.StatusCode)
	}

	gz, err := gzip.NewReader(resp.Body)
	if err != nil {
		return nil, nil, err
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, nil, err
		}
		if hdr.Name == "APKINDEX" {
			return parseAPKINDEX(tr, repo)
		}
	}
	return nil, nil, fmt.Errorf("APKINDEX entry not found in %s", url)
}

var constraintRe = regexp.MustCompile(`[><=~!].*`)

// lookupDep resolves a single dep token (which may be a package name,
// a virtual provide like "so:libfoo.so.1", or "cmd:foo") to a Package.
func lookupDep(token string, mainIdx, communityIdx Index, mainProv, communityProv map[string]*Package) *Package {
	// strip version constraint
	name := constraintRe.ReplaceAllString(token, "")
	if name == "" {
		return nil
	}

	// direct package name
	if p := mainIdx[name]; p != nil {
		return p
	}
	if p := communityIdx[name]; p != nil {
		return p
	}

	// virtual provide (so:, cmd:, pc:, or bare virtual like "ifupdown-any")
	if p := mainProv[name]; p != nil {
		return p
	}
	if p := communityProv[name]; p != nil {
		return p
	}

	return nil
}

func resolve(names []string, mainIdx, communityIdx Index, mainProv, communityProv map[string]*Package) ([]*Package, error) {
	seen := make(map[string]bool) // keyed by package Name
	var result []*Package

	var visit func(token string) error
	visit = func(token string) error {
		pkg := lookupDep(token, mainIdx, communityIdx, mainProv, communityProv)
		if pkg == nil {
			fmt.Fprintf(os.Stderr, "warning: no package satisfies %q, skipping\n", token)
			return nil
		}
		if seen[pkg.Name] {
			return nil
		}
		seen[pkg.Name] = true
		for _, dep := range pkg.Deps {
			if err := visit(dep); err != nil {
				return err
			}
		}
		result = append(result, pkg)
		return nil
	}

	for _, n := range names {
		if err := visit(n); err != nil {
			return nil, err
		}
	}
	return result, nil
}

func downloadPkg(cfg *Config, pkg *Package) error {
	dest := filepath.Join(archDir(cfg), pkg.File)
	if _, err := os.Stat(dest); err == nil {
		logf(cfg, "  cached  %s", pkg.File)
		return nil
	}
	url := fmt.Sprintf("%s/%s/%s/%s/%s", cfg.Mirror, cfg.Version, pkg.Repo, cfg.Arch, pkg.File)
	logf(cfg, "  fetch   %s", url)

	resp, err := http.Get(url)
	if err != nil {
		return fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download %s: HTTP %d", url, resp.StatusCode)
	}

	tmp := dest + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	return os.Rename(tmp, dest)
}

// generateIndex writes APKINDEX.tar.gz in pure Go — no apk binary required.
func generateIndex(cfg *Config, pkgs []*Package) error {
	dir := archDir(cfg)
	outPath := filepath.Join(dir, "APKINDEX.tar.gz")

	var buf bytes.Buffer
	for _, pkg := range pkgs {
		buf.WriteString(pkg.Raw)
		buf.WriteByte('\n')
	}
	content := buf.Bytes()

	f, err := os.Create(outPath)
	if err != nil {
		return fmt.Errorf("create %s: %w", outPath, err)
	}
	defer f.Close()

	gw := gzip.NewWriter(f)
	tw := tar.NewWriter(gw)

	desc := []byte("Generated by apkfetch\n")
	if err := tw.WriteHeader(&tar.Header{Name: "DESCRIPTION", Mode: 0644, Size: int64(len(desc))}); err != nil {
		return err
	}
	if _, err := tw.Write(desc); err != nil {
		return err
	}
	if err := tw.WriteHeader(&tar.Header{Name: "APKINDEX", Mode: 0644, Size: int64(len(content))}); err != nil {
		return err
	}
	if _, err := tw.Write(content); err != nil {
		return err
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gw.Close()
}

var apkAddRe = regexp.MustCompile(`(?m)apk\s+add\s+(?:--[^\s]+\s+)*([^\\;\n&|]+)`)
var continuationRe = regexp.MustCompile(`\\\s*\n`)
var wordRe = regexp.MustCompile(`[a-zA-Z0-9][a-zA-Z0-9_.+-]*`)

func scanFile(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	joined := continuationRe.ReplaceAllString(string(data), " ")
	var pkgs []string
	for _, m := range apkAddRe.FindAllStringSubmatch(joined, -1) {
		for _, word := range wordRe.FindAllString(m[1], -1) {
			if !strings.HasPrefix(word, "-") {
				pkgs = append(pkgs, word)
			}
		}
	}
	return pkgs, nil
}

func scanPaths(paths []string) ([]string, error) {
	seen := make(map[string]bool)
	var all []string
	for _, root := range paths {
		err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if info.IsDir() {
				switch info.Name() {
				case ".git", "vendor", "node_modules":
					return filepath.SkipDir
				}
				return nil
			}
			base := filepath.Base(path)
			isDockerfile := base == "Containerfile" || base == "Dockerfile" || strings.HasPrefix(base, "Containerfile.") || strings.HasPrefix(base, "Dockerfile.")
			isShell := strings.HasSuffix(base, ".sh") || strings.HasSuffix(base, ".bash")
			isMakefile := base == "Makefile" || base == "makefile" || strings.HasSuffix(base, ".mk")
			if !isDockerfile && !isShell && !isMakefile {
				return nil
			}
			pkgs, err := scanFile(path)
			if err != nil {
				fmt.Fprintf(os.Stderr, "warning: scan %s: %v\n", path, err)
				return nil
			}
			for _, p := range pkgs {
				if !seen[p] {
					seen[p] = true
					all = append(all, p)
				}
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(all)
	return all, nil
}

func logf(cfg *Config, format string, args ...any) {
	if cfg.Verbose {
		fmt.Printf(format+"\n", args...)
	}
}

func dedup(ss []string) []string {
	seen := make(map[string]bool)
	var out []string
	for _, s := range ss {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func main() {
	cfg := &Config{}
	var extraPkgs string

	flag.StringVar(&cfg.Mirror, "mirror", defaultMirror, "Alpine mirror base URL")
	flag.StringVar(&cfg.Version, "version", "v3.23", "Alpine version (e.g. v3.23)")
	flag.StringVar(&cfg.Arch, "arch", "aarch64", "target architecture")
	flag.StringVar(&cfg.CacheDir, "cache", "./apk-cache", "local cache directory")
	flag.StringVar(&extraPkgs, "pkg", "", "comma-separated extra packages to always include")
	flag.BoolVar(&cfg.Verbose, "v", false, "verbose output")
	flag.BoolVar(&cfg.NoIndex, "no-index", false, "skip APKINDEX generation")
	flag.Parse()

	cfg.ScanPaths = flag.Args()
	if len(cfg.ScanPaths) == 0 {
		cfg.ScanPaths = []string{"."}
	}

	fmt.Printf("scanning %v ...\n", cfg.ScanPaths)
	found, err := scanPaths(cfg.ScanPaths)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scan error: %v\n", err)
		os.Exit(1)
	}
	if extraPkgs != "" {
		for _, p := range strings.Split(extraPkgs, ",") {
			if p = strings.TrimSpace(p); p != "" {
				found = append(found, p)
			}
		}
	}
	found = dedup(found)
	if len(found) == 0 {
		fmt.Println("no apk add calls found")
		os.Exit(0)
	}
	fmt.Printf("packages found: %s\n", strings.Join(found, " "))

	fmt.Printf("fetching package indexes for alpine %s/%s ...\n", cfg.Version, cfg.Arch)
	mainIdx, mainProv, err := fetchIndex(cfg, "main")
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	communityIdx, communityProv, err := fetchIndex(cfg, "community")
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("index: %d main + %d community packages\n", len(mainIdx), len(communityIdx))

	pkgs, err := resolve(found, mainIdx, communityIdx, mainProv, communityProv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("resolved to %d packages (including deps)\n", len(pkgs))

	if err := os.MkdirAll(archDir(cfg), 0755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir %s: %v\n", archDir(cfg), err)
		os.Exit(1)
	}

	fmt.Printf("downloading to %s ...\n", archDir(cfg))
	failed := 0
	for _, pkg := range pkgs {
		if err := downloadPkg(cfg, pkg); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			failed++
		}
	}
	if failed > 0 {
		fmt.Fprintf(os.Stderr, "%d packages failed\n", failed)
	}

	if !cfg.NoIndex {
		fmt.Printf("generating %s/APKINDEX.tar.gz ...\n", archDir(cfg))
		if err := generateIndex(cfg, pkgs); err != nil {
			fmt.Fprintf(os.Stderr, "index error: %v\n", err)
			os.Exit(1)
		}
	}

	fmt.Printf("done. %d packages in %s\n", len(pkgs)-failed, archDir(cfg))
	fmt.Println()
	fmt.Println("Containerfile usage:")
	fmt.Printf("  COPY %s /apk-cache\n", cfg.CacheDir)
	fmt.Println("  RUN echo '/apk-cache' > /etc/apk/repositories && apk add --no-network --allow-untrusted <packages>")
}
