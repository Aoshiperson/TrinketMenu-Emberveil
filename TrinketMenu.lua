--[[ TrinketMenu (Emberveil 精简版) —— 配置全在 CFG，直接改 ]]--

local CFG = {
	X = 370, Y = 150,           -- 主窗口左上角位置（相对屏幕左下角，已含缩放前的单位）
	SCALE = 1,
	MAIN_ORIENT = "VERTICAL",   -- 已装备的两个饰品："VERTICAL" 或 "HORIZONTAL"
	MENU_SIDE = "RIGHT",        -- 背包饰品菜单在主窗口哪一侧："RIGHT" "LEFT" "TOP" "BOTTOM"
	COLUMNS = false,            -- 填数字固定列数；false 则按饰品数量自动
	KEEP_OPEN = false,          -- 菜单常开
	MENU_ON_SHIFT = false,      -- 按住 Shift 才显示菜单
	TOOLTIPS = true,
	COOLDOWN_TEXT = true,       -- 图标上显示冷却秒数
	NOTIFY = false,             -- 饰品冷却好了提示
	NOTIFY_CHAT = false,        -- 提示同时发到聊天框
}

local G = getfenv(0)
local MAX, SIZE = 30, 40
local SIDE = {
	RIGHT  = { point = "BOTTOMLEFT",  rel = "BOTTOMRIGHT", xd =  1, yd =  1 },
	LEFT   = { point = "BOTTOMRIGHT", rel = "BOTTOMLEFT",  xd = -1, yd =  1 },
	TOP    = { point = "BOTTOMLEFT",  rel = "TOPLEFT",     xd =  1, yd =  1 },
	BOTTOM = { point = "TOPLEFT",     rel = "BOTTOMLEFT",  xd =  1, yd = -1 },
}

TrinketMenu = {}

local bagged, nbagged = {}, 0   -- 背包里的饰品
local queue = {}                -- [0]/[1] = 战斗中排队的饰品名
local used = {}                 -- 用过的饰品，用于冷却提示
local worn, mbtn = {}, {}
local tip, refresh_in = nil, nil
local wtries, mtries = 0, 0

--[[ 工具 ]]--

local function LinkName(link)
	if not link then return nil end
	local _, _, name = string.find(link, "%[(.-)%]")
	return name
end

local function LinkID(link)
	if not link then return nil end
	local _, _, id = string.find(link, "item:(%d+)")
	return id
end

local function IsReallyDead()
	if not UnitIsDeadOrGhost("player") then return false end
	for i = 1, 24 do
		if UnitBuff("player", i) == "Interface\\Icons\\Ability_Rogue_FeignDeath" then
			return false
		end
	end
	return true
end

-- 返回 贴图, 名字, 链接
local function WornInfo(slot)
	local link = GetInventoryItemLink("player", slot)
	if link then
		local _, _, _, _, _, _, _, _, tex = GetItemInfo(LinkID(link) or "")
		return tex, LinkName(link), link
	end
	local _, tex = GetInventorySlotInfo("Trinket" .. (slot - 13) .. "Slot")
	return tex, nil, nil
end

-- 返回 inv 或 nil, bag, slot
local function FindItem(name, withInv)
	if withInv then
		for i = 13, 14 do
			if LinkName(GetInventoryItemLink("player", i)) == name then return i end
		end
	end
	for b = 0, 4 do
		for s = 1, GetContainerNumSlots(b) do
			if LinkName(GetContainerItemLink(b, s)) == name then return nil, b, s end
		end
	end
end

local function AutoCols(n)
	if n > 24 then return 5 elseif n > 18 then return 4
	elseif n > 12 then return 3 elseif n > 4 then return 2 end
	return 1
end

local function Schedule(delay) refresh_in = delay end

--[[ 窗口 ]]--

local function MakeButton(name, parent, id)
	local b = CreateFrame("CheckButton", name, parent, "ActionButtonTemplate")
	b:SetID(id)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b.icon = G[name .. "Icon"]
	b.cd = G[name .. "Cooldown"]
	local f = CreateFrame("Frame", nil, b)
	f:SetWidth(36); f:SetHeight(12)
	f:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
	b.text = f:CreateFontString(name .. "Time", "OVERLAY", "NumberFontNormal")
	b.text:SetJustifyH("CENTER")
	b.text:SetAllPoints(f)
	return b
end

local main = CreateFrame("Frame", "TrinketMenu_MainFrame", UIParent)
main:SetFrameStrata("LOW")
main:SetToplevel(true)
main:SetScale(CFG.SCALE)
main:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", CFG.X, CFG.Y)
local horizontal = (CFG.MAIN_ORIENT == "HORIZONTAL")
main:SetWidth(horizontal and 76 or 36)
main:SetHeight(horizontal and 36 or 76)

