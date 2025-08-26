local teleport_button = ac.ControlButton("AdvancedTeleport/Teleport")
local sim = ac.getSim()
local teleports = {}
local teleportGroups = {}
local selectedGroupIndex = -1
local mapId = nil
local mapHash = nil
local configFile = ac.getFolder(ac.FolderID.ACApps) .. "/lua/AdvancedTeleport/config.ini"

local teleportInProgress = false
local teleportToPitsInProgress = false
local teleportToGroupInProgress = false

local targetTeleport = nil

local function checkTeleportOccupied(teleport, shouldConsiderCars)
    for i=0, sim.carsCount-1 do
        if shouldConsiderCars[i] and ac.getCar(i).position:distanceSquared(teleport.POS)<(6^2) then
            return true
        end
    end
    return false
end

local function hashMapName(mapName)
    local hash = 0
    for i = 1, #mapName do
        hash = ((hash * 31) + string.byte(mapName, i)) % 1000000
    end
    return "MAP_" .. hash
end

-- Load teleport points from server configuration
local function loadOnlineTeleports()
    teleports = {}
    teleportGroups = {}
    if not (sim.isOnlineRace and ac.INIConfig.onlineExtras) then
        return
    end
    
    local ini = ac.INIConfig.onlineExtras()
    local teleport_data = {}
    
    -- Parse teleport points from INI file
    for a, b in ini:iterateValues('TELEPORT_DESTINATIONS', 'POINT') do
        local n = tonumber(b:match('%d+')) + 1
        
        if teleport_data[n] == nil then
            for i = #teleport_data, n do
                if teleport_data[i] == nil then teleport_data[i] = {} end
            end
        end
        
        local suffix = b:match('_(%a+)$')
        if suffix == nil then 
            teleport_data[n]['POINT'] = ini:get('TELEPORT_DESTINATIONS', b, 'noname' .. n-1)
        elseif suffix == 'POS' then 
            teleport_data[n]['POS'] = ini:get('TELEPORT_DESTINATIONS', b, vec3())
        elseif suffix == 'HEADING' then 
            teleport_data[n]['HEADING'] = ini:get('TELEPORT_DESTINATIONS', b, 0)
        elseif suffix == 'GROUP' then 
            teleport_data[n]['GROUP'] = ini:get('TELEPORT_DESTINATIONS', b, 'group')
        end
        teleport_data[n]["N"] = n
        teleport_data[n]['INDEX'] = 0
    end
    
    -- Convert to sorted array
    for i = 1, #teleport_data do
        if teleport_data[i]["POINT"] ~= nil then
            teleport_data[i]['INDEX'] = #teleports
            if teleport_data[i].HEADING == nil then teleport_data[i]['HEADING'] = 0 end
            if teleport_data[i].POS == nil then teleport_data[i]['POS'] = vec3() end
            table.insert(teleports, teleport_data[i])
        end
    end
    
    -- Group teleports by GROUP property
    local groupMap = {}
    for _, teleport in ipairs(teleports) do
        local groupName = teleport.GROUP or "Default"
        if not groupMap[groupName] then
            groupMap[groupName] = {
                name = groupName,
                teleports = {}
            }
        end
        table.insert(groupMap[groupName].teleports, teleport)
    end
    
    -- Convert group map to sorted array
    for groupName, group in pairs(groupMap) do
        table.insert(teleportGroups, group)
    end
    
    -- Sort groups by name
    table.sort(teleportGroups, function(a, b) return a.name < b.name end)
    
    -- Load saved group index for current map
    local config = ac.INIConfig.load(configFile)
    
    local savedIndex = config:get(mapHash, "SELECTED_GROUP_INDEX", -1)
    
    -- Validate that the saved index is still valid for current groups
    if savedIndex >= 0 and savedIndex < #teleportGroups then
        selectedGroupIndex = savedIndex
    else
        selectedGroupIndex = -1
    end
