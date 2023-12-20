#import "template.typ": *
#import "@preview/codelst:2.0.0": sourcecode

#show: project.with(
  title: "χ 语言设计与实现",
  authors: (
    (name: "叶焯仁", email: "cn_yzr@qq.com", affiliation: "ACT, BUAA"),
    (name: "郝泽钰", email: "withinlover@gmail.com", affiliation: "ACT, BUAA"),
  ),
)

= 背景与目标 <chapter:background>

本节介绍 χ 语言（西文：χ-lang 或 chi-lang）的设计背景与语法特性。

== 设计背景

资源泄漏是指在程序运行过程中未能正确释放已分配的各种系统资源，其中包括内存、文件句柄、网络连接等。这种问题可能导致程序在长时间运行后逐渐占用越来越多的系统资源，最终影响系统性能，甚至导致系统崩溃。最常见的资源泄漏是内存泄漏，即程序在动态分配内存后忘记释放。此外，文件句柄、网络连接、数据库连接以及线程和进程等资源的泄漏都可能对系统稳定性产生负面影响。为有效避免资源泄漏，程序员需要仔细管理程序中使用的所有资源，并确保在不再需要时正确释放它们。

在基于 C 语言的内核开发中，仔细管理资源并防止泄漏是至关重要的。内核作为操作系统的核心，直接管理硬件和提供系统服务，因此它的健壮性和稳定性对整个系统的可靠运行至关重要。资源泄漏可能导致内存耗尽、文件句柄失控、网络连接问题等，最终影响系统性能和可用性。合理管理内核中的各种资源，包括内存分配、设备驱动、中断处理等，不仅能够确保系统的高效运行，还能防止潜在的安全漏洞。在内核级别，资源泄漏可能导致系统崩溃或不稳定，因此开发人员必须特别注意资源的正确释放，采用严格的资源管理和内存回收策略，以确保内核的可维护性和高度可靠性。

以北航计算机学院本科生课程《操作系统》（课程设计）为例，其在遍历页表，沿途为次级页表创建页面时有 @code:pgdir-walk-lv2。

#figure(
  sourcecode[
    ```c
    int pgdir_walk(Pde *pgdir, u_long va, int create, Pte **ppte) {
      int ret;
      Pde *pgdir_entryp;
      
      struct Page *pp;
    
      pgdir_entryp = pgdir + PDX(va);
    
      if (!((*pgdir_entryp) & PTE_V)) {
        if (create) {
          // alloc page table
          if ((ret = page_alloc(&pp)) != 0) {
            return ret;
          }
          *pgdir_entryp = page2pa(pp);
          *pgdir_entryp |= PTE_V | PTE_D;
          pp->pp_ref++;
        } else {
          *ppte = NULL;
          return 0;
        }
      }
    
      *ppte = (Pte *)KADDR(PTE_ADDR(*pgdir_entryp)) + PTX(va);
      return 0;
    }
    ```
  ],
  caption: "二级页表遍历并沿途创建次级页表"
)<code:pgdir-walk-lv2>

若不加注意地将其迁移到三级页表的实现中，则将存在潜在的资源泄漏。如 @code:pgdir-walk-lv3-leak 的高亮行就存在泄漏先前第 13 行 ```c page_alloc(&pp2)``` 所分配 ```c pp2``` 的风险。

#figure(
  sourcecode(
    highlighted: (31,),
    highlight-color: rgb(255, 127, 127),
  )[
    ```c
    int pgdir_walk(Pde *pgdir, u_long va, int create, Pte **ppte) {
      int ret;
      Pte *pgdir1_entryp;
      Pde *pgdir2_entryp;
      
      struct Page *pp1 = NULL, *pp2 = NULL;
    
      pgdir2_entryp = pgdir + PTX(va, 2);
    
      if (!((*pgdir2_entryp) & PTE_V)) {
        if (create) {
          // alloc page table
          if ((ret = page_alloc(&pp2)) != 0) {
            return ret;
          }
          *pgdir2_entryp = page2pa(pp2);
          *pgdir2_entryp |= PTE_V | PTE_D;
          pp->pp_ref++;
        } else {
          *ppte = NULL;
          return 0;
        }
      }
  
      pgdir1_entryp = (Pte *)KADDR(PTE_ADDR(*pgdir2_entryp)) + PTX(va, 1);
  
      if (!((*pgdir1_entryp) & PTE_V)) {
        if (create) {
          // alloc page table
          if ((ret = page_alloc(&pp1)) != 0) {
            return ret;
          }
          *pgdir1_entryp = page2pa(pp1);
          *pgdir1_entryp |= PTE_V | PTE_D;
          pp->pp_ref++;
        } else {
          *ppte = NULL;
          return 0;
        }
      }
  
      *ppte = (Pte *)KADDR(PTE_ADDR(*pgdir1_entryp)) + PTX(va, 0);
      return 0;
    }
    ```
  ],
  caption: "三级页表遍历并沿途创建次级页表（存在资源泄漏）"
)<code:pgdir-walk-lv3-leak>

