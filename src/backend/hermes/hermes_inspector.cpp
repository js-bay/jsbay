#include "hermes_bridge.h"

#include <cassert>
#include <chrono>
#include <condition_variable>
#include <hermes/cdp/CDPAgent.h>
#include <hermes/cdp/CDPDebugAPI.h>

#ifndef HERMES_ENABLE_DEBUGGER
#error "hermes_inspector.cpp requires a debugger-enabled Hermes SDK"
#endif

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace jsi = facebook::jsi;
using FbHermesRuntime = facebook::hermes::HermesRuntime;
using namespace facebook::hermes;

extern "C" FbHermesRuntime *hermes_context_runtime_for_inspector(JsbayHermesContext *);
extern "C" void hermes_context_set_inspector(JsbayHermesContext *, JsbayHermesInspector *);
extern "C" JsbayHermesInspector *hermes_context_get_inspector(JsbayHermesContext *);

constexpr size_t kMaxOutboundMessages = 256;
constexpr size_t kMaxPendingLargeRequests = 16;
constexpr size_t kDefaultMaxOutboundMessageBytes = 64 << 20;
constexpr size_t kDefaultMaxOutboundBacklogBytes = 8 << 20;

struct JsbayHermesInspector;
struct SourceTicket {
    std::string source;
    std::unordered_set<std::string> existing_script_ids;
    bool consumed = false;
};
thread_local JsbayHermesInspector *active_source_inspector = nullptr;
thread_local std::shared_ptr<SourceTicket> active_queued_source_ticket;
thread_local JsbayHermesInspector *active_enqueue_inspector = nullptr;
thread_local bool active_enqueue_failed = false;
struct SourceRequestScope {
    JsbayHermesInspector *previous_inspector = active_source_inspector;
    std::shared_ptr<SourceTicket> previous_ticket = std::move(active_queued_source_ticket);

    SourceRequestScope(JsbayHermesInspector *inspector, std::shared_ptr<SourceTicket> ticket) {
        active_source_inspector = inspector;
        active_queued_source_ticket = std::move(ticket);
    }
    ~SourceRequestScope() {
        active_source_inspector = previous_inspector;
        active_queued_source_ticket = std::move(previous_ticket);
    }
};
static void sourceTicketBegin(JsbayHermesInspector *inspector,
                              const std::shared_ptr<SourceTicket> &ticket);
static void sourceTicketEnd(JsbayHermesInspector *inspector,
                            const std::shared_ptr<SourceTicket> &ticket);

struct RuntimeTaskBox {
    debugger::RuntimeTask task;
    FbHermesRuntime *runtime;
    JsbayHermesInspector *inspector;
    std::shared_ptr<SourceTicket> source_ticket;
};

static void runRuntimeTask(void *opaque) {
    std::unique_ptr<RuntimeTaskBox> box(static_cast<RuntimeTaskBox *>(opaque));
    try {
        sourceTicketBegin(box->inspector, box->source_ticket);
        box->task(*box->runtime);
        sourceTicketEnd(box->inspector, box->source_ticket);
    } catch (...) {
        sourceTicketEnd(box->inspector, box->source_ticket);
    }
}

static void cancelRuntimeTask(void *opaque) {
    delete static_cast<RuntimeTaskBox *>(opaque);
}

struct JsbayHermesInspector;
static std::mutex g_live_inspectors_mutex;
static std::unordered_set<JsbayHermesInspector *> g_live_inspectors;

struct JsbayHermesInspector {
    JsbayHermesInspector(JsbayHermesContext *c = nullptr, FbHermesRuntime *r = nullptr,
                         int32_t id = 0, HermesInspectorEmitFn em = nullptr,
                         HermesInspectorCloseFn cl = nullptr, HermesInspectorEnqueueFn enq = nullptr,
                         HermesInspectorParseFn p = nullptr, void *u = nullptr)
        : context(c), runtime(r), instance_id(id), emit(em), close(cl),
          enqueue(enq), parse(p), user_data(u) {
        std::lock_guard<std::mutex> lock(g_live_inspectors_mutex);
        g_live_inspectors.insert(this);
    }
    ~JsbayHermesInspector() {
        std::lock_guard<std::mutex> lock(g_live_inspectors_mutex);
        g_live_inspectors.erase(this);
    }

