#include <napi/native_api.h>
#include <client/ovpncli.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <thread>
#include <unistd.h>

namespace {
using namespace openvpn::ClientAPI;

std::string Quote(const std::string &s)
{
    std::ostringstream out;
    out << '"';
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c);
        else out << c;
    }
    out << '"';
    return out.str();
}

Config MakeConfig(const std::string &profile)
{
    Config c;
    c.content = profile;
    c.guiVersion = "ShuangsecaiOVPN 0.1.0";
    c.platformVersion = "HarmonyOS 7";
    c.connTimeout = 45;
    c.tunPersist = false;
    c.googleDnsFallback = false;
    c.retryOnAuthFailed = false;
    c.clockTickMS = 1000;
    c.compressionMode = "no";
    c.dhcpSearchDomainsAsSplitDomains = false;
    return c;
}

struct Network {
    std::string address;
    int prefix;
    bool ipv6;
};

std::string NetworksJson(const std::vector<Network> &networks)
{
    std::string result = "[";
    for (const auto &n : networks) {
        if (result.size() > 1) result += ',';
        result += "{\"address\":" + Quote(n.address) + ",\"prefix\":" + std::to_string(n.prefix)
            + ",\"ipv6\":" + (n.ipv6 ? "true" : "false") + "}";
    }
    return result + ']';
}

std::string StringsJson(const std::vector<std::string> &values)
{
    std::string result = "[";
    for (const auto &v : values) {
        if (result.size() > 1) result += ',';
        result += Quote(v);
    }
    return result + ']';
}

class HarmonyClient final : public OpenVPNClient {
public:
    napi_threadsafe_function callback = nullptr;
    std::atomic<bool> running{false};
    std::atomic<bool> stopping{false};
    std::mutex mutex;
    std::condition_variable response;
    std::string state = "DISCONNECTED";
    std::string error;
    std::string builderError;
    InterfaceStats lastStats{};
    int nextRequest = 0;
    int waitingRequest = 0;
    int replyValue = -1;
    bool replied = false;
    bool waitingTun = false;
    std::vector<Network> addresses;
    std::vector<Network> routes;
    std::vector<std::string> dns;
    std::vector<std::string> domains;
    int mtu = 1500;

    void Emit(std::string message)
    {
        auto data = std::make_unique<std::string>(std::move(message));
        if (callback && napi_call_threadsafe_function(callback, data.get(), napi_tsfn_nonblocking) == napi_ok)
            data.release();
    }

    void State(const std::string &value, const std::string &code = "")
    {
        {
            std::lock_guard<std::mutex> guard(mutex);
            state = value;
            if (!code.empty()) error = code;
            else if (value == "CONNECTED" || value == "DISCONNECTED") error.clear();
        }
        Emit("{\"type\":\"state\",\"state\":" + Quote(value) + ",\"error\":" + Quote(code) + "}");
    }

    int Request(const std::string &type, const std::string &fields = "")
    {
        std::unique_lock<std::mutex> guard(mutex);
        if (stopping) return -1;
        const int id = ++nextRequest;
        waitingRequest = id;
        waitingTun = type == "tun";
        replied = false;
        Emit("{\"type\":" + Quote(type) + ",\"requestId\":" + std::to_string(id) + fields + "}");
        const bool ready = response.wait_for(guard, std::chrono::seconds(15), [this] { return replied || stopping; });
        waitingRequest = 0;
        return ready && replied && !stopping ? replyValue : -1;
    }

