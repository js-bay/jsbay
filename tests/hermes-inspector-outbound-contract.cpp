#include "../src/backend/hermes/hermes_inspector.cpp"

#include <cstdio>
#include <stdexcept>
#include <vector>

#define CHECK(expr) do { if (!(expr)) throw std::runtime_error(#expr); } while (false)

struct OutboundFixture {
    struct Frame {
        std::string text;
        uint64_t token;
    };

    JsbayHermesInspector inspector{nullptr, nullptr, 0, emit, nullptr, nullptr, parseScriptSource, this};
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<Frame> frames;
    size_t allowed = 0;
    bool stopping = false;

    explicit OutboundFixture(size_t backlog) {
        inspector.max_outbound_backlog_bytes = backlog;
        inspector.max_outbound_message_bytes = 256;
        addSession(1);
    }

    ~OutboundFixture() {
        if (!inspector.outbound_sender.joinable()) return;
        {
            std::lock_guard<std::mutex> lock(inspector.outbound_mutex);
            inspector.outbound_open = false;
        }
        inspector.outbound_cv.notify_one();
        {
            std::lock_guard<std::mutex> lock(mutex);
            stopping = true;
        }
        changed.notify_one();
        inspector.outbound_sender.join();
    }

    void addSession(uint64_t id) {
        auto session = std::make_shared<JsbayHermesInspector::Session>();
        session->metadata = std::make_shared<JsbayHermesInspector::Metadata>();
        inspector.sessions.emplace(id, std::move(session));
    }

    void startSender() {
        inspector.outbound_sender = std::thread(runOutboundSender, &inspector);
    }

    Frame waitForFrame(size_t number) {
        std::unique_lock<std::mutex> lock(mutex);
        CHECK(changed.wait_for(lock, std::chrono::seconds(3), [&] { return frames.size() >= number; }));
        return frames.at(number - 1);
    }

    void finishFrame(size_t number) {
        std::lock_guard<std::mutex> lock(mutex);
        allowed = number;
        changed.notify_one();
    }

    JsbayHermesInspector::OutboundState state() {
        std::lock_guard<std::mutex> lock(inspector.outbound_mutex);
        return inspector.outbound_sessions.at(1);
    }

    static bool emit(uint64_t, const char *json, size_t len, uint64_t token, void *ctx) {
        auto &fixture = *static_cast<OutboundFixture *>(ctx);
        std::unique_lock<std::mutex> lock(fixture.mutex);
        fixture.frames.push_back({std::string(json, len), token});
        fixture.changed.notify_all();
        fixture.changed.wait(lock, [&] { return fixture.stopping || fixture.allowed >= fixture.frames.size(); });
        return true;
    }

    static bool parseScriptSource(const char *, size_t, HermesInspectorInfoSink sink, void *target) {
        constexpr char method[] = "Debugger.getScriptSource";
        HermesInspectorMessageInfo info{};
        info.id = 9;
        info.flags = 1;
        info.method = method;
        info.method_len = sizeof(method) - 1;
        info.script_id = "1";
        info.script_id_len = 1;
        sink(target, &info);
        return true;
    }
};

static void testChargedBytes() {
    OutboundFixture fixture(64);
    const std::string fallback = R"({"id":2,"error":{"code":-1}})";
    const std::string ordinary = R"({"id":1,"error":{"code":-1}})";
    CHECK(enqueueOutbound(&fixture.inspector, 1, fallback, 2, true));
    CHECK(enqueueOutbound(&fixture.inspector, 1, ordinary, 1));
    CHECK(fixture.state().bytes == ordinary.size());
    CHECK(fixture.state().messages == 2);

    fixture.startSender();
    CHECK(fixture.waitForFrame(1).text == fallback);
    CHECK(fixture.state().bytes == ordinary.size());
    CHECK(fixture.state().messages == 1);
    fixture.finishFrame(1);
    CHECK(fixture.waitForFrame(2).text == ordinary);
    CHECK(fixture.state().bytes == 0);
    CHECK(fixture.state().messages == 0);
}

static void testSynchronousLargeRelease() {
    OutboundFixture fixture(8);
    auto *inspector = &fixture.inspector;
    inspector->delivery_observed.store(false);
    const std::string large(32, 'x');
    CHECK(enqueueOutbound(inspector, 1, large));
    CHECK(enqueueOutbound(inspector, 1, "{}"));
    fixture.startSender();
    CHECK(fixture.waitForFrame(1).token != 0);
    CHECK(fixture.state().large_message_in_flight);
    CHECK(!enqueueOutbound(inspector, 1, large));
    fixture.finishFrame(1);
    CHECK(fixture.waitForFrame(2).token == 0);
    CHECK(!fixture.state().large_message_in_flight);
    CHECK(enqueueOutbound(inspector, 1, large));
}

