# Learning Swift From This App

This file has two parts.

**Part 1** is a real walk through Swift's grammar and style — the language
itself, independent of this codebase. It covers things Swift can do whether
or not `ClaudeUsageMonitor` happens to use them, because a tour limited to
"whatever this one app does" leaves real gaps (this app barely uses `throw`,
never uses generics beyond one function, never needs `weak`/`unowned`
beyond one closure, etc.). Read Part 1 top to bottom once, like a language
guide, ideally with a Swift file open (even an empty playground) so you can
type the examples and see what the compiler says back.

**Part 2** is the original guided tour: every concept tied to a specific
line in this real, working macOS menu bar app. Once Part 1 has given you
the vocabulary, Part 2 shows you that vocabulary used under real
constraints — deadlines, framework quirks, actual bugs and their fixes.

The intended way to use this: read Part 1 in order. Then read Part 2
section by section, opening the referenced file alongside this doc each
time, looking at the code in full context (not just the quoted snippet).

---

# Part 1: Swift, from the ground up

## 1.0 What even is a program?

Before looking at any Swift code, it helps to be clear on what a program
*is* — what it means to write one, compile one, and run one — because
every piece of language syntax makes more sense once you have that
foundation.

### Source code, compiler, binary

A program starts as **source code** — a plain text file that a human
writes and reads. The text itself does nothing; it's just instructions in
a language the computer doesn't directly understand. To make it runnable,
you pass it through a **compiler**, which reads the text and translates it
into a **binary** — a file of raw machine instructions (zeros and ones)
that the CPU can execute directly.

When you run `swift build` in this project's directory, that's the
compiler step. Swift reads every `.swift` file in `Sources/`, checks that
they're valid, and if everything's correct, writes a binary to the
`.build/release/` folder. If something's wrong — a typo, a type mismatch,
a missing variable — the compiler stops and tells you exactly which file
and line number the problem is on, *before any code runs*. This is
fundamentally different from Python or JavaScript, where you often only
discover an error when the program actually tries to execute that broken
line. Swift's compiler finds a whole category of bugs at compile time so
you never encounter them at runtime.

### What is a "type"?

Every value in a program has a **type**: a label that tells the computer
what kind of value this is, how many bytes of memory it occupies, and what
operations are legal on it. An `Int` (integer) occupies 8 bytes, and you
can add two of them. A `String` (text) occupies variable memory, and you
can concatenate two of them. A `Bool` occupies 1 byte and has only two
possible values: `true` or `false`.

When the compiler sees:

```swift
let x = 5
```

it doesn't just record the value `5`. It also decides: "the type of `x`
is `Int`." Now, if you later write:

```swift
let y = x + "hello"
```

the compiler immediately catches this as a type error — you can't add an
`Int` and a `String`. This error happens at compile time, not at runtime,
which means your app never ships with that bug.

Concretely, `let x = 5` means: "reserve 8 bytes of memory, store the
value 5 there, call that location `x`, and from this point forward treat
`x` as an `Int`." The name `x` doesn't exist when the program actually
runs — the compiler replaces it with the memory address. The name is for
you, not the CPU.

### What is a "crash"?

A crash is when a running program encounters a situation it cannot
continue from — it terminates abruptly rather than doing something wrong
silently. Common causes:

- **Accessing memory that doesn't belong to you** — in C this is an
  out-of-bounds array access; it reads garbage or triggers an OS
  protection fault. Swift prevents this: accessing an array out of bounds
  *always* crashes immediately with a clear error message rather than
  silently reading garbage.
- **Unwrapping a nil value** — if you tell Swift "this optional definitely
  has a value" (`someOptional!`) and you're wrong, the program crashes with
  "Unexpectedly found nil." This is the Swift equivalent of a
  NullPointerException.
- **Integer overflow** — in debug mode, Swift crashes if you exceed the
  range of an integer type. C would silently wrap around and give you wrong
  math.

Swift's approach is: if something's wrong, crash loudly and early rather
than limp along silently producing wrong results. The crash message
includes a file name and line number; the program didn't go *further*
wrong before stopping.

### What `swift build` and `./build_app.sh` actually do

Running `swift build -c release` in this project:
1. Reads `Package.swift` to understand which source files belong to which
   targets (`UsageCore` library + `Usage` executable + `UsageTests` test
   target).
2. Compiles each `.swift` file in `Sources/UsageCore/` into a library
   object.
3. Compiles each `.swift` file in `Sources/ClaudeUsageMonitor/` into an
   executable that links against the `UsageCore` library.
4. Outputs the binary at `.build/release/Usage`.

`./build_app.sh` then wraps that binary in a proper macOS `.app` bundle —
a folder named `Usage.app/` containing `Info.plist` (app metadata), the
binary itself at `Contents/MacOS/Usage`, and optionally an icon. The
bundle is important because macOS's WKWebView (the embedded browser that
handles login) stores its session cookies keyed to the bundle identifier —
a bare binary doesn't have one, so cookies don't persist across relaunches.

---

## 1.1 The shape of a Swift file

A Swift source file has no required boilerplate. No class wrapping
everything (unlike Java), no `#include`/header split (unlike C), no
mandatory `package` declaration at the top (unlike Go or Java). A file can
be just:

```swift
let greeting = "hello"
print(greeting)
```

and that's a complete, valid, runnable piece of Swift. Statements don't
need semicolons — a newline ends a statement. You *can* write a semicolon
to put two statements on one line (`let a = 1; let b = 2`), but it's rare
in idiomatic Swift and this codebase never does it.

Comments: `//` for a line, `/* ... */` for a block (and block comments can
nest in Swift, unlike C: `/* outer /* inner */ still outer */` is legal).
This codebase's style — per its own CLAUDE.md — is to write very few
comments, and only ones that explain *why*, not *what*. That's a project
convention, not a language requirement; Swift itself is comment-agnostic.

## 1.2 `let` vs `var` — the first decision you make about every value

Every value you name in Swift is either a **constant** (`let`) or a
**variable** (`var`):

```swift
let pi = 3.14159       // constant: cannot be reassigned after this line
var counter = 0         // variable: can be reassigned
counter += 1             // fine
pi = 3.0                 // compile error: cannot assign to value: 'pi' is a 'let' constant
```

Why does this distinction exist at all? In a short script you might not
care — you could use `var` for everything and it would work. But in a real
program with thousands of lines, "can this value change later?" is a real,
important question. If you use `var` for everything, a reader (or your
future self) has no quick way to know whether a value *actually* changes
later or just *might*. Using `let` for anything that doesn't change is a
statement: "this value is set once and never touched again — you don't
need to track it." That makes the code much easier to reason about, and
it means the compiler can sometimes make the program faster knowing the
value is fixed.

Swift's culture leans hard toward `let` by default — you only reach for
`var` when you specifically know a value needs to change. A stray `var`
where a `let` would do is exactly the kind of thing a code reviewer will
flag.

> **Try this:** Create a file with `let x = 5`, then try `x = 10` on the
> next line. Run `swift <filename>.swift` and read the error the compiler
> produces. Then change `let` to `var` and confirm it now compiles.

Note that "constant" describes the *binding*, not necessarily deep
immutability — see structs vs. classes (§1.10) for what `let` actually
buys you with each.

## 1.3 Type inference and explicit annotation

Every value in Swift has a type. The compiler needs to know the type of
every value before the program runs — but it's often smart enough to
figure it out for you from the value you provide:

```swift
let x = 42          // inferred: Int
let y = 3.14         // inferred: Double
let s = "hi"          // inferred: String
let flag = true        // inferred: Bool
```

This is called **type inference** — the compiler looks at the right-hand
side (`42`, `3.14`, etc.) and decides what type `x`, `y`, etc. must be.
You don't have to write the type yourself, though you *can* by adding a
colon after the name:

```swift
let x: Int = 42          // same result, explicit annotation
```

You *must* annotate explicitly when there's no initial value to infer
from, or when you want a different type than the default:

```swift
let n: Double = 42          // without annotation, `42` infers as Int, not Double
var name: String              // declared but not initialized — compiler will require
                               // you to set it before using it
let scores: [Int] = []          // empty array literal — nothing to infer element type from
```

**Swift is statically and strongly typed.** This is different from Python
or JavaScript, where values can quietly change type at runtime. In Swift,
once a value is typed, it stays that type forever — and the compiler
refuses any operation that mixes incompatible types without an explicit
conversion:

```swift
let total = 1 + 2.0          // compile error: Int + Double is not allowed
let total = 1.0 + 2.0        // fine: both Doubles
let total = Double(1) + 2.0  // fine: explicit conversion from Int to Double
```

This trips up people coming from Python or JavaScript constantly, but it's
also what makes Swift's compiler so useful: a huge class of runtime bugs
simply can't reach you because the compiler blocked them at the source.

> **Try this:** Write `let result = "3" + 3` and see what error the
> compiler gives. Then try `let result = Int("3")! + 3` — the `!` is an
> "I promise this conversion works" (you'll learn what it actually does
> in §1.6).

The short mental model: Swift's compiler knows the type of every
expression — and if two types don't fit together, it tells you exactly
where the mismatch is before you ever run the program.

## 1.4 Basic types

Swift has a small set of built-in types you'll use constantly:

**`Int`** — a whole number (no decimal point). On every Mac you'll target,
`Int` is 64 bits, meaning it can hold values from about −9.2 quintillion
to +9.2 quintillion — more than enough for almost any count or index.
`Int8`, `Int16`, `Int32`, `Int64` and unsigned `UInt*` variants exist for
when the width specifically matters (binary protocols, C interop — see
§2.3.11 in Part 2 for a real example, but you'll rarely need them in
ordinary code).