    bool socket_protect(openvpn_io::detail::socket_type fd, std::string, bool) override
    {
        return Request("protect", ",\"fd\":" + std::to_string(fd)) == 1;
    }
    bool tun_builder_new() override
    {
        addresses.clear(); routes.clear(); dns.clear(); domains.clear(); mtu = 1500;
        builderError.clear();
        return !stopping;
    }
    bool RejectBuilder(const std::string &code)
    {
        builderError = code;
        State("CONNECTING", code);
        return false;
    }
    bool tun_builder_set_layer(int layer) override { return layer == 3; }
    bool tun_builder_set_remote_address(const std::string &, bool) override { return true; }
    bool tun_builder_add_address(const std::string &ip, int prefix, const std::string &, bool ipv6, bool) override
    {
        addresses.push_back({ip, prefix, ipv6});
        return true;
    }
    bool tun_builder_add_route(const std::string &ip, int prefix, int metric, bool ipv6) override
    {
        if (metric > 0) return RejectBuilder("ROUTE_METRIC_UNSUPPORTED");
        routes.push_back({ip, prefix, ipv6});
        return true;
    }
    bool tun_builder_exclude_route(const std::string &, int, int, bool) override
    {
        return RejectBuilder("EXCLUDE_ROUTE_UNSUPPORTED");
    }
    bool tun_builder_set_route_metric_default(int metric) override
    {
        return metric <= 0 || RejectBuilder("ROUTE_METRIC_UNSUPPORTED");
    }
    bool tun_builder_reroute_gw(bool ipv4, bool ipv6, unsigned int) override
    {
        if (ipv4) routes.push_back({"0.0.0.0", 0, false});
        if (ipv6) routes.push_back({"::", 0, true});
        return true;
    }
    bool tun_builder_set_mtu(int value) override
    {
        if (value < 576 || value > 1500) return RejectBuilder("MTU_UNSUPPORTED");
        mtu = value;
        return true;
    }
    bool tun_builder_set_dns_options(const openvpn::DnsOptions &options) override
    {
        for (const auto &item : options.servers) {
            const auto &s = item.second;
            if (!s.domains.empty() || !s.sni.empty()
                || (s.transport != openvpn::DnsServer::Transport::Unset && s.transport != openvpn::DnsServer::Transport::Plain)
                || s.dnssec == openvpn::DnsServer::Security::Yes) {
                return RejectBuilder("DNS_OPTIONS_UNSUPPORTED");
            }
            for (const auto &a : s.addresses) {
                if (a.port != 0 && a.port != 53) return RejectBuilder("DNS_OPTIONS_UNSUPPORTED");
                dns.push_back(a.address);
            }
        }
        for (const auto &d : options.search_domains) domains.push_back(d.domain);
        return true;
    }
    bool tun_builder_set_session_name(const std::string &) override { return true; }
    bool tun_builder_persist() override { return false; }
    bool tun_builder_set_allow_family(int af, bool allow) override
    {
        if (!allow) {
            const bool hasAddress = std::any_of(addresses.begin(), addresses.end(), [af](const Network &n) {
                return n.ipv6 == (af == AF_INET6);
            });
            if (!hasAddress) return RejectBuilder("BLOCK_FAMILY_UNSUPPORTED");
        }
        return true;
    }
    int tun_builder_establish() override
    {
        // Some optional builder callback return values are not checked by core.
        if (!builderError.empty()) return -1;
        return Request("tun", ",\"addresses\":" + NetworksJson(addresses) + ",\"routes\":" + NetworksJson(routes)
            + ",\"dns\":" + StringsJson(dns) + ",\"domains\":" + StringsJson(domains) + ",\"mtu\":" + std::to_string(mtu));
    }
    void tun_builder_teardown(bool) override { Request("destroyTun"); }
    bool pause_on_connection_timeout() override { return false; }
    void clock_tick() override { if (stopping) stop(); }
    void event(const Event &e) override
    {
        if (e.name == "CONNECTED") State("CONNECTED");
        else if (e.name == "RECONNECTING" || e.name == "RESOLVE" || e.name == "WAIT" || e.name == "CONNECTING") {
            if (!stopping) State("CONNECTING");
        } else if (e.error || e.fatal) {
            // Event names are protocol constants. Never forward info/log/profile content.
            State(stopping ? "DISCONNECTING" : "CONNECTING", e.name);
        }
    }
    void acc_event(const AppCustomControlMessageEvent &) override {}
    void log(const LogInfo &) override {}
    void external_pki_cert_request(ExternalPKICertRequest &request) override
    {
        request.error = true; request.errorText = "External PKI unsupported";
    }
    void external_pki_sign_request(ExternalPKISignRequest &request) override
    {
        request.error = true; request.errorText = "External PKI unsupported";
    }
};

struct Engine {
    std::shared_ptr<HarmonyClient> client;
    std::thread worker;
};

