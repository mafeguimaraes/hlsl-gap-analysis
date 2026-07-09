# HLSL clangd - Implementation Ideas

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
  -> HI.Name = A->getSpelling()
  -> HLSLParsedSemanticAttr::getSpelling()
  -> "(No spelling)"
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

### Solution (Implemented)

**Option C - Explicit `def` per semantic in `Attr.td`**


- **Option A** (dyn_cast in Hover.cpp): prototyped and working, but local fix
- **Option B** (modify getSpelling): can affect all Clang callers
- **Option C** (explicit spellings): initially blocked by `HLSLAnnotation` requiring
  lowercase, but `Microsoft<>` spellings work correctly

The approach adds a separate `def` for each system semantic in `Attr.td`,
following the pre-existing `HLSLPositionSemantic` pattern:

```
def HLSLTargetSemantic : HLSLSemanticBaseAttr {
  let Spellings = [Microsoft<"SV_Target">];
  ...
}
def HLSLDispatchThreadIDSemantic : HLSLSemanticBaseAttr {
  let Spellings = [Microsoft<"SV_DispatchThreadID">];
  ...
}
// etc. for each system semantic
```

And `SemaHLSL.cpp` is updated to use the specific attr type per semantic:

```cpp
// Before:
D->addAttr(createSemanticAttr<HLSLParsedSemanticAttr>(AL, Index));

// After (example for SV_DispatchThreadID):
D->addAttr(createSemanticAttr<HLSLDispatchThreadIDSemanticAttr>(AL, Index));
```

**Confirmed working**, hover now shows correct names:
- `SV_Target0` -> hover shows `SV_Target` 
- `SV_Position` -> hover shows `SV_Position` 
- `SV_DispatchThreadID` -> hover shows `SV_DispatchThreadID` 

**Note:** Semantics without a `def` still show `Unknown HLSL semantic` error (e.g. `SV_ClipDistance`).

**System semantics implemented so far:**
- `SV_Position` (pre-existing `HLSLPositionSemantic`)
- `SV_Target` (`HLSLTargetSemanticAttr`)
- `SV_VertexID` (`HLSLVertexIDSemanticAttr`)
- `SV_DispatchThreadID` (`HLSLDispatchThreadIDSemanticAttr`)
- `SV_GroupIndex` (`HLSLGroupIndexSemanticAttr`)
- `SV_GroupThreadID` (`HLSLGroupThreadIDSemanticAttr`)
- `SV_GroupID` (`HLSLGroupIDSemanticAttr`)

**Remaining work:**
- Add remaining system semantics (`SV_ClipDistance`, etc.)
- Handle user-defined semantics (`TEXCOORD`, `COLOR`, `POSITION`) - still dynamic

### Files to Modify

- `clang/include/clang/Basic/Attr.td` (new `def` per semantic)
- `clang/lib/Sema/SemaHLSL.cpp` (use specific attr types)
- `clang-tools-extra/clangd/unittests/HoverTests.cpp` (new test cases)

---

## Idea I2: Hover for Loop/Branch Control Attributes (`[unroll]`, `[loop]`, `[branch]`, `[flatten]`)

### Gap
Hovering over `[unroll]`, `[loop]`, `[branch]`, and `[flatten]` shows nothing
at all.

### Root Cause

The hover flow never reaches `getHoverContents(const Attr *A)` for these attributes.

These attributes are `StmtAttr` - they are attached to statements, not
declarations. In the AST they live inside an `AttributedStmt`:

```
AttributedStmt
├── HLSLLoopHintAttr    - [unroll] or [loop]
└── ForStmt             - the loop body
```

When the cursor is over `[unroll]`, the clangd selection tree
(`Selection.cpp`) traverses the AST to find the node at that position. It
finds the `AttributedStmt` but does not descend into its attributes. The node
that reaches the hover handler is the `CompoundStmt` of the loop body,
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
SelectionTree::createRight()   <- builds the tree by traversing the AST
    ↓                             TraverseAttr is called for numthreads here
    ↓                             HLSLLoopHintAttr is never traversed (Problem B)
SelectionTree ready
    ↓
ST.commonAncestor()            <- returns the most specific node found
    ↓
CompoundStmt                   <- deepest node the tree could reach
    ↓
not Attr, not Expr, not Decl   <- falls into else branch (added by me)
    ↓
