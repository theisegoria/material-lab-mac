#pragma once
#include "PBRMaterialLab.h"
#include <string>

namespace pbrlab {
bool writePNG(const std::string& path, const PBRLabMap& map, std::string& error);
}
