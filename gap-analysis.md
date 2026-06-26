# HLSL clangd Gap Analysis

## Overview

This document tracks the gap analysis for HLSL support in clangd, conducted as
part of GSoC 2026. The goal is to identify which HLSL constructs are present in
the Clang AST but not properly exposed by clangd via the Language Server
Protocol (LSP).

## Methodology

### Environment

- **Clang/clangd version:** 23.0.0git (commit 61341994bb45)
- **Target:** `dxil-pc-shadermodel6.3-library`
- **Include path:** `~/projects/llvm-project/build/lib/clang/23/include`
- **Editor:** VS Code with clangd extension (SSH remote)

### Process

For each HLSL construct category:

1. Create an isolated `.hlsl` test file with representative constructs
2. Add the file to `compile_commands.json` with correct HLSL flags
3. Test LSP features in VS Code: hover, completion, go-to-definition, diagnostics
4. Confirm gaps with AST dump when needed:

```bash
clang -x hlsl -target dxil-pc-shadermodel6.3-library \
  -I ~/projects/llvm-project/clang/lib/Headers \
  -Xclang -ast-dump FILE.hlsl 2>&1 | grep -E "HLSL|SV_|shader|Attr|implicit"
```

### Gap Classification

- **Frontend gap:** construct is absent or has `<invalid sloc>` in the AST —
  out of scope for this project
- **Tooling gap:** construct is present in the AST but clangd does not expose
  it via LSP — the target of this project
- **Configuration gap:** clangd lacks the setup needed to process HLSL files
  correctly without manual intervention
- **Architectural gap:** the LSP protocol or clangd's design assumptions do not
  accommodate HLSL-specific workflows 

### LSP Features Tested

| Symbol | Feature |
|--------|---------|
| ✅ | Works correctly |
| ❌ | Fails or missing |
| ⚠️ | Works but with incorrect output |
| ? | Not yet tested |
| ➖ | Not applicable |

## Category 1: Shader Attributes and Qualifiers

### Results

| Construct | Hover | Completion | Go-to-def | Diagnostics | AST Node | Notes |
|-----------|-------|------------|-----------|-------------|----------|-------|
| `[shader]` | ✅ | ✅ | ➖ | ✅ | `HLSLShaderAttr` | Go-to-def N/A: intrinsic keyword |
| `[numthreads]` | ✅ | ✅ | ➖ | ✅ | `HLSLNumThreadsAttr` | Go-to-def N/A: intrinsic keyword |
| `register(t0)` | ❌ | ❌ | ➖ | ❌ | `HLSLResourceBindingAttr` | Hover, completion and diagnostics null.|
| `groupshared` | ✅ | ✅ | ➖ | ❌ | `HLSLGroupSharedAddressSpace` | Go-to-def N/A: keyword. Diagnostic missing: `groupshared` outside compute shader produces no error.|
| `row_major` | ❌ | ❌ | ➖ | ❌ | None (not in AST) | Frontend gap — not present in AST. clangd treats it as unknown type. |
| `column_major` | ❌ | ❌ | ➖ | ❌ | None (not in AST) | Same as `row_major`. |
| `in` (qualifier) | ✅ | ❌ | ➖ | ❌ | `HLSLParamModifier` | Hover on qualifier shows correct docs. Hover on `in` variable shows correct HLSL type. |
| `out` (qualifier) | ⚠️ | ❌ | ➖ | ❌ | `HLSLParamModifier` | Hover on qualifier shows correct docs. Hover on `out` variable shows internal C++ representation `float &__restrict` instead of `out float`. |
| `inout` (qualifier) | ⚠️ | ❌ | ➖ | ❌ | `HLSLParamModifier` | Same as `out`. |
| `register(b0, space1)` | ⚠️ | ⚠️ | ➖ | ⚠️ | `HLSLResourceBindingAttr` | AST correctly preserves the `space` parameter in `HLSLResourceBindingAttr` (e.g. `"b0" "space1"`). Hover works correctly on `register` in `cbuffer`, `StructuredBuffer` and `RWStructuredBuffer` declarations, showing full docs including `space` explanation. However, hover fails for `register` on resource types (`Texture2D`, `RWTexture2D`, `SamplerState`) due to the pre-existing `Texture2D` partial specialization issue. Completion for `space` is text-based, not from clangd Sema. False negative: duplicate `register(t0, space0)` bindings produce no diagnostic — instead an `Ambiguous partial specializations of 'Texture2D<>'` error fires. |
| `[RootSignature(...)]` | ⚠️ | ➖ | ➖ | ⚠️ | `HLSLRootSignatureDecl` + `RootSignatureAttr` | Hover on the `RootSignature` keyword shows correct documentation including a link to Microsoft docs, but leaks the internal mangled name (e.g. `__hlsl_rootsig_decl_5043145690877839846`). Hover on the entry function shows function signature only, not the attribute. Completion: N/A inside string literal. Diagnostics partially forwarded: malformed string `"INVALID_GARBAGE_STRING"` correctly produces `Invalid parameter of RootSignature`. However, false positive: `"CBV(b0, space1)"` incorrectly produces `Invalid parameter of CBV` — `space` is valid HLSL syntax. AST dump confirms `HLSLRootSignatureDecl` is produced for valid signatures with all parameters correctly parsed (including `space`, `visibility`, `flags`). No AST node is produced for the invalid string, but the diagnostic still reaches LSP. |