对于该问题，需如 @code:patch-pgdir-walk-lv3 在高亮行上添加相应检查语句，方能确保资源不被泄漏。

#figure(
  sourcecode[
    ```c
    if (pp2 != NULL) {
      page_free(pp2);
    }
    return ret;
    ```
  ]
  ,caption: "三级页表遍历并沿途创建次级页表（修正）"
)<code:patch-pgdir-walk-lv3>

使用 C 语言时的类似风险场景还有：
- #underline[文件打开]后因异常退出函数而遗漏#underline[文件关闭]
- #underline[内存分配]后因异常退出函数而遗漏#underline[内存释放]
- #underline[信号量获取]后因异常退出函数而遗漏#underline[信号量释放]
- ...

为解决或缓解该问题，我们调研了流行的系统级编程语言 Rust、C++、Golang 的语言机制，希望从中获得启发。

*考虑 Rust 语言？* Rust 是一种系统级编程语言，专注于安全性、并发性和性能。它由 Mozilla 开发，并于 2010 年首次发布。Rust 旨在提供内存安全性，防止常见的内存错误，如空指针引用、数据竞争等，通过引入所有权系统、借用和生命周期等概念来实现。其所有权机制可实现 RAII（Resource Acquisition Is Initialization）模式，在编译期确定每一资源（文件、内存页、锁等）的释放位置，从而从语言机制上防止了资源泄漏。但相对于 C 来说，Rust 作为一种全新设计的语言，在目前，尤其是在内核级开发中尚未普及使用，这意味着在未来若干年里，C 语言依然是内核级开发的首选。

*考虑 C++ 语言？* C++ 是一种通用编程语言，具有高性能和广泛应用的特点。它是从 C 语言演变而来的，通过添加面向对象编程（OOP）和其他一些特性，使得程序员可以更方便地编写复杂的软件。以下是一些关于 C++ 的基本信息。通过编写 C++ 语言中的构造函数（constructor）与析构函数（destructor），可实现 RAII 模式，从语言机制上防止资源泄漏。但相对于 C 来说，C++ 语法特性过于丰富，对程序编写者的心智要求极高，难以在内核级开发中推广。

*考虑 Golang 语言？* Golang 是一种由 Google 开发的编程语言。它于 2007 年首次公开亮相，于 2009 年正式发布。Go 的设计目标是提供一种简单而高效的编程语言，具有强大的并发支持和内置的垃圾回收（GC, Garbage Collection）机制。其垃圾回收机制以及 ```go defer``` 关键字可有效地在运行时回收资源。但对于 C 来说，Golang 所依赖的运行时环境过大，难以在内核开发中携带其运行时，因此不利于其在内核级开发中的推广。

针对内核级开发的现状，结合 Rust、C++ 的 RAII 思想，学习 Golang 的 ```go defer``` 语法，我们为 C 语言添加一个小而精的、用于控制资源的语法，将有利于目前基于 C 语言内核级开发。

== 语言特性 <sec:feature>

我们为 C 语言添加了一个名为 χ-hook 的语法特性，并将该语言命名为 χ-lang（#link("https://zh.wikipedia.org/wiki/%CE%A7")[χ] 为希腊字母，读音：[çi]），其中 χ 在英文中的拼写为 chi，因此亦可称该语言为 chi-lang（#strong[C] with #strong[H]ook #strong[I]mprovement）。该语法特性将便于内核开发时对资源的释放控制。

该语法特性允许 C 语言程序设计者在函数体内定义钩子（Hook）。在函数体中，每一个钩子 $H$ 绑定到指定标签 $L$ 与待插入的语句 $B$，其语义为将 $B$ 语句插入到 $L$ 处。该语法可提供较灵活的钩子定义与使用，从而为防止资源泄漏提供有力的语法支撑。

χ 语言新增了一个关键字 `__chi_hook__`，用以定义钩子，其前后的双下划线可以尽可能地确保现有的项目没有用到该关键字，从而极大地降低项目迁移到 χ 语言的成本。

