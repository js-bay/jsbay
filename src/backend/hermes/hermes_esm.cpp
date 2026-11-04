// Hermes spike ESM ModuleLoader — host-side transform (Hermes pin disables native CJS/ESM codegen).
// Transforms a subset of import/export into a CommonJS-like wrapper evaluated via JSI.
#include "hermes_bridge.h"

#include <hermes/hermes.h>
#include <jsi/jsi.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace jsi = facebook::jsi;
using FbHermesRuntime = facebook::hermes::HermesRuntime;


struct HermesModuleRecord {
    jsi::Object exports;
    bool loading = false;
    bool ready = false;
    bool failed = false;
    std::string fail_message;
};

struct HermesModLoader {
    void *ud = nullptr;
    HermesModResolveFn resolve = nullptr;
    HermesModLoadFn load = nullptr;
    HermesModFreeResolvedFn free_resolved = nullptr;
    std::unordered_map<std::string, std::shared_ptr<HermesModuleRecord>> cache;
    std::string current_referrer;
};

// We store loader on context via a side map keyed by context pointer (avoid reshaping opaque).
static std::mutex g_mod_mu;
static std::unordered_map<JsbayHermesContext *, std::unique_ptr<HermesModLoader>> g_mod_loaders;

static char *dupCStringLocal(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = 0;
    return out;
}

static void hermesEvalSetErrLocal(HermesEvalResult &out, const std::string &s) {
    out.err = dupCStringLocal(s);
    out.err_len = out.err ? s.size() : 0;
}

static bool isIdentStart(char c) {
    return std::isalpha(static_cast<unsigned char>(c)) || c == '_' || c == '$';
}
static bool isIdent(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '$';
}

static bool canStartRegexLiteral(const std::string &preceding);
static void blankRegexLiteral(std::string &out, size_t &i);

// Same length as src, with string/template/comment/regexp interiors blanked to spaces so export/import regexes cannot match text that is not executable source.
static std::string blankNonCode(const std::string &src) {
    std::string out = src;
    size_t i = 0;
    while (i < out.size()) {
        char c = out[i];
        if (c == '/' && i + 1 < out.size() && out[i + 1] == '/') {
            i += 2;
            while (i < out.size() && out[i] != '\n') { out[i] = ' '; ++i; }
            continue;
        }
        if (c == '/' && i + 1 < out.size() && out[i + 1] == '*') {
            out[i] = out[i + 1] = ' ';
            i += 2;
            while (i + 1 < out.size() && !(out[i] == '*' && out[i + 1] == '/')) { out[i] = ' '; ++i; }
            if (i < out.size()) out[i++] = ' ';
            if (i < out.size()) out[i++] = ' ';
            continue;
        }
        if (c == '/' && canStartRegexLiteral(out.substr(0, i))) {
            blankRegexLiteral(out, i);
            continue;
        }
        if (c == '\'' || c == '"' || c == '`') {
            char q = c;
            ++i;
            while (i < out.size()) {
                if (out[i] == '\\' && i + 1 < out.size()) { out[i] = out[i + 1] = ' '; i += 2; continue; }
                if (out[i] == q) { ++i; break; }
                out[i] = ' ';
                ++i;
            }
            continue;
        }
        ++i;
    }
    return out;
}


// True when `/` after `preceding` can start a RegExp literal (vs division).
// Practical heuristic: regex-ok after operators / expression-intro keywords / punctuators and at start-of-input; division after identifiers, numbers, `)`, `]`, string/template closes.
static bool canStartRegexLiteral(const std::string &preceding) {
    size_t pk = preceding.size();
    while (pk > 0 && std::isspace(static_cast<unsigned char>(preceding[pk - 1]))) --pk;
    if (pk == 0) return true;

    // Postfix ++ / -- → division (i++/x/, i--/x/).
    if (pk >= 2 &&
        ((preceding[pk - 1] == '+' && preceding[pk - 2] == '+') ||
         (preceding[pk - 1] == '-' && preceding[pk - 2] == '-'))) {
        size_t before = pk - 2;
        while (before > 0 && std::isspace(static_cast<unsigned char>(preceding[before - 1]))) --before;
        if (before > 0) {
            char b = preceding[before - 1];
            if (std::isalnum(static_cast<unsigned char>(b)) || b == '_' || b == '$' || b == ')' ||
                b == ']' || b == '"' || b == '\'' || b == '`')
                return false;
        }
    }

    char prev = preceding[pk - 1];
    if (prev == ']' || prev == '"' || prev == '\'' || prev == '`') return false;
    if (prev == ')') {
        // Closing a call/group is division, but `if (…)` / `while (…)` / `for (…)` / `with (…)` / `switch (…)` leave the grammar where `/…/` can start a RegExp literal.
        int depth = 0;
        size_t j = pk;
        while (j > 0) {
            char ch = preceding[j - 1];
            if (ch == ')') {
                ++depth;
                --j;
                continue;
            }
            if (ch == '(') {
                --depth;
                --j;
                if (depth == 0) {
                    while (j > 0 && std::isspace(static_cast<unsigned char>(preceding[j - 1]))) --j;
                    size_t end = j;
                    while (j > 0) {
                        char w = preceding[j - 1];
                        if (!(std::isalnum(static_cast<unsigned char>(w)) || w == '_' || w == '$')) break;
                        --j;
                    }
                    std::string word = preceding.substr(j, end - j);
                    if (word == "if" || word == "while" || word == "for" || word == "with" ||
                        word == "switch")
                        return true;
                    return false;
                }
                continue;
            }
            --j;
        }
        return false;
    }

    // Identifier / keyword / number token.
    if (std::isalnum(static_cast<unsigned char>(prev)) || prev == '_' || prev == '$') {
        size_t start = pk;
        while (start > 0) {
            char ch = preceding[start - 1];
            if (std::isalnum(static_cast<unsigned char>(ch)) || ch == '_' || ch == '$')
                --start;
            else
                break;
        }
        std::string word = preceding.substr(start, pk - start);
        static const char *kws[] = {"return", "typeof", "instanceof", "in", "void", "new",
                                    "delete", "throw", "case", "else", "do", "await", "yield"};
        for (const char *kw : kws) {
            if (word == kw) return true;
        }
        return false; // identifier or numeric literal → division
    }

    // Expression-introducing punctuators / operators (incl. + - for infix/prefix).
    if (std::strchr("([{,;=!?:~&|^*%<>+-", prev) != nullptr) return true;
    return false;
}

// Copy `/pattern/flags` verbatim from src[i] (i at opening `/`). Handles `\` escapes and character classes so `/` inside `[...]` does not terminate the literal.
static void copyRegexLiteral(const std::string &src, size_t &i, std::string &out) {
    out.push_back(src[i++]); // opening /
    bool in_class = false;
    while (i < src.size()) {
        char ch = src[i];
        if (ch == '\\' && i + 1 < src.size()) {
            out.push_back(src[i++]);
            out.push_back(src[i++]);
            continue;
        }
        if (ch == '[' && !in_class) {
            in_class = true;
            out.push_back(src[i++]);
            continue;
        }
        if (ch == ']' && in_class) {
            in_class = false;
            out.push_back(src[i++]);
            continue;
        }
        if (ch == '/' && !in_class) {
            out.push_back(src[i++]); // closing /
            while (i < src.size() && std::isalpha(static_cast<unsigned char>(src[i])))
                out.push_back(src[i++]);
            return;
        }
        // Unterminated regex (newline) — stop without consuming the newline.
        if (ch == '\n' || ch == '\r') return;
        out.push_back(src[i++]);
    }
}

// Skip a regex literal in-place (no output); used by template `${...}` brace scanner.
static void skipRegexLiteral(const std::string &src, size_t &i) {
    ++i; // opening /
    bool in_class = false;
    while (i < src.size()) {
        char ch = src[i];
        if (ch == '\\' && i + 1 < src.size()) {
            i += 2;
            continue;
        }
        if (ch == '[' && !in_class) {
            in_class = true;
            ++i;
            continue;
        }
        if (ch == ']' && in_class) {
            in_class = false;
            ++i;
            continue;
        }
        if (ch == '/' && !in_class) {
            ++i; // closing /
            while (i < src.size() && std::isalpha(static_cast<unsigned char>(src[i]))) ++i;
            return;
        }
        if (ch == '\n' || ch == '\r') return;
        ++i;
    }
}

// Blank `/pattern/flags` interiors in-place (keep delimiters/flags length); used by blankNonCode.
static void blankRegexLiteral(std::string &out, size_t &i) {
    ++i; // keep opening /
    bool in_class = false;
    while (i < out.size()) {
        char ch = out[i];
        if (ch == '\\' && i + 1 < out.size()) {
            out[i] = out[i + 1] = ' ';
            i += 2;
            continue;
        }
        if (ch == '[' && !in_class) {
            in_class = true;
            out[i++] = ' ';
            continue;
        }
        if (ch == ']' && in_class) {
            in_class = false;
            out[i++] = ' ';
            continue;
        }
        if (ch == '/' && !in_class) {
            ++i; // keep closing /
            while (i < out.size() && std::isalpha(static_cast<unsigned char>(out[i]))) ++i;
            return;
        }
        if (ch == '\n' || ch == '\r') return;
        out[i++] = ' ';
    }
}

static void collectPatternBoundNames(const std::string &src, size_t &i, std::vector<std::string> &names);
static std::vector<std::string> collectDeclaratorBoundNames(const std::string &src, size_t start);
static std::vector<std::string> collectParamListBoundNames(const std::string &src, size_t open_paren);