Engine *GetEngine(napi_env env, napi_callback_info info)
{
    void *data = nullptr;
    size_t count = 0;
    napi_get_cb_info(env, info, &count, nullptr, nullptr, &data);
    return static_cast<Engine *>(data);
}

std::string GetString(napi_env env, napi_value value)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > 2 * 1024 * 1024) return {};
    std::string result(length + 1, '\0');
    napi_get_value_string_utf8(env, value, result.data(), result.size(), &length);
    result.resize(length);
    return result;
}
napi_value String(napi_env env, const std::string &text)
{
    napi_value result;
    napi_create_string_utf8(env, text.c_str(), text.size(), &result);
    return result;
}
napi_value Boolean(napi_env env, bool value)
{
    napi_value result;
    napi_get_boolean(env, value, &result);
    return result;
}
void CallJs(napi_env env, napi_value callback, void *, void *data)
{
    std::unique_ptr<std::string> message(static_cast<std::string *>(data));
    if (!env || !callback) return;
    napi_value argument = String(env, *message), undefined, result;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, callback, 1, &argument, &result);
}

napi_value Evaluate(napi_env env, napi_callback_info info)
{
    napi_value arg;
    size_t count = 1;
    napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
    try {
        HarmonyClient evaluator;
        auto result = evaluator.eval_config(MakeConfig(GetString(env, arg)));
        return String(env, "{\"error\":" + std::string(result.error ? "true" : "false")
            + ",\"externalPki\":" + (result.externalPki ? "true" : "false")
            + ",\"requiresAuth\":" + (result.autologin ? "false" : "true")
            + ",\"requiresKeyPassword\":" + (result.privateKeyPasswordRequired ? "true" : "false")
            + ",\"staticChallenge\":" + (!result.staticChallenge.empty() ? "true" : "false")
            + ",\"allowPasswordSave\":" + (result.allowPasswordSave ? "true" : "false")
            + ",\"lockedUsername\":" + Quote(result.userlockedUsername)
            + ",\"protocol\":" + Quote(result.remoteProto) + "}");
    } catch (...) { return String(env, "{\"error\":true}"); }
}

void StopClient(Engine *engine)
{
    const auto &client = engine->client;
    if (!client || !client->running) return;
    {
        std::lock_guard<std::mutex> guard(client->mutex);
        const auto stats = client->tun_stats();
        if (stats.bytesIn > 0 || stats.bytesOut > 0) client->lastStats = stats;
    }
    client->stopping = true;
    client->response.notify_all();
    client->stop();
}

