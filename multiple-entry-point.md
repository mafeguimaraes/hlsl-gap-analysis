# HLSL clangd: Multiple Entry Point Support, Investigation and Results

This document summarizes the investigation of the "multiple entry point" problem (multiple shader
stages, vertex, pixel, compute, etc., in the same `.hlsl` file), including a working prototype of the context-switching mechanism.

---

## 1. The original problem

An `.hlsl` file can contain multiple entry functions (`VSMain`, `PSMain`, `CSMain`, etc.), each
belonging to a different shader stage. clangd needs to know, at any given moment, which
`CompileCommand` to use to build the AST, which raises two questions:

1. A file with no matching entry in `compile_commands.json`: how should clangd compile it by
   default (fallback)?
2. A file with multiple entries in `compile_commands.json` (one per stage): how do we let the
   user work with all entry points, given that clangd can only have one active AST per file?

## 2. Finding 1: the fallback already solves the modern case

**Change implemented** in `GlobalCompilationDatabase::getFallbackCommand`
(`clang-tools-extra/clangd/GlobalCompilationDatabase.cpp`):

```cpp
else if (FileExtension == ".hlsl")
  // No compile_commands.json entry for this shader: assume a standalone
  // HLSL library target so hover/diagnostics/completion work across all
  // entry points in the file without picking a specific shader stage.
  Argv.insert(Argv.end(), {"-x", "hlsl", "-target",
                           "dxil-pc-shadermodel6.3-library"});
```

**Validation:** a file with `[shader("vertex")]`, `[shader("pixel")]`, and `[shader("compute")]`
at the same time, compiled in `library` mode, produces a single AST containing all entry
points, each with its own `HLSLShaderAttr` and semantics validated independently (confirmed by
hover, diagnostics, and `documentSymbol` all working correctly for the three at once).

**Conclusion:** for the modern HLSL style (explicit `[shader("...")]` per function), the multiple
entry point problem is already solved with this simple fallback. No context-switching
mechanism is needed.


## 3. Finding 2: the legacy case (without `[shader(...)]`) still breaks

Tested with a `compile_commands.json` with two entries for the same file:

```json
{"command": "clang -x hlsl -target dxil-pc-shadermodel6.3-vertex -hlsl-entry VSMain ..."}
{"command": "clang -x hlsl -target dxil-pc-shadermodel6.3-pixel  -hlsl-entry PSMain ..."}
```

clangd (via `DirectoryBasedGlobalCompilationDatabase::getCompileCommand`) picks only the first
entry (`Candidates.front()`) and ignores the second. Confirmed in the log: the AST for
`shader_legacy.hlsl` was built only with the `vertex`/`VSMain` command.

**Root mechanism** (`SemaHLSL::ActOnTopLevelFunction`, called from `SemaDecl.cpp`):

```cpp
if (NewFD->hasAttr<HLSLShaderAttr>())
  HLSL().CheckEntryPoint(NewFD);
```