我们将在 @chapter:grammar、@chapter:semantics 中详细介绍其文法、指称语义，在本小节中，我们通过 χ-hook 语法特性重写 @code:pgdir-walk-lv3-leak 为 @code:pgdir-walk-lv3-no-leak，为读者初步展示该语法特性。

#figure(
  sourcecode(
    highlighted: (8, 9, 10, 11, 12, 37),
    highlight-color: rgb(127, 255, 127),
  )[
    ```c
    int pgdir_walk(Pde *pgdir, u_long va, int create, Pte **ppte) {
      int ret;
      Pte *pgdir1_entryp;
      Pde *pgdir2_entryp;
      
      struct Page *pp1 = NULL, *pp2 = NULL;

      __chi_hook__(err) {
        if (pp2 != NULL) {
          page_free(&pp2);
        }
      };
    
      pgdir2_entryp = pgdir + PTX(va, 2);
    
      if (!((*pgdir2_entryp) & PTE_V)) {
        if (create) {
          // alloc page table
          if ((ret = page_alloc(&pp2)) != 0) {
            return ret;
          }
          *pgdir2_entryp = page2pa(pp2);
          *pgdir2_entryp |= PTE_V | PTE_D;
          pp->pp_ref++;
        } else {
          *ppte = NULL;
          return 0;
        }
      }
  
      pgdir1_entryp = (Pte *)KADDR(PTE_ADDR(*pgdir2_entryp)) + PTX(va, 1);
  
      if (!((*pgdir1_entryp) & PTE_V)) {
        if (create) {
          // alloc page table
          if ((ret = page_alloc(&pp1)) != 0) {
    err:
            return ret;
          }
          *pgdir1_entryp = page2pa(pp1);
          *pgdir1_entryp |= PTE_V | PTE_D;
          pp->pp_ref++;
        } else {
          *ppte = NULL;
          return 0;
        }
      }
  
      *ppte = (Pte *)KADDR(PTE_ADDR(*pgdir1_entryp)) + PTX(va, 0);
      return 0;
    }
    ```
  ],
  caption: "三级页表遍历并沿途创建次级页表（无资源泄漏）"
) <code:pgdir-walk-lv3-no-leak>

= 语言文法 <chapter:grammar>

本节介绍 χ 语言的文法，以 EBNF 的形式展示 χ 语言在 C 语言基础上的改进。由于 χ 语言是对 C 语言函数内的语法改进，因此本节仅展示函数内的文法。

== 函数文法

χ 语言的函数（function-definition）文法与 C 语言标准文法几乎相同。χ 语言对 C 语言的改进工作集中在 statement 中，@sec:statement 将叙述 statement 的文法结构。

=== 函数定义

$
"function-definition" &|->&& ["decl-specs"] "declarator" ["declaration-list"] "compound-statement" \
"decl-specs" &|->&& "storage-class-spec" ["decl-specs"] \
             &|->&& "type-spec" ["decl-specs"] \
             &|->&& "func-spec" ["decl-specs"] \
             &|->&& "align-spec" ["decl-specs"] \
"declarator" &|->&& ["pointer"] "direct-declarator" \
"declaration-list" &|->&& ..\
"compound-statement" &|->&& "'{'" ["block-item-list"] "'}'" \
$

其中，declaration-list（声明列表）与 K&R 风格的 C 标准中的对应文法相同，不再赘述。

=== 存储类型说明符

$
"storage-class-spec" &|->&& "'typedef'" | "'extern'" | "'static'" | "'auto'" | "'register'" | "'_Thread_local'" \
$

=== 类型说明符

$
"type-spec" &|->&& "simple-type-spec" \
            &|->&& "enum-spec" \
            &|->&& "typename-spec" \
"simple-type-spec" &|->&& "'char'" | "'wchar_t'" \
                   &|->&& "'bool'" | "'short'" | "'int'" | "'long'" \
                   &|->&& "'signed'" | "'unsigned'" \
                   &|->&& "'float'" | "'double'" \
                   &|->&& "'void'" \
"enum-spec" &|->&& "'enum'" ["identifier"] "'{'" ["enumerator-list"] "'}'" \
            &|->&& "'enum'" ["identifier"] "'{'" "enumerator-list" "','" "'}'" \
"enumerator-list" &|->&& "enumerator" | "enumerator" "','" "enumerator-list" \
"enumerator" &|->&& "enumerator-constant" ["'='" "constant-expression"] \
"enumerator-constant" &|->&& "identifier" \
"typename-spec" &|->&& "typedef-name" \
"typedef-name" &|->&& "identifier" \
$

其中，identifier（标识符）、constant-expression（常量表达式）的文法与 C 标准中的对应文法相同，不再赘述。