for i = 0, 1 do
	local b = MakeButton("TrinketMenu_Trinket" .. i, main, 13 + i)
	b:SetPoint("TOPLEFT", main, "TOPLEFT", horizontal and (i * SIZE) or 0, horizontal and 0 or (-i * SIZE))
	local qf = CreateFrame("Frame", nil, b)
	qf:SetWidth(18); qf:SetHeight(18)
	qf:SetPoint("TOPLEFT", b, "TOPLEFT", -2, 2)
	b.queue = qf:CreateTexture(nil, "OVERLAY")
	b.queue:SetAllPoints(qf)
	b.queue:Hide()
	worn[i] = b
end

local menu = CreateFrame("Frame", "TrinketMenu_MenuFrame", UIParent)
menu:SetFrameStrata("MEDIUM")
menu:SetToplevel(true)
menu:SetScale(CFG.SCALE)
menu:SetWidth(36); menu:SetHeight(36)
menu:Hide()
for i = 1, MAX do
	mbtn[i] = MakeButton("TrinketMenu_Menu" .. i, menu, i)
end

local scan = CreateFrame("GameTooltip", "TrinketMenu_TooltipScan", UIParent, "GameTooltipTemplate")
scan:Hide()

--[[ 冷却 ]]--

local function SetCD(btn, start, duration, enable)
	CooldownFrame_SetTimer(btn.cd, start, duration, enable)
	local t = btn.text
	if not CFG.COOLDOWN_TEXT or not start or start == 0 or not duration then
		t:SetText("")
		return
	end
	local remain = duration - (GetTime() - start)
	local cur = t:GetText()
	if remain <= 0 then
		t:SetText("")
	elseif remain < 3 and (cur == nil or cur == "") then
		-- 公共冷却，不显示
	elseif remain < 60 then
		t:SetText(math.floor(remain + .5) .. " s")
	elseif remain < 3600 then
		t:SetText(math.ceil(remain / 60) .. " m")
	else
		t:SetText(math.ceil(remain / 3600) .. " h")
	end
end

local function UpdateWornCooldowns()
	for i = 0, 1 do
		local start, dur, en = GetInventoryItemCooldown("player", 13 + i)
		SetCD(worn[i], start, dur, en)
	end
end

local function UpdateMenuCooldowns()
	for i = 1, nbagged do
		local t = bagged[i]
		local start, dur, en = GetContainerItemCooldown(t.bag, t.slot)
		SetCD(mbtn[i], start, dur, en)
	end
end

--[[ 冷却提示 ]]--

local function Notify(msg)
	if not CFG.NOTIFY then return end
	PlaySound("GnomeExploration")
	UIErrorsFrame:AddMessage(msg, .2, .7, .9, 1, 3)
	if CFG.NOTIFY_CHAT then DEFAULT_CHAT_FRAME:AddMessage("|cff33b2e5" .. msg) end
end

local function CheckUsed()
	for name, st in pairs(used) do
		local inv, bag, slot = FindItem(name, true)
		local start, dur
		if inv then
			start, dur = GetInventoryItemCooldown("player", inv)
		elseif bag then
			start, dur = GetContainerItemCooldown(bag, slot)
		end
		if not start then
			used[name] = nil
		elseif start > 0 and dur and dur > 5 then
			st.seen = true            -- 出现过真实冷却（排除公共冷却）
		elseif start == 0 then
			st.age = st.age + 1
			if st.seen then
				used[name] = nil
				Notify(name .. " ready!")
			elseif st.age >= 3 then
				used[name] = nil       -- 没有真实冷却，不用盯了
			end
		end
	end
end

--[[ Tooltip ]]--

local function ShowTip()
	if not tip or not CFG.TOOLTIPS then return end
	GameTooltip_SetDefaultAnchor(GameTooltip, tip.owner)
	local start
	if tip.bag then
		GameTooltip:SetBagItem(tip.bag, tip.slot)
		start = GetContainerItemCooldown(tip.bag, tip.slot)
	else
		GameTooltip:SetInventoryItem("player", tip.inv)
		start = GetInventoryItemCooldown("player", tip.inv)
		local q = queue[tip.inv - 13]
		if q then GameTooltip:AddLine("Queued: " .. q) end
	end
	tip.cd = start and start > 0
	GameTooltip:Show()
end

--[[ 菜单 ]]--