Without `[shader(...)]`, a function only becomes an entry point (and only then has its semantics
validated) if the `CompileCommand`'s *triple* already specifies a concrete stage (`-target
...-vertex`, not `library`) and `-hlsl-entry <name>` matches the function name; in that case
the `HLSLShaderAttr` is synthesized implicitly. Since a single triple only carries one stage at a
time, a single `CompileCommand` never treats VS and PS from the same file as entry points at
the same time in the legacy style, unlike `library` mode with `[shader(...)]`, which already
solves this for free.

**Conclusion:** the multiple entry point problem is real only for the legacy style
(`-hlsl-entry`/`-T` via command line, with no attribute in the source).

## 4. Prototype of the context-switching mechanism 

Tested with a Python script speaking LSP directly to `clangd` via stdin/stdout.

### Low-level mechanism: `workspace/didChangeConfiguration`

clangd already exposes, via a standard LSP protocol extension, a way to update the
`CompileCommand` of an open file without closing and reopening it:

```json
{
  "method": "workspace/didChangeConfiguration",
  "params": {
    "settings": {
      "compilationDatabaseChanges": {
        "<file>": {
          "workingDirectory": "...",
          "compilationCommand": ["clang", "-x", "hlsl", "-target", "...-pixel",
                                  "-hlsl-entry", "PSMain", "..."]
        }
      }
    }
  }
}
```

Internally: `ClangdLSPServer::applyConfiguration` calls `OverlayCDB::setCompileCommand` (updates
an in-memory map and trigger `OnCommandChanged.broadcast`), which then goes through
`ClangdServer::reparseOpenFilesIfNeeded` (rebuilds the file's AST with the new command).

**Validated with a real execution log:**
- Before the switch: `HLSLShaderAttr` synthesized at the `VSMain` line (line 6).
- After the switch: `HLSLShaderAttr` synthesized at the `PSMain` line (line 13).
- The AST is rebuilt (`Rebuilding invalidated preamble`) with the new triple/`-hlsl-entry`.

**Persistence tested:** closing and reopening the document (`didClose`/`didOpen`), with the same
clangd process still running, keeps the choice made. The state lives in `OverlayCDB`, not in
the document. It is only lost if the clangd process is restarted.

### Convenience command: `clangd.hlslEntryPoints`

Implemented a new `workspace/executeCommand` that lists the top-level functions in the file, with
the stage already known (if the function has `HLSLShaderAttr` in the current AST), without trying
to infer anything for functions that do not. This follows the preference already expressed by the
LLVM/DirectX community (Discord) for explicit user control over automatic stage inference.

Example of a real response, with `VSMain` active (via `compile_commands.json`) and `PSMain`
unannotated:

```json
[{"name": "VSMain", "stage": "vertex"}, {"name": "PSMain"}]
```

Implemented in three layers, following the same pattern as `clangd.applyTweak`:
- `Protocol.h`/`.cpp`: `HLSLEntryPointsArgs` struct (just `{file}`).
- `ClangdServer.h`/`.cpp`: `getHLSLEntryPoints`, runs via `WorkScheduler->runWithAST`, iterates
  `TranslationUnitDecl::decls()`, filters `FunctionDecl` with a body, reports `HLSLShaderAttr` if
  present.
- `ClangdLSPServer.h`/`.cpp`: `clangd.hlslEntryPoints` command, handler, registered in
  `Bind.command(...)` and in the `executeCommandProvider` list.

**Limitation identified in this version:** the command only reports what the AST that is
currently active already knows. It has no visibility into the other entries that exist in
`compile_commands.json` for the same file, so `PSMain` showed up without a `stage` whenever
`VSMain` was the active entry, even though a `pixel`/`PSMain` entry was available in
`compile_commands.json`. This left discovering the alternative options up to the client (it would
have to read the raw `compile_commands.json` and manually parse the flags, including handling two
different conventions: the native clang `-hlsl-entry`/`-target`, and dxc mode's `-T`/`-E` via
`--driver-mode=dxc`).

## 5. Automatic discovery of all available entries

To remove this limitation, `clangd.hlslEntryPoints` was extended to query all the entries in
`compile_commands.json` for the file, not just the active one, closing the gap without requiring
any string parsing on the client.

### New server API: `GlobalCompilationDatabase::getAllCompileCommands`

The public clangd interface (`GlobalCompilationDatabase::getCompileCommand`, singular) always
returned only one entry, using `.front()`.
A new method was added, mirroring the same delegation chain already used by `getCompileCommand`
across the three implementations:

```cpp
// GlobalCompilationDatabase.h, virtual method with a default body
virtual std::vector<tooling::CompileCommand>
getAllCompileCommands(PathRef File) const {
  if (auto Cmd = getCompileCommand(File))
    return {std::move(*Cmd)};
  return {};
}
```

- `DirectoryBasedGlobalCompilationDatabase::getAllCompileCommands`: reuses
  `Res->CDB->getCompileCommands(File)`, the low-level `tooling::CompilationDatabase` API that
  already returned all entries all along.
- `OverlayCDB::getAllCompileCommands`: if a command was set manually (via
  `setCompileCommand`/`didChangeConfiguration`), it is the single source of truth, otherwise, it
  delegates to `DelegatingCDB`.
- `DelegatingCDB::getAllCompileCommands`: passes through to `Base`, the same pattern as
  `getCompileCommand`.

### Rewrite of `ClangdServer::getHLSLEntryPoints`

Instead of running `WorkScheduler->runWithAST` (which only sees the active AST), the new version
iterates `CDB.getAllCompileCommands(File)` and, for each candidate, calls
`buildCompilerInvocation` (`clang-tools-extra/clangd/Compiler.cpp`), the same function used
internally by `TUScheduler` to resolve a `CompileCommand` into a structured `CompilerInvocation`,
without needing to build the full AST:

```cpp
void ClangdServer::getHLSLEntryPoints(PathRef File,
                                      Callback<llvm::json::Value> CB) {
  llvm::json::Array Result;
  for (const auto &Cmd : CDB.getAllCompileCommands(File)) {
    ParseInputs Inputs;
    Inputs.CompileCommand = Cmd;
    Inputs.TFS = &TFS;
    IgnoringDiagConsumer IgnoreDiags;
    auto Invocation = buildCompilerInvocation(Inputs, IgnoreDiags);
    if (!Invocation)
      continue;
    llvm::json::Object Entry;
    if (!Invocation->getTargetOpts().HLSLEntry.empty())
      Entry["name"] = Invocation->getTargetOpts().HLSLEntry;
    auto Env = llvm::Triple(Invocation->getTargetOpts().Triple).getEnvironment();
    if (Env != llvm::Triple::UnknownEnvironment && Env != llvm::Triple::Library)
      Entry["stage"] = HLSLShaderAttr::ConvertEnvironmentTypeToStr(Env);
    Entry["command"] = llvm::json::Array(Cmd.CommandLine);
    if (!Entry.empty())
      Result.push_back(std::move(Entry));
  }
  CB(llvm::json::Value(std::move(Result)));
}
```

**Why this solves the two flag conventions without manual parsing:** the `createInvocation` call
inside `buildCompilerInvocation` already runs the clang driver behind the scenes, and the driver
already normalizes `--driver-mode=dxc -T vs_6_0 -E VSMain` into the same structured fields
(`TargetOpts().HLSLEntry`, `TargetOpts().Triple`) that the native convention (`-hlsl-entry VSMain
-target ...-vertex`) uses. The official Clang HLSL documentation confirms this normalization,
noting that the DXC `/E` option is translated to the cc1 flag `-hlsl-entry`. This removes any need
for regex or convention-recognition logic on the client side.

**Real result, with both entries from `compile_commands.json`** (`vertex`/`VSMain` and
`pixel`/`PSMain`):

```json
[
  {
    "command": ["clang", "-x", "hlsl", "-target", "dxil-pc-shadermodel6.3-vertex",
                "-hlsl-entry", "VSMain", "-resource-dir=...", "shader_legacy.hlsl"],
    "name": "VSMain",
    "stage": "vertex"
  },
  {
    "command": ["clang", "-x", "hlsl", "-target", "dxil-pc-shadermodel6.3-pixel",
                "-hlsl-entry", "PSMain", "-resource-dir=...", "shader_legacy.hlsl"],
    "name": "PSMain",
    "stage": "pixel"
  }
]
```

Note that now both entries show up with the correct `stage`, even though only `VSMain` was
active in the AST at the time of the call, and each entry already includes the full `command`,
ready to be resent.

### End-to-end test: 

A Python script that closes the full loop, reusing the `command` returned by
`clangd.hlslEntryPoints` literally without touching anything inside a
`workspace/didChangeConfiguration`:

1. Calls `clangd.hlslEntryPoints`.
2. Picks the `PSMain` entry from the response.
3. Hovers over `PSMain` (baseline, before the switch).
4. Sends `didChangeConfiguration` with `compilationCommand: target["command"]`, with no parsing,
   no reconstruction, and no knowledge of flag conventions.
5. Hovers over `PSMain` again (after the switch).

**Confirmed in the execution log:**
- Before: `[Selection] TraverseAttr: shader range=...:6:1-...` (`VSMain`'s line).
- After: `[Selection] TraverseAttr: shader range=...:13:1-...` (`PSMain`'s line).

The synthesized `HLSLShaderAttr` migrated from one function to another within the same clangd
run, confirming that the discovery-plus-activation pair works end to end with no business logic
on the client side at all. The client only needs to: 

(a) call the discovery command, 

(b) let the user pick an entry from the list, 

(c) resend that entry's `command` via
`didChangeConfiguration`. There is no string parsing, no need to recognize flag conventions, and
no need to duplicate driver-resolution logic on the client.

## 6. Current state and next steps

| Item | Status |
|---|---|
| Library-mode fallback (`.hlsl` with no compile_commands.json) | Implemented and validated |
| Context-switching mechanism (`didChangeConfiguration`) | Validated, no new code in clangd |
| `GlobalCompilationDatabase::getAllCompileCommands` (new API) | Implemented and tested |
| `clangd.hlslEntryPoints` command (discovery of all entries) | Implemented and tested end to end |
| Client extension (VS Code), quick-pick/switching UX | Out of scope for GSoC, future work |
| Upstream PRs | None opened yet |