=== 函数说明符

$
"func-spec" &|->&& "'inline'" \
$

=== 对齐说明符

$
"align-spec" &|->&& "'_Alignas'" "'('" "type-id" "')'" \
             &|->&& "'_Alignas'" "'('" "constant-expression" "')'" \
$

其中，type-id（类型标识符）、constant-expression（常量表达式）的文法与 C 标准中的对应文法相同，不再赘述。

=== 块项目列表

$
"block-item-list" &|->&& "block-item" ["block-item-list"] \
"block-item" &|->&& "declaration" | "statement" \
$

其中，declaration（声明）的文法与 C 标准的对应文法相同，不再赘述；statement（语句）的文法与 C 标准的文法有差异，具体可见 @sec:statement。

== 语句文法 <sec:statement>

χ 语言的语句（statement）文法如下。

=== 语句

$
"statement" &|->&& "labeled-statement" \
            &|->&& "compound-statement" \
            &|->&& "expression-statement" \
            &|->&& "selection-statement" \
            &|->&& "iteration-statement" \
            &|->&& "jump-statement" \
            &|->&& "hook-statement" \
$

=== 带标签语句

$
"labeled-statement" &|->&& "identifier" "':'" "statement" \
                    &|->&& "'case'" "constant-expression" "':'" "statement" \
                    &|->&& "'default'" "':'" "statement" \
$

其中，identifier（标识符）的文法与 C 标准中的对应文法相同，不再赘述。

=== 选择语句

$
"selection-statement" &|->&& "if-statement" | "switch-statement" \
$

其中，if-statement（条件语句）、switch-statement（开关语句）的文法与 C 标准中的对应文法相同，不再赘述。

=== 迭代语句

$
"iteration-statement" &|->&& "while-statement" | "do-statement" | "for-statement" \
$

其中，while-statement（while 循环语句）、do-statement（do-while 循环语句）、for-statement（for 循环语句）的文法与 C 标准中的对应文法相同，不再赘述。

=== 表达式语句

$
"expression-statement" &|->&& ["expression"] "';'" \
$

其中，expression（表达式）的文法与 C 标准中的对应文法相同，不再赘述。

=== 跳转语句

$
"jump-statement" &|->&& "'goto'" "identifier" "';'" \
                 &|->&& "'continue'" "';'" \
                 &|->&& "'break'" "';'" \
                 &|->&& "'return'" ["expression"] "';'" \
$

其中，identifier（标识符）、expression（表达式）的文法与 C 标准中的对应文法相同，不再赘述。

=== 钩子语句

$
"hook-statement" &|->&& "'__chi_hook__'" "'('" "identifier" "')'" "statement" \
$

其中，identifier（标识符）的文法与 C 标准中的对应文法相同，不再赘述。

= 指称语义 <chapter:semantics>

本节介绍 χ 语言的指称语义。由于 χ 语言是对 C 语言函数内的语法改进，因此本节仅展示函数内的指称语义。

== 存储域

存储域定义为：

$
"Store" = "Location" -> ("stored" "Storable" + "undefined" + "unused")
$

引入存储域上的辅助函数如下：

$
"empty_store" &:&& "Store" \
"allocate" &:&& "Store" -> "Store" times "Location" \
"deallocate" &:&& "Store" times "location" -> "Store" \
"update" &:&& "Store" times "Location" times "Storable" -> "Store" \
"fetch" &:&& "Store" times "Location" -> "Storable" \
$

他们的形式化定义为：

$
"empty_store" &=&& lambda"loc"."unused" \
"allocate"("sto") &=&& "let" \
                  & && quad "loc" = "any_unused_location"("sto") \
                  & && "in" \
                  & && quad ("sto"["loc" -> "undefined"], "loc") \
"deallocate"("sto", "loc") &=&& "sto"["loc" -> "unused"] \
"update"("sto", "loc", "storable") &=&& "sto"["loc" -> "stored" "storable"] \
"fetch"("sto", "loc") &=&& "let" \
                      & && quad "stored_value" ("stored" "storable") = "storable" \
                      & && quad "stored_value" ("undefined") = "fail" \
                      & && quad "stored_value" ("unused") = "fail" \
                      & && "in" \
                      & && quad "stored_value" ("sto"("loc"))
$

== 环境域

环境域定义为：

$
"Environ" &=&& "Identifier" -> ("bound" "Bindable" + "unbound") \
$

引入环境域上的辅助函数如下：

