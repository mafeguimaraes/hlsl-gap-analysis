# [RFC] Improving HLSL Support in clangd

**GSoC 2026 - LLVM Organization**  
Author: Maria Fernanda Guimarães | Mentors: Finn Plummer, Ashley Coleman

## Abstract

This RFC proposes improvements to HLSL support in clangd, focusing on language-server
features for compute, vertex, and pixel shaders. The proposed work adds or improves hover
information and code completion for HLSL-specific language constructs for these types of
shaders, with consideration that clang is not feature complete. Each gap was investigated to
identify its root cause, multiple implementation options were considered, and one approach
per gap was selected and prototyped.

To understand the decisions and all the options considered, please check this document:
[hlsl-decision-rfc](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/hlsl-decision-rfc.md).

## Background

HLSL (High-Level Shading Language) is a C++-like language used for GPU shader programming
in DirectX. The Clang compiler supports parsing HLSL, and clangd provides language-server
features for HLSL files. However, HLSL introduces language constructs that have no direct
equivalent in standard C++, such as semantic annotations, resource binding attributes, and
parameter direction qualifiers. As a result, several IDE features require HLSL-specific
handling in clangd.

This RFC presents the HLSL language constructs for which clangd support is currently
incomplete. For each issue, we describe the expected behavior, identify the gap and proposed a
solution.

The document is organized into two sections, one for **Hover** and one for **Code
Completion**, with a subsection for each language construct:

**Hover**
- I1: Hover for semantic annotations (`SV_Target`, `SV_Position`, user-defined, etc.)
- I2: Hover for loop/branch control attributes (`[unroll]`, `[loop]`, `[branch]`, `[flatten]`)
- I3: Hover for out/inout parameter qualifiers
- I4: Hover for vector swizzle and matrix element access
- I5: RootSignature hover leaking internal compiler identifier
- I6: register hover not triggered when cursor is inside the argument

**Code Completion**
- I7: Code Completion Inside `[...]` Mixes Statement and Declaration Attributes
- I8: Code Completion Inside `register(...)`
- I9: Code Completion for HLSL Annotations After `:`
- I10: Code Completion for HLSL Vector Swizzle Members
- I11: Code Completion for HLSL Matrix Swizzle Members

---

# Section 1 — Hover

## I1 — Hover for HLSL Semantic Annotations

### Expected Behaviour

Hovering over a semantic annotation, such as `SV_Target` or `SV_Position`, should display
the semantic name and helpful documentation.

### Gap

Hovering over `SV_Target` or `SV_Position` shows `(No spelling)` instead of the semantic
name. This is caused by all HLSL semantics being represented in the AST as
`HLSLParsedSemanticAttr`, defined in `Attr.td` with an empty spellings list. The clangd
hover path calls `A->getSpelling()`, which TableGen generates to return `"(No spelling)"`
when the list is empty, ignoring the runtime data stored in the attribute instance.

### Proposed Solution

Add each system-value semantic as an explicit `Microsoft<>` spelling in
`HLSLParsedSemantic` in `Attr.td`. TableGen then generates `getSpelling()` with a switch
that returns the correct string based on a spelling index stored at parse time.
User-defined semantics (e.g. `TEXCOORD`, `COLOR`) are maintained as
`HLSLUnparsedSemanticAttr` and rendered via a dedicated branch in `Hover.cpp`.

---

## I2 — Hover for Loop/Branch Control Attributes

### Expected Behaviour

Hovering over `[unroll]`, `[loop]`, `[branch]`, or `[flatten]` should display the attribute
name and documentation about its effect on GPU shader execution.

### Gap

Hovering over these attributes produces no tooltip. They are statement attributes that live
inside an `AttributedStmt` node in the AST. The clangd `SelectionTree` (`Selection.cpp`) had
no override for `AttributedStmt`. The base `RecursiveASTVisitor` visits the child statement
but does not call `TraverseAttr` for attached attributes, making `HLSLLoopHintAttr` and
`HLSLControlFlowHintAttr` invisible to the selection tree. Declaration attributes
(`[numthreads]`, `[shader]`) work correctly because the `SelectionTree` already traverses
them via `TraverseAttr` when visiting `FunctionDecl`, `VarDecl`, etc.

### Proposed Solution

Extend the selection tree to traverse attributes attached to `AttributedStmt` nodes before
visiting the underlying statement. This allows hover requests to reach HLSL loop and branch
attributes using the existing hover infrastructure. Since these attributes already define
`Microsoft<>` spellings in `Attr.td`, no changes are required in `Hover.cpp`. The solution is
generic and also improves support for other statement attributes in Clang, not only HLSL.

---

## I3 — Hover for out/inout Parameter Qualifiers

### Expected Behaviour

Hovering over a parameter declared with `out` or `inout` should show the HLSL type, e.g.
`out float` or `inout float`.