napi_value Start(napi_env env, napi_callback_info info)
{
    napi_value args[5];
    size_t count = 5;
    void *data = nullptr;
    napi_get_cb_info(env, info, &count, args, nullptr, &data);
    auto *engine = static_cast<Engine *>(data);
    auto &client = engine->client;
    auto &worker = engine->worker;
    if (count != 5 || (client && client->running)) return Boolean(env, false);
    if (worker.joinable()) worker.join();
    auto current = std::make_shared<HarmonyClient>();
    napi_value resource = String(env, "OpenVPN events");
    if (napi_create_threadsafe_function(env, args[4], nullptr, resource, 0, 1, nullptr, nullptr, nullptr,
        CallJs, &current->callback) != napi_ok) return Boolean(env, false);
    auto config = MakeConfig(GetString(env, args[0]));
    config.privateKeyPassword = GetString(env, args[3]);
    ProvideCreds creds;
    creds.username = GetString(env, args[1]);
    creds.password = GetString(env, args[2]);
    current->running = true;
    client = current;
    worker = std::thread([current, config = std::move(config), creds = std::move(creds)]() mutable {
        try {
            current->State("CONNECTING");
            auto evaluation = current->eval_config(config);
            if (evaluation.error || evaluation.externalPki || !evaluation.staticChallenge.empty())
                current->State("FAILED", "PROFILE_UNSUPPORTED");
            else {
                auto provided = current->provide_creds(creds);
                if (provided.error) current->State("FAILED", "CREDENTIALS_INVALID");
                else if (!current->stopping) {
                    auto status = current->connect();
                    if (current->stopping) current->State("DISCONNECTED");
                    else {
                        std::string failure;
                        { std::lock_guard<std::mutex> guard(current->mutex); failure = current->error; }
                        current->State("FAILED", !failure.empty() ? failure
                            : (status.error && !status.status.empty() ? status.status : "CONNECTION_ENDED"));
                    }
                }
            }
        } catch (...) { current->State(current->stopping ? "DISCONNECTED" : "FAILED", "CORE_ERROR"); }
        if (current->stopping) current->State("DISCONNECTED");
        std::fill(config.content.begin(), config.content.end(), '\0');
        std::fill(config.privateKeyPassword.begin(), config.privateKeyPassword.end(), '\0');
        std::fill(creds.password.begin(), creds.password.end(), '\0');
        current->running = false;
        current->Emit("{\"type\":\"stopped\"}");
        napi_release_threadsafe_function(current->callback, napi_tsfn_release);
    });
    return Boolean(env, true);
}
napi_value Stop(napi_env env, napi_callback_info info)
{
    StopClient(GetEngine(env, info));
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}
napi_value Respond(napi_env env, napi_callback_info info)
{
    napi_value args[2];
    size_t count = 2;
    void *data = nullptr;
    napi_get_cb_info(env, info, &count, args, nullptr, &data);
    const auto &client = static_cast<Engine *>(data)->client;
    int32_t id = 0, value = -1;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int32(env, args[1], &value);
    if (!client) return Boolean(env, false);
    std::lock_guard<std::mutex> guard(client->mutex);
    if (client->stopping || client->waitingRequest != id) return Boolean(env, false);
    // Core owns a duplicate. ArkTS always closes its original descriptor.
    client->replyValue = client->waitingTun && value >= 0 ? dup(value) : value;
    client->replied = true;
    client->response.notify_all();
    return Boolean(env, true);
}
napi_value CloseFd(napi_env env, napi_callback_info info)
{
    size_t count = 1;
    napi_value arg;
    int32_t fd = -1;
    napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
    napi_get_value_int32(env, arg, &fd);
    if (fd >= 0) close(fd);
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}
napi_value Snapshot(napi_env env, napi_callback_info info)
{
    const auto &client = GetEngine(env, info)->client;
    if (!client) return String(env, "{\"state\":\"DISCONNECTED\",\"running\":false,\"bytesIn\":0,\"bytesOut\":0,\"packetsIn\":0,\"packetsOut\":0,\"error\":\"\"}");
    std::lock_guard<std::mutex> guard(client->mutex);
    auto stats = client->tun_stats();
    if (client->running && (stats.bytesIn > 0 || stats.bytesOut > 0)) client->lastStats = stats;
    else if (!client->running) stats = client->lastStats;
    return String(env, "{\"state\":" + Quote(client->state) + ",\"running\":" + (client->running ? "true" : "false")
        + ",\"bytesIn\":" + std::to_string(stats.bytesIn) + ",\"bytesOut\":" + std::to_string(stats.bytesOut)
        + ",\"packetsIn\":" + std::to_string(stats.packetsIn) + ",\"packetsOut\":" + std::to_string(stats.packetsOut)
        + ",\"error\":" + Quote(client->error) + "}");
}
void Cleanup(void *data)
{
    auto *engine = static_cast<Engine *>(data);
    StopClient(engine);
    if (engine->worker.joinable()) engine->worker.join();
    delete engine;
}
napi_value Init(napi_env env, napi_value exports)
{
    auto *engine = new Engine();
    napi_property_descriptor properties[] = {
        {"evaluate", nullptr, Evaluate, nullptr, nullptr, nullptr, napi_default, engine},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, engine},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, engine},
        {"respond", nullptr, Respond, nullptr, nullptr, nullptr, napi_default, engine},
        {"snapshot", nullptr, Snapshot, nullptr, nullptr, nullptr, napi_default, engine},
        {"closeFd", nullptr, CloseFd, nullptr, nullptr, nullptr, napi_default, engine}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    napi_add_env_cleanup_hook(env, Cleanup, engine);
    return exports;
}
napi_module module = {1, 0, nullptr, Init, "ovpn", nullptr, {0}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
} // namespace
