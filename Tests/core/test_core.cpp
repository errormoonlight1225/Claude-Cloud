// Small CLI over kiln_core used by test.sh.
#include <fstream>
#include <iostream>
#include <sstream>

#include "kiln_core.h"

static std::string ReadFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

static void WriteFile(const std::string& path, const std::string& data) {
    std::ofstream out(path, std::ios::binary);
    out << data;
}

static int Fail(const std::string& error) {
    std::cerr << "ERROR: " << error << std::endl;
    return 1;
}

int main(int argc, char** argv) {
    if (argc < 2) return Fail("usage: test_core <command> ...");
    std::string cmd = argv[1];
    std::string error;

    if (cmd == "csr" && argc == 5) {
        std::string key, csr;
        if (!kiln::GenerateCSR(argv[2], key, csr, error)) return Fail(error);
        WriteFile(argv[3], key);
        WriteFile(argv[4], csr);
        return 0;
    }
    if (cmd == "p12" && argc == 6) {
        std::string p12;
        if (!kiln::MakePKCS12(ReadFile(argv[2]), {}, ReadFile(argv[3]), argv[4], "Kiln Test", p12, error))
            return Fail(error);
        WriteFile(argv[5], p12);
        return 0;
    }
    if (cmd == "parsep12" && argc == 6) {
        kiln::Identity id;
        if (!kiln::ParsePKCS12(ReadFile(argv[2]), argv[3], id, error)) return Fail(error);
        WriteFile(argv[4], id.certificateDER);
        WriteFile(argv[5], id.privateKeyPEM);
        std::cout << "chain=" << id.chainDER.size() << std::endl;
        return 0;
    }
    if (cmd == "pair" && argc == 5) {
        kiln::Identity id;
        if (!kiln::ParseCertificateAndKey(ReadFile(argv[2]), ReadFile(argv[3]), argv[4], id, error))
            return Fail(error);
        std::cout << "chain=" << id.chainDER.size() << std::endl;
        return 0;
    }
    if (cmd == "info" && argc == 3) {
        kiln::CertificateInfo info;
        if (!kiln::GetCertificateInfo(ReadFile(argv[2]), info, error)) return Fail(error);
        std::cout << "cn=" << info.commonName << "\nou=" << info.organizationalUnit
                  << "\no=" << info.organization << "\nserial=" << info.serialHex
                  << "\nsha1=" << info.sha1Hex << "\nnotAfter=" << info.notAfter << std::endl;
        return 0;
    }
    if (cmd == "cms" && argc == 3) {
        std::string content;
        if (!kiln::DecodeCMS(ReadFile(argv[2]), content, error)) return Fail(error);
        std::cout << content;
        return 0;
    }
    if (cmd == "list" && argc == 3) {
        std::vector<std::string> entries;
        if (!kiln::ListZipEntries(argv[2], entries, error)) return Fail(error);
        for (const auto& e : entries) std::cout << e << "\n";
        return 0;
    }
    if (cmd == "read" && argc == 4) {
        std::string data;
        if (!kiln::ReadZipEntry(argv[2], argv[3], data, 1 << 20, error)) return Fail(error);
        std::cout << data;
        return 0;
    }
    if (cmd == "unzip" && argc == 4) {
        return kiln::ExtractZip(argv[2], argv[3], error) ? 0 : Fail(error);
    }
    if (cmd == "zip" && argc == 4) {
        return kiln::ArchiveFolder(argv[2], argv[3], 6, error) ? 0 : Fail(error);
    }
    if (cmd == "sign" && argc >= 7) {
        kiln::SignOptions o;
        o.certificatePath = argv[3];
        o.privateKeyPath = argv[4];
        for (int i = 5; i < argc - 1; i++) o.profilePaths.push_back(argv[i]);
        o.bundleID = argv[argc - 1];
        o.displayName = "Kiln Test";
        std::string appFolder;
        auto log = [](int level, const std::string& line) { std::cout << "[" << level << "] " << line << "\n"; };
        if (!kiln::SignFolder(argv[2], o, log, appFolder, error)) return Fail(error);
        std::cout << "app=" << appFolder << std::endl;
        return 0;
    }
    return Fail("unknown command or wrong arguments: " + cmd);
}