## Category 2: Semantics

**Test file:** `test_semantics.hlsl`

### Results

| Construct | Hover | Completion | Go-to-def | Diagnostics | AST Node | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- | :--- |
| `SV_Target` | ❌ | ❌ | ➖ | ✅ | `HLSLParsedSemanticAttr` | Hover shows `(No spelling)`. Completion suggestions appear in VS Code but are text-based (no `textDocument/completion` request visible in clangd log). Diagnostics correctly validate type and pipeline stage. |
| `SV_Position` | ❌ | ❌ | ➖ | ✅ | `HLSLParsedSemanticAttr` | Same as `SV_Target`. |
| `SV_DispatchThreadID` | ❌ | ❌ | ➖ | ✅ | `HLSLParsedSemanticAttr` | Same as `SV_Target`. |
| `POSITION` | ❌ | ❌ | ➖ | ❌ | `HLSLParsedSemanticAttr` | Hover and completion fail. Diagnostic fails to validate semantic names. |
| `TEXCOORD` | ❌ | ❌ | ➖ | ❌ | `HLSLParsedSemanticAttr` | Same as `POSITION`. |
| `COLOR` | ❌ | ❌ | ➖ | ❌ | `HLSLParsedSemanticAttr` | Same as `POSITION`. |
| `TEXCOORD0`, `TEXCOORD1`, … | ❌ | ❌ | ➖ | ✅ | `HLSLParsedSemanticAttr` | Hover shows `(No spelling)` — same as `TEXCOORD` without suffix. AST stores the index separately (e.g. `"TEXCOORD" 2`), but clangd does not expose it. Completion does not suggest suffix variants. Diagnostics correctly validate usage. |
| `SV_Target0`, `SV_Target1`, … | ❌ | ❌ | ➖ | ⚠️ | `HLSLParsedSemanticAttr` | Hover shows `(No spelling)` — same as `SV_Target` without suffix. AST stores index separately (e.g. `"SV_Target" 1`). False negative: `SV_Target8` (out-of-range index, valid range is 0–7) produces no diagnostic — frontend does not validate the index range. |
| `SV_ClipDistance0`, `SV_ClipDistance1` | ❌ | ❌ | ➖ | ❌ | None (not in AST) | **Frontend gap.** clangd reports `Unknown HLSL semantic 'SV_ClipDistance'` — the semantic is not recognized even with a valid numeric suffix. Does not appear in AST dump. |
| Semantics in user-defined structs | ❌ | ❌ | ➖ | ✅ | `HLSLParsedSemanticAttr` | Behavior is identical to semantics on entry function parameters — hover shows `(No spelling)`, AST nodes are correctly produced. |