### Gap

Hovering shows the internal C++ type (`float &__restrict`) instead. HLSL `out` and `inout`
qualifiers are lowered by Clang to C++ reference types with `__restrict`. The AST carries
`HLSLParamModifierAttr` on the `ParmVarDecl`, but three places in `Hover.cpp` print the
parameter type using the raw Clang type, ignoring the HLSL qualifier: the Type field when
hovering on the variable, the Type field in function signature tooltip, and the Definition
line in hover tooltip.

### Proposed Solution

For each of the three cases, add a `ParmVarDecl` branch that checks for
`HLSLParamModifierAttr` and reconstructs the HLSL type by stripping the reference and
prepending the qualifier. The `in` qualifier is omitted from display because it is the
default in HLSL.

---

## I4 — Hover for Vector Swizzle and Matrix Element Access

### Expected Behaviour

Hovering over a swizzle expression like `.xyz` or a matrix element like `._m00` should show
the accessor name and the result type (e.g. `vector<float, 3>` or `float`).

### Gap

Hovering produces no information. Vector swizzle accesses are represented as
`ExtVectorElementExpr` and matrix element accesses as `MatrixElementExpr`. Both store the
result type in `Expr::getType()`, already resolved by Sema. However,
`getHoverContents(const Expr *E)` in `Hover.cpp` has no cases for these node types. Since
swizzle and matrix accesses are runtime values, `EvaluateAsRValue` returns false and hover
produces nothing.

### Proposed Solution

Add two `dyn_cast` branches in `getHoverContents(const Expr *E)` that extract the accessor
name via `getAccessor().getName()` and the result type via `getType()`. No evaluation is
needed.

---

## I5 — RootSignature Hover Leaking Internal Identifier

### Expected Behaviour

Hovering over `[RootSignature("RS_CBV")]` should display the documentation for the
RootSignature attribute without exposing internal compiler details.

### Gap

Hover shows the documentation but also leaks the definition
`[RootSignature("__hlsl_rootsig_decl_5043168244180965862")]`. The HLSL parser processes the
string literal argument of RootSignature and produces an internal `IdentifierInfo` with a
generated name. This generated identifier is stored in `RootSignatureAttr` via
`getSignatureIdent()`. The original string literal is discarded after parsing and not stored
in the attribute. The generic hover path calls `A->printPretty()`, which prints the stored
identifier.

### Proposed Solution

Add a `dyn_cast<RootSignatureAttr>` branch in `getHoverContents(const Attr *A)` that sets
`HI.Name` and `HI.Documentation` directly, skipping `printPretty` entirely.

---

## I6 — register Hover Not Triggered Inside Arguments

### Expected Behaviour

Hovering on the slot identifier inside `register(t1)` (e.g. on `t1`) should display the
register documentation, including a description of what `t` means (SRV).

### Gap

Hovering inside the argument produces no tooltip; only hovering on the `register` keyword
itself works. The source range stored in `HLSLResourceBindingAttr` was zero-width: both the
start and end pointed to the same location (the start of the `register` keyword).
`ParseHLSLAnnotations` called `Attrs.addNew` with a single `SourceLocation` instead of a full
`SourceRange`. When the `SelectionTree` checks whether the cursor falls inside an attribute,
a zero-width range never matches.

### Proposed Solution

Capture the closing `)` location before consuming it in the `AT_HLSLResourceBinding` case,
and pass a full `SourceRange` to `addNew`.

---

# Section 2 — Code Completion

## I7 — Code Completion Inside `[...]` Mixes Statement and Declaration Attributes

### Expected Behaviour

Inside a function body, `[` should suggest only statement attributes (`unroll`, `loop`,
`branch`, `flatten`). Outside a function, `[` should suggest only declaration attributes
(`numthreads`, `shader`, `RootSignature`, `WaveSize`).

### Gap

Completion showed all Microsoft-syntax attributes indiscriminately, mixing statement and
declaration contexts. `ParseMicrosoftAttributes` called
`CodeCompleteAttribute(AS_Microsoft)` which returns all attributes with `AS_Microsoft`
spelling, with no distinction between contexts. `IsStmt` was not threaded through the call
site.

### Proposed Solution

Add a defaulted `bool IsStmtContext = false` parameter to `MaybeParseMicrosoftAttributes` /
`ParseMicrosoftAttributes`. Only `ParseStmt.cpp` passes `true`; the other five call sites
are unchanged. `CodeCompleteHLSLAttributes` filters `ParsedAttrInfo::getAllBuiltin()` by
accepted syntax values, an optional kind restriction, a `bool RequireStmt` flag, and an
optional `ExcludeKind` (needed to exclude `AT_HLSLParsedSemantic` from bracket-attribute
contexts).

---