tooltip empty
```

**Log evidence:**
```
[Selection] TraverseAttr: numthreads   <- found during tree construction
[Hover] Untreated node: CompoundStmt  <- commonAncestor() result
result: null
```

This confirms two distinct problems:

**Problem B - `AttributedStmt` not traversed (primary problem):**
`Selection.cpp` has no traversal of attributes inside `AttributedStmt`,
confirmed by grep returning no results for `AttributedStmt` or `StmtAttr`.
The `HLSLLoopHintAttr` is completely invisible to the SelectionTree.
This is the main problem to fix.

**Problem A - `numthreads` appears in log but is unrelated to the cursor:**
`numthreads` appears in the log because `TraverseAttr` is called for every
attribute encountered during tree construction, including attributes of the
enclosing `FunctionDecl`. It is not selected as `commonAncestor()`, that
returns `CompoundStmt`. The `numthreads` in the log is a side effect of the
traversal, not the selected node.

**Problem D (newly discovered) - Incorrect source range for attributes without arguments:**

Added a `TraverseAttributedStmt` in `Selection.cpp` to print all attributes
and their source ranges. The log revealed:

```
[unroll]    range=136:4-136:4   <- begin == end, zero-length range
[unroll(8)] range=140:4-140:12  <- correct range
[loop]      range=144:4-144:4   <- zero-length range
[branch]    range=148:4-148:4   <- zero-length range
[flatten]   range=152:4-152:4   <- zero-length range
```

Attributes **without arguments** have a collapsed source range, begin and
end point to the same location. 

**Root cause of Problem D** found in `ParseDeclCXX.cpp`:

```cpp
// When attribute has arguments - ParseCXX11AttributeArgs computes full range
if (Tok.is(tok::l_paren)) {
    AttrParsed = ParseCXX11AttributeArgs(II, NameLoc, Attrs, &EndLoc, ...);
}
// When attribute has NO arguments - only NameLoc is used, no EndLoc
if (!AttrParsed) {
    Attrs.addNew(II, NameLoc, AttributeScopeInfo(), nullptr, 0,
                 ParsedAttr::Form::Microsoft());  // range collapses to NameLoc:NameLoc
}
```

The fix would be to pass `EndLoc` computed from the closing `]` bracket
(`T.getCloseLocation()`) to `addNew` for attributes without arguments.

**This is a Clang frontend bug, not a clangd bug** - the source range is
computed incorrectly in the parser before clangd ever sees the attribute.

### Solution (Implemented)

**Fix implemented - Add `AttributedStmt` traversal to `Selection.cpp`:**

Added `TraverseAttributedStmt` to `SelectionVisitor` in `Selection.cpp`:

```cpp
bool TraverseAttributedStmt(AttributedStmt *S) {
    return traverseNode(S, [&] {
        // Explicitly visit each attribute inside AttributedStmt
        for (const Attr *A : S->getAttrs())
            if (!TraverseAttr(const_cast<Attr *>(A)))
                return false;
        // Then traverse the child statement normally
        return TraverseStmt(S->getSubStmt());
    });
}
```

**Confirmed working** - hover now shows correct tooltips for all loop/branch attributes:
- `[unroll]` -> hover shows `unroll` with documentation 
- `[loop]` ->hover shows `loop` 
- `[branch]` -> hover shows `branch` 
- `[flatten]` -> hover shows `flatten` 

**Important discovery:** The zero-width source range (Problem D) did **not** need
to be fixed, the hover works correctly even with zero-width ranges, because
`traverseNode` finds the attribute as part of the `AttributedStmt` traversal
regardless of range matching.

**Why it works:** `HLSLLoopHintAttr` and `HLSLControlFlowHintAttr` already have
`Microsoft<>` spellings in `Attr.td`, so `getSpelling()` returns the correct
name automatically, no special case needed in `Hover.cpp`.

**Remaining open question:** The source range bug in `ParseDeclCXX.cpp` (Problem D)
still exists but is not blocking hover. It may still be worth fixing as a
correctness issue for other consumers of the source range.

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
  body, is this a source range issue or a traversal priority issue?

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

**Case 1 - `Type` field when hovering on the variable:**
```cpp
// getHoverContents(const NamedDecl *D)
else if (const auto *VD = dyn_cast<ValueDecl>(D))
    HI.Type = printType(VD->getType(), Ctx, PP);  // shows "float &__restrict"
```
`ParmVarDecl` is a subclass of `ValueDecl`, so it falls into this generic case.

**Case 2 - `Type` field in function signature tooltip:**
```cpp
// toHoverInfoParam()
Out.Type = printType(PVD->getType(), PVD->getASTContext(), PP);  // shows "float &__restrict"
```

**Case 3 - `Definition` line in hover tooltip:**
```cpp
// getHoverContents(const NamedDecl *D)
HI.Definition = printDefinition(D, PP, TB);  // shows "out float &__restrict b"
```
`printDefinition` calls `D->print()` which uses the internal C++ printer.

**Case 1 fix** - add a `ParmVarDecl` case before the generic `ValueDecl` case:

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

**Case 2 fix** - same logic in `toHoverInfoParam`:

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

**Case 3 fix** - override `HI.Definition` after `printDefinition`:

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

All three cases confirmed working - hover now shows:
- `a` (in) -> `Type: float` / `// In paramTest\nin float a`
- `b` (out) -> `Type: out float` / `// In paramTest\nout float b`
- `c` (inout) -> `Type: inout float` / `// In paramTest\ninout float c`

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

## I4 - Hover for Vector Swizzle and Matrix Element Access

### Problem

Hovering over `.xyz`, `._m00`, `._11_22` etc. produces no hover information.

### Root Cause

`ExtVectorElementExpr` and `MatrixElementExpr` are not compile-time constants, so
`printExprValue` returns `nullopt` and the hover path produces nothing. The fallback walks up
to the nearest `VarDecl` and shows the base variable type instead.

### Options Considered

**Option A - Language-specific dispatch layer**

Route HLSL expression nodes through a dedicated HLSL hover handler rather than adding
`dyn_cast` branches to the generic `getHoverContents`.

Disadvantage: a dispatch layer does not yet exist, and building one is out of scope for this
patch. `ExtVectorElementExpr` is also used by OpenCL and other vector extensions, so it is
not purely HLSL.

---

**Option B - `dyn_cast` branches in `getHoverContents` Chosen**

Add two branches following the same pattern as `CXXThisExpr` and `PredefinedExpr`:

```cpp
if (const auto *VecExpr = dyn_cast<ExtVectorElementExpr>(E)) {
  HI.emplace();
  HI->Name = VecExpr->getAccessor().getName().str();
  HI->Type = printType(VecExpr->getType(), AST.getASTContext(), PP);
  return HI;
}
if (const auto *MatExpr = dyn_cast<MatrixElementExpr>(E)) {
  HI.emplace();
  HI->Name = MatExpr->getAccessor().getName().str();
  HI->Type = printType(MatExpr->getType(), AST.getASTContext(), PP);
  return HI;
}
```

No evaluation needed. `getType()` is already resolved by Sema.

---
## I5 - `RootSignature` Hover Leaking Internal Identifier

### Problem

Hovering over `[RootSignature("RS_CBV")]` shows the definition as
`[RootSignature("__hlsl_rootsig_decl_5043168244180965862")]` instead of something
meaningful to the user.

### Root Cause

The HLSL parser calls `ParseHLSLRootSignature` to parse the root signature DSL string. This
function returns a generated `IdentifierInfo` with a hashed name (`__hlsl_rootsig_decl_<hash>`)
and stores it in `RootSignatureAttr::signatureIdent`. The original string literal (`"RS_CBV"`) is
not stored anywhere in the attribute after parsing.

The generic hover path calls `A->printPretty()`, which prints the stored identifier, leaking the
internal name.

`getSignatureIdent()->getName()` was also investigated, it returns the same generated name,
not the original string.

### Options Considered

**Option A - Store the original string literal in `RootSignatureAttr`**