---

## Category 3: Resource Types

**Test file:** `test_resources.hlsl`

**Register binding reference:**
| Letter | Type | Examples |
|--------|------|---------|
| `t` | SRV (read-only) | `Texture2D`, `StructuredBuffer` |
| `u` | UAV (read-write) | `RWTexture2D`, `RWStructuredBuffer` |
| `b` | CBuffer | `cbuffer`, `ConstantBuffer` |
| `s` | Sampler | `SamplerState` |

### Results

| Construct | Hover | Completion | Go-to-def | Diagnostics | AST Node | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- | :--- |
| `Texture2D` | ⚠️ | ❌ | ❌ | ⚠️ | `ClassTemplateDecl` | Hover on variable shows `Texture2D<float4>` as the primary type with `aka Texture2D<vector<float, 4>>` as secondary. Hover on the type itself shows `class Texture2D<vector<float, 4>>`. Ambiguous partial specialization diagnostic persists. Previously crashed clangd (SIGABRT) — resolved in commit 61341994bb45. |
| `RWTexture2D` | ❌ | ❌ | ❌ | ❌ | N/A | Not recognized as a valid type. Clangd suggests `Texture2D` as a replacement, conflating SRV and UAV types. Hover on the variable incorrectly resolves the type as `Texture2D<float4>` instead of `RWTexture2D<float4>`. Ambiguous partial specialization diagnostic fires against the wrong resolved type. |
| `StructuredBuffer` | ⚠️ | ❌ | ❌ | ⚠️ | `VarDecl` | Hover on variable shows `StructuredBuffer<float4>` as the primary type with `aka StructuredBuffer<vector<float, 4>>` as secondary. Hover on the type itself shows the internal `class StructuredBuffer<vector<float, 4>>` representation. `__createFromImplicitBinding` implementation detail still visible in variable hover. |
| `RWStructuredBuffer` | ⚠️ | ❌ | ❌ | ⚠️ | `VarDecl` | Same pattern as `StructuredBuffer`. Variable hover shows `RWStructuredBuffer<float4>` as primary type. `__createFromImplicitBindingWithImplicitCounter` implementation detail still exposed in variable hover. |
| `SamplerState` | ⚠️ | ❌ | ❌ | ⚠️ | `VarDecl` | Hover on type still shows empty `class SamplerState {}`. Hover on variable shows correct type. False positive diagnostic `Variable has incomplete type 'SamplerState'`. |
| `cbuffer` | ✅ | ❌ | ➖ | ⚠️ | `HLSLBufferDecl` | Hover shows `cbuffer Constants {}`. Completion fails. False negative: duplicate `register(b0)` bindings across two cbuffers produce no diagnostic. |
| `ConstantBuffer<T>` | ❌ | ❌ | ❌ | ⚠️ | N/A | Type not recognized. Template argument `MyConstants` triggers `undeclared identifier` diagnostic with an incorrect suggestion to replace it with the name of the existing `cbuffer`. Hover resolves the type as `hlsl_constant int` and includes the contents of commented-out cbuffers as type context, indicating clangd is parsing commented code to resolve the type. |

