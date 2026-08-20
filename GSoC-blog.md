# Improving HLSL Support in clangd - GSoC 2026 Final Report

**Contributor:** Maria Fernanda Guimarães

**Organization:** LLVM Compiler Infrastructure

**Mentors:** Finn Plummer, Ashley Coleman

---

## 1. Introduction

HLSL (High-Level Shading Language) is a C++-like language used for GPU shader programming. Clang already provides support for parsing HLSL and represents many of its language constructs in the Clang AST.

`clangd` provides IDE features such as hover, code completion, diagnostics, and symbol navigation. While many features can be reused from its existing C/C++ infrastructure, HLSL introduces constructs that have no direct equivalent in standard C++, such as:

* semantic annotations such as `SV_Target` and `SV_Position`;
* resource binding attributes such as `register(t0, space1)`;
* parameter direction qualifiers such as `out` and `inout`;
* vector and matrix swizzles such as `.xyz` and `._m00`;
* shader-specific attributes such as `[shader]`, `[numthreads]`, `[unroll]`, and `[loop]`.

These constructs may already be represented correctly in the AST, but `clangd` does not automatically know how to expose them through the Language Server Protocol (LSP). As a result, a construct can be fully understood by Clang while still producing incomplete or incorrect IDE behavior.

This GSoC project focused on identifying and closing these gaps in `clangd`.

The project followed these steps:

1. Identify the gaps in the existing HLSL support.
2. Investigate their root causes in Clang and clangd.
3. Develop possible implementation approaches for each gap.
4. Discuss the approaches with the LLVM community through an RFC.
5. Turn the agreed solutions into detailed GitHub issues.
6. Implement each solution in an independently reviewable pull request.
7. Investigate a larger architectural problem: multiple HLSL entry points in the same file.

This report describes that process and the resulting contributions.

---

## 2. What work was done

During the project, I:

* Created a gap analysis of HLSL support in `clangd`;
* Tested HLSL constructs across hover, code completion, go-to-definition, and diagnostics;
* Classified the observed problems into frontend, tooling, configuration, and architectural gaps;
* Documented implementation alternatives and their trade-offs;
* Proposed the solutions through an LLVM RFC;
* Incorporated feedback from LLVM and DirectX developers;
* Created 11 GitHub issues;
* Implemented the corresponding fixes in 11 pull requests;
* Investigated the multiple-entry-point problem and built a working prototype for context switching.

### Project results

| Item                           | Result                                          |
| ------------------------------ | ------------------------------------------------ |
| Gap analysis                   | Completed                                        |
| RFC                            | Published and discussed with the LLVM community  |
| GitHub issues                  | 11                                               |
| Pull requests                  | 11                                               |
| Merged PRs                     | 3                                                 |
| PRs still under review         | 8                                                 |
| Multiple-entry-point prototype | Working                                           |

---

## 3. Gap Analysis

The first phase of the project was to understand the existing HLSL support in clangd.

I created a test suite covering different HLSL construct categories and tested the behavior of each construct against multiple clangd features.

The complete analysis is available here: **[Gap Analysis](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/gap-analysis.md)**

### 3.1 Methodology

For each HLSL construct category, I created an isolated `.hlsl` test file containing representative examples.

The tests were then compiled with the appropriate HLSL configuration and exercised through VS Code and the clangd LSP interface.

For each construct, I tested:

* **Hover**
* **Code completion**
* **Go-to-definition**
* **Diagnostics**

The workflow was like this:

```text
HLSL construct
      |
      v
Isolated .hlsl test
      |
      v
clangd / LSP behavior
      |
      |--- Hover
      |--- Completion
      |--- Go-to-definition
      |--- Diagnostics
      |
      v
AST inspection when necessary
      |
      v
Classify the gap
```

This approach helped distinguish problems that actually belonged to clangd from problems that originated earlier in the compiler pipeline.

The test environment used Clang/clangd `23.0.0git`, the `dxil-pc-shadermodel6.3-library` target, and VS Code with the clangd extension.

### 3.2 Gap Classification

I classified each problem into one of four categories.

**Frontend gap**: the construct was not represented correctly in the AST, or was missing entirely. These problems were outside the main scope of the project, since clangd cannot expose information that Clang does not provide.

**Tooling gap**: the construct was correctly represented in the AST, but clangd did not expose it through the LSP. These were the main targets of the project.

**Configuration gap**: the compiler and clangd could support the construct, but the necessary configuration was missing or required manual intervention.

**Architectural gap**: the problem came from a mismatch between HLSL's compilation model and assumptions made by clangd or the LSP. This classification became important later when investigating multiple HLSL entry points.