Add a `StringRef` or `IdentifierInfo*` field to `RootSignatureAttr` in `Attr.td` that preserves
the original user-written string, and populate it in `ParseHLSLRootSignatureAttributeArgs`.

Disadvantage: requires changes to `Attr.td`, the generated attribute infrastructure, and the
parser. Out of scope for this patch.

---

**Option B - Recover the original string via `getSignatureDecl()`**

`RootSignatureAttr` also stores a `HLSLRootSignatureDecl*` via `getSignatureDecl()`. This
decl might carry the original name.

Investigation showed the decl name is also the generated `__hlsl_rootsig_decl_<hash>`
identifier, the original string is not recoverable through this path either.

---

**Option C - Skip `printPretty`; show documentation only Chosen**

Add a `dyn_cast<RootSignatureAttr>` branch in `getHoverContents(const Attr *A)` that sets
`HI.Name` and `HI.Documentation` and returns without setting `HI.Definition`:

```cpp
if (const auto *RS = llvm::dyn_cast<RootSignatureAttr>(A)) {
  HI.Name = "RootSignature";
  HI.Documentation = Attr::getDocumentation(A->getKind()).str();
  return HI;
}
```

This suppresses the leaking definition line without requiring any parser or `Attr.td` changes.

---

### Why Option C

Options A and B either require deeper changes out of scope for this patch or are technically
not possible. Option C is the minimal correct fix: it removes the confusing output and still
shows the useful documentation. Recovering the original string is documented as a known
limitation and future work.

---

## I6 - `register` Hover Not Triggered Inside Arguments

### Problem

Hovering inside `register(t1)`, for example on `t1`, produces no hover. Only hovering
directly on the `register` keyword triggers the tooltip.

### Root Cause

`ParseHLSLAnnotations` in `ParseHLSL.cpp` called `Attrs.addNew` with a single
`SourceLocation` (`Loc`, the start of the `register` keyword) instead of a `SourceRange`:

```cpp
Attrs.addNew(II, Loc, ...); // Loc is a single point
```

`addNew` has two overloads: one accepting `SourceLocation` (creates a zero-width range) and
one accepting `SourceRange`. The single-point overload was used, so the stored range for
`HLSLResourceBindingAttr` was always `Loc–Loc` (zero-width).

When the `SelectionTree` checks whether the cursor falls inside an attribute, it tests
`range.contains(cursor)`. A zero-width range only contains its own start point, so any cursor
position inside `(t1)`, including on `t`, `1`, or the parentheses, never matched.

This is the same class of zero-width range bug identified for `[unroll]` in I2, but caused by
the `addNew` call in the parser rather than by missing argument parsing.

### Options Considered

**Option A - Fix the range only for `AT_HLSLResourceBinding`**

Capture the closing `)` location inside the `AT_HLSLResourceBinding` case and pass a
`SourceRange` to `addNew` only for that case, leaving other attributes unchanged.

---

**Option B - Fix the range for all attributes via a shared `AttrEndLoc` variable Chosen**

Declare `SourceLocation AttrEndLoc = Loc` before the switch (defaulting to the start location,
preserving zero-width behavior for attributes that don't update it). Inside
`AT_HLSLResourceBinding`, capture `AttrEndLoc = Tok.getLocation()` before consuming the
closing `)`. Pass `SourceRange(Loc, AttrEndLoc)` to `addNew` for all cases:

```cpp
SourceLocation AttrEndLoc = Loc;

// inside AT_HLSLResourceBinding:
AttrEndLoc = Tok.getLocation();
if (ExpectAndConsume(tok::r_paren, diag::err_expected)) { ... }

// at addNew:
Attrs.addNew(II, SourceRange(Loc, AttrEndLoc), AttributeScopeInfo(),
             ArgExprs.data(), ArgExprs.size(), Form);
```

This is slightly more general than Option A and leaves a natural extension point for
`AT_HLSLPackOffset` if the same fix is needed there in the future.

---

## Idea I7: Hover for Resource Types (`Texture2D`, `RWTexture2D`, `SamplerState`)

### Gap

Hover is broken for HLSL resource types in different ways depending on the type:

- `Texture2D` - hover shows partial specialization error
- `RWTexture2D` - not recognized at all (`No template named 'RWTexture2D'`)
- `SamplerState` - shows `Incomplete type` error

### Root Cause

All three problems are Clang-level bugs, not clangd bugs:

**`Texture2D` - partial specialization bug:**

`Texture2D` is defined in `HLSLExternalSemaSource.cpp` but has an unresolved
partial specialization ambiguity. This causes the `VarDecl` to be marked
`invalid` in the AST:

```
VarDecl ... invalid myTex 'hlsl_constant int'
```

The type is incorrectly resolved as `hlsl_constant int` instead of
`Texture2D<float4>`.

**`RWTexture2D` - not implemented in Clang:**

`RWTexture2D` is simply not defined in `HLSLExternalSemaSource.cpp`. Confirmed:

```bash
grep -n "RWTexture2D" clang/lib/Sema/HLSLExternalSemaSource.cpp
# no output
```

Without this definition, the Clang doesn't know what `RWTexture2D` is, every use is an error and the AST is invalid for this type.

**`SamplerState` - incomplete type:**

`SamplerState` is defined but not fully resolved, producing an
`Incomplete type` diagnostic.

### Candidate Solution

All three require fixes in `clang/lib/Sema/HLSLExternalSemaSource.cpp`, 
clang problems, but prerequisites for any hover support.

### Open Questions

- Are other resource types (`RWTexture1D`, `RWTexture3D`, `Texture1D`, etc.)
  also missing?
- Should these be tracked as separate Clang bug reports?

### Files to Modify

- `clang/lib/Sema/HLSLExternalSemaSource.cpp` (Clang-level)

---

## Idea I8: Hover for `register` Bindings (`register(t0)`, `register(b1, space2)`)

### Gap

Hover for `register` bindings was broken for resource types. After Finn's
patch (I4), the status is now:

- `cbuffer` / `ConstantBuffer<T>` - always worked
- `Texture2D` -  works 
- `SamplerState` - works
- `RWTexture2D` - blocked by Clang-level work in progress (same as I4)

### What Changed

Before the patch, `Texture2D` and `RWTexture2D` variables were marked
`invalid` in the AST, causing `HLSLResourceBindingAttr` to be lost. After the
patch, `Texture2D` is correctly resolved and its `register` binding is
accessible to the SelectionTree.

### Remaining Gap

`Hover.cpp` has no display handler for `HLSLResourceBindingAttr`, the hover
works generically but could show richer information:

```bash
grep "HLSLResourceBinding" clang-tools-extra/clangd/Hover.cpp
# no output
```

A dedicated handler could show the slot and space more clearly:

```cpp
if (const auto *RB = llvm::dyn_cast<HLSLResourceBindingAttr>(A)) {
  std::string Slot = RB->getSlot().str();
  std::string Space = RB->getSpace().str();
  std::string Name = "register(" + Slot;
  if (!Space.empty() && Space != "space0")
    Name += ", " + Space;
  Name += ")";
  HI.Name = Name;
  HI.Documentation = Attr::getDocumentation(A->getKind()).str();
  return HI;
}
```

### Open Questions

- Should `space0` be shown explicitly or omitted as default?
- Is a dedicated display handler needed or is the generic one sufficient?

### Files to Modify

- `clang-tools-extra/clangd/Hover.cpp` (optional display handler)
- `clang-tools-extra/clangd/unittests/HoverTests.cpp`

---
## Idea I9: Code Completion Suggests Declaration Attributes Inside Statement Position (`[unroll]`, `[branch]`, etc.)

### Gap

Triggering code completion after `[` inside a statement (e.g. between `switch`
and the closing `}` of a function body) suggests every HLSL bracket attribute
indiscriminately, mixing statement attributes with declaration attributes:

```
branch
flatten
loop(directive)
numthreads(X, Y, Z)        <- declaration attribute, invalid here
RootSignature(SignatureIdent) <- declaration attribute, invalid here
shader(Type)                <- declaration attribute, invalid here
SV_DispatchThreadID(...)    <- semantic, invalid here
SV_GroupID(...)
...
unroll(directive)
```

`numthreads`, `RootSignature`, `shader`, and every `SV_*` semantic only make
sense on an entry-point function declaration, never inside a statement.

### Root Cause

Confirmed via the clangd trace log for the completion request:

```
Code complete: sema context Attribute, query scopes [] (AnyScope=true), expected type <none>
Code complete: 15 results from Sema, 0 from Index, 0 matched, 0 from identifiers, 15 returned.
```

`sema context Attribute` corresponds to `CodeCompletionContext::CCC_Attribute`,
set inside `SemaCodeCompletion::CodeCompleteAttribute`. Tracing the call chain
showed this project's own `CodeCompleteHLSLAnnotation` (added for semantic
completion after `:`) is never reached for this case, commenting it out had
no effect on the bug, confirming it wasn't the source.