    JsbayHermesContext *context = nullptr;
    FbHermesRuntime *runtime = nullptr;
    int32_t instance_id = 0;
    HermesInspectorEmitFn emit = nullptr;
    HermesInspectorCloseFn close = nullptr;
    HermesInspectorEnqueueFn enqueue = nullptr;
    HermesInspectorParseFn parse = nullptr;
    void *user_data = nullptr;
    std::unique_ptr<cdp::CDPDebugAPI> debug_api;
    std::mutex mutex;
    struct Metadata {
        std::mutex mutex;
        std::unordered_set<long long> debugger_enable_ids;
        std::unordered_set<long long> runtime_enable_ids;
        bool execution_context_sent = false;
        bool terminal = false;
        bool terminal_close_sent = false;
    };
    struct Session {
        std::shared_ptr<cdp::CDPAgent> agent;
        std::shared_ptr<Metadata> metadata;
    };
    std::unordered_map<uint64_t, std::shared_ptr<Session>> sessions;
    std::mutex command_mutex;
    std::mutex source_mutex;
    std::shared_ptr<SourceTicket> active_source_ticket;
    std::unordered_map<std::string, std::shared_ptr<const std::string>> script_sources;
    std::deque<std::string> script_source_order;
    size_t script_source_bytes = 0;
    struct PendingLargeSource {
        long long id;
        std::shared_ptr<const std::string> source;
    };
    struct OutboundMessage {
        uint64_t session_id;
        std::string json;
        std::optional<long long> response_id;
        size_t charged_bytes = 0;
        uint64_t delivery_token = 0;
        std::shared_ptr<const std::string> pending_source;
    };
    struct OutboundState {
        size_t bytes = 0;
        size_t messages = 0;
        bool large_message_in_flight = false;
        uint64_t large_message_seq = 0;
        std::deque<PendingLargeSource> pending_large;
    };
    std::mutex outbound_mutex;
    std::condition_variable outbound_cv;
    std::deque<OutboundMessage> outbound;
    std::unordered_map<uint64_t, OutboundState> outbound_sessions;
    uint64_t outbound_sequence = 0;
    uint64_t terminal_generation = 0;
    bool terminal_pending = false;
    bool outbound_open = true;
    std::thread outbound_sender;
    size_t max_outbound_message_bytes = kDefaultMaxOutboundMessageBytes;
    size_t max_outbound_backlog_bytes = kDefaultMaxOutboundBacklogBytes;
    std::atomic<bool> delivery_observed{false};
    bool closing = false;
    bool stopped = false;
};

struct EnqueueFailureScope {
    JsbayHermesInspector *previous_inspector = active_enqueue_inspector;
    bool previous_failed = active_enqueue_failed;

    explicit EnqueueFailureScope(JsbayHermesInspector *inspector) {
        active_enqueue_inspector = inspector;
        active_enqueue_failed = false;
    }
    ~EnqueueFailureScope() {
        active_enqueue_inspector = previous_inspector;
        active_enqueue_failed = previous_failed;
    }
    bool failed() const {
        return active_enqueue_failed;
    }
};

static void discardOutboundSession(JsbayHermesInspector *inspector, uint64_t session_id) {
    std::lock_guard<std::mutex> lock(inspector->outbound_mutex);
    auto state = inspector->outbound_sessions.find(session_id);
    if (state == inspector->outbound_sessions.end())
        return;
    for (auto it = inspector->outbound.begin(); it != inspector->outbound.end();) {
        if (it->session_id == session_id)
            it = inspector->outbound.erase(it);
        else
            ++it;
    }
    inspector->outbound_sessions.erase(state);
}

static uint64_t reserveLargeMessage(JsbayHermesInspector *inspector,
                                    JsbayHermesInspector::OutboundState &state) {
    ++inspector->outbound_sequence;
    if (inspector->outbound_sequence == 0)
        ++inspector->outbound_sequence;
    state.large_message_seq = inspector->outbound_sequence;
    state.large_message_in_flight = true;
    return state.large_message_seq;
}

static void releaseLargeMessage(JsbayHermesInspector *inspector, uint64_t session_id,
                                uint64_t delivery_token) {
    if (delivery_token == 0)
        return;
    bool terminalize = false;
    {
        std::lock_guard<std::mutex> lock(inspector->outbound_mutex);
        const auto it = inspector->outbound_sessions.find(session_id);
        if (it == inspector->outbound_sessions.end() ||
            it->second.large_message_seq != delivery_token)
            return;
        it->second.large_message_in_flight = false;
        if (!it->second.pending_large.empty()) {
            const auto &next = it->second.pending_large.front();
            const uint64_t next_seq = reserveLargeMessage(inspector, it->second);
            try {
                inspector->outbound.push_back({session_id, "", next.id, 0, next_seq, next.source});
                it->second.pending_large.pop_front();
                it->second.messages += 1;
                inspector->outbound_cv.notify_one();
            } catch (...) {
                it->second.large_message_in_flight = false;
                terminalize = true;
            }
        }
    }
    if (terminalize)
        terminalizeSession(inspector, session_id);
}

static std::optional<size_t> escapedJsonLen(const std::string &s) noexcept {
    size_t len = 2; // surrounding quotes
    for (unsigned char c : s) {
        size_t add = 1;
        switch (c) {
        case '"':
        case '\\':
        case '\b':
        case '\f':
        case '\n':
        case '\r':
        case '\t':
            add = 2;
            break;
        default:
            if (c <= 0x1f) {
                add = 6;
            }
            break;
        }
        if (__builtin_add_overflow(len, add, &len))
            return std::nullopt;
    }
    return len;
}

static void appendJsonQuoted(std::string &out, const std::string &value) {
    out.push_back('\"');
    static constexpr char hex[] = "0123456789abcdef";
    for (unsigned char c : value) {
        switch (c) {
        case '\"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\b':
            out += "\\b";
            break;
        case '\f':
            out += "\\f";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (c <= 0x1f) {
                out += "\\u00";
                out.push_back(hex[c >> 4]);
                out.push_back(hex[c & 15]);
            } else {
                out.push_back(static_cast<char>(c));
            }
            break;
        }
    }
    out.push_back('\"');
}

