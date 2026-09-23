#include "PNGWriter.hpp"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <limits>
#include <unistd.h>
#include <vector>
#include <zlib.h>

namespace pbrlab {
namespace {
void be32(std::vector<uint8_t>& out, uint32_t n) {
    out.push_back(static_cast<uint8_t>(n >> 24));
    out.push_back(static_cast<uint8_t>(n >> 16));
    out.push_back(static_cast<uint8_t>(n >> 8));
    out.push_back(static_cast<uint8_t>(n));
}
uint32_t readBE32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
void chunk(std::vector<uint8_t>& out, const char name[4], const std::vector<uint8_t>& data) {
    be32(out, static_cast<uint32_t>(data.size()));
    const size_t begin = out.size();
    out.insert(out.end(), name, name + 4);
    out.insert(out.end(), data.begin(), data.end());
    uLong crc = crc32(0, nullptr, 0);
    crc = crc32(crc, out.data() + begin, static_cast<uInt>(out.size() - begin));
    be32(out, static_cast<uint32_t>(crc));
}
uint8_t paeth(int a, int b, int c) {
    int p = a + b - c, pa = std::abs(p - a), pb = std::abs(p - b), pc = std::abs(p - c);
    if (pa <= pb && pa <= pc) return static_cast<uint8_t>(a);
    return static_cast<uint8_t>(pb <= pc ? b : c);
}
// Applies filter `type` to `row` given the previous unfiltered row (zeros for the first row).
void filterRow(int type, const uint8_t* row, const uint8_t* prior, size_t length, size_t bpp, uint8_t* out) {
    for (size_t i = 0; i < length; ++i) {
        int a = i >= bpp ? row[i - bpp] : 0, b = prior[i], c = i >= bpp ? prior[i - bpp] : 0;
        int predictor = 0;
        switch (type) {
        case 1: predictor = a; break;
        case 2: predictor = b; break;
        case 3: predictor = (a + b) / 2; break;
        case 4: predictor = paeth(a, b, c); break;
        default: break;
        }
        out[i] = static_cast<uint8_t>(row[i] - predictor);
    }
}
uint8_t unfilterValue(int type, int x, int a, int b, int c) {
    switch (type) {
    case 1: return static_cast<uint8_t>(x + a);
    case 2: return static_cast<uint8_t>(x + b);
    case 3: return static_cast<uint8_t>(x + (a + b) / 2);
    case 4: return static_cast<uint8_t>(x + paeth(a, b, c));
    default: return static_cast<uint8_t>(x);
    }
}
} // namespace

bool encodePNG(const PBRLabMap& map, std::vector<uint8_t>& png, std::string& error) {
    const bool height = map.format == PBRLabPixelFormatR16UNormLE;
    const size_t bpp = height ? 2 : 4;
    const size_t widthBytes = static_cast<size_t>(map.width) * bpp;
    if (!map.pixels || !map.width || !map.height || map.row_bytes < widthBytes ||
        map.byte_count < map.row_bytes * map.height || map.width > 4096 || map.height > 4096) {
        error = "invalid map layout"; return false;
    }
    std::vector<uint8_t> raw;
    raw.reserve((widthBytes + 1) * map.height);
    std::vector<uint8_t> current(widthBytes), prior(widthBytes, 0), candidate(widthBytes), best(widthBytes);
    for (uint32_t y = 0; y < map.height; ++y) {
        const auto* row = map.pixels + static_cast<size_t>(y) * map.row_bytes;
        if (height) {
            for (uint32_t x = 0; x < map.width; ++x) { // PNG samples are network (big-endian) byte order.
                current[x * 2] = row[x * 2 + 1];
                current[x * 2 + 1] = row[x * 2];
            }
        } else std::memcpy(current.data(), row, widthBytes);
        // Minimum-sum-of-absolute-differences adaptive filter selection (deterministic).
        uint64_t bestScore = std::numeric_limits<uint64_t>::max();
        int bestType = 0;
        for (int type = 0; type <= 4; ++type) {
            filterRow(type, current.data(), prior.data(), widthBytes, bpp, candidate.data());
            uint64_t score = 0;
            for (uint8_t v : candidate) score += static_cast<uint64_t>(std::abs(static_cast<int>(static_cast<int8_t>(v))));
            if (score < bestScore) { bestScore = score; bestType = type; best.swap(candidate); }
        }
        raw.push_back(static_cast<uint8_t>(bestType));
        raw.insert(raw.end(), best.begin(), best.end());
        prior.swap(current);
    }
    uLongf compressedSize = compressBound(static_cast<uLong>(raw.size()));
    std::vector<uint8_t> compressed(compressedSize);
    if (compress2(compressed.data(), &compressedSize, raw.data(), static_cast<uLong>(raw.size()), 6) != Z_OK) {
        error = "zlib compression failed"; return false;
    }
    compressed.resize(compressedSize);
    png.assign({137, 80, 78, 71, 13, 10, 26, 10});
    std::vector<uint8_t> ihdr;
    be32(ihdr, map.width); be32(ihdr, map.height);
    ihdr.push_back(height ? 16 : 8);
    ihdr.push_back(height ? 0 : 6); // Grayscale height or RGBA.
    ihdr.insert(ihdr.end(), {0, 0, 0}); // Deflate, adaptive filtering, no interlace.
    chunk(png, "IHDR", ihdr);
    if (map.format == PBRLabPixelFormatRGBA8SRGB) chunk(png, "sRGB", {0});
    else { std::vector<uint8_t> gamma; be32(gamma, 100000); chunk(png, "gAMA", gamma); }
    chunk(png, "IDAT", compressed);
    chunk(png, "IEND", {});
    return true;
}

bool writeFileAtomically(const std::string& path, const std::vector<uint8_t>& bytes, std::string& error) {
    std::string temp = path + ".partial-XXXXXX";
    std::vector<char> pattern(temp.begin(), temp.end());
    pattern.push_back('\0');
    int fd = mkstemp(pattern.data());
    if (fd < 0) { error = "cannot create temporary output: " + std::string(std::strerror(errno)); return false; }
    size_t written = 0;
    while (written < bytes.size()) {
        ssize_t n = ::write(fd, bytes.data() + written, bytes.size() - written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            error = "cannot write output: " + std::string(std::strerror(errno));
            ::close(fd); ::unlink(pattern.data()); return false;
        }
        written += static_cast<size_t>(n);
    }
    const mode_t mask = ::umask(0);
    ::umask(mask);
    if (::fchmod(fd, 0666 & ~mask) != 0 || ::fsync(fd) != 0 || ::close(fd) != 0) {
        error = "cannot flush output: " + std::string(std::strerror(errno));
        ::unlink(pattern.data()); return false;
    }
    if (::rename(pattern.data(), path.c_str()) != 0) {
        error = "cannot rename output into place: " + std::string(std::strerror(errno));
        ::unlink(pattern.data()); return false;
    }
    return true;
}

bool inspectPNG(const uint8_t* p, size_t size, PNGInfo& info, std::string& error) {
    static constexpr uint8_t signature[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    info = PNGInfo{};
    if (!p || size < 8 + 25 + 12 || std::memcmp(p, signature, 8)) { error = "not a PNG"; return false; }
    size_t offset = 8;
    bool sawIHDR = false, sawIEND = false, idatClosed = false, sawIDAT = false;
    std::vector<uint8_t> compressed;
    while (offset < size) {
        if (size - offset < 12) { error = "truncated PNG chunk"; return false; }
        uint32_t length = readBE32(p + offset);
        if (length > 0x7fffffffu || size - offset - 12 < length) { error = "PNG chunk length out of range"; return false; }
        const uint8_t* type = p + offset + 4;
        const uint8_t* data = type + 4;
        uLong crc = crc32(0, nullptr, 0);
        crc = crc32(crc, type, static_cast<uInt>(length + 4));
        if (readBE32(data + length) != static_cast<uint32_t>(crc)) { error = "PNG chunk CRC mismatch"; return false; }
        const bool isIDAT = !std::memcmp(type, "IDAT", 4);
        if (!sawIHDR) {
            if (std::memcmp(type, "IHDR", 4) || length != 13) { error = "PNG must begin with IHDR"; return false; }
            sawIHDR = true;
            info.width = readBE32(data); info.height = readBE32(data + 4);
            info.bitDepth = data[8]; info.colorType = data[9]; info.interlace = data[12];
            if (data[10] != 0 || data[11] != 0) { error = "unsupported PNG compression or filter method"; return false; }
        } else if (!std::memcmp(type, "IHDR", 4)) { error = "duplicate IHDR"; return false; }
        else if (isIDAT) {
            if (idatClosed) { error = "non-contiguous IDAT chunks"; return false; }
            sawIDAT = true;
            compressed.insert(compressed.end(), data, data + length);
        } else if (!std::memcmp(type, "IEND", 4)) {
            sawIEND = true; offset += 12 + length; break;
        } else {
            if (sawIDAT) idatClosed = true;
            if (!std::memcmp(type, "sRGB", 4)) info.hasSRGB = true;
            if (!std::memcmp(type, "gAMA", 4)) info.hasGAMA = true;
            if (!std::memcmp(type, "PLTE", 4)) { error = "palette PNGs are not valid map encodings"; return false; }
        }
        offset += 12 + length;
    }
    if (!sawIEND || offset != size) { error = "PNG must end with IEND and no trailing bytes"; return false; }
    if (!sawIDAT) { error = "PNG has no image data"; return false; }
    if (!info.width || !info.height || info.width > 16384 || info.height > 16384) { error = "PNG dimensions out of range"; return false; }
    if (info.interlace != 0) { error = "interlaced PNGs are not valid map encodings"; return false; }
    size_t channels = 0;
    switch (info.colorType) {
    case 0: channels = 1; break;
    case 2: channels = 3; break;
    case 4: channels = 2; break;
    case 6: channels = 4; break;
    default: error = "unsupported PNG colour type"; return false;
    }
    if (info.bitDepth != 8 && info.bitDepth != 16) { error = "unsupported PNG bit depth"; return false; }
    const size_t bpp = channels * info.bitDepth / 8;
    const size_t stride = static_cast<size_t>(info.width) * bpp;
    const size_t expected = (stride + 1) * info.height;
    std::vector<uint8_t> raw(expected + 1);
    z_stream z{};
    if (inflateInit(&z) != Z_OK) { error = "zlib init failed"; return false; }
    z.next_in = compressed.data(); z.avail_in = static_cast<uInt>(compressed.size());
    z.next_out = raw.data(); z.avail_out = static_cast<uInt>(raw.size());
    int status = inflate(&z, Z_FINISH);
    const size_t produced = raw.size() - z.avail_out;
    const bool trailingInput = z.avail_in != 0;
    inflateEnd(&z);
    if (status != Z_STREAM_END || produced != expected || trailingInput) {
        error = "PNG image data does not inflate to the IHDR size"; return false;
    }
    // Reconstruct every row so a corrupt filter type is caught (and the data is actually decoded).
    std::vector<uint8_t> prior(stride, 0), row(stride);
    for (uint32_t y = 0; y < info.height; ++y) {
        const uint8_t* line = raw.data() + static_cast<size_t>(y) * (stride + 1);
        int type = line[0];
        if (type > 4) { error = "invalid PNG row filter"; return false; }
        for (size_t i = 0; i < stride; ++i) {
            int a = i >= bpp ? row[i - bpp] : 0, c = i >= bpp ? prior[i - bpp] : 0;
            row[i] = unfilterValue(type, line[1 + i], a, prior[i], c);
        }
        prior.swap(row);
    }
    return true;
}
} // namespace pbrlab