Searching all call sites of `CodeCompleteAttribute` and narrowing by which
ones use `AttributeCommonInfo::AS_Microsoft` led to
`Parser::ParseMicrosoftAttributes` in `ParseDeclCXX.cpp`:

```cpp
void Parser::ParseMicrosoftAttributes(ParsedAttributes &Attrs) {
  assert(Tok.is(tok::l_square) && "Not a Microsoft attribute list");
  ...
  if (Tok.is(tok::code_completion)) {
    cutOffParsing();
    Actions.CodeCompletion().CodeCompleteAttribute(
        AttributeCommonInfo::AS_Microsoft,
        SemaCodeCompletion::AttributeCompletion::Attribute,
        /*Scope=*/nullptr);
    break;
  }
```

This function parses `[...]` bracket attributes and is shared between MSVC
(`__declspec`-style bracket attrs, e.g. `uuid`) and HLSL, confirmed by:

```cpp
// ParseDeclCXX.cpp:4456
if (getLangOpts().MicrosoftExt || getLangOpts().HLSL) {
```

The completion call filters candidates only by `AttributeCommonInfo::Syntax
== AS_Microsoft`. Every HLSL bracket attribute, statement attributes
(`[unroll]`, `[branch]`) and declaration attributes (`[numthreads]`,
`[RootSignature]`) alike, was given a `Microsoft<>` spelling as part of I1
(the semantic hover fix), which means they all share `AS_Microsoft` and are
therefore indistinguishable by `Syntax` alone at this call site. `Syntax`
was sufficient for MSVC's own bracket attributes, where no statement/declaration
split of this kind exists, so the gap was latent until HLSL's dual-context
bracket attributes exposed it.

Checking all call sites of `MaybeParseMicrosoftAttributes` confirmed the
statement/declaration split is knowable at the call site:

```bash
grep -rn "ParseMicrosoftAttributes(" clang/lib/Parse/*.cpp clang/include/clang/Parse/Parser.h
```

```
ParseDecl.cpp:6152      <- parameter declaration
ParseDecl.cpp:7641      <- parameter declaration
ParseDeclCXX.cpp:2788   <- decl-specifier
Parser.cpp:1060         <- decl-specifier
ParseStmt.cpp:76        <- statement, gated by `if (getLangOpts().HLSL)`
ParseTentative.cpp:1763 <- decl-specifier
```

Only `ParseStmt.cpp:76` is a statement context, and it is the only call site
gated on `getLangOpts().HLSL`, meaning it does not fire at all for
non-HLSL/MSVC code. The other five are unambiguously declaration/parameter
contexts. This confirms `ParsedAttrInfo::IsStmt` (already the basis of the
`TraverseAttributedStmt` fix in I2) is the correct discriminator, and that it
can be threaded through cleanly without touching non-HLSL behavior.

### Options Considered

**Option A - Filter inside the shared `CodeCompleteAttribute`**

Add a statement/declaration parameter directly to the generic
`SemaCodeCompletion::CodeCompleteAttribute`, used by `__declspec`, GNU
`__attribute__`, C++11 `[[...]]`, and Microsoft bracket attributes alike.
Rejected: this function is shared well beyond HLSL, and any change to its
filtering risks altering completion behavior for MSVC/C++ attributes that
have no statement/declaration ambiguity today.

---