// This only marks a terminal close. The separate sender calls the host without holding Hermes' outbound callback mutex, so releasing the last agent cannot recursively lock it.
static void terminalizeSession(JsbayHermesInspector *inspector, uint64_t session_id) {
    std::shared_ptr<JsbayHermesInspector::Metadata> metadata;
    {
        std::lock_guard<std::mutex> lock(inspector->mutex);
        const auto session = inspector->sessions.find(session_id);
        if (session == inspector->sessions.end())
            return;
        metadata = session->second->metadata;
    }
    {
        std::lock_guard<std::mutex> lock(metadata->mutex);
        if (metadata->terminal)
            return;
        metadata->terminal = true;
    }
    {
        std::lock_guard<std::mutex> lock(inspector->outbound_mutex);
        for (auto it = inspector->outbound.begin(); it != inspector->outbound.end();) {
            if (it->session_id == session_id)
                it = inspector->outbound.erase(it);
            else
                ++it;
        }
        inspector->outbound_sessions.erase(session_id);
        inspector->terminal_generation += 1;
        inspector->terminal_pending = true;
    }
    inspector->outbound_cv.notify_one();
}

// Metadata is created with the session, so terminal notification never needs to allocate after an error path. Claiming the flag makes a transport which reports close asynchronously receive only one close request.
static std::optional<uint64_t> takeTerminalSession(JsbayHermesInspector *inspector) {
    std::lock_guard<std::mutex> lock(inspector->mutex);
    for (const auto &[session_id, session] : inspector->sessions) {
        std::lock_guard<std::mutex> metadata_lock(session->metadata->mutex);
        if (session->metadata->terminal && !session->metadata->terminal_close_sent) {
            session->metadata->terminal_close_sent = true;
            return session_id;
        }
    }
    return std::nullopt;
}

static bool enqueueOutbound(JsbayHermesInspector *inspector, uint64_t session_id,
                            std::string json,
                            std::optional<long long> response_id = std::nullopt,
                            bool is_fallback = false,
                            uint64_t reserved_seq = 0) {
    bool close_session = false;
    try {
        std::shared_ptr<JsbayHermesInspector::Metadata> metadata;
        {
            std::lock_guard<std::mutex> lock(inspector->mutex);
            const auto session = inspector->sessions.find(session_id);
            if (session == inspector->sessions.end())
                return false;
            metadata = session->second->metadata;
        }
        std::lock_guard<std::mutex> metadata_lock(metadata->mutex);
        if (metadata->terminal)
            return false;
        std::lock_guard<std::mutex> outbound_lock(inspector->outbound_mutex);
        if (!inspector->outbound_open)
            return false;
        const size_t max_msg = inspector->max_outbound_message_bytes;
        const size_t max_backlog = inspector->max_outbound_backlog_bytes;
        if (json.size() > max_msg) {
            if (!response_id) {
                close_session = true;
            } else {
                char fallback[128];
                const int len = snprintf(fallback, sizeof(fallback),
                    "{\"id\":%lld,\"error\":{\"code\":-32000,\"message\":\"Message is too large\"}}",
                    *response_id);
                if (len <= 0 || static_cast<size_t>(len) >= sizeof(fallback) ||
                    static_cast<size_t>(len) > max_msg) {
                    close_session = true;
                } else {
                    std::string bounded_fallback(fallback, static_cast<size_t>(len));
                    json.swap(bounded_fallback);
                    is_fallback = true;
                }
            }
        }
        if (!close_session) {
            auto &state = inspector->outbound_sessions[session_id];
            const bool is_large = !is_fallback && json.size() > max_backlog;
            const size_t charged_bytes = (is_fallback || is_large) ? 0 : json.size();
            if (state.messages >= kMaxOutboundMessages) {
                close_session = true;
            } else if (charged_bytes > max_backlog || state.bytes > max_backlog - charged_bytes) {
                close_session = true;
            } else if (is_large && reserved_seq != 0 &&
                       (!state.large_message_in_flight || state.large_message_seq != reserved_seq)) {
                return false;
            } else if (is_large && reserved_seq == 0 && state.large_message_in_flight) {
                return false;
            } else {
                inspector->outbound.push_back({session_id, std::move(json), response_id,
                                               charged_bytes, reserved_seq});
                state.bytes += charged_bytes;
                state.messages += 1;
                if (is_large && reserved_seq == 0)
                    inspector->outbound.back().delivery_token = reserveLargeMessage(inspector, state);
                inspector->outbound_cv.notify_one();
                return true;
            }
        }
    } catch (...) {
        close_session = true;
    }
    if (close_session)
        terminalizeSession(inspector, session_id);
    return false;
}