$
"empty-environ" &:&& "Environ" \
"bind" &:&& "Identifier" times "Bindable" -> "Environ" \
"overlay" &:&& "Environ" times "Environ" -> "Environ" \
"find" &:&& "Environ" times "Identifier" -> "Bindable" \
$

他们的形式化定义为：

$
"empty-environ" &=&& lambda"ident". "unbound" \
"bind"("ident", "bindable") &=&& lambda"ident"'. "if" "ident"' = "ident" "then" "bound" "bindable" "else" "unbound" \
"overlay"("env"', "env") &=&& lambda"ident". "if" "env"'("ident") != "unbound" "then" "env"'("ident") "else" "env"("ident") \
"find"("env", "ident") &=&& "let" \
                       & && quad "bound_value" ("bound" "bindable") = "bindable" \
                       & && quad "bound_value" ("unbound") = \
                       & && "in" \
                       & && quad "bound_value" ("env"("ident")) \
$

== 钩子域

钩子域定义为：

$
"Hook" &=&& "Label" -> "Statement"
$

引入钩子域上的辅助函数如下：

$
"empty-hook" &:&& "Hook" \
"chain" &:&& "Statement" times "Statement" -> "Statement" \
"register" &:&& "Label" times "Statement" -> "Hook" \
"merge" &:&& "Hook" times "Hook" -> "Hook" \
"yield" &:&& "Hook" times "Label" -> "Statement" \
$

他们的形式化定义为：

$
"empty-hook" &=&& lambda"label"."nil" \
"chain"("statement"', "statement") &=&& "statement"' + "statement" \
"register"("label", "statement") &=&& lambda"label"'."if" "label"' = "label" "then" "statement" "else" "nil" \
"merge"("hook"_"old", "hook"_"new") &=&& lambda"label"."chain"("hook"_"new" ("label"), "hook"_"old" ("label")) \
"yield"("hook", "label") &=&& "hook"("label") \
$

其中 nil 为空语句，两语句（statement）加法的结果为两语句拼接形成的复合语句（compound-statement）。

== 语义域

语义域定义为：

$
"Value" &=&& "Bool" + "Value" + "Integer" + "Float" + "Identifier" \
"Storable" &=&& "Value" \
"Bindable" &=&& "value" "Value" + "variable" "Location" \
$

== 语句语义

定义 χ 语言语句执行的语义函数如下：

$
"execute"_chi &:&& "Statement" -> (("Environ" -> "Store" -> "Hook") -> "Store" times "Hook") \
$

χ 语言对 C 语言的语法改进引发的语义变化主要体现在钩子语句与带标签语句上。而对于 C 语言其他原有的语句，其语义函数：

$
"execute"_chi [ "statement" ] "env" "sto" "hook" = ("execute"_C [ "statement" ] "env" "sto", "hook")
$

=== 钩子语句

$
& "execute"_chi [ \
& quad "__chi_hook__" "'('" "label" "')'" "statement" \
& ] "env" "sto" "hook" &=& "let" \
&                      & & quad "hook"' = "register"("label", "statement") \
&                      & & "in" \
&                      & & quad ("merge"("hook", "hook"'), "sto")
$

=== 带标签语句

$
& "execute"_chi [ \
& quad "label" "':'" "statement" \
& ] "env" "sto" "hook" &=& "let" \
&                      & & quad "statement"' = "yield"("hook", "label") \
&                      & & "in" \
&                      & & quad "execute"_chi [ "statement" ]  "env" ("execute"_chi [ "statement"' ] "env" "sto" "hook")
$

= 语言实现 <chapter:implementation>

本节介绍 χ 语言的具体实现。由于 χ 语言是对 C 语言的改进，因此在实现过程中我们选择 #link("https://github.com/llvm/llvm-project")[LLVM Project] 为基础进行增量开发。

== LLVM Project 与技术路线

Clang 与 LLVM 后端共同构建了一个轻量化、模块化、易于扩展的编译器。

LLVM（Low-Level Virtual Machine），以其通用的中间表示（LLVM IR）为核心，奠定了其整个编译体系的灵活性、可重用性和高性能。

Clang 作为 C、C++ 和 Objective-C 等高级语言的前端，承担着将源代码转换为 LLVM IR 的任务，注重可读性、易扩展性和快速编译的设计理念成为其独特之处。Clang 的设计理念突显了可读性的重要性，使得开发者能够更轻松地理解生成的代码和错误信息，尤其在调试阶段。其模块化架构为各个组件提供了清晰的边界，使得功能的理解和扩展变得更为简单。而其强调的编译速度，则是对开发效率的追求，为开发者提供了更快速的编译体验。