The gap analysis covered seven HLSL construct categories and provided the basis for the rest of the project.

---

## 4. Creating Implementation Ideas

Once the gaps were identified, the next step was to understand how each problem should actually be fixed.

For each tooling gap, I investigated:

* where the relevant information was stored in the AST;
* where clangd currently handled the corresponding feature;
* why the existing code failed;
* whether the fix should live in clangd or Clang;
* whether the change could be generalized;
* and what alternative implementation approaches were possible.

This resulted in a separate document containing the implementation ideas and open design questions: **[Implementation Ideas](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/implementation-ideias.md)**

---

## 5. RFC and Community Discussion

After investigating the individual gaps and possible implementations, I wrote an RFC for the LLVM community: **[LLVM Discourse RFC](https://discourse.llvm.org/t/rfc-improving-hlsl-support-in-clangd/91359)**

The RFC describes, for each issue, the expected behavior, the observed gap, the root cause, and the proposed solution. 

### 5.1 Decision Log

I also maintained a companion decision document containing the alternatives considered for each issue and the reasons for choosing or rejecting them: **[Decision Log](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/hlsl-decision-rfc.md)**

This was useful both during the design process and later during implementation and review, because it preserved the reasoning behind the chosen approach rather than documenting only the final code.

### 5.2. Community Feedback

The RFC discussion on Discourse was an important part of the project. Some initial ideas were refined after community feedback, which helped turn the initial implementation ideas into solutions that better matched clangd's existing design and user experience.

---

## 6. From RFC Items to GitHub Issues

After the RFC discussion, each implementation item was turned into a dedicated GitHub issue. The purpose of the issues was to make each piece of work independently understandable and reviewable.

Each issue described the expected behavior, the observed behavior, the root cause, the proposed implementation, and relevant technical details: **[All GitHub Issues](https://github.com/llvm/llvm-project/issues?q=is%3Aissue%20mafeguimaraes)**

The 11 issues were:

| Issue | Description                                                      | Area       |
| ----- | ------------------------------------------------------------------ | ---------- |
| I1    | Hover for HLSL semantic annotations                                | Hover      |
| I2    | Hover for loop/branch control attributes                           | Hover      |
| I3    | Hover for `out`/`inout` parameter qualifiers                       | Hover      |
| I4    | Hover for vector swizzle and matrix element access                 | Hover      |
| I5    | RootSignature hover leaking internal identifier                    | Hover      |
| I6    | `register` hover not triggered inside arguments                    | Hover      |
| I7    | Completion inside `[...]` mixes statement/declaration attributes   | Completion |
| I8    | Completion inside `register(...)`                                  | Completion |
| I9    | Completion for HLSL annotations after `:`                          | Completion |
| I10   | Completion for HLSL vector swizzle members                         | Completion |
| I11   | Completion for HLSL matrix swizzle members                         | Completion |

---

## 7. Implementation

Each issue was implemented in a separate pull request so that the changes could be reviewed independently: **[All Pull Requests](https://github.com/llvm/llvm-project/issues?q=is%3Apr%20author%3Amafeguimaraes%20label%3Aclangd)**

The table below summarizes the root cause and fix for each issue. Full technical detail for each one is available in its GitHub issue and PR.

| Issue | Root cause | Fix |
| ----- | ---------- | --- |
| I1 - Semantic annotations | `HLSLParsedSemanticAttr` had no defined spellings, so hover showed `(No spelling)` | Added explicit `Microsoft<>` spellings for system-value semantics |
| I2 - Loop/branch attributes | clangd's `SelectionTree` traversed declaration attributes but not statement attributes | Extended traversal to `AttributedStmt` |
| I3 - `out`/`inout` parameters | `out`/`inout` are lowered to C++ references internally, leaking types like `float &__restrict` | Added a `getHLSLParamTypeAsWritten()` helper to recover the HLSL spelling |
| I4 - Vector/matrix element hover | `ExtVectorElementExpr`/`MatrixElementExpr` had no hover handling | Added dedicated hover handling for both node kinds |
| I5 - RootSignature hover | Generic `printPretty()` leaked an internal compiler-generated identifier | Generated user-facing hover text directly instead of using the generic path |
| I6 - `register(...)` hover range | `HLSLResourceBindingAttr` had a zero-width source range | Parser updated to capture the full argument range |
| I7 - Attribute completion in `[...]` | Statement and declaration attribute completion were not distinguished | Propagated statement-context info through parsing to filter candidates |
| I8 - `register(...)` completion | Completion had no awareness of resource type (`t`/`u`/`b`/`s`) | Propagated the `Declarator` so completion can suggest the right register class |
| I9 - Annotations after `:` | No completion hook existed at that parsing point | Added the missing completion path, later refined to filter `SV_*` suggestions by prefix |
| I10 - Vector swizzle completion | No completion handling for `ExtVectorType` | Added swizzle-aware completion enforcing HLSL's component rules |
| I11 - Matrix swizzle completion | No completion handling for `ConstantMatrixType` | Added matrix swizzle completion enforcing HLSL's `_m`/`_` notation rules |

---

## 8. Multiple Entry Points

In addition to the original 11 issues, I investigated an architectural problem: HLSL files containing multiple shader entry points (e.g. `VSMain`, `PSMain`, `CSMain`), which conflicts with clangd's model of a single active compilation context per file.

For modern HLSL (using `[shader(...)]` attributes), the `library` compilation target already handles this correctly, and I implemented a fallback that uses it automatically. For legacy HLSL (entry point chosen via compiler flags), I built and validated a working prototype that lets clangd discover all entry points for a file and switch between them at runtime.

Full details: **[Multiple Entry Point Investigation](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/multiple-entry-point.md)**

---

## 9. Future Work

The legacy multiple-entry-point prototype still needs to be upstreamed and paired with client-side UX.

Other smaller follow-ups identified during the project: 

* richer RootSignature hover reconstruction;
* the broader `RecursiveASTVisitor` / `AttributedStmt` traversal question;
* default `files.associations` entry for `.hlsl` in `vscode-clangd`.

---

## 10. What I Learned

- Before Google Summer of Code, I had some experience working with LLVM, but I had never worked on `clangd` or HLSL. Working on this project gave me the opportunity to understand how language-server features connect to Clang's parser, AST, Sema, and LLVM's tooling infrastructure.

- One of the most valuable things I learned was how to investigate a compiler tooling problem from the user's perspective and trace it back to its root cause. In a few cases, what initially looked like a `clangd` problem turned out to be related to how an HLSL construct was represented in the AST or handled by Sema.

- I learned how important it is to understand the existing architecture before implementing a fix. Instead of adding HLSL-specific logic immediately, I often found that existing Clang or `clangd` infrastructure could be extended to support the new construct in a more general way.

- I also learned a lot from the upstreaming process itself. Writing an RFC, discussing design alternatives with the LLVM community, incorporating feedback, and then turning the agreed-upon solution into small, focused pull requests was an important part of the project.

- Finally, investigating the multiple-entry-point problem taught me how some compiler tooling problems are not individual bugs, but architectural problems that require understanding the interaction between the compiler, `clangd`, the compilation database, and the LSP.

Overall, this GSoC gave me much more confidence in navigating a large compiler codebase, debugging problems across different layers of the compiler, and contributing changes to an open-source project like LLVM.

---

## 11. Links

* **[Gap Analysis](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/gap-analysis.md)** 
* **[Implementation Ideas](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/implementation-ideias.md)**
* **[LLVM RFC - Discourse](https://discourse.llvm.org/t/rfc-improving-hlsl-support-in-clangd/91359)**
* **[RFC Decision Log](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/hlsl-decision-rfc.md)**
* **[GitHub Issues](https://github.com/llvm/llvm-project/issues?q=is%3Aissue%20mafeguimaraes)**
* **[Merged Pull Requests](https://github.com/llvm/llvm-project/issues?q=is%3Apr%20author%3Amafeguimaraes%20label%3Aclangd%20state%3Aclosed)**
* **[Pull Requests in Review](https://github.com/llvm/llvm-project/issues?q=is%3Apr%20author%3Amafeguimaraes%20label%3Aclangd%20state%3Aopen)**
* **[Multiple Entry Point Investigation](https://github.com/mafeguimaraes/hlsl-gap-analysis/blob/main/multiple-entry-point.md)**

---

## 12. Acknowledgments

I would like to thank my mentors, **Finn Plummer** and **Ashley Coleman**, for their guidance and support throughout this project. They always made time to talk to me, discuss my progress, answer my questions, and help me work through the challenges I encountered. I am grateful for all the feedback they gave on my ideas, and for taking the time to explain things, listen to my proposals, and help me find a way forward whenever I was unsure about something. Working with them was one of the most valuable parts of this experience. I really enjoyed our discussions and learned a great deal from the way they approached problems.

I would also like to thank the LLVM and DirectX communities for the discussions and feedback on the RFC and implementation ideas. The community input was an important part of refining the proposed solutions and understanding how these features should fit into `clangd`'s existing architecture.