static bool enqueueFallbackError(JsbayHermesInspector *inspector, uint64_t session_id,
                                 long long request_id, const char *message) {
    char fallback[192];
    const int len = snprintf(fallback, sizeof(fallback),
        "{\"id\":%lld,\"error\":{\"code\":-32000,\"message\":\"%s\"}}",
        request_id, message);
    if (len <= 0 || static_cast<size_t>(len) >= sizeof(fallback) ||
        static_cast<size_t>(len) > inspector->max_outbound_message_bytes) {
        return false;
    }
    try {
        return enqueueOutbound(inspector, session_id,
                               std::string(fallback, static_cast<size_t>(len)), request_id, true);
    } catch (...) {
        return false;
    }
}

static void runOutboundSender(JsbayHermesInspector *inspector) {
    for (;;) {
        try {
            JsbayHermesInspector::OutboundMessage message;
            uint64_t delivery_token = 0;
            {
                std::unique_lock<std::mutex> lock(inspector->outbound_mutex);
                inspector->outbound_cv.wait(lock, [inspector] {
                    return !inspector->outbound_open || inspector->terminal_pending ||
                           !inspector->outbound.empty();
                });
                if (!inspector->outbound_open)
                    return;
                if (inspector->terminal_pending) {
                    const uint64_t generation = inspector->terminal_generation;
                    lock.unlock();
                    if (const auto session_id = takeTerminalSession(inspector)) {
                        inspector->close(*session_id, inspector->user_data);
                    } else {
                        lock.lock();
                        if (inspector->terminal_generation == generation)
                            inspector->terminal_pending = false;
                    }
                    continue;
                }
                message = std::move(inspector->outbound.front());
                inspector->outbound.pop_front();
                const auto state = inspector->outbound_sessions.find(message.session_id);
                if (state != inspector->outbound_sessions.end()) {
                    if (state->second.bytes < message.charged_bytes || state->second.messages == 0) {
                        std::abort();
                    }
                    state->second.bytes -= message.charged_bytes;
                    state->second.messages -= 1;
                }
            }
            if (message.pending_source) {
                try {
                    const std::string id_str = std::to_string(*message.response_id);
                    const auto escaped_len = escapedJsonLen(*message.pending_source);
                    if (!escaped_len) throw std::bad_alloc();
                    constexpr size_t kEnvelopeFixed =
                        sizeof("{\"id\":") - 1 +
                        sizeof(",\"result\":{\"scriptSource\":") - 1 +
                        sizeof("}}") - 1;
                    message.json.reserve(*escaped_len + id_str.size() + kEnvelopeFixed);
                    message.json += "{\"id\":";
                    message.json += id_str;
                    message.json += ",\"result\":{\"scriptSource\":";
                    appendJsonQuoted(message.json, *message.pending_source);
                    message.json += "}}";
                    message.pending_source.reset();
                } catch (...) {
                    const auto rid = *message.response_id;
                    const auto token = message.delivery_token;
                    releaseLargeMessage(inspector, message.session_id, token);
                    if (!enqueueFallbackError(inspector, message.session_id, rid,
                                              "Unable to allocate script source response")) {
                        terminalizeSession(inspector, message.session_id);
                    }
                    continue;
                }
            }
            delivery_token = message.delivery_token;
            const bool emit_ok = inspector->emit(message.session_id, message.json.data(),
                                                 message.json.size(), delivery_token, inspector->user_data);
            if (delivery_token != 0 && (!emit_ok || !inspector->delivery_observed.load())) {
                releaseLargeMessage(inspector, message.session_id, delivery_token);
            }
            if (!emit_ok && message.response_id) {
                const auto rid = *message.response_id;
                message.json.clear();
                message.json.shrink_to_fit();
                char err_buf[128];
                const int n = snprintf(
                    err_buf, sizeof(err_buf),
                    "{\"id\":%lld,\"error\":{\"code\":-32000,\"message\":\"Inspector transport is busy or disconnected\"}}",
                    rid);
                bool fallback_ok = false;
                if (n > 0 && static_cast<size_t>(n) < sizeof(err_buf)) {
                    try {
                        if (static_cast<size_t>(n) <= inspector->max_outbound_message_bytes) {
                            fallback_ok = inspector->emit(message.session_id, err_buf,
                                                          static_cast<size_t>(n), 0, inspector->user_data);
                        }
                    } catch (...) {
                    }
                }
                if (!fallback_ok) {
                    terminalizeSession(inspector, message.session_id);
                }
            }
        } catch (...) {
        }
    }
}

static void sourceTicketBegin(JsbayHermesInspector *inspector,
                              const std::shared_ptr<SourceTicket> &ticket) {
    if (!ticket)
        return;
    for (const auto &script : inspector->runtime->getDebugger().getLoadedScripts())
        ticket->existing_script_ids.insert(std::to_string(script.fileId));
    std::lock_guard<std::mutex> lock(inspector->source_mutex);
    inspector->active_source_ticket = ticket;
}

static void sourceTicketEnd(JsbayHermesInspector *inspector,
                            const std::shared_ptr<SourceTicket> &ticket) {
    if (!ticket)
        return;
    std::lock_guard<std::mutex> lock(inspector->source_mutex);
    if (inspector->active_source_ticket == ticket)
        inspector->active_source_ticket.reset();
}