## I8 — Code Completion Inside `register(...)`

### Expected Behaviour

Typing `register(` should suggest the correct slot prefix for the declared resource type
(e.g. `u0` for `RWStructuredBuffer`, `t0` for `Texture2D`). Typing `register(t0,` should
suggest `space0`. Both should be Tab-navigable snippets.

### Gap

Completion inside `register(|)` or `register(t0, |)` showed generic top-level results.
`ParseHLSLAnnotations` had no `tok::code_completion` hooks inside the
`AT_HLSLResourceBinding` case. The token fell through to the error branch, which called
`SkipUntil` and returned, leaving the parser at top-level context. The `Declarator*` was
also not threaded through, making type-aware slot filtering impossible.

### Proposed Solution

Two `ConsumeCodeCompletionToken()` hooks added inside `AT_HLSLResourceBinding`.
`CodeCompleteHLSLResourceSlot(D)` receives the `Declarator*` and resolves the resource class
by matching the `CXXRecordDecl` name (e.g. `starts_with("RW")` → `u`,
`starts_with("Texture")` → `t`). `CodeCompleteHLSLResourceSpace()` suggests `space` with a
placeholder `0`.

---

## I9 — Code Completion for HLSL Annotations After `:`

### Expected Behaviour

Typing `:` after a variable or parameter declaration should suggest valid annotations for
that context: parsed semantics (`SV_Target`, `SV_Position`, etc.), `register(slot, space)`
with the correct slot pre-filled based on the declared resource type, and
`packoffset(c0)`. Both `register` and `packoffset` should be inserted as Tab-navigable
snippets.

### Gap

Typing `:` produced no completion results. `ParseHLSLAnnotations` had no
`tok::code_completion` hook. The token fell into the `if (!II)` error branch and was
discarded. The `Declarator*` was not threaded through to Sema, making type-aware slot
filtering impossible.

### Proposed Solution

Add `const Declarator *D` parameter to `ParseHLSLAnnotations` and
`MaybeParseHLSLAnnotations(Declarator &D)`. `CodeCompleteHLSLAnnotation(D)` iterates
`ParsedAttrInfo::getAllBuiltin()` and emits candidates for `AS_HLSLAnnotation` (`register`,
`packoffset`) and `AS_Microsoft` + `AT_HLSLParsedSemantic` (`SV_Target`, etc.). The slot is
resolved by `CXXRecordDecl` name since `HLSLAttributedResourceType` is not yet built at
parse time. `register` and `packoffset` use `CCP_CodePattern` with `CXCursor_Constructor`
to preserve both Tab stops.

---

## I10 — Code Completion for HLSL Vector Swizzle Members

### Expected Behaviour

Typing `v.` on a `float3` should suggest `x`, `y`, `z`, `r`, `g`, `b`. Typing `v.x` should
suggest only `x`, `y`, `z` (locking to the xyzw set). Typing `v.xr` should suggest nothing
(mixing sets is semantically invalid). Typing `v.xyzw` should suggest nothing (4-component
limit reached).

### Gap

Typing `v.` produced no suggestions. `CodeCompleteMemberReferenceExpr` handled `RecordDecl`
members but had no case for `ExtVectorType`. The already-typed prefix (e.g. `"x"` when
typing `v.x`) was available via `getCodeCompletionFilter()` but not used, so semantically
invalid combinations like `v.xr` were not filtered.

### Proposed Solution

Add an `ExtVectorType` branch in `DoCompletion` inside `CodeCompleteMemberReferenceExpr`.
`AddHLSLVectorSwizzleCompletions` reads `getCodeCompletionFilter()` and enforces three
rules: (1) no mixing xyzw/rgba sets — detected from filter characters; (2) max 4 components;
(3) only valid components for the vector size.

---

## I11 — Code Completion for HLSL Matrix Swizzle Members

### Expected Behaviour

Typing `m.` on a `float2x2` should suggest `_m00`, `_m01`, `_m10`, `_m11` and `_11`, `_12`,
`_21`, `_22`. Typing `m._m00` should continue with `_m` notation only. Typing `m._m00_11`
should suggest nothing (mixing notations is invalid).

### Gap

Typing `m.` produced no suggestions. `ConstantMatrixType` was not handled in
`CodeCompleteMemberReferenceExpr`. HLSL supports two notation systems (`_m` zero-indexed and
`_` one-indexed) that cannot be mixed, but this was not enforced.

### Proposed Solution

Add a `ConstantMatrixType` branch in `DoCompletion`. `AddHLSLMatrixSwizzleCompletions`
detects the notation from the filter prefix: `starts_with("_m")` locks to 0-indexed (4
chars/component, max 16 chars total), `starts_with("_")` locks to 1-indexed (3
chars/component, max 12 chars total). Mixing notations returns no suggestions.