**Option B - Thread `IsStmtContext` through `ParseMicrosoftAttributes` and
dispatch to a dedicated HLSL completion path Chosen**

Add a defaulted `bool IsStmtContext = false` parameter to
`MaybeParseMicrosoftAttributes` / `ParseMicrosoftAttributes`. Only
`ParseStmt.cpp:76` passes `true`; the other five call sites are unchanged,
preserving their existing (default) behavior exactly:

```cpp
bool MaybeParseMicrosoftAttributes(ParsedAttributes &Attrs,
                                    bool IsStmtContext = false) {
  if ((getLangOpts().MicrosoftExt || getLangOpts().HLSL) &&
      Tok.is(tok::l_square)) {
    ParsedAttributes AttrsWithRange(AttrFactory);
    ParseMicrosoftAttributes(AttrsWithRange, IsStmtContext);
    AttrsParsed = !AttrsWithRange.empty();
    Attrs.takeAllAppendingFrom(AttrsWithRange);
  }
  return AttrsParsed;
}
```

Inside `ParseMicrosoftAttributes`, only diverge from the existing generic
path when compiling HLSL, leaving MSVC/`uuid` completion untouched:

```cpp
if (Tok.is(tok::code_completion)) {
  cutOffParsing();
  if (getLangOpts().HLSL) {
    Actions.CodeCompletion().CodeCompleteHLSLAttributes(
        {AttributeCommonInfo::AS_Microsoft}, /*Kind=*/std::nullopt,
        /*RequireStmt=*/IsStmtContext,
        /*ExcludeKind=*/ParsedAttr::AT_HLSLParsedSemantic);
  } else {
    Actions.CodeCompletion().CodeCompleteAttribute(
        AttributeCommonInfo::AS_Microsoft,
        SemaCodeCompletion::AttributeCompletion::Attribute,
        /*Scope=*/nullptr);
  }
  break;
}
```

`CodeCompleteHLSLAttributes` filters `ParsedAttrInfo::getAllBuiltin()` by a
list of accepted `Syntax` values, an optional `ParsedAttr::Kind` restriction,
an optional `RequireStmt` flag, and an optional `ExcludeKind`:

```cpp
void SemaCodeCompletion::CodeCompleteHLSLAttributes(
    llvm::ArrayRef<AttributeCommonInfo::Syntax> Syntaxes,
    std::optional<ParsedAttr::Kind> RestrictToKind,
    bool RequireStmt,
    std::optional<ParsedAttr::Kind> ExcludeKind) {
  ResultBuilder Results(..., CodeCompletionContext::CCC_Attribute);
  for (const auto *A : ParsedAttrInfo::getAllBuiltin()) {
    if (!A->acceptsLangOpts(getLangOpts()))
      continue;
    if (RestrictToKind && A->AttrKind != *RestrictToKind)
      continue;
    if (ExcludeKind && A->AttrKind == *ExcludeKind)
      continue;
    if (A->IsStmt != RequireStmt)
      continue;
    for (const auto &S : A->Spellings) {
      if (!llvm::is_contained(Syntaxes, S.Syntax))
        continue;
      // add completion item
    }
  }
}
```

The `ExcludeKind=AT_HLSLParsedSemantic` parameter is required because
`SV_*` semantics also have `IsStmt=0`, the same as declaration attributes
like `numthreads` and `shader`. Without the exclusion, the declaration
context completion (`[` outside a function) would incorrectly include
`SV_Target`, `SV_Position`, etc., which are only valid after `:` in
parameter/return type annotations, not inside `[...]` brackets.

---

### Why Option B

Option A risks regressing completion for non-HLSL Microsoft/C++ attributes
that never needed a statement/declaration distinction. Option B isolates the
fix to the single call site that is already exclusively HLSL-gated
(`ParseStmt.cpp:76`), leaves the five declaration/parameter call sites
byte-for-byte unchanged via the defaulted parameter, and reuses the same
`IsStmt` field that already grounds the I2 hover fix, keeping the
statement/declaration distinction consistent across both hover and
completion.

### Result

| Context | Before | After |
|---|---|---|
| `[` inside function body | all attrs mixed | only `branch`, `flatten`, `loop`, `unroll` |
| `[` outside function (global) | all attrs mixed | only `numthreads`, `shader`, `RootSignature`, `WaveSize` |

### Known Limitation (Out of Scope for This Fix)

Completion after `:` (semantic annotation position) still mixes `register`,
`packoffset`, and semantic names, since all three are syntactically valid
after `TypeName varName :` and this call site (`ParseHLSLAnnotations`, not
`ParseMicrosoftAttributes`) does not currently inspect the declared type to
disambiguate resource declarations from shader I/O parameters. Tracked
separately; not addressed by this change.

### Files Modified

- `clang/include/clang/Parse/Parser.h` - `MaybeParseMicrosoftAttributes` /
  `ParseMicrosoftAttributes` signatures updated with `bool IsStmtContext = false`
- `clang/lib/Parse/ParseDeclCXX.cpp` - `ParseMicrosoftAttributes` body
  dispatches to `CodeCompleteHLSLAttributes` for HLSL, passing `IsStmtContext`
  and `ExcludeKind=AT_HLSLParsedSemantic`
- `clang/lib/Parse/ParseStmt.cpp` - passes `/*IsStmtContext=*/true` at the
  HLSL statement call site
- `clang/include/clang/Sema/SemaCodeCompletion.h` - `CodeCompleteHLSLAttributes`
  declaration with 4 parameters (Syntaxes, RestrictToKind, RequireStmt, ExcludeKind)
- `clang/lib/Sema/SemaCodeComplete.cpp` - `CodeCompleteHLSLAttributes`
  implementation
- `clang-tools-extra/clangd/unittests/CodeCompleteTests.cpp` - tests 
---
## Idea I10: Code Completion Inside `register(...)` Arguments

### Gap

Triggering code completion inside `register(...)` produces generic top-level
completion (types, keywords, intrinsics) instead of the valid resource slot
prefixes and the `space` keyword:

```hlsl
StructuredBuffer<int> buf : register(|)        // shows types/keywords, not t/u/b/s
StructuredBuffer<int> buf : register(t0, |)    // shows types/keywords, not "space"
```

### Root Cause