local function BuildMenu()
	if CFG.MENU_ON_SHIFT and not IsShiftKeyDown() then return end
	nbagged = 0
	local pending = false
	for b = 0, 4 do
		for s = 1, GetContainerNumSlots(b) do
			local link = GetContainerItemLink(b, s)
			if link then
				local id = LinkID(link)
				local _, _, _, _, _, _, _, loc, tex = GetItemInfo(id or "")
				if loc == "INVTYPE_TRINKET" then
					if nbagged < MAX then
						nbagged = nbagged + 1
						local t = bagged[nbagged]
						if not t then t = {}; bagged[nbagged] = t end
						t.bag, t.slot, t.name, t.tex = b, s, LinkName(link), tex
					end
				elseif not loc and id then
					pending = true      -- 物品数据还没同步
				end
			end
		end
	end
	if pending then
		if mtries < 20 then mtries = mtries + 1; Schedule(0.5) end
	else
		mtries = 0
	end

	if nbagged < 1 then menu:Hide(); return end

	local cols = CFG.COLUMNS or AutoCols(nbagged)
	if cols > nbagged then cols = nbagged end
	local rows = math.ceil(nbagged / cols)
	local S = SIDE[CFG.MENU_SIDE] or SIDE.RIGHT

	menu:ClearAllPoints()
	menu:SetPoint(S.point, main, S.rel, 0, 0)
	menu:SetWidth(cols * SIZE - 4)
	menu:SetHeight(rows * SIZE - 4)

	for i = 1, MAX do
		local btn = mbtn[i]
		if i <= nbagged then
			local row = math.floor((i - 1) / cols)
			local col = (i - 1) - row * cols
			btn:ClearAllPoints()
			btn:SetPoint(S.point, menu, S.point, col * SIZE * S.xd, row * SIZE * S.yd)
			btn.icon:SetTexture(bagged[i].tex)
			btn:Show()
		else
			btn:Hide()
		end
	end
	UpdateMenuCooldowns()
	menu:Show()
end

--[[ 排队 / 换装 ]]--

local function UpdateQueue()
	for w = 0, 1 do
		local icon = worn[w].queue
		icon:Hide()
		if queue[w] then
			local _, b, s = FindItem(queue[w])
			if b then
				local tex = GetContainerItemInfo(b, s)
				icon:SetTexture(tex)
				icon:Show()
			end
		end
	end
end

local function EquipByName(name, slot)
	if not name then return end
	if UnitAffectingCombat("player") or IsReallyDead() then
		local which = slot - 13
		if queue[which] == name then
			queue[which] = nil
		else
			if queue[1 - which] == name then queue[1 - which] = nil end
			queue[which] = name
		end
	elseif not CursorHasItem() and not SpellIsTargeting() then
		local _, b, s = FindItem(name)
		if b then
			local _, _, locked = GetContainerItemInfo(b, s)
			if not locked and not IsInventoryItemLocked(slot) then
				PickupContainerItem(b, s)
				PickupInventoryItem(slot)
				worn[slot - 13].icon:SetDesaturated(1)
				Schedule(0.75)
			end
		end
	end
	UpdateQueue()
end

local function UpdateWorn()
	local retry = false
	for i = 0, 1 do
		local tex, _, link = WornInfo(13 + i)
		worn[i].icon:SetTexture(tex)
		worn[i].icon:SetDesaturated(nil)
		worn[i]:SetChecked(nil)
		if link and not tex then retry = true end   -- 物品数据没同步，稍后重试
	end
	UpdateWornCooldowns()
	if retry then
		if wtries < 20 then wtries = wtries + 1; Schedule(0.5) end
	else
		wtries = 0
	end
	if menu:IsVisible() then BuildMenu() end
end

local function ReflectUse(slot)
	worn[slot - 13]:SetChecked(1)
	Schedule(0.75)
	if CFG.NOTIFY then
		local name = LinkName(GetInventoryItemLink("player", slot))
		if name then used[name] = { age = 0 } end
	end
end

--[[ 事件处理（同时兼容 this/arg1 全局和 self/参数 两种约定）]]--

local function WornClick(self)
	self = self or this
	if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
		self:SetChecked(nil)
		ChatFrameEditBox:Insert(GetInventoryItemLink("player", self:GetID()))
	else
		UseInventoryItem(self:GetID())
	end
end

local function WornEnter(self)
	self = self or this
	BuildMenu()
	tip = { owner = self, inv = self:GetID() }
	ShowTip()
end

local function MenuClick(self, button)
	self = self or this
	button = button or arg1
	self:SetChecked(nil)
	local t = bagged[self:GetID()]
	if not t then return end
	if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
		ChatFrameEditBox:Insert(GetContainerItemLink(t.bag, t.slot))
	else
		EquipByName(t.name, (button == "LeftButton") and 13 or 14)
		if not IsShiftKeyDown() and not CFG.KEEP_OPEN then menu:Hide() end
	end
end

local function MenuEnter(self)
	self = self or this
	local t = bagged[self:GetID()]
	if t then
		tip = { owner = self, bag = t.bag, slot = t.slot }
		ShowTip()
	end
