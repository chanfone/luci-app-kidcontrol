module("luci.controller.kidcontrol", package.seeall)

local uci = require("luci.model.uci").cursor()
local util = require("luci.util")
local jsonc = require("luci.jsonc")

function index()
	local page = entry({"admin", "services", "kidcontrol"}, call("action_index"), _("儿童上网管控"), 91)
	page.dependent = false
	page.acl_depends = { "luci-app-kidcontrol" }
end

local function trim(s)
	return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function esc(s)
	return util.pcdata(tostring(s or ""))
end

local function cmd(command)
	local f = io.popen(command .. " 2>&1")
	local out = f:read("*a")
	f:close()
	return out or ""
end

local function norm_mac(mac)
	if type(mac) == "table" then
		for _, value in pairs(mac) do
			local found = norm_mac(value)
			if found then return found end
		end
		return nil
	end
	mac = trim(mac):lower():gsub("-", ":")
	if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		return mac
	end
	return nil
end

local function valid_ip(ip)
	ip = trim(ip)
	return ip:match("^%d+%.%d+%.%d+%.%d+$") and ip or nil
end

local function norm_domain(domain)
	domain = trim(domain):lower()
	domain = domain:gsub("^https?://", ""):gsub("^//", "")
	domain = domain:gsub("/.*$", ""):gsub(":%d+$", "")
	domain = domain:gsub("^www%.", "")
	if domain:match("^[a-z0-9][a-z0-9%.%-]*%.[a-z][a-z0-9%-]*$") then
		return domain
	end
	return nil
end

local CATEGORY_DEFS = {
	{
		id = "short_video",
		name = "抖音/字节系短视频",
		desc = "抖音、西瓜视频、今日头条、TikTok 及常见字节系娱乐入口。",
		services = { "tiktok" },
		domains = {
			"douyin.com", "douyincdn.com", "douyinpic.com", "douyinstatic.com",
			"douyinliving.com", "iesdouyin.com", "ixigua.com", "toutiao.com",
			"snssdk.com", "pstatp.com", "byteimg.com", "bytedance.com"
		}
	},
	{
		id = "kuaishou",
		name = "快手",
		desc = "快手、快影及常见快手 CDN 域名。",
		services = {},
		domains = { "kuaishou.com", "gifshow.com", "ksapisrv.com", "kspkg.com", "yximgs.com", "kwaizt.com" }
	},
	{
		id = "bilibili",
		name = "Bilibili",
		desc = "B 站网页、App 与视频 CDN。",
		services = { "bilibili" },
		domains = { "bilibili.com", "bilibili.tv", "bilivideo.com", "acgvideo.com", "hdslb.com" }
	},
	{
		id = "xiaohongshu",
		name = "小红书",
		desc = "小红书网页、App 与图片/视频 CDN。",
		services = {},
		domains = { "xiaohongshu.com", "xiaohongshu.net", "xhscdn.com", "xhslink.com" }
	},
	{
		id = "game_platforms",
		name = "游戏平台通用",
		desc = "Steam、Epic、暴雪、拳头、主机游戏平台、Discord、Twitch 等。",
		services = {
			"steam", "epic_games", "origin", "battle_net", "riot_games",
			"activision_blizzard", "nintendo", "playstation", "xboxlive",
			"discord", "twitch"
		},
		domains = {
			"steamstatic.com", "steamcontent.com", "steampowered.com", "steamcommunity.com",
			"epicgames.com", "unrealengine.com", "battle.net", "blizzard.com",
			"riotgames.com", "riotcdn.net", "playvalorant.com", "leagueoflegends.com",
			"discord.com", "discord.gg", "discordapp.com", "twitch.tv"
		}
	},
	{
		id = "roblox_minecraft",
		name = "Roblox/Minecraft",
		desc = "Roblox 与 Minecraft 相关域名。",
		services = { "roblox", "minecraft" },
		domains = { "roblox.com", "rbxcdn.com", "minecraft.net", "minecraftservices.com", "mojang.com" }
	},
	{
		id = "proxy_dns",
		name = "代理/VPN/私人 DNS",
		desc = "常见 DoH、私人 DNS、代理入口；同时保留 HaGeZi 绕过过滤订阅。",
		services = { "telegram" },
		domains = {
			"dns.google", "cloudflare-dns.com", "one.one.one.one", "doh.pub",
			"dns.alidns.com", "dns.quad9.net", "quad9.net", "nextdns.io",
			"adguard-dns.io", "opendns.com", "telegram.org", "t.me"
		}
	}
}

local function category_by_id(id)
	for _, c in ipairs(CATEGORY_DEFS) do
		if c.id == id then return c end
	end
	return nil
end

