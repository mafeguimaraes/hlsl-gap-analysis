# HLSL clangd — Implementation Ideas

## Overview

This document tracks implementation ideas and open questions for improving
HLSL support in clangd, developed as part of GSoC 2026. 

---

## Idea I1: Hover for HLSL Semantics (`SV_Target`, `TEXCOORD`, etc.)

### Gap
Hovering over HLSL semantic annotations (e.g. `SV_Position`, `SV_Target0`,
`TEXCOORD1`) shows `(No spelling)` instead of the semantic name.

### Root Cause

HLSL semantics are represented in the AST as `HLSLParsedSemanticAttr`, which
stores the semantic name and index as data fields:

```cpp
class HLSLParsedSemanticAttr : public HLSLSemanticBaseAttr {
  llvm::StringRef getSemanticName() const;  // e.g. "SV_Target"
  int getSemanticIndex() const;             // e.g. 0, 1, 2
};
```

The hover path in clangd is:

```
getHoverContents(const Attr *A)
  → HI.Name = A->getSpelling()
  → HLSLParsedSemanticAttr::getSpelling()
  → "(No spelling)"
```

`getSpelling()` returns `"(No spelling)"` because `HLSLParsedSemanticAttr` is
defined in `Attr.td` with no spellings:

```
def HLSLParsedSemantic : HLSLSemanticBaseAttr {
  let Spellings = [];
}
```

TableGen generates `getSpelling()` as a fixed `"(No spelling)"` return. 

The AST contains the data:

```cpp
if (const auto *SA = llvm::dyn_cast<HLSLParsedSemanticAttr>(A))
  llvm::errs() << SA->getSemanticName(); // prints "SV_Position", "SV_Target"
```

### Candidate Solutions

**Option A — Special case in `Hover.cpp` (least invasive)**

Add a `dyn_cast` branch in `getHoverContents(const Attr *A)` before the
generic `getSpelling()` call:

```cpp
if (const auto *SA = llvm::dyn_cast<HLSLParsedSemanticAttr>(A)) {
  std::string Name = SA->getSemanticName().str();
  int Idx = SA->getSemanticIndex();
  if (Idx > 0)
    Name += std::to_string(Idx);
  HI.Name = Name;
  HI.Documentation = Attr::getDocumentation(A->getKind()).str();
  return HI;
}
```

This was prototyped and confirmed to produce correct output:
- `SV_Position` → hover shows `SV_Position`
- `SV_Target` at index 1 → hover shows `SV_Target1`

Downside: local fix that only helps hover, not other consumers of `getSpelling()`.

**Option B — Custom `getSpelling()` implementation**

Override `getSpelling()` to return the semantic name dynamically:

```cpp
const char *HLSLParsedSemanticAttr::getSpelling() const {
  return getSemanticName().data();
}
```

Risk: Could affect all callers of `getSpelling()` across the Clang
codebase, not just hover.

**Option C — Explicit spellings per semantic**

Add each semantic name as an explicit spelling in `Attr.td`:

```
def HLSLParsedSemantic : HLSLSemanticBaseAttr {
  let Spellings = [HLSLSemantic<"SV_Position">, HLSLSemantic<"SV_Target">, ...];
}
```