struct ParsedMessage {
    std::optional<long long> id;
    bool has_result = false;
    std::string method;
    std::string script_id;
    std::string expression;
    bool valid = true;
};
static void copyInfo(void *target, const HermesInspectorMessageInfo *info) noexcept {
    auto *out = static_cast<ParsedMessage *>(target);
    try {
        if (info->flags & 1)
            out->id = info->id;
        out->has_result = (info->flags & 2) != 0;
        if (info->method)
            out->method.assign(info->method, info->method_len);
        if (info->script_id)
            out->script_id.assign(info->script_id, info->script_id_len);
        if ((info->flags & 4) && info->expression)
            out->expression.assign(info->expression, info->expression_len);
    } catch (...) {
        out->valid = false;
    }
}
static std::optional<ParsedMessage> parseMessage(JsbayHermesInspector *inspector,
                                                 const std::string &json) {
    ParsedMessage out;
    return inspector->parse(json.data(), json.size(), copyInfo, &out) && out.valid
               ? std::optional<ParsedMessage>(std::move(out))
               : std::nullopt;
}

static std::string jsonQuote(const std::string &value) {
    std::string out;
    if (const auto len = escapedJsonLen(value)) {
        out.reserve(*len);
    }
    appendJsonQuoted(out, value);
    return out;
}

// enqueue owns task_data only after returning true; a false result leaves cleanup to this bridge.
static bool enqueueTask(JsbayHermesInspector *inspector, debugger::RuntimeTask task) {
    try {
        std::shared_ptr<SourceTicket> ticket;
        if (active_source_inspector == inspector) {
            ticket = std::move(active_queued_source_ticket);
            active_source_inspector = nullptr;
        }
        auto *box =
            new RuntimeTaskBox{std::move(task), inspector->runtime, inspector, std::move(ticket)};
        if (inspector->enqueue(runRuntimeTask, cancelRuntimeTask, box, inspector->user_data))
            return true;
        cancelRuntimeTask(box);
    } catch (...) {
    }
    if (active_enqueue_inspector == inspector)
        active_enqueue_failed = true;
    return false;
}

extern "C" JsbayHermesInspector *
hermes_inspector_start(JsbayHermesContext *ctx, int32_t instance_id, HermesInspectorEmitFn emit,
                       HermesInspectorCloseFn close, HermesInspectorEnqueueFn enqueue,
                       void *user_data, HermesInspectorParseFn parse,
                       size_t max_message_bytes, size_t max_backlog_bytes) {
    try {
        FbHermesRuntime *runtime = hermes_context_runtime_for_inspector(ctx);
        if (!runtime || !emit || !close || !enqueue || !parse)
            return nullptr;
        std::unique_ptr<JsbayHermesInspector> candidate(new JsbayHermesInspector{
            ctx, runtime, instance_id, emit, close, enqueue, parse, user_data});
        auto *inspector = candidate.get();
        inspector->max_outbound_message_bytes =
            max_message_bytes != 0 ? max_message_bytes : kDefaultMaxOutboundMessageBytes;
        inspector->max_outbound_backlog_bytes =
            max_backlog_bytes != 0 ? max_backlog_bytes : kDefaultMaxOutboundBacklogBytes;
        inspector->debug_api = cdp::CDPDebugAPI::create(*runtime);
        if (!inspector->debug_api)
            return nullptr;
        inspector->outbound_sender = std::thread(runOutboundSender, inspector);
        hermes_context_set_inspector(ctx, inspector);
        return candidate.release();
    } catch (...) {
        return nullptr;
    }
}

