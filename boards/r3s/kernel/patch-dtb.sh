#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Disable unsupported nodes in the FriendlyElec RK3566 DTB for NanoPi R3S.
# The R3S has no NPU voltage supply; leaving NPU nodes enabled causes
# the rk_iommu driver to trigger a kernel panic during PM domain powerup.
# The headless Alpian profile also wants the display/HDMI stack disabled so
# DRM does not steal the console or bring up unused display hardware.
#
# Uses dtc to decompile/recompile the DTB so nodes are found by compatible
# string and label pattern rather than by hardcoded addresses (which differ
# between RK3566 BSP variants).
set -euo pipefail

dtb_file="${1:?Usage: patch-dtb.sh <dtb_file>}"

echo "Patching DTB for NanoPi R3S: $(basename "$dtb_file")"

python3 - "$dtb_file" <<'PYEOF'
import sys, re, subprocess, os, tempfile

dtb = sys.argv[1]

# Decompile DTB -> DTS.
proc = subprocess.run(
    ['dtc', '-q', '-I', 'dtb', '-O', 'dts', dtb],
    capture_output=True, text=True)
if proc.returncode != 0:
    print(f'dtc decompile failed:\n{proc.stderr}', file=sys.stderr)
    sys.exit(1)
orig_lines = proc.stdout.split('\n')

# Compute brace depth at the START of each line (before that line's braces).
depths = []
d = 0
for line in orig_lines:
    depths.append(d)
    for ch in line:
        if ch == '{':
            d += 1
        elif ch == '}':
            d -= 1

# Identify target node start lines by two criteria:
#   (a) compatible property contains a target substring
#   (b) node header (label + name) contains a target keyword
#
# This catches cases where a child node's compatible is generic but its label
# or node name still identifies it as board-specific plumbing.
TARGET_RULES = (
    (
        'npu',
        ('rknpu', 'rockchip,rk3568-rknpu', 'rockchip,rk3566-rknpu'),
        ('npu',),
    ),
    (
        'display',
        (
            'rockchip,display-subsystem',
            'rockchip,dw-hdmi',
            'rockchip,hdmi',
            'rockchip,vop',
            'rockchip,vop2',
            'hdmi-connector',
        ),
        ('display-subsystem', 'vop', 'hdmi', 'route-hdmi'),
    ),
)
nodes_to_disable = set()  # original line indices of node-opening lines

for i, line in enumerate(orig_lines):
    stripped = line.strip()

    # (a) compatible property match
    if re.match(r'compatible\s*=', stripped):
        for _, compat_terms, _ in TARGET_RULES:
            if any(term in stripped for term in compat_terms):
                for j in range(i - 1, -1, -1):
                    if depths[j] < depths[i] and '{' in orig_lines[j]:
                        nodes_to_disable.add(j)
                        break
        continue

    # (b) node header line containing one of the target keywords
    if '{' not in stripped or '=' in stripped.split('{')[0]:
        continue
    header = stripped.split('{')[0]
    lowered_header = header.lower()
    for _, _, header_terms in TARGET_RULES:
        if any(term in lowered_header for term in header_terms):
            nodes_to_disable.add(i)
            break

if not nodes_to_disable:
    print('  No NPU nodes found to disable.', file=sys.stderr)
    sys.exit(0)

# For each target node, decide whether to replace an existing status property
# or insert a new one after the node-opening line.
status_replace = {}       # orig line idx -> replacement text
status_insert_after = set()  # node start line indices needing a new status line

for node_idx in nodes_to_disable:
    inner_depth = depths[node_idx] + 1
    found = False
    for k in range(node_idx + 1, len(orig_lines)):
        if depths[k] < inner_depth:
            break
        if depths[k] == inner_depth and re.match(r'\s*status\s*=', orig_lines[k]):
            status_replace[k] = re.sub(
                r'status\s*=\s*"[^"]*"', 'status = "disabled"', orig_lines[k])
            found = True
            break
    if not found:
        status_insert_after.add(node_idx)
    name = orig_lines[node_idx].strip().split('{')[0].strip()
    print(f'  disabled: {name}')

# Build the patched DTS in a single forward pass.
result = []
for i, line in enumerate(orig_lines):
    result.append(status_replace.get(i, line))
    if i in status_insert_after:
        next_line = orig_lines[i + 1] if i + 1 < len(orig_lines) else ''
        m = re.match(r'^(\s+)', next_line)
        indent = m.group(1) if m else '\t\t'
        result.append(f'{indent}status = "disabled";')

# Recompile DTS -> DTB in place.
with tempfile.NamedTemporaryFile(mode='w', suffix='.dts', delete=False) as f:
    f.write('\n'.join(result))
    tmp_dts = f.name
try:
    proc2 = subprocess.run(
        ['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', dtb, tmp_dts],
        capture_output=True)
    if proc2.returncode != 0:
        print(f'dtc recompile failed:\n{proc2.stderr.decode()}', file=sys.stderr)
        sys.exit(1)
finally:
    os.unlink(tmp_dts)
print('  DTB recompiled.')
PYEOF

echo "DTB patch complete."