end

local function Leave()
	GameTooltip:Hide()
	tip = nil
end

local function Tick()
	if CFG.NOTIFY then CheckUsed() end
	if CFG.COOLDOWN_TEXT then
		UpdateWornCooldowns()
		if menu:IsVisible() then UpdateMenuCooldowns() end
	end
	if tip and tip.cd then ShowTip() end
end

local function Init()
	local oldUseInventoryItem = UseInventoryItem
	UseInventoryItem = function(slot)
		oldUseInventoryItem(slot)
		if (slot == 13 or slot == 14) and not MerchantFrame:IsVisible() then
			ReflectUse(slot)
		end
	end

	local oldUseAction = UseAction
	UseAction = function(slot, cursor, onself)
		oldUseAction(slot, cursor, onself)
		if IsEquippedAction(slot) then
			scan:SetOwner(WorldFrame, "ANCHOR_NONE")
			scan:SetAction(slot)
			local text = G["TrinketMenu_TooltipScanTextLeft1"]:GetText()
			for i = 0, 1 do
				local _, name = WornInfo(13 + i)
				if name and name == text then ReflectUse(13 + i) end
			end
		end
	end

	UpdateWorn()
	UpdateQueue()
	if CFG.KEEP_OPEN then BuildMenu() end
end

local function OnEvent(self, ev, a1)
	ev = ev or event
	a1 = a1 or arg1
	if ev == "PLAYER_LOGIN" then
		Init()
	elseif ev == "UNIT_INVENTORY_CHANGED" then
		if a1 == "player" then UpdateWorn() end
	elseif ev == "ACTIONBAR_UPDATE_COOLDOWN" then
		UpdateWornCooldowns()
	elseif not IsReallyDead() and (queue[0] or queue[1]) then
		-- PLAYER_REGEN_ENABLED / PLAYER_UNGHOST / PLAYER_ALIVE：脱战或复活后执行排队
		local q0, q1 = queue[0], queue[1]
		queue[0], queue[1] = nil, nil
		EquipByName(q0, 13)
		EquipByName(q1, 14)
	end
end

--[[ 挂接 ]]--

for i = 0, 1 do
	worn[i]:SetScript("OnClick", WornClick)
	worn[i]:SetScript("OnEnter", WornEnter)
	worn[i]:SetScript("OnLeave", Leave)
end
for i = 1, MAX do
	mbtn[i]:SetScript("OnClick", MenuClick)
	mbtn[i]:SetScript("OnEnter", MenuEnter)
	mbtn[i]:SetScript("OnLeave", Leave)
end

main:SetScript("OnEvent", OnEvent)
main:RegisterEvent("PLAYER_LOGIN")
main:RegisterEvent("UNIT_INVENTORY_CHANGED")
main:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
main:RegisterEvent("PLAYER_REGEN_ENABLED")
main:RegisterEvent("PLAYER_UNGHOST")
main:RegisterEvent("PLAYER_ALIVE")

local driver = CreateFrame("Frame", nil, UIParent)
local over_acc, tick_acc = 0, 0

-- 辅助函数：精准检测鼠标是否在某个 Frame 的矩形区域内（兼容 SCALE 缩放）
local function IsCursorOverFrame(f)
	if not f or not f:IsVisible() then return false end
	local scale = f:GetEffectiveScale() or 1
	local x, y = GetCursorPosition()
	x = x / scale
	y = y / scale

	local left = f:GetLeft()
	local bottom = f:GetBottom()
	local width = f:GetWidth()
	local height = f:GetHeight()

	if not left or not bottom or not width or not height then return false end

	return (x >= left and x <= (left + width) and y >= bottom and y <= (bottom + height))
end

driver:SetScript("OnUpdate", function(self, elapsed)
	elapsed = elapsed or arg1
	if not elapsed then return end

	if refresh_in then
		refresh_in = refresh_in - elapsed
		if refresh_in <= 0 then
			refresh_in = nil
			UpdateWorn()
		end
	end

	over_acc = over_acc + elapsed
	if over_acc >= .25 then
		over_acc = 0
		if menu:IsVisible() and not CFG.KEEP_OPEN and not IsShiftKeyDown() then
			-- 使用基于实际屏幕坐标和缩放的精准碰撞检测
			local over = IsCursorOverFrame(main) or IsCursorOverFrame(menu)
			for i = 0, 1 do if IsCursorOverFrame(worn[i]) then over = true end end
			for i = 1, nbagged do if IsCursorOverFrame(mbtn[i]) then over = true end end

			if not over then
				menu:Hide()
			end
		end
	end

	tick_acc = tick_acc + elapsed
	if tick_acc >= 1 then
		tick_acc = 0
		Tick()
	end
end)
