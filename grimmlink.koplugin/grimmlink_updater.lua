local logger = require("logger")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local DataStorage = require("datastorage")

local Updater = {
    GITHUB_REPO = "0xstillb/grimmlink",
    GITHUB_API_BASE = "https://api.github.com",
    RELEASE_ASSET_NAME = "grimmlink.koplugin.zip",
    ALTERNATE_ASSET_PATTERN = "grimmlink-v%s.zip",
    CACHE_DURATION = 3600,
    STARTUP_CHECK_INTERVAL = 86400,
    HTTP_TIMEOUT = 15,
    DOWNLOAD_TIMEOUT = 60,
    BACKUP_KEEP_COUNT = 3,
    updater_key_prefix = "updater_",
    plugin_dir = nil,
    backup_dir = nil,
    temp_dir = nil,
    db = nil,
    allow_prerelease = false,
    update_repo = "0xstillb/grimmlink",
}

local function safeStr(value)
    if value == nil then
        return nil
    end
    return tostring(value)
end

local function shellQuote(value)
    local raw = safeStr(value) or ""
    return "'" .. raw:gsub("'", [["'"']]) .. "'"
end

local function runCommand(command)
    local result = os.execute(command)
    if type(result) == "number" then
        return result == 0
    end
    if type(result) == "boolean" then
        return result
    end
    return false
end

local function readCommand(command)
    local handle = io.popen(command)
    if not handle then
        return false, "failed to execute command"
    end
    local output = handle:read("*a")
    local ok = handle:close()
    if type(ok) == "number" then
        ok = ok == 0
    elseif ok == nil then
        ok = false
    end
    return ok, output
end

local function getHeader(headers, key)
    if type(headers) ~= "table" then
        return nil
    end
    return headers[key] or headers[key:lower()] or headers[key:upper()]
end

function Updater:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Updater:normalizeRepo(update_repo)
    local normalized = safeStr(update_repo)
    if normalized ~= self.GITHUB_REPO then
        if normalized and normalized ~= "" then
            logger.warn("GrimmLink Updater: forcing official repo", self.GITHUB_REPO, "instead of", normalized)
        end
        return self.GITHUB_REPO
    end
    return normalized
end

function Updater:init(plugin_dir, db, options)
    options = options or {}
    self.plugin_dir = plugin_dir
    self.db = db
    self.allow_prerelease = options.allow_prerelease == true
    self.update_repo = self:normalizeRepo(options.update_repo)
    self.command_runner = options.command_runner
    self.command_reader = options.command_reader
    self.backup_dir = DataStorage:getDataDir() .. "/grimmlink-backups"
    self.temp_dir = DataStorage:getDataDir() .. "/grimmlink-update-" .. tostring(os.time())

    self:_runCommand("mkdir -p " .. shellQuote(self.backup_dir))
    return true
end

function Updater:_runCommand(command)
    if type(self.command_runner) == "function" then
        return self.command_runner(command)
    end
    return runCommand(command)
end

function Updater:_readCommand(command)
    if type(self.command_reader) == "function" then
        return self.command_reader(command)
    end
    return readCommand(command)
end

function Updater:setAllowPrerelease(allowed)
    self.allow_prerelease = allowed == true
end

function Updater:getCurrentVersion()
    local version_file = (self.plugin_dir or "") .. "/plugin_version.lua"
    local ok, version_info = pcall(dofile, version_file)
    if not ok or type(version_info) ~= "table" then
        logger.warn("GrimmLink Updater: failed to read plugin_version.lua")
        return {
            version = "0.0.0-dev",
            version_type = "development",
            git_commit = "unknown",
            build_date = "unknown",
        }
    end
    return version_info
end

function Updater:parseVersion(version_string)
    if not version_string then
        return nil
    end

    local raw = tostring(version_string):gsub("^v", "")
    if raw:match("dev") then
        return { major = 0, minor = 0, patch = 0, is_dev = true }
    end

    local major, minor, patch = raw:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then
        return nil
    end

    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        is_dev = false,
    }
end

function Updater:compareVersions(v1, v2)
    if not v1 or not v2 then
        return 0
    end

    if v1.is_dev and not v2.is_dev then
        return -1
    end
    if not v1.is_dev and v2.is_dev then
        return 1
    end
    if v1.is_dev and v2.is_dev then
        return 0
    end

    if v1.major ~= v2.major then
        return v1.major < v2.major and -1 or 1
    end
    if v1.minor ~= v2.minor then
        return v1.minor < v2.minor and -1 or 1
    end
    if v1.patch ~= v2.patch then
        return v1.patch < v2.patch and -1 or 1
    end
    return 0
end

function Updater:formatBytes(bytes)
    local value = tonumber(bytes)
    if not value or value <= 0 then
        return "Unknown size"
    end
    if value < 1024 then
        return string.format("%d B", value)
    end
    if value < (1024 * 1024) then
        return string.format("%.1f KB", value / 1024)
    end
    return string.format("%.1f MB", value / (1024 * 1024))
end

function Updater:getExpectedAssetNames(version)
    local version_tag = (safeStr(version or "") or ""):gsub("^v", "")
    return {
        self.RELEASE_ASSET_NAME,
        string.format(self.ALTERNATE_ASSET_PATTERN, version_tag),
    }
end

function Updater:_makeHttpRequest(url, headers, max_redirects)
    max_redirects = max_redirects or 5
    local current_url = url
    local redirects = 0

    while redirects <= max_redirects do
        local response_body = {}
        local request_headers = headers or {}
        request_headers["User-Agent"] = request_headers["User-Agent"] or "GrimmLink-KOReader-Plugin"
        request_headers["Accept"] = request_headers["Accept"] or "application/vnd.github+json"

        local protocol = current_url:match("^https://") and https or http
        protocol.TIMEOUT = self.HTTP_TIMEOUT

        local _, code, response_headers = protocol.request{
            url = current_url,
            method = "GET",
            headers = request_headers,
            sink = ltn12.sink.table(response_body),
        }

        if type(code) ~= "number" then
            return false, "connection failed: " .. tostring(code)
        end

        local response_text = table.concat(response_body)
        if code >= 300 and code < 400 then
            local location = getHeader(response_headers, "location")
            if not location then
                return false, "redirect without location"
            end
            if location:sub(1, 1) == "/" then
                local base_url = current_url:match("^(https?://[^/]+)")
                location = (base_url or "") .. location
            end
            redirects = redirects + 1
            current_url = location
        elseif code >= 200 and code < 300 then
            return true, response_text, code, response_headers
        else
            return false, response_text ~= "" and response_text or ("HTTP " .. tostring(code)), code, response_headers
        end
    end

    return false, "too many redirects"
end

function Updater:_resolveDownloadUrl(url, max_redirects)
    max_redirects = max_redirects or 5
    local current_url = url
    local redirects = 0

    while redirects <= max_redirects do
        local protocol = current_url:match("^https://") and https or http
        protocol.TIMEOUT = self.DOWNLOAD_TIMEOUT

        local _, code, response_headers = protocol.request{
            url = current_url,
            method = "HEAD",
            headers = {
                ["User-Agent"] = "GrimmLink-KOReader-Plugin",
                ["Accept"] = "application/octet-stream",
            },
            sink = ltn12.sink.table({}),
        }

        if type(code) ~= "number" then
            return false, "connection failed: " .. tostring(code)
        end

        if code >= 300 and code < 400 then
            local location = getHeader(response_headers, "location")
            if not location then
                return false, "redirect without location"
            end
            if location:sub(1, 1) == "/" then
                local base_url = current_url:match("^(https?://[^/]+)")
                location = (base_url or "") .. location
            end
            redirects = redirects + 1
            current_url = location
        elseif code >= 200 and code < 300 then
            return true, current_url, response_headers
        else
            return false, "download head request failed: HTTP " .. tostring(code)
        end
    end

    return false, "too many redirects"
end

function Updater:selectReleaseAsset(release_data)
    if type(release_data) ~= "table" or type(release_data.assets) ~= "table" then
        return nil
    end

    local expected_names = {}
    for _, name in ipairs(self:getExpectedAssetNames(release_data.tag_name or release_data.version)) do
        expected_names[name] = true
    end

    for _, asset in ipairs(release_data.assets) do
        if expected_names[asset.name] then
            return {
                name = asset.name,
                download_url = asset.browser_download_url,
                size = tonumber(asset.size) or 0,
            }
        end
    end
    return nil
end

function Updater:normalizeReleaseInfo(release_data)
    if type(release_data) ~= "table" then
        return nil, "invalid release payload"
    end

    local asset = self:selectReleaseAsset(release_data)
    if not asset then
        local expected = table.concat(self:getExpectedAssetNames(release_data.tag_name or release_data.version), " or ")
        return nil, "release asset not found (" .. expected .. ")"
    end

    local version = safeStr(release_data.tag_name)
    if not version or version == "" then
        return nil, "missing tag_name"
    end

    return {
        version = version,
        download_url = asset.download_url,
        asset_name = asset.name,
        size = asset.size,
        prerelease = release_data.prerelease == true,
        published_at = safeStr(release_data.published_at) or "",
        changelog = safeStr(release_data.body) or "",
    }, nil
end

function Updater:extractLatestRelease(api_data)
    if self.allow_prerelease then
        if type(api_data) ~= "table" then
            return nil, "invalid GitHub response"
        end
        for _, release_data in ipairs(api_data) do
            local release_info = self:normalizeReleaseInfo(release_data)
            if release_info then
                return release_info, nil
            end
        end
        return nil, "no usable release found"
    end

    return self:normalizeReleaseInfo(api_data)
end

function Updater:getLatestRelease()
    local url
    if self.allow_prerelease then
        url = string.format("%s/repos/%s/releases?per_page=10", self.GITHUB_API_BASE, self.update_repo)
    else
        url = string.format("%s/repos/%s/releases/latest", self.GITHUB_API_BASE, self.update_repo)
    end

    local success, response_text = self:_makeHttpRequest(url)
    if not success then
        return nil, "failed to fetch release info: " .. tostring(response_text)
    end

    local ok, payload = pcall(json.decode, response_text)
    if not ok then
        return nil, "invalid GitHub JSON response"
    end

    return self:extractLatestRelease(payload)
end

function Updater:_cacheKey(name)
    return self.updater_key_prefix .. name
end

function Updater:getCachedReleaseInfo()
    if not self.db or type(self.db.getPluginSetting) ~= "function" then
        return nil
    end

    local cached_at = tonumber(self.db:getPluginSetting(self:_cacheKey("latest_release_cached_at")))
    local cached_json = self.db:getPluginSetting(self:_cacheKey("latest_release_json"))
    if not cached_at or not cached_json then
        return nil
    end
    if (os.time() - cached_at) > self.CACHE_DURATION then
        return nil
    end

    local ok, release_info = pcall(json.decode, cached_json)
    if not ok or type(release_info) ~= "table" then
        return nil
    end
    return release_info
end

function Updater:cacheReleaseInfo(release_info)
    if not self.db or type(self.db.savePluginSetting) ~= "function" then
        return false
    end
    self.db:savePluginSetting(self:_cacheKey("latest_release_json"), json.encode(release_info))
    self.db:savePluginSetting(self:_cacheKey("latest_release_cached_at"), os.time())
    return true
end

function Updater:clearCache()
    if not self.db or type(self.db.savePluginSetting) ~= "function" then
        return false
    end
    self.db:savePluginSetting(self:_cacheKey("latest_release_json"), nil)
    self.db:savePluginSetting(self:_cacheKey("latest_release_cached_at"), nil)
    return true
end

function Updater:checkForUpdates(use_cache)
    local current_info = self:getCurrentVersion()
    local release_info = use_cache and self:getCachedReleaseInfo() or nil

    if not release_info then
        local error_msg
        release_info, error_msg = self:getLatestRelease()
        if not release_info then
            return nil, error_msg
        end
        self:cacheReleaseInfo(release_info)
    end

    local current_parsed = self:parseVersion(current_info.version)
    local latest_parsed = self:parseVersion(release_info.version)
    if not current_parsed or not latest_parsed then
        return nil, "failed to parse version information"
    end

    return {
        available = self:compareVersions(current_parsed, latest_parsed) < 0,
        current_version = current_info.version,
        latest_version = release_info.version,
        release_info = release_info,
    }, nil
end

function Updater:downloadReleaseAsset(url, progress_callback)
    self:_runCommand("mkdir -p " .. shellQuote(self.temp_dir))
    local zip_path = self.temp_dir .. "/grimmlink-update.zip"
    local file, err = io.open(zip_path, "wb")
    if not file then
        return false, "failed to create download file: " .. tostring(err)
    end

    local resolved_ok, resolved_url, response_headers = self:_resolveDownloadUrl(url)
    if not resolved_ok then
        local success, response_text = self:_makeHttpRequest(url, {
            ["User-Agent"] = "GrimmLink-KOReader-Plugin",
            ["Accept"] = "application/octet-stream",
        })
        if not success then
            file:close()
            self:_runCommand("rm -f " .. shellQuote(zip_path))
            return false, resolved_url
        end
        file:write(response_text)
        file:close()
        if progress_callback then
            progress_callback(#response_text, #response_text)
        end
        return true, zip_path
    end

    local total_bytes = tonumber(getHeader(response_headers, "content-length")) or 0
    local bytes_downloaded = 0
    local function sink(chunk)
        if chunk then
            file:write(chunk)
            bytes_downloaded = bytes_downloaded + #chunk
            if progress_callback then
                progress_callback(bytes_downloaded, total_bytes)
            end
        end
        return 1
    end

    local protocol = resolved_url:match("^https://") and https or http
    protocol.TIMEOUT = self.DOWNLOAD_TIMEOUT
    local _, code = protocol.request{
        url = resolved_url,
        method = "GET",
        headers = {
            ["User-Agent"] = "GrimmLink-KOReader-Plugin",
            ["Accept"] = "application/octet-stream",
        },
        sink = sink,
    }
    file:close()

    if type(code) ~= "number" or code < 200 or code >= 300 then
        self:_runCommand("rm -f " .. shellQuote(zip_path))
        return false, "download failed: HTTP " .. tostring(code)
    end

    return true, zip_path
end

function Updater:_validateZipStructure(zip_path)
    local success, output = self:_readCommand("unzip -l " .. shellQuote(zip_path) .. " 2>&1")
    if not success then
        return false, "failed to inspect ZIP archive"
    end

    local has_main = output:match("grimmlink%.koplugin/main%.lua")
    local has_meta = output:match("grimmlink%.koplugin/_meta%.lua")
    local has_version = output:match("grimmlink%.koplugin/plugin_version%.lua")
    if not has_main or not has_meta or not has_version then
        return false, "ZIP does not contain a valid grimmlink.koplugin package"
    end
    return true, nil
end

function Updater:_extractZip(zip_path, extract_dir)
    self:_runCommand("mkdir -p " .. shellQuote(extract_dir))
    local ok = self:_runCommand("unzip -q -o " .. shellQuote(zip_path) .. " -d " .. shellQuote(extract_dir))
    if not ok then
        return false, "failed to extract update archive"
    end
    return true, nil
end

function Updater:backupCurrentVersion()
    self:_runCommand("mkdir -p " .. shellQuote(self.backup_dir))
    local version = self:getCurrentVersion().version or "unknown"
    local backup_name = string.format("grimmlink-%s-%s", version, os.date("%Y%m%d-%H%M%S"))
    local backup_path = self.backup_dir .. "/" .. backup_name
    local ok = self:_runCommand("cp -R " .. shellQuote(self.plugin_dir) .. " " .. shellQuote(backup_path))
    if not ok then
        return false, "failed to create plugin backup"
    end
    self:cleanupOldBackups(self.BACKUP_KEEP_COUNT)
    return true, backup_path
end

function Updater:cleanupOldBackups(keep_count)
    keep_count = tonumber(keep_count) or self.BACKUP_KEEP_COUNT
    local ok, output = self:_readCommand("ls -t " .. shellQuote(self.backup_dir) .. " 2>&1")
    if not ok then
        return 0
    end

    local backups = {}
    for line in output:gmatch("[^\r\n]+") do
        if line:match("^grimmlink%-") then
            backups[#backups + 1] = line
        end
    end

    local removed = 0
    for index = keep_count + 1, #backups do
        local path = self.backup_dir .. "/" .. backups[index]
        if self:_runCommand("rm -rf " .. shellQuote(path)) then
            removed = removed + 1
        end
    end
    return removed
end

function Updater:cleanupTempFiles()
    if self.temp_dir and self.temp_dir ~= "" then
        self:_runCommand("rm -rf " .. shellQuote(self.temp_dir))
    end
    return true
end

function Updater:rollbackToLatestBackup()
    local ok, output = self:_readCommand("ls -t " .. shellQuote(self.backup_dir) .. " 2>&1")
    if not ok then
        return false, "failed to list backups"
    end

    local latest_backup = nil
    for line in output:gmatch("[^\r\n]+") do
        if line:match("^grimmlink%-") then
            latest_backup = line
            break
        end
    end
    if not latest_backup then
        return false, "no GrimmLink backup is available"
    end

    local backup_path = self.backup_dir .. "/" .. latest_backup
    self:_runCommand("rm -rf " .. shellQuote(self.plugin_dir))
    local restored = self:_runCommand("cp -R " .. shellQuote(backup_path) .. " " .. shellQuote(self.plugin_dir))
    if not restored then
        return false, "failed to restore latest backup"
    end
    return true, backup_path
end

function Updater:installDownloadedUpdate(zip_path)
    local valid, error_msg = self:_validateZipStructure(zip_path)
    if not valid then
        return false, error_msg
    end

    local extract_dir = self.temp_dir .. "/extract"
    local ok = self:_extractZip(zip_path, extract_dir)
    if not ok then
        return false, "failed to extract update archive"
    end

    local extracted_plugin_dir = extract_dir .. "/grimmlink.koplugin"
    local probe = io.open(extracted_plugin_dir .. "/main.lua", "r")
    if not probe then
        return false, "grimmlink.koplugin was not found in extracted archive"
    end
    probe:close()

    local backup_ok, backup_result = self:backupCurrentVersion()
    if not backup_ok then
        return false, backup_result
    end

    local rollback_dir = self.temp_dir .. "/rollback-current"
    self:_runCommand("rm -rf " .. shellQuote(rollback_dir))

    local moved_old = self:_runCommand("mv " .. shellQuote(self.plugin_dir) .. " " .. shellQuote(rollback_dir))
    if not moved_old then
        return false, "failed to stage current plugin for replacement"
    end

    local moved_new = self:_runCommand("mv " .. shellQuote(extracted_plugin_dir) .. " " .. shellQuote(self.plugin_dir))
    if not moved_new then
        self:_runCommand("mv " .. shellQuote(rollback_dir) .. " " .. shellQuote(self.plugin_dir))
        return false, "failed to install updated grimmlink.koplugin package"
    end

    self:_runCommand("rm -rf " .. shellQuote(rollback_dir))
    self:cleanupTempFiles()
    return true, backup_result
end

function Updater:installUpdate(release_info, progress_callback)
    if type(release_info) ~= "table" then
        return false, "missing release info"
    end
    local download_url = safeStr(release_info.download_url)
    if not download_url or download_url == "" then
        return false, "missing download URL"
    end

    local downloaded, zip_or_error = self:downloadReleaseAsset(download_url, progress_callback)
    if not downloaded then
        self:cleanupTempFiles()
        return false, zip_or_error
    end

    local installed, backup_or_error = self:installDownloadedUpdate(zip_or_error)
    if not installed then
        self:cleanupTempFiles()
        return false, backup_or_error
    end

    self:clearCache()
    return true, backup_or_error
end

return Updater