在另一方面，LLVM 的设计理念强调通用中间表示的重要性，为前端和后端提供了一个共同的语言，使得不同语言的编译器能够更轻松地协同工作。其可重用性使得其他项目可以借助其强大的编译基础，而内置的优化器则进一步提高了生成机器代码的性能。

#figure(
  image("assets/llvm.png", width: 90%),
  caption: "LLVM IR 中间表示"
)

根据 @sec:feature 中的介绍，本项目提出的 `__chi_hook__` 语法是对现有的 C 语言所做出的改进，基于一个成熟的编译器可以让我们更有效率的完成开发，因此我们的技术路线是对 Clang 前端进行增量开发。

我们选择复用 C 语言中已有的 label 标签（原用于 goto 语句），在不改变其原有用法的基础上，实现 hook 的功能。具体的技术路线如下：

1. @sec:chi-hook-lexer：定义 `__chi_hook__` 关键字。
2. @sec:chi-hook-parser：引入 `__chi_hook__` 语法树结点，解析 χ-hook 语法。
3. @sec:chi-hook-code-gen：分析钩子语句的语义，重写带标签语句的语义分析过程，按需生成 `__chi_hook__` 块的 LLVM IR。

== 定义 `__chi_hook__` 关键字 <sec:chi-hook-lexer>

Clang 的编译流程可以分为词法分析（Lexer）、语法分析（Parser）、语义分析（CodeGen）等步骤。想要添加 `__chi_hook__` 关键词，则应当关注词法分析的内容。在 Clang 中，将 `keyword` 视为 token 的一种，在 `clang/include/clang/Basic/TokenKinds.def` 中通过 ```cpp KEYWORD(X, Y)``` 宏统一控制。

在此文件中添加 ```cpp KEYWORD(__chi_hook__, KEYALL)```。表示我们将 `__chi_hook__` 声明为关键字，并适用于所有的 C 语言版本。Clang 会自动化的解析这个文件并生成对应的 Lexer，最终输出包含 `__chi_hook__` 关键字的 Token 列表。

== 引入 `__chi_hook__` 语法树结点 <sec:chi-hook-parser>

我们主要需要修改 Clang 对 statement 语句的解析，整体思路为通过添加 `ChiHookStmt` 类及相关方法来完成对 ```cpp tok::kw___chi_hook__``` 的解析，其涉及的部分具体包含：

1. 在 ```cpp StmtResult Parser::ParseStatementOrDeclarationAfterAttribute()``` 中的开关语句中添加对 ```cpp tok::kw___chi_hook__``` 的支持。
2. 编写 ```cpp StmtResult Parser::ParseChiHookStatement()```，按照 @chapter:grammar>)中的设计完成对文法的解析。
3. 添加 ```cpp class ChiHookStmt : public Stmt``` 和 ```cpp class ChiHookStmtBitfields```并完成对应方法。
4. 编写 ```cpp StmtResult Sema::ActOnChiHookStmt()```，此方法最终返回生成的语法树结点。

== 分析钩子语句语义 <sec:chi-hook-code-gen>

完成语法树的构建后，我们需要利用语法树完成 LLVM IR 的生成。我们在设计过程中复用了带标签语句的设计，在处理 `ChiHookStmt` 时将内部的语句保留下来，并在处理到对应的带标签语句时输出。具体的实现步骤包括：

1. 实现用于输出语法树和遍历语法树的函数：
   - ```cpp void StmtPrinter::VisitChiHookStmt(ChiHookStmt *)```
   - ```cpp void StmtProfiler::VisitChiHookStmt(const ChiHookStmt *)```
2. 实现用于序列化和反序列化语法树的函数：
   - ```cpp void ASTStmtWriter::VisitChiHookStmt(ChiHookStmt *)```
   - ```cpp void ASTStmtReader::VisitChiHookStmt(ChiHookStmt *)```
3. 实现用于重建 χ-hook 语法中的 label 部分的函数：
   - ```cpp
     template<typename Derived>
     StmtResult TreeTransform<Derived>::TransformChiHookStmt(ChiHookStmt *)
     ```
4. 在 ```cpp CodeGenFunction::EmitSimpleStmt()``` 中的开关语句中添加对 ```cpp Stmt::ChiHookStmtClass``` 的支持。
5. 声明 ```cpp llvm::DenseMap<const LabelDecl*, Stmt*> ChiHookMap``` 用于存储钩子语句的 `label` 和 `statement` 映射关系。
6. 实现 ```cpp void CodeGenFunction::EmitChiHookStmt(const ChiHookStmt &)```，在遇到钩子语句时：
   - 若 ```cpp ChiHookMap``` 中已有对应标签，则将该钩子语句的待插入语句与 ```cpp ChiHookMap``` 中已有的语句按后来先出（LIFO）的顺序合并。
   - 若 ```cpp ChiHookMap``` 中没有对应标签，则将该钩子语句的标签与待插入语句放入 ```cpp ChiHookMap``` 中。