`ParseHLSLAnnotations` in `clang/lib/Parse/ParseHLSL.cpp` handles the
`AT_HLSLResourceBinding` case but had no `tok::code_completion` hooks inside
the argument parsing logic. The `tok::code_completion` token fell through to
the `!Tok.is(tok::identifier)` error branch, which called
`SkipUntil(tok::r_paren)` and returned, the parser then resumed at top-level
context, producing generic completion results.

### Solution (Implemented)

Two `tok::code_completion` hooks added inside `case ParsedAttr::AT_HLSLResourceBinding`:

**Hook 1 - slot prefix position** (`register(|`):

```cpp
// Code completion for the resource slot prefix: register(t|
if (Tok.is(tok::code_completion)) {
  ConsumeCodeCompletionToken();
  Actions.CodeCompletion().CodeCompleteHLSLResourceSlot(D);
  return;
}
if (!Tok.is(tok::identifier)) { ... }
StringRef SlotStr = Tok.getIdentifierInfo()->getName();
```

**Hook 2 - space position** (`register(t0, |`):

```cpp
ConsumeToken(); // consume comma
// Code completion for the space keyword: register(t0, space|
if (Tok.is(tok::code_completion)) {
  ConsumeCodeCompletionToken();
  Actions.CodeCompletion().CodeCompleteHLSLResourceSpace();
  return;
}
if (!Tok.is(tok::identifier)) { ... }
```

Both hooks use `ConsumeCodeCompletionToken()` instead of `cutOffParsing()`,
consistent with the approach adopted in I9 for `ParseHLSLAnnotations`.

**`CodeCompleteHLSLResourceSlot`** receives the `Declarator *D` and filters
by resource type using the same record-name mapping as `CodeCompleteHLSLAnnotation`.
If the type is known, only the matching prefix is suggested; otherwise all four
are shown as fallback:

```cpp
void SemaCodeCompletion::CodeCompleteHLSLResourceSlot(const Declarator *D) {
  char KnownSlot = 0;
  if (D) { /* same type resolution as CodeCompleteHLSLAnnotation */ }

  static const SlotPrefix Prefixes[] = {
      {"t", "Shader resource view (SRV)"},
      {"u", "Unordered access view (UAV)"},
      {"b", "Constant buffer (CBV)"},
      {"s", "Sampler state"},
  };
  for (const auto &P : Prefixes) {
    if (KnownSlot && P.Letter[0] != KnownSlot)
      continue; // skip non-matching slots when type is known
    // CCB.AddTypedTextChunk(P.Letter) + CCB.AddPlaceholderChunk("0")
  }
}
```

```hlsl
RWStructuredBuffer<float4> buf : register(|)  // suggests only: u0 
StructuredBuffer<float4>   buf : register(|)  // suggests only: t0 
SamplerState               s   : register(|)  // suggests only: s0 
// unknown type: shows all t0, u0, b0, s0
```

**`CodeCompleteHLSLResourceSpace`** suggests `space` with a `0` placeholder:

```cpp
CCB.AddTypedTextChunk("space");
CCB.AddPlaceholderChunk("0");
```

Both lists are intentionally small and hardcoded, unlike semantics and
bracket attributes, these are not registered in `Attr.td` as named spellings.
The slot prefixes (`t`, `u`, `b`, `s`) and the `space` keyword are parsed
as raw strings inside the `AT_HLSLResourceBinding` custom parser, so there
is no TableGen source to drive them.

### Files Modified

- `clang/lib/Parse/ParseHLSL.cpp` - two `tok::code_completion` hooks inside
  `case ParsedAttr::AT_HLSLResourceBinding`
- `clang/include/clang/Sema/SemaCodeCompletion.h` - declarations for
  `CodeCompleteHLSLResourceSlot(const Declarator *D = nullptr)` and
  `CodeCompleteHLSLResourceSpace`
- `clang/lib/Sema/SemaCodeComplete.cpp` - implementations of both functions
- `clang-tools-extra/clangd/unittests/CodeCompleteTests.cpp` - tests

---

## Idea I11: Code Completion for HLSL Annotations After `:`

### Gap

Typing `: ` after a variable or parameter declaration in HLSL produced no
completion results from clangd, the editor fell back to text-based
suggestions only:

```hlsl
float4 PSMain() : |          // no clangd suggestions
float4 color : |             // no clangd suggestions
Texture2D tex : |            // no clangd suggestions
RWStructuredBuffer<float4> buf : |  // no clangd suggestions
```

### Root Cause

HLSL annotations after `:` are parsed by `ParseHLSLAnnotations` in
`clang/lib/Parse/ParseHLSL.cpp`, a completely separate path from `[[...]]`
attribute parsing. The function had no `tok::code_completion` hook.

When the user typed `: ` and stopped, the token fell into the `if (!II)`
error branch and was discarded:

```
tok::colon -> consumed
tok::code_completion -> not kw_register, not identifier -> II = nullptr
if (!II) -> Diag(err_expected_semantic_identifier) -> return
```

### Solution (Implemented)

**Hook in `ParseHLSLAnnotations`:**

```cpp
else if (Tok.is(tok::code_completion)) {
  ConsumeCodeCompletionToken();
  Actions.CodeCompletion().CodeCompleteHLSLAnnotation(D);
  return;
}
```

**`ParseHLSLAnnotations` signature extended** to accept `const Declarator *D`:

```cpp
void Parser::ParseHLSLAnnotations(ParsedAttributes &Attrs,
                                  SourceLocation *EndLoc = nullptr,
                                  bool CouldBeBitField = false,
                                  const Declarator *D = nullptr);
```

`MaybeParseHLSLAnnotations(Declarator &D)` passes `&D` through, making the
declared type available at the completion call site.

**`CodeCompleteHLSLAnnotation`** data-driven from `Attr.td`, with
type-aware slot filtering:

