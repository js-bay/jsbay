// Hermes spike ESM ModuleLoader — host-side transform (Hermes pin disables native CJS/ESM codegen).
//
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

// Collision-free CJS wrapper parameter names so user ESM bindings named `exports` / `require` / `module` / `__filename` / `__dirname` do not clash with factory params (params share the module body scope).
static constexpr const char *kWrapExports = "__jsbay_exports";
static constexpr const char *kWrapRequire = "__jsbay_require";
static constexpr const char *kWrapModule = "__jsbay_module";
static constexpr const char *kWrapFilename = "__jsbay_filename";
static constexpr const char *kWrapDirname = "__jsbay_dirname";
static constexpr const char *kWrapImportMeta = "__jsbay_import_meta";
// Pristine intrinsic Object passed as a factory param so module-local `Object` cannot break generated export registration / star-reexport helpers (body `var Object = Object` would hit TDZ).
static constexpr const char *kWrapObject = "__jsbay_Object";
// Derived inside the factory from kWrapObject so export helpers call a non-shadowable defineProperty.
static constexpr const char *kWrapDefineProperty = "__jsbay_defineProperty";

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
//
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

    if (prev == '}') {
        // Closing `}` may end a statement block (regex ok: `if (…) {} /re/`) or an object/function expression (division: `x={}/y`).
        int depth = 0;
        size_t j = pk;
        while (j > 0) {
            char ch = preceding[j - 1];
            if (ch == '}') {
                ++depth;
                --j;
                continue;
            }
            if (ch == '{') {
                --depth;
                --j;
                if (depth != 0) continue;
                while (j > 0 && std::isspace(static_cast<unsigned char>(preceding[j - 1]))) --j;
                if (j == 0) return true; // block at input start
                char before = preceding[j - 1];
                // Nested/adjacent statement blocks.
                if (before == ';' || before == '{' || before == '}') return true;
                if (before == ')') {
                    // `if (…) {…}` / `while` / `for` / `switch` / `with` / `catch` / `function …(…) {…}`.
                    int pdepth = 0;
                    size_t k = j;
                    while (k > 0) {
                        char c2 = preceding[k - 1];
                        if (c2 == ')') {
                            ++pdepth;
                            --k;
                            continue;
                        }
                        if (c2 == '(') {
                            --pdepth;
                            --k;
                            if (pdepth != 0) continue;
                            while (k > 0 && std::isspace(static_cast<unsigned char>(preceding[k - 1]))) --k;
                            size_t end = k;
                            while (k > 0) {
                                char w = preceding[k - 1];
                                if (!(std::isalnum(static_cast<unsigned char>(w)) || w == '_' || w == '$')) break;
                                --k;
                            }
                            std::string word = preceding.substr(k, end - k);
                            if (word == "if" || word == "while" || word == "for" || word == "with" ||
                                word == "switch" || word == "catch" || word == "function")
                                return true;
                            // Named function/catch: `function ident(` — look one token further back.
                            while (k > 0 && std::isspace(static_cast<unsigned char>(preceding[k - 1]))) --k;
                            size_t end2 = k;
                            while (k > 0) {
                                char w = preceding[k - 1];
                                if (!(std::isalnum(static_cast<unsigned char>(w)) || w == '_' || w == '$')) break;
                                --k;
                            }
                            std::string word2 = preceding.substr(k, end2 - k);
                            if (word2 == "function" || word2 == "catch") return true;
                            return false; // call/group expression body
                        }
                        --k;
                    }
                    return false;
                }
                // Arrow block body `=>{…}` ends an expression → division.
                if (before == '>' && j >= 2 && preceding[j - 2] == '=') return false;
                if (std::isalnum(static_cast<unsigned char>(before)) || before == '_' || before == '$') {
                    size_t end = j;
                    size_t k = j;
                    while (k > 0) {
                        char w = preceding[k - 1];
                        if (!(std::isalnum(static_cast<unsigned char>(w)) || w == '_' || w == '$')) break;
                        --k;
                    }
                    std::string word = preceding.substr(k, end - k);
                    if (word == "else" || word == "try" || word == "finally" || word == "do" ||
                        word == "catch" || word == "class" || word == "function")
                        return true;
                    // Expression keywords introducing an object literal.
                    if (word == "return" || word == "throw" || word == "yield" || word == "await" ||
                        word == "typeof" || word == "new" || word == "void" || word == "delete" ||
                        word == "case" || word == "in" || word == "instanceof" || word == "of")
                        return false;
                    while (k > 0 && std::isspace(static_cast<unsigned char>(preceding[k - 1]))) --k;
                    // `class Name extends Base {` — heritage ends with an ident.
                    if (k >= 7 && preceding.compare(k - 7, 7, "extends") == 0) return true;
                    size_t end2 = k;
                    while (k > 0) {
                        char w = preceding[k - 1];
                        if (!(std::isalnum(static_cast<unsigned char>(w)) || w == '_' || w == '$')) break;
                        --k;
                    }
                    std::string word2 = preceding.substr(k, end2 - k);
                    if (word2 == "class" || word2 == "extends") return true;
                    return false;
                }
                if (before == ':') {
                    // `label:{…}` / `case 1:{…}` → statement; `key:{…}` in object → expression.
                    size_t k = j - 1; // at ':'
                    while (k > 0 && std::isspace(static_cast<unsigned char>(preceding[k - 1]))) --k;
                    if (k > 0 && (preceding[k - 1] == '"' || preceding[k - 1] == '\'' || preceding[k - 1] == '`')) {
                        char q = preceding[k - 1];
                        --k;
                        while (k > 0) {
                            if (k >= 2 && preceding[k - 1] == '\\') {
                                k -= 2;
                                continue;
                            }
                            if (preceding[k - 1] == q) {
                                --k;
                                break;
                            }
                            --k;
                        }
                    } else {
                        while (k > 0) {
                            char w = preceding[k - 1];
                            if (!(std::isalnum(static_cast<unsigned char>(w)) || w == '_' || w == '$')) break;
                            --k;
                        }
                    }
                    while (k > 0 && std::isspace(static_cast<unsigned char>(preceding[k - 1]))) --k;
                    if (k > 0 && (preceding[k - 1] == '{' || preceding[k - 1] == ',')) return false;
                    return true;
                }
                // Expression-introducing punctuators before `{` → object/expr → division.
                if (before == '=' || before == '(' || before == '[' || before == ',' || before == '?' ||
                    before == '!' || before == '~' || before == '&' || before == '|' || before == '^' ||
                    before == '*' || before == '%' || before == '<' || before == '>' || before == '+' ||
                    before == '-' || before == '.')
                    return false;
                return true;
            }
            --j;
        }
        return true; // unmatched `}` — statement-ish boundary
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

// Advance past leading whitespace and // or /* */ comments so anchored import collectors can see a declaration after a file header comment.
static size_t skipLeadingTrivia(const std::string &src, size_t i = 0) {
    while (i < src.size()) {
        unsigned char c = static_cast<unsigned char>(src[i]);
        if (std::isspace(c)) { ++i; continue; }
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '/') {
            i += 2;
            while (i < src.size() && src[i] != '\n') ++i;
            continue;
        }
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            if (i + 1 < src.size()) i += 2;
            else i = src.size();
            continue;
        }
        break;
    }
    return i;
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
static bool takeBalancedBracketExpr(const std::string &src, size_t &i, size_t &expr_start, size_t &expr_end);
static char prevSignificantChar(const std::string &src, size_t pos);
static size_t skipTriviaBackward(const std::string &src, size_t pos);
static char prevSignificantSkippingComments(const std::string &src, size_t pos);
static void collectAsAliasSpecs(const std::string &specs, std::vector<std::pair<std::string, std::string>> &out);