// Skip strings/comments/regex roughly; return rewritten source with identifier replacements.
// Template literal text is preserved, but `${...}` interpolations are rewritten recursively.
// Regex literals are copied verbatim so identifiers inside the pattern/flags are not rewritten.
static std::string rewriteIdents(const std::string &src,
                                 const std::unordered_map<std::string, std::string> &repl,
                                 std::vector<std::unordered_set<std::string>> scopes) {
    if (repl.empty()) return src;
    std::string out;
    out.reserve(src.size() + 32);

    // Lexical scopes of local bindings that shadow import rewrites.
    if (scopes.empty()) scopes.emplace_back();
    auto isShadowed = [&](const std::string &id) -> bool {
        for (auto it = scopes.rbegin(); it != scopes.rend(); ++it) {
            if (it->count(id)) return true;
        }
        return false;
    };
    auto addBindings = [&](const std::vector<std::string> &names) {
        if (scopes.empty()) return;
        for (const auto &n : names) {
            if (!n.empty()) scopes.back().insert(n);
        }
    };
    // Indices of scopes that act as function (or module) environments for `var` hoisting.
    std::vector<size_t> fn_scope_stack;
    fn_scope_stack.push_back(0); // module / script scope
    auto addVarBindings = [&](const std::vector<std::string> &names) {
        size_t idx = fn_scope_stack.empty() ? 0 : fn_scope_stack.back();
        if (idx >= scopes.size()) idx = scopes.empty() ? 0 : scopes.size() - 1;
        if (scopes.empty()) return;
        for (const auto &n : names) {
            if (!n.empty()) scopes[idx].insert(n);
        }
    };
    auto pushScope = [&]() { scopes.emplace_back(); };
    auto popScope = [&]() {
        if (scopes.size() > 1) scopes.pop_back();
        while (!fn_scope_stack.empty() && fn_scope_stack.back() >= scopes.size()) fn_scope_stack.pop_back();
        if (fn_scope_stack.empty()) fn_scope_stack.push_back(0);
    };
    auto pushFunctionScope = [&]() {
        pushScope();
        fn_scope_stack.push_back(scopes.size() - 1);
    };
    // Scan a matched `{...}` body (or top-level range) for `var` bindings, skipping nested function environments (function/class, arrow bodies, and object/class methods) so their vars stay local to those scopes.
    auto collectVarBindingsInRange = [&](size_t from, size_t to, std::unordered_set<std::string> &into) {
        size_t i = from;
        auto skipLineComment = [&]() {
            i += 2;
            while (i < src.size() && src[i] != '\n') ++i;
        };
        auto skipBlockComment = [&]() {
            i += 2;
            while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            if (i + 1 < src.size()) i += 2;
        };
        auto skipQuoted = [&](char q) {
            ++i;
            while (i < src.size()) {
                if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                if (src[i] == q) { ++i; break; }
                ++i;
            }
        };
        auto skipTemplate = [&]() {
            ++i;
            while (i < src.size()) {
                if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                if (src[i] == '`') { ++i; break; }
                if (src[i] == '$' && i + 1 < src.size() && src[i + 1] == '{') {
                    i += 2;
                    int d = 1;
                    while (i < src.size() && d > 0) {
                        if (src[i] == '{') ++d;
                        else if (src[i] == '}') --d;
                        ++i;
                    }
                    continue;
                }
                ++i;
            }
        };
        auto skipBalanced = [&](char open_ch, char close_ch) {
            int d = 0;
            while (i < src.size()) {
                char ch = src[i];
                if (ch == '/' && i + 1 < src.size() && src[i + 1] == '/') { skipLineComment(); continue; }
                if (ch == '/' && i + 1 < src.size() && src[i + 1] == '*') { skipBlockComment(); continue; }
                if (ch == '\'' || ch == '"') { char q = ch; skipQuoted(q); continue; }
                if (ch == '`') { skipTemplate(); continue; }
                if (ch == open_ch) { ++d; ++i; continue; }
                if (ch == close_ch) {
                    --d;
                    ++i;
                    if (d == 0) return;
                    continue;
                }
                ++i;
            }
        };
        auto skipWs = [&]() {
            while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        };
        auto skipNestedFunctionOrClass = [&](const std::string &kw) {
            skipWs();
            if (kw == "function" && i < src.size() && src[i] == '*') {
                ++i;
                skipWs();
            }
            if (i < src.size() && isIdentStart(src[i])) {
                while (i < src.size() && isIdent(src[i])) ++i;
                skipWs();
            }
            if (i < src.size() && src[i] == '(') skipBalanced('(', ')');
            skipWs();
            if (i < src.size() && src[i] == '{') skipBalanced('{', '}');
        };
        // After a name (or get/set/async name), skip `(params) { body }` so object/class method vars stay nested.
        auto skipMethodLikeIfPresent = [&]() -> bool {
            skipWs();
            if (i >= src.size() || src[i] != '(') return false;
            skipBalanced('(', ')');
            skipWs();
            if (i < src.size() && src[i] == '{') {
                skipBalanced('{', '}');
                return true;
            }
            return false;
        };
        while (i < to && i < src.size()) {
            char c = src[i];
            if (c == '/' && i + 1 < src.size() && src[i + 1] == '/') { skipLineComment(); continue; }
            if (c == '/' && i + 1 < src.size() && src[i + 1] == '*') { skipBlockComment(); continue; }
            if (c == '\'' || c == '"') { skipQuoted(c); continue; }
            if (c == '`') { skipTemplate(); continue; }
            // Arrow body `{...}` is its own function environment — do not harvest its `var` into the enclosing function.
            if (c == '=' && i + 1 < src.size() && src[i + 1] == '>') {
                i += 2;
                skipWs();
                if (i < src.size() && src[i] == '{') skipBalanced('{', '}');
                continue;
            }
            // Generator method `*name(){...}` inside object/class literals.
            if (c == '*' && (i == from || !isIdent(src[i - 1]))) {
                size_t save = i;
                ++i;
                skipWs();
                if (i < src.size() && isIdentStart(src[i])) {
                    while (i < src.size() && isIdent(src[i])) ++i;
                    if (skipMethodLikeIfPresent()) continue;
                }
                i = save + 1;
                continue;
            }
            if (isIdentStart(c) && (i == from || !isIdent(src[i - 1]))) {
                size_t j = i + 1;
                while (j < src.size() && isIdent(src[j])) ++j;
                std::string id = src.substr(i, j - i);
                if (id == "function" || id == "class") {
                    i = j;
                    // Nested function/class bodies are skipped here; declaration names for the enclosing scope are registered by collectLexicalBindingsInRange (which also skips nested blocks).
                    skipNestedFunctionOrClass(id);
                    continue;
                }
                if (id == "var") {
                    auto names = collectDeclaratorBoundNames(src, j);
                    for (const auto &n : names) if (!n.empty()) into.insert(n);
                    i = j;
                    continue;
                }
                // Control-flow `(...){...}` keeps `var` in the enclosing function — do not skip those bodies.
                if (id == "if" || id == "while" || id == "for" || id == "switch" || id == "catch" || id == "with") {
                    i = j;
                    continue;
                }
                i = j;
                // `get`/`set`/`async` method: skip optional name then `(params){body}`.
                if (id == "get" || id == "set" || id == "async") {
                    skipWs();
                    if (i < src.size() && src[i] == '*') {
                        ++i;
                        skipWs();
                    }
                    if (i < src.size() && isIdentStart(src[i])) {
                        while (i < src.size() && isIdent(src[i])) ++i;
                    }
                    if (skipMethodLikeIfPresent()) continue;
                    continue;
                }
                // Ordinary object/class method `name(params){body}` — nested function environment.
                if (skipMethodLikeIfPresent()) continue;
                continue;
            }
            ++i;
        }
    };

    // Scan a matched `{...}` body (or top-level range) for `let`/`const` bindings in this lexical scope only.
    // Nested `{...}` blocks are skipped so their bindings stay in the child scope. Loop-header `let`/`const` (`for` / `for await`) are skipped here too — they get their own scope during rewrite rather than shadowing the enclosing function or block.
    // Registering before rewriting lets references that textually precede the declarator resolve to the local binding (TDZ / closure capture), matching native ESM.
    auto collectLexicalBindingsInRange = [&](size_t from, size_t to, std::unordered_set<std::string> &into) {
        size_t i = from;
        auto skipLineComment = [&]() {
            i += 2;
            while (i < src.size() && src[i] != '\n') ++i;
        };
        auto skipBlockComment = [&]() {
            i += 2;
            while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            if (i + 1 < src.size()) i += 2;
        };
        auto skipQuoted = [&](char q) {
            ++i;
            while (i < src.size()) {
                if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                if (src[i] == q) { ++i; break; }
                ++i;
            }
        };
        auto skipTemplate = [&]() {
            ++i;
            while (i < src.size()) {
                if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                if (src[i] == '`') { ++i; break; }
                if (src[i] == '$' && i + 1 < src.size() && src[i + 1] == '{') {
                    i += 2;
                    int d = 1;
                    while (i < src.size() && d > 0) {
                        if (src[i] == '{') ++d;
                        else if (src[i] == '}') --d;
                        ++i;
                    }
                    continue;
                }
                ++i;
            }
        };
        auto skipBalanced = [&](char open_ch, char close_ch) {
            int d = 0;
            while (i < src.size()) {
                char ch = src[i];
                if (ch == '/' && i + 1 < src.size() && src[i + 1] == '/') { skipLineComment(); continue; }
                if (ch == '/' && i + 1 < src.size() && src[i + 1] == '*') { skipBlockComment(); continue; }
                if (ch == '\'' || ch == '"') { char q = ch; skipQuoted(q); continue; }
                if (ch == '`') { skipTemplate(); continue; }
                if (ch == open_ch) { ++d; ++i; continue; }
                if (ch == close_ch) {
                    --d;
                    ++i;
                    if (d == 0) return;
                    continue;
                }
                ++i;
            }
        };
        auto skipNestedFunctionOrClass = [&](const std::string &kw) {
            while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            if (kw == "function" && i < src.size() && src[i] == '*') {
                ++i;
                while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            }
            if (i < src.size() && isIdentStart(src[i])) {
                while (i < src.size() && isIdent(src[i])) ++i;
                while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            }
            if (i < src.size() && src[i] == '(') skipBalanced('(', ')');
            while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            if (i < src.size() && src[i] == '{') skipBalanced('{', '}');
        };
        while (i < to && i < src.size()) {
            char c = src[i];
            if (c == '/' && i + 1 < src.size() && src[i + 1] == '/') { skipLineComment(); continue; }
            if (c == '/' && i + 1 < src.size() && src[i + 1] == '*') { skipBlockComment(); continue; }
            if (c == '\'' || c == '"') { skipQuoted(c); continue; }
            if (c == '`') { skipTemplate(); continue; }
            // Nested block: its let/const belong to the child scope, not this one.
            if (c == '{') { skipBalanced('{', '}'); continue; }
            if (isIdentStart(c) && (i == from || !isIdent(src[i - 1]))) {
                size_t j = i + 1;
                while (j < src.size() && isIdent(src[j])) ++j;
                std::string id = src.substr(i, j - i);
                if (id == "function" || id == "class") {
                    i = j;
                    // Register the declaration name for this enclosing scope before skipping nested params/body, so references that textually precede the declarator bind locally (TDZ / import shadowing), matching native ESM.
                    size_t name_pos = i;
                    while (name_pos < src.size() && std::isspace(static_cast<unsigned char>(src[name_pos]))) ++name_pos;
                    if (id == "function" && name_pos < src.size() && src[name_pos] == '*') {
                        ++name_pos;
                        while (name_pos < src.size() && std::isspace(static_cast<unsigned char>(src[name_pos]))) ++name_pos;
                    }
                    if (name_pos < src.size() && isIdentStart(src[name_pos])) {
                        size_t n = name_pos + 1;
                        while (n < src.size() && isIdent(src[n])) ++n;
                        into.insert(src.substr(name_pos, n - name_pos));
                    }
                    skipNestedFunctionOrClass(id);
                    continue;
                }
                // `for (let|const …)` / `for await (let|const …)` bindings belong to the loop scope, not this range.
                if (id == "for") {
                    i = j;
                    while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
                    if (i + 5 <= src.size() && src.compare(i, 5, "await") == 0 &&
                        (i + 5 == src.size() || !isIdent(src[i + 5]))) {
                        i += 5;
                        while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
                    }
                    if (i < src.size() && src[i] == '(') skipBalanced('(', ')');
                    continue;
                }
                if (id == "let" || id == "const") {
                    auto names = collectDeclaratorBoundNames(src, j);
                    for (const auto &n : names) if (!n.empty()) into.insert(n);
                    i = j;
                    continue;
                }
                i = j;
                continue;
            }
            ++i;
        }
    };

    // Match end of `{...}` starting at open_idx (`{`), returning exclusive end index of the interior (before `}`), or src.size().
    auto balancedBlockInterior = [&](size_t open_idx) -> std::pair<size_t, size_t> {
        size_t body_start = open_idx + 1;
        int depth = 1;
        size_t p = body_start;
        while (p < src.size() && depth > 0) {
            char ch = src[p];
            if (ch == '/' && p + 1 < src.size() && src[p + 1] == '/') {
                p += 2; while (p < src.size() && src[p] != '\n') ++p; continue;
            }
            if (ch == '/' && p + 1 < src.size() && src[p + 1] == '*') {
                p += 2; while (p + 1 < src.size() && !(src[p] == '*' && src[p + 1] == '/')) ++p;
                if (p + 1 < src.size()) p += 2; continue;
            }
            if (ch == '\'' || ch == '"') {
                char q = ch; ++p;
                while (p < src.size()) {
                    if (src[p] == '\\' && p + 1 < src.size()) { p += 2; continue; }
                    if (src[p] == q) { ++p; break; }
                    ++p;
                }
                continue;
            }
            if (ch == '`') {
                ++p;
                while (p < src.size()) {
                    if (src[p] == '\\' && p + 1 < src.size()) { p += 2; continue; }
                    if (src[p] == '`') { ++p; break; }
                    if (src[p] == '$' && p + 1 < src.size() && src[p + 1] == '{') {
                        p += 2; int d = 1;
                        while (p < src.size() && d > 0) {
                            if (src[p] == '{') ++d;
                            else if (src[p] == '}') --d;
                            ++p;
                        }
                        continue;
                    }
                    ++p;
                }
                continue;
            }
            if (ch == '{') { ++depth; ++p; continue; }
            if (ch == '}') { --depth; ++p; continue; }
            ++p;
        }
        size_t body_end = (depth == 0) ? (p - 1) : src.size();
        return {body_start, body_end};
    };

    // Container stack: ObjectLit vs Block vs ClassBody vs Bracket vs Paren/ParamList.
    enum class Cont : uint8_t { ObjectLit, Block, ClassBody, Bracket, Paren, ParamList, FnBody, ForHead };
    std::vector<Cont> cont;
    // When a ParamList `)` is followed by `{`, the next `{` is FnBody and pops the param scope on `}`.
    bool next_brace_is_fn_body = false;
    // `class` / `class Name` / `class … extends …` schedules the next non-object-literal `{` as ClassBody (nested classes nest the counter).
    int class_body_braces_pending = 0;
    // After `for (let|const …)` / `for await (…)`, pop the loop-header scope when its body ends: entries are `cont.size()` after the ForHead `)` — matched when a Block at that depth closes, or a `;` ends a non-braced body.
    std::vector<size_t> for_scope_pop_at_block_depth;
    std::vector<size_t> for_scope_pop_at_stmt_depth;
    // True while scanning a parameter default initializer (`=` … until `,`/`)` at ParamList depth).
    bool in_param_default = false;
    // Expression-bodied arrows (`=> expr` without `{`): cont.size() when the body began. Pop the param scope when the expression ends at that container depth (`,` / `;`) or when an outer container closes (cont shrinks below the marker).
    std::vector<size_t> expr_arrow_cont_depth;
    auto closeExprArrowsDeeperThan = [&](size_t depth) {
        while (!expr_arrow_cont_depth.empty() && expr_arrow_cont_depth.back() > depth) {
            expr_arrow_cont_depth.pop_back();
            popScope();
        }
    };
    auto closeExprArrowsAt = [&](size_t depth) {
        while (!expr_arrow_cont_depth.empty() && expr_arrow_cont_depth.back() == depth) {
            expr_arrow_cont_depth.pop_back();
            popScope();
        }
    };

    auto prevSignificant = [&]() -> char {
        size_t pk = out.size();
        while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
        return pk > 0 ? out[pk - 1] : '\0';
    };
    auto outEndsWithWord = [&](size_t end, const char *w) -> bool {
        size_t n = std::strlen(w);
        if (end < n) return false;
        if (out.compare(end - n, n, w) != 0) return false;
        if (end > n && isIdent(out[end - n - 1])) return false;
        return true;
    };
    auto prevIsObjectLitIntro = [&]() -> bool {
        char p = prevSignificant();
        if (p == '=' || p == ':' || p == ',' || p == '(' || p == '[' || p == '!' ||
            p == '?' || p == '&' || p == '|' || p == '+' || p == '-' || p == '*' ||
            p == '/' || p == '%' || p == '~' || p == '^' || p == '<' || p == '>' ||
            p == '\0')
            return true;
        size_t pk = out.size();
        while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
        return outEndsWithWord(pk, "return") || outEndsWithWord(pk, "throw") ||
               outEndsWithWord(pk, "else") || outEndsWithWord(pk, "=>") ||
               outEndsWithWord(pk, "of") || outEndsWithWord(pk, "in") ||
               outEndsWithWord(pk, "case") || outEndsWithWord(pk, "void") ||
               outEndsWithWord(pk, "typeof") || outEndsWithWord(pk, "delete") ||
               outEndsWithWord(pk, "new") || outEndsWithWord(pk, "default");
    };
    auto underParamList = [&]() -> bool {
        for (auto it = cont.rbegin(); it != cont.rend(); ++it) {
            if (*it == Cont::ParamList) return true;
            if (*it == Cont::FnBody || *it == Cont::Block || *it == Cont::ClassBody) return false;
        }
        return false;
    };
    auto skipSpacesSrc = [&](size_t &p) {
        while (p < src.size() && std::isspace(static_cast<unsigned char>(src[p]))) ++p;
    };

    size_t i = 0;

    // Copy a balanced template literal starting at i (`), rewriting interpolations.
    auto copyTemplate = [&]() {
        out.push_back(src[i++]);
        while (i < src.size()) {
            if (src[i] == '\\' && i + 1 < src.size()) {
                out.push_back(src[i++]);
                out.push_back(src[i++]);
                continue;
            }
            if (src[i] == '`') {
                out.push_back(src[i++]);
                return;
            }
            if (src[i] == '$' && i + 1 < src.size() && src[i + 1] == '{') {
                out.push_back(src[i++]);
                out.push_back(src[i++]);
                size_t start = i;
                int depth = 1;
                while (i < src.size() && depth > 0) {
                    char ic = src[i];
                    if (ic == '/' && i + 1 < src.size() && src[i + 1] == '/') {
                        i += 2;
                        while (i < src.size() && src[i] != '\n') ++i;
                        continue;
                    }
                    if (ic == '/' && i + 1 < src.size() && src[i + 1] == '*') {
                        i += 2;
                        while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
                        if (i + 1 < src.size()) i += 2;
                        continue;
                    }
                    if (ic == '/' && canStartRegexLiteral(src.substr(start, i - start))) {
                        skipRegexLiteral(src, i);
                        continue;
                    }
                    if (ic == '\'' || ic == '"') {
                        char q = ic;
                        ++i;
                        while (i < src.size()) {
                            if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                            if (src[i] == q) { ++i; break; }
                            ++i;
                        }
                        continue;
                    }
                    if (ic == '`') {
                        ++i;
                        while (i < src.size()) {
                            if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                            if (src[i] == '`') { ++i; break; }
                            if (src[i] == '$' && i + 1 < src.size() && src[i + 1] == '{') {
                                i += 2;
                                int nested = 1;
                                while (i < src.size() && nested > 0) {
                                    if (src[i] == '{') ++nested;
                                    else if (src[i] == '}') --nested;
                                    ++i;
                                }
                                continue;
                            }
                            ++i;
                        }
                        continue;
                    }
                    if (ic == '{') { ++depth; ++i; continue; }
                    if (ic == '}') {
                        --depth;
                        if (depth == 0) break;
                        ++i;
                        continue;
                    }
                    ++i;
                }
                out += rewriteIdents(src.substr(start, i - start), repl, scopes);
                if (i < src.size() && src[i] == '}') out.push_back(src[i++]);
                continue;
            }
            out.push_back(src[i++]);
        }
    };

    // Module / inherited scopes: register let/const for the whole range before rewriting so early references see local bindings.
    if (!scopes.empty()) collectLexicalBindingsInRange(0, src.size(), scopes.back());

    while (i < src.size()) {
        char c = src[i];
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '/') {
            while (i < src.size() && src[i] != '\n') out.push_back(src[i++]);
            continue;
        }
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '*') {
            out.push_back(src[i++]);
            out.push_back(src[i++]);
            while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) out.push_back(src[i++]);
            if (i < src.size()) out.push_back(src[i++]);
            if (i < src.size()) out.push_back(src[i++]);
            continue;
        }
        if (c == '/' && canStartRegexLiteral(out)) {
            copyRegexLiteral(src, i, out);
            continue;
        }
        if (c == '\'' || c == '"') {
            char q = c;
            out.push_back(src[i++]);
            while (i < src.size()) {
                if (src[i] == '\\' && i + 1 < src.size()) {
                    out.push_back(src[i++]);
                    out.push_back(src[i++]);
                    continue;
                }
                out.push_back(src[i]);
                if (src[i] == q) { ++i; break; }
                ++i;
            }
            continue;
        }
        if (c == '`') {
            copyTemplate();
            continue;
        }

        if (c == '{') {
            Cont kind;
            if (next_brace_is_fn_body) {
                kind = Cont::FnBody;
                next_brace_is_fn_body = false;
                // Param scope already pushed; body shares it (no extra scope).
                // Collect function-scoped `var` bindings now so they shadow imports for the whole body, including references that appear before the declarator.
                if (!scopes.empty()) {
                    size_t body_start = i + 1;
                    int depth = 1;
                    size_t p = body_start;
                    while (p < src.size() && depth > 0) {
                        char ch = src[p];
                        if (ch == '/' && p + 1 < src.size() && src[p + 1] == '/') {
                            p += 2; while (p < src.size() && src[p] != '\n') ++p; continue;
                        }
                        if (ch == '/' && p + 1 < src.size() && src[p + 1] == '*') {
                            p += 2; while (p + 1 < src.size() && !(src[p] == '*' && src[p + 1] == '/')) ++p;
                            if (p + 1 < src.size()) p += 2; continue;
                        }
                        if (ch == '\'' || ch == '"') {
                            char q = ch; ++p;
                            while (p < src.size()) {
                                if (src[p] == '\\' && p + 1 < src.size()) { p += 2; continue; }
                                if (src[p] == q) { ++p; break; }
                                ++p;
                            }
                            continue;
                        }
                        if (ch == '`') {
                            ++p;
                            while (p < src.size()) {
                                if (src[p] == '\\' && p + 1 < src.size()) { p += 2; continue; }
                                if (src[p] == '`') { ++p; break; }
                                if (src[p] == '$' && p + 1 < src.size() && src[p + 1] == '{') {
                                    p += 2; int d = 1;
                                    while (p < src.size() && d > 0) {
                                        if (src[p] == '{') ++d;
                                        else if (src[p] == '}') --d;
                                        ++p;
                                    }
                                    continue;
                                }
                                ++p;
                            }
                            continue;
                        }
                        if (ch == '{') { ++depth; ++p; continue; }
                        if (ch == '}') { --depth; ++p; continue; }
                        ++p;
                    }
                    size_t body_end = (depth == 0) ? (p - 1) : src.size();
                    collectVarBindingsInRange(body_start, body_end, scopes.back());
                    collectLexicalBindingsInRange(body_start, body_end, scopes.back());
                }
            } else if (prevIsObjectLitIntro()) {
                kind = Cont::ObjectLit;
            } else if (class_body_braces_pending > 0) {
                kind = Cont::ClassBody;
                --class_body_braces_pending;
                pushScope();
                // Class fields are not let/const; static blocks / method bodies are nested and collected in their own scopes.
                if (!scopes.empty()) {
                    auto range = balancedBlockInterior(i);
                    collectLexicalBindingsInRange(range.first, range.second, scopes.back());
                }
            } else {
                kind = Cont::Block;
                pushScope();
                // Pre-collect this block's let/const so references before the declarator bind locally.
                if (!scopes.empty()) {
                    auto range = balancedBlockInterior(i);
                    collectLexicalBindingsInRange(range.first, range.second, scopes.back());
                }
            }
            cont.push_back(kind);
            out.push_back(src[i++]);
            continue;
        }
        if (c == '}') {
            if (!cont.empty()) {
                Cont kind = cont.back();
                cont.pop_back();
                if (kind == Cont::Block || kind == Cont::ClassBody) {
                    popScope();
                    // Loop-header scope whose body was this block, or a single-statement body that ended in a braced statement (`if`/`while`/…).
                    if (kind == Cont::Block) {
                        if (!for_scope_pop_at_block_depth.empty() && cont.size() == for_scope_pop_at_block_depth.back()) {
                            for_scope_pop_at_block_depth.pop_back();
                            popScope();
                        } else if (!for_scope_pop_at_stmt_depth.empty() && cont.size() == for_scope_pop_at_stmt_depth.back()) {
                            for_scope_pop_at_stmt_depth.pop_back();
                            popScope();
                        }
                    }
                } else if (kind == Cont::FnBody) {
                    // End of function/catch body — drop the ParamList scope.
                    popScope();
                }
            }
            closeExprArrowsDeeperThan(cont.size());
            out.push_back(src[i++]);
            continue;
        }
        if (c == '[') {
            cont.push_back(Cont::Bracket);
            out.push_back(src[i++]);
            continue;
        }
        if (c == ']') {
            if (!cont.empty() && cont.back() == Cont::Bracket) cont.pop_back();
            closeExprArrowsDeeperThan(cont.size());
            out.push_back(src[i++]);
            continue;
        }
        if (c == '(') {
            Cont kind = Cont::Paren;
            size_t pk = out.size();
            while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
            size_t pk2 = pk;
            if (pk2 > 0 && isIdent(out[pk2 - 1])) {
                while (pk2 > 0 && isIdent(out[pk2 - 1])) --pk2;
                while (pk2 > 0 && std::isspace(static_cast<unsigned char>(out[pk2 - 1]))) --pk2;
            }
            // Parenthesized arrow params establish a ParamList too: look ahead past the matching `)` for `=>` so bindings register before import rewrite.
            auto parenFollowedByArrow = [&](size_t open_idx) -> bool {
                size_t p = open_idx + 1;
                int depth = 1;
                while (p < src.size() && depth > 0) {
                    char ch = src[p];
                    if (ch == '/' && p + 1 < src.size() && src[p + 1] == '/') {
                        p += 2;
                        while (p < src.size() && src[p] != '\n') ++p;
                        continue;
                    }
                    if (ch == '/' && p + 1 < src.size() && src[p + 1] == '*') {
                        p += 2;
                        while (p + 1 < src.size() && !(src[p] == '*' && src[p + 1] == '/')) ++p;
                        if (p + 1 < src.size()) p += 2;
                        continue;
                    }
                    if (ch == '\'' || ch == '"') {
                        char q = ch; ++p;
                        while (p < src.size()) {
                            if (src[p] == '\\' && p + 1 < src.size()) { p += 2; continue; }
                            if (src[p] == q) { ++p; break; }
                            ++p;
                        }
                        continue;
                    }
                    if (ch == '`') {
                        ++p;
                        while (p < src.size()) {
                            if (src[p] == '\\' && p + 1 < src.size()) { p += 2; continue; }
                            if (src[p] == '`') { ++p; break; }
                            if (src[p] == '$' && p + 1 < src.size() && src[p + 1] == '{') {
                                p += 2; int d = 1;
                                while (p < src.size() && d > 0) {
                                    if (src[p] == '{') ++d;
                                    else if (src[p] == '}') --d;
                                    ++p;
                                }
                                continue;
                            }
                            ++p;
                        }
                        continue;
                    }
                    if (ch == '(') { ++depth; ++p; continue; }
                    if (ch == ')') {
                        --depth; ++p;
                        if (depth == 0) break;
                        continue;
                    }
                    ++p;
                }
                if (depth != 0) return false;
                skipSpacesSrc(p);
                return p + 1 < src.size() && src[p] == '=' && src[p + 1] == '>';
            };
            // Object / class method params: `{ m(value) {…} }`, `class { m(value) {…} }`, `{ [k](a){} }`, `{ *g(a){} }`, `{ async m(a){} }`, `{ get x(){} }`, `static m(a){}`.
            auto opensMethodParamList = [&]() -> bool {
                const bool in_obj = !cont.empty() && cont.back() == Cont::ObjectLit;
                const bool in_class = !cont.empty() && cont.back() == Cont::ClassBody;
                if (!in_obj && !in_class) return false;
                size_t end = pk; // trailing spaces already stripped into pk
                if (end == 0) return false;
                // Computed method name ends with `]`.
                if (out[end - 1] == ']') return true;
                if (!isIdent(out[end - 1])) return false;
                size_t name_start = end;
                while (name_start > 0 && isIdent(out[name_start - 1])) --name_start;
                size_t before = name_start;
                while (before > 0 && std::isspace(static_cast<unsigned char>(out[before - 1]))) --before;
                char bp = before > 0 ? out[before - 1] : '\0';
                if (bp == '{' || bp == ',' || bp == '*') return true;
                // Class fields/methods are often semicolon-separated.
                if (in_class && bp == ';') return true;
                // get / set / async / static before the method name.
                if (before > 0 && isIdent(out[before - 1])) {
                    size_t ws = before;
                    while (ws > 0 && isIdent(out[ws - 1])) --ws;
                    std::string prev_word = out.substr(ws, before - ws);
                    if (prev_word == "get" || prev_word == "set" || prev_word == "async") return true;
                    if (in_class && prev_word == "static") return true;
                }
                return false;
            };
            auto opensForHead = [&]() -> bool {
                if (outEndsWithWord(pk, "for")) return true;
                // `for await (`
                if (!outEndsWithWord(pk, "await")) return false;
                size_t before = pk;
                if (before < 5) return false;
                before -= 5; // len("await")
                while (before > 0 && std::isspace(static_cast<unsigned char>(out[before - 1]))) --before;
                return outEndsWithWord(before, "for");
            };
            if (opensForHead()) {
                // Loop-header lexical bindings (`let`/`const`) live in this scope until the loop body ends.
                kind = Cont::ForHead;
                pushScope();
            } else if (outEndsWithWord(pk2, "function") || outEndsWithWord(pk2, "catch") ||
                outEndsWithWord(pk, "function") || outEndsWithWord(pk, "catch") ||
                parenFollowedByArrow(i) || opensMethodParamList()) {
                kind = Cont::ParamList;
                pushFunctionScope();
                in_param_default = false;
                // Parameter scope binds every formal for the whole list (incl. TDZ for later params referenced in earlier defaults), matching native ESM before any default initializer is rewritten.
                addBindings(collectParamListBoundNames(src, i));
            }
            cont.push_back(kind);
            out.push_back(src[i++]);
            continue;
        }
        if (c == ')') {
            bool was_param = !cont.empty() && cont.back() == Cont::ParamList;
            bool was_for_head = !cont.empty() && cont.back() == Cont::ForHead;
            if (!cont.empty() && (cont.back() == Cont::Paren || cont.back() == Cont::ParamList ||
                                  cont.back() == Cont::ForHead))
                cont.pop_back();
            out.push_back(src[i++]);
            if (was_param) {
                in_param_default = false;
                size_t k = i;
                skipSpacesSrc(k);
                if (k < src.size() && src[k] == '{') {
                    next_brace_is_fn_body = true;
                } else if (k + 1 < src.size() && src[k] == '=' && src[k + 1] == '>') {
                    // Arrow: keep param scope; `=>` handler records expr-body end or sets FnBody.
                    next_brace_is_fn_body = false;
                } else {
                    popScope();
                }
            } else if (was_for_head) {
                size_t k = i;
                skipSpacesSrc(k);
                if (k < src.size() && src[k] == '{') {
                    for_scope_pop_at_block_depth.push_back(cont.size());
                } else {
                    for_scope_pop_at_stmt_depth.push_back(cont.size());
                }
            }
            closeExprArrowsDeeperThan(cont.size());
            continue;
        }

        // End expression-arrow bodies at this container depth (array elements, args, sequence).
        if (c == ',' || c == ';') {
            closeExprArrowsAt(cont.size());
            if (c == ';' && !for_scope_pop_at_stmt_depth.empty() &&
                cont.size() == for_scope_pop_at_stmt_depth.back()) {
                for_scope_pop_at_stmt_depth.pop_back();
                popScope();
            }
        }

        // Parameter / destructuring-default separators end a default initializer (not commas inside nested `(…)` of the default expr).
        if (c == ',' && underParamList() && !cont.empty() &&
            (cont.back() == Cont::ParamList || cont.back() == Cont::ObjectLit ||
             cont.back() == Cont::Bracket)) {
            in_param_default = false;
            out.push_back(src[i++]);
            continue;
        }

        // Parameter / destructuring default: `=` under ParamList at pattern depth (not `=>` / `==` / compound assigns).
        if (c == '=' && underParamList() && !cont.empty() &&
            (cont.back() == Cont::ParamList || cont.back() == Cont::ObjectLit ||
             cont.back() == Cont::Bracket) &&
            !(i + 1 < src.size() && (src[i + 1] == '>' || src[i + 1] == '=')) &&
            !(i > 0 && (src[i - 1] == '=' || src[i - 1] == '!' || src[i - 1] == '<' ||
                        src[i - 1] == '>' || src[i - 1] == '+' || src[i - 1] == '-' ||
                        src[i - 1] == '*' || src[i - 1] == '/' || src[i - 1] == '%' ||
                        src[i - 1] == '&' || src[i - 1] == '|' || src[i - 1] == '^'))) {
            in_param_default = true;
            out.push_back(src[i++]);
            continue;
        }

        // Arrow `=>`: block body → FnBody; expression body → track end so param scope does not leak.
        if (c == '=' && i + 1 < src.size() && src[i + 1] == '>') {
            out.push_back(src[i++]);
            out.push_back(src[i++]);
            size_t k = i;
            skipSpacesSrc(k);
            if (k < src.size() && src[k] == '{') {
                next_brace_is_fn_body = true;
            } else {
                // Expression body: param scope stays until `,`/`;` at this cont depth or an outer close.
                expr_arrow_cont_depth.push_back(cont.size());
            }
            continue;
        }

        if (isIdentStart(c)) {
            size_t j = i + 1;
            while (j < src.size() && isIdent(src[j])) ++j;
            std::string id = src.substr(i, j - i);

            // function / class declaration name binds in the enclosing scope.
            if ((id == "function" || id == "class") && (i == 0 || !isIdent(src[i - 1]))) {
                out += id;
                i = j;
                while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) out.push_back(src[i++]);
                if (id == "function" && i < src.size() && src[i] == '*') {
                    out.push_back(src[i++]);
                    while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) out.push_back(src[i++]);
                }
                if (i < src.size() && isIdentStart(src[i])) {
                    size_t n = i + 1;
                    while (n < src.size() && isIdent(src[n])) ++n;
                    std::string fname = src.substr(i, n - i);
                    addBindings({fname});
                    out += fname;
                    i = n;
                }
                if (id == "class") {
                    // Only real class declarations/expressions (`class {` / `class X {` / `class … extends …`), not `{ class(){} }` / `{ class: 1 }`.
                    size_t la = i;
                    while (la < src.size() && std::isspace(static_cast<unsigned char>(src[la]))) ++la;
                    bool is_decl = la < src.size() && src[la] == '{';
                    if (!is_decl && la + 7 <= src.size() && src.compare(la, 7, "extends") == 0 &&
                        (la + 7 == src.size() || !isIdent(src[la + 7])))
                        is_decl = true;
                    if (is_decl) ++class_body_braces_pending;
                }
                continue;
            }

            // const / let / var — register declarator bindings; rewrite only initializer expressions.
            // `var` is function-scoped (or module-scoped): keep it active for the enclosing function, not the current block.
            if ((id == "const" || id == "let" || id == "var") && (i == 0 || !isIdent(src[i - 1]))) {
                out += id;
                i = j;
                auto names = collectDeclaratorBoundNames(src, i);
                if (id == "var") addVarBindings(names);
                else addBindings(names);
                int depth = 0;
                while (i < src.size()) {
                    char ch = src[i];
                    if (ch == '/' && i + 1 < src.size() && src[i + 1] == '/') {
                        while (i < src.size() && src[i] != '\n') out.push_back(src[i++]);
                        continue;
                    }
                    if (ch == '/' && i + 1 < src.size() && src[i + 1] == '*') {
                        out.push_back(src[i++]); out.push_back(src[i++]);
                        while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) out.push_back(src[i++]);
                        if (i < src.size()) out.push_back(src[i++]);
                        if (i < src.size()) out.push_back(src[i++]);
                        continue;
                    }
                    if (ch == '\'' || ch == '"') {
                        char q = ch; out.push_back(src[i++]);
                        while (i < src.size()) {
                            if (src[i] == '\\' && i + 1 < src.size()) { out.push_back(src[i++]); out.push_back(src[i++]); continue; }
                            out.push_back(src[i]);
                            if (src[i] == q) { ++i; break; }
                            ++i;
                        }
                        continue;
                    }
                    if (ch == '`') { copyTemplate(); continue; }
                    if (ch == '{' || ch == '[' || ch == '(') { ++depth; out.push_back(src[i++]); continue; }
                    if (ch == '}' || ch == ']' || ch == ')') {
                        if (depth > 0) --depth;
                        out.push_back(src[i++]);
                        continue;
                    }
// Declarator initializer (depth 0) or binding-pattern default (depth > 0): rewrite imports in the expression.
                    if (ch == '=' &&
                        !(i + 1 < src.size() && (src[i + 1] == '>' || src[i + 1] == '=')) &&
                        !(i > 0 && (src[i - 1] == '=' || src[i - 1] == '!' || src[i - 1] == '<' ||
                                    src[i - 1] == '>' || src[i - 1] == '+' || src[i - 1] == '-' ||
                                    src[i - 1] == '*' || src[i - 1] == '/' || src[i - 1] == '%' ||
                                    src[i - 1] == '&' || src[i - 1] == '|' || src[i - 1] == '^'))) {
                        const bool pattern_default = depth > 0;
                        out.push_back(src[i++]);
                        size_t is = i;
                        int d = 0;
                        while (i < src.size()) {
                            char ic = src[i];
                            if (ic == '\'' || ic == '"' || ic == '`') {
                                char q = ic; ++i;
                                while (i < src.size()) {
                                    if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                                    if (src[i] == q) { ++i; break; }
                                    if (q == '`' && src[i] == '$' && i + 1 < src.size() && src[i + 1] == '{') {
                                        i += 2; int nd = 1;
                                        while (i < src.size() && nd > 0) {
                                            if (src[i] == '{') ++nd;
                                            else if (src[i] == '}') --nd;
                                            ++i;
                                        }
                                        continue;
                                    }
                                    ++i;
                                }
                                continue;
                            }
                            if (ic == '{' || ic == '[' || ic == '(') { ++d; ++i; continue; }
                            if (ic == '}' || ic == ']' || ic == ')') {
                                if (d == 0) {
                                    // Pattern default ends before the closing `}` / `]` of the pattern.
                                    if (pattern_default) break;
                                    ++i;
                                    continue;
                                }
                                --d;
                                ++i;
                                continue;
                            }
                            if (d == 0 && (ic == ',' || ic == ';')) break;
                            ++i;
                        }
                        out += rewriteIdents(src.substr(is, i - is), repl, scopes);
                        continue;
                    }
                    if (ch == ';' && depth == 0) { out.push_back(src[i++]); break; }
                    if (isIdentStart(ch)) {
                        size_t n = i + 1;
                        while (n < src.size() && isIdent(src[n])) ++n;
                        // for-of / for-in header boundary: leave `of`/`in` + iterable for the outer rewrite pass.
                        if (depth == 0) {
                            const std::string kw = src.substr(i, n - i);
                            if (kw == "of" || kw == "in") break;
                        }
                        out.append(src, i, n - i);
                        i = n;
                        continue;
                    }
                    out.push_back(src[i++]);
                }
                continue;
            }

            // Single-param arrow: `value =>` — bind before arrow.
            {
                size_t k = j;
                skipSpacesSrc(k);
                if (k + 1 < src.size() && src[k] == '=' && src[k + 1] == '>' &&
                    (cont.empty() || cont.back() == Cont::Block || cont.back() == Cont::ClassBody ||
                     cont.back() == Cont::FnBody || cont.back() == Cont::Paren || cont.back() == Cont::ForHead ||
                     cont.back() == Cont::ObjectLit || cont.back() == Cont::Bracket)) {
                    char p = prevSignificant();
                    // Only treat as param if not a call/member and looks like expression start.
                    if (p != '.' && p != '?' && !isIdent(p) && p != ')' && p != ']') {
                        pushFunctionScope();
                        addBindings({id});
                        out += id;
                        i = j;
                        // `=>` handler sets next_brace_is_fn_body; for expr body pop on `;` approx.
                        // Mark that an expression-body arrow owns this scope:
                        // handled when we see `=>` without `{` — pop at `;`/`,`/`)`/`}` depth 0 later via FnBody absence.
                        // Use a sticky flag:
                        // Reuse next_brace: if `=>` not followed by `{`, pop after copying arrow expr in `=>` handler.
                        continue;
                    }
                }
            }

            // ParamList / destructuring bindings under ParamList: do not rewrite; register binding.
            // Default-initializer expressions (after `=` until `,`/`)`) may reference imports — allow rewrite.
            if (underParamList()) {
                char p = prevSignificant();
                if (p != '.' && p != '?') {
                    if (!in_param_default) {
                        addBindings({id});
                        out += id;
                        i = j;
                        continue;
                    }
                }
            }

            bool after_dot = false;
            bool after_question = false;
            if (!out.empty()) {
                size_t pk = out.size();
                while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
                if (pk > 0 && out[pk - 1] == '.') after_dot = true;
                if (pk > 0 && out[pk - 1] == '?') after_question = true;
            }
            size_t k = j;
            while (k < src.size() && std::isspace(static_cast<unsigned char>(src[k]))) ++k;
            // Property keys are only excluded inside object literals; a following colon alone is also the consequent/alternate separator in `?:`.
            bool in_object_lit_for_key = !cont.empty() && cont.back() == Cont::ObjectLit;
            bool object_key = in_object_lit_for_key && !after_question && (k < src.size() && src[k] == ':' &&
                                                 !(k + 1 < src.size() && src[k + 1] == ':'));
            // Method / accessor keys (`value()`, `get value()`, `set value()`, `async value()`, `*value()`, class `static value()`) are names, not references.
            bool method_key = false;
            bool in_class_body_for_key = !cont.empty() && cont.back() == Cont::ClassBody;
            if (!after_dot && !after_question && (in_object_lit_for_key || in_class_body_for_key) &&
                k < src.size() && src[k] == '(') {
                size_t pk = out.size();
                while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
                if (pk > 0 && (out[pk - 1] == '{' || out[pk - 1] == ',' || out[pk - 1] == '*' ||
                               (in_class_body_for_key && out[pk - 1] == ';'))) {
                    method_key = true;
                } else if (pk > 0 && (std::isalnum(static_cast<unsigned char>(out[pk - 1])) ||
                                      out[pk - 1] == '_' || out[pk - 1] == '$')) {
                    size_t start = pk;
                    while (start > 0) {
                        char ch = out[start - 1];
                        if (std::isalnum(static_cast<unsigned char>(ch)) || ch == '_' || ch == '$')
                            --start;
                        else
                            break;
                    }
                    std::string prev_word = out.substr(start, pk - start);
                    if (prev_word == "get" || prev_word == "set" || prev_word == "async" ||
                        (in_class_body_for_key && prev_word == "static"))
                        method_key = true;
                }
            }
            auto it = repl.find(id);
            if (!after_dot && !object_key && !method_key && it != repl.end() && !isShadowed(id)) {
                // Shorthand only for ObjectLit property context — not arrays, args, or blocks.
                bool in_object_lit = !cont.empty() && cont.back() == Cont::ObjectLit;
                bool after_shorthand_intro = false;
                if (in_object_lit && !out.empty()) {
                    size_t pk = out.size();
                    while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
                    if (pk > 0 && (out[pk - 1] == '{' || out[pk - 1] == ',')) after_shorthand_intro = true;
                }
                bool ahead_shorthand_end = (k < src.size() && (src[k] == ',' || src[k] == '}'));
                if (after_shorthand_intro && ahead_shorthand_end)
                    out += id + ": " + it->second;
                else
                    out += it->second;
            } else {
                out += id;
            }
            i = j;
            continue;
        }

        out.push_back(c);
        ++i;
    }
    return out;
}