```cpp
void SemaCodeCompletion::CodeCompleteHLSLAnnotation(const Declarator *D) {
  // Determine the register slot from the declared type name.
  // HLSLAttributedResourceType is not yet built at parse time, so we
  // match the CXXRecordDecl name directly.
  char KnownSlot = 0;
  if (D) {
    const DeclSpec &DS = D->getDeclSpec();
    if (DS.getTypeSpecType() == DeclSpec::TST_typename) {
      QualType QT = SemaRef.GetTypeFromParser(DS.getRepAsType());
      if (!QT.isNull()) {
        const Type *Ty = QT->getUnqualifiedDesugaredType();
        if (const CXXRecordDecl *RD = Ty->getAsCXXRecordDecl()) {
          llvm::StringRef TypeName = RD->getName();
          if (TypeName.starts_with("RW") ||
              TypeName.starts_with("RasterizerOrdered"))
            KnownSlot = 'u';
          else if (TypeName == "StructuredBuffer" ||
                   TypeName == "Buffer" ||
                   TypeName.starts_with("Texture") ||
                   TypeName == "ByteAddressBuffer")
            KnownSlot = 't';
          else if (TypeName == "ConstantBuffer")
            KnownSlot = 'b';
          else if (TypeName.starts_with("Sampler"))
            KnownSlot = 's';
        }
      }
    }
  }
  // ... iterate Attr.td builtins, emit register/packoffset snippets
  // and semantic keywords
}
```

**Snippet completion for `register` and `packoffset`:**

`register` uses `CCP_CodePattern` with `CXCursor_Constructor` to prevent
`shouldPatchPlaceholder0` from converting the last placeholder to `$0`:

```cpp
char SlotAsText[] = {KnownSlot, '\0'};
CCB.AddTypedTextChunk("register");
CCB.AddChunk(CodeCompletionString::CK_LeftParen);
CCB.AddTextChunk(SlotAsText);
CCB.AddPlaceholderChunk("0"); 
CCB.AddChunk(CodeCompletionString::CK_Comma);
CCB.AddChunk(CodeCompletionString::CK_HorizontalSpace);
CCB.AddTextChunk("space");
CCB.AddPlaceholderChunk("0");
CCB.AddChunk(CodeCompletionString::CK_RightParen);
CCB.AddChunk(CodeCompletionString::CK_SemiColon);
Results.AddResult(CodeCompletionResult(CCB.TakeString(), CCP_CodePattern,
                                       CXCursor_Constructor));
```

### Result

```hlsl
RWStructuredBuffer<float4> buf : |
// suggests: register(u0, space0) <- slot filtered by type 
//           packoffset(c0)
//           SV_Target, SV_Position, SV_DispatchThreadID, ...

StructuredBuffer<float4> buf : |
// suggests: register(t0, space0) <- correct SRV slot 

SamplerState s : |
// suggests: register(s0, space0) <- correct sampler slot 
```

Tab navigation works between placeholders:
- Select `register(u0, space0)` -> cursor on `u0` -> Tab -> cursor on `space0`

### Files Modified

- `clang/include/clang/Parse/Parser.h` - `ParseHLSLAnnotations` and
  `MaybeParseHLSLAnnotations(Declarator &D)` updated to pass `const Declarator *D`
- `clang/lib/Parse/ParseHLSL.cpp` - `tok::code_completion` hook calling
  `CodeCompleteHLSLAnnotation(D)`
- `clang/include/clang/Sema/SemaCodeCompletion.h` - declaration of
  `CodeCompleteHLSLAnnotation(const Declarator *D = nullptr)`
- `clang/lib/Sema/SemaCodeComplete.cpp` - full implementation
- `clang-tools-extra/clangd/unittests/CodeCompleteTests.cpp` - tests 

---
## Idea I12: Code Completion for HLSL Vector Swizzle Members

### Gap

Typing `v.` on an HLSL vector produced no swizzle component suggestions from
clangd. Additionally, typing a partial swizzle like `v.x` produced no
continuation suggestions:

```hlsl
float3 v;
v.|    // no suggestions
v.x|   // no suggestions
v.xr|  // no suggestions (invalid - mixing sets)
```

### Root Cause

`CodeCompleteMemberReferenceExpr` handled `RecordDecl` members and ObjC
properties, but had no case for `ExtVectorType`, the AST representation of
HLSL vectors (`float2`, `float4`, etc.). The type fell through all branches
with no results.

Additionally, the partially-typed swizzle prefix (e.g. `"x"` when user typed
`v.x`) was available via `SemaRef.PP.getCodeCompletionFilter()` but was not
being used to filter or extend suggestions.

### Solution (Implemented)

Added `AddHLSLVectorSwizzleCompletions` called from `DoCompletion` inside
`CodeCompleteMemberReferenceExpr`:

```cpp
} else if (getLangOpts().HLSL && !IsArrow) {
  if (const auto *VT = BaseType->getAs<ExtVectorType>())
    AddHLSLVectorSwizzleCompletions(SemaRef, Results, VT);
  else if (const auto *MT = BaseType->getAs<ConstantMatrixType>())
    AddHLSLMatrixSwizzleCompletions(SemaRef, Results, MT);
}
```

`AddHLSLVectorSwizzleCompletions` reads `getCodeCompletionFilter()` to get
the already-typed prefix and applies three semantic rules:

1. **No mixing sets**: `xyzw` and `rgba` cannot be mixed (e.g. `xr` is
   invalid in HLSL and produces a compiler error)
2. **Max 4 components**: swizzles longer than 4 are invalid
3. **Only valid components for the vector size**: `float2` has no `z` or `b`

The `filterText` of each suggestion includes the already-typed prefix so the
clangd client can match correctly:

```cpp
StringRef Filter = SemaRef.PP.getCodeCompletionFilter();
// ...
if (!Filter.empty()) {
  llvm::SmallString<8> FullText(Filter);
  FullText += XYZWNames[I];
  CCB.AddTypedTextChunk(Results.getAllocator().CopyString(FullText));
} else {
  CCB.AddTypedTextChunk(XYZWNames[I]);
}
```

### Rules Summary

| Condition | Behavior |
|---|---|
| `v.` | suggests `x`, `y`, `z`, `r`, `g`, `b` (for `float3`) |
| `v.x` | suggests `x`, `y`, `z` only (xyzw set detected, rgba excluded) |
| `v.r` | suggests `r`, `g`, `b` only (rgba set detected, xyzw excluded) |
| `v.xr` | no suggestions (mixing sets - semantically invalid) |
| `v.xyzw` | no suggestions (4 components - maximum reached) |

