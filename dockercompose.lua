-- luci-app-dockercompose：Docker Compose 项目管理（LuCI 侧边栏）
-- 菜单：Docker > Docker Compose
-- API: /cgi-bin/luci/admin/docker/dockercompose/api/xxx

module("luci.controller.dockercompose", package.seeall)

local http = require "luci.http"
local util = require "luci.util"
local fs = require "nixio.fs"

local SETTINGS_FILE = "/etc/dockercompose.json"
local jsonc_ok, jsonc = pcall(require, "luci.jsonc")
local DEFAULT_DIR = "/mnt/usb1_2-1/Docker Compose"

-- 支持的 compose 文件名（按优先级）
local COMPOSE_FILES = { "docker-compose.yml", "docker-compose.yaml", "compose.yaml", "compose.yml" }

function index()
    entry({"admin", "docker", "dockercompose", "api", "list"}, call("api_list")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "new"}, call("api_new")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "delete"}, call("api_delete")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "up"}, call("api_up")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "down"}, call("api_down")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "restart"}, call("api_restart")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "logs"}, call("api_logs")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "yml_get"}, call("api_yml_get")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "yml_save"}, call("api_yml_save")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "settings_get"}, call("api_settings_get")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "settings_save"}, call("api_settings_save")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "op_start"}, call("op_start")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "op_status"}, call("op_status")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "op_cancel"}, call("op_cancel")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "rename"}, call("api_rename")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "move"}, call("api_move")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "sync"}, call("api_sync")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "note_save"}, call("api_note_save")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "autoup_log"}, call("api_autoup_log")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "log"}, call("api_log")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "log_clear"}, call("api_log_clear")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "image_tags"}, call("api_image_tags")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "arch"}, call("api_arch")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "up_check"}, call("api_up_check")).leaf = true
    entry({"admin", "docker", "dockercompose", "api", "up_status"}, call("api_up_status")).leaf = true
end

function json_out(t)
    http.prepare_content("application/json")
    http.write_json(t or {})
end

-- 统一工作日志：追加写入 /etc/dockercompose.log（操作记录），超过 300KB 自动截断保留尾部 150KB
-- 若 settings.log_keep_days > 0，每天首次写入时自动清理超过保留天数的旧日志
local LOG_FILE = "/etc/dockercompose.log"
local MAX_LOG = 300 * 1024
function log_line(typ, msg)
    local st = load_settings()
    local keep = tonumber(st.log_keep_days) or 0
    if keep > 0 then
        local lastf = "/tmp/dc_log_lastclean"
        local lf = io.open(lastf, "r")
        local last = (lf and lf:read("*a")) or ""
        if lf then lf:close() end
        local today = os.date("%Y-%m-%d")
        if last ~= today then
            local f = io.open(LOG_FILE, "r")
            if f then
                local all = f:read("*a")
                f:close()
                local cutoff = os.date("%Y-%m-%d", os.time() - keep * 86400)
                local lines = {}
                for line in all:gmatch("[^\n]+") do
                    local d = line:match("^%[(%d%d%d%d%-%d%d%-%d%d)")
                    if not (d and d < cutoff) then lines[#lines + 1] = line end
                end
                local f2 = io.open(LOG_FILE, "w")
                if f2 then f2:write(table.concat(lines, "\n") .. "\n"); f2:close() end
            end
            local f3 = io.open(lastf, "w")
            if f3 then f3:write(today); f3:close() end
        end
    end
    local f0 = io.open(LOG_FILE, "r")
    if f0 then
        local sz = f0:seek("end")
        f0:close()
        if sz > MAX_LOG then
            local f1 = io.open(LOG_FILE, "r")
            if f1 then
                local all = f1:read("*a")
                f1:close()
                local f2 = io.open(LOG_FILE, "w")
                if f2 then f2:write(all:sub(-(MAX_LOG / 2))); f2:close() end
            end
        end
    end
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("[%Y-%m-%d %H:%M:%S]") .. " [" .. typ .. "] " .. msg .. "\n")
        f:close()
    end
end

-- 清空日志：src=ops|autoup
function api_log_clear()
    local src = clean(http.formvalue("src"))
    local target = src == "autoup" and "/etc/dockercompose_autoup.log" or LOG_FILE
    local f = io.open(target, "w")
    if f then f:close() end
    log_line("日志", "已清空" .. (src == "autoup" and "自动更新日志" or "操作日志"))
    json_out({ ok = true })
end

-- 读取工作日志 + 自动升级日志
function api_log()
    local f = io.open(LOG_FILE, "r")
    local ops = f and f:read("*a") or ""
    if f then f:close() end
    local f2 = io.open("/etc/dockercompose_autoup.log", "r")
    local au = f2 and f2:read("*a") or ""
    if f2 then f2:close() end
    if ops == "" then ops = "（暂无操作日志）" end
    if au == "" then au = "（暂无自动更新日志）" end
    json_out({ ok = true, ops = ops, autoup = au })
end

-- 目录路径校验：只拒绝控制字符；所有 shell 调用均用 shellquote 转义
function clean_dir(p)
    if not p or p == "" then return nil end
    if #p > 300 then return nil end
    if string.find(p, "%c") then return nil end
    p = string.gsub(p, "//+", "/")
    if p == "/" then return nil end
    return p
end

function clean_name(n)
    if not n or n == "" then return nil end
    if #n > 200 then return nil end
    if string.find(n, "%c") or string.find(n, "[/\\]") then return nil end
    return n
end

-- 清理普通字符串：去控制字符、限长
function clean(s)
    if not s then return "" end
    s = tostring(s)
    if #s > 200 then s = s:sub(1, 200) end
    return s
end