local function lookup_ip(ip)
	ip = valid_ip(ip)
	if not ip then return nil, nil end
	local f = io.open("/tmp/dhcp.leases", "r")
	if f then
		for line in f:lines() do
			local _, mac, lease_ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			if lease_ip == ip then
				f:close()
				return norm_mac(mac), (name and name ~= "*" and name or "")
			end
		end
		f:close()
	end
	local neigh = cmd("ip neigh show " .. ip)
	local mac = neigh:match("lladdr%s+([%x:]+)")
	return norm_mac(mac), ""
end

local function add_match(matches, name, ip, mac, source)
	ip = valid_ip(ip or "") or ""
	mac = norm_mac(mac or "")
	name = trim(name or "")
	if not mac and ip == "" and name == "" then return end
	matches[#matches + 1] = {
		name = name,
		ip = ip,
		mac = mac or "",
		source = source or ""
	}
end

local function device_matches()
	local matches = {}
	uci:foreach("kidcontrol", "device", function(s)
		add_match(matches, s.name, s.ip, s.mac, "儿童管控")
	end)
	uci:foreach("dhcp", "host", function(s)
		add_match(matches, s.name, s.ip, s.mac, "DHCP 静态地址")
	end)
	local f = io.open("/tmp/dhcp.leases", "r")
	if f then
		for line in f:lines() do
			local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			add_match(matches, name ~= "*" and name or "", ip, mac, "DHCP 当前租约")
		end
		f:close()
	end
	local neigh = cmd("ip neigh show")
	for line in neigh:gmatch("[^\n]+") do
		local ip = line:match("^(%d+%.%d+%.%d+%.%d+)%s")
		local mac = line:match("lladdr%s+([%x:]+)")
		add_match(matches, "", ip, mac, "邻居表")
	end
	return matches
end

local function find_device(name, ip, mac)
	name = trim(name or "")
	ip = valid_ip(ip or "") or ""
	mac = norm_mac(mac or "")
	local lname = name:lower()
	local best, best_score = nil, -1
	for _, item in ipairs(device_matches()) do
		local score = 0
		if mac and norm_mac(item.mac) == mac then score = score + 100 end
		if ip ~= "" and item.ip == ip then score = score + 80 end
		if lname ~= "" and item.name:lower() == lname then score = score + 60 end
		if lname ~= "" and item.name:lower():find(lname, 1, true) then score = score + 25 end
		if score > best_score then
			best, best_score = item, score
		end
	end
	if best and best_score > 0 then return best end
	if ip ~= "" then
		local found_mac, found_name = lookup_ip(ip)
		if found_mac then return { name = found_name or "", ip = ip, mac = found_mac, source = "在线查询" } end
	end
	return nil
end