static void testOversizedSourceFallbackKeepsSessionUsable() {
    OutboundFixture fixture(64);
    auto *inspector = &fixture.inspector;
    auto &source = inspector->script_sources["1"];
    source = std::make_shared<const std::string>(160, '\t');
    CHECK(hermes_inspector_message(inspector, 1, "{}", 2));
    CHECK(fixture.state().bytes == 0);
    source = std::make_shared<const std::string>("42");
    CHECK(hermes_inspector_message(inspector, 1, "{}", 2));
    fixture.startSender();
    CHECK(fixture.waitForFrame(1).text == R"({"id":9,"error":{"code":-32000,"message":"Script source is too large to send"}})");
    fixture.finishFrame(1);
    CHECK(fixture.waitForFrame(2).text == R"({"id":9,"result":{"scriptSource":"42"}})");
}

static void testOversizedResponseAndNotification() {
    OutboundFixture fixture(128);
    auto *inspector = &fixture.inspector;
    const std::string oversized = R"({"id":12,"error":{"message":")" + std::string(512, 'r') + R"("}})";
    CHECK(enqueueOutbound(inspector, 1, oversized, 12));
    CHECK(fixture.state().bytes == 0);
    CHECK(inspector->outbound.front().json == R"({"id":12,"error":{"code":-32000,"message":"Message is too large"}})");
    fixture.addSession(2);
    CHECK(!enqueueOutbound(inspector, 2, std::string(512, 'n')));
    CHECK(inspector->sessions.at(2)->metadata->terminal);
}

static void testStaleDeliveryToken() {
    OutboundFixture fixture(8);
    auto *inspector = &fixture.inspector;
    inspector->delivery_observed.store(true);
    const std::string large(32, 'x');
    CHECK(enqueueOutbound(inspector, 1, large));
    fixture.startSender();
    const auto first = fixture.waitForFrame(1).token;
    CHECK(first != 0);
    jsbay_hermes_inspector_delivery_complete(inspector, 1, first);
    discardOutboundSession(inspector, 1);
    CHECK(enqueueOutbound(inspector, 1, large));
    fixture.finishFrame(1);
    const auto second = fixture.waitForFrame(2).token;
    CHECK(second != 0 && first != second);
    jsbay_hermes_inspector_delivery_complete(inspector, 1, first);
    CHECK(!enqueueOutbound(inspector, 1, large));
    jsbay_hermes_inspector_delivery_complete(inspector, 1, second);
    CHECK(enqueueOutbound(inspector, 1, large));
}

static void testPendingLargeSourceQueueing() {
    OutboundFixture fixture(8);
    auto *inspector = &fixture.inspector;
    inspector->delivery_observed.store(true);
    auto &source1 = inspector->script_sources["1"];
    source1 = std::make_shared<const std::string>(32, 'a');
    auto &source2 = inspector->script_sources["2"];
    source2 = std::make_shared<const std::string>(32, 'b');

    static std::string current_script_id = "1";
    inspector->parse_script_source = [](const char *, size_t, HermesInspectorInfoSink sink, void *target) -> bool {
        constexpr char method[] = "Debugger.getScriptSource";
        HermesInspectorMessageInfo info{};
        info.id = 10;
        info.flags = 1;
        info.method = method;
        info.method_len = sizeof(method) - 1;
        info.script_id = current_script_id.c_str();
        info.script_id_len = current_script_id.size();
        sink(target, &info);
        return true;
    };

    current_script_id = "1";
    CHECK(hermes_inspector_message(inspector, 1, "{}", 2));
    CHECK(fixture.state().large_message_in_flight);
    CHECK(fixture.state().pending_large.empty());

    current_script_id = "2";
    CHECK(hermes_inspector_message(inspector, 1, "{}", 2));
    CHECK(fixture.state().large_message_in_flight);
    CHECK(fixture.state().pending_large.size() == 1);

    fixture.startSender();
    const auto frame1 = fixture.waitForFrame(1);
    CHECK(frame1.token != 0);
    CHECK(frame1.text.find(std::string(32, 'a')) != std::string::npos);

    jsbay_hermes_inspector_delivery_complete(inspector, 1, frame1.token);
    fixture.finishFrame(1);

    const auto frame2 = fixture.waitForFrame(2);
    CHECK(frame2.token != 0);
    CHECK(frame2.text.find(std::string(32, 'b')) != std::string::npos);
    jsbay_hermes_inspector_delivery_complete(inspector, 1, frame2.token);
    fixture.finishFrame(2);
    CHECK(!fixture.state().large_message_in_flight);
    CHECK(fixture.state().pending_large.empty());
}

int main() {
    try {
        testChargedBytes();
        testSynchronousLargeRelease();
        testOversizedSourceFallbackKeepsSessionUsable();
        testOversizedResponseAndNotification();
        testStaleDeliveryToken();
        testPendingLargeSourceQueueing();
    } catch (const std::exception &error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
    return 0;
}
