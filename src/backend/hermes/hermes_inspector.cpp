#include "hermes_bridge.h"

#include <cassert>
#include <chrono>
#include <condition_variable>
#include <hermes/cdp/CDPAgent.h>
#include <hermes/cdp/CDPDebugAPI.h>

#ifndef HERMES_ENABLE_DEBUGGER
#error "hermes_inspector.cpp requires a debugger-enabled Hermes SDK"
#endif

#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>

namespace jsi = facebook::jsi;
using FbHermesRuntime = facebook::hermes::HermesRuntime;
using namespace facebook::hermes;

extern "C" FbHermesRuntime *hermes_context_runtime_for_inspector(JsbayHermesContext *);
extern "C" void hermes_context_set_inspector(JsbayHermesContext *, JsbayHermesInspector *);
extern "C" JsbayHermesInspector *hermes_context_get_inspector(JsbayHermesContext *);

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

struct JsbayHermesInspector {
    JsbayHermesContext *context;
    FbHermesRuntime *runtime;
    int32_t instance_id;
    HermesInspectorEmitFn emit;
    HermesInspectorCloseFn close;
    HermesInspectorEnqueueFn enqueue;
    HermesInspectorParseFn parse;
    void *user_data;
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
    std::unordered_map<std::string, std::string> script_sources;
    std::deque<std::string> script_source_order;
    size_t script_source_bytes = 0;
    struct OutboundMessage {
        uint64_t session_id;
        std::string json;
    };
    struct OutboundState {
        size_t bytes = 0;
        size_t messages = 0;
    };
    std::mutex outbound_mutex;
    std::condition_variable outbound_cv;
    std::deque<OutboundMessage> outbound;
    std::unordered_map<uint64_t, OutboundState> outbound_sessions;
    uint64_t terminal_generation = 0;
    bool terminal_pending = false;
    bool outbound_open = true;
    std::thread outbound_sender;
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
                            std::string json) {
    bool rejected = false;
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
        constexpr size_t kMaxOutboundMessages = 256;
        constexpr size_t kMaxOutboundBytes = 4 << 20;
        if (!inspector->outbound_open)
            return false;
        auto &state = inspector->outbound_sessions[session_id];
        if (state.messages == kMaxOutboundMessages || json.size() > kMaxOutboundBytes ||
            json.size() > kMaxOutboundBytes - state.bytes) {
            rejected = true;
        } else {
            state.bytes += json.size();
            state.messages += 1;
            inspector->outbound.push_back({session_id, std::move(json)});
            inspector->outbound_cv.notify_one();
            return true;
        }
    } catch (...) {
        rejected = true;
    }
    if (rejected)
        terminalizeSession(inspector, session_id);
    return false;
}

static void runOutboundSender(JsbayHermesInspector *inspector) {
    for (;;) {
        JsbayHermesInspector::OutboundMessage message;
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
                state->second.bytes -= message.json.size();
                state->second.messages -= 1;
            }
        }
        inspector->emit(message.session_id, message.json.data(), message.json.size(),
                        inspector->user_data);
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
    std::string out = "\"";
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
            if (c < 0x20) {
                out += "\\u00";
                out.push_back(hex[c >> 4]);
                out.push_back(hex[c & 15]);
            } else
                out.push_back(static_cast<char>(c));
        }
    }
    return out + "\"";
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
                       void *user_data, HermesInspectorParseFn parse) {
    try {
        FbHermesRuntime *runtime = hermes_context_runtime_for_inspector(ctx);
        if (!runtime || !emit || !close || !enqueue || !parse)
            return nullptr;
        std::unique_ptr<JsbayHermesInspector> candidate(new JsbayHermesInspector{
            ctx, runtime, instance_id, emit, close, enqueue, parse, user_data});
        auto *inspector = candidate.get();
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
                            constexpr size_t kMaxSourceEntryBytes = 64 * 1024;
                            constexpr size_t kMaxSourceJournalBytes = 4 * 1024 * 1024;
                            const auto &source = inspector->active_source_ticket->source;
                            if (source.size() <= kMaxSourceEntryBytes &&
                                source.size() <=
                                    kMaxSourceJournalBytes - inspector->script_source_bytes) {
                                const auto inserted =
                                    inspector->script_sources.emplace(script_id, source);
                                try {
                                    inspector->script_source_order.push_back(script_id);
                                } catch (...) {
                                    inspector->script_sources.erase(inserted.first);
                                    throw;
                                }
                                inspector->script_source_bytes += source.size();
                                constexpr size_t kMaxScriptSources = 128;
                                if (inspector->script_source_order.size() > kMaxScriptSources) {
                                    inspector->script_source_bytes -=
                                        inspector
                                            ->script_sources[inspector->script_source_order.front()]
                                            .size();
                                    inspector->script_sources.erase(
                                        inspector->script_source_order.front());
                                    inspector->script_source_order.pop_front();
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
                    enqueueOutbound(inspector, session_id, context);
                }
                enqueueOutbound(inspector, session_id, std::move(reply));
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
            std::optional<std::string> source;
            if (!script_id.empty()) {
                std::lock_guard<std::mutex> lock(inspector->source_mutex);
                const auto it = inspector->script_sources.find(script_id);
                if (it != inspector->script_sources.end())
                    source = it->second;
            }
            if (!source) {
                const std::string error = "{\"id\":" + std::to_string(*id) +
                                          ",\"error\":{\"code\":-32000,\"message\":\"Source is "
                                          "unavailable for this script id\"}}";
                enqueueOutbound(inspector, session_id, error);
            } else {
                const std::string response = "{\"id\":" + std::to_string(*id) +
                                             ",\"result\":{\"scriptSource\":" + jsonQuote(*source) +
                                             "}}";
                enqueueOutbound(inspector, session_id, response);
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