local function sections(stype)
	local t = {}
	uci:foreach("kidcontrol", stype, function(s)
		t[#t + 1] = s
	end)
	return t
end

local function find_existing_domain(domain)
	domain = norm_domain(domain or "")
	if not domain then return nil end
	local found = nil
	uci:foreach("kidcontrol", "domain", function(s)
		if not found and norm_domain(s.domain or "") == domain then
			found = s
		end
	end)
	return found
end

local function find_existing_device(name, ip, mac)
	name = trim(name or "")
	ip = valid_ip(ip or "") or ""
	mac = norm_mac(mac or "")
	local lname = name:lower()
	local found = nil
	uci:foreach("kidcontrol", "device", function(s)
		if found then return end
		local smac = norm_mac(s.mac or "")
		local sip = valid_ip(s.ip or "") or ""
		local sname = trim(s.name or "")
		if mac and smac == mac then
			found = s
		elseif ip ~= "" and sip == ip then
			found = s
		elseif lname ~= "" and sname:lower() == lname then
			found = s
		end
	end)
	return found
end

local function dedupe_config()
	local changed, removed = false, 0
	local domain_seen, domain_remove = {}, {}
	uci:foreach("kidcontrol", "domain", function(s)
		local domain = norm_domain(s.domain or "")
		if domain then
			if domain_seen[domain] then
				domain_remove[#domain_remove + 1] = s[".name"]
			else
				domain_seen[domain] = s[".name"]
				if s.domain ~= domain then
					uci:set("kidcontrol", s[".name"], "domain", domain)
					changed = true
				end
			end
		end
	end)
	for _, section in ipairs(domain_remove) do
		uci:delete("kidcontrol", section)
		removed = removed + 1
		changed = true
	end

	local device_seen, device_remove = {}, {}
	uci:foreach("kidcontrol", "device", function(s)
		local mac = norm_mac(s.mac or "")
		local ip = valid_ip(s.ip or "") or ""
		local key = nil
		if mac then key = "mac:" .. mac
		elseif ip ~= "" then key = "ip:" .. ip
		else key = "name:" .. trim(s.name or ""):lower()
		end
		if key and device_seen[key] then
			local keep = device_seen[key]
			if trim(uci:get("kidcontrol", keep, "name") or "") == "" and trim(s.name or "") ~= "" then
				uci:set("kidcontrol", keep, "name", trim(s.name))
			end
			if (uci:get("kidcontrol", keep, "ip") or "") == "" and ip ~= "" then
				uci:set("kidcontrol", keep, "ip", ip)
			end
			if not norm_mac(uci:get("kidcontrol", keep, "mac") or "") and mac then
				uci:set("kidcontrol", keep, "mac", mac)
			end
			if (s.enabled or "1") == "1" then uci:set("kidcontrol", keep, "enabled", "1") end
			if (s.block_dot or "1") == "1" then uci:set("kidcontrol", keep, "block_dot", "1") end
			device_remove[#device_remove + 1] = s[".name"]
		elseif key then
			device_seen[key] = s[".name"]
		end
	end)
	for _, section in ipairs(device_remove) do
		uci:delete("kidcontrol", section)
		removed = removed + 1
		changed = true
	end

	if changed then uci:commit("kidcontrol") end
	return removed
end

local function delete_sections(stype)
	local names = {}
	uci:foreach("kidcontrol", stype, function(s) names[#names + 1] = s[".name"] end)
	for _, name in ipairs(names) do uci:delete("kidcontrol", name) end
end

local function section_exists(stype, section)
	local exists = false
	section = trim(section or "")
	if section == "" then return false end
	uci:foreach("kidcontrol", stype, function(s)
		if s[".name"] == section then exists = true end
	end)
	return exists
end

local function device_mac_set()
	local set = {}
	uci:foreach("kidcontrol", "device", function(s)
		local mac = norm_mac(s.mac)
		if mac then set[mac] = s end
	end)
	return set
end

local function sync_dhcp()
	local devices = device_mac_set()
	local seen = {}
	local remove = {}

	uci:foreach("dhcp", "host", function(h)
		local mac = norm_mac(h.mac)
		if h.kidcontrol == "1" and (not mac or not devices[mac]) then
			remove[#remove + 1] = h[".name"]
		elseif mac and devices[mac] then
			local d = devices[mac]
			uci:set("dhcp", h[".name"], "name", d.name or "Kid-Device")
			uci:set("dhcp", h[".name"], "mac", mac)
			if valid_ip(d.ip) then uci:set("dhcp", h[".name"], "ip", d.ip) end
			uci:set("dhcp", h[".name"], "kidcontrol", "1")
			seen[mac] = true
		end
	end)

	for _, name in ipairs(remove) do uci:delete("dhcp", name) end
	for mac, d in pairs(devices) do
		if not seen[mac] and valid_ip(d.ip) then
			local s = uci:add("dhcp", "host")
			uci:set("dhcp", s, "name", d.name or "Kid-Device")
			uci:set("dhcp", s, "mac", mac)
			uci:set("dhcp", s, "ip", d.ip)
			uci:set("dhcp", s, "kidcontrol", "1")
		end
	end
	uci:commit("dhcp")
	cmd("/etc/init.d/dnsmasq restart")
end

local function enabled_domain_rules()
	local rules = {}
	uci:foreach("kidcontrol", "domain", function(s)
		local d = norm_domain(s.domain)
		if d and (s.enabled or "1") == "1" then
			rules[#rules + 1] = "||" .. d .. "^"
		end
	end)
	uci:foreach("kidcontrol", "category", function(s)
		if (s.enabled or "0") == "1" then
			local def = category_by_id(s.id)
			if def then
				for _, d in ipairs(def.domains or {}) do
					rules[#rules + 1] = "||" .. d .. "^"
				end
			end
		end
	end)
	table.sort(rules)
	return rules
end

local function enabled_service_ids()
	local seen, ids = {}, {}
	uci:foreach("kidcontrol", "category", function(s)
		if (s.enabled or "0") == "1" then
			local def = category_by_id(s.id)
			if def then
				for _, id in ipairs(def.services or {}) do
					if not seen[id] then
						seen[id] = true
						ids[#ids + 1] = id
					end
				end
			end
		end
	end)
	table.sort(ids)
	return ids
end

local function agh_settings()
	local agh_url = trim(uci:get("kidcontrol", "main", "agh_url") or "http://192.168.1.1:3000")
	local agh_user = trim(uci:get("kidcontrol", "main", "agh_user") or "admin")
	local agh_password = uci:get("kidcontrol", "main", "agh_password") or ""
	return agh_url, agh_user, agh_password
end

local function agh_login()
	local agh_url, agh_user, agh_password = agh_settings()
	if agh_password == "" then
		return false, "请先在 /etc/config/kidcontrol 设置 main.agh_password，才能同步 AdGuard Home。", agh_url
	end
	local f = io.open("/tmp/kidcontrol-agh-login.json", "w")
	if not f then return false, "无法写入临时登录配置。", agh_url end
	f:write(jsonc.stringify({ name = agh_user, password = agh_password }))
	f:close()
	local login = ""
	for _ = 1, 20 do
		login = cmd("curl -s -c /tmp/agh-kidcontrol.cookie -H 'Content-Type: application/json' -d @/tmp/kidcontrol-agh-login.json " .. agh_url .. "/control/login")
		if login:match("OK") then return true, "AdGuard Home 登录成功。", agh_url end
		os.execute("sleep 1")
	end
	return false, "AdGuard Home 登录失败，无法同步。", agh_url
end

local function agh_client_tags(name)
	local lname = trim(name or ""):lower()
	if lname:find("phone", 1, true) or lname:find("iphone", 1, true) or lname:find("android", 1, true) then
		return { "device_phone", "user_child" }
	end
	if lname:find("pad", 1, true) or lname:find("tablet", 1, true) then
		return { "device_tablet", "user_child" }
	end
	if lname:find("mac", 1, true) then
		return { "device_laptop", "os_macos", "user_child" }
	end
	if lname:find("windows", 1, true) or lname:find("pc", 1, true) then
		return { "device_pc", "os_windows", "user_child" }
	end
	return { "device_pc", "user_child" }
end

local function agh_client_payload(device)
	local ids = {}
	local ip = valid_ip(device.ip or "")
	local mac = norm_mac(device.mac or "")
	if ip then ids[#ids + 1] = ip end
	if mac then ids[#ids + 1] = mac end
	if #ids == 0 then return nil end
	local name = trim(device.name or "")
	if name == "" then name = mac and ("Kid-" .. mac:gsub(":", "")) or ("Kid-" .. ip:gsub("%.", "-")) end
	return {
		name = name,
		ids = ids,
		tags = agh_client_tags(name),
		upstreams = {},
		use_global_settings = true,
		filtering_enabled = false,
		parental_enabled = false,
		safebrowsing_enabled = false,
		safesearch_enabled = false,
		use_global_blocked_services = true,
		blocked_services = {},
		ignore_querylog = false,
		ignore_statistics = false
	}
end

local function agh_find_client(clients, desired)
	if type(clients) ~= "table" or type(desired) ~= "table" then return nil end
	for _, c in ipairs(clients) do
		if c.name == desired.name then return c end
		if type(c.ids) == "table" and type(desired.ids) == "table" then
			for _, existing_id in ipairs(c.ids) do
				for _, desired_id in ipairs(desired.ids) do
					if existing_id == desired_id then return c end
				end
			end
		end
	end
	return nil
end

local function sync_adguard_clients()
	local ok, msg, agh_url = agh_login()
	if not ok then return false, msg end
	local body = cmd("curl -s -b /tmp/agh-kidcontrol.cookie " .. agh_url .. "/control/clients")
	local data = jsonc.parse(body or "")
	if type(data) ~= "table" or type(data.clients) ~= "table" then
		return false, "读取 AdGuard Home 客户端列表失败。"
	end
	local changed = 0
	for _, d in ipairs(sections("device")) do
		local desired = agh_client_payload(d)
		if desired then
			local existing = agh_find_client(data.clients, desired)
			local payload_path = "/tmp/kidcontrol-agh-client.json"
			local endpoint = "/control/clients/add"
			local payload = desired
			if existing then
				endpoint = "/control/clients/update"
				payload = { name = existing.name, data = desired }
			end
			local f = io.open(payload_path, "w")
			if not f then return false, "无法写入临时客户端配置。" end
			f:write(jsonc.stringify(payload))
			f:close()
			local out = cmd("curl -s -b /tmp/agh-kidcontrol.cookie -H 'Content-Type: application/json' -d @" .. payload_path .. " " .. agh_url .. endpoint)
			if out and #trim(out) > 0 then
				return false, "同步 AdGuard Home 客户端失败：" .. out
			end
			changed = changed + 1
			body = cmd("curl -s -b /tmp/agh-kidcontrol.cookie " .. agh_url .. "/control/clients")
			data = jsonc.parse(body or "") or data
		end
	end
	return true, "AdGuard Home 客户端已同步 " .. changed .. " 台。"
end

local function sync_adguard_services()
	local ids = enabled_service_ids()
	local payload = jsonc.stringify(ids)
	local f = io.open("/tmp/kidcontrol-services.json", "w")
	if not f then return false, "无法写入临时服务分类配置。" end
	f:write(payload)
	f:close()
	local ok, msg, agh_url = agh_login()
	if not ok then return false, msg end
	local out = ""
	for _ = 1, 20 do
		out = cmd("curl -s -b /tmp/agh-kidcontrol.cookie -H 'Content-Type: application/json' -d @/tmp/kidcontrol-services.json " .. agh_url .. "/control/blocked_services/set")
		if #trim(out) == 0 or out:match("OK") then break end
		os.execute("sleep 1")
	end
	if out and #trim(out) > 0 and not out:match("OK") then
		return false, "同步 AdGuard Home 服务分类失败：" .. out
	end
	return true, "AdGuard Home 服务分类已同步。"
end

local function sync_adguard_rules()
	local path = "/etc/adguardhome.yaml"
	local f = io.open(path, "r")
	if not f then return false, "无法读取 /etc/adguardhome.yaml" end
	local lines = {}
	for line in f:lines() do lines[#lines + 1] = line end
	f:close()

	local rules = enabled_domain_rules()
	local out, skipping, replaced = {}, false, false
	for _, line in ipairs(lines) do
		if line:match("^user_rules:") then
			out[#out + 1] = "user_rules:"
			for _, rule in ipairs(rules) do out[#out + 1] = "  - '" .. rule .. "'" end
			skipping = true
			replaced = true
		elseif skipping then
			if line:match("^%S") then
				skipping = false
				out[#out + 1] = line
			end
		else
			out[#out + 1] = line
		end
	end
	if not replaced then
		out[#out + 1] = "user_rules:"
		for _, rule in ipairs(rules) do out[#out + 1] = "  - '" .. rule .. "'" end
	end

	cmd("cp /etc/adguardhome.yaml /etc/adguardhome.yaml.bak-kidcontrol-$(date +%Y%m%d-%H%M%S)")
	f = io.open(path, "w")
	if not f then return false, "无法写入 /etc/adguardhome.yaml" end
	f:write(table.concat(out, "\n") .. "\n")
	f:close()
	local check = cmd("/usr/bin/AdGuardHome -c /etc/adguardhome.yaml -w /etc/adguardhome/work --check-config")
	if not check:match("configuration file is ok") then return false, check end
	cmd("/etc/init.d/adguardhome restart")
	return true, "AdGuard Home 自定义域名规则已同步。"
end

local function apply_all()
	dedupe_config()
	sync_dhcp()
	local ok, msg = sync_adguard_rules()
	local ok_clients, msg_clients = sync_adguard_clients()
	local ok_services, msg_services = sync_adguard_services()
	local out = cmd("/etc/init.d/kidcontrol reload")
	if not ok then return false, msg end
	if not ok_clients then return false, msg_clients end
	if not ok_services then return false, msg_services end
	if out and #out > 0 then return true, msg .. "\n" .. out end
	return true, msg .. "\n" .. msg_clients .. "\n" .. msg_services .. "\n儿童管控规则已应用。"
end

local function export_data()
	local data = { version = 1, devices = {}, domains = {}, categories = {} }
	for _, d in ipairs(sections("device")) do
		data.devices[#data.devices + 1] = {
			name = d.name or "",
			ip = d.ip or "",
			mac = d.mac or "",
			enabled = (d.enabled or "1") == "1",
			block_dot = (d.block_dot or "1") == "1"
		}
	end
	for _, d in ipairs(sections("domain")) do
		data.domains[#data.domains + 1] = {
			domain = d.domain or "",
			enabled = (d.enabled or "1") == "1"
		}
	end
	uci:foreach("kidcontrol", "category", function(c)
		data.categories[#data.categories + 1] = {
			id = c.id or "",
			enabled = (c.enabled or "0") == "1"
		}
	end)
	return data
end

local function import_data(text)
	local data = jsonc.parse(text or "")
	if type(data) ~= "table" then return false, "导入内容不是有效 JSON。" end
	if type(data.devices) ~= "table" then data.devices = {} end
	if type(data.domains) ~= "table" then data.domains = {} end
	if type(data.categories) ~= "table" then data.categories = {} end

	delete_sections("device")
	delete_sections("domain")
	delete_sections("category")

	for _, d in ipairs(data.devices) do
		local mac = norm_mac(d.mac or "")
		local ip = valid_ip(d.ip or "") or ""
		if mac or ip ~= "" then
			local s = uci:add("kidcontrol", "device")
			uci:set("kidcontrol", s, "name", trim(d.name or "Kid-Device"))
			uci:set("kidcontrol", s, "ip", ip)
			if mac then uci:set("kidcontrol", s, "mac", mac) end
			uci:set("kidcontrol", s, "enabled", d.enabled == false and "0" or "1")
			uci:set("kidcontrol", s, "block_dot", d.block_dot == false and "0" or "1")
		end
	end
	for _, d in ipairs(data.domains) do
		local domain = norm_domain(d.domain or "")
		if domain then
			local s = uci:add("kidcontrol", "domain")
			uci:set("kidcontrol", s, "domain", domain)
			uci:set("kidcontrol", s, "enabled", d.enabled == false and "0" or "1")
		end
	end
	for _, c in ipairs(data.categories) do
		if category_by_id(c.id or "") then
			local s = uci:add("kidcontrol", "category")
			uci:set("kidcontrol", s, "id", c.id)
			uci:set("kidcontrol", s, "enabled", c.enabled == true and "1" or "0")
		end
	end
	uci:commit("kidcontrol")
	return apply_all()
end

local function add_device(http)
	local ip = valid_ip(http.formvalue("ip") or "") or ""
	local mac = norm_mac(http.formvalue("mac") or "")
	local name = trim(http.formvalue("name") or "")
	local found = find_device(name, ip, mac)
	if found then
		if ip == "" then ip = found.ip or "" end
		if not mac then mac = norm_mac(found.mac or "") end
		if name == "" then name = found.name or "" end
	end
	if not mac and ip == "" then return false, "没有找到 MAC，也没有可用固定 IP。请至少填写 IP 地址，或在 DHCP 静态地址中绑定后再添加。" end
	if name == "" then name = mac and ("Kid-" .. mac:gsub(":", "")) or ("Kid-" .. ip:gsub("%.", "-")) end
	local existing = find_existing_device(name, ip, mac)
	if existing then
		local changed = false
		local section = existing[".name"]
		if trim(existing.name or "") == "" and name ~= "" then uci:set("kidcontrol", section, "name", name); changed = true end
		if (existing.ip or "") == "" and ip ~= "" then uci:set("kidcontrol", section, "ip", ip); changed = true end
		if not norm_mac(existing.mac or "") and mac then uci:set("kidcontrol", section, "mac", mac); changed = true end
		if changed then
			uci:commit("kidcontrol")
			local ok, msg = apply_all()
			if not ok then return false, msg end
			return true, "设备已存在，未重复添加；已补全缺失信息并重新应用规则。"
		end
		return false, "设备已存在，未重复添加。"
	end
	local s = uci:add("kidcontrol", "device")
	uci:set("kidcontrol", s, "name", name)
	uci:set("kidcontrol", s, "ip", ip)
	if mac then uci:set("kidcontrol", s, "mac", mac) end
	uci:set("kidcontrol", s, "enabled", http.formvalue("enabled") and "1" or "0")
	uci:set("kidcontrol", s, "block_dot", http.formvalue("block_dot") and "1" or "0")
	uci:commit("kidcontrol")
	return apply_all()
end

local function lookup_device_form(http)
	local name = trim(http.formvalue("name") or "")
	local ip = valid_ip(http.formvalue("ip") or "") or ""
	local mac = norm_mac(http.formvalue("mac") or "")
	local found = find_device(name, ip, mac)
	if not found then
		if ip ~= "" then
			return true, "未找到 MAC，但可以先按固定 IP 添加。设备上线或 DHCP 静态地址补齐 MAC 后，可再查找补全。", {
				name = name,
				ip = ip,
				mac = mac or ""
			}
		end
		return false, "没有找到匹配设备。请确认设备在线，或先在 网络 -> DHCP/DNS -> 静态地址 中绑定。", {
			name = name,
			ip = ip,
			mac = mac or ""
		}
	end
	local message = "已从 " .. found.source .. " 找到设备信息，请确认后点击添加设备。"
	if (found.mac or "") == "" and (found.ip or ip) ~= "" then
		message = "已从 " .. found.source .. " 找到名称/IP，但没有 MAC；可先按固定 IP 添加。"
	end
	return true, message, {
		name = found.name ~= "" and found.name or name,
		ip = found.ip ~= "" and found.ip or ip,
		mac = found.mac ~= "" and found.mac or (mac or "")
	}
end

local function add_domain(http)
	local domain = norm_domain(http.formvalue("domain") or "")
	if not domain then return false, "域名格式不正确。" end
	if find_existing_domain(domain) then
		return false, "域名已存在，未重复添加。"
	end
	local s = uci:add("kidcontrol", "domain")
	uci:set("kidcontrol", s, "domain", domain)
	uci:set("kidcontrol", s, "enabled", "1")
	uci:commit("kidcontrol")
	return apply_all()
end

local function delete_section(stype, section)
	section = trim(section or "")
	if not section_exists(stype, section) then
		return false, "要删除的记录不存在，页面可能已经刷新过。"
	end
	uci:delete("kidcontrol", section)
	uci:commit("kidcontrol")
	local removed = dedupe_config()
	local ok, msg = apply_all()
	if not ok then return false, msg end
	if removed > 0 then
		return true, "已删除，并顺手清理了 " .. removed .. " 条重复记录。"
	end
	return true, "已删除并应用。"
end

local function set_section_option(section, option, value)
	if section and option then
		uci:set("kidcontrol", section, option, value)
		uci:commit("kidcontrol")
		return apply_all()
	end
	return false, "参数缺失。"
end

local function set_global_enabled(value)
	uci:set("kidcontrol", "main", "enabled", value == "1" and "1" or "0")
	uci:commit("kidcontrol")
	return apply_all()
end

local function set_category_enabled(id, value)
	local def = category_by_id(id or "")
	if not def then return false, "未知分类。" end
	local found = nil
	uci:foreach("kidcontrol", "category", function(s)
		if s.id == id then found = s[".name"] end
	end)
	if not found then
		found = uci:add("kidcontrol", "category")
		uci:set("kidcontrol", found, "id", id)
	end
	uci:set("kidcontrol", found, "enabled", value == "1" and "1" or "0")
	uci:commit("kidcontrol")
	return apply_all()
end

local function category_states()
	local enabled = {}
	uci:foreach("kidcontrol", "category", function(s)
		if s.id then enabled[s.id] = (s.enabled or "0") == "1" end
	end)
	local out = {}
	for _, def in ipairs(CATEGORY_DEFS) do
		out[#out + 1] = {
			id = def.id,
			name = def.name,
			desc = def.desc,
			services = def.services or {},
			domains = def.domains or {},
			enabled = enabled[def.id] == true
		}
	end
	return out
end

local function csv_cell(value)
	value = tostring(value or "")
	if value:match('[,"\n]') then
		value = '"' .. value:gsub('"', '""') .. '"'
	end
	return value
end

local function export_csv(devices, domains, categories)
	local lines = { "类型,名称,IP,MAC,域名,启用,阻断DoT,AdGuard规则" }
	for _, d in ipairs(devices) do
		lines[#lines + 1] = table.concat({
			csv_cell("设备"),
			csv_cell(d.name),
			csv_cell(d.ip),
			csv_cell(d.mac),
			csv_cell(""),
			csv_cell((d.enabled or "1") == "1" and "是" or "否"),
			csv_cell((d.block_dot or "1") == "1" and "是" or "否"),
			csv_cell("")
		}, ",")
	end
	for _, d in ipairs(domains) do
		lines[#lines + 1] = table.concat({
			csv_cell("域名"),
			csv_cell(""),
			csv_cell(""),
			csv_cell(""),
			csv_cell(d.domain),
			csv_cell((d.enabled or "1") == "1" and "是" or "否"),
			csv_cell(""),
			csv_cell("||" .. tostring(d.domain or "") .. "^")
		}, ",")
	end
	for _, c in ipairs(categories or {}) do
		lines[#lines + 1] = table.concat({
			csv_cell("分类"),
			csv_cell(c.name),
			csv_cell(""),
			csv_cell(""),
			csv_cell(table.concat(c.domains or {}, " ")),
			csv_cell(c.enabled and "是" or "否"),
			csv_cell(""),
			csv_cell(table.concat(c.services or {}, " "))
		}, ",")
	end
	return table.concat(lines, "\n")
end

local function counter_for(nft, mac, proto, port)
	mac = norm_mac(mac or "")
	if not mac then return 0, 0 end
	local pattern = "ether saddr " .. mac .. ".-" .. proto .. " dport " .. port .. ".-counter packets (%d+) bytes (%d+)"
	local packets, bytes = (nft or ""):match(pattern)
	return tonumber(packets or 0), tonumber(bytes or 0)
end

local function counter_for_ip(nft, ip, proto, port)
	ip = valid_ip(ip or "")
	if not ip then return 0, 0 end
	local pattern = "ip saddr " .. ip:gsub("%.", "%%.") .. ".-" .. proto .. " dport " .. port .. ".-counter packets (%d+) bytes (%d+)"
	local packets, bytes = (nft or ""):match(pattern)
	return tonumber(packets or 0), tonumber(bytes or 0)
end

local function rule_statuses(devices, nft)
	local statuses = {}
	for _, d in ipairs(devices) do
		local mac = norm_mac(d.mac or "")
		local match_type = mac and "MAC" or (valid_ip(d.ip or "") and "IP" or "未生效")
		local match_value = mac or valid_ip(d.ip or "") or ""
		local udp_packets, tcp_packets, dot_tcp, dot_udp
		if mac then
			udp_packets = counter_for(nft, mac, "udp", "53")
			tcp_packets = counter_for(nft, mac, "tcp", "53")
			dot_tcp = counter_for(nft, mac, "tcp", "853")
			dot_udp = counter_for(nft, mac, "udp", "853")
		else
			udp_packets = counter_for_ip(nft, d.ip, "udp", "53")
			tcp_packets = counter_for_ip(nft, d.ip, "tcp", "53")
			dot_tcp = counter_for_ip(nft, d.ip, "tcp", "853")
			dot_udp = counter_for_ip(nft, d.ip, "udp", "853")
		end
		statuses[#statuses + 1] = {
			name = d.name or "",
			ip = d.ip or "",
			mac = mac or "",
			match_type = match_type,
			match_value = match_value,
			enabled = (d.enabled or "1") == "1",
			block_dot = (d.block_dot or "1") == "1",
			dns_packets = udp_packets + tcp_packets,
			dot_packets = dot_tcp + dot_udp
		}
	end
	return statuses
end

function action_index()
	local http = require("luci.http")
	local dsp = require("luci.dispatcher")
	local tpl = require("luci.template")
	local action = http.formvalue("do")
	local ok, notice = true, nil
	local lookup_values = {
		name = "",
		ip = "",
		mac = ""
	}

	if action == "export" then
		http.header("Content-Disposition", "attachment; filename=kidcontrol-backup.json")
		http.prepare_content("application/json")
		http.write(jsonc.stringify(export_data(), true))
		return
	end

	if http.getenv("REQUEST_METHOD") == "POST" then
		lookup_values = {
			name = trim(http.formvalue("name") or ""),
			ip = valid_ip(http.formvalue("ip") or "") or trim(http.formvalue("ip") or ""),
			mac = norm_mac(http.formvalue("mac") or "") or trim(http.formvalue("mac") or "")
		}
		if action == "add_device" then ok, notice = add_device(http)
		elseif action == "lookup_device" then ok, notice, lookup_values = lookup_device_form(http)
		elseif action == "add_domain" then ok, notice = add_domain(http)
		elseif action == "delete_device" then ok, notice = delete_section("device", http.formvalue("section"))
		elseif action == "delete_domain" then ok, notice = delete_section("domain", http.formvalue("section"))
		elseif action == "toggle_device" then ok, notice = set_section_option(http.formvalue("section"), "enabled", http.formvalue("value") == "1" and "1" or "0")
		elseif action == "toggle_domain" then ok, notice = set_section_option(http.formvalue("section"), "enabled", http.formvalue("value") == "1" and "1" or "0")
		elseif action == "toggle_global" then ok, notice = set_global_enabled(http.formvalue("value"))
		elseif action == "toggle_category" then ok, notice = set_category_enabled(http.formvalue("id"), http.formvalue("value"))
		elseif action == "apply" then ok, notice = apply_all()
		elseif action == "import" then ok, notice = import_data(http.formvalue("import_json"))
		end
		if action == "add_device" and ok then
			lookup_values = { name = "", ip = "", mac = "" }
		end
	end

	local cleaned = dedupe_config()
	if cleaned > 0 and not notice then
		notice = "已自动清理 " .. cleaned .. " 条重复记录。"
		ok = true
	end

	local devices = sections("device")
	local domains = sections("domain")
	local nft = cmd("nft list chain inet fw4 kidcontrol_prerouting; nft list chain inet fw4 kidcontrol_forward")
	local agh = cmd("pidof AdGuardHome >/dev/null && echo running || echo stopped")
	local kc = cmd("/etc/init.d/kidcontrol enabled >/dev/null 2>&1 && echo enabled || echo disabled")
	local export = export_data()
	local rules = rule_statuses(devices, nft)
	local global_enabled = uci:get("kidcontrol", "main", "enabled") ~= "0"
	local categories = category_states()

	tpl.render("kidcontrol/index", {
		esc = esc,
		page_url = dsp.build_url("admin", "services", "kidcontrol"),
		export_url = dsp.build_url("admin", "services", "kidcontrol") .. "?do=export",
		lookup_values = lookup_values,
		devices = devices,
		domains = domains,
		rules = rules,
		categories = categories,
		notice = notice,
		ok = ok,
		nft = nft,
		agh = trim(agh),
		kidcontrol = trim(kc),
		global_enabled = global_enabled,
		export_json = jsonc.stringify(export, true),
		export_csv = export_csv(devices, domains, categories)
	})
end