extern "C" bool hermes_inspector_session_open(JsbayHermesInspector *inspector,
                                              uint64_t session_id) {
    try {
        if (!inspector)
            return false;
        {
            std::lock_guard<std::mutex> lock(inspector->mutex);
            if (inspector->stopped || inspector->closing ||
                inspector->sessions.find(session_id) != inspector->sessions.end())
                return false;
        }
        auto session = std::make_shared<JsbayHermesInspector::Session>();
        session->metadata = std::make_shared<JsbayHermesInspector::Metadata>();
        auto enqueue = [inspector](debugger::RuntimeTask task) {
            (void)enqueueTask(inspector, std::move(task));
        };
        std::weak_ptr<JsbayHermesInspector::Metadata> weak_metadata = session->metadata;
        auto emit = [inspector, session_id, weak_metadata](const std::string &json) {
            try {
                std::string reply = json;
                const std::shared_ptr<JsbayHermesInspector::Metadata> metadata =
                    weak_metadata.lock();
                if (!metadata)
                    return;
                {
                    std::lock_guard<std::mutex> lock(metadata->mutex);
                    if (metadata->terminal)
                        return;
                }
                const auto object = parseMessage(inspector, reply);
                if (!object) {
                    terminalizeSession(inspector, session_id);
                    return;
                }
                const auto &id = object->id;
                bool send_context = false;
                if (id && object->has_result) {
                    std::lock_guard<std::mutex> lock(metadata->mutex);
                    if (metadata->debugger_enable_ids.erase(*id) != 0) {
                        reply = "{\"id\":" + std::to_string(*id) +
                                ",\"result\":{\"debuggerId\":\"jsbay-hermes-" +
                                std::to_string(inspector->instance_id) + "\"}}";
                    }
                    if (metadata->runtime_enable_ids.erase(*id) != 0 &&
                        !metadata->execution_context_sent) {
                        metadata->execution_context_sent = true;
                        send_context = true;
                    }
                } else if (object->method == "Debugger.scriptParsed") {
                    const auto &script_id = object->script_id;
                    if (!script_id.empty()) {
                        std::lock_guard<std::mutex> lock(inspector->source_mutex);
                        if (inspector->active_source_ticket &&
                            !inspector->active_source_ticket->consumed &&
                            !inspector->active_source_ticket->existing_script_ids.count(
                                script_id) &&
                            !inspector->script_sources.count(script_id)) {
                            inspector->active_source_ticket->consumed = true;
                            const size_t max_source_entry = inspector->max_outbound_message_bytes;
                            const size_t max_source_journal =
                                std::max<size_t>(inspector->max_outbound_message_bytes, 64 << 20);
                            const auto &source = inspector->active_source_ticket->source;
                            if (source.size() <= max_source_entry) {
                                while (!inspector->script_source_order.empty() &&
                                       source.size() > max_source_journal - inspector->script_source_bytes) {
                                    const auto &oldest_id = inspector->script_source_order.front();
                                    inspector->script_source_bytes -=
                                        inspector->script_sources[oldest_id]->size();
                                    inspector->script_sources.erase(oldest_id);
                                    inspector->script_source_order.pop_front();
                                }
                                if (source.size() <= max_source_journal - inspector->script_source_bytes) {
                                    auto source_ptr = std::make_shared<const std::string>(source);
                                    const auto inserted =
                                        inspector->script_sources.emplace(script_id, std::move(source_ptr));
                                    try {
                                        inspector->script_source_order.push_back(script_id);
                                    } catch (...) {
                                        inspector->script_sources.erase(inserted.first);
                                        throw;
                                    }
                                    inspector->script_source_bytes += source.size();
                                    constexpr size_t kMaxScriptSources = 128;
                                    while (inspector->script_source_order.size() > kMaxScriptSources) {
                                        const auto &oldest_id = inspector->script_source_order.front();
                                        inspector->script_source_bytes -=
                                            inspector->script_sources[oldest_id]->size();
                                        inspector->script_sources.erase(oldest_id);
                                        inspector->script_source_order.pop_front();
                                    }
                                }
                            }
                        }
                    }
                }
                if (send_context) {
                    const std::string context =
                        "{\"method\":\"Runtime.executionContextCreated\",\"params\":{\"context\":{"
                        "\"id\":" +
                        std::to_string(inspector->instance_id) +
                        ",\"origin\":\"\",\"name\":\"jsbay\",\"auxData\":{\"isDefault\":true}}}}";
                    enqueueOutbound(inspector, session_id, context, std::nullopt);
                }
                if (!enqueueOutbound(inspector, session_id, std::move(reply), id)) {
                    if (id) {
                        if (!enqueueFallbackError(inspector, session_id, *id,
                                                  "Inspector transport is busy or disconnected")) {
                            terminalizeSession(inspector, session_id);
                        }
                    } else {
                        terminalizeSession(inspector, session_id);
                    }
                }
            } catch (...) {
                terminalizeSession(inspector, session_id);
            }
        };
        EnqueueFailureScope enqueue_scope(inspector);
        auto agent = std::shared_ptr<cdp::CDPAgent>(cdp::CDPAgent::create(
            inspector->instance_id, *inspector->debug_api, std::move(enqueue), std::move(emit)));
        if (!agent || enqueue_scope.failed())
            return false;
        std::lock_guard<std::mutex> lock(inspector->mutex);
        if (inspector->stopped || inspector->closing ||
            inspector->sessions.find(session_id) != inspector->sessions.end())
            return false;
        session->agent = std::move(agent);
        inspector->sessions.emplace(session_id, std::move(session));
        return true;
    } catch (...) {
        return false;
    }
}