static std::string rewriteIdents(const std::string &src,
                                 const std::unordered_map<std::string, std::string> &repl) {
    return rewriteIdents(src, repl, std::vector<std::unordered_set<std::string>>{});
}

struct ImportBinding {
    std::string local;
    std::string imported; // "." for namespace, "default" for default
    std::string module;
};

static std::string trim(std::string s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.erase(s.begin());
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
    return s;
}

// Collect bound names from a binding pattern (`ident`, `{a, b: c}`, `[x, ...y]`).
static void collectPatternBoundNames(const std::string &src, size_t &i, std::vector<std::string> &names) {
    while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
    if (i >= src.size()) return;
    if (src[i] == '{') {
        ++i;
        while (i < src.size()) {
            while (i < src.size() && (std::isspace(static_cast<unsigned char>(src[i])) || src[i] == ',')) ++i;
            if (i >= src.size()) return;
            if (src[i] == '}') { ++i; return; }
            if (src[i] == '.' && i + 2 < src.size() && src[i + 1] == '.' && src[i + 2] == '.') {
                i += 3;
                while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
                size_t j = i;
                while (j < src.size() && isIdent(src[j])) ++j;
                if (j > i) names.push_back(src.substr(i, j - i));
                i = j;
                continue;
            }
            if (src[i] == '{' || src[i] == '[') {
                collectPatternBoundNames(src, i, names);
                while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
                if (i < src.size() && src[i] == '=') {
                    ++i;
                    int depth = 0;
                    while (i < src.size()) {
                        char ch = src[i];
                        if (ch == '\\' && i + 1 < src.size()) { i += 2; continue; }
                        if (ch == '\'' || ch == '"' || ch == '`') {
                            char q = ch; ++i;
                            while (i < src.size()) {
                                if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                                if (src[i] == q) { ++i; break; }
                                ++i;
                            }
                            continue;
                        }
                        if (ch == '{' || ch == '[' || ch == '(') { ++depth; ++i; continue; }
                        if (ch == '}' || ch == ']' || ch == ')') {
                            if (depth == 0) break;
                            --depth; ++i; continue;
                        }
                        if (depth == 0 && (ch == ',' || ch == '}')) break;
                        ++i;
                    }
                }
                continue;
            }
            if (!isIdentStart(src[i])) { ++i; continue; }
            size_t j = i + 1;
            while (j < src.size() && isIdent(src[j])) ++j;
            std::string first = src.substr(i, j - i);
            i = j;
            while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            if (i < src.size() && src[i] == ':') {
                ++i;
                collectPatternBoundNames(src, i, names);
            } else {
                names.push_back(first);
                if (i < src.size() && src[i] == '=') {
                    ++i;
                    int depth = 0;
                    while (i < src.size()) {
                        char ch = src[i];
                        if (ch == '\\' && i + 1 < src.size()) { i += 2; continue; }
                        if (ch == '\'' || ch == '"' || ch == '`') {
                            char q = ch; ++i;
                            while (i < src.size()) {
                                if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                                if (src[i] == q) { ++i; break; }
                                ++i;
                            }
                            continue;
                        }
                        if (ch == '{' || ch == '[' || ch == '(') { ++depth; ++i; continue; }
                        if (ch == '}' || ch == ']' || ch == ')') {
                            if (depth == 0) break;
                            --depth; ++i; continue;
                        }
                        if (depth == 0 && (ch == ',' || ch == '}')) break;
                        ++i;
                    }
                }
            }
        }
        return;
    }
    if (src[i] == '[') {
        ++i;
        while (i < src.size()) {
            while (i < src.size() && (std::isspace(static_cast<unsigned char>(src[i])) || src[i] == ',')) ++i;
            if (i >= src.size()) return;
            if (src[i] == ']') { ++i; return; }
            if (src[i] == '.' && i + 2 < src.size() && src[i + 1] == '.' && src[i + 2] == '.') {
                i += 3;
                while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
                size_t j = i;
                while (j < src.size() && isIdent(src[j])) ++j;
                if (j > i) names.push_back(src.substr(i, j - i));
                i = j;
                continue;
            }
            collectPatternBoundNames(src, i, names);
            while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            if (i < src.size() && src[i] == '=') {
                ++i;
                int depth = 0;
                while (i < src.size()) {
                    char ch = src[i];
                    if (ch == '\\' && i + 1 < src.size()) { i += 2; continue; }
                    if (ch == '\'' || ch == '"' || ch == '`') {
                        char q = ch; ++i;
                        while (i < src.size()) {
                            if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                            if (src[i] == q) { ++i; break; }
                            ++i;
                        }
                        continue;
                    }
                    if (ch == '{' || ch == '[' || ch == '(') { ++depth; ++i; continue; }
                    if (ch == '}' || ch == ']' || ch == ')') {
                        if (depth == 0) break;
                        --depth; ++i; continue;
                    }
                    if (depth == 0 && (ch == ',' || ch == ']')) break;
                    ++i;
                }
            }
        }
        return;
    }
    if (!isIdentStart(src[i])) return;
    size_t j = i + 1;
    while (j < src.size() && isIdent(src[j])) ++j;
    names.push_back(src.substr(i, j - i));
    i = j;
}