This is how the attribute was defined before
[PR #167862](https://github.com/llvm/llvm-project/pull/167862/changes), which
intentionally consolidated all semantics into a single attribute. 

### Open Questions

- Should the index `0` be shown in hover? (`SV_Target` vs `SV_Target0`) What is the expected display convention?
- Why did PR #167862 move away from explicit spellings? Is there a reason that
  rules out Option C?
- Is Option A acceptable as a permanent fix, or is it considered a workaround
  that should be replaced by a proper solution later?

### Files to Modify

- `clang-tools-extra/clangd/Hover.cpp` (Option A)
- `clang-tools-extra/clangd/unittests/HoverTests.cpp` (new test cases)

---

## Idea I2: Hover for Loop/Branch Control Attributes (`[unroll]`, `[loop]`, `[branch]`, `[flatten]`)

### Gap
Hovering over `[unroll]`, `[loop]`, `[branch]`, and `[flatten]` shows nothing
at all — no tooltip appears.

### Root Cause

The hover flow never reaches `getHoverContents(const Attr *A)` for these attributes.

These attributes are `StmtAttr` — they are attached to statements, not
declarations. In the AST they live inside an `AttributedStmt`:

```
AttributedStmt
├── HLSLLoopHintAttr    ← [unroll] or [loop]
└── ForStmt             ← the loop body
```

When the cursor is over `[unroll]`, the clangd selection tree
(`Selection.cpp`) traverses the AST to find the node at that position. It
finds the `AttributedStmt` but does not descend into its attributes. The node
that reaches the hover handler is the `CompoundStmt` of the loop body —
confirmed via logging:

```cpp
} else {
  llvm::errs() << "NODE KIND: "
               << N->ASTNode.getNodeKind().asStringRef() << "\n";
  // prints: CompoundStmt
}
```

A search of `Selection.cpp` confirms there is no handling for `AttributedStmt`
or `StmtAttr`:

```bash
grep -n "AttributedStmt\|StmtAttr" clang-tools-extra/clangd/Selection.cpp
# no output
```

By contrast, declaration attributes (`InheritableAttr`, `DeclAttr`) on
`FunctionDecl`, `VarDecl`, etc. work correctly because the selection tree
already traverses declaration attributes. This is why `[shader]`,
`[numthreads]`, and `[RootSignature]` show hover tooltips but `[unroll]` does not.

### Investigation Results 

Added logging to the hover path to trace exactly what happens when the cursor
is placed over `[unroll]`. The complete flow discovered:

```
Hover request at line 135 (position of [unroll])
    ↓
SelectionTree::createRight()   ← builds the tree by traversing the AST
    ↓                             TraverseAttr is called for numthreads here
    ↓                             HLSLLoopHintAttr is never traversed (Problem B)
SelectionTree ready
    ↓
ST.commonAncestor()            ← returns the most specific node found
    ↓
CompoundStmt                   ← deepest node the tree could reach
    ↓
not Attr, not Expr, not Decl   ← falls into else branch (added by me)
    ↓
tooltip empty
```

**Log evidence:**
```
[Selection] TraverseAttr: numthreads   ← found during tree construction
[Hover] Untreated node: CompoundStmt  ← commonAncestor() result
result: null
```

This confirms two distinct problems:

**Problem B — `AttributedStmt` not traversed (primary problem):**
`Selection.cpp` has no traversal of attributes inside `AttributedStmt` —
confirmed by grep returning no results for `AttributedStmt` or `StmtAttr`.
The `HLSLLoopHintAttr` is completely invisible to the SelectionTree.
This is the main problem to fix.

**Problem A — `numthreads` appears in log but is unrelated to the cursor:**
`numthreads` appears in the log because `TraverseAttr` is called for every
attribute encountered during tree construction — including attributes of the
enclosing `FunctionDecl`. It is not selected as `commonAncestor()` — that
returns `CompoundStmt`. The `numthreads` in the log is a side effect of the
traversal, not the selected node. Needs further investigation to understand
if it causes any issues beyond the log noise.

**Problem C — `getHoverContents` returns null for `numthreads`:**
Even when `numthreads` is correctly found as an `Attr` in other scenarios,
`getHoverContents` returns `std::nullopt` for it. This is a separate bug —
`HI.Name` likely ends up empty or the documentation lookup fails for
`HLSLNumThreadsAttr`.

### Candidate Solution

Three fixes are needed, in order of dependency:

**Fix 1 (Problem B — primary) — Add `AttributedStmt` traversal to `Selection.cpp`:**

```
when visiting AttributedStmt:
  for each Attr in AttributedStmt->getAttrs():
    if cursor position is within the Attr's source range:
      return Attr as the selected node
  otherwise:
    continue traversal into the child statement
```

Once this is done, `ST.commonAncestor()` will return `HLSLLoopHintAttr`
instead of `CompoundStmt` when the cursor is over `[unroll]`.

**Fix 2 (Problem A — secondary) — Investigate `numthreads` in traversal log:**

Understand why `numthreads` appears during tree construction and whether it
causes incorrect behavior beyond log noise. May not require a fix once
Problem B is resolved.

**Fix 3 (Problem C) — Display logic for loop/branch attributes:**

Once the correct `Attr` node is surfaced, add `dyn_cast` branches in
`getHoverContents(const Attr *A)`:

```cpp
if (const auto *LH = llvm::dyn_cast<HLSLLoopHintAttr>(A)) {
  std::string Name;
  ...
  HI.Name = Name;
  HI.Documentation = Attr::getDocumentation(A->getKind()).str();
  return HI;
}
```

### Scope Note

Fix 1 affects **all** `StmtAttr` in Clang, not just HLSL. Any language
feature that uses statement attributes (OpenMP pragmas, C++ `[[likely]]`,
etc.) would also gain hover support. 

### Open Questions

- Is adding `AttributedStmt` traversal to `Selection.cpp` the right approach,
  or is there a reason it was not implemented before?
- Should this be scoped to HLSL attributes only, or implemented generically
  for all `StmtAttr`?
- Why is `numthreads` being selected for cursor positions inside the function
  body — is this a source range issue or a traversal priority issue?

### Files to Modify

- `clang-tools-extra/clangd/Selection.cpp` (Fix 1 and Fix 2)
- `clang-tools-extra/clangd/Hover.cpp` (Fix 3)
- `clang-tools-extra/clangd/unittests/SelectionTests.cpp` (new test cases)
- `clang-tools-extra/clangd/unittests/HoverTests.cpp` (new test cases)

---

## Idea I3: Hover for `out`/`inout` Parameter Qualifiers

### Gap
Hovering over a variable declared with `out` or `inout` qualifier shows the
internal C++ type (`float &__restrict`) instead of the HLSL type (`out float`,
`inout float`).

### Root Cause

HLSL `out` and `inout` qualifiers are represented in the AST as
`HLSLParamModifierAttr` on `ParmVarDecl`. Internally, Clang lowers these to
C++ reference types with `__restrict`. Three places in `Hover.cpp` print the
parameter type using the raw Clang type, all of which need to be fixed:

**Case 1 — `Type` field when hovering on the variable:**
```cpp
// getHoverContents(const NamedDecl *D)
else if (const auto *VD = dyn_cast<ValueDecl>(D))
    HI.Type = printType(VD->getType(), Ctx, PP);  // shows "float &__restrict"
```
`ParmVarDecl` is a subclass of `ValueDecl`, so it falls into this generic case.

**Case 2 — `Type` field in function signature tooltip:**
```cpp
// toHoverInfoParam()
Out.Type = printType(PVD->getType(), PVD->getASTContext(), PP);  // shows "float &__restrict"
```

**Case 3 — `Definition` line in hover tooltip:**
```cpp
// getHoverContents(const NamedDecl *D)
HI.Definition = printDefinition(D, PP, TB);  // shows "out float &__restrict b"
```
`printDefinition` calls `D->print()` which uses the internal C++ printer.

**Case 1 fix** — add a `ParmVarDecl` case before the generic `ValueDecl` case:

```cpp
else if (const auto *PVD = dyn_cast<ParmVarDecl>(D)) {
  if (const auto *Mod = PVD->getAttr<HLSLParamModifierAttr>()) {

     // Remove the internal reference type and recover the base HLSL type.
    // Example:
    //   PVD->getType()      = "float &__restrict"
    //   BaseType           = "float"
    QualType BaseType = PVD->getType().getNonReferenceType();

    // Convert the QualType into a printable string.
    // Example:
    //   BaseType           = float
    //   BaseHLSLType.Type  = "float"
    auto BaseHLSLType = printType(BaseType, Ctx, PP);

    if (Mod->isOut())
      // Produces: "out float"
      HI.Type = HoverInfo::PrintedType(("out " + BaseHLSLType.Type).c_str());
    else if (Mod->isInOut())
      // Produces: "inout float"
      HI.Type = HoverInfo::PrintedType(("inout " + BaseHLSLType.Type).c_str());
    else
      // Plain input parameter ("in" is implicit in HLSL).
      // Produces: "float"
      HI.Type = BaseHLSLType;
  } else {
    HI.Type = printType(PVD->getType(), Ctx, PP);
  }
}
else if (const auto *VD = dyn_cast<ValueDecl>(D))
  HI.Type = printType(VD->getType(), Ctx, PP);
```

**Case 2 fix** — same logic in `toHoverInfoParam`:

```cpp
if (const auto *Mod = PVD->getAttr<HLSLParamModifierAttr>()) {
  QualType BaseType = PVD->getType().getNonReferenceType();
  auto BaseHLSLType = printType(BaseType, PVD->getASTContext(), PP);
  if (Mod->isOut())
    Out.Type = HoverInfo::PrintedType(("out " + BaseHLSLType.Type).c_str());
  else if (Mod->isInOut())
    Out.Type = HoverInfo::PrintedType(("inout " + BaseHLSLType.Type).c_str());
  else
    Out.Type = BaseHLSLType;
} else {
  Out.Type = printType(PVD->getType(), PVD->getASTContext(), PP);
}
```

**Case 3 fix** — override `HI.Definition` after `printDefinition`:

```cpp
HI.Definition = printDefinition(D, PP, TB);
if (const auto *PVD = dyn_cast<ParmVarDecl>(D)) {
  if (const auto *Mod = PVD->getAttr<HLSLParamModifierAttr>()) {
    QualType BaseType = PVD->getType().getNonReferenceType();
    std::string BaseStr = printType(BaseType, Ctx, PP).Type;
    std::string Qualifier;
    if (Mod->isOut())        Qualifier = "out ";
    else if (Mod->isInOut()) Qualifier = "inout ";
    HI.Definition = Qualifier + BaseStr + " " + PVD->getNameAsString();
  }
}
```

All three cases confirmed working — hover now shows:
- `a` (in) → `Type: float` / `// In paramTest\nin float a`
- `b` (out) → `Type: out float` / `// In paramTest\nout float b`
- `c` (inout) → `Type: inout float` / `// In paramTest\ninout float c`

Note: `in` qualifier is intentionally omitted from the type display since it
is the default in HLSL.

### Open Questions

- Should `in` be shown explicitly in the hover (`in float`) or omitted since
  it is the default? The current prototype omits it.
- The Case 3 fix rebuilds the definition string manually. Is there a cleaner
  way to override the printer for HLSL parameter types?

### Files to Modify

- `clang-tools-extra/clangd/Hover.cpp` (three locations)
- `clang-tools-extra/clangd/unittests/HoverTests.cpp` (new test cases)

---

## Summary Table

| ID | Gap | Root Cause |
|----|-----|-----------|
| I1 | Hover for semantics | `getSpelling()` returns `(No spelling)` for `HLSLParsedSemanticAttr` | 
| I2 | Hover for loop/branch attrs | `Selection.cpp` does not traverse `StmtAttr` inside `AttributedStmt` | 
| I3 | Hover for `out`/`inout` qualifiers | `ParmVarDecl` type printed as internal C++ `float &__restrict` |