7. 修改  ```cpp CodeGenFunction::EmitLabelStmt()``` 使其在遇到 `ChiHookStatement` 中声明的标签时，将 ```cpp ChiHookMap``` 中保存的对应语句输出。


= 应用实例

== 文件资源回收

@code:example-file-close 展示了一个文件打开与关闭的例子，通过 χ-hook 语法，可防止资源泄漏。

#figure(
  sourcecode[
    ```c
    #include <stdio.h>

    int main() {
      FILE *file1 = fopen("files/file1.txt", "r");
      printf("opened file: %p\n", file1);
  
      __chi_hook__(ret) {
        fclose(file1);
        printf("closed file: %p\n", file1);
      };
  
      FILE *file2 = fopen("files/file2.txt", "r");
      printf("opened file: %p\n", file2);
  
      __chi_hook__(ret) {
        fclose(file2);
        printf("closed file: %p\n", file2);
      };
  
      char buf[128] = {0};
      
      fgets(buf, sizeof buf - 1, file1);
      printf("read from file: %p\n", file1);
      printf("content: %s\n", buf);
  
      fgets(buf, sizeof buf - 1, file2);
      printf("read from file: %p\n", file2);
      printf("content: %s\n", buf);
    ret:
      return 0;
    }
    ```
  ],
  caption: "χ 语言中的文件资源回收"
) <code:example-file-close>

@code:example-file-close 的运行结果如下：

#sourcecode[
  ```txt
  opened file: 0x563b3e4a22a0
  opened file: 0x563b3e4a2890
  read from file: 0x563b3e4a22a0
  content: Hello, World!
  
  read from file: 0x563b3e4a2890
  content: Hello, Chi-Lang!
  
  closed file: 0x563b3e4a2890
  closed file: 0x563b3e4a22a0
  ```
]

#pagebreak(weak: true)

== 多资源锁获取与回收

@code:example-mutex-group-lock-and-unlock 展示一个多资源锁获取与回收的例子，通过 χ-hook 语法，可防止死锁与资源泄漏。

#figure(
  sourcecode[
    ```c
    #include <errno.h>
    #include <pthread.h>
    #include <stdio.h>

    #define MUTEX_NUM 32
    #define PTHREAD_NUM 16

    pthread_mutex_t mtx[MUTEX_NUM];
    pthread_t thread[PTHREAD_NUM];

    int access_index(int child_index, int array_index) {
      return child_index % 2 == 0 ? array_index : MUTEX_NUM - array_index - 1;
    }

    void *race(void *arg) {
      const int index = (int)arg;
      int i;

      __chi_hook__ (retry) {
        for (; i >= 0; i--)
          pthread_mutex_unlock(&mtx[access_index(index, i)]);
      };
      __chi_hook__ (ret) {
        for (i = 0; i < MUTEX_NUM; i++)
          pthread_mutex_unlock(&mtx[access_index(index, i)]);
      };
      while (1) {
        for (i = 0; i < MUTEX_NUM; i++)
          if (pthread_mutex_trylock(&mtx[access_index(index, i)]) == EBUSY)
            goto retry;
        break;
      retry:
      }
      printf("thread %d (tid=%lu) acquired all mutexes\n", index, pthread_self());
    ret:
      return NULL;
    }

    int main() {
      int i;
      
      for (i = 0; i < MUTEX_NUM; i++)
        pthread_mutex_init(&mtx[i], NULL);
      __chi_hook__ (ret) {
        for (i = 0; i < MUTEX_NUM; i++)
          pthread_mutex_destroy(&mtx[i]);
      };
      for (i = 0; i < PTHREAD_NUM; i++)
        pthread_create(&thread[i], NULL, race, (void *)i);
      for (i = 0; i < PTHREAD_NUM; i++) {
        pthread_join(thread[i], NULL);
        printf("child %d (tid=%lu) exited\n", i, thread[i]);
      }
    ret:
      return 0;
    }
    ```
  ],
  caption: "χ 语言中的多锁资源获取与回收"
) <code:example-mutex-group-lock-and-unlock>

@code:example-mutex-group-lock-and-unlock 的运行结果如下：