end

function script.windowShow()
    loadOnlineTeleports()
    mapId = ac.getTrackFullID('/')
    mapHash = hashMapName(mapId)
end

function script.windowMain(dt)
    ui.text('Teleport Button:')
    teleport_button:control()

    ui.separator()
    
    ui.text('Available Teleports:')

    local availableTeleports = {}
    local firstTeleport = nil
    
    if #teleportGroups == 0 then
        if sim.isOnlineRace then
            ui.textColored('No teleport groups available', rgbm.colors.yellow)
        else
            ui.textColored('Not in online race', rgbm.colors.red)
        end
    else
        local shouldConsiderCars = {}

        for i=0, sim.carsCount-1 do
            local car = ac.getCar(i)
            if ((not sim.isReplayOnlyMode) and car.isConnected and (not car.isHidingLabels)) or (sim.isReplayActive and car.isActive) then
                shouldConsiderCars[i] = true
            end
        end

        -- Display teleport groups as radio buttons
        for i, group in ipairs(teleportGroups) do
            local groupName = group.name
            local availableCount = 0
            local totalCount = #group.teleports
            
            for _, teleport in ipairs(group.teleports) do
                if selectedGroupIndex == i - 1 and firstTeleport == nil then
                    firstTeleport = teleport
                end

                if not checkTeleportOccupied(teleport, shouldConsiderCars) then
                    availableCount = availableCount + 1
                    if selectedGroupIndex == i - 1 then
                        table.insert(availableTeleports, teleport)
                    end
                end
            end
            
            local displayName = groupName .. ' (' .. availableCount .. '/' .. totalCount .. ' available)'
            
            -- Color code based on availability
            if availableCount == 0 then
                ui.pushStyleColor(ui.StyleColor.Text, rgbm.colors.red)
            elseif availableCount < totalCount then
                ui.pushStyleColor(ui.StyleColor.Text, rgbm.colors.yellow)
            end
            
            if ui.radioButton(displayName .. '##' .. i, selectedGroupIndex == i - 1) then
                selectedGroupIndex = i - 1
                if selectedGroupIndex < 0 then return end
    
                local config = ac.INIConfig.load(configFile)
                
                config:set(mapHash, "SELECTED_GROUP_INDEX", selectedGroupIndex)
                config:set(mapHash, "MAP_NAME", mapId)
                config:save()
            end
            
            if availableCount == 0 then
                ui.popStyleColor()
                if ui.itemHovered() then
                    ui.setTooltip('All teleports in this group are blocked')
                end
            elseif availableCount < totalCount then
                ui.popStyleColor()
                if ui.itemHovered() then
                    ui.setTooltip('Some teleports in this group are blocked')
                end
            end
        end
    end

    if teleport_button:pressed() then
        if not teleportInProgress then
            teleportInProgress = true
            targetTeleport = availableTeleports[1] or firstTeleport
            if ac.canTeleportToServerPoint(targetTeleport.INDEX) then
                ac.teleportToServerPoint(targetTeleport.INDEX)
                teleportToGroupInProgress = true
            else
                teleportToPitsInProgress = true
            end
        else
            teleportInProgress = false
            teleportToPitsInProgress = false
            teleportToGroupInProgress = false
            targetTeleport = nil
        end
    end

    if teleportInProgress then
        if teleportToPitsInProgress then
            if ac.tryToTeleportToPits() then
                teleportToPitsInProgress = false
                teleportToGroupInProgress = true
            end
        elseif teleportToGroupInProgress then
            if ac.getCar(0).position:distanceSquared(targetTeleport.POS) < (6^2) then
                teleportInProgress = false
                teleportToGroupInProgress = false
                targetTeleport = nil
            elseif ac.canTeleportToServerPoint(targetTeleport.INDEX) then
                ac.teleportToServerPoint(targetTeleport.INDEX)
            end
        end
    end
end