```swift
let count = 42
let negativeTemp = -7
let bigNumber = 1_000_000    // underscores in literals are allowed and ignored;
                              // they're just for readability
```

**`Double`** and **`Float`** — numbers with a decimal point. `Double` is
the default: any literal like `3.14` is a `Double` unless you annotate
otherwise. `Float` has half the precision (32 bits vs. 64 bits) and is
rarely the right choice unless you're working with graphics APIs that
specifically want it. When in doubt, use `Double`.

```swift
let pi: Double = 3.14159
let proportion = 0.75      // inferred as Double
```

**`Bool`** — `true` or `false`. There's no automatic conversion from
other types in Swift: `if someInt` is a compile error, you must write
`if someInt != 0`. This is deliberate — Swift refuses to guess which type's
notion of "truthy" you meant.

```swift
let isConnected = true
let isLoading: Bool = false
```

**`String`** — text. Covered in depth in §1.18; not just "an array of
bytes" the way C strings are. Notable: you create one with double quotes,
and you embed other values inside one with `\(...)`:

```swift
let name = "Ada"
let greeting = "Hello, \(name)!"    // "Hello, Ada!"
let digits = "\(42 * 2)"             // "84"
```

**`Character`** — a single human-readable character. You'll use this
infrequently, but it explains why you can't add an integer index directly
to a String (§1.18).

**Tuples** — a lightweight, unnamed grouping of values, useful when you
want to return more than one thing from a function without declaring a
whole `struct` for it:

```swift
func minMax(_ numbers: [Int]) -> (min: Int, max: Int) {
    (numbers.min()!, numbers.max()!)
}
let result = minMax([4, 1, 9, 3])
print(result.min, result.max)   // 1 9
```

Tuples are good for small, throwaway groupings inside a function or
between two closely related lines. The moment you find yourself passing a
tuple through three different functions, or adding a fourth field to it,
promote it to a `struct` (§1.10) — a tuple has no label, no methods, and
no way to validate its contents at construction time.

> **Try this:** In a blank `.swift` file, create `let x: Int = 3.14` and
> see what error the compiler produces. Then try `let x = Int(3.14)` and
> note how the explicit conversion is required. Swift is never going to
> silently truncate a `Double` to an `Int` behind your back.

## 1.5 Control flow

Control flow is how you tell a program to make decisions, repeat work, or
skip things. Swift's control flow will look familiar if you've seen any C,
Java, JavaScript, or Python — with some deliberate restrictions that
prevent common bugs.

### if / else

The condition never needs (and never takes) parentheses, and the braces
are always mandatory — there is no single-line-without-braces `if` in
Swift:

```swift
let score = 85

if score > 90 {
    print("A")
} else if score > 80 {
    print("B")
} else {
    print("C")
}
// prints "B"
```

Why mandatory braces? Because optional-braces `if` is the source of a
famous class of bugs in C. Without braces, you can accidentally write
code that looks like two lines are in the `if` block but only the first
actually is. Swift eliminates the ambiguity by requiring braces, always.

`if` can also be used as an expression (Swift 5.9+):

```swift
let grade = if score > 90 { "A" } else if score > 80 { "B" } else { "C" }
```

The shorter **ternary** form from older languages also works:
`let grade = score > 90 ? "A" : "B"`. Use it for simple two-branch
choices; use a full `if`/`else` when either branch has multiple lines.

### switch

Swift's `switch` is far more powerful than C's. Three things distinguish
it:

1. **Exhaustive by default.** If you `switch` over an `enum`, the compiler
   refuses to compile unless you've covered every case. This is load-bearing
   — it means adding a new `enum` case automatically breaks every `switch`
   that doesn't handle it, at compile time. (See §2.3.13 in Part 2 for an
   exact example from this app.)

2. **No implicit fallthrough.** In C's `switch`, execution "falls through"
   from one case to the next unless you explicitly write `break`. Swift
   reverses this: each `case` is entirely separate by default. To share
   behavior between cases, list them on one line separated by commas.

3. **Real pattern matching.** `case` can match ranges, tuples, bind
   variables, and add `where` guards:

```swift
let percent = 73.0

switch percent {
case 0:
    print("nothing used")
case 1..<50:                          // range pattern: matches 1, 2, ..., 49
    print("low")
case 50..<80, 80..<90:                // two ranges, one case (no fallthrough needed)
    print("medium")
case let x where x >= 90:             // binds `x` and adds an extra condition
    print("high: \(x)%")
default:
    print("other")
}
```

The `default` case is required when the `switch` can't be exhaustive —
like when the scrutinized type is `Double`, which has infinitely many
values.

### for-in loops

There is no C-style `for (int i = 0; i < n; i++)` in Swift — that syntax
was removed from the language deliberately. Iteration is always over a
*sequence*, using `for item in sequence`:

```swift
for i in 0..<5 { print(i) }              // half-open range: 0, 1, 2, 3, 4
for i in 0...5 { print(i) }              // closed range: 0, 1, 2, 3, 4, 5
for item in someArray { print(item) }
for (key, value) in someDictionary { print(key, value) }
for i in stride(from: 0, to: 10, by: 2) { print(i) }   // 0, 2, 4, 6, 8
```

`0..<5` is a "half-open range" — it includes 0, 1, 2, 3, 4 but *not* 5.
This lines up with arrays, which are zero-indexed (`array[0]` through
`array[4]` for a 5-element array), so `for i in 0..<array.count` covers
every valid index exactly.

### while and repeat-while

For the rare case where you don't have a sequence to iterate, just a
condition to check:

```swift
var count = 0
while count < 3 {
    print(count)
    count += 1
}
// 0, 1, 2

repeat {
    print("at least once")
} while false
// prints "at least once" (body always runs at least one time)
```

> **Try this:** Write a loop that prints only the even numbers from 0 to
> 20 using `stride`. Then write it again using a `for i in 0...20`
> combined with an `if i % 2 == 0` — notice how `stride` is more direct
> when you know the stepping pattern ahead of time.

## 1.6 Optionals — the single most distinctive thing about Swift

### The problem optionals solve

In most programming languages, any variable that holds an object can also
hold a special "nothing" value — called `null` in Java/JavaScript/C#, or
`None` in Python, or `nil` in older Objective-C. This sounds fine until
you forget to check for it:

```
// pseudocode for what happens in Java/Python/etc.
username = lookUpUsername(forUserID: 42)
// username might be null if no user with ID 42 exists!

print(username.uppercased())
// If username IS null, this crashes: NullPointerException
// This is one of the most common runtime crashes in any codebase
```

The problem is that the *type* of `username` (a `String`) gives you no
clue whether it can be null. You have to read the documentation (or learn
from a crash) to discover that `lookUpUsername` might return nothing. The
null check is easy to forget because nothing in the type system reminds
you it's necessary.

Swift's solution is the **Optional** type. Instead of allowing any value
to be "secretly null," Swift makes the possibility of absence a visible
part of the type itself:

- `String` means "this is definitely a String — I guarantee it."
- `String?` means "this might be a String, or it might be nothing."

And these two types are *different* — you cannot use a `String?` where a
`String` is expected, without explicitly handling the possibility of
"nothing" first. The compiler tracks this everywhere and refuses to compile
code that ignores it.

### What nil looks like in Swift

Any type `T` has a counterpart `Optional<T>`, written `T?`, meaning "either
a value of type `T`, or nothing (`nil`)." This is not a hidden null pointer
— it's a real type (an `enum` with two cases, `.some(value)` and `.none`,
that the compiler gives special syntax sugar to), and the type system
tracks the difference between `String` and `String?` at every single use.
You cannot pass a `String?` where a `String` is expected without explicitly
dealing with the possibility of `nil` first.

```swift
var name: String? = "Ada"
name = nil          // legal — that's the whole point of the `?`
```

You cannot use an optional directly as if it were the wrapped value —
`name.count` is a compile error on a `String?`. You have to unwrap it
first, and Swift gives you several ways to do that, each suited to a
different situation:

**Optional binding** (`if let` / `guard let`) — the most common, safest
form. It only enters the new scope if the value is non-nil, and inside
that scope you have a real, non-optional value:

```swift
if let realName = name {
    print("Hello, \(realName)")     // realName is a plain String in here
} else {
    print("no name")
}
```

`guard let` is the same idea, but for "bail out early if this is nil"
rather than "branch into two cases" — extremely common at the top of a
function:

```swift
func greet(_ name: String?) -> String {
    guard let name = name else { return "Hello, stranger" }
    return "Hello, \(name)"        // name is unwrapped for the rest of the function
}
```

Note the name-shadowing idiom `guard let name = name` — rebinding the
unwrapped value to the *same* name as the optional is standard Swift
style, not a mistake; it means you never accidentally refer to the
optional version again later in the function. (As of Swift 5.7+ you can
write the even shorter `guard let name else { ... }` when you want to keep
the same name — this codebase's `UsageMonitor` code still spells it out
the older, fully-explicit way in places, which is equally correct.)

**Nil-coalescing operator (`??`)** — "use this value, or a default if it's
nil," in one expression:

```swift
let displayName = name ?? "Anonymous"
```

**Optional chaining (`?.`)** — call a method or access a property on an
optional, short-circuiting to `nil` if any link in the chain is `nil`,
without ever crashing:

```swift
let upperFirstLetter = name?.first?.uppercased()
// if `name` is nil, the whole expression is nil — no crash, no unwrap needed
```

**Force unwrap (`!`)** — "I am certain this is not nil; crash the program
if I'm wrong":

```swift
let definitelyName = name!     // traps at runtime if name is nil
```