> **Future work:** The method surface of resource types is larger than what was tested in this analysis. The wg-hlsl working group maintains a full list in [Issue #406 (Core Texture and Sampler)](https://github.com/llvm/wg-hlsl/issues/406) and [Issue #409 (Advanced Texture Methods)](https://github.com/llvm/wg-hlsl/issues/409), which includes additional methods such as the `tex[uint2]` subscript operator, `.mips[m][xy]`, and `.sample[s]`.

---

## Category 4: Built-in Functions

**Test file:** `test_builtins.hlsl`

### Results

| Construct | Hover | Completion | Go-to-def | Diagnostics | AST Node | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- | :--- |
| `dot`, `mul`, `normalize`, `saturate`, `lerp` | ✅ | ✅ | ✅ | ✅ | `CallExpr` | Full LSP support. Hover accurately displays signatures. Go-to-def successfully navigates to internal headers (e.g., `hlsl_alias_intrinsics.h`). |
| `.Sample()`, `.Load()`, `.Store()` | ✅ | ⚠️ | ❌ | ❌ | N/A | Hover and go-to-def fail — clangd cannot resolve methods due to `Texture2D` partial specialization ambiguity. Completion shows global HLSL symbols instead of `Texture2D` members. Writing to a read-only `Texture2D` via `tex2d[coords] = value` produces no diagnostic. |

---

## Category 5: Primitive HLSL Types

**Test file:** `test_types.hlsl`

### Results

| Construct | Hover | Completion | Go-to-def | Diagnostics | AST Node | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- | :--- |
| Vectors (`float3`, `int2`, etc.) | ✅ | ✅ | ✅ | ✅ | `ExtVectorType` | Fully parsed and constant-evaluated. Hover shows exact values (e.g. `{1, 2, 3}`) and displays the type as `vector<float, 3>`. |
| `matrix<T, R, C>` | ❌ | ❌ | ➖ | ❌ | N/A | Instantiating the native `matrix` keyword conflicts with the C++ `hlsl::matrix` template definition in internal headers, causing an unresolvable `ambiguous_reference` compiler error. |
| `float4x4` (Matrix Alias) | ⚠️ | ✅ | ➖ | ❌ | `TypedefType` | Hover successfully resolves the alias, but exposes the underlying C++ template `matrix<float, 4, 4>` instead of the HLSL alias. |
| `Swizzle` | ❌ | ❌ | ➖ | ✅ | `ExtVectorElementExpr` | Handled by C++ vector extensions. Hover fails to describe the mask operation. Diagnostics correctly catch invalid masks. |
| Matrix subscript (`m[0]`, `m[0][1]`) | ⚠️ | ❌ | ➖ | ✅ | `ExtVectorElementExpr` | Hover resolves to the matrix variable `m` instead of the subscript result type (`float4`, `float`, `float3`). Completion does not suggest subscript. Diagnostics work correctly. |
| Matrix swizzle `_m<row><col>` (0-indexed) | ⚠️ | ❌ | ➖ | ✅ | `MatrixElementExpr` | AST correctly produces `MatrixElementExpr` nodes with correct result types (e.g. `_m00` → `float`, `_m00_m11` → `vector<float, 2>`). Hover resolves to the matrix variable instead of the swizzle result type. Completion does not suggest `_m00`, `_m01`, etc. after `m.`. Diagnostics correctly catch out-of-bounds access (e.g. `_m22` on `float2x2`). |
| Matrix swizzle `_<row+1><col+1>` (1-indexed) | ⚠️ | ❌ | ➖ | ✅ | `MatrixElementExpr` | AST correctly produces `MatrixElementExpr` nodes with correct result types (e.g. `_11` → `float`, `_11_22` → `vector<float, 2>`, `_11_22_33` → `vector<float, 3>`). Hover resolves to the matrix variable instead of the swizzle result type — same failure as `_m` notation. Did not appear in initial AST dump because the grep pattern filtered on `_m`; confirmed via targeted query. |

---

## Category 6: Qualifiers and Modifiers

Constructs originally planned for this category (`in`, `out`, `inout`,
`groupshared`, `row_major`, `column_major`) were tested as part of Category 1
— Shader Attributes and Qualifiers — due to their contextual overlap with
shader attribute testing. See Category 1 results.

---

## Category 7: Control Flow Attributes and Interpolation Qualifiers

**Test file:** `test_control_flow_attrs.hlsl`

### 7A: Loop and Branch Control Attributes

| Construct | Hover | Completion | Go-to-def | Diagnostics | AST Node | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- | :--- |
| `[unroll]` | ❌ | ❌ | ➖ | ❌ | `HLSLLoopHintAttr` | AST contains `HLSLLoopHintAttr` with value `unroll 0`. Hover shows nothing. Completion is text-based, not from clangd Sema. False negative: `[unroll]` on a non-loop statement produces no diagnostic. |
| `[unroll(N)]` | ❌ | ❌ | ➖ | ❌ | `HLSLLoopHintAttr` | AST contains `HLSLLoopHintAttr` with value `unroll 8` (the N argument is preserved). Same LSP failures as `[unroll]`. |
| `[loop]` | ❌ | ❌ | ➖ | ❌ | `HLSLLoopHintAttr` | AST contains `HLSLLoopHintAttr` with value `loop 0`. Hover shows nothing. Completion is text-based, not from clangd Sema. |
| `[branch]` | ❌ | ❌ | ➖ | ❌ | `HLSLControlFlowHintAttr` | AST contains `HLSLControlFlowHintAttr` with value `branch`. Same LSP failures as `[loop]`. |
| `[flatten]` | ❌ | ❌ | ➖ | ❌ | `HLSLControlFlowHintAttr` | AST contains `HLSLControlFlowHintAttr` with value `flatten`. Same LSP failures as `[loop]`. |

### 7B: Semantic Interpolation Qualifiers

These appear on pixel shader input struct members or function parameters.

| Construct | Hover | Completion | Go-to-def | Diagnostics | AST Node | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- | :--- |
| `linear` | ❌ | ❌ | ➖ | ❌ | None (not in AST) | **Frontend gap.** clangd reports `Unknown type name 'linear'` — treats qualifier as a type name rather than a keyword modifier. AST dump confirms no `HLSLLinearAttr` or equivalent node is produced. Struct is marked `invalid` in the AST. |
| `centroid` | ❌ | ❌ | ➖ | ❌ | None (not in AST) | **Frontend gap.** Same as `linear`. Parser emits `Expected ';' at end of declaration list`. No AST node produced. |
| `nointerpolation` | ❌ | ⚠️ | ➖ | ❌ | None (not in AST) | **Frontend gap.** Same parse failure. Completion suggests `nointerpolation` as text-based match, not from clangd Sema. AST dump shows `CS_BadInterp` marked `invalid`, with parameter type incorrectly resolved as `int`. Because `PSInput_Interp` is `invalid`, `input.color` in `PS_Interp` generates a spurious `No member named 'color'` error. |
| `noperspective` | ❌ | ❌ | ➖ | ❌ | None (not in AST) | **Frontend gap.** Same as `linear`. |
| `sample` | ❌ | ❌ | ➖ | ❌ | None (not in AST) | **Frontend gap.** Same as `linear`. |

---

## Configuration Gaps (Type 2)

These gaps affect how clangd is set up to handle HLSL files, independent of
any specific construct.

### Gap C1: No fallback support for `.hlsl` files

**Description:** When a `.hlsl` file is opened without a `compile_commands.json`,
clangd generates a bare fallback command with no HLSL-specific flags. This
causes clangd to treat the file as C++, resulting in incorrect parsing and
broken LSP features across all categories.

**Evidence:** The `getFallbackCommand` function in
`clang-tools-extra/clangd/GlobalCompilationDatabase.cpp` (line ~57) only
handles `.h` files as a special case:

```cpp
auto FileExtension = llvm::sys::path::extension(File);
if (FileExtension.empty() || FileExtension == ".h")
    Argv.push_back("-xobjective-c++-header");
Argv.push_back(std::string(File));
```

For `.hlsl` files, no special handling exists. The fallback command becomes
simply `clang <file>`, with no `-x hlsl` or HLSL target flags.

**Contrast with Clang:** The Clang driver (`clang/lib/Driver/Types.cpp`) does
map `.hlsl` to `TY_HLSL`:

```
.Case("hlsl", TY_HLSL)
```

But clangd never consults this mapping in its fallback path. A search of the
entire clangd source confirms zero references to `hlsl`, `isHLSL`, or `TY_HLSL`
in any `.cpp` or `.h` file under `clang-tools-extra/clangd/`. HLSL is
completely invisible to clangd's internal logic.

**Fix required:** Add a special case for `.hlsl` files in `getFallbackCommand`
that injects `-x hlsl` and a sensible default HLSL target into the fallback
command, similar to the existing `.h` handling.

**Workaround (confirmed working):** A `.clangd` config file placed at the
project root can supply the missing flags via `CompileFlags`. 

```yaml
If:
  PathMatch: ".*\.hlsl(i)?$"
CompileFlags:
  Remove:
    - "-f*"
    - "-pedantic"
    - "-c"
    - "-UNDEBUG"
  Add:
    - "--driver-mode=dxc"
    - "-T"
    - "cs_6_6"
    - "-E"
    - "main"
```

When this file is present, clangd applies the flags as a fallback even without
a `compile_commands.json`. The clangd log confirms the behavior:

```
Loading config file at .../hlsl-gap-analysis/.clangd
Failed to find compilation database for .../mats.hlsl
Generic fallback command is: ... --driver-mode=dxc -T cs_6_6 -E main ...
All checks completed, 0 errors
```

**Limitations of the workaround:**

- The target (`-T cs_6_6`) and entry point (`-E main`) are fixed. Files with
  different entry point names or shader types (vertex, pixel, etc.) will fail
  to compile correctly under this config, producing false diagnostics such as
  `Use of undeclared identifier` for standard HLSL intrinsics.
- This is a per-project manual configuration — the same problem as
  `compile_commands.json`, just with a different file format.
- Does not resolve **Gap A1** (multiple entry points per file): a single
  `-T`/`-E` pair can only target one entry point at a time.

**Conclusion:** The workaround confirms that supplying `--driver-mode=dxc` and
a shader target is sufficient for clangd to parse HLSL correctly. This
validates the approach for the proper fix in `getFallbackCommand`: detect
`.hlsl` files and inject these flags automatically, without requiring manual
configuration from the developer.

---

### Gap C2: No automatic HLSL flags inference

**Description:** Even with a `compile_commands.json`, the developer must
manually specify `-x hlsl`, the correct `-target` triple, and the include path
for HLSL headers. There is no mechanism for clangd to infer these flags
automatically from the file extension or from a shader configuration file.

**Impact:** Every HLSL project requires manual `compile_commands.json`
configuration. Unlike C++ projects where many build systems generate this
automatically, there is no standard tooling to generate HLSL compile commands
for clangd.

---

## Architectural Gap (Type 3)

### Gap A1: Multiple entry points in a single HLSL file

**Description:** A fundamental mismatch exists between the LSP model and HLSL's
compilation model. The LSP assumes a single compilation context per file — one
set of compiler flags, one target, one entry point. HLSL breaks this assumption:
a single `.hlsl` file commonly contains multiple entry points, each requiring
a different shader stage target to compile correctly.

**Example:** A typical shader file may contain:

```hlsl
[shader("vertex")]
float4 VSMain(float3 pos : POSITION) : SV_Position {
    return float4(pos, 1.0);
}

[shader("pixel")]
float4 PSMain(float2 uv : TEXCOORD) : SV_Target {
    return float4(1.0, 0.0, 0.0, 1.0);
}
```

To compile `VSMain` correctly, the target must be `dxil-pc-shadermodel6.3-vertex`.
To compile `PSMain` correctly, the target must be `dxil-pc-shadermodel6.3-pixel`.
The `compile_commands.json` format only allows one command per file, so only
one entry point can be compiled with the correct target at a time. The other
entry point will receive incorrect or missing diagnostics, hover information,
and completions.

**Impact:** There is no correct way to configure clangd for a multi-entry-point
HLSL file today. Any single configuration will produce degraded results for at
least one entry point. 


**Open design questions (for RFC):**
- Should clangd maintain multiple ASTs for the same file, one per entry point?
- Should a new LSP extension be proposed to allow clients to select the active
  entry point?
- Should clangd use the `library` target by default and accept reduced
  stage-specific diagnostics as a pragmatic compromise?
- How should editors surface entry point selection to the user?

---
