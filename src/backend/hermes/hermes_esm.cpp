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
    if (prev == ')' || prev == ']' || prev == '"' || prev == '\'' || prev == '`') return false;

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
    auto pushScope = [&]() { scopes.emplace_back(); };
    auto popScope = [&]() {
        if (scopes.size() > 1) scopes.pop_back();
    };

    // Container stack: ObjectLit vs Block vs Bracket vs Paren/ParamList.
    enum class Cont : uint8_t { ObjectLit, Block, Bracket, Paren, ParamList, FnBody };
    std::vector<Cont> cont;
    // When a ParamList `)` is followed by `{`, the next `{` is FnBody and pops the param scope on `}`.
    bool next_brace_is_fn_body = false;

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
            if (*it == Cont::FnBody || *it == Cont::Block) return false;
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
            } else if (prevIsObjectLitIntro()) {
                kind = Cont::ObjectLit;
            } else {
                kind = Cont::Block;
                pushScope();
            }
            cont.push_back(kind);
            out.push_back(src[i++]);
            continue;
        }
        if (c == '}') {
            if (!cont.empty()) {
                Cont kind = cont.back();
                cont.pop_back();
                if (kind == Cont::Block) {
                    popScope();
                } else if (kind == Cont::FnBody) {
                    // End of function/catch body — drop the ParamList scope.
                    popScope();
                }
            }
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
            if (outEndsWithWord(pk2, "function") || outEndsWithWord(pk2, "catch") ||
                outEndsWithWord(pk, "function") || outEndsWithWord(pk, "catch")) {
                kind = Cont::ParamList;
                pushScope();
            }
            cont.push_back(kind);
            out.push_back(src[i++]);
            continue;
        }
        if (c == ')') {
            bool was_param = !cont.empty() && cont.back() == Cont::ParamList;
            if (!cont.empty() && (cont.back() == Cont::Paren || cont.back() == Cont::ParamList))
                cont.pop_back();
            out.push_back(src[i++]);
            if (was_param) {
                size_t k = i;
                skipSpacesSrc(k);
                if (k < src.size() && src[k] == '{') {
                    next_brace_is_fn_body = true;
                } else if (k + 1 < src.size() && src[k] == '=' && src[k + 1] == '>') {
                    // Arrow expression body: keep param scope until approximate end.
                    next_brace_is_fn_body = false;
                    // If `=> {` then brace handler; if `=> expr` pop at `;` loosely below.
                } else {
                    popScope();
                }
            }
            continue;
        }

        // Arrow `=>` with block body after a non-paren single-param: `value => ...`
        if (c == '=' && i + 1 < src.size() && src[i + 1] == '>') {
            out.push_back(src[i++]);
            out.push_back(src[i++]);
            size_t k = i;
            skipSpacesSrc(k);
            if (k < src.size() && src[k] == '{') {
                // Single-param arrow: binding was already added when we saw the ident before `=>`.
                next_brace_is_fn_body = true;
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
                continue;
            }

            // const / let / var — register declarator bindings; rewrite only initializer expressions.
            if ((id == "const" || id == "let" || id == "var") && (i == 0 || !isIdent(src[i - 1]))) {
                out += id;
                i = j;
                auto names = collectDeclaratorBoundNames(src, i);
                addBindings(names);
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
                    if (ch == '=' && depth == 0) {
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
                            if (ic == '}' || ic == ']' || ic == ')') { if (d > 0) --d; ++i; continue; }
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
                    (cont.empty() || cont.back() == Cont::Block || cont.back() == Cont::FnBody ||
                     cont.back() == Cont::Paren || cont.back() == Cont::ObjectLit ||
                     cont.back() == Cont::Bracket)) {
                    char p = prevSignificant();
                    // Only treat as param if not a call/member and looks like expression start.
                    if (p != '.' && p != '?' && !isIdent(p) && p != ')' && p != ']') {
                        pushScope();
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
            if (underParamList()) {
                char p = prevSignificant();
                if (p != '.' && p != '?') {
                    // After `=` inside params this is a default-value reference — allow rewrite/shadow check.
                    if (p != '=') {
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
            bool object_key = !after_question && (k < src.size() && src[k] == ':' &&
                                                 !(k + 1 < src.size() && src[k + 1] == ':'));
            // Method / accessor keys (`value()`, `get value()`, `set value()`, `async value()`, `*value()`) are names, not references.
            bool method_key = false;
            if (!after_dot && !after_question && !cont.empty() && cont.back() == Cont::ObjectLit &&
                k < src.size() && src[k] == '(') {
                size_t pk = out.size();
                while (pk > 0 && std::isspace(static_cast<unsigned char>(out[pk - 1]))) --pk;
                if (pk > 0 && (out[pk - 1] == '{' || out[pk - 1] == ',' || out[pk - 1] == '*')) {
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
                    if (prev_word == "get" || prev_word == "set" || prev_word == "async")
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

        // Expression-body arrows keep param scopes open after `=>` without `{`; this rewriter does not pop those scopes at depth-0 `;` / `,` / `)` / `}`, so identifier replacement can miss or over-apply inside expression-arrow bodies.

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
                while (pos < specs.size()) {
                    size_t comma = specs.find(',', pos);
                    std::string part = trim(specs.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos));
                    if (!part.empty()) {
                        auto as_pos = part.find(" as ");
                        if (as_pos != std::string::npos)
                            imports.push_back({trim(part.substr(as_pos + 4)), trim(part.substr(0, as_pos)), m[3].str()});
                        else
                            imports.push_back({part, part, m[3].str()});
                    }
                    if (comma == std::string::npos) break;
                    pos = comma + 1;
                }
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
    eatImports();

    // export { a, b as c } from 'mod';
    {
        static const std::regex re(R"(export\s*\{([^}]*)\}\s*from\s*(['\"])([^'\"]+)\2\s*;?)");
        std::smatch m;
        for (;;) {
            std::string blanked = blankNonCode(body);
            if (!std::regex_search(blanked, m, re)) break;
            // Specs / module from the blanked match spans on the live body (same offsets).
            std::string specs = body.substr(m.position(1), m.length(1));
            std::string mod = body.substr(m.position(3), m.length(3));
            static int reexport_ns = 0;
            std::string ns = "__jsbay_re" + std::to_string(reexport_ns++);
            std::string repl = "var " + ns + " = require(\"" + mod + "\");";
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
            body.replace(m.position(), m.length(), repl);
        }
    }

    // export * from 'mod';
    {
        static const std::regex re(R"(export\s*\*\s*from\s*(['\"])([^'\"]+)\1\s*;?)");
        for (;;) {
            std::string blanked = blankNonCode(body);
            std::smatch m;
            if (!std::regex_search(blanked, m, re)) break;
            std::string mod = body.substr(m.position(2), m.length(2));
            // Live bindings via getters; exclude default per ExportEntriesFromModule.
            std::string repl =
                "(function(__jsbay_star){Object.keys(__jsbay_star).forEach(function(k){"
                "if(k===\"default\"||Object.prototype.hasOwnProperty.call(exports,k))return;"
                "Object.defineProperty(exports,k,{enumerable:true,configurable:true,"
                "get:function(){return __jsbay_star[k];}});});})(require(\"" +
                mod + "\"));";
            body.replace(m.position(), m.length(), repl);
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

    // Build require prelude + live import bindings
    std::unordered_map<std::string, std::string> ident_repl;
    int ns_i = 0;
    std::unordered_map<std::string, std::string> mod_to_ns;
    for (auto &ib : imports) {
        if (ib.module.empty()) continue;
        if (!mod_to_ns.count(ib.module)) {
            std::string ns = "__jsbay_ns" + std::to_string(ns_i++);
            mod_to_ns[ib.module] = ns;
            prelude.push_back("var " + ns + " = require(\"" + ib.module + "\");");
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

    body = rewriteIdents(body, ident_repl);

    std::string out = "(async function(exports,require,module,__filename,__dirname,__jsbay_import_meta){\n\"use strict\";\n";
    for (auto &p : prelude) out += p + "\n";
    out += body;
    out += "\n";
    for (auto &e : epilogue) out += e + "\n";
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
        // Ensure a loader exists for require during entry. makeRequire closures capture the
        // loader pointer, so it must outlive this stack frame (heap / context map).
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