This is the one tool in the list that can crash, and it should be treated
as a small, explicit admission: "I've checked this elsewhere and the
compiler can't see that proof." Reaching for `!` as a way to silence the
compiler instead of actually handling `nil` is the single most common
mistake Swift beginners make, and it's exactly what optional binding and
`??` exist to make unnecessary in almost every real case.

**Implicitly unwrapped optionals (`T!`)**, as a *type* annotation rather
than an operator, show up in one specific situation: a property that is
genuinely optional only during a brief initialization window (classic
example: an `@IBOutlet` in UIKit, wired up by Interface Builder after
`init` runs but guaranteed non-nil for the rest of the object's life). You
treat a `T!` like a plain `T` everywhere after that window — it still
crashes if you're wrong, same as `!`, it just doesn't make you write the
`!` at every single use site.

> **Try this:** Write a function `lookUp(id: Int) -> String?` that returns
> `"Alice"` if `id == 1` and `nil` otherwise. Call it and try to pass the
> result directly to a function that expects a `String` — the compiler
> will refuse. Then use `if let` to unwrap it and pass the unwrapped value.
> Notice how the compiler *forces* you to handle the nil case at the point
> you use it, not three lines later when you've forgotten about it.

## 1.7 Collections: Array, Dictionary, Set

```swift
var numbers: [Int] = [1, 2, 3]          // Array<Int>, shorthand [Int]
var ages: [String: Int] = ["Ada": 36]     // Dictionary<String, Int>, shorthand [String: Int]
var unique: Set<Int> = [1, 2, 3]          // Set<Int> — no shorthand syntax, unordered, no duplicates
```

All three are **value types** (structs under the hood — see §1.9), which
means assigning one to another variable, or passing it into a function,
copies it conceptually — mutating the copy never affects the original.
(Swift optimizes this with copy-on-write under the hood, so it's not
actually duplicating memory until one of the copies is mutated — but the
*semantics* you can rely on, the part that matters for correctness, is
"independent copies.")

Key methods worth knowing cold, because they replace most hand-written
loops:

```swift
let doubled = numbers.map { $0 * 2 }                  // [2, 4, 6]
let evens = numbers.filter { $0 % 2 == 0 }              // [2]
let sum = numbers.reduce(0) { $0 + $1 }                  // 6, or just numbers.reduce(0, +)
let sorted = numbers.sorted(by: >)                        // descending
let found = numbers.first { $0 > 1 }                       // Optional(2) — first match or nil
let allPositive = numbers.allSatisfy { $0 > 0 }              // true
```

`map`/`filter`/`reduce` chain naturally and read close to a description of
the transformation: `numbers.filter { $0 > 1 }.map { $0 * 10 }`. This
codebase uses exactly this style throughout (e.g. `recent.map(\.turnCount)`
in `Insights.swift` — note the `\.turnCount` key-path shorthand, equivalent
to `{ $0.turnCount }`, used as a function argument directly).

Dictionary access always returns an `Optional` — `ages["Ada"]` is `Int?`,
not `Int`, because the key might not exist. This is the same optional
mechanism from §1.6 showing up automatically, not a special case.

> **Try this:** Create an array `[5, 2, 8, 1, 9, 3]`. Chain `.filter`,
> `.map`, and `.sorted` to produce a sorted list of the squares of all
> even numbers. The answer (for this array) is `[4, 64]`. Notice how each
> step reads like a description of what you want rather than how to do it
> — this style is common throughout this app's codebase.

## 1.8 Functions

```swift
func add(_ a: Int, _ b: Int) -> Int {
    a + b              // implicit return: a single-expression function body
                        // can omit the `return` keyword (Swift 5.1+)
}
```

Swift functions distinguish an **argument label** (what the caller writes)
from a **parameter name** (what you use inside the function body) —
they're often the same, but don't have to be:

```swift
func greet(person name: String) -> String {
    "Hello, \(name)"
}
greet(person: "Ada")          // caller writes `person:`
                               // body refers to it as `name`
```

The underscore `_` you saw in `add(_ a: Int, _ b: Int)` means "no argument
label" — the caller writes `add(1, 2)`, not `add(a: 1, b: 2)`. Choosing
labeled vs. unlabeled parameters is a real API design decision in Swift,
not boilerplate: labels make call sites read like English
(`view.insertSubview(label, at: 0)`) when that helps, and get dropped when
the parameter's role is obvious from context (`add(1, 2)`).

Default parameter values and variadic parameters:

```swift
func renderPieIconImage(percent: Double, diameter: CGFloat = 16, trailingGap: CGFloat = 6) -> NSImage { ... }
// callers can omit diameter/trailingGap entirely and get the defaults —
// this is a real signature from this app's Settings.swift

func sum(_ numbers: Int...) -> Int {     // variadic: caller passes any number of Ints
    numbers.reduce(0, +)
}
sum(1, 2, 3, 4)
```

`inout` parameters let a function mutate the caller's variable directly,
rather than a copy — the caller must mark the argument with `&`:

```swift
func increment(_ value: inout Int) {
    value += 1
}
var x = 5
increment(&x)
print(x)        // 6
```

Functions are first-class values in Swift — a function's type is just
another type you can store, pass around, and return:

```swift
func makeAdder(adding amount: Int) -> (Int) -> Int {
    { value in value + amount }       // returns a closure (see §1.9 below)
}
let addFive = makeAdder(adding: 5)
addFive(10)        // 15
```

> **Try this:** Write a function `clamp(_ value: Double, min: Double,
> max: Double) -> Double` that returns `min` if `value` is below `min`,
> `max` if `value` is above `max`, and `value` otherwise. Call it with
> a few test values to confirm. This function — or its equivalent — shows
> up in this app's `Geometry.swift` to ensure windows can't be positioned
> off-screen.

## 1.9 Closures

### Why closures exist

When you pass a function to another function — "call this when you're
done," or "use this to decide whether to include each item" — you often
don't need a full named function. A one-liner that you'll never call from
anywhere else doesn't deserve a name and a separate definition. **Closures**
are the answer: an inline, anonymous function value, written at the place
where it's used.

A closure is the same concept as a lambda in Python or an arrow function
in JavaScript, but with several syntax shortcuts Swift applies
progressively as context lets it infer more:

```swift
let multiply: (Int, Int) -> Int = { (a: Int, b: Int) -> Int in
    return a * b
}
```

That's the fully spelled-out form. Swift can usually infer the parameter
and return types from context, so in practice you'll see much shorter
forms, all equivalent when the closure is, say, the argument to
`sorted(by:)`:

```swift
numbers.sorted(by: { (a: Int, b: Int) -> Bool in a < b })   // explicit types
numbers.sorted(by: { a, b in a < b })                         // types inferred
numbers.sorted(by: { $0 < $1 })                                // $0/$1 shorthand for the args
numbers.sorted(by: <)                                            // `<` itself is a function value
```

**Trailing closure syntax**: when a closure is the *last* argument to a
function, you can move it outside the parentheses (and drop the
parentheses entirely if it's the *only* argument). This is everywhere in
real Swift/SwiftUI code:

```swift
numbers.map { $0 * 2 }                 // trailing closure, no parens needed at all
DispatchQueue.main.async {
    self.refresh()
}
```

That second example is exactly the shape used throughout this app's
background-work pattern (Part 2 §2.3.9) — `DispatchQueue.global(qos:).async { ... }`
is a function call whose only argument is a trailing closure.

**Capturing values**: a closure captures (keeps alive) any variable from
its enclosing scope that it references, for as long as the closure itself
exists. This is what makes the stored-closure pattern in Part 2 §2.3.5
work — and it's also exactly what creates the reference-cycle risk that
`[weak self]` exists to solve (covered there in detail).

> **Try this:** Write a function `makeMultiplier(by factor: Int) -> (Int)
> -> Int` that returns a closure capturing `factor`. Call it to create
> `double = makeMultiplier(by: 2)` and `triple = makeMultiplier(by: 3)`.
> Verify `double(5) == 10` and `triple(5) == 15`. Notice that `factor`
> is captured inside each closure and lives on independently — `double`
> and `triple` each have their own copy of it.

## 1.10 Structs vs. classes — value semantics vs. reference semantics

This is the single biggest "this isn't like the language I came from"
decision in Swift, and getting an intuition for it matters more than
almost anything else in this list.

```swift
struct Point { var x: Int; var y: Int }
class Counter { var value: Int = 0 }
```

A **struct** is a *value type*: when you assign it to a new variable, pass
it to a function, or store it in a collection, you get an independent
copy. Mutating the copy never affects the original.

```swift
struct Point { var x: Int; var y: Int }
var a = Point(x: 0, y: 0)
var b = a            // b is a full, independent copy of a
b.x = 100
print(a.x)            // 0 — unaffected
```

A **class** is a *reference type*: assigning it, passing it, or storing it
just copies a reference to the *same* underlying object. Mutating through
one reference is visible through every other reference to that same
object.

```swift
class Counter { var value: Int = 0 }
let a = Counter()
let b = a            // b refers to the SAME object as a
b.value = 100
print(a.value)        // 100 — both `a` and `b` point at the one Counter
```

This is also why `let` means different things for the two: `let a =
Counter()` only prevents you from reassigning what `a` points *to* — you
can still mutate `a.value` freely, because the object itself isn't `let`,
the *binding* is. `let p = Point(x: 0, y: 0)` is much stricter: you can't
mutate `p.x` either, because there's no separate "object" to mutate — the
whole value *is* the binding.

A method on a struct that needs to modify the struct's own properties must
be marked `mutating` (and can then only be called on a `var`, never a
`let`, instance):

```swift
struct Point {
    var x: Int
    var y: Int
    mutating func moveRight(by amount: Int) {
        x += amount
    }
}
```

**When to use which**, as a rule of thumb that holds for the vast majority
of real code: prefer `struct` by default — for models, data, anything that
represents a *value* (a point, a color, a settings bundle, a parsed usage
record). Reach for `class` when you specifically need shared, mutable
identity — something where it matters that there's exactly *one* of it and
multiple parts of your code need to see the same live, mutating instance.
This app's own code is a clean real-world illustration of exactly that
split: `TurnUsage`, `AppSettings`, `SyncState`, `SavedCookie` are all
`struct`s — pure data, copied freely, no shared-identity concerns. `final
class UsageMonitor: ObservableObject` is a class because its entire job
*is* shared, observed, mutating identity — every view in the app needs to
see the literal same instance update live (Part 2 §2.3.6 covers this in
depth).

One more difference worth knowing: classes support **inheritance**
(`class Dog: Animal { ... }`), structs do not. This codebase doesn't use
class inheritance anywhere — every `class` in it (`UsageMonitor`,
`InsightsAnalyzer`, `TurnHistoryAnalyzer`, the window controllers,
`AppDelegate`) is declared `final` and stands alone. That's not an
accident: Swift's own culture (protocol-oriented programming, §1.13) tends
to reach for protocols and composition over class inheritance hierarchies,
and `final` is the explicit way of saying "this hierarchy stops here,"
which also lets the compiler skip dynamic dispatch (see Part 2 §2.3.6).

> **Try this:** Create a `struct Point` with `var x: Int` and `var y:
> Int`. Assign it to `var a`, then `var b = a`, then modify `b.x`. Print
> both `a.x` and `b.x`. Then do the same with `class Point` — same struct
> definition, different keyword. Notice how the class version makes `a.x`
> change when you modified through `b`, while the struct version left `a`
> untouched. This is the single most important behavioral difference between
> the two.

## 1.11 Enums — far more than C's named integers

### Why enums exist

Suppose you have a function that can succeed or fail, and if it fails it
can fail in a few distinct ways. In a language without enums you might
return an integer (0 = success, 1 = not found, 2 = permission denied) or
a string ("ok", "not_found", "denied") — but now the caller has to know
which integers or strings are valid, and there's nothing stopping them
from passing 99 or "typo". An `enum` solves this by making the valid
values a closed set of named cases that the compiler checks for you.

A C `enum` is just a set of named integer constants. Swift's `enum` is a
real, full-featured type:

```swift
enum Direction {
    case north, south, east, west
}
```

**Raw values** — give every case an underlying value of some type, for
free serialization/round-tripping:

```swift
enum SeparatorStyle: String, CaseIterable {
    case chevron, dot, bar, diamond
}
SeparatorStyle.dot.rawValue          // "dot"
SeparatorStyle(rawValue: "bar")        // Optional(.bar) — note: still optional,
                                        // since not every String is a valid case
```

**Associated values** — unlike raw values (one fixed value per case,
shared across all instances of that case), associated values let *each
instance* of a case carry its own different data:

```swift
enum NetworkResult {
    case success(data: Data)
    case failure(error: Error, statusCode: Int)
}

func handle(_ result: NetworkResult) {
    switch result {
    case .success(let data):
        print("Got \(data.count) bytes")
    case .failure(let error, let statusCode):
        print("Failed with \(statusCode): \(error)")
    }
}
```

This is the idiomatic Swift replacement for "a result object with a status
flag and then a bunch of fields that are only meaningful for some
statuses" — the enum's cases make illegal states (like "success" with an
error message attached) unrepresentable, rather than just unlikely. It's
also exactly the shape of Swift's own standard library `Result<Success,
Failure>` type, which is `enum Result<Success, Failure: Error> { case
success(Success); case failure(Failure) }` — you'll meet it constantly in
any code dealing with completion-handler-style asynchronous APIs (see
§1.15 and Part 2 §2.3.8).

`CaseIterable` (conformance shown above) auto-generates a static
`.allCases` array — `SeparatorStyle.allCases` gives you `[.chevron, .dot,
.bar, .diamond]` with zero manual maintenance, which is exactly how this
app builds its Settings picker's option list (Part 2 §2.3.1).

> **Try this:** Define an enum `Suit` with cases `hearts`, `diamonds`,
> `clubs`, `spades`. Add a computed property `isRed: Bool` that returns
> `true` for hearts and diamonds, `false` otherwise. Iterate over all
> cases with `for suit in Suit.allCases` and print each suit's name and
> whether it's red (you'll need `CaseIterable` for `.allCases`). Notice
> how exhaustive switch means if you later add a `.joker` case, the
> compiler immediately flags every switch that doesn't handle it.

## 1.12 Properties: stored, computed, and observed

A **stored property** just holds a value, like `var x: Int` in a struct.

A **computed property** has no storage of its own — it runs code every
time it's read (and optionally written):

```swift
struct Rectangle {
    var width: Double
    var height: Double
    var area: Double {                 // read-only computed property
        width * height
    }
    var perimeter: Double {            // computed property with both get and set
        get { 2 * (width + height) }
        set { width = newValue / 4; height = newValue / 4 }
    }
}
```

This app uses computed properties constantly for exactly the right
reason: a value that's always derivable from other state shouldn't be
stored and kept in sync by hand. `TurnUsage.weightedCost` (Part 2 §2.3.2)
and `UsageMonitor.estimatedPercent` are both computed, not stored — there
is no risk of them silently going stale the way a manually-updated stored
field could.

**Property observers** (`willSet`/`didSet`) let a *stored* property run
code in response to its own changes, without becoming a full computed
property:

```swift
var score: Int = 0 {
    didSet {
        print("Score changed from \(oldValue) to \(score)")
    }
}
```

**`lazy`** delays a stored property's initial computation until the first
time it's actually read, useful when the initial value is expensive and
might never be needed:

```swift
lazy var expensiveResult: [Int] = computeSomethingSlow()
```

> **Try this:** Create a struct `Circle` with a stored `radius: Double`.
> Add a computed property `area: Double` and a computed property
> `diameter: Double`. Confirm that changing `radius` immediately changes
> `area` and `diameter` without any extra code — that's the whole benefit
> of computed properties over manually-updated stored ones.

## 1.13 Protocols and protocol-oriented programming

### What a protocol is

A **protocol** is a contract. It says: "any type that claims to conform to
me must provide these properties and methods." It doesn't say *how* to
implement them — just *that* they must exist. This lets you write code
that works with any type conforming to the protocol, without caring about
the concrete type.

If you've used Java or TypeScript, you'll recognize this as an
`interface` — but in Swift, protocols are more central to how code is
organized. Almost everything in the standard library and in Apple's
frameworks is built around protocols, and learning to think in "what
capability does this type need?" rather than "what class hierarchy should
this fit into?" is one of the biggest mindset shifts in Swift.

A protocol declares a set of requirements — methods, properties — that any
conforming type must provide, with no implementation of its own:

```swift
protocol Greetable {
    var name: String { get }
    func greet() -> String
}

struct Person: Greetable {
    var name: String
    func greet() -> String { "Hello, \(name)" }
}
```

Where Swift goes further than a plain interface: **protocol extensions**
let you give a protocol a *default implementation*, which every conforming
type gets for free unless it chooses to override it:

```swift
extension Greetable {
    func greet() -> String { "Hi there, \(name)" }   // default implementation
}

struct Robot: Greetable {
    var name: String
    // no greet() override needed — uses the protocol extension's default
}
```

This is "protocol-oriented programming" — instead of building a class
hierarchy where shared behavior lives in a base class, you declare a
protocol for the *capability*, give it a default implementation via an
extension, and any type (struct, class, or enum — protocols work on all
three, unlike class inheritance) can opt in. SwiftUI's own `View` protocol
works exactly this way: it has one real requirement (`var body: some
View`), and everything else (`.padding()`, `.background()`, etc.) is
default behavior layered on via extensions. The `Shape` protocol this app
uses (Part 2 §2.3.3) is the same idea at a smaller scale: conform to
`Shape` by implementing one method (`path(in:)`), and you get an entire
`View` for free, because `Shape` itself extends `View` and provides default
behavior for everything else.

> **Try this:** Define a protocol `Describable` with one requirement:
> `var description: String { get }`. Make both a `struct Dog` and a
> `struct Car` conform to it. Write a free function
> `describe(_ thing: Describable)` that prints `thing.description`. Call
> it with both a `Dog` and a `Car` — the function doesn't care what the
> concrete type is, only that it satisfies `Describable`.

## 1.14 Extensions

An `extension` adds new functionality — methods, computed properties,
protocol conformances — to an *existing* type, including types you didn't
write yourself (Apple's own `String`, `Int`, `Array`, anything):

```swift
extension Int {
    var isEven: Bool { self % 2 == 0 }
}
4.isEven        // true
```

This is how this app's own `Color` theme constants are added (Part 2
§"Theme" in `App.swift`: `extension Color { static let bgDeep = ... }`) —
rather than wrapping `Color` in some custom theme type, the app just
*extends* SwiftUI's own `Color` with the app's specific palette, so
`Color.bgDeep` reads exactly like a built-in color (`Color.red`,
`Color.blue`) at every call site.

## 1.15 Generics

A generic function or type works over *any* type that satisfies some
constraint, written once instead of duplicated per concrete type:

```swift
func firstAndLast<T>(_ array: [T]) -> (T, T)? {
    guard let first = array.first, let last = array.last else { return nil }
    return (first, last)
}
firstAndLast([1, 2, 3])          // works for [Int]
firstAndLast(["a", "b", "c"])      // and for [String] — same function, no duplication
```

`T` here is a **type parameter** — a placeholder the compiler fills in
with whatever concrete type you actually called the function with, fully
type-checked at compile time (this is *not* like Java's type erasure or
duck typing — the compiler genuinely specializes and verifies each use).

Constraints (`where` clauses, or inline `<T: SomeProtocol>`) restrict what
`T` is allowed to be, in exchange for letting you call that protocol's
methods on values of type `T` inside the function:

```swift
func describe<T: CustomStringConvertible>(_ value: T) -> String {
    "Value is: \(value.description)"
}
```

This app's one real generic function, `binding<T>(_:)` in `Settings.swift`
(Part 2 §2.3.7), is a clean minimal example: it's generic over `T` so that
one function works for `Binding<Bool>`, `Binding<SeparatorStyle>`, and
every other settings field's type, instead of needing a hand-written
`Binding(get:set:)` block per field.

## 1.16 Error handling: `throw`, `try`, `catch`

### The problem error handling solves

When a function might fail — reading a file that might not exist, parsing
text that might not be valid JSON, connecting to a server that might be
down — you need a way to communicate that failure to the caller. Returning
`nil` (optional) works for simple "not found" cases, but sometimes you
want to explain *why* something failed, not just *that* it did. That's
what `throw`/`try`/`catch` is for.

Swift's structured error handling looks like Java's checked exceptions,
but is lighter weight. Any type conforming to the empty `Error` protocol
can be thrown:

```swift
enum ValidationError: Error {
    case tooShort
    case containsInvalidCharacters
}

func validate(_ password: String) throws {
    guard password.count >= 8 else { throw ValidationError.tooShort }
}
```

A function that can throw must be marked `throws` in its signature, and
every call site must be marked with one of three keywords:

```swift
do {
    try validate(password)
    print("valid")
} catch ValidationError.tooShort {
    print("too short")
} catch {
    print("some other error: \(error)")     // `error` is implicitly bound here
}

try? validate(password)        // converts to an Optional: nil on throw, discarding the error
try! validate(password)        // asserts it won't throw: crashes the program if it does
```

`try?` is the one you'll see most in real code that doesn't care *why*
something failed, only *whether* it succeeded — and it's exactly the
pattern this app's persistence functions lean on heavily (Part 2 §2.3.2):
`try? Data(contentsOf: url)` turns "maybe the file doesn't exist, maybe
it's unreadable, maybe the JSON is malformed" into a single `nil` you
handle with an ordinary `guard let ... else` fallback, with no `catch`
block needed because the app genuinely doesn't care which of those three
things happened — only that loading didn't succeed.

The completion-handler style this app uses for asynchronous work
(`UsageAPI.fetchRawUsageJSON(completion: @escaping (Result<...>) -> Void)`,
Part 2 §2.3.8) predates Swift's modern `async`/`await` (added in Swift 5.5)
and is a different mechanism from `throws` — it reports failure through a
`Result` value passed to a closure, rather than the `throw`/`catch`
control flow above. Both exist in real, current Swift code; which one
you're looking at depends on when that code was written and what API
shape it's calling into (`URLSession`'s older `dataTask(with:completion:)`
API predates `async`/`await` and is what `UsageAPI.swift` is built on).

> **Try this:** Write a function `divide(_ a: Double, by b: Double) throws
> -> Double` that throws a `DivisionError.divideByZero` (define that enum)
> if `b == 0`, and otherwise returns `a / b`. Call it three ways: with
> `do/try/catch`, with `try?` (discarding why it failed), and with `try!`
> (crashing on zero). Run the `try!` version with `b = 0` and observe the
> crash message and where it points.

## 1.17 Type casting

`as`, `as?`, and `as!` convert between types, mirroring the optional-unwrap
trio from §1.6:

```swift
let value: Any = "hello"
let upcast = value as String           // `as` for a guaranteed-safe upcast/conversion
let maybe = value as? Int                 // `as?` — Optional(Int), nil here since it's actually a String
let forced = value as! String             // `as!` — crashes if the cast is wrong
```

`Any` can hold a value of *any* type at all; `AnyObject` is the same idea
restricted to class instances. Both show up in this codebase exactly where
you'd expect — at the boundary with loosely-typed JSON
(`JSONSerialization.jsonObject(with:) as? [String: Any]` in `UsageAPI.swift`
and `App.swift`'s `parseTurnUsage`), because JSON has no static Swift type
until you've actually inspected and cast each field. Outside of boundaries
like JSON parsing or Objective-C/AppKit interop, reaching for `Any` in your
own code is usually a sign you should have used a generic (§1.15) or a
protocol (§1.13) instead — `Any` throws away all the type safety Swift
otherwise gives you for free.

## 1.18 Strings aren't byte arrays

A Swift `String` is a collection of `Character`s, where each `Character`
is a full Unicode **extended grapheme cluster** — what a human would call
"one visible character," even when it's composed of multiple underlying
Unicode scalars (an emoji with a skin-tone modifier, an accented letter
built from a base letter plus a combining mark, etc.). This means
`"👨‍👩‍👧‍👦".count` is `1`, even though that single family emoji is several
Unicode code points combined — and it means `String` does **not** support
direct integer indexing (`myString[3]` is a compile error). You navigate a
string with `String.Index`, usually via methods rather than raw offsets:

```swift
let s = "Hello"
s.first                  // Optional("H") as a Character
s.count                  // 5
s.uppercased()             // "HELLO"
s.contains("ell")           // true
s.replacingOccurrences(of: "l", with: "L")     // "HeLLo"
```

String interpolation (`"\(expression)"`) embeds any expression's
description directly:

```swift
let name = "Ada"
let count = 3
print("\(name) has \(count) message\(count == 1 ? "" : "s")")
```

Triple-quoted multi-line literals (`"""`) let you embed large blocks of
text — even another language entirely, like the embedded HTML this app
ships its phone dashboard as (Part 2 §2.3.14) — without escaping every quote
or newline.

## 1.19 `defer`

A `defer` block schedules code to run when the current scope exits — no
matter *which* exit path is taken (a normal fall-through, an early
`return`, or a thrown error) — and if there are multiple `defer` blocks in
one scope, they run in reverse order of how they were written:

```swift
func processFile() {
    let handle = openFile()
    defer { closeFile(handle) }     // guaranteed to run, however this function exits
    if somethingWrong {
        return                        // closeFile still runs
    }
    // ... use handle ...
}                                      // closeFile runs here on the normal path too
```

This is the idiomatic Swift answer to "make sure cleanup happens no matter
how this function exits," and it's most load-bearing exactly where manual
resource management shows up — freeing a C-allocated structure being the
clearest example, covered with a real instance from this codebase in Part
2 §2.3.11.

## 1.20 Access control

Five levels, from least to most restrictive: `open` and `public` (visible
outside the defining module — `open` additionally allows subclassing from
outside it), `internal` (the default if you write nothing — visible
anywhere in the same module, which for an app target means "anywhere in
this app"), `fileprivate` (visible only within the same source file), and
`private` (visible only within the same enclosing declaration, e.g. inside
one `struct` or `class` body).

```swift
private static func saveCookieJar(_ cookies: [SavedCookie]) { ... }   // only callable inside UsageAPI itself
static func loadCookieJar() -> [SavedCookie] { ... }                  // internal by default — callable from anywhere in the app
```

This codebase uses `private` constantly for exactly the right reason:
nearly everything is `internal` (the default) or `private` — there's no
`public`/`open` anywhere, because the whole thing is a single app target,
not a library other code links against. Marking a helper `private` (like
`UsageAPI.saveCookieJar` above) is a real signal to a reader: "this exists
only to support the public functions in this same file/type; you'll never
need to call it directly."

## 1.21 Memory management: ARC, `weak`, and `unowned`

### How memory management works (and why it matters)

When a program creates a class instance, memory is allocated for it.
When the instance is no longer needed, that memory should be freed —
otherwise the program slowly "leaks" memory until eventually the OS kills
it.

Swift manages this automatically with **Automatic Reference Counting**
(ARC): the runtime keeps a count of how many "strong references" point at
each class instance. When the count drops to zero, the instance is
immediately deallocated. No garbage collector, no manual `free()` calls —
ARC handles it for you.

But ARC has exactly one sharp edge: a **reference cycle**. If two objects
hold strong references to each other, their counts never reach zero, and
neither is ever freed — even if no other code can reach either of them.
This is a memory leak that ARC cannot solve on its own.

```swift
final class Parent {
    var child: Child?
}
final class Child {
    var parent: Parent?      // if this is a STRONG reference back to Parent...
}
let p = Parent()
let c = Child()
p.child = c
c.parent = p                  // ...now p and c hold strong references to EACH OTHER.
// even if every other reference to p and c goes away, this pair keeps each
// other alive forever — neither one's reference count ever reaches zero.
```

The fix is to mark one side of a cyclical relationship `weak` (an optional
reference that automatically becomes `nil` when the object it points to is
deallocated) or `unowned` (a non-optional reference that assumes the
referenced object will always outlive it, and traps if you're wrong —
used only when you're certain the lifetime relationship makes `nil` an
impossibility, never as a default choice over `weak`):

```swift
final class Child {
    weak var parent: Parent?     // breaks the cycle — Parent can now be deallocated freely
}
```

The exact same problem, and the exact same fix, applies to **closures**
that capture `self` and are themselves stored somewhere `self` can reach —
which is precisely the situation in this app's `anchorFrameProvider`
closure (Part 2 §2.3.5): `AppDelegate` hands `UsageMonitor` a closure that
captures `self` (the `AppDelegate`), and `UsageMonitor` stores that closure
as a property. Without `[weak self]` in the closure's capture list, that
closure would hold `AppDelegate` alive forever, and `AppDelegate` (via the
stored closure) would hold the closure alive forever — a textbook
reference cycle, just one level removed from the toy `Parent`/`Child`
example above. Recognizing "a closure captures self, and is stored
somewhere self can reach (directly or indirectly)" as the pattern that
calls for `[weak self]` is one of the highest-value instincts to build as
a working Swift developer — it's a real, common source of memory leaks in
real apps, not an academic exercise.

> **The mental checklist for `[weak self]`:** Does a closure (1) reference
> `self`, and (2) get stored somewhere `self` can directly or indirectly
> reach? If yes to both, use `[weak self]` and guard at the top. The
> `AppDelegate` → `UsageMonitor` → `anchorFrameProvider` closure in this
> app is a textbook example: the closure captures `AppDelegate` (`self`),
> and is stored in `UsageMonitor`, which `AppDelegate` owns — cycle
> complete without `[weak self]`.

## 1.22 Naming and style conventions

Swift's own API Design Guidelines (which the standard library and every
Apple framework follow, and which this codebase follows throughout) boil
down to a few rules worth internalizing:

- **Types** (`struct`, `class`, `enum`, `protocol`) are `UpperCamelCase`:
  `TurnUsage`, `SeparatorStyle`, `UsageMonitor`.
- **Everything else** — variables, constants, function/method names,
  enum *cases* — is `lowerCamelCase`: `turnCount`, `loadSettings()`,
  `.chevron`.
- **Read call sites as English where it helps.** A well-named Swift API
  reads almost like a sentence at the call site:
  `window.setFrameTopLeftPoint(NSPoint(x: x, y: anchorFrame.maxY))`,
  `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown])`. This is
  why argument labels (§1.8) are a real design decision, not boilerplate.
- **Omit needless words.** Prefer `array.remove(at: 2)` over
  `array.removeElementAtIndex(2)` — the parameter's type and label already
  carry the meaning; don't repeat it in the function name too.
- **Boolean properties and methods read as assertions.** `isLoading`,
  `isConnected`, `hasStarted` — not `loading`, `connected`, `started`. This
  app follows this exactly: `isConnected`, `isFetching`, `hasStarted`,
  `isLoading` all over `App.swift` and the analyzer classes.

### A note on what Part 1 didn't cover

Part 1 covers the language features you'll need to read and understand this
app. There's more Swift beyond this — `async`/`await` concurrency (Swift 5.5+),
property wrappers, result builders (which power SwiftUI's view DSL),
`Sendable` and actors for structured concurrency, macros (Swift 5.9+) —
but none of those appear in this codebase, so they're left for when you
need them. The Swift Evolution site (https://www.swift.org/swift-evolution/)
is the canonical source for what exists and why each feature was added.

---

# Part 2: This App — a guided tour

This part is the original tour: every concept tied to a specific line in
this real, working macOS menu bar app. Open the referenced file alongside
this doc and read them side by side.

## 2.1 What this app actually does

`Usage` is a macOS menu bar app that shows you, as a small live gauge, how
much of your Claude plan you've used — both in the current 5-hour session
and over the rolling 7-day window. Concretely:

- It sits in the menu bar as a small pie-slice icon plus optional text
  (`12%`, or `12% · +1.5% last turn · New session at 4:00 PM`, depending on
  what you've enabled in Settings).
- Click it and a popover drops down showing a big circular gauge, a
  "connect your account" flow, a phone-dashboard QR code, and shortcuts to
  three auxiliary windows: **Settings**, **Turn History**, and **Insights**.
- The real percentages come straight from Anthropic's own (undocumented)
  usage API — the app logs in once via an embedded browser, captures the
  session cookies, and then calls `https://claude.ai/api/organizations/<org>/usage`
  directly with those cookies on every turn and every 60 seconds as a
  safety net.
- Independently, it tails every `~/.claude/projects/**/*.jsonl` Claude Code
  transcript file on your Mac, second by second, to know the instant a new
  "turn" (one assistant reply with a token-usage block) happens — that's
  what triggers the "fetch fresh numbers now" call, and what powers the
  Turn History and Insights windows (which are 100% local statistics, no
  network call involved).
- It also runs a tiny embedded HTTP server on your LAN so you can scan a QR
  code and see the same live gauge on your phone.

None of this needs a database, a build tool, or a single third-party
dependency — `Package.swift` declares zero dependencies, and everything
above is built from Apple's own frameworks (`SwiftUI`, `AppKit`, `WebKit`,
`Network`, `Foundation`, `CoreImage`, `ServiceManagement`, `Combine`).

## 2.2 File structure — what lives where

```
ClaudeUsageMonitor/
├── Package.swift                       Swift Package Manager manifest
├── build_app.sh                        Wraps `swift build` into a real .app bundle
├── icon/generate_icon.swift            One-off script that drew the app's Dock/Finder icon
└── Sources/ClaudeUsageMonitor/
    ├── App.swift          The hub: app state, the menu bar item, the popover UI,
    │                      window positioning helpers, theme colors, token pricing
    ├── UsageAPI.swift      Talks to the real claude.ai usage endpoint using saved cookies
    ├── WebScraping.swift   The one-time login window (a plain WKWebView)
    ├── LocalServer.swift   The phone dashboard's raw TCP/HTTP server + QR code generator
    ├── Settings.swift      Persisted settings model, the pie-icon renderer, Settings window
    ├── TurnHistory.swift   Per-turn timeline window — scans local transcripts
    └── Insights.swift      Per-session analyzer — rule-based usage insights window
```

A few things worth noticing about this structure before you read any code:

- **No `main.swift`.** Swift treats a file literally named `main.swift` as
  *implicit top-level executable code* — every top-level statement in it
  just runs, in order, no `@main` needed. This project instead uses the
  `@main` attribute (see `ClaudeUsageMonitorApp` at the bottom of
  `App.swift`) to mark the entry point explicitly, which is why the file
  with `@main` in it is named `App.swift`, not `main.swift`. The two
  approaches are mutually exclusive — having both is a compile error.
- **One target, one folder.** `Package.swift` declares a single
  `executableTarget` pointed at `Sources/ClaudeUsageMonitor`. There's no
  separate library target, no test target (yet) — everything compiles into
  one binary.
- **Files are split by *feature*, not by *layer*.** `Settings.swift`
  contains its data model (`AppSettings`), its rendering logic (the pie
  icon renderer), *and* its window/view code, all together. This is a
  reasonable pattern for an app this size: you only ever need to open one
  file to understand or change one feature, instead of jumping between a
  `Models/`, `Views/`, and `Controllers/` folder for every change.

## 2.3 Swift language features, in the order you'll meet them

### 2.3.1 `enum` with associated behavior — `Sources/ClaudeUsageMonitor/Settings.swift:7-27`

```swift
enum SeparatorStyle: String, Codable, CaseIterable {
    case chevron, dot, bar, diamond

    var glyph: String {
        switch self {
        case .chevron: return "›"
        ...
        }
    }
}
```

Swift enums aren't just a set of named constants like in C — they can carry
**computed properties** (`glyph`, `label` here) and conform to protocols.
`: String` means each case has a raw string value (`"chevron"` etc.) for
free, which is what makes it `Codable` — you get JSON persistence with zero
extra code. `CaseIterable` auto-generates `SeparatorStyle.allCases`, used in
the Settings UI's segmented picker (`Settings.swift:205`) to build the list
of options without hand-maintaining an array. (See Part 1 §1.11 for the
full picture of what Swift enums can do beyond this one example.)

### 2.3.2 `struct` + `Codable` for free JSON persistence — `Settings.swift:29-56`

```swift
struct AppSettings: Codable {
    var showPercent: Bool = true
    ...
    static let defaultSettings = AppSettings()
}

func loadSettings() -> AppSettings {
    guard let data = try? Data(contentsOf: settingsFileURL),
          let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    else { return .defaultSettings }
    return decoded
}
```

This pattern repeats three times in the app (`AppSettings` here,
`SyncState` in `App.swift:110-120`, `SavedCookie` in `UsageAPI.swift:15-19`)
— it's the idiomatic "tiny local database" in Swift: a plain `struct`
conforming to `Codable`, encoded/decoded straight to a JSON file with
`JSONEncoder`/`JSONDecoder`. No SQLite, no Core Data, no third-party
persistence library needed for settings-sized data.

Notice `try?` instead of `try`/`catch` — it converts a throwing call into
an `Optional` (`nil` on failure instead of propagating the error). Chaining
multiple `try?`s in one `guard let ... , let ... else` is a common Swift
idiom for "attempt several optional steps, bail to a sane default if any
of them fails" — exactly what you want for "load preferences, or fall back
to defaults if the file's missing or corrupt." (See Part 1 §1.16 for `try`
and `catch` in their full, non-optional-discarding form.)

### 2.3.3 Protocol-oriented `Shape` and custom drawing — `Settings.swift:60-81`

```swift
struct PieSlice: Shape {
    var percent: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard percent > 0 else { return path }
        ...
        path.addArc(center: center, radius: radius, startAngle: startAngle,
                    endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}
```

`Shape` is a SwiftUI protocol with exactly one requirement: turn a
`CGRect` into a `Path`. Conform to it and you get a real SwiftUI `View`
for free (`Shape` extends `View`) — you can `.fill()` it, `.stroke()` it,
animate its parameters, etc. This is how the app draws "a pie slice that's
X% of a circle" as a reusable, declarative SwiftUI shape rather than
dropping into manual `Core Graphics` drawing — that manual approach
*does* show up separately, in `renderPieIconImage` (see §2.3.4), because the
two have different jobs. (This is protocol-oriented programming in
action — see Part 1 §1.13 for the general mechanism `Shape` is built on.)

Read the comment right above the angle-sweep line — it explains a subtle
gotcha that's *the* most important thing to internalize about drawing
circles in Apple frameworks: SwiftUI's `View` coordinate space has **y
pointing down**, so "visually clockwise" and "mathematically clockwise"
(`clockwise: true`) are opposite. Compare this to `renderPieIconImage`
below, which draws into an `NSImage` (a **y-up**, "flipped" coordinate
space) — there, `clockwise: true` really is visually clockwise. Same pie
slice, two coordinate systems, two different `clockwise` values to get the
same visual result. This is a real bug class in Apple UI code; the
comments in both places exist because it bit the person who wrote this.

### 2.3.4 `NSImage.lockFocus()` — manual bitmap drawing (AppKit) — `Settings.swift:87-126`

```swift
func renderPieIconImage(percent: Double, diameter: CGFloat = 16, trailingGap: CGFloat = 6) -> NSImage {
    let image = NSImage(size: NSSize(width: canvasWidth, height: diameter))
    image.lockFocus()
    // ... NSBezierPath drawing calls here ...
    image.unlockFocus()
    image.isTemplate = false
    return image
}
```

This is **AppKit**, not SwiftUI — `lockFocus()`/`unlockFocus()` bracket a
block of imperative drawing calls (`NSBezierPath`, `.setStroke()`,
`.setFill()`) into a fixed-size bitmap. Why not just use the `PieSlice`
SwiftUI `Shape` from §2.3.3 here too? The comment directly above the function
explains it: `MenuBarExtra`'s label area collapses unpredictably when you
mix a live SwiftUI `Shape` with `Text` — so the menu bar icon specifically
needs an unambiguous, pre-rendered bitmap with a fixed intrinsic size.
**Same visual result, two different tools, chosen because one tool failed
in one specific host context.** That's a realistic, not theoretical,
reason to reach for AppKit instead of staying in pure SwiftUI.

### 2.3.5 Closures as stored properties — `App.swift:205`, `App.swift:752-761`

```swift
var anchorFrameProvider: (() -> NSRect?)?
```

This declares a property whose *type* is "a function that takes no
arguments and returns an optional `NSRect`" — a closure stored as data,
not called immediately. It's set once, in `AppDelegate`:

```swift
sharedMonitor.anchorFrameProvider = { [weak self] in
    guard let self = self else { return nil }
    if self.popover.isShown, let popoverWindow = self.popover.contentViewController?.view.window {
        return popoverWindow.frame
    }
    if let button = self.statusItem.button, let buttonWindow = button.window {
        return buttonWindow.convertToScreen(button.frame)
    }
    return nil
}
```

This is a real-world case for a common pattern: `UsageMonitor` (in
`App.swift`) needs to know "where is the popover on screen right now?" to
position auxiliary windows beside it, but `UsageMonitor` has no reference
to `AppDelegate`'s `NSStatusItem`/`NSPopover` (and shouldn't — that would
create a dependency in the wrong direction, view-state on app-plumbing).
Instead, `AppDelegate` *hands `UsageMonitor` a closure* that knows how to
answer the question, and `UsageMonitor` just calls it
(`anchorFrameProvider?()` in `openSettings()` etc., `App.swift:336-346`)
without knowing or caring how the answer is computed. This is dependency
injection without a framework — just a stored closure.

`[weak self]` in the closure's capture list is worth understanding on its
own: without it, the closure would hold a *strong* reference to
`AppDelegate`, and since `AppDelegate` holds the closure as a property,
you'd have a **reference cycle** — neither object can ever be deallocated.
`[weak self]` makes the captured `self` an `Optional` that becomes `nil` if
the real object is freed elsewhere, which is why the closure immediately
does `guard let self = self else { return nil }`. (Part 1 §1.21 walks
through the toy two-object version of this same problem, if the closure
version here doesn't click right away.)

### 2.3.6 `final class ... : ObservableObject` + `@Published` — `App.swift:195-217`

```swift
final class UsageMonitor: ObservableObject {
    @Published var lastTurn: TurnUsage?
    @Published var turnCount: Int = 0
    @Published var settings: AppSettings = loadSettings()
    ...
}
```

This is the backbone of how SwiftUI views in this app stay in sync with
real-time state. `ObservableObject` + `@Published` is Combine's (Apple's
reactive framework) integration point with SwiftUI: any view that holds
this object as `@ObservedObject var monitor: UsageMonitor` (see
`ConnectPanel`, `SettingsView`, `MenuContentView`, etc.) automatically
re-renders whenever *any* `@Published` property on it changes — you never
manually call something like `setNeedsDisplay()`. `final` on the class is
a small but meaningful detail: it tells the compiler no subclass will ever
override anything here, which both documents intent and lets the compiler
skip dynamic-dispatch overhead for its methods. (See Part 1 §1.10 for why
this is a `class` and not a `struct` in the first place — it's exactly
the "shared, mutating identity" case described there.)

Contrast this with the comment at `App.swift:711-716`, which explains a
real limitation the author hit: SwiftUI's own `MenuBarExtra` API doesn't
reliably re-render its label when `@Published` properties change — so the
actual menu bar button (`NSStatusItem`) is driven *imperatively* instead
(`button.image = ...`, `button.title = ...` in `AppDelegate.refresh()`,
triggered by manually subscribing to `objectWillChange`). This is a good
lesson in itself: SwiftUI's declarative model is the default, but when a
specific Apple API doesn't hold up its end of the contract, dropping to
imperative AppKit calls driven by your own subscription is a legitimate
fallback — not a sign you're "doing SwiftUI wrong."

### 2.3.7 `Binding` with a generic key path — `Settings.swift:153-161`

```swift
private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { monitor.settings[keyPath: keyPath] },
        set: { newValue in
            monitor.settings[keyPath: keyPath] = newValue
            monitor.persistSettings()
        }
    )
}
```

This is a small piece of generic, reusable plumbing worth slowing down on.
`WritableKeyPath<AppSettings, T>` is a *first-class reference to a
property* — `\.showPercent` is a `WritableKeyPath<AppSettings, Bool>`,
`\.separatorStyle` is a `WritableKeyPath<AppSettings, SeparatorStyle>`, and
so on. Instead of writing six nearly-identical `Binding(get:set:)` blocks
for six toggles/pickers, this one generic function works for *all* of
them — call `binding(\.showPercent)` and get back a `Binding<Bool>` that
reads/writes that one field and calls `persistSettings()` after every
write. `T` is inferred automatically from whichever key path you pass in.
This is the kind of abstraction Swift's type system makes nearly free —
no runtime cost, full type safety, and it deletes real duplication. (Compare
this to the project's own CLAUDE.md guidance to avoid premature
abstraction — this one earns its keep because it's used six times in the
same file, not because it might be useful someday. See Part 1 §1.15 for
generics in general — this function is one of the only real generics
usages in the whole app.)

### 2.3.8 Error handling with custom `NSError` — `UsageAPI.swift:56-103`

```swift
guard !jar.isEmpty else {
    completion(.failure(NSError(domain: "UsageAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "No saved session — connect your account first."])))
    return
}
```

`Result<[String: Any], Error>` plus a completion-handler closure is the
classic pre-`async`/`await` pattern for asynchronous APIs in Swift —
you'll see it throughout `UsageAPI.swift` and `Insights.swift`. Each
distinct failure mode gets its own `code` (1 through 5 here) and a
human-readable `NSLocalizedDescriptionKey` message — when something goes
wrong, the message that eventually reaches `statusMessage` in
`UsageMonitor` (`App.swift:360`) is exactly this string, which is why
errors in this app tend to be specific ("No `lastActiveOrg` cookie saved.
Cookies present: ...") instead of a generic "something went wrong." (Part
1 §1.16 covers `throw`/`try`/`catch` in full — this completion-handler
`Result` style is a different, older mechanism for the same underlying
problem: reporting that something failed and why.)

### 2.3.9 `DispatchQueue` and explicit threading — `Insights.swift:68-79`, `TurnHistory.swift:26-37`

```swift
func refresh(weeklyPercent: Double?) {
    isLoading = true
    DispatchQueue.global(qos: .userInitiated).async {
        let summaries = self.scanAllSessions()
        let generated = Self.generateInsights(sessions: summaries, weeklyPercent: weeklyPercent)
        DispatchQueue.main.async {
            self.sessions = summaries
            self.insights = generated
            self.isLoading = false
        }
    }
}
```

This pattern — *do slow work on a background queue, then hop back to
`.main` to touch `@Published` UI state* — appears identically in both
`InsightsAnalyzer` and `TurnHistoryAnalyzer`, because both classes do the
same kind of work: walk every `.jsonl` file under `~/.claude/projects`,
which can be slow if you have a lot of session history. `@Published`
properties are only safe to mutate on the main thread (SwiftUI's
rendering is tied to it), so the inner `DispatchQueue.main.async` block at
the end is not optional ceremony — skipping it is a real, if often silently
tolerated, threading bug.

### 2.3.10 `NWListener` — a raw TCP server, no frameworks — `LocalServer.swift:11-128`

`LocalUsageServer` is a real (tiny) HTTP/1.1 server built entirely on
Apple's `Network` framework — no Vapor, no third-party socket library.
Worth tracing through once:

- `NWListener` (`LocalServer.swift:22`) opens a TCP listening socket on a
  fixed port.
- Every new connection gets handed to `handle(_:)`, which calls
  `receive(on:buffer:)` — a small **recursive function** that keeps
  appending incoming bytes to a buffer until it finds the `\r\n\r\n` that
  marks the end of an HTTP header block, then dispatches based on the
  request line (`respond(to:on:)`).
- Responses are hand-assembled HTTP: a literal `"HTTP/1.1 \(status)\r\n..."`
  string concatenated with a `Content-Length` computed from the body's
  byte count (`LocalServer.swift:114-121`).

This is a good example of "you don't need a framework to do networking in
Swift" — and also a good example of where *not* to reach for this style in
a real production server: there's no concurrency limit, no timeout
handling beyond `isComplete`, and no HTTP parsing beyond the first line.
It's appropriately scoped for "a read-only, LAN-only, single-user phone
dashboard," which is exactly the comment at the top of the file
(`LocalServer.swift:7-10`) tells you it's for.

### 2.3.11 Low-level C interop for LAN IP — `LocalServer.swift:132-151`

```swift
func getLocalIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        ...
    }
}
```

This function calls straight into BSD/POSIX C APIs (`getifaddrs`,
`getnameinfo`) — the same calls you'd use in C — because there's no
higher-level Apple API for "what's my LAN IP." `UnsafeMutablePointer` is
Swift's typed wrapper around a raw C pointer; `defer { freeifaddrs(ifaddr) }`
guarantees the C-allocated linked list gets freed exactly once, no matter
which `return` inside the function actually executes — this is `defer`
from Part 1 §1.19 doing real work, not a toy example. `sequence(first:
next:)` is a neat Swift standard library trick for turning a C-style
linked list (where each node has a `.pointee.ifa_next` pointer to the
next one) into something you can iterate with a plain `for` loop.

### 2.3.12 `NSApplicationDelegateAdaptor` and the smallest possible `App` — `App.swift:792-801`

```swift
@main
struct ClaudeUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

Every SwiftUI app needs a type conforming to the `App` protocol marked
`@main`, with a `body` that returns at least one `Scene`. This app barely
uses SwiftUI's own app lifecycle at all — `@NSApplicationDelegateAdaptor`
bridges in a classic AppKit `NSApplicationDelegate`
(`applicationDidFinishLaunching`, full AppKit control over the status item
and popover), and the `Scene` is a throwaway `Settings { EmptyView() }`
purely to satisfy the protocol requirement. The comment right above it is
honest about this: "All real UI is driven by AppDelegate's
NSStatusItem/NSPopover — SwiftUI still requires at least one Scene to
exist." This is a useful pattern to recognize: SwiftUI's `App`/`Scene`
machinery is mainly built around document- and window-based apps; a menu
bar utility like this one uses just enough of it to boot, then does
everything else in AppKit.

### 2.3.13 `enum` for a closed two-value choice instead of a `Bool` — `App.swift:155`

```swift
enum WindowSide { case left, right }
```

It would be possible to write `func positionWindow(..., onLeft: Bool)`
instead. The enum is more self-documenting at every call site —
`side: .left` reads unambiguously, whereas `onLeft: true` requires you to
remember which way `true` goes. This is a cheap, idiomatic Swift habit:
reach for a small `enum` instead of a `Bool` whenever the two states have
names that mean something (`.left`/`.right`, not `true`/`false`). It also
means that if this ever needed a third option (a `.center` case — see
Part 2 §2.6's "where to go next"), the compiler's exhaustive-`switch`
requirement (Part 1 §1.5) would force you to update every `switch` over
`WindowSide` — a `Bool` could never have given you that safety net.

### 2.3.14 Multi-line string literals for embedded HTML — `LocalServer.swift:171-261`

```swift
let dashboardHTML = """
<!DOCTYPE html>
<html>
...
</html>
"""
```

Triple-quoted strings (`"""`) let you embed a large, multi-line block of
literal text — here, a whole HTML/CSS/JS page — directly in a Swift source
file with no escaping of quotes or newlines required. This is how the
phone dashboard ships without a separate `.html` asset file or build step:
it's just a Swift `String` constant, served byte-for-byte by
`LocalUsageServer.respond(to:on:)`.

## 2.4 SwiftUI-specific patterns worth knowing

- **`ZStack` + `LinearGradient` + `.ignoresSafeArea()`** is the recurring
  background pattern across every window (`SettingsView`, `InsightsView`,
  `TurnHistoryView`, `MenuContentView`) — a gradient sits behind the
  content in a `ZStack`, ignoring the safe area so it fills the whole
  window edge-to-edge rather than stopping at the title bar inset.
- **`@ObservedObject` vs. owning the object.** Every auxiliary view takes
  its model as `@ObservedObject var monitor: UsageMonitor` (or `analyzer:`)
  — meaning the view *observes* an object it doesn't own and didn't
  create. The object's actual lifetime is owned by `UsageMonitor` itself
  (`insightsAnalyzer`, `turnHistoryAnalyzer` as `let` properties,
  `App.swift:213-216`) or by `sharedMonitor` (`App.swift:709`), a single
  global instance shared for the app's whole lifetime — a deliberate
  choice given there's exactly one menu bar item and exactly one set of
  app-wide state.
- **`.fixedSize(horizontal: false, vertical: true)`** (e.g.
  `TurnHistory.swift:119`, `Insights.swift:253`) — tells a multi-line
  `Text` to take exactly the height its content needs rather than
  truncating or wrapping unpredictably inside a fixed-size parent. Worth
  remembering any time body text inside a `VStack` looks clipped.
- **`GeometryReader` for proportional widths** — `TurnHistoryRow`
  (`TurnHistory.swift:153-157`) uses `GeometryReader` to read the
  available width of its parent and draw a background rectangle scaled to
  `share` (a 0–1 fraction) — a simple, dependency-free progress-bar effect.

## 2.5 AppKit-specific patterns worth knowing

- **`NSPopover` with `.semitransient`** (`App.swift:741-750`) — the main
  dropdown isn't a window, it's a popover anchored to the status item.
  `.semitransient` behavior (vs. `.transient`) is what allows the
  Settings/Insights/Turn History windows to open *without* the main
  popover snapping shut the instant they take focus.
- **A global event monitor for click-away dismissal**
  (`App.swift`, `outsideClickMonitor` in `AppDelegate`) —
  `NSEvent.addGlobalMonitorForEvents` only fires for clicks *outside your
  own app's windows*, which is exactly the tool needed to close the
  popover on an outside click while leaving clicks on your own auxiliary
  windows alone.
- **`NSHostingController`** — the bridge that lets a SwiftUI `View` be
  hosted inside a plain AppKit `NSWindow`. Every auxiliary window
  controller (`SettingsWindowController`, `InsightsWindowController`,
  `TurnHistoryWindowController`) follows the same shape: build a SwiftUI
  view, wrap it in `NSHostingController(rootView:)`, hand that to
  `NSWindow(contentViewController:)`.
- **Window leveling and positioning** — `positionWindow(_:relativeTo:side:)`
  (`App.swift:161-193`) is a good worked example of real AppKit screen-space
  math: computing an x-coordinate relative to an anchor frame, clamping it
  to the screen's visible frame so it can never run off-screen, and setting
  `window.level = .floating` so it renders above the popover's own
  popover-level window layer instead of getting visually buried under it.

## 2.6 A few real bugs fixed in this codebase, and what they teach

Reading old bugs (and their fixes) in a real project is often more
instructive than reading correct code, because it shows you the kind of
mistake the language/framework actually invites.

1. **Window width read before layout.** `positionWindow` computes
   `x = anchorFrame.minX - window.frame.width - gap` for the `.left` side.
   But `window.frame.width`, read immediately after
   `NSWindow(contentViewController:)`, can still reflect a stale/default
   size — SwiftUI's `.frame(width:height:)` modifier on the root view
   doesn't necessarily take effect synchronously. The `.right` side
   (`x = anchorFrame.maxX + gap`) never used `width` at all, so it
   "accidentally" worked while `.left` silently didn't. The fix:
   `window.setContentSize(hosting.view.fittingSize)` before measuring or
   positioning, forcing AppKit to settle on the real size first. Lesson:
   **a bug that only shows up on one of two structurally identical code
   paths is often hiding an implicit dependency** — here, a dependency on
   timing/layout-completion that one path's math happened not to need.
2. **Coordinate-space sign flips.** Covered in §2.3.3 — the same
   "clockwise" boolean means visually opposite things in SwiftUI's `Path`
   (y-down) versus AppKit's `NSBezierPath` inside `lockFocus()` (y-up,
   unflipped). Any time you port the same drawing logic between SwiftUI
   and AppKit, re-derive the angle math instead of assuming it transfers.
3. **A framework component's reactivity contract not holding.** Covered in
   §2.3.6 — `MenuBarExtra`'s label not reliably updating from `@Published`
   state. Lesson: declarative bindings are *usually* reliable, but verify
   it for the specific component you're using before building an entire
   feature on the assumption.

## 2.7 Where to go next

- Open `Sources/ClaudeUsageMonitor/App.swift` top to bottom once, slowly —
  it's the largest file and ties every other file together.
- Try adding a fourth `SeparatorStyle` case and watch the Settings UI pick
  it up automatically (because of `CaseIterable` — §2.3.1) with no other
  code changes.
- Try changing `WindowSide` to add a `.center` case and wiring it through
  `positionWindow` — a small, contained way to practice extending an
  `enum` and a `switch` statement that's required to be exhaustive (Swift
  won't compile a `switch` over an enum that's missing a case, which is
  itself worth experiencing once — see Part 1 §1.5).
- Once Part 1 and Part 2 both make sense, try writing one small new
  feature end-to-end yourself — a fourth auxiliary window, say, or a new
  rule in `InsightsAnalyzer.generateInsights` — and notice which Part 1
  concepts you reach for without having to look them up again.
