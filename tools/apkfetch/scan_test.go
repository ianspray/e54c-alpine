// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ian Spray

package main

import (
	"strings"
	"os"
	"testing"
)

func TestScanFile(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  []string
	}{
		{
			"simple",
			"RUN apk add curl jq git\n",
			[]string{"curl", "jq", "git"},
		},
		{
			"continuation",
			"RUN apk add --no-cache \\\n    curl \\\n    jq\n",
			[]string{"curl", "jq"},
		},
		{
			"multiple RUN",
			"RUN apk add curl\nRUN apk add --update git openssh-client\n",
			[]string{"curl", "git", "openssh-client"},
		},
		{
			"shell script",
			"#!/bin/sh\napk add ca-certificates tzdata\n",
			[]string{"ca-certificates", "tzdata"},
		},
		{
			"with flags",
			"apk add --no-cache --update-cache busybox\n",
			[]string{"busybox"},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// write to temp file
			f, _ := os.CreateTemp("", "test*.sh")
			f.WriteString(c.input)
			f.Close()
			defer os.Remove(f.Name())

			got, err := scanFile(f.Name())
			if err != nil {
				t.Fatal(err)
			}
			if strings.Join(got, ",") != strings.Join(c.want, ",") {
				t.Errorf("got %v, want %v", got, c.want)
			}
		})
	}
}

func TestParseAPKINDEX(t *testing.T) {
	sample := `C:Q1abc123
P:curl
V:8.5.0-r0
A:x86_64
D:ca-certificates libcurl

C:Q1def456
P:libcurl
V:8.5.0-r0
A:x86_64
D:

`
	idx, _, err := parseAPKINDEX(strings.NewReader(sample), "main")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := idx["curl"]; !ok {
		t.Error("curl not found")
	}
	if idx["curl"].Version != "8.5.0-r0" {
		t.Errorf("wrong version: %s", idx["curl"].Version)
	}
	if len(idx["curl"].Deps) != 2 {
		t.Errorf("expected 2 deps, got %v", idx["curl"].Deps)
	}
}