### Files Modified

- `clang/lib/Sema/SemaCodeComplete.cpp`, `AddHLSLVectorSwizzleCompletions`
  function + hook in `CodeCompleteMemberReferenceExpr`

---

## Idea I13: Code Completion for HLSL Matrix Swizzle Members

### Gap

Typing `m.` on an HLSL matrix produced no swizzle component suggestions.
HLSL supports two matrix swizzle notations that cannot be mixed:

```hlsl
float2x2 m;
m.|         // no suggestions
m._m00|     // no suggestions
m._11|      // no suggestions
m._m00_11|  // no suggestions (invalid - mixing notations)
```

### Root Cause

Same as I12, `CodeCompleteMemberReferenceExpr` had no case for
`ConstantMatrixType`. Added in the same branch as I12.

### Solution (Implemented)

`AddHLSLMatrixSwizzleCompletions` reads `getCodeCompletionFilter()` and
applies three semantic rules specific to matrix swizzles:

1. **No mixing notations**: `_m` (0-indexed) and `_` (1-indexed) cannot
   be mixed (e.g. `_m00_11` is invalid)
2. **Max 4 components**: same as vector swizzles
3. **Only valid indices for the matrix size**: `float2x2` has no `_m22`

Detection of which notation is in use is based on the filter prefix:
- Starts with `_m` -> 0-indexed notation, each component is 4 chars (`_mRC`)
- Starts with `_` (not `_m`) -> 1-indexed notation, each component is 3 chars (`_RC`)
- Filter size must be a multiple of the component size (no mid-component suggestions)

```cpp
if (Filter.starts_with("_m")) {
  UseOneNotation = false;
  if (Filter.size() % 4 != 0 || Filter.size() >= 16) return;
} else if (Filter.starts_with("_")) {
  UseMNotation = false;
  if (Filter.size() % 3 != 0 || Filter.size() >= 12) return;
} else {
  return; // unknown prefix
}
```

The `filterText` includes the already-typed prefix (same technique as I12).

### Rules Summary

| Condition | Behavior |
|---|---|
| `m.` | suggests `_m00`..,`_m11`, `_11`..`_22` (for `float2x2`) |
| `m._m00` | suggests `_m00_m00`, `_m00_m01`, etc. (`_m` notation locked) |
| `m._11` | suggests `_11_11`, `_11_12`, etc. (`_` notation locked) |
| `m._m00_11` | no suggestions (mixing notations - invalid) |
| `m._m00_m01_m10_m11` | no suggestions (4 components - maximum) |

### Files Modified

- `clang/lib/Sema/SemaCodeComplete.cpp`, `AddHLSLMatrixSwizzleCompletions`
  function + hook in `CodeCompleteMemberReferenceExpr` (shared with I12)

---

## Summary Table

| ID | Gap | Root Cause | Status |
|----|-----|-----------|--------|
| I1 | Hover for semantics | `getSpelling()` returns `(No spelling)` for `HLSLParsedSemanticAttr` | Implemented, explicit `def` per semantic in `Attr.td` + `SemaHLSL.cpp` updated; 7 system semantics working |
| I2 | Hover for loop/branch attrs | `AttributedStmt` not traversed in `Selection.cpp` | Implemented, `TraverseAttributedStmt` added to `Selection.cpp`; all 4 attributes working |
| I3 | Hover for `out`/`inout` qualifiers | `ParmVarDecl` type printed as internal C++ `float &__restrict` | Prototype confirmed working in all 3 locations |
| I4 | Hover for vector swizzle and matrix element access | No case in `getHoverContents` for `ExtVectorElementExpr` / `MatrixElementExpr` | Added `dyn_cast` branches in `getHoverContents` for both node types |
| I5 | RootSignature hover leaks internal identifier | Original string literal discarded by parser; only generated `__hlsl_rootsig_decl_<hash>` stored | Skip `printPretty`, now shows just the documentation |
| I6 | `register` hover not triggered inside argument | Zero-width `SourceRange` in `HLSLResourceBindingAttr`; cursor inside `(t1)` never matched | Zero-width `SourceRange` fixed, hover now shows documentation |
| I7 | Hover for resource types | Clang-level bugs: `Texture2D` partial spec, `RWTexture2D` not implemented, `SamplerState` incomplete | All three are Clang bugs, prerequisites for clangd fixes |
| I8 | Hover for `register` bindings | `Texture2D`/`RWTexture2D` blocked by I7; `SamplerState` attr present but not traversed; no display handler in `Hover.cpp` | Depends on I7; `SamplerState` traversal under investigation |
| I9 | Completion inside `[...]` mixes statement and declaration attrs | `ParseMicrosoftAttributes` had no HLSL-aware filtering; `IsStmt` not threaded through | Implemented: `IsStmtContext` + `bool RequireStmt` (simplified from `optional<bool>`); `CodeCompleteHLSLAttributes` with `ExcludeKind` |
| I10 | Completion inside `register(...)` shows generic results | No `tok::code_completion` hooks inside `AT_HLSLResourceBinding` parser | Implemented: hooks for slot prefix and `space0`; `CodeCompleteHLSLResourceSlot(D)` filters by declared type (e.g. only `u0` for `RWStructuredBuffer`) |
| I11 | Completion after `:` shows nothing; no type-aware slot filtering | No hook in `ParseHLSLAnnotations`; `Declarator*` not threaded through | Implemented: hook added; `CodeCompleteHLSLAnnotation(D)` filters slot by record name; snippet Tab stops for `register` and `packoffset` |
| I12 | No swizzle completion for HLSL vectors | `ExtVectorType` not handled in `CodeCompleteMemberReferenceExpr` | Implemented: `AddHLSLVectorSwizzleCompletions` with set-mixing detection and 4-component limit via `getCodeCompletionFilter()` |
| I13 | No swizzle completion for HLSL matrices | `ConstantMatrixType` not handled in `CodeCompleteMemberReferenceExpr` | Implemented: `AddHLSLMatrixSwizzleCompletions` with notation-mixing detection (`_m` vs `_`) and 4-component limit |