// Bound names for `const/let/var` declarators starting at `start` (after the keyword).
static std::vector<std::string> collectDeclaratorBoundNames(const std::string &src, size_t start) {
    std::vector<std::string> names;
    size_t i = start;
    while (i < src.size()) {
        while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        if (i >= src.size() || src[i] == ';') break;
        collectPatternBoundNames(src, i, names);
        while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        if (i < src.size() && src[i] == '=') {
            ++i;
            int depth = 0;
            while (i < src.size()) {
                char ch = src[i];
                if (ch == '\\' && i + 1 < src.size()) { i += 2; continue; }
                if (ch == '\'' || ch == '"' || ch == '`') {
                    char q = ch; ++i;
                    while (i < src.size()) {
                        if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                        if (src[i] == q) { ++i; break; }
                        ++i;
                    }
                    continue;
                }
                if (ch == '{' || ch == '[' || ch == '(') { ++depth; ++i; continue; }
                if (ch == '}' || ch == ']' || ch == ')') {
                    if (depth > 0) --depth;
                    ++i; continue;
                }
                if (depth == 0 && (ch == ',' || ch == ';')) break;
                ++i;
            }
        }
        while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        if (i < src.size() && src[i] == ',') { ++i; continue; }
        break;
    }
    return names;
}

// Bound names for a parameter list starting at `open_paren` (`(`). Collects every formal before any default initializer is rewritten so later params shadow imports for the whole parameter scope (TDZ).
static std::vector<std::string> collectParamListBoundNames(const std::string &src, size_t open_paren) {
    std::vector<std::string> names;
    if (open_paren >= src.size() || src[open_paren] != '(') return names;
    size_t i = open_paren + 1;
    while (i < src.size()) {
        while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        if (i >= src.size() || src[i] == ')') break;
        if (src[i] == '/' && i + 1 < src.size() && src[i + 1] == '/') {
            i += 2;
            while (i < src.size() && src[i] != '\n') ++i;
            continue;
        }
        if (src[i] == '/' && i + 1 < src.size() && src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            if (i + 1 < src.size()) i += 2;
            continue;
        }
        if (src[i] == '.' && i + 2 < src.size() && src[i + 1] == '.' && src[i + 2] == '.') {
            i += 3;
            while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            collectPatternBoundNames(src, i, names);
            break;
        }
        collectPatternBoundNames(src, i, names);
        while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        if (i < src.size() && src[i] == '=') {
            ++i;
            int depth = 0;
            while (i < src.size()) {
                char ch = src[i];
                if (ch == '/' && i + 1 < src.size() && src[i + 1] == '/') {
                    i += 2;
                    while (i < src.size() && src[i] != '\n') ++i;
                    continue;
                }
                if (ch == '/' && i + 1 < src.size() && src[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
                    if (i + 1 < src.size()) i += 2;
                    continue;
                }
                if (ch == '\\' && i + 1 < src.size()) { i += 2; continue; }
                if (ch == '\'' || ch == '"' || ch == '`') {
                    char q = ch; ++i;
                    while (i < src.size()) {
                        if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                        if (src[i] == q) { ++i; break; }
                        ++i;
                    }
                    continue;
                }
                if (ch == '{' || ch == '[' || ch == '(') { ++depth; ++i; continue; }
                if (ch == '}' || ch == ']' || ch == ')') {
                    if (depth == 0) break;
                    --depth; ++i; continue;
                }
                if (depth == 0 && ch == ',') break;
                ++i;
            }
        }
        while (i < src.size() && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        if (i < src.size() && src[i] == ',') { ++i; continue; }
        break;
    }
    return names;
}

// Rewrite import.meta / dynamic import() only in executable source (and inside template interpolations). Strings, comments, regexp literals, and template cooked text stay intact.
static std::string rewriteImportMetaAndDynamic(const std::string &src) {
    std::string out;
    out.reserve(src.size() + 64);
    size_t i = 0;

    auto copyQuoted = [&](char q) {
        out.push_back(src[i++]);
        while (i < src.size()) {
            if (src[i] == '\\' && i + 1 < src.size()) {
                out.push_back(src[i++]);
                out.push_back(src[i++]);
                continue;
            }
            out.push_back(src[i]);
            if (src[i] == q) {
                ++i;
                break;
            }
            ++i;
        }
    };

    auto scanBalancedCallEnd = [&](size_t open_paren) -> size_t {
        // open_paren points at '(' of import(...). Return index past matching ')' or npos.
        int depth = 0;
        size_t p = open_paren;
        while (p < src.size()) {
            char ch = src[p];
            if (ch == '\\' && p + 1 < src.size()) {
                p += 2;
                continue;
            }
            if (ch == '\'' || ch == '"' || ch == '`') {
                char qq = ch;
                ++p;
                while (p < src.size()) {
                    if (src[p] == '\\' && p + 1 < src.size()) {
                        p += 2;
                        continue;
                    }
                    if (src[p] == qq) {
                        ++p;
                        break;
                    }
                    // Nested template interpolations: skip coarsely by brace depth inside `${`.
                    if (qq == '`' && src[p] == '$' && p + 1 < src.size() && src[p + 1] == '{') {
                        p += 2;
                        int nested = 1;
                        while (p < src.size() && nested > 0) {
                            if (src[p] == '{') ++nested;
                            else if (src[p] == '}') --nested;
                            ++p;
                        }
                        continue;
                    }
                    ++p;
                }
                continue;
            }
            if (ch == '(' || ch == '{' || ch == '[') {
                ++depth;
                ++p;
                continue;
            }
            if (ch == ')' || ch == '}' || ch == ']') {
                --depth;
                ++p;
                if (depth == 0) return p;
                continue;
            }
            ++p;
        }
        return std::string::npos;
    };

    auto tryRewriteImportAt = [&]() -> bool {
        if (i + 6 > src.size() || src.compare(i, 6, "import") != 0) return false;
        if (i > 0 && isIdent(src[i - 1])) return false;
        if (i + 6 < src.size() && isIdent(src[i + 6])) return false;
        // Member access / method call: obj.import(...) is not dynamic import().
        if (i > 0) {
            size_t j = i;
            while (j > 0 && std::isspace(static_cast<unsigned char>(src[j - 1]))) --j;
            if (j > 0 && src[j - 1] == '.') return false;
        }

        size_t k = i + 6;
        while (k < src.size() && std::isspace(static_cast<unsigned char>(src[k]))) ++k;

        // import.meta
        if (k + 4 < src.size() && src[k] == '.' && src.compare(k + 1, 4, "meta") == 0 &&
            (k + 5 >= src.size() || !isIdent(src[k + 5]))) {
            out += "(__jsbay_import_meta)";
            i = k + 5;
            return true;
        }

        // dynamic import( ... )
        if (k >= src.size() || src[k] != '(') return false;
        size_t arg = k + 1;
        while (arg < src.size() && std::isspace(static_cast<unsigned char>(src[arg]))) ++arg;
        if (arg >= src.size() || (src[arg] != '\'' && src[arg] != '"')) return false;
        char q = src[arg++];
        size_t spec_start = arg;
        while (arg < src.size()) {
            if (src[arg] == '\\' && arg + 1 < src.size()) {
                arg += 2;
                continue;
            }
            if (src[arg] == q) break;
            ++arg;
        }
        if (arg >= src.size()) return false;
        std::string spec = src.substr(spec_start, arg - spec_start);
        ++arg; // closing quote
        while (arg < src.size() && std::isspace(static_cast<unsigned char>(src[arg]))) ++arg;

        if (arg < src.size() && src[arg] == ',') {
            size_t end = scanBalancedCallEnd(k);
            if (end == std::string::npos) return false;
            out += "Promise.reject(new Error(\"import attributes not supported\"))";
            i = end;
            return true;
        }
        if (arg >= src.size() || src[arg] != ')') return false;
        out += "Promise.resolve().then(function(){ return require(";
        out.push_back(q);
        out += spec;
        out.push_back(q);
        out += "); })";
        i = arg + 1;
        return true;
    };

    auto skipTemplateInterpolation = [&](size_t from) -> size_t {
        // `from` is first char inside `${...}` (after '{'). Return index of matching '}'.
        size_t p = from;
        int depth = 1;
        while (p < src.size() && depth > 0) {
            char ic = src[p];
            if (ic == '/' && p + 1 < src.size() && src[p + 1] == '/') {
                p += 2;
                while (p < src.size() && src[p] != '\n') ++p;
                continue;
            }
            if (ic == '/' && p + 1 < src.size() && src[p + 1] == '*') {
                p += 2;
                while (p + 1 < src.size() && !(src[p] == '*' && src[p + 1] == '/')) ++p;
                if (p + 1 < src.size()) p += 2;
                continue;
            }
            if (ic == '\'' || ic == '"') {
                char q = ic;
                ++p;
                while (p < src.size()) {
                    if (src[p] == '\\' && p + 1 < src.size()) {
                        p += 2;
                        continue;
                    }
                    if (src[p] == q) {
                        ++p;
                        break;
                    }
                    ++p;
                }
                continue;
            }
            if (ic == '`') {
                ++p;
                while (p < src.size()) {
                    if (src[p] == '\\' && p + 1 < src.size()) {
                        p += 2;
                        continue;
                    }
                    if (src[p] == '`') {
                        ++p;
                        break;
                    }
                    if (src[p] == '$' && p + 1 < src.size() && src[p + 1] == '{') {
                        p += 2;
                        int nested = 1;
                        while (p < src.size() && nested > 0) {
                            if (src[p] == '{') ++nested;
                            else if (src[p] == '}') --nested;
                            ++p;
                        }
                        continue;
                    }
                    ++p;
                }
                continue;
            }
            if (ic == '{') {
                ++depth;
                ++p;
                continue;
            }
            if (ic == '}') {
                --depth;
                if (depth == 0) return p;
                ++p;
                continue;
            }
            ++p;
        }
        return p;
    };

    while (i < src.size()) {
        char c = src[i];
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '/') {
            while (i < src.size() && src[i] != '\n') out.push_back(src[i++]);
            continue;
        }
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '*') {
            out.push_back(src[i++]);
            out.push_back(src[i++]);
            while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) out.push_back(src[i++]);
            if (i < src.size()) out.push_back(src[i++]);
            if (i < src.size()) out.push_back(src[i++]);
            continue;
        }
        if (c == '/' && canStartRegexLiteral(out)) {
            copyRegexLiteral(src, i, out);
            continue;
        }
        if (c == '\'' || c == '"') {
            copyQuoted(c);
            continue;
        }
        if (c == '`') {
            out.push_back(src[i++]);
            while (i < src.size()) {
                if (src[i] == '\\' && i + 1 < src.size()) {
                    out.push_back(src[i++]);
                    out.push_back(src[i++]);
                    continue;
                }
                if (src[i] == '`') {
                    out.push_back(src[i++]);
                    break;
                }
                if (src[i] == '$' && i + 1 < src.size() && src[i + 1] == '{') {
                    out.push_back(src[i++]);
                    out.push_back(src[i++]);
                    // i now at first char of the interpolation expression.
                    size_t expr_start = i;
                    size_t close = skipTemplateInterpolation(expr_start);
                    out += rewriteImportMetaAndDynamic(src.substr(expr_start, close - expr_start));
                    i = close;
                    if (i < src.size() && src[i] == '}') out.push_back(src[i++]);
                    continue;
                }
                out.push_back(src[i++]);
            }
            continue;
        }
        if (tryRewriteImportAt()) continue;
        out.push_back(c);
        ++i;
    }
    return out;
}