extern "C" bool hermes_inspector_message(JsbayHermesInspector *inspector, uint64_t session_id,
                                         const char *json, size_t len) {
    try {
        if (!inspector || !json)
            return false;
        std::shared_ptr<JsbayHermesInspector::Session> session;
        {
            std::lock_guard<std::mutex> lock(inspector->mutex);
            auto it = inspector->sessions.find(session_id);
            if (inspector->stopped || inspector->closing || it == inspector->sessions.end())
                return false;
            session = it->second;
        }
        std::string message(json, len);
        const auto object = parseMessage(inspector, message);
        if (!object)
            return false;
        const auto &method = object->method;
        const auto &id = object->id;
        if (method.empty() || !id)
            return false;
        if (method == "Debugger.getScriptSource") {
            const auto &script_id = object->script_id;
            std::shared_ptr<const std::string> source_ptr;
            if (!script_id.empty()) {
                std::lock_guard<std::mutex> lock(inspector->source_mutex);
                const auto it = inspector->script_sources.find(script_id);
                if (it != inspector->script_sources.end())
                    source_ptr = it->second;
            }
            if (!source_ptr) {
                if (!enqueueFallbackError(inspector, session_id, *id,
                                          "Source is unavailable for this script id")) {
                    terminalizeSession(inspector, session_id);
                }
                return true;
            }
            const auto escaped_len = escapedJsonLen(*source_ptr);
            constexpr size_t kEnvelopeFixed =
                sizeof("{\"id\":") - 1 +
                sizeof(",\"result\":{\"scriptSource\":") - 1 +
                sizeof("}}") - 1; // 34
            const std::string id_str = std::to_string(*id);
            size_t total_len = 0;
            const bool overflow = !escaped_len ||
                __builtin_add_overflow(*escaped_len, id_str.size(), &total_len) ||
                __builtin_add_overflow(total_len, kEnvelopeFixed, &total_len);
            if (overflow || total_len > inspector->max_outbound_message_bytes) {
                if (!enqueueFallbackError(inspector, session_id, *id,
                                          "Script source is too large to send")) {
                    terminalizeSession(inspector, session_id);
                }
                return true;
            }
            bool is_busy = false;
            uint64_t reserved_seq = 0;
            const bool is_large = total_len > inspector->max_outbound_backlog_bytes;
            {
                std::lock_guard<std::mutex> session_lock(inspector->mutex);
                const auto current_session = inspector->sessions.find(session_id);
                if (current_session == inspector->sessions.end() || current_session->second != session)
                    return true;
                std::lock_guard<std::mutex> metadata_lock(session->metadata->mutex);
                if (session->metadata->terminal)
                    return true;
                std::lock_guard<std::mutex> lock(inspector->outbound_mutex);
                auto &state = inspector->outbound_sessions[session_id];
                if (state.messages >= kMaxOutboundMessages) {
                    is_busy = true;
                } else if (is_large && state.large_message_in_flight) {
                    if (state.pending_large.size() < kMaxPendingLargeRequests) {
                        state.pending_large.push_back({*id, source_ptr});
                        return true;
                    }
                    is_busy = true;
                } else if (is_large) {
                    reserved_seq = reserveLargeMessage(inspector, state);
                }
            }
            if (is_busy) {
                if (!enqueueFallbackError(inspector, session_id, *id,
                                          "Inspector transport is busy or disconnected")) {
                    terminalizeSession(inspector, session_id);
                }
                return true;
            }
            std::string response;
            try {
                response.reserve(total_len);
                response += "{\"id\":";
                response += id_str;
                response += ",\"result\":{\"scriptSource\":";
                appendJsonQuoted(response, *source_ptr);
                response += "}}";
            } catch (...) {
                if (is_large) releaseLargeMessage(inspector, session_id, reserved_seq);
                const bool queued = enqueueFallbackError(inspector, session_id, *id,
                    "Unable to allocate script source response");
                if (!queued) terminalizeSession(inspector, session_id);
                return true;
            }
            if (!enqueueOutbound(inspector, session_id, std::move(response), *id, false,
                                 reserved_seq)) {
                if (is_large) releaseLargeMessage(inspector, session_id, reserved_seq);
                if (!enqueueFallbackError(inspector, session_id, *id,
                                          "Inspector transport is busy or disconnected")) {
                    terminalizeSession(inspector, session_id);
                }
            }
            return true;
        }
        std::lock_guard<std::mutex> command_lock(inspector->command_mutex);
        {
            std::lock_guard<std::mutex> metadata_lock(session->metadata->mutex);
            if (session->metadata->terminal)
                return true;
        }
        if (method == "Debugger.enable") {
            std::lock_guard<std::mutex> lock(session->metadata->mutex);
            session->metadata->debugger_enable_ids.insert(*id);
        }
        if (method == "Runtime.enable") {
            std::lock_guard<std::mutex> lock(session->metadata->mutex);
            session->metadata->runtime_enable_ids.insert(*id);
        }
        std::shared_ptr<SourceTicket> ticket;
        if (method == "Runtime.evaluate" && !object->expression.empty()) {
            ticket = std::make_shared<SourceTicket>(SourceTicket{object->expression});
        }
        if (method == "Runtime.disable") {
            std::lock_guard<std::mutex> lock(session->metadata->mutex);
            session->metadata->execution_context_sent = false;
        }
        EnqueueFailureScope enqueue_scope(inspector);
        SourceRequestScope source_scope(inspector, std::move(ticket));
        session->agent->handleCommand(std::move(message));
        if (enqueue_scope.failed()) {
            terminalizeSession(inspector, session_id);
        }
        return true;
    } catch (...) {
        return false;
    }
}

extern "C" void hermes_inspector_session_close(JsbayHermesInspector *inspector,
                                               uint64_t session_id) {
    try {
        if (!inspector)
            return;
        std::shared_ptr<JsbayHermesInspector::Session> session;
        bool resume = false;
        {
            std::lock_guard<std::mutex> lock(inspector->mutex);
            auto it = inspector->sessions.find(session_id);
            if (it == inspector->sessions.end())
                return;
            session = std::move(it->second);
            inspector->sessions.erase(it);
            resume = inspector->sessions.empty();
        }
        {
            std::lock_guard<std::mutex> lock(session->metadata->mutex);
            session->metadata->terminal = true;
        }
        discardOutboundSession(inspector, session_id);
        session.reset();
        if (resume)
            inspector->debug_api->asyncDebuggerAPI().triggerInterrupt_TS(
                [api = inspector->debug_api.get()](FbHermesRuntime &) {
                    if (api->asyncDebuggerAPI().isWaitingForCommand())
                        api->asyncDebuggerAPI().resumeFromPaused(
                            debugger::AsyncDebugCommand::Continue);
                });
    } catch (...) {
    }
}