#sourcecode[
  ```txt
  thread 0 (tid=140624507016896) acquired all mutexes
  thread 2 (tid=140624490231488) acquired all mutexes
  thread 1 (tid=140624498624192) acquired all mutexes
  thread 3 (tid=140624481838784) acquired all mutexes
  thread 4 (tid=140624473446080) acquired all mutexes
  thread 5 (tid=140624342808256) acquired all mutexes
  thread 6 (tid=140624465053376) acquired all mutexes
  thread 7 (tid=140624456660672) acquired all mutexes
  thread 8 (tid=140624448267968) acquired all mutexes
  thread 9 (tid=140624439875264) acquired all mutexes
  thread 10 (tid=140624431482560) acquired all mutexes
  thread 11 (tid=140624423089856) acquired all mutexes
  thread 12 (tid=140624334415552) acquired all mutexes
  thread 13 (tid=140624326022848) acquired all mutexes
  thread 14 (tid=140624317630144) acquired all mutexes
  child 0 (tid=140624507016896) exited
  child 1 (tid=140624498624192) exited
  thread 15 (tid=140624309237440) acquired all mutexes
  child 2 (tid=140624490231488) exited
  child 3 (tid=140624481838784) exited
  child 4 (tid=140624473446080) exited
  child 5 (tid=140624342808256) exited
  child 6 (tid=140624465053376) exited
  child 7 (tid=140624456660672) exited
  child 8 (tid=140624448267968) exited
  child 9 (tid=140624439875264) exited
  child 10 (tid=140624431482560) exited
  child 11 (tid=140624423089856) exited
  child 12 (tid=140624334415552) exited
  child 13 (tid=140624326022848) exited
  child 14 (tid=140624317630144) exited
  child 15 (tid=140624309237440) exited
  ```
]

#pagebreak(weak: true)

== 开发场景

在实际开发场景中，利用 hook 可以触发多个代码块多特点，在代码编写的过程中可以更集中于每个元素自身的行动模式，在使用时借由 hook 机制统一触发。@code:example-develop 模拟了“三国杀”游戏的对战过程。

#figure(
  sourcecode[
    ```c
    #include <stdio.h>
    #define true 1
    #define false 0
    
    int main() {
      // 模拟三国杀场景
      int playerHP[5] = {5, 4, 3, 3, 5};
      int GameOver = false;
      int winner0 = -1, winner1 = -1;
      // player0 是主公，每次攻击活着的下一个人, 胜利条件是杀光反贼、内奸
      __chi_hook__(move) {
        if (playerHP[0] > 0) {
          for (int i = 1; i < 5; ++i) {
            if (playerHP[i] > 0) {
              playerHP[i] -= 1;
              break;
            }
          }
        }
      };
      __chi_hook__(check) {
        if (playerHP[1] <= 0 && playerHP[2] <= 0 && playerHP[4] <= 0) {
          GameOver = true; winner0 = 0; winner1 = 1;
        }
      };
      // player1 是忠臣，每次攻击活着的下一个除主公以外的人, 胜利条件与主公相同
      __chi_hook__(move) { /* 省略具体实现 */ };
      // player2 是反贼，每次攻击主公，胜利条件是主公死亡
      __chi_hook__(move) { /* 省略具体实现 */ };
      __chi_hook__(check) {
        if (playerHP[0] <= 0) {
          GameOver = true; winner0 = 2; winner1 = 3;
        }
      };
      // player3 是反贼，每次攻击主公，胜利条件是主公死亡
      __chi_hook__(move) { /* 省略具体实现 */ };
      // player4 是内奸，均衡场上局势，胜利条件是自己以外的人均死亡
      __chi_hook__(move) { /* 省略具体实现 */ };
      __chi_hook__(check) {
        if (playerHP[0] <= 0 && playerHP[1] <= 0 && 
            playerHP[2] <= 0 && playerHP[3] <= 0) {
          GameOver = true; winner0 = 4; winner1 = -1;
        }
      };
      int Round = 0;
      while (!GameOver) {
        move:
        check:
        printf("Simulate Round %d: \n", ++Round);
      }
      printf("winner: %d %d\n", winner0, winner1);
      return 0;
    }
    ```
  ],
  caption: "χ 语言在开发中的应用"
) <code:example-develop>


= 附录

在本节中，我们提供了基于 #link("https://github.com/llvm/llvm-project")[clang 仓库] `release/17.x` 的 patch，读者可使用该 patch 或使用我们的 #link("https://github.com/Coekjan/chi-lang")[chi-lang 仓库]复现我们的工作。

#sourcecode[
  #raw(lang: "patch", read("chi-lang.patch"))
]