-- 规范化升级时间：兼容 "HH:MM" / "HH:MM:SS"，统一为 "HH:MM"（只提取时:分，不误删分钟）
function clean_time(s)
    local v = clean(s)
    if v == "" then return v end
    -- 支持多时间点（逗号分隔），每个规范化为 HH:MM
    local parts = {}
    for part in v:gmatch("[^,]+") do
        local h, m = part:match("^(%d+):(%d+)")
        if h and m then parts[#parts + 1] = h .. ":" .. m end
    end
    if #parts > 0 then return table.concat(parts, ",") end
    return v
end

function is_dir(st)
    return st and (st.type == "dir" or st.mode == "directory" or st.mode == "dir")
end

-- 归一化镜像加速地址列表（去协议/斜杠，过滤空项）
local function norm_mirrors(v)
    local out = {}
    if type(v) == "table" then
        for _, m in ipairs(v) do
            local mm = tostring(m or ""):gsub("^https?://", ""):gsub("/+$", ""):gsub("^/", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if mm ~= "" then out[#out + 1] = mm end
        end
    elseif type(v) == "string" then
        for m in v:gmatch("[^,%s]+") do
            local mm = m:gsub("^https?://", ""):gsub("/+$", ""):gsub("^/", "")
            if mm ~= "" then out[#out + 1] = mm end
        end
    end
    return out
end
-- 默认加速地址（至少 3 个互相备份；docker.io 直连不通时依次尝试）
local DEFAULT_MIRRORS = { "docker.1ms.run", "docker.m.daocloud.io", "docker.1panel.live" }

function load_settings()
    if fs.access(SETTINGS_FILE) then
        local f = io.open(SETTINGS_FILE, "r")
        if f then
            local s = f:read("*a"); f:close()
            if jsonc_ok then
                local ok, d = pcall(jsonc.parse, s)
                if ok and type(d) == "table" and type(d.dir) == "string" then
                    local ms = norm_mirrors(d.check_mirrors)
                    if #ms == 0 then
                        -- 兼容旧版单值 check_mirror；再没有则用默认
                        ms = norm_mirrors(d.check_mirror)
                    end
                    if #ms == 0 then ms = DEFAULT_MIRRORS end
                    d.check_mirrors = ms
                    if not d.mirror_mode then d.mirror_mode = "auto" end
                    return d
                end
            end
        end
    end
    return { dir = DEFAULT_DIR, check_mirrors = DEFAULT_MIRRORS, mirror_mode = "auto" }
end

-- 读取系统已配置的镜像加速源（优先 OpenWrt UCI /etc/config/dockerd，其次 /etc/docker/daemon.json）
-- 注意：定义为全局函数，供 api_settings_get / check_mirror_hosts 调用
function system_mirrors()
    local out = {}
    local f = io.open("/etc/config/dockerd", "r")
    if f then
        local s = f:read("*a"); f:close()
        for m in s:gmatch("https?://[^%s'\"%]},]+") do
            local h = m:gsub("^https?://", ""):gsub("/+$", ""):gsub("^/", "")
            if h ~= "" then out[#out + 1] = h end
        end
    end
    if #out == 0 then
        local f2 = io.open("/etc/docker/daemon.json", "r")
        if f2 then
            local s2 = f2:read("*a"); f2:close()
            for m in s2:gmatch('"https?://[^"%s]+"') do
                local h = m:gsub('"', ""):gsub("^https?://", ""):gsub("/+$", ""):gsub("^/", "")
                if h ~= "" then out[#out + 1] = h end
            end
        end
    end
    return out
end

function save_settings(t)
    if not jsonc_ok then return false end
    local f = io.open(SETTINGS_FILE, "w")
    if not f then return false end
    f:write(jsonc.stringify(t or {})); f:close()
    return true
end

-- 执行 shell 命令；返回 (ok, output)，带超时（BusyBox timeout）
function sh(cmd, t)
    t = t or 60
    local f = io.popen("timeout " .. t .. " sh -c " .. util.shellquote(cmd) .. " 2>&1", "r")
    if not f then return false, "无法执行命令" end
    local out = f:read("*a")
    local ok = f:close()
    return ok == true, out or ""
end

-- 查找目录下的 compose 文件，返回文件名或 nil
function find_compose(d)
    if not fs.access(d) then return nil end
    for _, fn in ipairs(COMPOSE_FILES) do
        if fs.access(d .. "/" .. fn) then return fn end
    end
    return nil
end

-- 读取项目中文备注（.name 文件），无则返回空串
function read_note(d)
    local nf = io.open(d .. "/.name", "r")
    if nf then
        local s = nf:read("*a") or ""
        nf:close()
        return s:gsub("%s+$", "")
    end
    return ""
end

-- ============ API ============

-- 项目列表（含运行状态）
-- 解析 compose 文件信息：容器名 / 端口 / 映射路径（供首页卡片展示；相对路径拼项目目录为真实路径）
local function parse_yml_info(fp, dir)
    local f = io.open(fp, "r")
    if not f then return {}, {}, {} end
    local y = f:read("*a"); f:close()
    local containers, ports, volumes = {}, {}, {}
    local sc, sp, sv = {}, {}, {}
    for c in y:gmatch("container_name:%s*([%w][%w_.-]*)") do
        if not sc[c] then sc[c] = true; containers[#containers + 1] = c end
    end
    for p in y:gmatch('%-%s*"(%d+):%d+') do
        if not sp[p] then sp[p] = true; ports[#ports + 1] = p end
    end
    for p in y:gmatch('%-%s*(%d+):%d+') do
        if not sp[p] then sp[p] = true; ports[#ports + 1] = p end
    end
    for line in y:gmatch("[^\r\n]+") do
        -- 挂载行：- "宿主机路径:容器路径"（引号可选，宿主机路径支持含空格，相对路径 ./ 拼项目目录为真实路径）
        local v = line:match("^%s*%-%s*[\"']?([%./][^\"']+)[\"']?%s*$")
        if v then
            local hv, cv = v:match("^([^:]+):(.+)$")
            if hv and cv then
                if hv:sub(1, 1) == "." then hv = (dir or "") .. hv:sub(2) end
                if not sv[hv] then sv[hv] = true; volumes[#volumes + 1] = hv end
            end
        end
    end
    return containers, ports, volumes
end

-- 收集已占用端口：docker 容器映射 + 其他项目 yml
local function collect_used_ports(root, cur)
    local used = {}
    local ok, out = sh("docker ps -a --format '{{.Ports}}' 2>/dev/null", 15)
    if out then
        for m in out:gmatch("0%.0%.0%.0:(%d+)%-%>") do used[m] = true end
        for m in out:gmatch(":::(%d+)%-%>") do used[m] = true end
    end
    local ok2, ls = sh("ls -d " .. util.shellquote(root) .. "/*/ 2>/dev/null", 10)
    if ls then
        for d in ls:gmatch("[^\r\n]+") do
            d = d:gsub("/%s*$", "")
            if d ~= cur then
                for _, fn in ipairs({ "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" }) do
                    local fp = d .. "/" .. fn
                    if fs.access(fp) then
                        local f = io.open(fp, "r")
                        if f then
                            local y = f:read("*a"); f:close()
                            for m in y:gmatch('%-%s*"(%d+):%d+') do used[m] = true end
                            for m in y:gmatch('%-%s*(%d+):%d+') do used[m] = true end
                        end
                    end
                end
            end
        end
    end
    return used
end

-- 端口冲突自动顺延：逐个替换冲突的宿主机端口，返回 是否改动 / 新内容 / 提示列表
local function fix_ports(root, project_dir, content)
    local used = collect_used_ports(root, project_dir)
    local lines = {}
    for line in content:gmatch("([^\r\n]*)\r?\n?") do lines[#lines + 1] = line end
    local changed, noti = false, {}
    for i, l in ipairs(lines) do
        local ind, host, rest = l:match("^(%s*)%-%s*\"(%d+):(.-)\"%s*$")
        local q = true
        if not host then
            ind, host, rest = l:match("^(%s*)%-%s*(%d+):(.-)%s*$")
            q = false
        end
        if host then
            local np = host
            while used[np] do np = tostring(tonumber(np) + 1) end
            if np ~= host then
                if q then
                    lines[i] = ind .. '- "' .. np .. ':' .. rest .. '"'
                else
                    lines[i] = ind .. '- ' .. np .. ':' .. rest
                end
                used[np] = true
                noti[#noti + 1] = host .. " → " .. np
                changed = true
            else
                used[host] = true
            end
        end
    end
    return changed, table.concat(lines, "\n"), noti
end

function api_list()
    local s = load_settings()
    local dir = clean_dir(s.dir) or DEFAULT_DIR
    local items = {}
    local seen = {}

    if fs.access(dir) then
        local ok, iter, obj = pcall(fs.dir, dir)
        if ok then
            for name in iter, obj do
                if name ~= "." and name ~= ".." and not name:find("^%.") then
                    local sub = dir .. "/" .. name
                    local st = fs.stat(sub)
                    if st and is_dir(st) then
                        local yml = find_compose(sub)
                        if yml and not seen[sub] then
                            seen[sub] = true
                            local note = read_note(sub)
                            items[#items + 1] = { name = name, dir = sub, yml = yml, note = note }
                        end
                    end
                end
            end
        end
        -- 根目录本身有 compose 文件时也列为一个项目
        local top_yml = find_compose(dir)
        if top_yml then
            local nm = string.match(dir, "([^/]+)$") or dir
            local note = read_note(dir)
            table.insert(items, 1, { name = nm, dir = dir, yml = top_yml, note = note })
        end
    end

    -- 运行状态：docker compose ls -a
    local ok, out = sh("docker compose ls -a --format json 2>/dev/null", 30)
    local status = {}
    if ok and out and out ~= "" and jsonc_ok then
        local ok2, arr = pcall(jsonc.parse, out)
        if ok2 and type(arr) == "table" then
            for _, pr in ipairs(arr) do
                local cf = pr.ConfigFiles or ""
                local sts = pr.Status or ""
                for _, it in ipairs(items) do
                    if cf:find(it.dir, 1, true) == 1 then
                        status[it.name] = sts
                    end
                end
            end
        end
    end

    -- 容器运行时长 + 镜像版本：docker ps 的 Status（Up 3 days / Up About an hour…）与 Image
    local ok4, out4 = sh("docker ps -a --format '{{.Names}}\\t{{.Status}}\\t{{.Image}}' 2>/dev/null", 15)
    local uptime = {}
    local cimg = {}
    if ok4 and out4 then
        for line in out4:gmatch("[^\r\n]+") do
            local cname, sts, img = line:match("^(.-)\t(.+)\t(.+)$")
            if cname and sts then
                local up = sts:match("^Up (.*)$")
                if up then uptime[cname] = up end
            end
            if cname and img then cimg[cname] = img end
        end
    end

    for _, it in ipairs(items) do
        it.status = status[it.name] or ""
        if it.status == "" then it.status = "未创建" end
        local yst = fs.stat(it.dir .. "/" .. it.yml)
        it.mtime = yst and yst.mtime and os.date("%Y-%m-%d %H:%M", yst.mtime) or ""
        local cs, ps, vs = parse_yml_info(it.dir .. "/" .. it.yml, it.dir)
        it.containers = cs or {}
        it.ports = ps or {}
        it.volumes = vs or {}
        it.uptime = ""
        it.cver = ""
        for _, c in ipairs(it.containers) do
            if uptime[c] and uptime[c] ~= "" then it.uptime = uptime[c]; break end
        end
        for _, c in ipairs(it.containers) do
            local img = cimg[c]
            if img then
                local t = img:match(":([^:/]+)$")
                it.cver = t or img
                break
            end
        end
    end

    -- 空列表时必须输出 JSON 空数组 []（Lua 空 table 会被序列化为 {}，前端 forEach 会崩）
    if #items == 0 and jsonc_ok and jsonc.array then
        items = jsonc.array()
    end
    local okp, outp = sh("command -v docker-compose 2>/dev/null | xargs readlink -f 2>/dev/null", 10)
    local compose_path = "未找到"
    if okp and outp then
        local p = outp:gsub("%s+$", "")
        if p ~= "" then compose_path = p end
    end
    json_out({ dir = dir, entries = items, compose_path = compose_path })
end

-- 新建项目：建子目录 + 写入 yaml（content 为空则用模板），可选立即启动
function api_new()
    local s = load_settings()
    local dir = clean_dir(s.dir) or DEFAULT_DIR
    local name = clean_name(http.formvalue("name"))
    if not name then json_out({ error = "项目名不合法" }); return end
    if name:find("^%.") then json_out({ error = "项目名不合法" }); return end
    -- 确保项目根目录存在（根目录丢失/首次使用时自动创建在 settings.dir 下）
    if not fs.access(dir) then
        local okr = os.execute("mkdir -p " .. util.shellquote(dir))
        if not okr then json_out({ error = "根目录创建失败" }); return end
    end
    local d = dir .. "/" .. name
    if fs.access(d) then json_out({ error = "项目已存在" }); return end
    local content = http.formvalue("content")
    if content == nil or content == "" then
        content = "# " .. name .. "\nservices:\n  app:\n    image: your-image:latest\n    restart: unless-stopped\n"
    end
    -- 端口冲突自动顺延：检测与 docker 容器/其他项目的端口占用，冲突则顺延到下一个可用端口
    local notice = nil
    local ch, nc, noti = fix_ports(dir, d, content)
    if ch then content = nc; notice = table.concat(noti, "、") end
    local ok = os.execute("mkdir -p " .. util.shellquote(d))
    if not ok then json_out({ error = "创建目录失败" }); return end
    local f = io.open(d .. "/docker-compose.yml", "w")
    if not f then json_out({ error = "写入失败（权限？）" }); return end
    f:write(content); f:close()
    -- 中文备注：写入项目目录 .name（前端新建时输入的中文名）
    local note = http.formvalue("note")
    if note and note ~= "" then
        local nf = io.open(d .. "/.name", "w")
        if nf then nf:write(note); nf:close() end
    end
    local start = http.formvalue("start")
    if start == "1" then
        -- 已创建；启动交给前端走后台任务（避免同步阻塞），此处仅提示
        log_line("创建", name .. "（" .. d .. "）")
        json_out({ ok = true, name = name, dir = d, need_start = true, notice = notice })
        return
    end
    if http.formvalue("src") == "copy" then
        log_line("复制", "复制为新项目 " .. name .. "（" .. d .. "）")
    else
        log_line("创建", name .. "（" .. d .. "）")
    end
    json_out({ ok = true, name = name, dir = d, notice = notice })
end

-- 删除项目：默认保留容器运行（keep_container 缺省为 1，防止误删容器）；
-- keep_data 控制是否保留项目目录与数据（默认保留，只删 compose 配置文件）
function api_delete()
    local s = load_settings()
    local root = clean_dir(s.dir) or DEFAULT_DIR
    local p = clean_dir(http.formvalue("path"))
    local keep = http.formvalue("keep_data") ~= "0"
    local keep_container = http.formvalue("keep_container") ~= "0"
    if not p then json_out({ error = "参数不合法" }); return end
    if p:sub(1, #root + 1) ~= root .. "/" then json_out({ error = "只能删除项目目录" }); return end
    local rest = p:sub(#root + 2)
    if rest == "" or rest:find("/") or rest:find("^%.") then json_out({ error = "只能删除项目目录" }); return end
    if not find_compose(p) then json_out({ error = "不是 compose 项目" }); return end
    -- 仅当明确要求删除容器时才 down；默认保留容器运行
    if not keep_container then
        sh("cd " .. util.shellquote(p) .. " && docker compose down", 120)
    end
    if keep then
        local removed = false
        for _, name in ipairs({ "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" }) do
            local f = p .. "/" .. name
            if fs.access(f) then
                os.remove(f)
                removed = true
            end
        end
        if not removed then json_out({ error = "未找到 compose 配置文件" }); return end
        log_line("删除", "删除项目 " .. rest .. "（保留容器/保留目录）")
        json_out({ ok = true, kept = true })
    else
        local ok = os.execute("rm -rf " .. util.shellquote(p))
        if not ok then json_out({ error = "删除失败" }); return end
        log_line("删除", "删除项目 " .. rest .. "（含目录数据）")
        json_out({ ok = true })
    end
end

-- 修改项目备注（写入项目目录 .name，卡片显示中文名）
function api_note_save()
    local s = load_settings()
    local root = clean_dir(s.dir) or DEFAULT_DIR
    local p = clean_dir(http.formvalue("path"))
    local note = http.formvalue("note") or ""
    note = note:gsub("%s+$", ""):sub(1, 100)
    if not p then json_out({ error = "参数不合法" }); return end
    if p:sub(1, #root + 1) ~= root .. "/" then json_out({ error = "只能操作项目目录" }); return end
    local rest = p:sub(#root + 2)
    if rest == "" or rest:find("/") or rest:find("^%.") then json_out({ error = "只能操作项目目录" }); return end
    if not find_compose(p) then json_out({ error = "不是 compose 项目" }); return end
    if note == "" then
        if fs.access(p .. "/.name") then os.remove(p .. "/.name") end
    else
        local nf = io.open(p .. "/.name", "w")
        if not nf then json_out({ error = "写入失败" }); return end
        nf:write(note); nf:close()
    end
    json_out({ ok = true, note = note })
end

-- 通用 compose 操作（up/down/restart/logs）
function compose_op(act)
    local p = clean_dir(http.formvalue("path"))
    if not p then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "目录不存在" }); return end

    local svc = clean_name(http.formvalue("service")) or ""
    local tail = tonumber(http.formvalue("tail")) or 200
    if tail < 10 then tail = 10 end
    if tail > 5000 then tail = 5000 end

    local cd = "cd " .. util.shellquote(p) .. " && "
    local cmd, t
    if act == "up" then
        cmd = cd .. "docker compose up -d"; t = 300
    elseif act == "down" then
        cmd = cd .. "docker compose down"; t = 180
    elseif act == "restart" then
        cmd = cd .. "docker compose restart" .. (svc ~= "" and (" " .. util.shellquote(svc)) or ""); t = 120
    elseif act == "logs" then
        cmd = cd .. "docker compose logs --tail=" .. tail .. (svc ~= "" and (" " .. util.shellquote(svc)) or ""); t = 60
    else
        json_out({ error = "未知操作" }); return
    end

    local ok, out = sh(cmd, t)
    if act == "logs" then
        json_out({ ok = true, log = out })
        return
    end
    if not ok then
        json_out({ error = (out ~= "" and out or "执行失败（可能超时）"):sub(1, 600) })
    else
        json_out({ ok = true, msg = out:sub(1, 300) })
    end
end

function api_up() compose_op("up") end
function api_down() compose_op("down") end
function api_restart() compose_op("restart") end
function api_logs() compose_op("logs") end

-- 读取 compose 文件
function api_yml_get()
    local p = clean_dir(http.formvalue("path"))
    if not p then json_out({ error = "参数不合法" }); return end
    local yml = find_compose(p)
    if not yml then json_out({ error = "未找到 compose 文件" }); return end
    local f = io.open(p .. "/" .. yml, "r")
    if not f then json_out({ error = "读取失败" }); return end
    local content = f:read("*a"); f:close()
    json_out({ ok = true, name = yml, content = content })
end

-- 保存 compose 文件
function api_yml_save()
    local p = clean_dir(http.formvalue("path"))
    local name = clean_name(http.formvalue("name"))
    local content = http.formvalue("content") or ""
    if not p or not name then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "目录不存在" }); return end

    local ok_name = false
    for _, fn in ipairs(COMPOSE_FILES) do
        if name == fn then ok_name = true end
    end
    if not ok_name then json_out({ error = "文件名不合法" }); return end

    local f = io.open(p .. "/" .. name, "w")
    if not f then json_out({ error = "写入失败（权限？）" }); return end
    f:write(content); f:close()
    local pname = p:match("([^/]+)$") or p
    if http.formvalue("down") == "1" then
        log_line("降级", "降级项目 " .. pname)
    elseif http.formvalue("src") == "up" then
        log_line("更新", "切换镜像版本 " .. pname)
    else
        log_line("编辑", "编辑项目 " .. pname .. "（" .. name .. "）")
    end
    json_out({ ok = true })
end

-- 设置读写
-- 应用自动更新计划：写更新脚本 + 更新 crontab（保留其他任务行）
function apply_autoup_cron(st)
    if not st or not st.dir then return end
    local scr = [[#!/bin/sh
# Docker Compose 自动更新（插件生成）
LOG=/etc/dockercompose_autoup.log
echo "[$(date '+%F %T')] ===== 自动更新开始 =====" >> "$LOG"
ROOT=__ROOT__
cd "$ROOT" || exit 0
# 读取系统镜像加速源（UCI dockerd，与插件检查同一来源；读不到用默认 3 个互相备份）
MIRS=$(grep -o 'https\?://[a-zA-Z0-9._-]*' /etc/config/dockerd 2>/dev/null | sed 's|https\?://||')
[ -z "$MIRS" ] && MIRS="docker.1ms.run docker.m.daocloud.io docker.1panel.live"
for d in "$ROOT"/*/; do
  [ -d "$d" ] || continue
  for fn in docker-compose.yml docker-compose.yaml compose.yaml compose.yml; do
    if [ -f "$d/$fn" ]; then
      RC=$(cd "$d" && docker compose ps -q 2>/dev/null)
      if [ -z "$RC" ]; then
        echo "[$(date '+%F %T')] 项目已停止，跳过自动更新（不拉取镜像）" >> "$LOG"
        break
      fi
      echo "[$(date '+%F %T')] 更新项目: $d" >> "$LOG"
      # 固定版本检测：yml 中 image 带固定 tag（非 latest）时，依次尝试系统镜像加速源查询远程最新稳定版并在日志提示
      IL=$(grep -m1 'image:' "$d/$fn" 2>/dev/null)
      IMG=$(echo "$IL" | sed 's/.*image:[ \t]*//' | tr -d "\"'" | awk '{print $1}')
      case "$IMG" in
        *:latest|*@sha256:*) ;;
        *:*)
          T=${IMG##*:}; R=${IMG%:*}
          case "$R" in *.*/*) R2=${R#*/};; *) R2=$R;; esac
          case "$R2" in docker.io/*) R2=${R2#docker.io/};; esac
          NEW=""
          for m in $MIRS; do
            NEW=$(curl -s -m 8 "https://$m/v2/$R2/tags/list" 2>/dev/null | grep -o '"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | tr -d '"' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
            [ -n "$NEW" ] && break
          done
          if [ -n "$NEW" ] && [ "$NEW" != "$T" ]; then
            echo "[$(date '+%F %T')] 发现新版本 $R:$T -> $R:$NEW（yml 固定版本未自动切换，如需跟随最新请把 image 改为 latest）" >> "$LOG"
          fi
          ;;
      esac
      (cd "$d" && docker compose pull -q 2>&1) >> "$LOG" 2>&1
      (cd "$d" && docker compose up -d 2>&1) >> "$LOG" 2>&1
      break
    fi
  done
done
sleep 3
docker image prune -a -f >> "$LOG" 2>&1 || true
echo "[$(date '+%F %T')] ===== 自动更新结束 =====" >> "$LOG"
]]
    scr = scr:gsub("__ROOT__", util.shellquote(st.dir))
    local f = io.open("/etc/dockercompose_autoup.sh", "w")
    if f then f:write(scr); f:close() end
    os.execute("chmod +x /etc/dockercompose_autoup.sh")
    local cr = io.open("/etc/crontabs/root", "r")
    local content = cr and cr:read("*a") or ""
    if cr then cr:close() end
    local lines = {}
    for line in content:gmatch("[^\n]+") do
        if not line:find("dockercompose_autoup") then lines[#lines + 1] = line end
    end
    if st.autoup_enabled and (st.autoup_time or st.autoup_mode == "interval") then
        if st.autoup_mode == "interval" then
            -- 间隔模式：任意"时:分"分钟数（0:0 = 不启用该模式）→ 每分钟 cron 检查 + 间隔文件（秒）
            local m = tonumber(st.autoup_interval) or 0
            if m > 1439 then m = 1439 end
            if m <= 0 then
                -- 0 分钟 = 不启用间隔升级：自动关闭自动升级，清掉间隔文件与 checker，不写 cron 行
                st.autoup_enabled = false
                os.execute("rm -f /etc/dockercompose_autoup_interval /etc/dockercompose_autoup_check.sh")
            else
                local ivf = io.open("/etc/dockercompose_autoup_interval", "w")
                if ivf then ivf:write(tostring(m * 60)); ivf:close() end
                local chk = "#!/bin/sh\nLASTF=/tmp/dc_autoup_last\nIV=$(cat /etc/dockercompose_autoup_interval 2>/dev/null || echo 3600)\nNOW=$(date +%s)\nLAST=$(cat $LASTF 2>/dev/null || echo 0)\nif [ $((NOW - LAST)) -ge $IV ]; then\n  echo $NOW > $LASTF\n  /etc/dockercompose_autoup.sh\nfi\n"
                local fc = io.open("/etc/dockercompose_autoup_check.sh", "w")
                if fc then fc:write(chk); fc:close() end
                os.execute("chmod +x /etc/dockercompose_autoup_check.sh")
                lines[#lines + 1] = "* * * * * /etc/dockercompose_autoup_check.sh >/dev/null 2>&1"
            end
        else
            -- 每天/每周定时模式：支持多时间点（逗号分隔），每个时间生成一条 cron；time 为空时兜底 02:30
            local t = st.autoup_time
            if t == "" or not t then t = "02:30" end
            local times = {}
            for part in t:gmatch("[^,]+") do
                local h, m = part:match("^(%d+):(%d+)")
                if h and m then times[#times + 1] = { h = h, m = m } end
            end
            if #times == 0 then
                local h, m = t:match("^(%d+):(%d+)")
                if h and m then times[#times + 1] = { h = h, m = m } end
            end
            if #times > 0 then
                local days = (st.autoup_days and st.autoup_days ~= "" and st.autoup_days ~= "*") and st.autoup_days or "*"
                for _, tm in ipairs(times) do
                    lines[#lines + 1] = string.format("%s %s * * %s /etc/dockercompose_autoup.sh >/dev/null 2>&1", tm.m, tm.h, days)
                end
            end
        end
    end
    local f2 = io.open("/etc/crontabs/root", "w")
    if f2 then f2:write(table.concat(lines, "\n") .. "\n"); f2:close() end
    os.execute("/etc/init.d/cron restart 2>/dev/null || true")
end

function api_settings_get()
    local st = load_settings()
    st.sys_mirrors = system_mirrors()
    json_out({ settings = st })
end

function api_settings_save()
    local dir = clean_dir(http.formvalue("dir"))
    local mapdir = clean(http.formvalue("default_map_dir"))
    if not dir then json_out({ error = "目录不合法" }); return end
    if not fs.access(dir) then
        local ok = os.execute("mkdir -p " .. util.shellquote(dir))
        if not ok then json_out({ error = "目录不存在且自动创建失败" }); return end
    end
    local st = load_settings()
    st.dir = dir
    st.default_map_dir = mapdir
    -- 镜像源模式：auto=自动同步系统镜像加速源（dockerd/daemon.json）；manual=手动填写
    local mm = http.formvalue("mirror_mode")
    if mm ~= nil then
        if mm == "auto" or mm == "manual" then st.mirror_mode = mm end
    end
    -- 镜像检查加速地址列表（逗号分隔，手动模式用；auto 模式作为系统源读取失败时的兜底）
    local cm = http.formvalue("check_mirrors")
    if cm == nil then cm = http.formvalue("check_mirror") end
    if cm ~= nil then
        local ms = norm_mirrors(cm)
        if #ms == 0 then ms = DEFAULT_MIRRORS end
        st.check_mirrors = ms
    end
    -- 日志自动清理天数（0=不清理）
    local lkd = http.formvalue("log_keep_days")
    if lkd ~= nil then
        local n = tonumber(clean(lkd)) or 0
        if n < 0 then n = 0 end
        if n > 365 then n = 365 end
        st.log_keep_days = n
    end
    -- 自动升级计划（前端设置时提交）
    local au = http.formvalue("autoup_enabled")
    if au ~= nil then
        st.autoup_enabled = (au == "1" or au == "true")
        st.autoup_mode = clean(http.formvalue("autoup_mode")) or "daily"
        st.autoup_time = clean_time(http.formvalue("autoup_time"))
        st.autoup_days = clean(http.formvalue("autoup_days")) or "*"
        st.autoup_interval = clean(http.formvalue("autoup_interval")) or "6"
        apply_autoup_cron(st)
    end
    if not save_settings(st) then json_out({ error = "保存失败" }); return end
    json_out({ ok = true, settings = { dir = dir, default_map_dir = mapdir, log_keep_days = st.log_keep_days, autoup_enabled = st.autoup_enabled, autoup_mode = st.autoup_mode, autoup_time = st.autoup_time, autoup_days = st.autoup_days, autoup_interval = st.autoup_interval, check_mirrors = st.check_mirrors or DEFAULT_MIRRORS } })
end

function api_autoup_log()
    local f = io.open("/etc/dockercompose_autoup.log", "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    if content == "" then content = "（暂无自动升级日志）" end
    json_out({ ok = true, log = content })
end

-- 查询镜像可用版本（registry tags API + 加速代理 + 本地镜像兜底），供降级弹窗下拉选择
function api_image_tags()
    local img = clean(http.formvalue("image"))
    if not img or img == "" then json_out({ error = "缺少镜像名" }); return end
    local base = img
    while base:match(":[^:/]+$") do base = base:gsub(":[^:/]+$", "") end
    local registry, path = "registry-1.docker.io", base
    local slash = base:find("/")
    if slash then
        local first = base:sub(1, slash - 1)
        if first:find("%.") or first == "localhost" or first:find(":") then
            registry = first
            path = base:sub(slash + 1)
        else
            path = base
        end
    end
    -- 清理加速前缀（m.daocloud.io/docker.io/hanxi/xiaomusic → hanxi/xiaomusic）
    local proxypath = path
    proxypath = proxypath:gsub("^docker%.io/library/", "")
    proxypath = proxypath:gsub("^docker%.io/", "")
    -- 候选查询 URL：优先配置的镜像加速地址（docker.io 直连在部分网络不可达）
    local function try_url(url)
        local ok, out = sh("curl -s -m 12 '" .. url .. "'", 25)
        if ok and out and out ~= "" then
            local okj, j = pcall(jsonc.parse, out)
            if okj and type(j) == "table" and j.tags and type(j.tags) == "table" then
                return j.tags
            end
        end
        return nil
    end
    local tags
    local core_path = strip_dockerio(path)  -- 剥离代理前缀里的 docker.io/（如 m.daocloud.io/docker.io/xxx）
    if registry == "registry-1.docker.io" then
        -- docker.io 依次尝试配置的镜像加速地址（互相备份）
        for _, mir in ipairs(check_mirror_hosts()) do
            tags = try_url("https://" .. mir .. "/v2/" .. core_path .. "/tags/list")
            if tags then break end
        end
        if not tags then tags = try_url("https://m.daocloud.io/docker.io/" .. core_path .. "/tags/list") end
    else
        tags = try_url("https://" .. registry .. "/v2/" .. path .. "/tags/list")
        if not tags then
            for _, mir in ipairs(check_mirror_hosts()) do
                tags = try_url("https://" .. mir .. "/v2/" .. core_path .. "/tags/list")
                if tags then break end
            end
        end
    end
    -- 本地镜像版本兜底（已下载的可直接降级）
    local local_tags = {}
    local ok5, out5 = sh("docker images --format '{{.Repository}}|{{.Tag}}' 2>/dev/null", 15)
    if ok5 and out5 then
        for line in out5:gmatch("[^\r\n]+") do
            local r, t = line:match("^(.-)|(.+)$")
            if r and t and (r == base or r:find(proxypath, 1, true) or proxypath:find(r, 1, true)) then
                local_tags[#local_tags + 1] = t
            end
        end
    end
    local seen, merged = {}, {}
    local function add(t)
        if t and t ~= "" and not seen[t] then seen[t] = true; merged[#merged + 1] = t end
    end
    if tags then for _, t in ipairs(tags) do add(t) end end
    for _, t in ipairs(local_tags) do add(t) end
    if #merged == 0 then json_out({ error = "查询失败（无法连接镜像仓库）" }); return end
    table.sort(merged, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na > nb end
        return a > b
    end)
    json_out({ ok = true, repo = base, tags = merged })
end

-- 当前设备架构（uname 映射 docker 平台名）
function api_arch()
    local arch = (io.popen("uname -m 2>/dev/null"):read("*a") or ""):gsub("%s", "")
    if arch == "aarch64" then arch = "arm64" elseif arch == "x86_64" then arch = "amd64" end
    json_out({ ok = true, arch = arch })
end

-- 更新前校验：目标版本是否支持当前设备架构（防止匹配到其他系统/架构的版本导致启动失败）
-- 直接超时执行命令（timeout 直接杀命令进程本身；不走 sh -c 包装，避免子进程残留占用管道导致 read 卡死）
local function rund(t, cmd)
    local f = io.popen("timeout " .. t .. " " .. cmd .. " 2>&1", "r")
    if not f then return "" end
    local o = f:read("*a"); f:close()
    return o or ""
end
-- 通过 registry API 两步认证取 manifest：返回 { digest = Docker-Content-Digest 头, body = manifest 内容 }
-- 该 digest 与 docker 本地保存的 RepoDigest 同源（多架构拉取时本地就是 index digest），对比才准确；
-- 而 docker manifest inspect 输出的是子平台 digest（amd64/arm64 各自），永远匹配不上 index digest（此前误报根因）。
-- 源不可达 / 认证失败返回 nil
local function reg_fetch(host, repo, tag)
    local base = "https://" .. host .. "/v2/" .. repo .. "/manifests/" .. tag
    local acc = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
    local hdr = rund(20, "curl -sI -m 8 '" .. base .. "' -H 'Accept: " .. acc .. "'")
    if hdr == "" then return nil end
    local d = hdr:match("Docker%-Content%-Digest:%s*([^%s\r\n]+)")
    local tok = ""
    if not d then
        -- 401：按 WWW-Authenticate 里的 realm/service/scope 拿 token 再请求
        local realm = hdr:match('realm="([^"]+)"')
        local service = hdr:match('service="([^"]+)"')
        local scope = hdr:match('scope="([^"]+)"')
        if not realm then return nil end
        local tokurl = realm .. "?service=" .. (service or "") .. "&scope=" .. (scope or ("repository:" .. repo .. ":pull"))
        tok = rund(20, "curl -s -m 8 '" .. tokurl .. "' | grep -o '\"token\":\"[^\"]*\"' | cut -d'\"' -f4")
        if tok == "" then return nil end
        local hdr2 = rund(20, "curl -sI -m 8 '" .. base .. "' -H 'Authorization: Bearer " .. tok .. "' -H 'Accept: " .. acc .. "'")
        d = hdr2:match("Docker%-Content%-Digest:%s*([^%s\r\n]+)")
    end
    if not d then return nil end
    local auth = ""
    if tok ~= "" then auth = "-H 'Authorization: Bearer " .. tok .. "' " end
    local body = rund(20, "curl -s -m 8 " .. auth .. "-H 'Accept: " .. acc .. "' '" .. base .. "'")
    return { digest = d, body = body }
end
-- 解析镜像名为 host / repo / tag（docker.io 官方仓库不带域名）
local function parse_img(img)
    local host, repo
    local fs = img:find("/")
    if fs then
        local pre = img:sub(1, fs - 1)
        if pre:find("%.") or pre:find(":") then host = pre; repo = img:sub(fs + 1)
        else host = "docker.io"; repo = img end
    else
        host = "docker.io"; repo = "library/" .. img
    end
    local tag = repo:match(":([^:]+)$") or "latest"
    repo = repo:match("^(.-):[^:]*$") or repo
    return host, repo, tag
end
-- 当前生效的镜像检查加速地址列表：auto 模式优先系统镜像加速源（dockerd/daemon.json，系统变更自动跟随），
-- 系统源为空时退回手动/默认；manual 模式用设置里手动填写的地址
-- 注意：定义为全局函数，供 api_image_tags / remote_digest 等多处调用（避免 local 定义顺序问题）
function check_mirror_hosts()
    local s = load_settings()
    if (s.mirror_mode or "auto") == "auto" then
        local sys = system_mirrors()
        if #sys > 0 then return sys end
    end
    local ms = norm_mirrors(s.check_mirrors)
    if #ms == 0 then return DEFAULT_MIRRORS end
    return ms
end
-- 依次尝试各加速地址查询 docker.io 镜像，返回第一个成功的 {digest, body} 或 nil
local function reg_fetch_dockerio(repo, tag)
    for _, mir in ipairs(check_mirror_hosts()) do
        local rf = reg_fetch(mir, repo, tag)
        if rf then return rf end
    end
    return nil
end
-- 剥离代理前缀里的 docker.io/（如 m.daocloud.io/docker.io/hanxi/xiaomusic → hanxi/xiaomusic），供加速通道重试
-- 注意：定义为全局函数，供 api_image_tags（定义于其后）调用
function strip_dockerio(repo)
    if type(repo) == "string" and repo:find("^docker%.io/") then
        return repo:sub(10)
    end
    return repo
end
local function remote_digest(img)
    local host, repo, tag = parse_img(img)
    if host == "docker.io" then
        -- docker.io 官方仓库直连不通：依次尝试配置的镜像加速地址（代理转发官方 manifest，digest 与本地 RepoDigest 同源可比）
        local rf = reg_fetch_dockerio(repo, tag)
        return rf and rf.digest or nil
    end
    local rf = reg_fetch(host, repo, tag)
    if not rf and repo:find("^docker%.io/") then
        -- 镜像源本身是 docker.io 的加速代理（如 m.daocloud.io/docker.io/xxx），直连该源不通时剥离前缀走加速列表
        rf = reg_fetch_dockerio(strip_dockerio(repo), tag)
    end
    return rf and rf.digest or nil
end
function api_up_check()
    local path = clean_dir(http.formvalue("path"))
    local tag = clean(http.formvalue("tag"))
    if not path or not find_compose(path) then json_out({ error = "不是 compose 项目" }); return end
    if tag == "" then tag = "latest" end
    local fn = find_compose(path)
    local yf = path .. "/" .. fn
    local f = io.open(yf, "r")
    if not f then json_out({ error = "读取 yml 失败" }); return end
    local yml = f:read("*a"); f:close()
    local img = yml:match("image:%s*([^%s#]+)") or ""
    img = img:gsub('^"', ''):gsub('"$', ''):gsub("^'", ""):gsub("'$", "")
    local base = img:match("^(.-):[^:]*$") or img
    local arch = (io.popen("uname -m 2>/dev/null"):read("*a") or ""):gsub("%s", "")
    if arch == "aarch64" then arch = "arm64" elseif arch == "x86_64" then arch = "amd64" end
    -- 当前 yml 里的 tag：latest 是动态标签，官方更新后 yml 不变，必须对比镜像内容 digest 才能知道是否真有新版
    local cur_tag = img:match(":([^:]+)$")
    if not cur_tag then cur_tag = "latest" end
    local steps = {}
    local function st(s) steps[#steps + 1] = s end
    if img == "" then json_out({ ok = true, arch = arch, error = "yml 中未配置 image，无法更新", steps = steps }); return end
    st("读取配置：image=" .. img)
    -- 目标 tag 与当前 tag 相同（典型 latest 场景）：比较本地镜像与远端 manifest 的 digest
    if cur_tag == tag then
        st("当前版本 " .. cur_tag .. " 与目标 " .. tag .. " 相同，对比镜像内容 digest 判断是否真有新版")
        local ldig = rund(15, "docker image inspect --format '{{index .RepoDigests 0}}' " .. util.shellquote(img))
        local lsha = ldig and ldig:match("@sha256:([0-9a-f]+)") or ""
        if lsha ~= "" then st("本地 digest：sha256:" .. lsha) end
        local rdig = remote_digest(img)
        if rdig then st("远端 digest：" .. rdig) end
        if lsha ~= "" and rdig then
            if rdig:find("sha256:" .. lsha) then
                st("digest 一致 → 已是最新版，无需更新")
                json_out({ ok = true, arch = arch, up_to_date = true, steps = steps })
            else
                st("digest 不一致 → 官方已发布新版，可更新")
                json_out({ ok = true, arch = arch, changed = true, steps = steps })
            end
            return
        end
        -- 本地无 RepoDigest 或查不到远端 digest：确认源可达性，不可达直接阻止（避免拉取阶段无限卡）
        local host, repo, tt = parse_img(img)
        if host == "docker.io" then
            if rdig then
                -- 加速地址查到了远端 digest 但本地无对应镜像：放行拉取
                st("远端 digest（经镜像加速通道）：" .. rdig .. "，本地无对应镜像，可执行更新")
                json_out({ ok = true, arch = arch, changed = true, steps = steps })
                return
            end
            st("镜像源与加速通道均不可达，无法确认是否有新版")
            json_out({ ok = true, arch = arch, unknown = true, steps = steps })
            return
        end
        st("未能完整确认 digest，探测镜像源（" .. (host or "?") .. "）可达性…")
        local rf = reg_fetch(host, repo, tt)
        if not rf and repo:find("^docker%.io/") then
            -- 镜像源本身是 docker.io 的加速代理（如 m.daocloud.io/docker.io/xxx）：剥离前缀走加速列表重试
            rf = reg_fetch_dockerio(strip_dockerio(repo), tt)
        end
        if not rf then
            st("镜像源网络不可达，已取消更新")
            json_out({ ok = true, arch = arch, error = "无法连接镜像源（" .. (host or "?") .. "）确认是否有新版，已取消更新。请检查网络或稍后再试", steps = steps })
            return
        end
        st("镜像源可达，放行重新拉取")
        json_out({ ok = true, arch = arch, changed = true, steps = steps })
        return
    end
    -- 不同版本：优先用 registry API 校验版本与架构（快），失败退回 docker manifest inspect
    st("目标版本 " .. tag .. " 与当前 " .. cur_tag .. " 不同，校验版本存在性及架构（" .. arch .. "）")
    local host, repo, tt = parse_img(base .. ":" .. tag)
    local rf = nil
    if host == "docker.io" then
        -- docker.io 依次尝试配置的镜像加速地址校验（代理转发官方 manifest）
        rf = reg_fetch_dockerio(repo, tt)
    else
        rf = reg_fetch(host, repo, tt)
        if not rf and repo:find("^docker%.io/") then
            rf = reg_fetch_dockerio(strip_dockerio(repo), tt)
        end
    end
    if rf then
        st("镜像源可达，远端 digest：" .. rf.digest)
        if not rf.body:find('"architecture"%s*:%s*"' .. arch .. '"') then
            local alt = (arch == "arm64" and "aarch64") or (arch == "amd64" and "x86_64") or ""
            if alt == "" or not rf.body:find('"architecture"%s*:%s*"' .. alt .. '"') then
                st("该版本不支持 " .. arch .. " 架构，已拦截")
                json_out({ error = "版本 " .. tag .. " 不支持当前设备架构（" .. arch .. "），已拦截。请选择其他版本或 latest", arch = arch, steps = steps })
                return
            end
        end
        st("架构校验通过")
        json_out({ ok = true, arch = arch, steps = steps })
        return
    end
    -- registry API 不可达（含 docker.io）：退回 docker manifest inspect（走 docker daemon，可能配了镜像加速）
    local mf = rund(12, "docker manifest inspect " .. util.shellquote(base .. ":" .. tag))
    if mf == "" or mf:find("no such manifest") or mf:find("UNAUTHORIZED") then
        if host == "docker.io" then
            -- docker.io 无法预校验版本与架构，放行拉取（走加速通道，失败会在拉取阶段明确报错）
            st("镜像源 docker.io 无法预校验版本与架构，将通过镜像加速通道直接拉取（失败会显示原因）")
            json_out({ ok = true, arch = arch, unknown = true, steps = steps })
            return
        end
        st("镜像源（" .. (host or "?") .. "）网络不可达，已取消更新")
        json_out({ ok = true, arch = arch, error = "镜像源（" .. (host or "?") .. "）当前网络不可达，无法校验版本，已取消更新", steps = steps })
        return
    end
    -- 单架构 manifest 顶层与多架构列表都含 "architecture":"<arch>"（兼容 curl 无空格 / docker CLI 带空格）
    if not mf:find('"architecture"%s*:%s*"' .. arch .. '"') then
        local alt = (arch == "arm64" and "aarch64") or (arch == "amd64" and "x86_64") or ""
        if alt == "" or not mf:find('"architecture"%s*:%s*"' .. alt .. '"') then
            st("该版本不支持 " .. arch .. " 架构，已拦截")
            json_out({ error = "版本 " .. tag .. " 不支持当前设备架构（" .. arch .. "），已拦截。请选择其他版本或 latest", arch = arch, steps = steps })
            return
        end
    end
    st("架构校验通过")
    json_out({ ok = true, arch = arch, steps = steps })
end

-- 检查项目当前镜像是否有远端新版本（供项目卡片更新状态提示）
-- 对比本地 RepoDigest 与远端 manifest digest：不同 → has_update=true；查不到远端 → checked=false（前端显示"检查失败"，不误报"最新"）
function api_up_status()
    local path = clean_dir(http.formvalue("path"))
    if not path or not find_compose(path) then json_out({ error = "不是 compose 项目" }); return end
    local fn = find_compose(path)
    local yf = path .. "/" .. fn
    local f = io.open(yf, "r")
    if not f then json_out({ error = "读取 yml 失败" }); return end
    local yml = f:read("*a"); f:close()
    local img = yml:match("image:%s*([^%s#]+)") or ""
    img = img:gsub('^"', ''):gsub('"$', ''):gsub("^'", ""):gsub("'$", "")
    if img == "" then json_out({ ok = true, checked = false, msg = "未找到镜像行" }); return end
    local base = img:match("^(.-):[^:]*$") or img
    local cur_tag = img:match(":([^:]+)$") or "latest"
    local ldig = rund(15, "docker image inspect --format '{{index .RepoDigests 0}}' " .. util.shellquote(img))
    local lsha = ldig and ldig:match("@sha256:([0-9a-f]+)") or ""
    if lsha == "" then
        -- 回退：yml 的 tag 可能被自动更新清理摘除（容器仍运行），改用容器实际镜像 ID 查 RepoDigests
        local okc, cid = sh("cd " .. util.shellquote(path) .. " && docker compose ps -q 2>/dev/null | head -1", 15)
        cid = (cid or ""):gsub("%s+", "")
        if okc and cid ~= "" then
            local iid = rund(10, "docker inspect --format '{{.Image}}' " .. util.shellquote(cid))
            if iid and iid ~= "" then
                -- docker 会把 sha256: 前缀当 digest 查找（page not found），去掉前缀用纯 ID 查 RepoDigests
                local iid2 = iid:gsub("^sha256:%s*", ""):gsub("%s+", "")
                local ldig2 = rund(10, "docker image inspect --format '{{index .RepoDigests 0}}' " .. util.shellquote(iid2))
                lsha = ldig2 and ldig2:match("@sha256:([0-9a-f]+)") or ""
            end
        end
        if lsha == "" then json_out({ ok = true, checked = false, msg = "本地镜像无 digest" }); return end
    end
    local rdig = remote_digest(img)
    if not rdig then json_out({ ok = true, checked = false, msg = "镜像源查询失败（加速地址不可达）" }); return end
    json_out({ ok = true, checked = true, has_update = not rdig:find("sha256:" .. lsha) })
end

-- 移动项目目录（更改路径）：先停容器 → mv 目录 → 返回新路径（前端在新路径启动）
function api_move()
    local s = load_settings()
    local root = clean_dir(s.dir) or DEFAULT_DIR
    local p = clean_dir(http.formvalue("path"))
    local np = clean_dir(http.formvalue("newpath"))
    if not p or not np then json_out({ error = "参数不合法" }); return end
    if p == np then json_out({ error = "新路径不能与原路径相同" }); return end
    if not fs.access(p) then json_out({ error = "原路径不存在" }); return end
    if fs.access(np) then json_out({ error = "目标路径已存在" }); return end
    if p:sub(1, #root + 1) ~= root .. "/" then json_out({ error = "只能移动项目目录" }); return end
    local rest = p:sub(#root + 2)
    if rest == "" or rest:find("/") or rest:find("^%.") then json_out({ error = "只能移动项目目录" }); return end
    if not find_compose(p) then json_out({ error = "不是 compose 项目" }); return end
    local parent = np:match("^(.*)/[^/]+$")
    if not parent or not fs.access(parent) then json_out({ error = "目标父目录不存在" }); return end
    if np:sub(1, #p) == p and (#np == #p or np:sub(#p + 1, #p + 1) == "/") then json_out({ error = "不能移动到自身内部" }); return end
    -- 先停容器（失败不阻塞移动）
    sh("cd " .. util.shellquote(p) .. " && docker compose down", 180)
    local ok = os.execute("mv " .. util.shellquote(p) .. " " .. util.shellquote(np))
    if not ok then json_out({ error = "移动失败（跨盘或权限问题？）" }); return end
    log_line("移动", "移动项目 " .. rest .. " → " .. np)
    json_out({ ok = true, dir = np, name = string.match(np, "([^/]+)$") or "" })
end

-- ============ 同步：把未托管容器整理进 Docker Compose ============

-- yaml 双引号字符串转义（路径含空格 / 环境变量含特殊字符时安全）
local function yq(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

-- 由 docker inspect 单容器 JSON 生成 docker-compose.yml（保留原镜像/端口/挂载/env/重启策略）
local function build_compose_yaml(j)
    local img = j.Config and j.Config.Image or ""
    if img == "" then return nil end
    local name = (j.Name or ""):gsub("^/", "")
    if name == "" or name:find("%s") then return nil end
    local L = {
        "services:",
        "  app:",
        "    image: " .. img,
        "    container_name: " .. name,
    }
    -- restart 策略
    local rp = j.HostConfig and j.HostConfig.RestartPolicy and j.HostConfig.RestartPolicy.Name
    if rp and rp ~= "" and rp ~= "no" then
        L[#L + 1] = "    restart: " .. rp
    end
    -- host 网络
    local netm = j.HostConfig and j.HostConfig.NetworkMode
    if netm == "host" then L[#L + 1] = "    network_mode: host" end
    -- 端口映射（保留 HostIp / HostPort，原样还原）
    local pb = j.HostConfig and j.HostConfig.PortBindings
    if pb and next(pb) then
        L[#L + 1] = "    ports:"
        for cp, binds in pairs(pb) do
            if type(binds) == "table" then
                for _, b in ipairs(binds) do
                    local hp = b.HostPort or ""
                    local hostip = b.HostIp or ""
                    local cpnum = cp:gsub("/.*$", "")
                    if hp ~= "" and cpnum ~= "" then
                        local spec
                        if hostip ~= "" and hostip ~= "0.0.0.0" and hostip ~= "::" then
                            spec = hostip .. ":" .. hp .. ":" .. cpnum
                        else
                            spec = hp .. ":" .. cpnum
                        end
                        L[#L + 1] = "      - " .. yq(spec)
                    end
                end
            end
        end
    end
    -- bind 挂载（原样保留主机路径，映射路径不变）
    local vols = {}
    if type(j.Mounts) == "table" then
        for _, m in ipairs(j.Mounts) do
            if m and m.Type == "bind" and m.Source and m.Destination then
                local spec = m.Source .. ":" .. m.Destination
                if m.RW == false then spec = spec .. ":ro" end
                vols[#vols + 1] = spec
            end
        end
    end
    if #vols > 0 then
        L[#L + 1] = "    volumes:"
        for _, v in ipairs(vols) do L[#L + 1] = "      - " .. yq(v) end
    end
    -- 环境变量（跳过 docker 自动注入项；显式 env 全部保留）
    local envs = {}
    local skip = { PATH = 1, HOSTNAME = 1, HOME = 1, PWD = 1, LANG = 1, LC_ALL = 1,
                   TERM = 1, SHLVL = 1, OLDPWD = 1 }
    if j.Config and type(j.Config.Env) == "table" then
        for _, e in ipairs(j.Config.Env) do
            local k = e:match("^([^=]+)=")
            if k and not skip[k] then envs[#envs + 1] = e end
        end
    end
    if #envs > 0 then
        L[#L + 1] = "    environment:"
        for _, e in ipairs(envs) do L[#L + 1] = "      - " .. yq(e) end
    end
    return table.concat(L, "\n") .. "\n"
end

-- 同步接口：不传 confirm 只扫描返回待同步容器；confirm=1 执行接管
function api_sync()
    local s = load_settings()
    local root = clean_dir(s.dir) or DEFAULT_DIR
    local confirm = http.formvalue("confirm") == "1"

    -- 1. 现有 compose 项目目录名集合（根目录子目录含 compose 文件 + 根目录自身）
    local projects = {}
    if fs.access(root) then
        local ok, iter, obj = pcall(fs.dir, root)
        if ok then
            for name in iter, obj do
                if name ~= "." and name ~= ".." and not name:find("^%.") then
                    local sub = root .. "/" .. name
                    local st = fs.stat(sub)
                    if st and is_dir(st) and find_compose(sub) then projects[name] = true end
                end
            end
        end
        if find_compose(root) then
            projects[string.match(root, "([^/]+)$") or root] = true
        end
    end

    -- 2. 全部容器 vs 已被 compose 接管的容器
    --    判定"已托管"必须同时满足：容器带 compose label 且根目录存在同名项目
    --    （删除项目后容器仍带 label，但根目录无项目 → 不算已托管，可重新同步收编）
    local all, managed = {}, {}
    local ok1, o1 = sh("docker ps -a --format '{{.Names}}' 2>/dev/null", 30)
    if ok1 and o1 then for l in o1:gmatch("[^\r\n]+") do all[l] = true end end
    local ok2, o2 = sh("docker ps -a --format '{{.Names}}|{{.Label \"com.docker.compose.project\"}}' --filter 'label=com.docker.compose.project' 2>/dev/null", 30)
    if ok2 and o2 then
        for line in o2:gmatch("[^\r\n]+") do
            local cn, pj = line:match("^(.-)|(.+)$")
            if cn and pj and projects[pj] then managed[cn] = true end
        end
    end

    -- 3. 待同步 = 全部容器 − 已托管 − 已存在同名项目
    local pending = {}
    for name in pairs(all) do
        if not managed[name] and not projects[name] then
            local cn = clean_name(name)
            if cn then pending[#pending + 1] = cn end
        end
    end
    table.sort(pending)

    if not confirm then
        -- 仅扫描：把待同步容器交给前端弹窗确认
        json_out({ ok = true, pending = pending, count = #pending })
        return
    end

    -- only 参数：只处理指定容器名（前端逐个同步显示进度时使用），默认处理全部 pending
    local only_s = http.formvalue("only") or ""
    if only_s ~= "" then
        local only = {}
        for w in only_s:gmatch("[^,]+") do
            local cn = clean_name(w)
            if cn then only[cn] = true end
        end
        local ft = {}
        for _, n in ipairs(pending) do
            if only[n] then ft[#ft + 1] = n end
        end
        pending = ft
    end

    -- 4. 执行：逐个容器 inspect → 生成 compose → 停原容器 → 以 Compose 方式接管启动
    --    前端可传 items=[{name:项目名, note:备注}]（顺序对应 pending，缺省项目名=容器名）
    local items = {}
    local items_json = http.formvalue("items")
    if items_json and items_json ~= "" then
        local okj, j = pcall(jsonc.parse, items_json)
        if okj and type(j) == "table" then
            for i, it in ipairs(j) do
                if type(it) == "table" then
                    items[i] = {
                        name = clean_name(tostring(it.name or "")),
                        note = tostring(it.note or ""):sub(1, 100),
                    }
                end
            end
        end
    end
    local added = {}
    for i, name in ipairs(pending) do
        local item = { name = name }
        local pname = (items[i] and items[i].name ~= "") and items[i].name or name
        local note = items[i] and items[i].note or ""
        local ok3, ins = sh("docker inspect " .. util.shellquote(name) .. " 2>/dev/null", 30)
        if not ok3 or ins == "" or not jsonc_ok then
            item.ok = false; item.msg = "inspect 失败"
        else
            local okj, j = pcall(jsonc.parse, ins)
            if not okj or type(j) ~= "table" or type(j[1]) ~= "table" then
                item.ok = false; item.msg = "解析失败"
            else
                local yml = build_compose_yaml(j[1])
                if not yml then
                    item.ok = false; item.msg = "生成配置失败"
                else
                    local d = root .. "/" .. pname
                    if fs.access(d) and find_compose(d) then
                        item.ok = false; item.msg = "项目名「" .. pname .. "」已存在"
                    else
                        os.execute("mkdir -p " .. util.shellquote(d))
                        local f = io.open(d .. "/docker-compose.yml", "w")
                        if not f then
                            item.ok = false; item.msg = "写入失败"
                        else
                            f:write(yml); f:close()
                            if note ~= "" then
                                local nf = io.open(d .. "/.name", "w")
                                if nf then nf:write(note); nf:close() end
                            end
                            local ok4, o4 = sh("docker stop " .. util.shellquote(name)
                                .. " && docker rm " .. util.shellquote(name)
                                .. " && cd " .. util.shellquote(d) .. " && docker compose up -d", 300)
                            if not ok4 then
                                item.ok = false; item.msg = (o4 or ""):gsub("%s+$", ""):sub(1, 200)
                            else
                                item.ok = true; item.msg = (o4 or ""):gsub("%s+$", ""):sub(1, 120)
                                log_line("同步", "同步容器 " .. name .. " 为项目 " .. pname)
                            end
                        end
                    end
                end
            end
        end
        added[#added + 1] = item
    end
    json_out({ ok = true, added = added })
end

-- ============ 后台操作任务（启动/停止/重启 + 实时日志） ============

local TASKDIR = "/tmp/dc_tasks"

function task_file(id, suffix)
    return TASKDIR .. "/" .. id .. suffix
end

-- 启动后台操作：op_start?action=up&path=xxx[&service=yyy]
function op_start()
    local action = clean_name(http.formvalue("action"))
    local p = clean_dir(http.formvalue("path"))
    if not action or not p then json_out({ error = "参数不合法" }); return end
    if not fs.access(p) then json_out({ error = "目录不存在" }); return end
    local svc = clean_name(http.formvalue("service")) or ""
    local pull = http.formvalue("pull")

    os.execute("mkdir -p " .. TASKDIR)
    local id = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    local logf = task_file(id, ".log")
    local pidf = task_file(id, ".pid")
    local donef = task_file(id, ".done")

    local cd = "cd " .. util.shellquote(p) .. " && "
    local cmd
    if action == "up" then
        cmd = cd .. "docker compose up -d"
        if pull == "1" then
            cmd = cmd .. " --pull always; sleep 3; docker image prune -a -f >/dev/null 2>&1 || true"
            log_line("升级", "升级项目 " .. (p:match("([^/]+)$") or p))
        else
            log_line("启动", "启动项目 " .. (p:match("([^/]+)$") or p))
        end
    elseif action == "down" then
        cmd = cd .. "docker compose down"
        log_line("停止", "停止项目 " .. (p:match("([^/]+)$") or p))
    elseif action == "restart" then
        cmd = cd .. "docker compose restart" .. (svc ~= "" and (" " .. util.shellquote(svc)) or "")
        log_line("重启", "重启项目 " .. (p:match("([^/]+)$") or p) .. (svc ~= "" and (" 服务 " .. svc) or ""))
    else json_out({ error = "未知操作" }); return end

    -- 后台执行：nohup sh -c 'cmd; echo $? > done' > log 2>&1 & echo $! > pid
    os.execute("nohup sh -c " .. util.shellquote(cmd .. "; echo $? > " .. donef) .. " > " .. logf .. " 2>&1 & echo $! > " .. pidf)
    json_out({ ok = true, id = id, action = action })
end

-- 轮询状态：op_status?id=xxx
function op_status()
    local id = clean_name(http.formvalue("id"))
    if not id then json_out({ error = "参数不合法" }); return end
    local logf = task_file(id, ".log")
    local donef = task_file(id, ".done")

    local full = ""
    if fs.access(logf) then
        local f = io.open(logf, "r")
        if f then full = f:read("*a"); f:close() end
    end
    local done = fs.access(donef)
    local code = nil
    if done then
        local f = io.open(donef, "r")
        if f then code = f:read("*a"):gsub("%s+", ""); f:close() end
    end

    -- 返回尾部日志（最多 ~6KB，前端按需全量轮询增量）
    local tail = 6000
    local log = ""
    if #full > tail then log = full:sub(#full - tail) else log = full end
    json_out({ ok = true, done = done, code = code, log = log, len = #full })
end

-- 取消任务：op_cancel?id=xxx
function op_cancel()
    local id = clean_name(http.formvalue("id"))
    if not id then json_out({ error = "参数不合法" }); return end
    local pidf = task_file(id, ".pid")
    if fs.access(pidf) then
        local f = io.open(pidf, "r")
        if f then
            local pid = f:read("*a"):gsub("%s+", "")
            f:close()
            if pid ~= "" then
                os.execute("kill " .. util.shellquote(pid) .. " 2>/dev/null; kill -9 " .. util.shellquote(pid) .. " 2>/dev/null")
            end
        end
    end
    json_out({ ok = true })
end