// ESM namespace export: getter-only live forwarding. Local updates stay visible; importer writes fail (no namespace setter).
static std::string exportLiveGetter(const std::string &exported, const std::string &expr) {
    return "Object.defineProperty(exports,\"" + exported +
           "\",{enumerable:true,configurable:true,get:function(){return " + expr + ";}});";
}

// Very small ESM→CJS transform covering modules_tests fixtures.
static std::string transformEsmToCjs(const std::string &src, const std::string &filename) {
    (void)filename;
    std::string body = rewriteImportMetaAndDynamic(src);
    std::vector<ImportBinding> imports;
    std::vector<std::string> prelude;
    std::vector<std::string> epilogue;

    // Strip/collect import declarations (multi-form). Process repeatedly.
    auto eatImports = [&]() {
        static const std::regex import_side(R"(^\s*import\s+(['\"])([^'\"]+)\1\s*;?\s*)");
        static const std::regex import_default(
            R"(^\s*import\s+([A-Za-z_$][\w$]*)\s+from\s+(['\"])([^'\"]+)\2\s*;?\s*)");
        static const std::regex import_ns(
            R"(^\s*import\s+\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+(['\"])([^'\"]+)\2\s*;?\s*)");
        static const std::regex import_named(
            R"(^\s*import\s*\{([^}]*)\}\s*from\s+(['\"])([^'\"]+)\2\s*;?\s*)");
        static const std::regex import_def_named(
            R"(^\s*import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]*)\}\s*from\s+(['\"])([^'\"]+)\3\s*;?\s*)");

        bool changed = true;
        while (changed) {
            changed = false;
            std::smatch m;
            if (std::regex_search(body, m, import_def_named) && m.position() == 0) {
                imports.push_back({m[1].str(), "default", m[4].str()});
                std::string specs = m[2].str();
                size_t pos = 0;
                while (pos < specs.size()) {
                    size_t comma = specs.find(',', pos);
                    std::string part = trim(specs.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos));
                    if (!part.empty()) {
                        auto as_pos = part.find(" as ");
                        if (as_pos != std::string::npos)
                            imports.push_back({trim(part.substr(as_pos + 4)), trim(part.substr(0, as_pos)), m[4].str()});
                        else
                            imports.push_back({part, part, m[4].str()});
                    }
                    if (comma == std::string::npos) break;
                    pos = comma + 1;
                }
                body = body.substr(m.length());
                changed = true;
                continue;
            }
            if (std::regex_search(body, m, import_named) && m.position() == 0) {
                std::string specs = m[1].str();
                size_t pos = 0;
                bool any_named = false;
                while (pos < specs.size()) {
                    size_t comma = specs.find(',', pos);
                    std::string part = trim(specs.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos));
                    if (!part.empty()) {
                        any_named = true;
                        auto as_pos = part.find(" as ");
                        if (as_pos != std::string::npos)
                            imports.push_back({trim(part.substr(as_pos + 4)), trim(part.substr(0, as_pos)), m[3].str()});
                        else
                            imports.push_back({part, part, m[3].str()});
                    }
                    if (comma == std::string::npos) break;
                    pos = comma + 1;
                }
                // `import {} from 'dep'` still evaluates the dependency (side effects / missing module).
                if (!any_named)
                    imports.push_back({"", "", m[3].str()});
                body = body.substr(m.length());
                changed = true;
                continue;
            }
            if (std::regex_search(body, m, import_ns) && m.position() == 0) {
                imports.push_back({m[1].str(), ".", m[3].str()});
                body = body.substr(m.length());
                changed = true;
                continue;
            }
            if (std::regex_search(body, m, import_default) && m.position() == 0) {
                imports.push_back({m[1].str(), "default", m[3].str()});
                body = body.substr(m.length());
                changed = true;
                continue;
            }
            if (std::regex_search(body, m, import_side) && m.position() == 0) {
                imports.push_back({"", "", m[2].str()}); // side-effect
                body = body.substr(m.length());
                changed = true;
                continue;
            }
            // Also allow imports after newlines mid-file: search next import at line start on blankNonCode so commented-out `import` is ignored; mutate live body at those offsets.
            static const std::regex any_import(R"((^|\n)(\s*import\s))");
            {
                std::string blanked = blankNonCode(body);
                if (std::regex_search(blanked, m, any_import)) {
                    size_t start = m.position() + (m[1].matched ? m[1].length() : 0);
                    if (start > 0) {
                        // Move the complete import declaration (not just the first line) to the front.
                        std::string tail = body.substr(start);
                        std::smatch im;
                        size_t decl_len = 0;
                        if (std::regex_search(tail, im, import_def_named) && im.position() == 0)
                            decl_len = im.length();
                        else if (std::regex_search(tail, im, import_named) && im.position() == 0)
                            decl_len = im.length();
                        else if (std::regex_search(tail, im, import_ns) && im.position() == 0)
                            decl_len = im.length();
                        else if (std::regex_search(tail, im, import_default) && im.position() == 0)
                            decl_len = im.length();
                        else if (std::regex_search(tail, im, import_side) && im.position() == 0)
                            decl_len = im.length();
                        else {
                            // Fallback: through terminating `;` on blankNonCode (strings/comments ignored).
                            size_t semi = blanked.find(';', start);
                            if (semi != std::string::npos) {
                                decl_len = semi - start + 1;
                                if (start + decl_len < body.size() && body[start + decl_len] == '\r') ++decl_len;
                                if (start + decl_len < body.size() && body[start + decl_len] == '\n') ++decl_len;
                            } else {
                                size_t line_end = body.find('\n', start);
                                decl_len = line_end == std::string::npos ? body.size() - start : line_end - start + 1;
                            }
                        }
                        if (decl_len > 0 && tail.find("import") != std::string::npos) {
                            std::string decl = body.substr(start, decl_len);
                            body.erase(start, decl_len);
                            body = decl + body;
                            changed = true;
                            continue;
                        }
                    }
                }
            }
        }
    };
    // Record ordinary-import and re-export dependency sites in source order before eatImports rotates mid-file imports.
    struct StaticDepOcc {
        size_t pos = 0;
        std::string module;
        bool is_reexport = false;
    };
    std::vector<StaticDepOcc> static_dep_occs;
    {
        std::string blanked = blankNonCode(body);
        static const std::regex re_export_named(R"(export\s*\{[^}]*\}\s*from\s*(['"])([^'"]+)\1)");
        static const std::regex re_export_star(R"(export\s*\*\s*(?:as\s+[A-Za-z_$][\w$]*\s+)?from\s*(['"])([^'"]+)\1)");
        static const std::regex re_imp_def_named(
            R"(import\s+[A-Za-z_$][\w$]*\s*,\s*\{[^}]*\}\s*from\s*(['"])([^'"]+)\1)");
        static const std::regex re_imp_named(R"(import\s*\{[^}]*\}\s*from\s*(['"])([^'"]+)\1)");
        static const std::regex re_imp_ns(R"(import\s*\*\s*as\s+[A-Za-z_$][\w$]*\s*from\s*(['"])([^'"]+)\1)");
        static const std::regex re_imp_default(R"(import\s+[A-Za-z_$][\w$]*\s+from\s*(['"])([^'"]+)\1)");
        static const std::regex re_imp_side(R"(import\s*(['"])([^'"]+)\1)");
        auto collect_re = [&](const std::regex &re, bool is_reexport, int mod_group) {
            for (std::sregex_iterator it(blanked.begin(), blanked.end(), re), end; it != end; ++it) {
                // Match on blankNonCode for structure; take specifier text from original `body` (blanked string interiors are spaces).
                static_dep_occs.push_back(
                    {static_cast<size_t>(it->position(mod_group)),
                     body.substr(it->position(mod_group), it->length(mod_group)), is_reexport});
            }
        };
        collect_re(re_export_named, true, 2);
        collect_re(re_export_star, true, 2);
        collect_re(re_imp_def_named, false, 2);
        collect_re(re_imp_named, false, 2);
        collect_re(re_imp_ns, false, 2);
        collect_re(re_imp_default, false, 2);
        collect_re(re_imp_side, false, 2);
        std::sort(static_dep_occs.begin(), static_dep_occs.end(),
                  [](const StaticDepOcc &a, const StaticDepOcc &b) {
                      if (a.pos != b.pos) return a.pos < b.pos;
                      return a.is_reexport < b.is_reexport;
                  });
        // Deduplicate identical (pos, module, kind) hits from overlapping import patterns.
        {
            std::vector<StaticDepOcc> filtered;
            for (const auto &o : static_dep_occs) {
                if (!filtered.empty() && filtered.back().pos == o.pos && filtered.back().module == o.module &&
                    filtered.back().is_reexport == o.is_reexport)
                    continue;
                filtered.push_back(o);
            }
            static_dep_occs.swap(filtered);
        }
    }
    eatImports();

    // Re-export dependency loads go into the static prelude (native ESM: all static deps before module body).
    // Process named and star re-exports left-to-right so prelude require order matches source order.
    // Each entry is (module, require-line); merged with ordinary imports by static_dep_occs source order below.
    std::vector<std::pair<std::string, std::string>> reexport_prelude;
    std::vector<std::string> star_reexport_nss;
    std::vector<std::string> post_epilogue;
    {
        static const std::regex re_named(R"(export\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\2\s*;?)");
        static const std::regex re_star(R"(export\s*\*\s*from\s*(['"])([^'"]+)\1\s*;?)");
        static int reexport_ns = 0;
        for (;;) {
            std::string blanked = blankNonCode(body);
            std::smatch m_named, m_star;
            bool has_named = std::regex_search(blanked, m_named, re_named);
            bool has_star = std::regex_search(blanked, m_star, re_star);
            if (!has_named && !has_star) break;
            const bool take_star = has_star && (!has_named || m_star.position() < m_named.position());
            if (take_star) {
                std::string mod = body.substr(m_star.position(2), m_star.length(2));
                std::string ns = "__jsbay_re" + std::to_string(reexport_ns++);
                reexport_prelude.push_back({mod, "var " + ns + " = require(\"" + mod + "\");"});
                star_reexport_nss.push_back(ns);
                body.replace(m_star.position(), m_star.length(), "");
            } else {
                // Specs / module from the blanked match spans on the live body (same offsets).
                std::string specs = body.substr(m_named.position(1), m_named.length(1));
                std::string mod = body.substr(m_named.position(3), m_named.length(3));
                std::string ns = "__jsbay_re" + std::to_string(reexport_ns++);
                reexport_prelude.push_back({mod, "var " + ns + " = require(\"" + mod + "\");"});
                std::string repl;
                size_t pos = 0;
                while (pos < specs.size()) {
                    size_t comma = specs.find(',', pos);
                    std::string part = trim(specs.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos));
                    if (!part.empty()) {
                        std::string imported, exported;
                        auto as_pos = part.find(" as ");
                        if (as_pos != std::string::npos) {
                            imported = trim(part.substr(0, as_pos));
                            exported = trim(part.substr(as_pos + 4));
                        } else {
                            imported = exported = part;
                        }
                        repl += exportLiveGetter(exported, ns + "." + imported);
                    }
                    if (comma == std::string::npos) break;
                    pos = comma + 1;
                }
                body.replace(m_named.position(), m_named.length(), repl);
            }
        }
    }

    // export default ...
    {
        static const std::regex re_fn(R"(export\s+default\s+function\s*([A-Za-z_$][\w$]*)?)");
        std::smatch m;
        std::string blanked = blankNonCode(body);
        if (std::regex_search(blanked, m, re_fn)) {
            std::string name = m[1].matched ? body.substr(m.position(1), m.length(1)) : "__default_export";
            if (!m[1].matched) {
                body.replace(m.position(), m.length(), "function " + name);
            } else {
                body.replace(m.position(), std::strlen("export default "), "");
            }
            epilogue.push_back(exportLiveGetter("default", name));
        } else {
            static const std::regex re_def(R"(export\s+default\s+)");
            blanked = blankNonCode(body);
            if (std::regex_search(blanked, m, re_def)) {
                body.replace(m.position(), m.length(), "exports.default = ");
            }
        }
    }

    // export function name
    {
        static const std::regex re(R"(export\s+function\s+([A-Za-z_$][\w$]*))");
        std::smatch m;
        std::string tmp = body;
        std::string blanked = blankNonCode(tmp);
        body.clear();
        size_t last = 0;
        while (std::regex_search(blanked.cbegin() + last, blanked.cend(), m, re)) {
            size_t pos = last + m.position();
            body.append(tmp, last, pos - last);
            std::string name = m[1].str();
            body += "function " + name;
            epilogue.push_back(exportLiveGetter(name, name));
            last = pos + m.length();
        }
        body.append(tmp, last, std::string::npos);
    }

    // export const/let/var ... — publish every bound name (multi-decl + destructuring).
    {
        static const std::regex re(R"(export\s+(const|let|var)\s+)");
        std::smatch m;
        for (;;) {
            std::string blanked = blankNonCode(body);
            if (!std::regex_search(blanked, m, re)) break;
            size_t start = m.position() + m.length();
            std::string kind = m[1].str();
            auto names = collectDeclaratorBoundNames(body, start);
            body.replace(m.position(), m.length(), kind + " ");
            for (const auto &name : names) {
                if (name.empty()) continue;
                epilogue.push_back(exportLiveGetter(name, name));
            }
        }
    }

    // export { a, b as c };
    {
        static const std::regex re(R"(export\s*\{([^}]*)\}\s*;?)");
        std::smatch m;
        for (;;) {
            std::string blanked = blankNonCode(body);
            if (!std::regex_search(blanked, m, re)) break;
            std::string specs = body.substr(m.position(1), m.length(1));
            std::string repl;
            size_t pos = 0;
            while (pos < specs.size()) {
                size_t comma = specs.find(',', pos);
                std::string part = trim(specs.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos));
                if (!part.empty()) {
                    std::string local, exported;
                    auto as_pos = part.find(" as ");
                    if (as_pos != std::string::npos) {
                        local = trim(part.substr(0, as_pos));
                        exported = trim(part.substr(as_pos + 4));
                    } else {
                        local = exported = part;
                    }
                    repl += exportLiveGetter(exported, local);
                }
                if (comma == std::string::npos) break;
                pos = comma + 1;
            }
            body.replace(m.position(), m.length(), repl);
        }
    }

    // Build require prelude + live import bindings.
    // Ordinary imports and re-export dependencies share one source-ordered static dependency prelude (native ESM init order).
    std::unordered_map<std::string, std::string> ident_repl;
    int ns_i = 0;
    std::unordered_map<std::string, std::string> mod_to_ns;
    std::unordered_map<std::string, std::string> import_require_line;
    for (auto &ib : imports) {
        if (ib.module.empty()) continue;
        if (!mod_to_ns.count(ib.module)) {
            std::string ns = "__jsbay_ns" + std::to_string(ns_i++);
            mod_to_ns[ib.module] = ns;
            import_require_line[ib.module] = "var " + ns + " = require(\"" + ib.module + "\");";
        }
        if (ib.local.empty()) continue; // side-effect only
        std::string ns = mod_to_ns[ib.module];
        if (ib.imported == ".") {
            ident_repl[ib.local] = ns;
        } else if (ib.imported == "default") {
            // Unbound call form reading .default so `export default undefined` stays undefined and default callables keep this === undefined.
            ident_repl[ib.local] = "(0, " + ns + ".default)";
        } else {
            // Unbound call form: `import { f }` must keep `f()` as an unbound call (this === undefined), not `__jsbay_ns.f()` which binds this to the ns.
            ident_repl[ib.local] = "(0, " + ns + "." + ib.imported + ")";
        }
    }

    std::unordered_map<std::string, std::vector<std::string>> reexport_require_lines;
    for (auto &p : reexport_prelude) reexport_require_lines[p.first].push_back(p.second);
    std::unordered_map<std::string, size_t> reexport_emit_idx;
    std::unordered_set<std::string> import_emitted;
    for (const auto &occ : static_dep_occs) {
        if (occ.is_reexport) {
            auto it = reexport_require_lines.find(occ.module);
            if (it == reexport_require_lines.end()) continue;
            size_t &idx = reexport_emit_idx[occ.module];
            if (idx >= it->second.size()) continue;
            prelude.push_back(it->second[idx++]);
        } else {
            if (import_emitted.count(occ.module)) continue;
            auto it = import_require_line.find(occ.module);
            if (it == import_require_line.end()) continue;
            prelude.push_back(it->second);
            import_emitted.insert(occ.module);
        }
    }
    // Flush any requires not matched by the pre-scan (defensive; preserve relative registration order).
    for (const auto &ib : imports) {
        if (ib.module.empty() || import_emitted.count(ib.module)) continue;
        auto it = import_require_line.find(ib.module);
        if (it == import_require_line.end()) continue;
        prelude.push_back(it->second);
        import_emitted.insert(ib.module);
    }
    {
        std::unordered_map<std::string, size_t> seen;
        for (const auto &p : reexport_prelude) {
            size_t n = seen[p.first]++;
            if (n >= reexport_emit_idx[p.first]) prelude.push_back(p.second);
        }
    }

    // Star re-exports: track originating binding across deps; omit ambiguous names unless an explicit export already resolved them.
    // Intermediate namespace objects from a diamond (a and b both re-export the same base binding) must not mark the name ambiguous — compare leaf origins, and record origins on this module for further star re-exports.
    if (!star_reexport_nss.empty()) {
        std::string star;
        star += "var __jsbay_star_prov=Object.create(null);";
        star += "if(!Object.prototype.hasOwnProperty.call(exports,\"__jsbay_star_origin\"))";
        star += "Object.defineProperty(exports,\"__jsbay_star_origin\",{value:Object.create(null),configurable:true});";
        for (const auto &ns : star_reexport_nss) {
            star += "Object.keys(" + ns + ").forEach(function(k){";
            star += "if(k===\"default\"||k===\"__jsbay_star_origin\")return;";
            star += "var __jsbay_origin=(" + ns + ".__jsbay_star_origin&&Object.prototype.hasOwnProperty.call(" + ns + ".__jsbay_star_origin,k))?" + ns + ".__jsbay_star_origin[k]:" + ns + ";";
            star += "if(Object.prototype.hasOwnProperty.call(__jsbay_star_prov,k)){";
            star += "if(__jsbay_star_prov[k]!==__jsbay_origin)__jsbay_star_prov[k]=null;";
            star += "}else{__jsbay_star_prov[k]=__jsbay_origin;}});";
        }
        star += "Object.keys(__jsbay_star_prov).forEach(function(k){";
        star += "var __jsbay_src=__jsbay_star_prov[k];";
        star += "if(__jsbay_src==null)return;";
        star += "if(Object.prototype.hasOwnProperty.call(exports,k))return;";
        star += "Object.defineProperty(exports,k,{enumerable:true,configurable:true,get:function(){return __jsbay_src[k];}});";
        star += "exports.__jsbay_star_origin[k]=__jsbay_src;";
        star += "});";
        post_epilogue.push_back(star);
    }

    body = rewriteIdents(body, ident_repl);

    std::string out = "(async function(exports,require,module,__filename,__dirname,__jsbay_import_meta){\n\"use strict\";\n";
    for (auto &p : prelude) out += p + "\n";
    out += body;
    out += "\n";
    for (auto &e : epilogue) out += e + "\n";
    for (auto &e : post_epilogue) out += e + "\n";
    // Non-thenable completion: returning the namespace would assimilate an export named `then` and hang awaitThenable.
    out += "return undefined;\n})";
    return out;
}

static std::string resolveId(HermesModLoader *loader, const std::string &referrer, const std::string &specifier) {
    if (loader && loader->resolve) {
        char *resolved = loader->resolve(loader->ud, referrer.c_str(), specifier.c_str());
        if (resolved) {
            std::string s(resolved);
            if (loader->free_resolved) loader->free_resolved(loader->ud, resolved);
            else std::free(resolved);
            return s;
        }
    }
    return specifier;
}

// Settle a thenable by attaching then() and draining microtasks (TLA / async module factory).
static jsi::Value awaitThenable(JsbayHermesContext *c, FbHermesRuntime &rt, jsi::Value value) {
    if (!value.isObject()) return value;
    jsi::Object obj = value.getObject(rt);
    jsi::Value then_v;
    try {
        then_v = obj.getProperty(rt, "then");
    } catch (...) {
        return value;
    }
    if (!then_v.isObject() || !then_v.getObject(rt).isFunction(rt)) return value;

    struct Box {
        bool done = false;
        bool ok = true;
        jsi::Value result;
        std::string err;
    };
    auto box = std::make_shared<Box>();
    box->result = jsi::Value::undefined();

    auto onFulfilled = jsi::Function::createFromHostFunction(
        rt, jsi::PropNameID::forAscii(rt, "onFulfilled"), 1,
        [box](jsi::Runtime &rt0, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
            box->done = true;
            box->ok = true;
            if (count > 0) box->result = jsi::Value(rt0, args[0]);
            return jsi::Value::undefined();
        });
    auto onRejected = jsi::Function::createFromHostFunction(
        rt, jsi::PropNameID::forAscii(rt, "onRejected"), 1,
        [box](jsi::Runtime &rt0, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
            box->done = true;
            box->ok = false;
            if (count > 0) {
                try {
                    if (args[0].isString()) box->err = args[0].getString(rt0).utf8(rt0);
                    else if (args[0].isObject()) {
                        auto o = args[0].getObject(rt0);
                        if (o.hasProperty(rt0, "message")) {
                            auto m = o.getProperty(rt0, "message");
                            if (m.isString()) box->err = m.getString(rt0).utf8(rt0);
                        }
                        if (box->err.empty()) box->err = args[0].toString(rt0).utf8(rt0);
                    } else {
                        box->err = args[0].toString(rt0).utf8(rt0);
                    }
                } catch (...) {
                    box->err = "module async evaluation rejected";
                }
            }
            if (box->err.empty()) box->err = "module async evaluation rejected";
            return jsi::Value::undefined();
        });

    then_v.getObject(rt).getFunction(rt).callWithThis(rt, obj, onFulfilled, onRejected);

    for (int i = 0; i < 100000 && !box->done; ++i) {
        hermes_context_drain_microtasks(c);
    }
    if (!box->done) throw jsi::JSError(rt, "module async evaluation timed out");
    if (!box->ok) throw jsi::JSError(rt, box->err);
    return std::move(box->result);
}

static jsi::Object loadAndEvalModule(JsbayHermesContext *c, HermesModLoader *loader,
                                     FbHermesRuntime &rt, const std::string &id);

static jsi::Function makeRequire(JsbayHermesContext *c, HermesModLoader *loader, FbHermesRuntime &rt,
                                 const std::string &referrer) {
    return jsi::Function::createFromHostFunction(
        rt, jsi::PropNameID::forAscii(rt, "require"), 1,
        [c, loader, referrer](jsi::Runtime &rt0, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
            auto &rt = static_cast<FbHermesRuntime &>(rt0);
            if (!loader || count < 1 || !args[0].isString())
                throw jsi::JSError(rt, "require expects a string");
            std::string spec = args[0].getString(rt).utf8(rt);
            std::string id = resolveId(loader, referrer, spec);
            return loadAndEvalModule(c, loader, rt, id);
        });
}

static jsi::Object loadAndEvalModule(JsbayHermesContext *c, HermesModLoader *loader,
                                     FbHermesRuntime &rt, const std::string &id) {
    auto it = loader->cache.find(id);
    if (it != loader->cache.end()) {
        if (it->second->failed) {
            throw jsi::JSError(rt, it->second->fail_message.empty()
                                    ? ("module '" + id + "' previously failed to evaluate")
                                    : it->second->fail_message);
        }
        return jsi::Value(rt, it->second->exports).getObject(rt);
    }
    if (!loader->load)
        throw jsi::JSError(rt, "could not load module '" + id + "'");
    const char *src_ptr = nullptr;
    size_t src_len = 0;
    if (!loader->load(loader->ud, id.c_str(), &src_ptr, &src_len) || !src_ptr)
        throw jsi::JSError(rt, "could not load module '" + id + "'");
    std::string source(src_ptr, src_len);

    auto rec = std::make_shared<HermesModuleRecord>(HermesModuleRecord{jsi::Object(rt), true, false});
    loader->cache.emplace(id, rec);

    std::string wrapped = transformEsmToCjs(source, id);
    try {
        auto factory = rt.evaluateJavaScript(std::make_shared<jsi::StringBuffer>(wrapped), id);
        if (!factory.isObject() || !factory.getObject(rt).isFunction(rt))
            throw jsi::JSError(rt, "module factory is not a function");
        auto fn = factory.getObject(rt).getFunction(rt);
        jsi::Object moduleObj(rt);
        moduleObj.setProperty(rt, "exports", rec->exports);
        jsi::Object importMeta(rt);
        importMeta.setProperty(rt, "url", jsi::String::createFromUtf8(rt, id));
        auto requireFn = makeRequire(c, loader, rt, id);
        jsi::Value result = fn.call(
            rt,
            rec->exports,
            requireFn,
            moduleObj,
            jsi::String::createFromUtf8(rt, id),
            jsi::String::createFromUtf8(rt, ""),
            importMeta);
        result = awaitThenable(c, rt, std::move(result));
        if (result.isObject()) {
            rec->exports = result.getObject(rt);
            moduleObj.setProperty(rt, "exports", rec->exports);
        } else {
            // Prefer module.exports if the async factory resolved to a non-object.
            auto ex = moduleObj.getProperty(rt, "exports");
            if (ex.isObject()) rec->exports = ex.getObject(rt);
        }
        rec->loading = false;
        rec->ready = true;
        return jsi::Value(rt, rec->exports).getObject(rt);
    } catch (const jsi::JSError &e) {
        rec->loading = false;
        rec->ready = false;
        rec->failed = true;
        rec->fail_message = e.getMessage();
        if (rec->fail_message.empty()) rec->fail_message = "module '" + id + "' failed to evaluate";
        throw;
    } catch (...) {
        rec->loading = false;
        rec->ready = false;
        rec->failed = true;
        rec->fail_message = "module '" + id + "' failed to evaluate";
        throw;
    }
}

extern "C" void hermes_install_module_loader(JsbayHermesContext *ctx, void *user_data,
                                             HermesModResolveFn resolve, HermesModLoadFn load,
                                             HermesModFreeResolvedFn free_resolved) {
    if (!ctx) return;
    std::lock_guard<std::mutex> lock(g_mod_mu);
    auto it = g_mod_loaders.find(ctx);
    if (it != g_mod_loaders.end()) {
        // Drop cached jsi::Objects while the Runtime is still alive.
        it->second->cache.clear();
        g_mod_loaders.erase(it);
    }
    auto loader = std::make_unique<HermesModLoader>();
    loader->ud = user_data;
    loader->resolve = resolve;
    loader->load = load;
    loader->free_resolved = free_resolved;
    g_mod_loaders.emplace(ctx, std::move(loader));
}

extern "C" void hermes_uninstall_module_loader(JsbayHermesContext *ctx) {
    if (!ctx) return;
    std::lock_guard<std::mutex> lock(g_mod_mu);
    auto it = g_mod_loaders.find(ctx);
    if (it == g_mod_loaders.end()) return;
    it->second->cache.clear();
    g_mod_loaders.erase(it);
}

static HermesModLoader *getLoader(JsbayHermesContext *ctx) {
    std::lock_guard<std::mutex> lock(g_mod_mu);
    auto it = g_mod_loaders.find(ctx);
    return it == g_mod_loaders.end() ? nullptr : it->second.get();
}

extern "C" HermesEvalResult hermes_eval_module(JsbayHermesContext *c, const char *src, size_t src_len,
                                               const char *filename, size_t filename_len) {
    HermesEvalResult out{};
    if (!c || !hermes_context_rt(c) || !src) {
        hermesEvalSetErrLocal(out, "invalid context");
        return out;
    }
    HermesModLoader *loader = getLoader(c);
    // Allow eval without loader when source has no imports — still run through transform.
    std::string fname(filename ? filename : "", filename_len);
    if (fname.empty()) fname = "<module>";
    std::string source(src, src_len);
    HermesModLoader *use = loader;
    std::shared_ptr<HermesModuleRecord> rec;
    auto markEntryFailed = [&](const std::string &msg) {
        if (!rec) return;
        rec->loading = false;
        rec->ready = false;
        rec->failed = true;
        rec->fail_message = msg.empty() ? ("module '" + fname + "' failed to evaluate") : msg;
    };
    try {
        auto &rt = *hermes_context_rt(c);
        // Ensure a loader exists for require during entry. makeRequire closures capture the loader pointer, so it must outlive this stack frame (heap / context map).
        if (!use) {
            auto owned = std::make_unique<HermesModLoader>();
            use = owned.get();
            std::lock_guard<std::mutex> lock(g_mod_mu);
            g_mod_loaders.emplace(c, std::move(owned));
        }
        // Entry: register synthetic module under filename, evaluate
        rec = std::make_shared<HermesModuleRecord>(HermesModuleRecord{jsi::Object(rt), true, false});
        use->cache[fname] = rec;
        std::string wrapped = transformEsmToCjs(source, fname);
        auto factory = rt.evaluateJavaScript(std::make_shared<jsi::StringBuffer>(wrapped), fname);
        if (!factory.isObject() || !factory.getObject(rt).isFunction(rt)) {
            hermesEvalSetErrLocal(out, "module factory is not a function");
            use->cache.erase(fname);
            return out;
        }
        auto fn = factory.getObject(rt).getFunction(rt);
        jsi::Object moduleObj(rt);
        moduleObj.setProperty(rt, "exports", rec->exports);
        jsi::Object importMeta(rt);
        importMeta.setProperty(rt, "url", jsi::String::createFromUtf8(rt, fname));
        auto requireFn = makeRequire(c, use, rt, fname);
        jsi::Value result = fn.call(rt, rec->exports, requireFn, moduleObj,
                jsi::String::createFromUtf8(rt, fname),
                jsi::String::createFromUtf8(rt, ""),
                importMeta);
        result = awaitThenable(c, rt, std::move(result));
        if (result.isObject()) {
            rec->exports = result.getObject(rt);
            moduleObj.setProperty(rt, "exports", rec->exports);
        } else {
            // Completion is intentionally non-thenable; take the namespace from module.exports.
            auto ex = moduleObj.getProperty(rt, "exports");
            if (ex.isObject()) rec->exports = ex.getObject(rt);
        }
        rec->loading = false;
        rec->ready = true;
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const jsi::JSError &e) {
        markEntryFailed(e.getMessage());
        hermesEvalSetErrLocal(out, e.getMessage());
        hermes_report_unhandled_rejection(c, e.getMessage().c_str());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const std::exception &e) {
        markEntryFailed(e.what());
        hermesEvalSetErrLocal(out, e.what());
        hermes_report_unhandled_rejection(c, e.what());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (...) {
        markEntryFailed("module evaluation error");
        hermesEvalSetErrLocal(out, "module evaluation error");
        hermes_report_unhandled_rejection(c, "module evaluation error");
        hermes_context_drain_microtasks(c);
        return out;
    }
}

extern "C" HermesEvalResult hermes_import_module(JsbayHermesContext *c, const char *specifier) {
    HermesEvalResult out{};
    if (!c || !hermes_context_rt(c) || !specifier) {
        hermesEvalSetErrLocal(out, "invalid context");
        return out;
    }
    HermesModLoader *loader = getLoader(c);
    if (!loader || !loader->load) {
        hermesEvalSetErrLocal(out, "no module loader configured");
        return out;
    }
    try {
        auto &rt = *hermes_context_rt(c);
        std::string id = resolveId(loader, "", specifier);
        loadAndEvalModule(c, loader, rt, id);
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const jsi::JSError &e) {
        hermesEvalSetErrLocal(out, e.getMessage());
        hermes_report_unhandled_rejection(c, e.getMessage().c_str());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const std::exception &e) {
        hermesEvalSetErrLocal(out, e.what());
        hermes_report_unhandled_rejection(c, e.what());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (...) {
        hermesEvalSetErrLocal(out, "module import failed");
        hermes_report_unhandled_rejection(c, "module import failed");
        hermes_context_drain_microtasks(c);
        return out;
    }
}