// Skip strings/comments/regex roughly; return rewritten source with identifier replacements.
//
// Template literal text is preserved, but `${...}` interpolations are rewritten recursively.
//
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
                if (ch == '/' && canStartRegexLiteral(src.substr(0, i))) { skipRegexLiteral(src, i); continue; }
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
            if (c == '/' && canStartRegexLiteral(src.substr(0, i))) { skipRegexLiteral(src, i); continue; }
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

    // Scan a matched `{...}` body (or top-level range) for `let`/`const` bindings in this lexical scope only. Nested `{...}` blocks are skipped so their bindings stay in the child scope. Loop-header `let`/`const` (`for` / `for await`) are skipped here too — they get their own scope during rewrite rather than shadowing the enclosing function or block. Registering before rewriting lets references that textually precede the declarator resolve to the local binding (TDZ / closure capture), matching native ESM.
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
                if (ch == '/' && canStartRegexLiteral(src.substr(0, i))) { skipRegexLiteral(src, i); continue; }
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
            if (c == '/' && canStartRegexLiteral(src.substr(0, i))) { skipRegexLiteral(src, i); continue; }
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
                    // Declaration names bind in this enclosing scope; expression names stay inside the nested function/class environment only.
                    auto isExprContextBefore = [&](size_t kw_pos) -> bool {
                        size_t pk = kw_pos;
                        while (pk > from && std::isspace(static_cast<unsigned char>(src[pk - 1]))) --pk;
                        // `async function` keeps the context from before `async`.
                        if (pk >= 5 && src.compare(pk - 5, 5, "async") == 0 &&
                            (pk == 5 || !isIdent(src[pk - 6]))) {
                            pk -= 5;
                            while (pk > from && std::isspace(static_cast<unsigned char>(src[pk - 1]))) --pk;
                        }
                        char p = pk > from ? src[pk - 1] : (pk > 0 ? src[pk - 1] : '\0');
                        // At range start, treat as declaration unless the char immediately before `from` is expression punctuation (caller range is body interior).
                        if (pk == from && from > 0) {
                            size_t q = from;
                            while (q > 0 && std::isspace(static_cast<unsigned char>(src[q - 1]))) --q;
                            p = q > 0 ? src[q - 1] : '\0';
                        }
                        if (p == '=' || p == '(' || p == '[' || p == ',' || p == '!' || p == '?' ||
                            p == '&' || p == '|' || p == '+' || p == '-' || p == '*' || p == '/' ||
                            p == '%' || p == '~' || p == '^' || p == '<' || p == '>' || p == ':')
                            return true;
                        auto endsWithWord = [&](size_t end, const char *w) -> bool {
                            size_t n = std::strlen(w);
                            if (end < n) return false;
                            if (src.compare(end - n, n, w) != 0) return false;
                            if (end > n && isIdent(src[end - n - 1])) return false;
                            return true;
                        };
                        return endsWithWord(pk, "return") || endsWithWord(pk, "throw") ||
                               endsWithWord(pk, "else") || endsWithWord(pk, "=>") ||
                               endsWithWord(pk, "of") || endsWithWord(pk, "in") ||
                               endsWithWord(pk, "case") || endsWithWord(pk, "void") ||
                               endsWithWord(pk, "typeof") || endsWithWord(pk, "delete") ||
                               endsWithWord(pk, "new") || endsWithWord(pk, "default") ||
                               endsWithWord(pk, "yield") || endsWithWord(pk, "await");
                    };
                    // `i` was advanced past the keyword; keyword starts at j - id.size()... actually i==j after `i = j`, keyword is [j-id.size(), j).
                    const size_t kw_pos = j - id.size();
                    const bool is_expr = isExprContextBefore(kw_pos);
                    if (!is_expr) {
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
    // After `for (let|const …)` / `for await (…)`, pop the loop-header scope when its body ends: entries are `cont.size()` after the ForHead `)` — matched when a Block at that depth closes, or a `;` ends a non-braced body. For unbraced bodies, defer the pop while `else` / `catch` / `finally` continues the body statement.
    std::vector<size_t> for_scope_pop_at_block_depth;
    std::vector<size_t> for_scope_pop_at_stmt_depth;
    // True while scanning a parameter default initializer (`=` … until `,`/`)` at ParamList depth).
    bool in_param_default = false;
    // Expression-bodied arrows (`=> expr` without `{`): cont.size() when the body began. Pop the param scope when the expression ends at that container depth (`,` / `;`) or when an outer container closes (cont shrinks below the marker).
    std::vector<size_t> expr_arrow_cont_depth;
    // Named function/class *expression* names bind only in their own environment (not the enclosing scope). Stash here and inject when ParamList / ClassBody opens.
    std::vector<std::string> pending_named_expr_bindings;
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
        // `else {` introduces a statement block, not an object literal — keep lexical scope push/pop.
        return outEndsWithWord(pk, "return") || outEndsWithWord(pk, "throw") ||
               outEndsWithWord(pk, "=>") ||
               outEndsWithWord(pk, "of") || outEndsWithWord(pk, "in") ||
               outEndsWithWord(pk, "case") || outEndsWithWord(pk, "void") ||
               outEndsWithWord(pk, "typeof") || outEndsWithWord(pk, "delete") ||
               outEndsWithWord(pk, "new") || outEndsWithWord(pk, "default");
    };
    // True when `function` / `class` starts an expression (name must not shadow the enclosing scope).
    auto isFnOrClassExpressionContext = [&]() -> bool {
        size_t pk = out.size();
        while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
        // `async function name` keeps the context from before `async`.
        if (outEndsWithWord(pk, "async")) {
            pk -= 5;
            while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
        }
        char p = pk > 0 ? out[pk - 1] : '\0';
        if (p == '=' || p == '(' || p == '[' || p == ',' || p == '!' || p == '?' ||
            p == '&' || p == '|' || p == '+' || p == '-' || p == '*' || p == '/' ||
            p == '%' || p == '~' || p == '^' || p == '<' || p == '>' || p == ':')
            return true;
        return outEndsWithWord(pk, "return") || outEndsWithWord(pk, "throw") ||
               outEndsWithWord(pk, "else") || outEndsWithWord(pk, "=>") ||
               outEndsWithWord(pk, "of") || outEndsWithWord(pk, "in") ||
               outEndsWithWord(pk, "case") || outEndsWithWord(pk, "void") ||
               outEndsWithWord(pk, "typeof") || outEndsWithWord(pk, "delete") ||
               outEndsWithWord(pk, "new") || outEndsWithWord(pk, "default") ||
               outEndsWithWord(pk, "yield") || outEndsWithWord(pk, "await");
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
    // Skip spaces and // /* */ comments so statement-continuation lookahead sees `else` / `catch` / `finally`.
    auto skipSpacesAndCommentsSrc = [&](size_t &p) {
        while (p < src.size()) {
            if (std::isspace(static_cast<unsigned char>(src[p]))) { ++p; continue; }
            if (src[p] == '/' && p + 1 < src.size() && src[p + 1] == '/') {
                p += 2;
                while (p < src.size() && src[p] != '\n') ++p;
                continue;
            }
            if (src[p] == '/' && p + 1 < src.size() && src[p + 1] == '*') {
                p += 2;
                while (p + 1 < src.size() && !(src[p] == '*' && src[p + 1] == '/')) ++p;
                if (p + 1 < src.size()) p += 2;
                continue;
            }
            break;
        }
    };
    // True when the statement after `pos` continues via else / catch / finally (keep loop-header scope alive).
    auto statementContinuesAfter = [&](size_t pos) -> bool {
        skipSpacesAndCommentsSrc(pos);
        auto atWord = [&](const char *w) -> bool {
            size_t n = std::strlen(w);
            if (pos + n > src.size()) return false;
            if (src.compare(pos, n, w) != 0) return false;
            if (pos + n < src.size() && isIdent(src[pos + n])) return false;
            return true;
        };
        return atWord("else") || atWord("catch") || atWord("finally");
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
                // Param scope already pushed; body shares it (no extra scope). Collect function-scoped `var` bindings now so they shadow imports for the whole body, including references that appear before the declarator.
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
                if (!pending_named_expr_bindings.empty()) {
                    addBindings({pending_named_expr_bindings.back()});
                    pending_named_expr_bindings.pop_back();
                }
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
                            // Unbraced loop body may be `if`/`try`; keep header scope through else/catch/finally.
                            if (!statementContinuesAfter(i + 1)) {
                                for_scope_pop_at_stmt_depth.pop_back();
                                popScope();
                            }
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
            // Object literal / class-body / binding computed key: rewrite the interior as an expression (imports), not as bindings.
            if (!cont.empty() && (cont.back() == Cont::ObjectLit || cont.back() == Cont::ClassBody)) {
                char prev = 0;
                size_t pk = out.size();
                while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
                if (pk > 0) prev = out[pk - 1];
                // Key position after `{` / `,` / class ASI `;`/`}` / `*` (generator) — not after `:` (nested array binding).
                if (prev == '{' || prev == ',' ||
                    (cont.back() == Cont::ClassBody && (prev == ';' || prev == '}' || prev == '*'))) {
                    out.push_back('[');
                    size_t es = 0, ee = 0;
                    if (!takeBalancedBracketExpr(src, i, es, ee)) {
                        while (i < src.size()) out.push_back(src[i++]);
                        continue;
                    }
                    out += rewriteIdents(src.substr(es, ee - es), repl, scopes);
                    out.push_back(']');
                    continue;
                }
            }
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
                // Class fields/methods are often semicolon-separated; ASI also allows the next method key right after a preceding method's closing `}`.
                if (in_class && (bp == ';' || bp == '}')) return true;
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
            // `function` / `catch` introduce ParamList only as bare keywords — exclude member calls (`.catch(` / `.function(`).
            auto isBareParamIntroKeyword = [&](size_t end, const char *w) -> bool {
                if (!outEndsWithWord(end, w)) return false;
                size_t n = std::strlen(w);
                size_t before = end - n;
                while (before > 0 && std::isspace(static_cast<unsigned char>(out[before - 1]))) --before;
                if (before > 0 && out[before - 1] == '.') return false;
                return true;
            };
            if (opensForHead()) {
                // Loop-header lexical bindings (`let`/`const`) live in this scope until the loop body ends.
                kind = Cont::ForHead;
                pushScope();
            } else if (isBareParamIntroKeyword(pk2, "function") || isBareParamIntroKeyword(pk2, "catch") ||
                isBareParamIntroKeyword(pk, "function") || isBareParamIntroKeyword(pk, "catch") ||
                parenFollowedByArrow(i) || opensMethodParamList()) {
                kind = Cont::ParamList;
                pushFunctionScope();
                in_param_default = false;
                // Named function expression: bind the name in this function environment only.
                if ((isBareParamIntroKeyword(pk2, "function") || isBareParamIntroKeyword(pk, "function")) &&
                    !pending_named_expr_bindings.empty()) {
                    addBindings({pending_named_expr_bindings.back()});
                    pending_named_expr_bindings.pop_back();
                }
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
                // `if (cond); else …` / similar — defer until the continued statement ends.
                if (!statementContinuesAfter(i + 1)) {
                    for_scope_pop_at_stmt_depth.pop_back();
                    popScope();
                }
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

            // function / class: declaration names bind in the enclosing scope; expression names stay in their own environment.
            if ((id == "function" || id == "class") && (i == 0 || !isIdent(src[i - 1]))) {
                const bool is_expr = isFnOrClassExpressionContext();
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
                    if (is_expr) pending_named_expr_bindings.push_back(fname);
                    else addBindings({fname});
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
            //
            // `var` is function-scoped (or module-scoped): keep it active for the enclosing function, not the current block.
            if ((id == "const" || id == "let" || id == "var") && (i == 0 || !isIdent(src[i - 1]))) {
                out += id;
                i = j;
                auto names = collectDeclaratorBoundNames(src, i);
                if (id == "var") addVarBindings(names);
                else addBindings(names);
                // Nest stack distinguishes object vs array patterns so computed keys (`{[expr]: x}`) rewrite `expr`.
                std::vector<char> nest;
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
                    if (ch == '[') {
                        char prev = prevSignificantChar(src, i);
                        // Object-pattern computed key: rewrite the expression inside `[...]`, keep binding names untouched.
                        if (!nest.empty() && nest.back() == '{' && (prev == '{' || prev == ',')) {
                            out.push_back('[');
                            size_t es = 0, ee = 0;
                            if (!takeBalancedBracketExpr(src, i, es, ee)) {
                                // Unterminated: copy remaining raw.
                                while (i < src.size()) out.push_back(src[i++]);
                                break;
                            }
                            out += rewriteIdents(src.substr(es, ee - es), repl, scopes);
                            out.push_back(']');
                            continue;
                        }
                        nest.push_back('[');
                        out.push_back(src[i++]);
                        continue;
                    }
                    if (ch == '{' || ch == '(') {
                        nest.push_back(ch);
                        out.push_back(src[i++]);
                        continue;
                    }
                    if (ch == '}' || ch == ']' || ch == ')') {
                        if (!nest.empty()) nest.pop_back();
                        out.push_back(src[i++]);
                        continue;
                    }
                    // Declarator initializer (nest empty) or binding-pattern default (nest non-empty): rewrite imports in the expression.
                    if (ch == '=' &&
                        !(i + 1 < src.size() && (src[i + 1] == '>' || src[i + 1] == '=')) &&
                        !(i > 0 && (src[i - 1] == '=' || src[i - 1] == '!' || src[i - 1] == '<' ||
                                    src[i - 1] == '>' || src[i - 1] == '+' || src[i - 1] == '-' ||
                                    src[i - 1] == '*' || src[i - 1] == '/' || src[i - 1] == '%' ||
                                    src[i - 1] == '&' || src[i - 1] == '|' || src[i - 1] == '^'))) {
                        const bool pattern_default = !nest.empty();
                        out.push_back(src[i++]);
                        size_t is = i;
                        int d = 0;
                        while (i < src.size()) {
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
                            if (ic == '/' && canStartRegexLiteral(src.substr(0, i))) {
                                skipRegexLiteral(src, i);
                                continue;
                            }
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
                    if (ch == ';' && nest.empty()) { out.push_back(src[i++]); break; }
                    if (isIdentStart(ch)) {
                        size_t n = i + 1;
                        while (n < src.size() && isIdent(src[n])) ++n;
                        // for-of / for-in header boundary: leave `of`/`in` + iterable for the outer rewrite pass.
                        if (nest.empty()) {
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
                        // `=>` handler sets next_brace_is_fn_body; for expr body pop on `;` approx. Mark that an expression-body arrow owns this scope: handled when we see `=>` without `{` — pop at `;`/`,`/`)`/`}` depth 0 later via FnBody absence. Use a sticky flag: Reuse next_brace: if `=>` not followed by `{`, pop after copying arrow expr in `=>` handler.
                        continue;
                    }
                }
            }

            // ParamList / destructuring pattern under ParamList: do not rewrite. Bound names were already registered by collectParamListBoundNames when the ParamList opened — do not treat property keys (`{value: x}`) as additional bindings.
            //
            // Default-initializer expressions (after `=` until `,`/`)`) may reference imports — allow rewrite. Computed keys are rewritten via the Cont::ObjectLit `[` handler before this path.
            if (underParamList()) {
                char p = prevSignificant();
                if (p != '.' && p != '?') {
                    if (!in_param_default) {
                        out += id;
                        i = j;
                        continue;
                    }
                }
            }

            // Skip preceding // /* */ trivia so `obj./*c*/value` stays a member access (property name not rewritten as import).
            bool after_dot = false;
            bool after_question = false;
            if (!out.empty()) {
                char prev = prevSignificantSkippingComments(out, out.size());
                if (prev == '.') after_dot = true;
                if (prev == '?') after_question = true;
            }
            size_t k = j;
            // Property-boundary lookahead must ignore comments (`{value /*c*/}` / `{value /*c*/: x}`), not only whitespace.
            skipSpacesAndCommentsSrc(k);
            // Property keys are only excluded inside object literals; a following colon alone is also the consequent/alternate separator in `?:`.
            bool in_object_lit_for_key = !cont.empty() && cont.back() == Cont::ObjectLit;
            bool object_key = in_object_lit_for_key && !after_question && (k < src.size() && src[k] == ':' &&
                                                 !(k + 1 < src.size() && src[k + 1] == ':'));
            // Method / accessor keys (`value()`, `get value()`, `set value()`, `async value()`, `*value()`, class `static value()`) are names, not references.
            bool method_key = false;
            bool in_class_body_for_key = !cont.empty() && cont.back() == Cont::ClassBody;
            if (!after_dot && !after_question && (in_object_lit_for_key || in_class_body_for_key) &&
                k < src.size() && src[k] == '(') {
                // Skip // /* */ trivia so `{/*c*/ value(){…}}` still sees `{`/`,` as the method-key boundary.
                size_t pk = skipTriviaBackward(out, out.size());
                // Class ASI: a preceding method's `}` is a valid boundary for the next method key (no semicolon required).
                if (pk > 0 && (out[pk - 1] == '{' || out[pk - 1] == ',' || out[pk - 1] == '*' ||
                               (in_class_body_for_key && (out[pk - 1] == ';' || out[pk - 1] == '}')))) {
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
            // Labels live in a separate namespace from values: do not rewrite label declarations or `break`/`continue` label operands.
            bool label_operand = false;
            {
                size_t lpk = out.size();
                while (lpk > 0 && std::isspace(static_cast<unsigned char>(out[lpk - 1]))) --lpk;
                if (outEndsWithWord(lpk, "break") || outEndsWithWord(lpk, "continue")) label_operand = true;
            }
            // Recognize labels only at statement boundaries so ternary/expression operands (`1 + value : 0`) stay rewritten.
            bool label_decl = false;
            if (!after_dot && !in_object_lit_for_key && !label_operand) {
                size_t lk = j;
                skipSpacesAndCommentsSrc(lk);
                if (lk < src.size() && src[lk] == ':' && !(lk + 1 < src.size() && src[lk + 1] == ':')) {
                    size_t lpk = out.size();
                    while (lpk > 0 && std::isspace(static_cast<unsigned char>(out[lpk - 1]))) --lpk;
                    char p = lpk > 0 ? out[lpk - 1] : '\0';
                    bool at_stmt_boundary = (p == '\0' || p == ';' || p == '{' || p == '}' || p == ')' || p == ':');
                    if (!at_stmt_boundary && (outEndsWithWord(lpk, "else") || outEndsWithWord(lpk, "do")))
                        at_stmt_boundary = true;
                    // `case value:` is an expression operand, not a label declaration.
                    if (at_stmt_boundary && !outEndsWithWord(lpk, "case")) label_decl = true;
                }
            }
            auto it = repl.find(id);
            if (!after_dot && !object_key && !method_key && !label_decl && !label_operand && it != repl.end() && !isShadowed(id)) {
                // Shorthand only for ObjectLit property context — not arrays, args, or blocks.
                bool in_object_lit = !cont.empty() && cont.back() == Cont::ObjectLit;
                bool after_shorthand_intro = false;
                if (in_object_lit && !out.empty()) {
                    size_t pk = out.size();
                    // Backward skip of spaces + // and /* */ trivia so `({/*c*/ value})` still sees `{`/`,` (mirrors skipSpacesAndCommentsSrc).
                    while (pk > 0) {
                        if (std::isspace(static_cast<unsigned char>(out[pk - 1]))) { --pk; continue; }
                        if (pk >= 2 && out[pk - 2] == '*' && out[pk - 1] == '/') {
                            size_t q = pk - 2;
                            bool found = false;
                            while (q > 0) {
                                if (out[q - 1] == '/' && out[q] == '*') { pk = q - 1; found = true; break; }
                                --q;
                            }
                            if (!found) break;
                            continue;
                        }
                        // Line comment: if this line contains `//`, drop from that `//` through pk.
                        size_t line_start = pk;
                        while (line_start > 0 && out[line_start - 1] != '\n') --line_start;
                        size_t slash = std::string::npos;
                        for (size_t t = line_start; t + 1 < pk; ++t) {
                            if (out[t] == '/' && out[t + 1] == '/') { slash = t; break; }
                            if (out[t] == '/' && out[t + 1] == '*') break;
                        }
                        if (slash != std::string::npos) { pk = slash; continue; }
                        break;
                    }
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

// Split `left as right` where `as` is a keyword with arbitrary JS whitespace on either side (space/tab/newline). Returns false for a plain binding (no alias).
static bool splitAsAlias(const std::string &part, std::string &left, std::string &right) {
    size_t i = 0;
    while (i < part.size() && std::isspace(static_cast<unsigned char>(part[i]))) ++i;
    if (i >= part.size() || !isIdentStart(part[i])) return false;
    size_t left_start = i;
    while (i < part.size() && isIdent(part[i])) ++i;
    size_t left_end = i;
    while (i < part.size() && std::isspace(static_cast<unsigned char>(part[i]))) ++i;
    if (i + 2 > part.size() || part[i] != 'a' || part[i + 1] != 's') return false;
    if (i + 2 < part.size() && isIdent(part[i + 2])) return false;
    i += 2;
    while (i < part.size() && std::isspace(static_cast<unsigned char>(part[i]))) ++i;
    if (i >= part.size() || !isIdentStart(part[i])) return false;
    size_t right_start = i;
    while (i < part.size() && isIdent(part[i])) ++i;
    size_t right_end = i;
    while (i < part.size() && std::isspace(static_cast<unsigned char>(part[i]))) ++i;
    if (i != part.size()) return false;
    left.assign(part, left_start, left_end - left_start);
    right.assign(part, right_start, right_end - right_start);
    return true;
}

// Collect every identifier token in executable source (string/comment/regexp interiors blanked) so generated bindings can avoid collisions.
static void collectIdentTokens(const std::string &src, std::unordered_set<std::string> &out) {
    const std::string blanked = blankNonCode(src);
    for (size_t i = 0; i < blanked.size();) {
        if (isIdentStart(blanked[i])) {
            size_t j = i + 1;
            while (j < blanked.size() && isIdent(blanked[j])) ++j;
            out.insert(blanked.substr(i, j - i));
            i = j;
            continue;
        }
        ++i;
    }
}

static std::string allocFreshIdent(std::unordered_set<std::string> &used, const std::string &prefix) {
    for (int n = 0;; ++n) {
        std::string name = prefix + std::to_string(n);
        if (!used.count(name)) {
            used.insert(name);
            return name;
        }
    }
}

// Prefer `preferred` when free; otherwise append a decimal suffix until unused.
static std::string allocFreshIdentExact(std::unordered_set<std::string> &used, const std::string &preferred) {
    if (!used.count(preferred)) {
        used.insert(preferred);
        return preferred;
    }
    for (int n = 0;; ++n) {
        std::string name = preferred + std::to_string(n);
        if (!used.count(name)) {
            used.insert(name);
            return name;
        }
    }
}

// Skip string / template / comment starting at `i` (for balanced-bracket scanners).
static bool skipStringTemplateOrComment(const std::string &src, size_t &i) {
    if (i >= src.size()) return false;
    char ch = src[i];
    if (ch == '/' && i + 1 < src.size() && src[i + 1] == '/') {
        i += 2;
        while (i < src.size() && src[i] != '\n') ++i;
        return true;
    }
    if (ch == '/' && i + 1 < src.size() && src[i + 1] == '*') {
        i += 2;
        while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
        if (i + 1 < src.size()) i += 2;
        return true;
    }
    if (ch == '\'' || ch == '"' || ch == '`') {
        char q = ch; ++i;
        while (i < src.size()) {
            if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
            if (q == '`' && src[i] == '$' && i + 1 < src.size() && src[i + 1] == '{') {
                i += 2; int nd = 1;
                while (i < src.size() && nd > 0) {
                    if (src[i] == '\'' || src[i] == '"' || src[i] == '`') {
                        // Nested quotes inside ${}: reuse this helper via a local scan of quotes only for depth bookkeeping of braces.
                        char nq = src[i]; ++i;
                        while (i < src.size()) {
                            if (src[i] == '\\' && i + 1 < src.size()) { i += 2; continue; }
                            if (src[i] == nq) { ++i; break; }
                            ++i;
                        }
                        continue;
                    }
                    if (src[i] == '{') ++nd;
                    else if (src[i] == '}') --nd;
                    ++i;
                }
                continue;
            }
            if (src[i] == q) { ++i; break; }
            ++i;
        }
        return true;
    }
    return false;
}


// Skip whitespace / line+block comments (not strings — string keys stay visible to the binding scanner).
static void skipWsAndComments(const std::string &src, size_t &i) {
    while (i < src.size()) {
        if (std::isspace(static_cast<unsigned char>(src[i]))) { ++i; continue; }
        if (src[i] == '/' && skipStringTemplateOrComment(src, i)) continue;
        break;
    }
}

// Position after dropping trailing spaces and // /* */ trivia before `pos` (so `{/*c*/ id` / `obj./*c*/id` still see `{` / `.`).
static size_t skipTriviaBackward(const std::string &src, size_t pos) {
    size_t pk = pos;
    while (pk > 0) {
        if (std::isspace(static_cast<unsigned char>(src[pk - 1]))) { --pk; continue; }
        if (pk >= 2 && src[pk - 2] == '*' && src[pk - 1] == '/') {
            size_t q = pk - 2;
            bool found = false;
            while (q > 0) {
                if (src[q - 1] == '/' && src[q] == '*') { pk = q - 1; found = true; break; }
                --q;
            }
            if (!found) break;
            continue;
        }
        // Line comment: drop from `//` through end-of-line trivia ending at pk.
        size_t line_start = pk;
        while (line_start > 0 && src[line_start - 1] != '\n') --line_start;
        size_t slash = std::string::npos;
        for (size_t t = line_start; t + 1 < pk; ++t) {
            if (src[t] == '/' && src[t + 1] == '/') { slash = t; break; }
            if (src[t] == '/' && src[t + 1] == '*') break;
        }
        if (slash != std::string::npos) { pk = slash; continue; }
        break;
    }
    return pk;
}

static char prevSignificantSkippingComments(const std::string &src, size_t pos) {
    size_t pk = skipTriviaBackward(src, pos);
    return pk > 0 ? src[pk - 1] : 0;
}

// True when `prev` can end an AssignmentExpression primary/postfix (ident, number, string/template close, )/]).
static bool tokenCanEndAssignmentExpr(char prev) {
    if (!prev) return false;
    if (isIdent(prev) || std::isdigit(static_cast<unsigned char>(prev))) return true;
    return prev == ')' || prev == ']' || prev == '}' || prev == '"' || prev == '\'' || prev == '`';
}

// `++` / `--` immediately before `linebreak_pos` (optional spaces) applied postfix to a prior ends-expr token.
static bool atPostfixIncDecBefore(const std::string &src, size_t linebreak_pos) {
    size_t p = linebreak_pos;
    while (p > 0 && std::isspace(static_cast<unsigned char>(src[p - 1])) && src[p - 1] != '\n' && src[p - 1] != '\r')
        --p;
    if (p < 2) return false;
    char a = src[p - 2], b = src[p - 1];
    if (!((a == '+' && b == '+') || (a == '-' && b == '-'))) return false;
    char before = prevSignificantSkippingComments(src, p - 2);
    return tokenCanEndAssignmentExpr(before);
}

// After a LineTerminator at declarator depth 0, true when the next token continues the AssignmentExpression (no ASI).
static bool canContinueExprAfterLineBreak(const std::string &src, size_t i) {
    if (i >= src.size()) return false;
    char c = src[i];
    if (c == '.' || c == '(' || c == '[' || c == '`' || c == ',' || c == ';' ||
        c == '+' || c == '-' || c == '*' || c == '/' || c == '%' || c == '^' || c == '&' || c == '|' ||
        c == '?' || c == ':' || c == '=' || c == '<' || c == '>' || c == '!' || c == '~')
        return true;
    auto atWord = [&](const char *w) -> bool {
        size_t n = std::strlen(w);
        if (i + n > src.size()) return false;
        if (src.compare(i, n, w) != 0) return false;
        if (i + n < src.size() && isIdent(src[i + n])) return false;
        return true;
    };
    return atWord("in") || atWord("instanceof");
}

// Parse `{…}` import/export specifier list into (left, right) pairs (`name` or `left as right`); skip // /* */ trivia so comments are not part of binding names.
static void collectAsAliasSpecs(const std::string &specs, std::vector<std::pair<std::string, std::string>> &out) {
    size_t i = 0;
    while (i < specs.size()) {
        skipWsAndComments(specs, i);
        if (i >= specs.size()) break;
        if (specs[i] == ',') { ++i; continue; }
        if (!isIdentStart(specs[i])) { ++i; continue; }
        size_t left_start = i;
        while (i < specs.size() && isIdent(specs[i])) ++i;
        std::string left = specs.substr(left_start, i - left_start);
        skipWsAndComments(specs, i);
        if (i + 2 <= specs.size() && specs[i] == 'a' && specs[i + 1] == 's' &&
            (i + 2 == specs.size() || !isIdent(specs[i + 2]))) {
            i += 2;
            skipWsAndComments(specs, i);
            if (i < specs.size() && isIdentStart(specs[i])) {
                size_t right_start = i;
                while (i < specs.size() && isIdent(specs[i])) ++i;
                out.emplace_back(left, specs.substr(right_start, i - right_start));
                continue;
            }
        }
        out.emplace_back(left, left);
    }
}

// Skip whitespace / commas / comments between binding-pattern elements.
static void skipPatternSeparators(const std::string &src, size_t &i) {
    while (i < src.size()) {
        if (std::isspace(static_cast<unsigned char>(src[i])) || src[i] == ',') { ++i; continue; }
        if (src[i] == '/' && skipStringTemplateOrComment(src, i)) continue;
        break;
    }
}

// `i` at `[`; on success leaves `i` past matching `]`, sets expr_start/expr_end to the interior.
static bool takeBalancedBracketExpr(const std::string &src, size_t &i, size_t &expr_start, size_t &expr_end) {
    if (i >= src.size() || src[i] != '[') return false;
    ++i;
    expr_start = i;
    int d = 1;
    while (i < src.size() && d > 0) {
        if (skipStringTemplateOrComment(src, i)) continue;
        char ch = src[i];
        if (ch == '[') { ++d; ++i; continue; }
        if (ch == ']') {
            --d;
            if (d == 0) { expr_end = i; ++i; return true; }
            ++i;
            continue;
        }
        ++i;
    }
    return false;
}

static char prevSignificantChar(const std::string &src, size_t pos) {
    size_t p = pos;
    while (p > 0) {
        --p;
        unsigned char c = static_cast<unsigned char>(src[p]);
        if (!std::isspace(c)) return static_cast<char>(c);
    }
    return 0;
}

// Collect bound names from a binding pattern (`ident`, `{a, b: c}`, `[x, ...y]`); skip comment trivia so comment identifiers are not treated as extra bindings.
static void collectPatternBoundNames(const std::string &src, size_t &i, std::vector<std::string> &names) {
    skipWsAndComments(src, i);
    if (i >= src.size()) return;
    if (src[i] == '{') {
        ++i;
        while (i < src.size()) {
            skipPatternSeparators(src, i);
            if (i >= src.size()) return;
            if (src[i] == '}') { ++i; return; }
            if (src[i] == '.' && i + 2 < src.size() && src[i + 1] == '.' && src[i + 2] == '.') {
                i += 3;
                skipWsAndComments(src, i);
                size_t j = i;
                while (j < src.size() && isIdent(src[j])) ++j;
                if (j > i) names.push_back(src.substr(i, j - i));
                i = j;
                continue;
            }
            if (src[i] == '[') {
                // Computed key `[expr]: binding` — do not collect names from expr; collect the binding after `:`.
                size_t save = i;
                size_t es = 0, ee = 0;
                if (!takeBalancedBracketExpr(src, i, es, ee)) return;
                (void)es; (void)ee;
                skipWsAndComments(src, i);
                if (i < src.size() && src[i] == ':') {
                    ++i;
                    collectPatternBoundNames(src, i, names);
                    skipWsAndComments(src, i);
                    if (i < src.size() && src[i] == '=') {
                        ++i;
                        int depth = 0;
                        while (i < src.size()) {
                            if (skipStringTemplateOrComment(src, i)) continue;
                            char ch = src[i];
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
                // Nested array pattern (not a computed key).
                i = save;
                collectPatternBoundNames(src, i, names);
                skipWsAndComments(src, i);
                if (i < src.size() && src[i] == '=') {
                    ++i;
                    int depth = 0;
                    while (i < src.size()) {
                        if (skipStringTemplateOrComment(src, i)) continue;
                        char ch = src[i];
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
            if (src[i] == '{') {
                collectPatternBoundNames(src, i, names);
                skipWsAndComments(src, i);
                if (i < src.size() && src[i] == '=') {
                    ++i;
                    int depth = 0;
                    while (i < src.size()) {
                        if (skipStringTemplateOrComment(src, i)) continue;
                        char ch = src[i];
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
            skipWsAndComments(src, i);
            if (i < src.size() && src[i] == ':') {
                ++i;
                collectPatternBoundNames(src, i, names);
                // Renamed binding may carry a default (`{x: y = value}`); skip it like shorthand/computed-key branches so initializer idents are not collected as locals.
                skipWsAndComments(src, i);
                if (i < src.size() && src[i] == '=') {
                    ++i;
                    int depth = 0;
                    while (i < src.size()) {
                        if (skipStringTemplateOrComment(src, i)) continue;
                        char ch = src[i];
                        if (ch == '{' || ch == '[' || ch == '(') { ++depth; ++i; continue; }
                        if (ch == '}' || ch == ']' || ch == ')') {
                            if (depth == 0) break;
                            --depth; ++i; continue;
                        }
                        if (depth == 0 && (ch == ',' || ch == '}')) break;
                        ++i;
                    }
                }
            } else {
                names.push_back(first);
                if (i < src.size() && src[i] == '=') {
                    ++i;
                    int depth = 0;
                    while (i < src.size()) {
                        if (skipStringTemplateOrComment(src, i)) continue;
                        char ch = src[i];
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
            skipPatternSeparators(src, i);
            if (i >= src.size()) return;
            if (src[i] == ']') { ++i; return; }
            if (src[i] == '.' && i + 2 < src.size() && src[i + 1] == '.' && src[i + 2] == '.') {
                i += 3;
                skipWsAndComments(src, i);
                size_t j = i;
                while (j < src.size() && isIdent(src[j])) ++j;
                if (j > i) names.push_back(src.substr(i, j - i));
                i = j;
                continue;
            }
            collectPatternBoundNames(src, i, names);
            skipWsAndComments(src, i);
            if (i < src.size() && src[i] == '=') {
                ++i;
                int depth = 0;
                while (i < src.size()) {
                    if (skipStringTemplateOrComment(src, i)) continue;
                    char ch = src[i];
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
        skipWsAndComments(src, i);
        if (i >= src.size() || src[i] == ';') break;
        collectPatternBoundNames(src, i, names);
        skipWsAndComments(src, i);
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
                if (ch == '/' && canStartRegexLiteral(src.substr(0, i))) {
                    skipRegexLiteral(src, i);
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
                    if (depth > 0) --depth;
                    ++i; continue;
                }
                // ASI: semicolon-free `export const a=1\nexport const b=2,c=3` must end the first declaration before the next statement.
                if (depth == 0 && (ch == '\n' || ch == '\r')) {
                    char prev = prevSignificantSkippingComments(src, i);
                    bool ended = tokenCanEndAssignmentExpr(prev) || atPostfixIncDecBefore(src, i);
                    if (ended) {
                        size_t la = i + 1;
                        if (ch == '\r' && la < src.size() && src[la] == '\n') ++la;
                        skipWsAndComments(src, la);
                        if (!canContinueExprAfterLineBreak(src, la)) break;
                    }
                    ++i;
                    continue;
                }
                if (depth == 0 && (ch == ',' || ch == ';')) break;
                ++i;
            }
        }
        skipWsAndComments(src, i);
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
                if (ch == '/' && canStartRegexLiteral(src.substr(0, i))) {
                    skipRegexLiteral(src, i);
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
        // Member access / method call: obj.import(...) is not dynamic import(). Skip // and /* */ trivia so `obj./*c*/import("dep")` stays a member call.
        if (i > 0 && prevSignificantSkippingComments(src, i) == '.') return false;

        size_t k = i + 6;
        while (k < src.size() && std::isspace(static_cast<unsigned char>(src[k]))) ++k;

        // import.meta
        if (k + 4 < src.size() && src[k] == '.' && src.compare(k + 1, 4, "meta") == 0 &&
            (k + 5 >= src.size() || !isIdent(src[k + 5]))) {
            out += std::string("(") + kWrapImportMeta + ")";
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
        out += std::string("Promise.resolve().then(function(){ return ") + kWrapRequire + "(";
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


// ESM namespace export: getter-only live forwarding, non-configurable once published. Local updates stay visible; importer writes fail (no namespace setter; defineProperty overwrite rejected).
static std::string exportLiveGetter(const std::string &exported, const std::string &expr) {
    return std::string(kWrapDefineProperty) + "(" + kWrapExports + ",\"" + exported +
           "\",{enumerable:true,configurable:false,get:function(){return " + expr + ";}});";
}

// Named `export {…} from`: live getter plus leaf origin `{m: moduleNs, b: bindingName}` so diamond star-reexports stay unambiguous only when both module identity and binding name match.
static std::string exportNamedReexport(const std::string &exported, const std::string &ns,
                                       const std::string &imported) {
    std::string out = exportLiveGetter(exported, ns + "." + imported);
    out += std::string("if(!") + kWrapObject + ".prototype.hasOwnProperty.call(" + kWrapExports +
           ",\"__jsbay_star_origin\"))" + kWrapDefineProperty + "(" + kWrapExports +
           ",\"__jsbay_star_origin\",{value:" + kWrapObject + ".create(null),configurable:true});";
    // Prefer a chained leaf origin; otherwise this named re-export is the leaf (module + imported binding).
    out += std::string(kWrapExports) + ".__jsbay_star_origin[\"" + exported + "\"]=(" + ns +
           ".__jsbay_star_origin&&" + kWrapObject + ".prototype.hasOwnProperty.call(" + ns +
           ".__jsbay_star_origin,\"" + imported + "\"))?" + ns + ".__jsbay_star_origin[\"" + imported +
           "\"]:{m:" + ns + ",b:\"" + imported + "\"};";
    return out;
}

// Very small ESM→CJS transform covering modules_tests fixtures.
static std::string transformEsmToCjs(const std::string &src, const std::string &filename) {
    (void)filename;
    // Seed reserved names from the original module so generated bindings (__jsbay_ns*, __default_export, …) cannot collide with user declarations.
    std::unordered_set<std::string> used_idents;
    collectIdentTokens(src, used_idents);
    for (const char *r : {kWrapExports, kWrapRequire, kWrapModule, kWrapFilename, kWrapDirname, kWrapImportMeta, kWrapObject,
                          kWrapDefineProperty})
        used_idents.insert(r);
    std::string body = rewriteImportMetaAndDynamic(src);
    std::vector<ImportBinding> imports;
    std::vector<std::string> prelude;
    std::vector<std::string> epilogue;
    // Function-declaration export getters (incl. default function) publish before the dependency prelude so cyclic importers see hoisted bindings during evaluation, matching native ESM instantiation order.
    std::vector<std::string> hoisted_exports;

    // Strip/collect import declarations (multi-form). Process repeatedly.
    auto eatImports = [&]() {
        // Match on source after skipLeadingTrivia so `/* header */ import …` is consumed; keep leading trivia in `body`.
        static const std::regex import_side(R"(^\s*import\s+(['\"])([^'\"]+)\1\s*;?\s*)");
        static const std::regex import_default(
            R"(^\s*import\s+([A-Za-z_$][\w$]*)\s+from\s+(['\"])([^'\"]+)\2\s*;?\s*)");
        static const std::regex import_ns(
            R"(^\s*import\s+\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+(['\"])([^'\"]+)\2\s*;?\s*)");
        static const std::regex import_named(
            R"(^\s*import\s*\{([^}]*)\}\s*from\s+(['\"])([^'\"]+)\2\s*;?\s*)");
        static const std::regex import_def_named(
            R"(^\s*import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]*)\}\s*from\s+(['\"])([^'\"]+)\3\s*;?\s*)");
        // Combined default + namespace: `import main, * as ns from 'dep'`.
        static const std::regex import_def_ns(
            R"(^\s*import\s+([A-Za-z_$][\w$]*)\s*,\s*\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+(['\"])([^'\"]+)\3\s*;?\s*)");

        bool changed = true;
        while (changed) {
            changed = false;
            const size_t lead = skipLeadingTrivia(body);
            const std::string rest = body.substr(lead);
            auto consume_match = [&](const std::smatch &m) {
                body = body.substr(0, lead) + rest.substr(m.length());
                changed = true;
            };
            std::smatch m;
            if (std::regex_search(rest, m, import_def_ns) && m.position() == 0) {
                imports.push_back({m[1].str(), "default", m[4].str()});
                imports.push_back({m[2].str(), ".", m[4].str()});
                consume_match(m);
                continue;
            }
            if (std::regex_search(rest, m, import_def_named) && m.position() == 0) {
                imports.push_back({m[1].str(), "default", m[4].str()});
                std::string specs = m[2].str();
                std::vector<std::pair<std::string, std::string>> parts;
                collectAsAliasSpecs(specs, parts);
                for (const auto &pr : parts)
                    imports.push_back({pr.second, pr.first, m[4].str()});
                consume_match(m);
                continue;
            }
            if (std::regex_search(rest, m, import_named) && m.position() == 0) {
                std::string specs = m[1].str();
                std::vector<std::pair<std::string, std::string>> parts;
                collectAsAliasSpecs(specs, parts);
                // `import {} from 'dep'` still evaluates the dependency (side effects / missing module).
                if (parts.empty())
                    imports.push_back({"", "", m[3].str()});
                else {
                    for (const auto &pr : parts)
                        imports.push_back({pr.second, pr.first, m[3].str()});
                }
                consume_match(m);
                continue;
            }
            if (std::regex_search(rest, m, import_ns) && m.position() == 0) {
                imports.push_back({m[1].str(), ".", m[3].str()});
                consume_match(m);
                continue;
            }
            if (std::regex_search(rest, m, import_default) && m.position() == 0) {
                imports.push_back({m[1].str(), "default", m[3].str()});
                consume_match(m);
                continue;
            }
            if (std::regex_search(rest, m, import_side) && m.position() == 0) {
                imports.push_back({"", "", m[2].str()}); // side-effect
                consume_match(m);
                continue;
            }
            // Also allow imports after newlines, same-line statements (`;`), or a closed declaration block (`}`): search next top-level import on blankNonCode so commented-out `import` is ignored; mutate live body at those offsets.
            static const std::regex any_import(R"((^|[\n;}])(\s*import\s))");
            {
                std::string blanked = blankNonCode(body);
                if (std::regex_search(blanked, m, any_import)) {
                    size_t start = m.position() + (m[1].matched ? m[1].length() : 0);
                    if (start > 0) {
                        // Move the complete import declaration (not just the first line) to the front.
                        std::string tail = body.substr(start);
                        std::smatch im;
                        size_t decl_len = 0;
                        if (std::regex_search(tail, im, import_def_ns) && im.position() == 0)
                            decl_len = im.length();
                        else if (std::regex_search(tail, im, import_def_named) && im.position() == 0)
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
        static const std::regex re_imp_def_ns(
            R"(import\s+[A-Za-z_$][\w$]*\s*,\s*\*\s+as\s+[A-Za-z_$][\w$]*\s+from\s*(['"])([^'"]+)\1)");
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
        collect_re(re_imp_def_ns, false, 2);
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
    //
    // Process named and star re-exports left-to-right so prelude require order matches source order.
    //
    // Each entry is (module, require-line); merged with ordinary imports by static_dep_occs source order below.
    std::vector<std::pair<std::string, std::string>> reexport_prelude;
    std::vector<std::string> star_reexport_nss;
    std::vector<std::string> post_epilogue;
    {
        static const std::regex re_named(R"(export\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\2\s*;?)");
        // Optional `as name` covers `export * as ns from 'dep'` (namespace re-export); bare `export * from` stays a star re-export.
        static const std::regex re_star(R"(export\s*\*\s*(?:as\s+([A-Za-z_$][\w$]*)\s+)?from\s*(['"])([^'"]+)\2\s*;?)");
        for (;;) {
            std::string blanked = blankNonCode(body);
            std::smatch m_named, m_star;
            bool has_named = std::regex_search(blanked, m_named, re_named);
            bool has_star = std::regex_search(blanked, m_star, re_star);
            if (!has_named && !has_star) break;
            const bool take_star = has_star && (!has_named || m_star.position() < m_named.position());
            if (take_star) {
                // Group 1 = optional namespace export name; group 3 = module specifier (quote is group 2).
                std::string mod = body.substr(m_star.position(3), m_star.length(3));
                std::string ns = allocFreshIdent(used_idents, "__jsbay_re");
                reexport_prelude.push_back({mod, "var " + ns + " = " + std::string(kWrapRequire) + "(\"" + mod + "\");"});
                if (m_star[1].matched) {
                    // `export * as ns from 'dep'`: expose the dependency namespace under `ns`, do not flatten star bindings.
                    std::string as_name = body.substr(m_star.position(1), m_star.length(1));
                    body.replace(m_star.position(), m_star.length(), exportLiveGetter(as_name, ns));
                } else {
                    star_reexport_nss.push_back(ns);
                    body.replace(m_star.position(), m_star.length(), "");
                }
            } else {
                // Specs / module from the blanked match spans on the live body (same offsets).
                std::string specs = body.substr(m_named.position(1), m_named.length(1));
                std::string mod = body.substr(m_named.position(3), m_named.length(3));
                std::string ns = allocFreshIdent(used_idents, "__jsbay_re");
                reexport_prelude.push_back({mod, "var " + ns + " = " + std::string(kWrapRequire) + "(\"" + mod + "\");"});
                std::string repl;
                std::vector<std::pair<std::string, std::string>> parts;
                collectAsAliasSpecs(specs, parts);
                for (const auto &pr : parts)
                    repl += exportNamedReexport(pr.second, ns, pr.first);
                body.replace(m_named.position(), m_named.length(), repl);
            }
        }
    }

    // export default ...
    {
        // Optional `async` and generator `*` must be recognized before the name so anonymous defaults keep `async function*` (not `function __default_export*`). Keyword boundaries: `(?![\w$])` after `function`/`class` so identifiers like `functionCall` / `classFactory` stay default-expression exports.
        static const std::regex re_fn(R"(export\s+default\s+(async\s+)?function(?![\w$])(\s*\*)?\s*([A-Za-z_$][\w$]*)?)");
        // Do not treat `extends` as an anonymous default class name (`export default class extends Base {}`).
        static const std::regex re_class(R"(export\s+default\s+class(?![\w$])(?:\s+(?!extends\b)([A-Za-z_$][\w$]*))?)");
        std::smatch m;
        std::string blanked = blankNonCode(body);
        if (std::regex_search(blanked, m, re_fn)) {
            std::string async_kw = m[1].matched ? body.substr(m.position(1), m.length(1)) : "";
            std::string star = m[2].matched ? body.substr(m.position(2), m.length(2)) : "";
            std::string name = m[3].matched ? body.substr(m.position(3), m.length(3))
                                            : allocFreshIdentExact(used_idents, "__default_export");
            if (!m[3].matched) {
                body.replace(m.position(), m.length(), async_kw + "function" + star + " " + name);
            } else {
                // Strip the matched `export`…`default`… prefix by its actual length (whitespace may span lines); leave `async`/`function`/name in place.
                std::string matched = blanked.substr(m.position(0), m.length(0));
                size_t rel = m[1].matched ? matched.find("async") : matched.find("function");
                size_t cut = (rel == std::string::npos) ? m.length(0) : rel;
                body.replace(m.position(), cut, "");
            }
            hoisted_exports.push_back(exportLiveGetter("default", name));
        } else if (std::regex_search(blanked = blankNonCode(body), m, re_class)) {
            // Keep a module-scoped class declaration (named or synthetic) so local refs resolve; publish via getter.
            std::string name = m[1].matched ? body.substr(m.position(1), m.length(1))
                                            : allocFreshIdentExact(used_idents, "__default_export");
            if (!m[1].matched) {
                body.replace(m.position(), m.length(), "class " + name);
            } else {
                // Strip the matched `export`…`default`… prefix by its actual length; leave `class Name` in place.
                std::string matched = blanked.substr(m.position(0), m.length(0));
                size_t rel = matched.find("class");
                size_t cut = (rel == std::string::npos) ? m.length(0) : rel;
                body.replace(m.position(), cut, "");
            }
            epilogue.push_back(exportLiveGetter("default", name));
        } else {
            static const std::regex re_def(R"(export\s+default\s+)");
            blanked = blankNonCode(body);
            if (std::regex_search(blanked, m, re_def)) {
                // Store the expression in an internal binding and expose a read-only live export (native ESM semantics).
                std::string def_bind = allocFreshIdentExact(used_idents, "__jsbay_default");
                body.replace(m.position(), m.length(), "var " + def_bind + " = ");
                epilogue.push_back(exportLiveGetter("default", def_bind));
            }
        }
    }

    // export class Name (named declaration; default class handled above). Reject `extends` as a false name.
    {
        static const std::regex re(R"(export\s+class\s+(?!extends\b)([A-Za-z_$][\w$]*))");
        std::smatch m;
        std::string tmp = body;
        std::string blanked = blankNonCode(tmp);
        body.clear();
        size_t last = 0;
        while (std::regex_search(blanked.cbegin() + last, blanked.cend(), m, re)) {
            size_t pos = last + m.position();
            body.append(tmp, last, pos - last);
            std::string name = m[1].str();
            body += "class " + name;
            epilogue.push_back(exportLiveGetter(name, name));
            last = pos + m.length();
        }
        body.append(tmp, last, std::string::npos);
    }

    // export [async] function name (including generators: preserve optional `async` and `*`)
    {
        static const std::regex re(R"(export\s+(async\s+)?function(\s*\*)?\s*([A-Za-z_$][\w$]*))");
        std::smatch m;
        std::string tmp = body;
        std::string blanked = blankNonCode(tmp);
        body.clear();
        size_t last = 0;
        while (std::regex_search(blanked.cbegin() + last, blanked.cend(), m, re)) {
            size_t pos = last + m.position();
            body.append(tmp, last, pos - last);
            std::string async_kw = m[1].matched ? m[1].str() : "";
            std::string star = m[2].matched ? m[2].str() : "";
            std::string name = m[3].str();
            body += async_kw + "function" + star + " " + name;
            hoisted_exports.push_back(exportLiveGetter(name, name));
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

    // Allocate import namespace locals before local `export {…}` so imported bindings can publish leaf provenance for diamond star-merge.
    std::unordered_map<std::string, std::string> mod_to_ns;
    std::unordered_map<std::string, std::string> import_require_line;
    for (auto &ib : imports) {
        if (ib.module.empty()) continue;
        if (!mod_to_ns.count(ib.module)) {
            std::string ns = allocFreshIdent(used_idents, "__jsbay_ns");
            mod_to_ns[ib.module] = ns;
            import_require_line[ib.module] = "var " + ns + " = " + std::string(kWrapRequire) + "(\"" + ib.module + "\");";
        }
    }
    // local name → (nsVar, importedBinding) for ordinary named/default imports (not namespace objects).
    std::unordered_map<std::string, std::pair<std::string, std::string>> import_local_origin;
    for (auto &ib : imports) {
        if (ib.local.empty() || ib.module.empty() || ib.imported == ".") continue;
        if (!import_local_origin.count(ib.local))
            import_local_origin.emplace(ib.local, std::make_pair(mod_to_ns[ib.module], ib.imported));
    }

    // export { a, b as c }; — require a non-identifier boundary so names like `__default_export {}` are not eaten.
    {
        static const std::regex re(R"((^|[^\w$])export\s*\{([^}]*)\}\s*;?)");
        std::smatch m;
        for (;;) {
            std::string blanked = blankNonCode(body);
            if (!std::regex_search(blanked, m, re)) break;
            std::string prefix = m[1].str(); // start-of-string or the boundary char
            std::string specs = body.substr(m.position(2), m.length(2));
            std::string repl;
            std::vector<std::pair<std::string, std::string>> parts;
            collectAsAliasSpecs(specs, parts);
            for (const auto &pr : parts) {
                const std::string &local = pr.first;
                const std::string &exported = pr.second;
                auto origin = import_local_origin.find(local);
                if (origin != import_local_origin.end())
                    // Carry the imported binding's leaf provenance through local export lists (import-then-export diamond).
                    repl += exportNamedReexport(exported, origin->second.first, origin->second.second);
                else
                    repl += exportLiveGetter(exported, local);
            }
            body.replace(m.position(), m.length(), prefix + repl);
        }
    }

    // Build require prelude + live import bindings.
    //
    // Ordinary imports and re-export dependencies share one source-ordered static dependency prelude (native ESM init order).
    std::unordered_map<std::string, std::string> ident_repl;
    for (auto &ib : imports) {
        if (ib.module.empty() || ib.local.empty()) continue; // side-effect only
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

    // Star re-exports: compare leaf origins `{m,b}` (module identity + binding name) for ambiguity, but read values from the immediate star source namespace so renamed named re-exports (`export {original as renamed}`) stay reachable under the export name. Omit ambiguous names unless an explicit export already resolved them; record leaf origins on this module for further star re-exports.
    if (!star_reexport_nss.empty()) {
        std::string star_prov = allocFreshIdentExact(used_idents, "__jsbay_star_prov");
        std::string star_ns_map = allocFreshIdentExact(used_idents, "__jsbay_star_ns");
        std::string star;
        star += "var " + star_prov + "=" + kWrapObject + ".create(null);";
        star += "var " + star_ns_map + "=" + kWrapObject + ".create(null);";
        star += std::string("if(!") + kWrapObject + ".prototype.hasOwnProperty.call(" + kWrapExports + ",\"__jsbay_star_origin\"))";
        star += std::string(kWrapDefineProperty) + "(" + kWrapExports + ",\"__jsbay_star_origin\",{value:" + kWrapObject + ".create(null),configurable:true});";
        for (const auto &ns : star_reexport_nss) {
            star += std::string(kWrapObject) + ".keys(" + ns + ").forEach(function(k){";
            star += "if(k===\"default\"||k===\"__jsbay_star_origin\")return;";
            star += std::string("var __jsbay_origin=(") + ns + ".__jsbay_star_origin&&" + kWrapObject + ".prototype.hasOwnProperty.call(" + ns + ".__jsbay_star_origin,k))?" + ns + ".__jsbay_star_origin[k]:{m:" + ns + ",b:k};";
            star += std::string("if(") + kWrapObject + ".prototype.hasOwnProperty.call(" + star_prov + ",k)){";
            star += "if(" + star_prov + "[k]==null||" + star_prov + "[k].m!==__jsbay_origin.m||" + star_prov + "[k].b!==__jsbay_origin.b){" + star_prov + "[k]=null;" + star_ns_map + "[k]=null;}";
            star += "}else{" + star_prov + "[k]=__jsbay_origin;" + star_ns_map + "[k]=" + ns + ";}});";
        }
        star += std::string(kWrapObject) + ".keys(" + star_prov + ").forEach(function(k){";
        star += "var __jsbay_src=" + star_prov + "[k];";
        star += "var __jsbay_lookup=" + star_ns_map + "[k];";
        star += "if(__jsbay_src==null)return;";
        star += std::string("if(") + kWrapObject + ".prototype.hasOwnProperty.call(" + kWrapExports + ",k))return;";
        star += std::string(kWrapDefineProperty) + "(" + kWrapExports + ",k,{enumerable:true,configurable:false,get:function(){return __jsbay_lookup[k];}});";
        star += std::string(kWrapExports) + ".__jsbay_star_origin[k]=__jsbay_src;";
        star += "});";
        post_epilogue.push_back(star);
    }

    body = rewriteIdents(body, ident_repl);

    // Pass pristine Object as a factory param (not a body `var`) so a module-local `const Object` TDZ cannot break capture.
    std::string out = std::string("(async function(") + kWrapExports + "," + kWrapRequire + "," +
        kWrapModule + "," + kWrapFilename + "," + kWrapDirname + "," + kWrapImportMeta + "," +
        kWrapObject +
        "){\n\"use strict\";\n";
    out += std::string("var ") + kWrapDefineProperty + "=" + kWrapObject + ".defineProperty.bind(" + kWrapObject + ");\n";
    for (auto &e : hoisted_exports) out += e + "\n";
    for (auto &p : prelude) out += p + "\n";
    out += body;
    out += "\n";
    for (auto &e : epilogue) out += e + "\n";
    for (auto &e : post_epilogue) out += e + "\n";
    // Non-thenable completion: returning the namespace would assimilate an export named `then` and hang awaitThenable.
    out += "return undefined;\n})";
    return out;
}

extern "C" char *hermes_esm_transform_source(const char *src, size_t src_len, const char *filename) {
    if (!src) return nullptr;
    std::string out = transformEsmToCjs(std::string(src, src_len), filename ? filename : "<transform>");
    return dupCStringLocal(out);
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

    // Drain microtasks and pump host tasks (timers / native / host scripts) so TLA can await setTimeout and similar macrotasks.
    for (int i = 0; i < 100000 && !box->done; ++i) {
        hermes_context_drain_microtasks(c);
        if (box->done) break;
        hermes_context_pump_host_tasks(c);
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
            importMeta,
            rt.global().getProperty(rt, "Object"));
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
                importMeta,
                rt.global().getProperty(rt, "Object"));
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
