# HLSL Gap Analysis for clangd

This repository tracks the gap analysis and implementation ideas for improving
HLSL support in clangd, developed as part of
[GSoC 2026](https://summerofcode.withgoogle.com) with the LLVM project.

## Goal

Identify which HLSL constructs are present in the Clang AST but not properly
exposed by clangd via the Language Server Protocol (LSP), and propose
solutions for each gap.

## Repository Structure

```
.
├── README.md
├── compile_commands.json       # Build flags for each test file
├── .clangd                     # Fallback config (see note below)
├── gap-analysis.md             # Gap analysis
├── hlsl-decision-rfc.md        # All options considered for the RFC
├── hlsl-rfc.md                 # Proposed improvements to HLSL support in clangd
├── implementation-ideas.md     # Implementation ideas and open questions
└── test_*.hlsl                 # Test files, one per construct category
```

## Test Files

| File | Category |
|------|----------|
| `test_shader_attr.hlsl` | Shader attributes (`[shader]`, `[numthreads]`) |
| `test_register.hlsl` | Register bindings |
| `test_register_space.hlsl` | Register bindings with `space` parameter |
| `test_root_signature.hlsl` | `[RootSignature]` attribute |
| `test_groupshared.hlsl` | `groupshared` qualifier |
| `test_param_modifiers.hlsl` | `in`, `out`, `inout` qualifiers |
| `test_semantics.hlsl` | HLSL semantics (`SV_Target`, `SV_Position`, etc.) |
| `test_semantics_extended.hlsl` | Semantics with numeric suffix and in structs |
| `test_resources.hlsl` | Resource types (`Texture2D`, `RWTexture2D`, etc.) |
| `test_constantbuffer.hlsl` | `ConstantBuffer<T>` |
| `test_builtins.hlsl` | Built-in functions (`dot`, `lerp`, `normalize`, etc.) |
| `test_types.hlsl` | Primitive HLSL types and vectors |
| `test_matrix_layout.hlsl` | `row_major` / `column_major` |
| `test_matrix_swizzle.hlsl` | Matrix swizzle (`_m00`, `_11` notations) |
| `test_control_flow_attrs.hlsl` | Loop/branch attributes and interpolation qualifiers |
| `test_multiple_entry.hlsl` | Multiple entry points in a single file |

## Environment

- **Clang/clangd version:** 23.0.0git (commit 61341994bb45)
- **Target:** `dxil-pc-shadermodel6.3-library`
- **Editor:** VS Code with clangd extension (SSH remote)

## Setup

The recommended way to use this repository is with a `compile_commands.json`,
which specifies the correct HLSL flags for each test file individually.

This file is **not included in the repository** because it contains
machine-specific paths. You need to create it locally.

Each entry follows this pattern:

```json
[
  {
    "directory": "/path/to/hlsl-gap-analysis",
    "file": "test_shader_attr.hlsl",
    "command": "clang -x hlsl -target dxil-pc-shadermodel6.3-library -I /path/to/llvm-project/build/lib/clang/23/include test_shader_attr.hlsl"
  }
]
```

Replace `/path/to/hlsl-gap-analysis` with the absolute path to this repository
and `/path/to/llvm-project/build/lib/clang/23/include` with the path to your
local clang headers. Add one entry per test file.

### Note on `.clangd`

A `.clangd` config file is also included as a reference:

```yaml
If:
  PathMatch: ".*\\.hlsl(i)?$"
CompileFlags:
  Remove: ["-f*", "-pedantic", "-c", "-UNDEBUG"]
  Add: ["--driver-mode=dxc", "-T", "cs_6_6", "-E", "main"]
```

**Limitation:** the fixed `-T cs_6_6 -E main` flags only work for files with
a single compute shader entry point named `main`. Files with other entry point
names or shader types will produce incorrect diagnostics. The `compile_commands.json`
approach is more reliable for this multi-file project.

## Documents

- **`hlsl-decision-rfc.md`**: This document is a companion to the RFC and
  records all options investigated for each gap, including options that were discarded and the
  reasons why. 

- **`gap-analysis.md`**: full gap analysis across 7 categories of
  HLSL constructs, configuration gaps, and architectural gaps. Each construct
  is tested for hover, completion, go-to-definition, and diagnostics, with
  AST dump evidence and gap classification (tooling gap vs frontend gap).

- **`implementation-ideas.md`**: implementation ideas for tooling gaps, with
  root cause analysis, candidate solutions, prototypes, and open questions for
  discussion with the community.

## Related Links

- [LLVM Project](https://github.com/llvm/llvm-project)
- [wg-hlsl working group](https://github.com/llvm/wg-hlsl)
- [GSoC 2026 project proposal](https://summerofcode.withgoogle.com/programs/2026/projects/3NvWcmRs)
