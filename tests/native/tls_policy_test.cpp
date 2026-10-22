#define OPENVPN_LOG_CLASS openvpn::LogBase
#include <openvpn/log/logbase.hpp>
#include <openvpn/ssl/sslchoose.hpp>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>

using namespace openvpn;

std::string Read(const std::string &path)
{
    std::ifstream input(path);
    if (!input) throw std::runtime_error("Missing disposable TLS fixture");
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

struct Session {
    SSLConfigAPI::Ptr config;
    SSLFactoryAPI::Ptr factory;
    SSLAPI::Ptr ssl;
};

Session MakeSession(const std::string &directory, bool server, bool trusted, bool correctName, bool serverRole)
{
    const std::string identity = server && serverRole ? "server" : "client";
    const std::string ca = !server && !trusted ? "other-ca" : "ca";
    std::string text = server ? "" : std::string("client\nremote-cert-tls server\nverify-x509-name ")
        + (correctName ? (serverRole ? "vpn.test" : "client.test") : "wrong.test") + " name\n";
    text += "<ca>\n" + Read(directory + "/" + ca + ".crt") + "</ca>\n"
        + "<cert>\n" + Read(directory + "/" + identity + ".crt") + "</cert>\n"
        + "<key>\n" + Read(directory + "/" + identity + ".key") + "</key>\n";
    auto options = OptionList::parse_from_config_static(text, nullptr);
    Session session;
    session.config = new SSLLib::SSLAPI::Config;
    session.config->set_rng(StrongRandomAPI::Ptr(new SSLLib::RandomAPI()));
    session.config->set_frame(Frame::Ptr(new Frame(Frame::Context(128, 4096, 3968, 0, 16, 0))));
    session.config->load(options, SSLConfigAPI::LF_PARSE_MODE);
    session.factory = session.config->new_factory();
    session.ssl = session.factory->ssl();
    return session;
}

bool Transfer(SSLAPI &sender, SSLAPI &receiver, bool &delivered)
{
    bool progress = false;
    while (sender.read_ciphertext_ready()) {
        receiver.write_ciphertext(sender.read_ciphertext());
        progress = true;
    }
    if (receiver.read_cleartext_ready()) {
        unsigned char data[64];
        const auto size = receiver.read_cleartext(data, sizeof(data));
        if (size > 0) {
            if (std::string(reinterpret_cast<char *>(data), size) != "ping")
                throw std::runtime_error("TLS application payload did not match");
            delivered = true;
        }
        progress = true;
    }
    return progress;
}

int Handshake(const std::string &directory, bool trusted, bool correctName, bool serverRole)
{
    try {
        auto server = MakeSession(directory, true, true, true, serverRole);
        auto client = MakeSession(directory, false, trusted, correctName, serverRole);
        client.ssl->start_handshake();
        bool written = false;
        bool delivered = false;
        for (int round = 0; round < 100; ++round) {
            if (!written) written = client.ssl->write_cleartext_unbuffered("ping", 4) == 4;
            const bool sent = Transfer(*client.ssl, *server.ssl, delivered);
            const bool received = Transfer(*server.ssl, *client.ssl, delivered);
            if (delivered) return 0;
            if (!sent && !received) throw std::runtime_error("TLS handshake stalled");
        }
        throw std::runtime_error("TLS handshake did not finish");
    } catch (const MbedTLSException &error) {
        return error.get_errnum();
    }
}

int main(int count, char **values)
{
    if (count != 3) return 2;
    try {
        const std::string directory = values[1];
        if (std::string(values[2]) == "unpatched") {
            if (Handshake(directory, true, true, true) != MBEDTLS_ERR_SSL_CERTIFICATE_VERIFICATION_WITHOUT_HOSTNAME)
                throw std::runtime_error("Original 0x5D80 failure was not reproduced");
            std::cout << "PASS original source reproduces TLS error 0x5D80\n";
            return 0;
        }
        if (Handshake(directory, true, true, true) != 0) throw std::runtime_error("Valid peer rejected");
        std::cout << "PASS trusted CA and matching OpenVPN identity complete handshake\n";
        if (Handshake(directory, false, true, true) != MBEDTLS_ERR_X509_CERT_VERIFY_FAILED)
            throw std::runtime_error("Untrusted CA was not rejected by certificate verification");
        std::cout << "PASS untrusted CA rejected\n";
        if (Handshake(directory, true, false, true) != MBEDTLS_ERR_X509_CERT_VERIFY_FAILED)
            throw std::runtime_error("Wrong OpenVPN identity was not rejected");
        std::cout << "PASS mismatched verify-x509-name rejected\n";
        const int roleError = Handshake(directory, true, true, false);
        if (roleError != MBEDTLS_ERR_SSL_HANDSHAKE_FAILURE && roleError != MBEDTLS_ERR_X509_CERT_VERIFY_FAILED)
            throw std::runtime_error("Client-only certificate did not fail TLS role checks");
        std::cout << "PASS client-only certificate cannot complete a server handshake, error=" << roleError << '\n';
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
