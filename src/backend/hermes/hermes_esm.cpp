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

static bool isIdentStart(char c) {
    return std::isalpha(static_cast<unsigned char>(c)) || c == '_' || c == '$';
}
static bool isIdent(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '$';
}

// Skip strings/comments roughly; return rewritten source with identifier replacements.
static std::string rewriteIdents(const std::string &src,
                                 const std::unordered_map<std::string, std::string> &repl) {
    if (repl.empty()) return src;
    std::string out;
    out.reserve(src.size() + 32);
    size_t i = 0;
    while (i < src.size()) {
        char c = src[i];
        // line comment
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '/') {
            while (i < src.size() && src[i] != '\n') out.push_back(src[i++]);
            continue;
        }
        // block comment
        if (c == '/' && i + 1 < src.size() && src[i + 1] == '*') {
            out.push_back(src[i++]);
            out.push_back(src[i++]);
            while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) out.push_back(src[i++]);
            if (i < src.size()) out.push_back(src[i++]);
            if (i < src.size()) out.push_back(src[i++]);
            continue;
        }
        // strings
        if (c == '\'' || c == '"' || c == '`') {
            char q = c;
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
            continue;
        }
        if (isIdentStart(c)) {
            // Only rewrite free identifier references — not object keys or member names after `.`.
            bool after_dot = false;
            if (!out.empty()) {
                size_t k = out.size();
                while (k > 0 && std::isspace(static_cast<unsigned char>(out[k - 1]))) --k;
                if (k > 0 && out[k - 1] == '.') after_dot = true;
            }
            size_t j = i + 1;
            while (j < src.size() && isIdent(src[j])) ++j;
            size_t k = j;
            while (k < src.size() && std::isspace(static_cast<unsigned char>(src[k]))) ++k;
            // Object-literal key `ident:` (but not `ident::` labels / TypeScript).
            bool object_key = (k < src.size() && src[k] == ':' && !(k + 1 < src.size() && src[k + 1] == ':'));
            std::string id = src.substr(i, j - i);
            auto it = repl.find(id);
            if (!after_dot && !object_key && it != repl.end())
                out += it->second;
            else
                out += id;
            i = j;
            continue;
        }
        out.push_back(c);
        ++i;
    }
    return out;
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