extern "C" void hermes_inspector_close_sessions(JsbayHermesInspector *inspector) {
    try {
        if (!inspector)
            return;
        std::unordered_map<uint64_t, std::shared_ptr<JsbayHermesInspector::Session>> sessions;
        {
            std::lock_guard<std::mutex> lock(inspector->mutex);
            if (inspector->stopped || inspector->closing)
                return;
            inspector->closing = true;
            sessions.swap(inspector->sessions);
        }
        for (const auto &[session_id, session] : sessions) {
            std::lock_guard<std::mutex> lock(session->metadata->mutex);
            session->metadata->terminal = true;
            discardOutboundSession(inspector, session_id);
        }
        sessions.clear();
        // A disconnected client must not strand the engine in a debugger pause. AsyncDebuggerAPI owns the pause loop, so this is safe from the reader thread.
        inspector->debug_api->asyncDebuggerAPI().triggerInterrupt_TS(
            [api = inspector->debug_api.get()](FbHermesRuntime &) {
                if (api->asyncDebuggerAPI().isWaitingForCommand()) {
                    api->asyncDebuggerAPI().resumeFromPaused(debugger::AsyncDebugCommand::Continue);
                }
            });
    } catch (...) {
    }
}

extern "C" void hermes_inspector_stop(JsbayHermesInspector *inspector) {
    try {
        if (!inspector)
            return;
        hermes_inspector_close_sessions(inspector);
        {
            std::lock_guard<std::mutex> lock(inspector->mutex);
            inspector->stopped = true;
        }
        {
            std::lock_guard<std::mutex> lock(inspector->outbound_mutex);
            inspector->outbound_open = false;
            inspector->outbound.clear();
            inspector->outbound_sessions.clear();
        }
        inspector->outbound_cv.notify_all();
        if (inspector->outbound_sender.joinable()) {
            assert(inspector->outbound_sender.get_id() != std::this_thread::get_id());
            inspector->outbound_sender.join();
        }
        inspector->debug_api.reset();
        hermes_context_set_inspector(inspector->context, nullptr);
        {
            std::lock_guard<std::mutex> lock(g_live_inspectors_mutex);
            g_live_inspectors.erase(inspector);
        }
        delete inspector;
    } catch (...) {
    }
}

extern "C" void hermes_inspector_console(JsbayHermesContext *ctx, const HermesValue *args,
                                         size_t argc, int level) {
    try {
        if (!ctx || (argc != 0 && !args))
            return;
        auto *inspector = hermes_context_get_inspector(ctx);
        if (!inspector || !inspector->debug_api)
            return;
        std::vector<jsi::Value> values;
        values.reserve(argc);
        for (size_t i = 0; i < argc; ++i)
            values.emplace_back(*inspector->runtime, *static_cast<jsi::Value *>(args[i]));
        cdp::ConsoleAPIType type = cdp::ConsoleAPIType::kLog;
        if (level == 1)
            type = cdp::ConsoleAPIType::kInfo;
        else if (level == 2)
            type = cdp::ConsoleAPIType::kWarning;
        else if (level == 3)
            type = cdp::ConsoleAPIType::kError;
        const double timestamp = std::chrono::duration<double, std::milli>(
                                     std::chrono::system_clock::now().time_since_epoch())
                                     .count();
        inspector->debug_api->addConsoleMessage(
            cdp::ConsoleMessage{timestamp, type, std::move(values)});
    } catch (...) {
    }
}

extern "C" void hermes_inspector_source_begin(JsbayHermesContext *ctx, const char *source,
                                              size_t source_len) {
    auto *inspector = hermes_context_get_inspector(ctx);
    if (!inspector)
        return;
    sourceTicketBegin(inspector, std::make_shared<SourceTicket>(
                                     SourceTicket{std::string(source ? source : "", source_len)}));
}

extern "C" void hermes_inspector_source_end(JsbayHermesContext *ctx) {
    auto *inspector = hermes_context_get_inspector(ctx);
    if (!inspector)
        return;
    std::lock_guard<std::mutex> lock(inspector->source_mutex);
    inspector->active_source_ticket.reset();
}

extern "C" void jsbay_hermes_inspector_delivery_complete(JsbayHermesInspector *inspector,
                                                        uint64_t session_id, uint64_t delivery_token) {
    if (!inspector)
        return;
    try {
        std::lock_guard<std::mutex> live_lock(g_live_inspectors_mutex);
        if (g_live_inspectors.find(inspector) == g_live_inspectors.end())
            return;
        releaseLargeMessage(inspector, session_id, delivery_token);
    } catch (...) {
    }
}

extern "C" void jsbay_hermes_inspector_set_delivery_observer(JsbayHermesInspector *inspector,
                                                             bool observed) {
    if (!inspector)
        return;
    inspector->delivery_observed.store(observed);
}