// Very small ESM→CJS transform covering modules_tests fixtures.
static std::string transformEsmToCjs(const std::string &src, const std::string &filename) {
    (void)filename;
    std::string body = src;
    std::vector<ImportBinding> imports;
    std::vector<std::string> prelude;
    std::vector<std::string> epilogue;

    // import.meta → (__jsbay_import_meta)
    {
        static const std::regex meta_re(R"(import\.meta)");
        body = std::regex_replace(body, meta_re, "(__jsbay_import_meta)");
    }

    // dynamic import('x', { with: ... }) → readable reject (no import-attributes surface).
    // Match any two-arg import(... , ...) so nested { type: 'json' } braces are covered.
    {
        static const std::regex dyn_attr_re(
            R"(import\s*\(\s*(['\"])([^'\"]+)\1\s*,\s*[^)]+\))");
        body = std::regex_replace(
            body, dyn_attr_re,
            "Promise.reject(new Error(\"import attributes not supported\"))");
    }
    // dynamic import('x') → Promise.resolve().then(function(){ return require('x'); })
    {
        static const std::regex dyn_re(R"(import\s*\(\s*(['\"])([^'\"]+)\1\s*\))");
        body = std::regex_replace(
            body, dyn_re,
            "Promise.resolve().then(function(){ return require($1$2$1); })");
    }

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
            // Also allow imports after newlines mid-file: search next import at line start
            static const std::regex any_import(R"((^|\n)(\s*import\s))");
            if (std::regex_search(body, m, any_import)) {
                size_t start = m.position() + (m[1].matched ? m[1].length() : 0);
                if (start > 0) {
                    // Move that import to front by rotating — simpler: extract line
                    size_t line_end = body.find('\n', start);
                    std::string line = body.substr(start, line_end == std::string::npos ? std::string::npos : line_end - start + (line_end == std::string::npos ? 0 : 1));
                    // If line looks like import, cut and prepend processing
                    if (line.find("import") != std::string::npos) {
                        body.erase(start, line.size());
                        body = line + body;
                        changed = true;
                        continue;
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
        while (std::regex_search(body, m, re)) {
            std::string specs = m[1].str();
            std::string mod = m[3].str();
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
                    repl += "Object.defineProperty(exports,\"" + exported +
                            "\",{enumerable:true,configurable:true,get:function(){return require(\"" + mod +
                            "\")." + imported + ";}});";
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
        body = std::regex_replace(
            body, re,
            "Object.assign(exports, require(\"$2\"));");
    }

    // export default ...
    {
        static const std::regex re_fn(R"(export\s+default\s+function\s*([A-Za-z_$][\w$]*)?)");
        std::smatch m;
        if (std::regex_search(body, m, re_fn)) {
            std::string name = m[1].matched ? m[1].str() : "__default_export";
            if (!m[1].matched) {
                body.replace(m.position(), m.length(), "function " + name);
            } else {
                body.replace(m.position(), std::strlen("export default "), "");
            }
            epilogue.push_back("exports.default = " + name + ";");
        } else {
            static const std::regex re_def(R"(export\s+default\s+)");
            if (std::regex_search(body, m, re_def)) {
                body.replace(m.position(), m.length(), "exports.default = ");
            }
        }
    }

    // export function name
    {
        static const std::regex re(R"(export\s+function\s+([A-Za-z_$][\w$]*))");
        std::smatch m;
        std::string tmp = body;
        body.clear();
        size_t last = 0;
        while (std::regex_search(tmp.cbegin() + last, tmp.cend(), m, re)) {
            size_t pos = last + m.position();
            body.append(tmp, last, pos - last);
            std::string name = m[1].str();
            body += "function " + name;
            epilogue.push_back("Object.defineProperty(exports,\"" + name +
                               "\",{enumerable:true,configurable:true,get:function(){return " + name +
                               ";},set:function(v){" + name + "=v;}});");
            last = pos + m.length();
        }
        body.append(tmp, last, std::string::npos);
    }

    // export const/let/var name = ...
    {
        static const std::regex re(R"(export\s+(const|let|var)\s+)");
        std::smatch m;
        while (std::regex_search(body, m, re)) {
            // Find binding names until '=' or ',' chain — simplified: single name
            size_t start = m.position() + m.length();
            size_t i = start;
            while (i < body.size() && isIdent(body[i])) ++i;
            std::string name = body.substr(start, i - start);
            body.replace(m.position(), m.length(), std::string(m[1]) + " ");
            if (!name.empty()) {
                epilogue.push_back("Object.defineProperty(exports,\"" + name +
                                   "\",{enumerable:true,configurable:true,get:function(){return " + name +
                                   ";},set:function(v){" + name + "=v;}});");
            }
        }
    }

    // export { a, b as c };
    {
        static const std::regex re(R"(export\s*\{([^}]*)\}\s*;?)");
        std::smatch m;
        while (std::regex_search(body, m, re)) {
            std::string specs = m[1].str();
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
                    repl += "Object.defineProperty(exports,\"" + exported +
                            "\",{enumerable:true,configurable:true,get:function(){return " + local +
                            ";},set:function(v){" + local + "=v;}});";
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
            ident_repl[ib.local] = "(" + ns + ".default!==undefined?" + ns + ".default:" + ns + ")";
        } else {
            ident_repl[ib.local] = ns + "." + ib.imported;
        }
    }

    body = rewriteIdents(body, ident_repl);

    std::string out = "(async function(exports,require,module,__filename,__dirname,__jsbay_import_meta){\n\"use strict\";\n";
    for (auto &p : prelude) out += p + "\n";
    out += body;
    out += "\n";
    for (auto &e : epilogue) out += e + "\n";
    out += "return exports;\n})";
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
    HermesEvalResult out{nullptr, nullptr};
    if (!c || !hermes_context_rt(c) || !src) {
        out.err = dupCStringLocal("invalid context");
        return out;
    }
    HermesModLoader *loader = getLoader(c);
    // Allow eval without loader when source has no imports — still run through transform.
    std::string fname(filename ? filename : "", filename_len);
    if (fname.empty()) fname = "<module>";
    std::string source(src, src_len);
    try {
        auto &rt = *hermes_context_rt(c);
        // Ensure a loader exists for require during entry. makeRequire closures capture the
        // loader pointer, so it must outlive this stack frame (heap / context map).
        HermesModLoader *use = loader;
        if (!use) {
            auto owned = std::make_unique<HermesModLoader>();
            use = owned.get();
            std::lock_guard<std::mutex> lock(g_mod_mu);
            g_mod_loaders.emplace(c, std::move(owned));
        }
        // Entry: register synthetic module under filename, evaluate
        auto rec = std::make_shared<HermesModuleRecord>(HermesModuleRecord{jsi::Object(rt), true, false});
        use->cache[fname] = rec;
        std::string wrapped = transformEsmToCjs(source, fname);
        auto factory = rt.evaluateJavaScript(std::make_shared<jsi::StringBuffer>(wrapped), fname);
        if (!factory.isObject() || !factory.getObject(rt).isFunction(rt)) {
            out.err = dupCStringLocal("module factory is not a function");
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
        }
        rec->loading = false;
        rec->ready = true;
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const jsi::JSError &e) {
        out.err = dupCStringLocal(e.getMessage());
        hermes_report_unhandled_rejection(c, e.getMessage().c_str());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const std::exception &e) {
        out.err = dupCStringLocal(e.what());
        hermes_report_unhandled_rejection(c, e.what());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (...) {
        out.err = dupCStringLocal("module evaluation error");
        hermes_report_unhandled_rejection(c, "module evaluation error");
        hermes_context_drain_microtasks(c);
        return out;
    }
}

extern "C" HermesEvalResult hermes_import_module(JsbayHermesContext *c, const char *specifier) {
    HermesEvalResult out{nullptr, nullptr};
    if (!c || !hermes_context_rt(c) || !specifier) {
        out.err = dupCStringLocal("invalid context");
        return out;
    }
    HermesModLoader *loader = getLoader(c);
    if (!loader || !loader->load) {
        out.err = dupCStringLocal("no module loader configured");
        return out;
    }
    try {
        auto &rt = *hermes_context_rt(c);
        std::string id = resolveId(loader, "", specifier);
        loadAndEvalModule(c, loader, rt, id);
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const jsi::JSError &e) {
        out.err = dupCStringLocal(e.getMessage());
        hermes_report_unhandled_rejection(c, e.getMessage().c_str());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (const std::exception &e) {
        out.err = dupCStringLocal(e.what());
        hermes_report_unhandled_rejection(c, e.what());
        hermes_context_drain_microtasks(c);
        return out;
    } catch (...) {
        out.err = dupCStringLocal("module import failed");
        hermes_report_unhandled_rejection(c, "module import failed");
        hermes_context_drain_microtasks(c);
        return out;
    }
}
